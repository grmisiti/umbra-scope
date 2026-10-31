import Foundation
import Metal

/// Receives frames published by the Umbra Link OFX plugin over ZeroMQ (see Shared/umbralink_protocol.h).
final class LinkSource: FrameSource {
    private let device: MTLDevice
    private let lock = NSLock()
    private var latest: (header: ul_frame_header, data: Data)?
    private var latestSeq = 0
    private var consumedSeq = 0
    private var lastMessage = Date.distantPast
    /// Why the last message was refused (wrong protocol version…), shown until a valid frame arrives.
    private var rejectedReason: String?
    /// Set when the ZeroMQ socket could not be set up: nothing will ever arrive.
    private var failure: String?
    private var _running = true
    private var running: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _running }
        set { lock.lock(); _running = newValue; lock.unlock() }
    }
    private var thread: Thread?
    private let textures: TextureRing

    init(device: MTLDevice) {
        self.device = device
        textures = TextureRing(device: device)
        let t = Thread { [weak self] in self?.receiveLoop() }
        t.name = "LinkSource"
        t.start()
        thread = t
    }

    /// The receive thread keeps the source alive until this is called.
    func stop() { running = false }

    var title: String { "Umbra Link" }

    var status: String {
        lock.lock(); defer { lock.unlock() }
        if let failure { return failure }
        if let rejectedReason { return rejectedReason }
        let age = Date().timeIntervalSince(lastMessage)
        if latest == nil { return "waiting for Resolve…" }
        return age < 1.5 ? "live" : String(format: "last frame %.0f s ago", age)
    }

    // MARK: - receive (background thread)

    private func fail(_ message: String) {
        lock.lock(); failure = message; lock.unlock()
        print("link: \(message)")
    }

    private func reject(_ reason: String) {
        lock.lock(); rejectedReason = reason; lock.unlock()
    }

    private func receiveLoop() {
        guard let ctx = zmq_ctx_new() else { fail("could not start ZeroMQ"); return }
        guard let sub = zmq_socket(ctx, ZMQ_SUB) else { zmq_ctx_term(ctx); fail("could not create the link socket"); return }
        var hwm: Int32 = 4, timeout: Int32 = 300, linger: Int32 = 0
        var maxBytes = Int64(UL_MAX_MESSAGE_BYTES)
        zmq_setsockopt(sub, ZMQ_MAXMSGSIZE, &maxBytes, 8)  // drops a peer that sends more
        zmq_setsockopt(sub, ZMQ_RCVHWM, &hwm, 4)
        zmq_setsockopt(sub, ZMQ_RCVTIMEO, &timeout, 4)
        zmq_setsockopt(sub, ZMQ_LINGER, &linger, 4)
        zmq_setsockopt(sub, ZMQ_SUBSCRIBE, "", 0)
        // ZeroMQ reconnects on its own, so this works whether the plugin starts before or after the app.
        var endpoint = [CChar](repeating: 0, count: 256)
        if ul_endpoint(&endpoint, endpoint.count) != 0 {
            fail("link path too long (TMPDIR)")
        } else if zmq_connect(sub, endpoint) != 0 {
            fail("could not connect: \(String(cString: zmq_strerror(zmq_errno())))")
        }
        if failure != nil { zmq_close(sub); zmq_ctx_term(ctx); return }

        while running {
            var parts = [Data]()
            var msg = zmq_msg_t()
            zmq_msg_init(&msg)
            guard zmq_msg_recv(&msg, sub, 0) >= 0 else {
                zmq_msg_close(&msg)
                let err = zmq_errno()
                if err == EAGAIN || err == EINTR { continue }  // timeout: check `running` again
                if err == ETERM { break }
                usleep(50_000)  // anything else: don't spin on a persistent error
                continue
            }
            while true {
                parts.append(Data(bytes: zmq_msg_data(&msg), count: zmq_msg_size(&msg)))
                let more = zmq_msg_more(&msg) != 0
                zmq_msg_close(&msg)
                if !more { break }
                zmq_msg_init(&msg)
                if zmq_msg_recv(&msg, sub, 0) < 0 { zmq_msg_close(&msg); break }
            }
            guard parts.count == 2, parts[0].count >= MemoryLayout<ul_frame_header>.size else { continue }
            var header = ul_frame_header()
            _ = withUnsafeMutableBytes(of: &header) { dst in
                parts[0].copyBytes(to: dst.bindMemory(to: UInt8.self), count: MemoryLayout<ul_frame_header>.size)
            }
            // Only well-formed Umbra Link frames: right magic and version, a known format, a sane size, and exactly
            // the number of pixel bytes the header announces.
            let bpp = ul_bytes_per_pixel(header.format)
            guard header.magic == UL_MAGIC else { reject("not an Umbra Link frame"); continue }
            guard header.version == UL_VERSION else {
                reject("plugin protocol v\(header.version), app expects v\(UL_VERSION) — reinstall the plugin")
                continue
            }
            guard bpp > 0 else { reject("unknown pixel format \(header.format) — reinstall the plugin"); continue }
            guard
                  header.width > 0, header.height > 0, header.width <= UL_MAX_DIMENSION, header.height <= UL_MAX_DIMENSION,
                  Int(header.width) * Int(header.height) <= Int(UL_MAX_PIXELS),
                  parts[1].count == Int(header.width) * Int(header.height) * bpp else { continue }
            lock.lock()
            lastMessage = Date()
            rejectedReason = nil
            latest = (header, parts[1])
            latestSeq += 1
            lock.unlock()
        }
        zmq_close(sub)
        zmq_ctx_term(ctx)
    }

    // MARK: - upload (render thread)

    func nextFrame() -> SourceFrame? {
        lock.lock()
        guard latestSeq != consumedSeq, let (h, data) = latest else { lock.unlock(); return nil }
        consumedSeq = latestSeq
        lock.unlock()

        let w = Int(h.width), ht = Int(h.height)
        let float = h.format == UInt32(UL_FORMAT_RGBA32F.rawValue)
        let format: MTLPixelFormat = float ? .rgba32Float : .rgba16Unorm
        let rowBytes = w * ul_bytes_per_pixel(h.format)
        guard let tex = textures.next(width: w, height: ht, format: format) else { return nil }
        data.withUnsafeBytes { buf in
            tex.replace(region: MTLRegionMake2D(0, 0, w, ht), mipmapLevel: 0, withBytes: buf.baseAddress!, bytesPerRow: rowBytes)
        }

        let legal = h.flags & UInt32(UL_FLAG_LEGAL_RANGE.rawValue) != 0
        let tc = h.timecode
        let info = String(format: "%d×%d %@ %@ %02d:%02d:%02d:%02d", w, ht, float ? "float" : "16-bit",
                          legal ? "legal" : "full", tc.0, tc.1, tc.2, tc.3)
        return SourceFrame(texture: tex, swapRB: false, videoRange: legal, flipY: false, info: info)
    }
}
