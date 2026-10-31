import AVFoundation
import CoreVideo
import Metal
import QuartzCore

/// Plays a video file from the Finder in a loop (muted) and hands out new decoded frames.
/// Frames are requested as 16-bit half-float RGBA, so 10- and 12-bit files (ProRes, HEVC Main 10…) keep
/// their precision; 8-bit files lose nothing either.
final class VideoSource: SeekableSource {
    let url: URL
    private let player: AVPlayer
    private let item: AVPlayerItem
    private let output: AVPlayerItemVideoOutput
    private var endObserver: NSObjectProtocol?
    private var textureCache: CVMetalTextureCache!
    /// Frame rate, filled in asynchronously once the asset's track is loaded.
    private final class FrameRate: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Double = 0
        var value: Double {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }
    private let frameRate = FrameRate()
    private var fps: Double { frameRate.value }

    init(url: URL, device: MTLDevice) {
        self.url = url
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        // A QuickTime movie can point at media elsewhere (other files, URLs); only its own media is played, so a
        // crafted movie can't make the app open network locations or read other files.
        let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        item = AVPlayerItem(asset: asset)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
        }
        let frameRate = frameRate
        Task {
            let tracks = try? await asset.loadTracks(withMediaType: .video)
            let rate = try? await tracks?.first?.load(.nominalFrameRate)
            frameRate.value = Double(rate ?? 0)
        }
        player.play()
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player.pause()
    }

    var title: String { url.lastPathComponent }
    var status: String { player.rate != 0 ? "playing" : "paused" }

    func togglePlay() {
        if player.rate != 0 { player.pause() } else { player.play() }
    }

    var isPlaying: Bool { player.rate != 0 }
    var framesPerSecond: Double { fps > 0 ? fps : 24 }
    var frameCount: Int {
        let d = item.duration.seconds
        return d.isFinite && d > 0 ? Int((d * framesPerSecond).rounded()) : 0
    }
    var currentFrame: Int {
        let t = player.currentTime().seconds
        return t.isFinite ? Int((t * framesPerSecond).rounded()) : 0
    }
    func seek(toFrame frame: Int) {
        player.pause()
        let t = CMTime(value: CMTimeValue(max(0, frame)) * 1000, timescale: CMTimeScale((framesPerSecond * 1000).rounded()))
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func setPlaying(_ playing: Bool) { if playing { player.play() } else { player.pause() } }

    /// Pauses and moves by whole frames (negative = back).
    func step(_ frames: Int) {
        player.pause()
        item.step(byCount: frames)
    }

    func nextFrame() -> SourceFrame? {
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t) else { return nil }
        var shown = CMTime.zero
        guard let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown) else { return nil }
        var cvTex: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, .rgba16Float, w, h, 0, &cvTex)
        guard let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        return SourceFrame(texture: tex, info: "\(w)×\(h) 16-bit file \(timecode(shown))", retain: cvTex)
    }

    private func timecode(_ time: CMTime) -> String {
        let seconds = max(0, time.seconds.isFinite ? time.seconds : 0)
        guard fps > 0 else { return String(format: "%.2fs", seconds) }
        let rate = max(1, Int(fps.rounded()))  // fps < 0.5 would round to 0
        let frame = Int((seconds * fps).rounded())
        return String(format: "%02d:%02d:%02d:%02d", frame / (rate * 3600), frame / (rate * 60) % 60, frame / rate % 60, frame % rate)
    }
}
