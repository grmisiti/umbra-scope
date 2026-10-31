import AVFoundation
import CoreVideo
import Metal

/// Live video from a capture card or camera (UVC devices such as HDMI-to-USB cards) through AVCaptureSession.
final class CaptureSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "CaptureSource")
    private let deviceName: String
    let deviceID: String
    private var textureCache: CVMetalTextureCache?
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var latestSeq = 0
    private var consumedSeq = 0
    private var lastFrame = Date.distantPast
    private var failure: String?
    /// Set by stop(): a configure() still waiting for camera access must not start the session afterwards.
    private var stopped = false
    private let output = AVCaptureVideoDataOutput()

    /// Capture devices, external ones (capture cards) first.
    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
            .sorted { ($0.deviceType == .external ? 0 : 1) < ($1.deviceType == .external ? 0 : 1) }
    }

    init(device captureDevice: AVCaptureDevice, metal: MTLDevice) {
        deviceName = captureDevice.localizedName
        deviceID = captureDevice.uniqueID
        super.init()
        CVMetalTextureCacheCreate(nil, nil, metal, nil, &textureCache)
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            if granted { self.queue.async { self.configure(captureDevice) } }
            else { self.fail("camera access denied (System Settings → Privacy & Security → Camera)") }
        }
    }

    private func fail(_ message: String) {
        lock.lock(); failure = message; lock.unlock()
        print("capture: \(message)")
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func configure(_ captureDevice: AVCaptureDevice) {
        if isStopped { return }
        session.beginConfiguration()
        session.sessionPreset = .high
        do {
            let input = try AVCaptureDeviceInput(device: captureDevice)
            guard session.canAddInput(input) else { throw CocoaError(.featureUnsupported) }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            fail("could not open \(deviceName): \(error.localizedDescription)")
            return
        }
        // Prefer the largest format, then the highest frame rate (MS2109 cards: 1080p30 over 720p60).
        let best = captureDevice.formats.max { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            let pa = Int(da.width) * Int(da.height), pb = Int(db.width) * Int(db.height)
            if pa != pb { return pa < pb }
            return (a.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                < (b.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }
        if let best {
            do {
                try captureDevice.lockForConfiguration()
                captureDevice.activeFormat = best
                if let range = best.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                    captureDevice.activeVideoMinFrameDuration = range.minFrameDuration
                }
                captureDevice.unlockForConfiguration()
            } catch {
                print("capture: could not pick the best format of \(deviceName), using its default: \(error.localizedDescription)")
            }
        }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                kCVPixelBufferMetalCompatibilityKey as String: true]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            fail("could not read video from \(deviceName)")
            return
        }
        session.addOutput(output)
        session.commitConfiguration()
        if isStopped { return }
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latest = pb
        latestSeq += 1
        lastFrame = Date()
        let first = latestSeq == 1
        lock.unlock()
        if first { print("capture: \(deviceName) live, \(CVPixelBufferGetWidth(pb))×\(CVPixelBufferGetHeight(pb))") }
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        queue.async { [session, output] in
            output.setSampleBufferDelegate(nil, queue: nil)
            session.stopRunning()
            // Release the device right away, so a new source can open the same card.
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            session.commitConfiguration()
        }
    }

    var title: String { deviceName }

    var status: String {
        lock.lock(); defer { lock.unlock() }
        if let failure { return failure }
        if latest == nil { return "waiting for signal…" }
        let age = Date().timeIntervalSince(lastFrame)
        return age < 1.5 ? "live" : String(format: "no signal for %.0f s", age)
    }

    func nextFrame() -> SourceFrame? {
        lock.lock()
        guard latestSeq != consumedSeq, let pb = latest, let cache = textureCache else { lock.unlock(); return nil }
        consumedSeq = latestSeq
        lock.unlock()
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        return SourceFrame(texture: tex, info: "\(w)×\(h) 8-bit capture", retain: cvTex)
    }
}
