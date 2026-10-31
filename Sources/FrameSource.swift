import Metal

/// A decoded frame ready for the decode pass, plus how to interpret its texture.
struct SourceFrame {
    var texture: MTLTexture
    var swapRB = false
    var videoRange = false
    var flipY = false
    /// One-line description for the window title (resolution, format, timecode…).
    var info = ""
    /// Owner of `texture`'s memory (e.g. a CVMetalTexture), kept alive until the GPU is done with the frame.
    var retain: AnyObject? = nil
}

/// A few textures used in turn, so an upload never overwrites one that in-flight command buffers still read.
final class TextureRing {
    private let device: MTLDevice
    private var slots: [MTLTexture] = []
    private var index = 0

    init(device: MTLDevice, count: Int = 3) {
        self.device = device
        self.count = count
    }
    private let count: Int

    /// The next slot, recreating the ring when size or format change.
    func next(width: Int, height: Int, format: MTLPixelFormat) -> MTLTexture? {
        if let t = slots.first, t.width != width || t.height != height || t.pixelFormat != format { slots = [] }
        if slots.isEmpty {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = .shared
            for _ in 0..<count {
                guard let t = device.makeTexture(descriptor: d) else { slots = []; return nil }
                slots.append(t)
            }
        }
        index = (index + 1) % slots.count
        return slots[index]
    }
}

/// Anything that can feed the scopes: a video file, a plugin stream, a still image.
protocol FrameSource: AnyObject {
    /// Name shown in the window title.
    var title: String { get }
    /// Connection or playback state, shown in the window title.
    var status: String { get }
    /// Returns a frame only when one newer than the last handed out is available.
    func nextFrame() -> SourceFrame?
    func togglePlay()
    /// Releases background work (threads, sockets) when the source is replaced or its window closes.
    func stop()
    /// Caveat shown over the picture (e.g. a rendering that isn't the camera maker's), or nil.
    var notice: String? { get }
}

/// Sources with a timeline (video files): what the player bar shows and drives.
protocol SeekableSource: FrameSource {
    var isPlaying: Bool { get }
    /// Number of frames, 0 while unknown.
    var frameCount: Int { get }
    /// Frame on screen (0-based).
    var currentFrame: Int { get }
    var framesPerSecond: Double { get }
    /// Pauses playback and shows that frame.
    func seek(toFrame frame: Int)
    func setPlaying(_ playing: Bool)
}

extension FrameSource {
    var status: String { "" }
    func togglePlay() {}
    func stop() {}
    var notice: String? { nil }
}
