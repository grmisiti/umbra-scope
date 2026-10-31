import Foundation
import Metal
import QuartzCore

/// A file decoded frame by frame on a background thread by FFmpeg or the Blackmagic RAW SDK
/// (see Sources/Decoders). Starts paused on the first frame; Space plays, `,` and `.` step.
final class FileDecodeSource: SeekableSource {
    let url: URL
    let info: fd_info
    private let decoder: OpaquePointer
    private let device: MTLDevice
    private let lock = NSLock()

    // Shared with the decode thread (guarded by `lock`).
    private var running = true
    private var playing = false
    private var current: Int64 = -1          // index of the frame last decoded
    private var pending: Int64? = 0          // frame to decode next when paused (first frame on open)
    private var latest: [UInt16]?
    private var latestIndex: Int64 = 0
    private var latestSeq = 0
    private var lastError: String?

    // Render-thread side.
    private var consumedSeq = 0
    private lazy var textures = TextureRing(device: device)

    /// Extensions handled here rather than by AVFoundation.
    static let extensions: Set<String> = ["braw", "mxf", "mkv", "avi", "webm", "mts", "m2ts", "r3d", "ari",
                                          "crm", "cr3", "cr2", "nef", "arw", "dng", "raf", "rw2", "orf", "pef", "srw"]

    init(url: URL, device: MTLDevice) throws {
        self.url = url
        self.device = device
        var info = fd_info()
        var err = [CChar](repeating: 0, count: 256)
        guard let d = fd_open(url.path, &info, &err, Int32(err.count)) else {
            throw NSError(domain: "Scopes", code: 20, userInfo: [NSLocalizedDescriptionKey: String(cString: err)])
        }
        decoder = d
        self.info = info
        let t = Thread { [weak self] in self?.decodeLoop() }
        t.name = "FileDecodeSource"
        t.start()
    }

    deinit { fd_close(decoder) }

    var title: String { url.lastPathComponent }

    /// RAW developed by LibRaw (Canon CRM, photo RAW) is not the camera maker's rendering: say so on screen.
    var notice: String? {
        let codec = withUnsafeBytes(of: info.codec) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard codec.hasSuffix("(LibRaw)") else { return nil }
        if url.pathExtension.lowercased() == "crm" {
            return "Canon Log 3 / Cinema Gamut via LibRaw, calibrated on an R5 C (ISO 800) — not Canon's processing."
        }
        return "LibRaw rendering, not the camera maker's. For exact values: Resolve + Umbra Link."
    }

    var status: String {
        lock.lock(); defer { lock.unlock() }
        if let e = lastError { return "error: \(e)" }
        let total = info.frame_count > 0 ? "/\(info.frame_count)" : ""
        return "\(playing ? "playing" : "paused") \(max(current, 0) + 1)\(total)"
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
    }

    func togglePlay() {
        lock.lock(); playing.toggle(); lock.unlock()
    }

    var isPlaying: Bool { lock.lock(); defer { lock.unlock() }; return playing }
    var frameCount: Int { Int(max(0, info.frame_count)) }
    var currentFrame: Int { lock.lock(); defer { lock.unlock() }; return Int(max(0, pending ?? current)) }
    var framesPerSecond: Double { info.fps > 0 ? info.fps : 24 }
    func seek(toFrame frame: Int) {
        lock.lock()
        playing = false
        var target = Int64(max(0, frame))
        if info.frame_count > 0 { target = min(target, info.frame_count - 1) }
        pending = target
        lock.unlock()
    }
    func setPlaying(_ p: Bool) { lock.lock(); playing = p; lock.unlock() }

    /// Pauses and moves by whole frames (negative = back).
    func step(_ frames: Int) {
        lock.lock()
        playing = false
        var target = max(0, current) + Int64(frames)
        if target < 0 { target = 0 }
        if info.frame_count > 0 { target = min(target, info.frame_count - 1) }
        pending = target
        lock.unlock()
    }

    // MARK: - decode thread

    private func decodeLoop() {
        var buffer = [UInt16](repeating: 0, count: Int(info.width) * Int(info.height) * 4)
        var nextDue = CACurrentMediaTime()
        let frameTime = info.fps > 0 ? 1 / info.fps : 1.0 / 24
        while true {
            lock.lock()
            guard running else { lock.unlock(); break }
            var want: Int64?
            if let p = pending {
                want = p
                pending = nil
            } else if playing && CACurrentMediaTime() >= nextDue {
                want = current + 1
            }
            lock.unlock()

            guard var index = want else {
                Thread.sleep(forTimeInterval: 0.004)
                continue
            }
            var r = buffer.withUnsafeMutableBufferPointer { fd_read(decoder, index, $0.baseAddress) }
            if r == 1 && index > 0 {          // past the end: loop
                index = 0
                r = buffer.withUnsafeMutableBufferPointer { fd_read(decoder, index, $0.baseAddress) }
            }
            nextDue = CACurrentMediaTime() + frameTime
            lock.lock()
            if r == 0 {
                current = index
                latest = buffer
                latestIndex = index
                latestSeq += 1
                lastError = nil
            } else {
                lastError = "could not decode frame \(index)"
                playing = false
            }
            lock.unlock()
        }
    }

    // MARK: - upload (render thread)

    func nextFrame() -> SourceFrame? {
        lock.lock()
        guard latestSeq != consumedSeq, let pixels = latest else { lock.unlock(); return nil }
        consumedSeq = latestSeq
        let index = latestIndex
        lock.unlock()

        let w = Int(info.width), h = Int(info.height)
        guard let tex = textures.next(width: w, height: h, format: .rgba16Unorm) else { return nil }
        pixels.withUnsafeBytes { buf in
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: buf.baseAddress!, bytesPerRow: w * 8)
        }
        let codec = withUnsafeBytes(of: info.codec) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let depth = info.bit_depth > 0 ? " \(info.bit_depth)-bit" : ""
        return SourceFrame(texture: tex, info: "\(w)×\(h) \(codec)\(depth) \(timecode(index))")
    }

    private func timecode(_ index: Int64) -> String {
        let rate = Int64(max(1, info.fps.rounded()))
        return String(format: "%02lld:%02lld:%02lld:%02lld", index / (rate * 3600), index / (rate * 60) % 60, index / rate % 60, index % rate)
    }
}
