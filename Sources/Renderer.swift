import AppKit
import CoreVideo
import Metal
import MetalKit

private struct ScatterUniforms {
    var frameSize: SIMD2<UInt32>
    var mode: UInt32
    var vecScale: Float
    var vecBins: UInt32
    var vecSpread: UInt32
    var waveMode: UInt32
    var roiShape: UInt32 = 0
    var roi = SIMD4<Float>(0, 0, 1, 1)
    var ditherRGB: Float = 0
    var ditherChroma: Float = 0
    var lumaRange = SIMD2<Float>(-1, 2)   // vectorscope: only samples with luma in this range (HML zones)
    var transfer: UInt32 = 0              // stops display: input curve
    var pad1: UInt32 = 0
    var pad2 = SIMD2<Float>(0, 0)
}

private struct MeanArgs {
    var roiShape: UInt32
    var pad = SIMD3<UInt32>(0, 0, 0)
    var roi: SIMD4<Float>
}

/// Curve of the material, so the stops display can return to scene-linear light (see to_linear in Scopes.metal).
enum StopsTransfer: UInt32, CaseIterable {
    case rec709 = 0, canonLog3, sLog3, logC3, bmdFilm5, davinciIntermediate, linear
    var title: String {
        ["Rec.709", "Canon Log 3", "S-Log3", "LogC3", "BMD Film Gen 5", "DaVinci Intermediate", "Linear"][Int(rawValue)]
    }
    var next: StopsTransfer { StopsTransfer(rawValue: (rawValue + 1) % UInt32(Self.allCases.count))! }

    /// CPU copy of the shader's curve, for the readout.
    func toLinear(_ y: Double) -> Double {
        switch self {
        case .rec709: return y < 0.081 ? y / 4.5 : pow((y + 0.099) / 1.099, 1 / 0.45)
        case .canonLog3:
            let x: Double
            if y < 0.04076162 { x = -(pow(10, (0.12783901 - y) / 0.36726845) - 1) / 14.98325 }
            else if y <= 0.105357102 { x = (y - 0.12512219) / 1.9754798 }
            else { x = (pow(10, (y - 0.12240537) / 0.36726845) - 1) / 14.98325 }
            return x * 0.9
        case .sLog3:
            let c = y * 1023
            return c >= 171.2102946929 ? pow(10, (c - 420) / 261.5) * 0.19 - 0.01 : (c - 95) * 0.01125 / (171.2102946929 - 95)
        case .logC3:
            let cut = 0.010591, a = 5.555556, b = 0.052272, c = 0.247190, d = 0.385537, e = 5.367655, f = 0.092809
            return y > e * cut + f ? (pow(10, (y - d) / c) - b) / a : (y - f) / e
        case .bmdFilm5:
            let A = 0.08692876065491224, B = 0.005494072432257808, C = 0.5300133392291939, D = 8.283605932402494, E = 0.09246575342465753
            return y < D * 0.005 + E ? (y - E) / D : exp((y - C) / A) - B
        case .davinciIntermediate:
            return y <= 0.02740668 ? y / 10.44426855 : pow(2, y / 0.07329248 - 7) - 0.0075
        case .linear: return y
        }
    }
}

/// Mean colour of the probe point or of the selection, in decoded signal units (1.0 = 100%).
struct Readout {
    var r: Double, g: Double, b: Double
    var pixels: Int
    var isSelection: Bool
}

/// A measured point: S1…S4 on the Source, R1…R4 on the Reference. Pairs with the same number are compared, and every
/// scope marks them (Source solid, Reference dashed) so one shot can be matched to the other.
struct ScopeTarget: Equatable {
    var r: Double, g: Double, b: Double
    var slot: Int                 // 0…3, the pair
    var fromReference: Bool
    var point: CGPoint            // picture uv
    var name: String { (fromReference ? "R" : "S") + "\(slot + 1)" }
    static let maxCount = 4       // per picture
}

/// A region marked on a scope, in signal terms; the picture then shows which pixels fall inside it.
struct ScopeMark: Equatable {
    enum Kind: UInt32 { case waveform = 1, vectorscope = 2 }
    var kind: Kind
    /// Waveform: frame x from, to (0…1) and signal value from, to. Vectorscope: Cb from, to and Cr from, to.
    var bounds: SIMD4<Float>
}

private struct EnvelopeArgs {
    var roiShape: UInt32
    var reset: UInt32
    var pad = SIMD2<UInt32>(0, 0)
    var roi: SIMD4<Float>
}

private struct PeaksArgs {
    var waveMode: UInt32
    var roiShape: UInt32
    var pad = SIMD2<UInt32>(0, 0)
    var roi: SIMD4<Float>
}

/// An area of the picture the scopes are limited to, in frame uv (0..1, origin top-left).
struct Selection: Equatable {
    enum Shape: UInt32 { case rectangle = 1, ellipse = 2 }
    var rect: CGRect
    var shape: Shape

    var uniform: SIMD4<Float> { SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)) }
    /// Fraction of the frame covered, used to keep the traces equally bright for small selections.
    var area: Float { Float(rect.width * rect.height) * (shape == .ellipse ? .pi / 4 : 1) }
}

private struct DecodeUniforms {
    var swapRB: UInt32
    var videoRange: UInt32
    var flipY: UInt32
    var lutMode: UInt32 = 0
    var shaperRange = SIMD2<Float>(0, 1)
    var cubeRange = SIMD2<Float>(0, 1)
    var shaperSize: Float = 1
    var cubeSize: Float = 1
    var pad = SIMD2<Float>(0, 0)
}

private struct PanelUniforms {
    var kind: UInt32
    var gain: Float
    var vecScale: Float
    var waveMode: UInt32 = 0
    var peakMax: Float = -1     // waveform peak lines; below -0.5 = not drawn
    var peakMin: Float = -1
    var roiShape: UInt32 = 0
    var noiseView: UInt32 = 0
    var roi = SIMD4<Float>(0, 0, 1, 1)
    var size = SIMD2<Float>(0, 0)     // card size in pixels
    var radius: Float = 0             // card corner radius in pixels
    var skin: UInt32 = 0              // picture: only skin tones in colour
    var wipe: Float = -1              // picture: where the Reference starts (0...1); < 0 = off
    var envFlags: UInt32 = 0          // waveform: 1 = this frame's min/max envelope, 2 = peak hold
    var envColumns: UInt32 = 0        // waveform: columns in the envelope buffers
    var envPad: Float = 0
    var markKind: UInt32 = 0          // picture: ScopeMark.Kind of the mark to highlight; scopes: outline to draw
    var markRGB: UInt32 = 0           // waveform mark in RGB mode: a pixel matches when any channel is in range
    var targetCount: UInt32 = 0       // waveform / vectorscope / stops: targets passed in buffer 3
    var vecSignal: Float = 1         // vectorscope: signal gain (2 = Show 2x Zoom); graticule unchanged
    var mark = SIMD4<Float>(0, 0, 0, 0)   // picture: ScopeMark.bounds; scopes: outline in panel uv (x0, x1, y0, y1)
}

private struct NoiseArgs {
    var swapRB: UInt32
    var videoRange: UInt32
    var flipY: UInt32
    var roiShape: UInt32
    var roi: SIMD4<Float>
}

/// Noise of one picture (inside its selection), measured on the received frame at full resolution.
/// Sigmas are standard deviations in signal units (1.0 = 100%), from the 3x3 high-pass residual.
struct NoiseStats {
    var pixels: Int
    var width: Int, height: Int
    var meanY: Float
    var sigmaY: Float, sigmaCb: Float, sigmaCr: Float
    var sigmaR: Float, sigmaG: Float, sigmaB: Float
    /// 20 log10(mean / sigma) on luma; nil when the area is black.
    var snrDB: Float? { meanY > 1e-4 && sigmaY > 0 ? 20 * log10(meanY / sigmaY) : nil }
}

/// Picture panels can show the noise instead of the image (high-pass residual amplified on grey).
enum NoiseView: UInt32, CaseIterable {
    case off = 0, luma = 1, chroma = 2
    var title: String { ["Off", "Luma ×10", "Chroma ×10"][Int(rawValue)] }
    var next: NoiseView { NoiseView(rawValue: (rawValue + 1) % 3)! }
}

/// How the waveform plots each sample.
enum WaveformMode: UInt32, CaseIterable {
    case color = 0   // luma position, drawn in the sample's own colour
    case rgb = 1     // R, G and B each at their own level, in their own colour
    case luma = 2    // luma position, monochrome

    var title: String { ["Color", "RGB", "Luma"][Int(rawValue)] }
    var next: WaveformMode { WaveformMode(rawValue: (rawValue + 1) % 3)! }
}

/// How much each sample is spread before plotting, to hide the steps of a quantised source.
enum DitherMode: Int, CaseIterable {
    case tenBit, eightBit, off

    var title: String { ["10-bit", "8-bit", "no smoothing"][rawValue] }
    var next: DitherMode { DitherMode(rawValue: (rawValue + 1) % 3)! }
    /// One code value in RGB and in Cb/Cr.
    var steps: (rgb: Float, chroma: Float) {
        switch self {
        case .tenBit: return (1 / 1023, 1 / 896)
        case .eightBit: return (1 / 255, 1 / 224)
        case .off: return (0, 0)
        }
    }
}

/// Page layout presets.
enum LayoutMode: String, CaseIterable {
    /// Live Source next to a Reference (snapshot), each with its own waveform and vectorscope.
    case comparison
    /// The Source alone: one picture, one waveform, one vectorscope, false colour.
    case single

    var title: String { self == .comparison ? "Comparison" : "Single" }
    /// Relative widths of the bottom-row columns (see PanelLayout.columns).
    var defaultWeights: [Double] { self == .comparison ? [0.975, 0.975, 1.0, 1.0, 1.25] : [1.3, 1.0, 1.3] }
}

/// The scope cards of the bottom row; each can be hidden, and the others share its width.
enum ScopePanel: Int, CaseIterable {
    /// `tools` is the last card: in Single a tabbed slot (HML, Stops, False Color), in Comparison False Color.
    case waveform, vectorscope, tools

    var title: String {
        switch self {
        case .waveform: return "Waveform"
        case .vectorscope: return "Vectorscope"
        case .tools: return "Tool Slot (HML · Stops · False Color)"
        }
    }

    /// Weight slots (indices into the layout's columnWeights) this panel occupies.
    func slots(in mode: LayoutMode) -> [Int] {
        switch (mode, self) {
        case (.comparison, .waveform): return [0, 1]
        case (.comparison, .vectorscope): return [2, 3]
        case (.comparison, .tools): return [4]
        case (.single, _): return [rawValue]
        }
    }
}

/// What the Single layout's tool slot shows.
enum ToolTab: Int, CaseIterable {
    case hml, stops, falseColor
    var title: String { ["HML", "Stops", "False Color"][rawValue] }
}

/// A panel that can fill the whole window (Cmd+F).
enum ZoomTarget: Equatable {
    case livePicture, snapPicture, liveWave, snapWave, liveVec, snapVec, tool

    /// Weight slot of the panel in a layout, or nil when that layout has no such panel.
    func slot(in mode: LayoutMode) -> Int? {
        switch (mode, self) {
        case (.single, .liveWave): return 0
        case (.single, .liveVec): return 1
        case (.single, .tool): return 2
        case (.comparison, .liveWave): return 0
        case (.comparison, .snapWave): return 1
        case (.comparison, .liveVec): return 2
        case (.comparison, .snapVec): return 3
        case (.comparison, .tool): return 4
        default: return nil
        }
    }
}

/// One picture with its own waveform and vectorscope: the live signal or the snapshot.
final class ScopeChannel {
    let name: String
    var source: FrameSource? {
        didSet {
            // A new source must not show the old one's picture and scopes under its own name.
            if oldValue !== source { oldValue?.stop(); dropPicture() }
            frameInfo = ""
        }
    }
    /// Description of the last frame decoded (size, format, timecode).
    fileprivate(set) var frameInfo = ""
    /// Vectorscope magnification around the centre (1 = 100%). The scatter is redone at the new scale, so
    /// zooming adds detail instead of enlarging pixels.
    var vecZoom: Float = 1 {
        didSet {
            vecZoom = min(max(vecZoom, Renderer.vecZoomRange.lowerBound), Renderer.vecZoomRange.upperBound)
            if vecZoom != oldValue { scatterDirty = true }
        }
    }
    /// Show 2x Zoom: chroma doubled before it reaches the vectorscope; the graticule keeps its scale.
    var vecBoost: Float = 1 {
        didSet { if vecBoost != oldValue { scatterDirty = true } }
    }
    /// Scale of the signal on the vectorscope: mouse zoom times the 2x signal gain.
    var vecView: Float { vecZoom * vecBoost }
    var hasFrame: Bool { frameTex != nil }
    /// Limits the waveform, vectorscope and peaks to part of the picture; nil = whole frame.
    var selection: Selection? {
        didSet { if selection != oldValue { scatterDirty = true; noiseDirty = true; readoutDirty = true; holdReset = true } }
    }
    /// Region marked on this picture's waveform or vectorscope (nil = none).
    var mark: ScopeMark?
    /// Waveform envelopes, per frame column: this frame's min/max and the peak hold (see wave_envelope).
    fileprivate var envBuf: MTLBuffer?
    fileprivate var holdBuf: MTLBuffer?
    /// The peak hold starts over from the next frame (new source, selection or size, or the user's reset).
    fileprivate var holdReset = true
    /// Point measured by the readout when there is no selection (frame uv, origin top-left).
    var probe: CGPoint? { didSet { readoutDirty = true } }
    /// Up to four measured points (picture uv) that stay put; their values are measured again on every new frame.
    var points: [CGPoint?] = Array(repeating: nil, count: ScopeTarget.maxCount) { didSet { pointsDirty = true } }
    /// Mean colour (5×5 px) at each point; updated a frame after the picture or the points change.
    fileprivate(set) var pointValues: [Readout?] = Array(repeating: nil, count: ScopeTarget.maxCount)
    fileprivate var pointsDirty = false
    /// Mean colour at the probe or inside the selection. Updated a frame after they change.
    fileprivate(set) var readout: Readout?
    fileprivate var readoutDirty = false
    /// Noise inside the selection (or the whole frame). Updated a frame after the picture or the selection changes.
    fileprivate(set) var noise: NoiseStats?
    /// Last frame as received (full resolution), kept to re-measure noise when the selection changes.
    fileprivate var lastFrame: SourceFrame?
    fileprivate var noiseDirty = false
    /// Highest and lowest point of the waveform trace, in signal units (1.0 = 100%). Updated a frame after the picture.
    fileprivate(set) var peaks: (max: Float, min: Float)?

    fileprivate var frameTex: MTLTexture?     // RGBA16F, downscaled source
    fileprivate var accWave: MTLTexture?      // frame width x waveHeight: one accumulator column per frame column
    fileprivate var accStops: MTLTexture?     // same shape as accWave, exposure in stops
    fileprivate let accVecWide: MTLTexture    // vecSize*vecSpread squared, scatter target
    fileprivate let accVec: MTLTexture        // vecSize squared, resolved
    fileprivate var scatterDirty = false
    /// The vectorscope accumulators still hold the dropped picture's trace: zero them before the next draw.
    fileprivate var vecNeedsClear = false
    /// The last frame must be decoded again (the LUT changed), even if the source sends nothing new.
    fileprivate var redecode = false

    fileprivate init(name: String, accVecWide: MTLTexture, accVec: MTLTexture) {
        self.name = name
        self.accVecWide = accVecWide
        self.accVec = accVec
    }

    /// Drops the current picture (e.g. when a snapshot is closed).
    func clear() {
        mark = nil
        source = nil
        selection = nil
        probe = nil
        dropPicture()
    }

    /// Forgets the frame and everything measured on it; the selection, mark, probe and points stay.
    private func dropPicture() {
        holdReset = true
        frameTex = nil
        accWave = nil
        peaks = nil
        lastFrame = nil
        noise = nil
        readout = nil
        accStops = nil
        pointValues = Array(repeating: nil, count: ScopeTarget.maxCount)
        vecNeedsClear = true
    }
}

/// Where each panel was drawn, in drawable pixels (origin top-left). Used to place labels and route mouse input.
struct ChannelLayout: Equatable {
    var pictureCard = CGRect.zero   // the picture's card (title row + picture area)
    var pictureArea = CGRect.zero   // where the picture is fitted, inside the card
    var picture = CGRect.zero       // the picture itself, aspect-fitted inside pictureArea
    var waveform = CGRect.zero
    var vectorscope = CGRect.zero
    var waveCard = CGRect.zero      // the cards holding them (zero when the panel is hidden)
    var vecCard = CGRect.zero
}

struct PanelLayout: Equatable {
    var live = ChannelLayout()
    var snapshot = ChannelLayout()
    var falseColor = CGRect.zero          // the whole panel
    var falseColorLegend = CGRect.zero
    var falseColorPicture = CGRect.zero   // aspect-fitted next to the legend
    var status = CGRect.zero              // top bar: wordmark and signal status
    var titleHeight: CGFloat = 0          // title row at the top of each card
    /// Single layout: the three HML vectorscopes (shadows, mids, highlights) and the stops display.
    var hml: [CGRect] = []
    var stops = CGRect.zero
    var hmlCard = CGRect.zero
    var stopsCard = CGRect.zero
    var falseColorCard = CGRect.zero
    var toolCard = CGRect.zero            // the last card (Single: tabbed tool slot)
    /// Every card's rectangle (drawn as rounded panels behind the content).
    var cards: [CGRect] = []
    var cardRadius: CGFloat = 0
    /// Bottom-row columns, full row height; the dividers between them can be dragged.
    /// Comparison: live waveform, reference waveform, live vectorscope, reference vectorscope, false colour.
    /// Single: waveform, vectorscope, HML, stops, false colour. Hidden panels are left out.
    var columns: [CGRect] = []
    /// For each column, its index in columnWeights (hidden panels keep their weight for when they come back).
    var columnSlots: [Int] = []
    /// Gap between columns, in drawable pixels.
    var columnGap: CGFloat = 0
}

/// Owns the GPU side: for each channel decode -> scatter (waveform, vectorscope), then one composite pass.
final class Renderer: NSObject, MTKViewDelegate {
    static let maxFrameWidth = 960          // the Umbra Link plugin's default Max width
    /// Waveform accumulator rows (its width follows the frame width). With the 5% margin above 100 and below 0,
    /// 1127 rows give 0-100 at least 1024 rows: one per 10-bit code value.
    static let waveHeight = 1127
    static let vecSize = 512
    static let vecScale: Float = 1.8        // |CbCr| = 0.5 lands at 90% of the panel radius at 100% zoom
    static let vecZoomRange: ClosedRange<Float> = 1...16
    /// Debug override through SCOPES_SPREAD; anything unparsable falls back to 4, and it is kept within 1…8.
    static let vecSpread = min(8, max(1, ProcessInfo.processInfo.environment["SCOPES_SPREAD"].flatMap { Int($0) } ?? 4))

    let device: MTLDevice
    private let queue: MTLCommandQueue

    private let decodePipeline: MTLRenderPipelineState
    private let scatterPipeline: MTLRenderPipelineState
    private let resolvePipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let peaksPipeline: MTLComputePipelineState
    private let envelopePipeline: MTLComputePipelineState
    /// Waveform: min/max curve per column for this frame (instantaneous envelope).
    var showEnvelope = false { didSet { channels.forEach { $0.scatterDirty = true } } }
    /// Waveform: min/max per column held across frames until reset (peak hold).
    var peakHold = false { didSet { if peakHold != oldValue { resetPeakHold() } } }
    /// Every measured point of both pictures (Source first), with its current value.
    var targets: [ScopeTarget] {
        [live, snapshot].flatMap { ch -> [ScopeTarget] in
            guard ch.hasFrame else { return [] }
            return (0..<ScopeTarget.maxCount).compactMap { i in
                guard let p = ch.points[i], let v = ch.pointValues[i] else { return nil }
                return ScopeTarget(r: v.r, g: v.g, b: v.b, slot: i, fromReference: ch === snapshot, point: p)
            }
        }
    }
    /// Points for the shaders, two float4 each: R, G, B and the luma exposure in stops on the current stops curve;
    /// then the pair (0…3) and 1 for a Reference point.
    private var targetData: [SIMD4<Float>] {
        targets.flatMap { t -> [SIMD4<Float>] in
            let tr = stopsTransfer
            let lin = 0.2126 * tr.toLinear(t.r) + 0.7152 * tr.toLinear(t.g) + 0.0722 * tr.toLinear(t.b)
            return [SIMD4(Float(t.r), Float(t.g), Float(t.b), Float(lin > 1e-6 ? log2(lin / 0.18) : -20)),
                    SIMD4(Float(t.slot), t.fromReference ? 1 : 0, 0, 0)]
        }
    }
    /// Starts the peak hold over from the next frame of every picture.
    func resetPeakHold() { channels.forEach { $0.holdReset = true; $0.scatterDirty = true } }
    private let meanPipeline: MTLComputePipelineState
    /// HML vectorscopes (live channel only): scatter targets and resolved bins, shadows / mids / highlights.
    static let hmlSize = 256
    static let hmlZones: [SIMD2<Float>] = [SIMD2(-1, 0.33), SIMD2(0.33, 0.66), SIMD2(0.66, 2)]
    private let hmlWide: [MTLTexture]
    private let hml: [MTLTexture]
    private let noisePipeline: MTLComputePipelineState

    let live: ScopeChannel
    let snapshot: ScopeChannel
    var channels: [ScopeChannel] { [live, snapshot] }

    var gainScale: Float = 1.0
    private let baseGain: (wave: Float, vec: Float) = (0.35, 0.06)
    var waveMode = WaveformMode.color { didSet { channels.forEach { $0.scatterDirty = true } } }
    var ditherMode = DitherMode.tenBit { didSet { channels.forEach { $0.scatterDirty = true } } }
    /// False Color shows the snapshot instead of the live signal.
    /// Comparison layout: the tool slot (HML, Stops, False Color) analyses the Reference instead of the Source.
    var toolShowsSnapshot = false { didSet { channels.forEach { $0.scatterDirty = true } } }
    var toolChannel: ScopeChannel { toolShowsSnapshot && layoutMode == .comparison ? snapshot : live }
    /// Called on the main queue when a channel's peaks change (to update the value labels).
    var onPeaks: (() -> Void)?
    /// Picture panels show the image or its noise.
    var noiseView = NoiseView.off
    /// The noise meter is on screen; without it the full-resolution noise passes are wasted work.
    var noiseMeterShown = false { didSet { if noiseMeterShown { channels.forEach { $0.noiseDirty = true } } } }
    /// Stops display input curve.
    var stopsTransfer = StopsTransfer.rec709 { didSet { channels.forEach { $0.scatterDirty = true } } }
    /// Pictures keep only skin tones in colour.
    var skinIsolation = false
    /// Vectorscopes show the signal at 2x (like DaVinci Resolve's "Show 2x Zoom").
    var vecDouble = false { didSet { channels.forEach { $0.vecBoost = vecDouble ? 2 : 1 } } }
    /// Single layout: the Reference shows right of a vertical line over the Source picture.
    var wipeEnabled = false
    var wipePosition: Double = 0.5

    private(set) var layout = PanelLayout()
    var layoutMode = LayoutMode.comparison {
        didSet { if layoutMode != oldValue { channels.forEach { $0.scatterDirty = true }; live.redecode = true } }
    }
    /// LUT chosen in the LUT panel; applied to the Source in the Single layout when `lutEnabled`, before every scope.
    var lut: GPULUT? { didSet { live.redecode = true; live.holdReset = true } }
    var lutEnabled = true { didSet { live.redecode = true } }
    /// Whether the Source picture and its scopes currently go through the LUT.
    var lutActive: Bool { lut != nil && lutEnabled && layoutMode == .single }
    /// Points reserved left of the Source picture for the LUT panel (Single layout); 0 = none.
    var lutPanelWidth: Double = 0
    private lazy var dummyShaper: MTLTexture? = {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        return device.makeTexture(descriptor: d)
    }()
    private lazy var dummyCube: MTLTexture? = {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba16Float
        d.usage = .shaderRead
        return device.makeTexture(descriptor: d)
    }()
    /// Points reserved under the Source picture for the player bar (video files); 0 = none.
    var playerBarHeight: Double = 0
    /// Bottom-row panels switched off; the remaining ones share the row (and with none, the picture takes it).
    var hiddenPanels: Set<ScopePanel> = [] { didSet { channels.forEach { $0.scatterDirty = true } } }
    func isShown(_ p: ScopePanel) -> Bool { !hiddenPanels.contains(p) && !p.slots(in: layoutMode).isEmpty }
    /// The panel filling the whole window (Cmd+F), nil for the normal layout. Not persisted.
    var zoomedPanel: ZoomTarget?
    /// The tab shown in the tool slot (only that one is computed).
    var toolTab = ToolTab.hml { didSet { channels.forEach { $0.scatterDirty = true } } }
    private func toolShown(_ t: ToolTab) -> Bool { isShown(.tools) && toolTab == t }
    /// Weight slots of the visible columns, left to right.
    var visibleSlots: [Int] { ScopePanel.allCases.filter(isShown).flatMap { $0.slots(in: layoutMode) } }
    /// Column widths are kept per layout, so switching back restores what you set.
    private var weightsByMode: [LayoutMode: [Double]] = Dictionary(uniqueKeysWithValues: LayoutMode.allCases.map { ($0, $0.defaultWeights) })
    /// Relative widths of the current layout's bottom-row columns (see PanelLayout.columns).
    var columnWeights: [Double] {
        get { weightsByMode[layoutMode] ?? layoutMode.defaultWeights }
        set { weightsByMode[layoutMode] = newValue }
    }
    func setColumnWeights(_ w: [Double], for mode: LayoutMode) { weightsByMode[mode] = w }
    var onLayout: ((PanelLayout) -> Void)?

    // Stats / capture
    private var statFrames = 0
    private var statNewFrames = 0
    private var statGPUTime: Double = 0
    private var statStart = CACurrentMediaTime()
    private var pendingCapture: (url: URL, overlay: [CaptureText])?
    var onStats: ((String) -> Void)?

    /// Text drawn on top of a window capture, since the labels are AppKit views and not part of the drawable.
    struct CaptureText {
        var string: NSAttributedString
        var rect: CGRect         // drawable pixels, origin top-left; text is cut in the middle if it doesn't fit
        var background: NSColor? = nil
    }

    init(view: MTKView) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "Scopes", code: 1, userInfo: [NSLocalizedDescriptionKey: "No Metal device"])
        }
        self.device = device
        self.queue = queue
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false           // allows reading back the drawable for screenshots
        view.clearColor = MTLClearColor(red: 0.145, green: 0.141, blue: 0.125, alpha: 1)   // #252420
        view.preferredFramesPerSecond = 60

        // No offline Metal toolchain is required: shaders are compiled from the bundled source.
        guard let shaderURL = Bundle.main.url(forResource: "Scopes", withExtension: "metal") else {
            throw NSError(domain: "Scopes", code: 2, userInfo: [NSLocalizedDescriptionKey: "Scopes.metal not in bundle"])
        }
        let library = try device.makeLibrary(source: String(contentsOf: shaderURL, encoding: .utf8), options: nil)

        func pipeline(_ vs: String, _ fs: String, _ format: MTLPixelFormat, additive: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vs)
            d.fragmentFunction = library.makeFunction(name: fs)
            d.colorAttachments[0].pixelFormat = format
            if additive {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add
                a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = .one
                a.destinationRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .one
                a.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        decodePipeline = try pipeline("fullscreen_vertex", "decode_fragment", .rgba16Float, additive: false)
        // Float32 accumulation so tens of thousands of hits per pixel don't saturate half-float precision.
        scatterPipeline = try pipeline("scatter_vertex", "scatter_fragment", .rgba32Float, additive: true)
        resolvePipeline = try pipeline("fullscreen_vertex", "resolve_fragment", .rgba32Float, additive: false)
        compositePipeline = try pipeline("fullscreen_vertex", "composite_fragment", view.colorPixelFormat, additive: false)
        peaksPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "peaks")!)
        envelopePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "wave_envelope")!)
        meanPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "area_mean")!)
        noisePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "noise_stats")!)

        func accumulator(_ w: Int, _ h: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        let wide = Self.vecSize * Self.vecSpread
        live = ScopeChannel(name: "Source Signal", accVecWide: accumulator(wide, wide), accVec: accumulator(Self.vecSize, Self.vecSize))
        snapshot = ScopeChannel(name: "Snapshot", accVecWide: accumulator(wide, wide), accVec: accumulator(Self.vecSize, Self.vecSize))
        hmlWide = (0..<3).map { _ in accumulator(Self.hmlSize * Self.vecSpread, Self.hmlSize * Self.vecSpread) }
        hml = (0..<3).map { _ in accumulator(Self.hmlSize, Self.hmlSize) }
        super.init()
        // New private textures hold whatever was in memory: clear the vectorscope accumulators so an empty
        // channel shows an empty scope.
        if let cmd = queue.makeCommandBuffer() {
            for tex in [live.accVecWide, live.accVec, snapshot.accVecWide, snapshot.accVec] + hmlWide + hml {
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = tex
                rp.colorAttachments[0].loadAction = .clear
                rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                rp.colorAttachments[0].storeAction = .store
                cmd.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
            }
            cmd.commit()
        }
    }

    func requestCapture(to url: URL, overlay: [CaptureText] = []) { pendingCapture = (url, overlay) }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let cmd = queue.makeCommandBuffer() else { return }
        statFrames += 1
        // Core Video textures read by this command buffer must outlive it, or their pixel buffers get recycled
        // while the GPU is still decoding them.
        var retained: [AnyObject] = []

        for ch in channels {
            if ch.vecNeedsClear {
                ch.vecNeedsClear = false
                for tex in [ch.accVecWide, ch.accVec] {
                    let rp = MTLRenderPassDescriptor()
                    rp.colorAttachments[0].texture = tex
                    rp.colorAttachments[0].loadAction = .clear
                    rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                    rp.colorAttachments[0].storeAction = .store
                    cmd.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
                }
            }
            // 1. decode a new source frame into the channel's RGBA16F frame texture
            if let f = ch.source?.nextFrame() {
                if let r = f.retain { retained.append(r) }
                if ch === live { statNewFrames += 1 }
                ch.frameInfo = f.info
                ch.scatterDirty = true
                ensureFrameTexture(ch, srcWidth: f.texture.width, srcHeight: f.texture.height)
                decode(cmd, frame: f, into: ch.frameTex!, lut: ch === live)
                ch.lastFrame = f
                ch.noiseDirty = true
                ch.readoutDirty = true
                ch.redecode = false
            } else if ch.redecode, let f = ch.lastFrame, let target = ch.frameTex {
                // Paused or still picture: apply the new LUT to the frame already received.
                ch.redecode = false
                if let r = f.retain { retained.append(r) }
                decode(cmd, frame: f, into: target, lut: ch === live)
                ch.scatterDirty = true
                ch.readoutDirty = true
            }
            if noiseMeterShown, ch.noiseDirty, let f = ch.lastFrame {
                ch.noiseDirty = false
                if let r = f.retain { retained.append(r) }
                computeNoise(cmd, ch, frame: f)
            }
            // 2. scatter: one point per sample into each accumulator (only when the picture or the scale
            //    changed; gain is applied at composite time, so a still snapshot is scattered once)
            if let frame = ch.frameTex, let accWave = ch.accWave, ch.scatterDirty {
                ch.scatterDirty = false
                scatter(cmd, frame: frame, into: accWave, mode: 0, instances: waveMode == .rgb ? 3 : 1, vecZoom: ch.vecView,
                        selection: ch.selection)
                scatter(cmd, frame: frame, into: ch.accVecWide, mode: 2, instances: 1, vecZoom: ch.vecView,
                        selection: ch.selection)
                resolveVectorscope(cmd, ch)
                computePeaks(cmd, ch, frame: frame)
                if showEnvelope || peakHold { computeEnvelope(cmd, ch, frame: frame) }
                if ch === toolChannel {
                    if let accStops = ch.accStops, toolShown(.stops) {
                        scatter(cmd, frame: frame, into: accStops, mode: 3, instances: 1, vecZoom: 1, selection: ch.selection)
                    }
                    for (i, zone) in Self.hmlZones.enumerated() where toolShown(.hml) {
                        scatter(cmd, frame: frame, into: hmlWide[i], mode: 2, instances: 1, vecZoom: 1, selection: ch.selection,
                                vecBins: Self.hmlSize, lumaRange: zone)
                        resolve(cmd, wide: hmlWide[i], into: hml[i])
                    }
                }
            }
            if ch.readoutDirty, let frame = ch.frameTex {
                ch.readoutDirty = false
                ch.pointsDirty = true   // the same events (new frame, redecode) move every point's value
                computeMean(cmd, ch, frame: frame)
            }
            if ch.pointsDirty, let frame = ch.frameTex {
                ch.pointsDirty = false
                computePoints(cmd, ch, frame: frame)
            }
        }

        if !retained.isEmpty { cmd.addCompletedHandler { _ in withExtendedLifetime(retained) {} } }

        // 3. composite panels onto the drawable
        guard let drawable = view.currentDrawable, let rp = view.currentRenderPassDescriptor else {
            cmd.commit(); return
        }
        rp.colorAttachments[0].loadAction = .clear
        let scale = view.window?.backingScaleFactor ?? 2
        var newLayout = computeLayout(width: Double(drawable.texture.width), height: Double(drawable.texture.height), scale: scale)
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
            enc.label = "composite"
            enc.setRenderPipelineState(compositePipeline)
            // env, hold and targets are only read when a panel sets them, but Metal validation wants every buffer
            // argument bound for every draw.
            var placeholder = SIMD4<Float>(repeating: 0)
            for i in 1...3 { enc.setFragmentBytes(&placeholder, length: MemoryLayout<SIMD4<Float>>.stride, index: i) }
            // Cards first; the content of each panel is drawn inside them.
            for card in newLayout.cards {
                panel(enc, tex: live.accVec, kind: 6, gain: 0, rect: card,
                      cardSize: SIMD2(Float(card.width.rounded()), Float(card.height.rounded())), cardRadius: Float(newLayout.cardRadius))
            }
            for (ch, isLive) in [(live, true), (snapshot, false)] where isLive || layoutMode == .comparison {
                var l = isLive ? newLayout.live : newLayout.snapshot
                if let frame = ch.frameTex {
                    l.picture = fit(l.pictureArea, aspect: Double(frame.width) / Double(frame.height))
                    let wipe: Float = isLive && layoutMode == .single && wipeEnabled && snapshot.hasFrame ? Float(wipePosition) : -1
                    panel(enc, tex: frame, kind: 0, gain: 0, rect: l.picture, selection: ch.selection, noiseView: noiseView,
                          refTex: snapshot.frameTex, skin: skinIsolation, wipe: wipe, mark: ch.mark.map { ($0.kind, $0.bounds) })
                }
                // A selection stretches fewer samples over the same waveform width and vectorscope: raise the gain
                // so the traces keep their brightness.
                let selWidth = Float(ch.selection?.rect.width ?? 1), selArea = ch.selection?.area ?? 1
                if let accWave = ch.accWave {
                    panel(enc, tex: accWave, kind: 1, gain: baseGain.wave * gainScale / max(selWidth, 0.02), rect: l.waveform,
                          peaks: ch.peaks, envelope: ch, mark: markOutline(ch, on: .waveform), showTargets: true)
                }
                // Zooming spreads the same samples over more bins; scale the gain so the trace keeps its brightness.
                panel(enc, tex: ch.accVec, kind: 3, gain: baseGain.vec * gainScale * ch.vecView / max(selArea.squareRoot(), 0.05),
                      rect: l.vectorscope, vecScale: Self.vecScale * ch.vecZoom, vecSignal: ch.vecBoost, mark: markOutline(ch, on: .vectorscope),
                      showTargets: true)
                if isLive { newLayout.live = l } else { newLayout.snapshot = l }
            }
            if toolChannel.hasFrame {
                // HML zones hold fewer samples each, in a coarser grid: similar overall brightness to the main scope.
                for (i, r) in newLayout.hml.enumerated() {
                    panel(enc, tex: hml[i], kind: 3, gain: baseGain.vec * gainScale * 0.75, rect: r)
                }
                if let accStops = toolChannel.accStops {
                    panel(enc, tex: accStops, kind: 7, gain: baseGain.wave * gainScale, rect: newLayout.stops, showTargets: true)
                }
            }
            if let frame = toolChannel.frameTex, !newLayout.falseColor.isEmpty {
                let legend = newLayout.falseColorLegend
                let area = CGRect(x: legend.maxX + legend.width * 0.6, y: newLayout.falseColor.minY,
                                  width: newLayout.falseColor.maxX - legend.maxX - legend.width * 0.6,
                                  height: newLayout.falseColor.height)
                newLayout.falseColorPicture = fit(area, aspect: Double(frame.width) / Double(frame.height))
                panel(enc, tex: frame, kind: 4, gain: 0, rect: newLayout.falseColorPicture)
            }
            panel(enc, tex: live.accVec, kind: 5, gain: 0, rect: newLayout.falseColorLegend)
            enc.endEncoding()
        }
        if newLayout != layout {
            layout = newLayout
            onLayout?(newLayout)
        }

        if let c = pendingCapture {
            pendingCapture = nil
            enqueueCapture(cmd, texture: drawable.texture, url: c.url, overlay: c.overlay)
        }

        cmd.addCompletedHandler { [weak self] cb in
            let dt = cb.gpuEndTime - cb.gpuStartTime
            DispatchQueue.main.async { self?.statGPUTime += dt }
        }
        cmd.present(drawable)
        cmd.commit()
        reportStats()
    }

    /// Top bar, then a row of picture cards (Source | Reference, or Source alone), then a row of scope cards
    /// whose widths follow `columnWeights`. Each card has a title row and its content inset below it.
    private func computeLayout(width W: Double, height H: Double, scale: Double) -> PanelLayout {
        let pad = 14.0 * scale, gap = 12.0 * scale, header = 44.0 * scale
        let titleRow = 30.0 * scale, inner = 12.0 * scale, gutter = 26.0 * scale
        var l = PanelLayout()
        l.titleHeight = titleRow
        l.cardRadius = 14.0 * scale
        l.status = CGRect(x: pad, y: 0, width: W - pad * 2, height: header)

        let y0 = header, usableH = H - header - pad
        let slots = visibleSlots
        // With every scope hidden the picture takes the whole height.
        let topH = slots.isEmpty ? usableH : (usableH - gap) * 0.5, bottomH = usableH - gap - topH
        func content(_ card: CGRect, left: Double = 0) -> CGRect {
            CGRect(x: card.minX + inner + left, y: card.minY + titleRow,
                   width: max(0, card.width - inner * 2 - left), height: max(0, card.height - titleRow - inner))
        }
        let single = layoutMode == .single
        // Cmd+F: the zoomed panel's card takes everything below the header, the other cards are left out.
        let full = CGRect(x: pad, y: y0, width: W - pad * 2, height: usableH)
        let zoom = zoomedPanel
        if single {
            l.live.pictureCard = CGRect(x: pad, y: y0, width: W - pad * 2, height: topH)
        } else {
            let w = (W - pad * 2 - gap) / 2
            l.live.pictureCard = CGRect(x: pad, y: y0, width: w, height: topH)
            l.snapshot.pictureCard = CGRect(x: pad + w + gap, y: y0, width: w, height: topH)
        }
        if let z = zoom {
            l.live.pictureCard = z == .livePicture ? full : .zero
            l.snapshot.pictureCard = z == .snapPicture && !single ? full : .zero
        }
        l.live.pictureArea = l.live.pictureCard.isEmpty ? .zero : content(l.live.pictureCard)
        // LUT panel left of the Source picture (Single), inside its card.
        if single && lutPanelWidth > 0 && !l.live.pictureArea.isEmpty {
            let w = (lutPanelWidth + 12) * scale
            l.live.pictureArea.origin.x += w
            l.live.pictureArea.size.width = max(0, l.live.pictureArea.width - w)
        }
        // Player bar under the Source picture, inside its card.
        let bar = playerBarHeight * scale
        if bar > 0 && !l.live.pictureArea.isEmpty { l.live.pictureArea.size.height = max(0, l.live.pictureArea.height - bar - 6 * scale) }
        l.snapshot.pictureArea = single || l.snapshot.pictureCard.isEmpty ? .zero : content(l.snapshot.pictureCard)

        // Visible scope cards share the row width in proportion to their weights (dragging a divider changes them).
        let rowY = y0 + topH + gap
        let weights = slots.map { columnWeights[$0] }
        let avail = max(0, W - pad * 2 - gap * Double(max(weights.count - 1, 0)))
        let total = max(weights.reduce(0, +), 1e-9)
        var x = pad
        l.columnGap = gap
        l.columnSlots = slots
        l.columns = weights.map { w in
            let width = avail * w / total
            defer { x += width + gap }
            return CGRect(x: x, y: rowY, width: width, height: bottomH)
        }
        let card = { (slot: Int) -> CGRect in
            if let z = zoom { return z.slot(in: self.layoutMode) == slot ? full : .zero }
            return slots.firstIndex(of: slot).map { l.columns[$0] } ?? .zero
        }
        // Vectorscopes stay square: the largest square that fits in the card's content, centred.
        func square(_ card: CGRect) -> CGRect {
            guard !card.isEmpty else { return .zero }
            let r = content(card), side = max(0, min(r.width, r.height))
            return CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
        }
        func waveContent(_ card: CGRect) -> CGRect { card.isEmpty ? .zero : content(card, left: gutter) }
        if single {
            l.live.waveCard = card(0)
            l.live.vecCard = card(1)
            l.toolCard = card(2)
        } else {
            l.live.waveCard = card(0)
            l.snapshot.waveCard = card(1)
            l.live.vecCard = card(2)
            l.snapshot.vecCard = card(3)
            l.toolCard = card(4)
        }
        // The tool slot shows one tab at a time.
        switch toolTab {
        case .hml: l.hmlCard = l.toolCard
        case .stops: l.stopsCard = l.toolCard
        case .falseColor: l.falseColorCard = l.toolCard
        }
        do {
            if !l.hmlCard.isEmpty {
                // HML: three squares side by side, with room for their zone names underneath.
                let h = content(l.hmlCard), gapS = 8.0 * scale, labelH = 18.0 * scale
                let side = max(0, min((h.width - gapS * 2) / 3, h.height - labelH))
                let x0 = h.midX - (side * 3 + gapS * 2) / 2, y = h.midY - (side + labelH) / 2
                l.hml = (0..<3).map { CGRect(x: x0 + Double($0) * (side + gapS), y: y, width: side, height: side) }
            }
            l.stops = waveContent(l.stopsCard)
        }
        for i in 0..<2 {
            var cl = i == 0 ? l.live : l.snapshot
            cl.waveform = waveContent(cl.waveCard)
            cl.vectorscope = square(cl.vecCard)
            if i == 0 { l.live = cl } else { l.snapshot = cl }
        }
        l.falseColor = l.falseColorCard.isEmpty ? .zero : content(l.falseColorCard)
        let fc = l.falseColor
        if !fc.isEmpty {
            let legendW = 8.0 * scale, legendH = min(fc.height, fc.width) * 0.8
            l.falseColorLegend = CGRect(x: fc.minX + 22.0 * scale, y: fc.midY - legendH / 2, width: legendW, height: legendH)
        }
        l.cards = (single ? [l.live.pictureCard] : [l.live.pictureCard, l.snapshot.pictureCard]) + l.columns
        if zoom != nil {
            l.cards = [full]
            l.columns = []
            l.columnSlots = []
        }
        return l
    }

    // MARK: - passes

    private func decode(_ cmd: MTLCommandBuffer, frame f: SourceFrame, into target: MTLTexture, lut applyLUT: Bool = false) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.label = "decode"
        enc.setRenderPipelineState(decodePipeline)
        var u = DecodeUniforms(swapRB: f.swapRB ? 1 : 0, videoRange: f.videoRange ? 1 : 0, flipY: f.flipY ? 1 : 0)
        var shaper = dummyShaper, cube = dummyCube
        if applyLUT, lutActive, let l = lut {
            if let t = l.shaper {
                u.lutMode |= 1; shaper = t
                u.shaperRange = l.data.shaperRange; u.shaperSize = Float(l.data.shaper.count)
            }
            if let t = l.cube {
                u.lutMode |= 2; cube = t
                u.cubeRange = l.data.cubeRange; u.cubeSize = Float(l.data.cubeSize)
            }
        }
        enc.setFragmentBytes(&u, length: MemoryLayout<DecodeUniforms>.stride, index: 0)
        enc.setFragmentTexture(f.texture, index: 0)
        enc.setFragmentTexture(shaper, index: 1)
        enc.setFragmentTexture(cube, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func scatter(_ cmd: MTLCommandBuffer, frame: MTLTexture, into acc: MTLTexture, mode: UInt32, instances: Int,
                         vecZoom: Float, selection: Selection?, vecBins: Int = Renderer.vecSize,
                         lumaRange: SIMD2<Float> = SIMD2(-1, 2)) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = acc
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.label = "scatter \(mode)"
        enc.setRenderPipelineState(scatterPipeline)
        var u = ScatterUniforms(frameSize: SIMD2(UInt32(frame.width), UInt32(frame.height)), mode: mode,
                                vecScale: Self.vecScale * vecZoom, vecBins: UInt32(vecBins),
                                vecSpread: UInt32(Self.vecSpread), waveMode: waveMode.rawValue,
                                roiShape: selection?.shape.rawValue ?? 0, roi: selection?.uniform ?? SIMD4(0, 0, 1, 1),
                                ditherRGB: ditherMode.steps.rgb, ditherChroma: ditherMode.steps.chroma,
                                lumaRange: lumaRange, transfer: stopsTransfer.rawValue)
        enc.setVertexBytes(&u, length: MemoryLayout<ScatterUniforms>.stride, index: 0)
        enc.setVertexTexture(frame, index: 0)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: frame.width * frame.height, instanceCount: instances)
        enc.endEncoding()
    }

    private func resolveVectorscope(_ cmd: MTLCommandBuffer, _ ch: ScopeChannel) {
        resolve(cmd, wide: ch.accVecWide, into: ch.accVec)
    }

    private func resolve(_ cmd: MTLCommandBuffer, wide: MTLTexture, into out: MTLTexture) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = out
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.label = "resolve vectorscope"
        enc.setRenderPipelineState(resolvePipeline)
        var k = UInt32(Self.vecSpread)
        enc.setFragmentBytes(&k, length: 4, index: 0)
        enc.setFragmentTexture(wide, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Mean colour inside the selection, or in a 5x5 px square at the probe; read when the command buffer completes.
    /// Mean of a 5×5 px square at each of a channel's points.
    private func computePoints(_ cmd: MTLCommandBuffer, _ ch: ScopeChannel, frame: MTLTexture) {
        let points = ch.points
        guard points.contains(where: { $0 != nil }) else {
            ch.pointValues = Array(repeating: nil, count: ScopeTarget.maxCount)
            return
        }
        guard let buf = device.makeBuffer(length: 16 * points.count, options: .storageModeShared) else { return }
        memset(buf.contents(), 0, buf.length)
        for (i, p) in points.enumerated() {
            guard let p, let enc = cmd.makeComputeCommandEncoder() else { continue }
            let hw = Float(2.5 / Double(frame.width)), hh = Float(2.5 / Double(frame.height))
            var args = MeanArgs(roiShape: 1, roi: SIMD4(Float(p.x) - hw, Float(p.y) - hh, hw * 2, hh * 2))
            enc.setComputePipelineState(meanPipeline)
            enc.setTexture(frame, index: 0)
            enc.setBuffer(buf, offset: 16 * i, index: 0)
            enc.setBytes(&args, length: MemoryLayout<MeanArgs>.stride, index: 1)
            enc.dispatchThreads(MTLSize(width: frame.width, height: frame.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
            enc.endEncoding()
        }
        cmd.addCompletedHandler { [weak self, weak ch] _ in
            let v = buf.contents().bindMemory(to: Float.self, capacity: 4 * points.count)
            let values: [Readout?] = points.indices.map { i in
                let n = Double(v[i * 4 + 3])
                guard points[i] != nil, n > 0 else { return nil }
                return Readout(r: Double(v[i * 4]) / n, g: Double(v[i * 4 + 1]) / n, b: Double(v[i * 4 + 2]) / n,
                               pixels: Int(n), isSelection: false)
            }
            DispatchQueue.main.async {
                ch?.pointValues = values
                self?.onPeaks?()
            }
        }
    }

    private func computeMean(_ cmd: MTLCommandBuffer, _ ch: ScopeChannel, frame: MTLTexture) {
        let roi: SIMD4<Float>, shape: UInt32
        if let sel = ch.selection {
            roi = sel.uniform; shape = sel.shape.rawValue
        } else if let p = ch.probe {
            let hw = Float(2.5 / Double(frame.width)), hh = Float(2.5 / Double(frame.height))
            roi = SIMD4(Float(p.x) - hw, Float(p.y) - hh, hw * 2, hh * 2); shape = 1
        } else {
            DispatchQueue.main.async { [weak self, weak ch] in ch?.readout = nil; self?.onPeaks?() }
            return
        }
        guard let buf = device.makeBuffer(length: 16, options: .storageModeShared),
              let enc = cmd.makeComputeCommandEncoder() else { return }
        memset(buf.contents(), 0, 16)
        var args = MeanArgs(roiShape: shape, roi: roi)
        enc.setComputePipelineState(meanPipeline)
        enc.setTexture(frame, index: 0)
        enc.setBuffer(buf, offset: 0, index: 0)
        enc.setBytes(&args, length: MemoryLayout<MeanArgs>.stride, index: 1)
        enc.dispatchThreads(MTLSize(width: frame.width, height: frame.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
        enc.endEncoding()
        let isSelection = ch.selection != nil
        cmd.addCompletedHandler { [weak self, weak ch] _ in
            let v = buf.contents().bindMemory(to: Float.self, capacity: 4)
            let n = Double(v[3])
            let result = n > 0 ? Readout(r: Double(v[0]) / n, g: Double(v[1]) / n, b: Double(v[2]) / n, pixels: Int(n),
                                         isSelection: isSelection) : nil
            DispatchQueue.main.async {
                ch?.readout = result
                self?.onPeaks?()
            }
        }
    }

    /// Noise statistics of the received frame inside the selection; read when the command buffer completes.
    private func computeNoise(_ cmd: MTLCommandBuffer, _ ch: ScopeChannel, frame f: SourceFrame) {
        guard let buf = device.makeBuffer(length: 11 * 4, options: .storageModeShared),
              let enc = cmd.makeComputeCommandEncoder() else { return }
        memset(buf.contents(), 0, 11 * 4)
        var args = NoiseArgs(swapRB: f.swapRB ? 1 : 0, videoRange: f.videoRange ? 1 : 0, flipY: f.flipY ? 1 : 0,
                             roiShape: ch.selection?.shape.rawValue ?? 0, roi: ch.selection?.uniform ?? SIMD4(0, 0, 1, 1))
        enc.setComputePipelineState(noisePipeline)
        enc.setTexture(f.texture, index: 0)
        enc.setBuffer(buf, offset: 0, index: 0)
        enc.setBytes(&args, length: MemoryLayout<NoiseArgs>.stride, index: 1)
        enc.dispatchThreads(MTLSize(width: f.texture.width, height: f.texture.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
        enc.endEncoding()
        let w = f.texture.width, h = f.texture.height
        cmd.addCompletedHandler { [weak self, weak ch] _ in
            let v = buf.contents().bindMemory(to: Float.self, capacity: 11)
            let n = v[0]
            guard n > 0 else { return }
            // var(residual) = 8/9 var(noise) for white noise; undo it.
            let sigma = { (sumSq: Float) in (sumSq / n * 9 / 8).squareRoot() }
            let stats = NoiseStats(pixels: Int(n), width: w, height: h, meanY: v[1] / n,
                                   sigmaY: sigma(v[5]), sigmaCb: sigma(v[6]), sigmaCr: sigma(v[7]),
                                   sigmaR: sigma(v[8]), sigmaG: sigma(v[9]), sigmaB: sigma(v[10]))
            DispatchQueue.main.async {
                ch?.noise = stats
                self?.onPeaks?()
            }
        }
    }

    /// Reduces the frame to its waveform max/min on the GPU; the result is read when the command buffer completes.
    // MARK: - scope marks (scope region -> pixels)

    /// Panel uv (x0, x1, y0, y1; y down) of a channel's mark on one of its scopes, or nil if the mark is on the other.
    private func markOutline(_ ch: ScopeChannel, on kind: ScopeMark.Kind) -> (ScopeMark.Kind, SIMD4<Float>)? {
        guard let m = ch.mark, m.kind == kind else { return nil }
        let b = m.bounds
        switch kind {
        case .waveform:
            let roi = ch.selection?.uniform ?? SIMD4(0, 0, 1, 1)
            let x = { (fx: Float) in (fx - roi.x) / max(roi.z, 1e-6) }
            let y = { (v: Float) in 1 - (v + 0.05) / 1.1 }
            return (kind, SIMD4(x(b.x), x(b.y), y(b.w), y(b.z)))
        case .vectorscope:
            let s = Self.vecScale * ch.vecView
            return (kind, SIMD4((b.x * s + 1) / 2, (b.y * s + 1) / 2, (1 - b.w * s) / 2, (1 - b.z * s) / 2))
        }
    }

    /// Signal-space mark from a rectangle dragged on a scope panel (panel uv, y down).
    func scopeMark(_ ch: ScopeChannel, kind: ScopeMark.Kind, panel r: CGRect) -> ScopeMark {
        let x0 = Float(r.minX), x1 = Float(r.maxX), y0 = Float(r.minY), y1 = Float(r.maxY)
        switch kind {
        case .waveform:
            let roi = ch.selection?.uniform ?? SIMD4(0, 0, 1, 1)
            let v = { (y: Float) in (1 - y) * 1.1 - 0.05 }
            return ScopeMark(kind: kind, bounds: SIMD4(roi.x + x0 * roi.z, roi.x + x1 * roi.z, v(y1), v(y0)))
        case .vectorscope:
            let s = Self.vecScale * ch.vecView
            return ScopeMark(kind: kind, bounds: SIMD4((x0 * 2 - 1) / s, (x1 * 2 - 1) / s, (1 - y1 * 2) / s, (1 - y0 * 2) / s))
        }
    }

    private func computeEnvelope(_ cmd: MTLCommandBuffer, _ ch: ScopeChannel, frame: MTLTexture) {
        let bytes = frame.width * 2 * MemoryLayout<SIMD4<Float>>.stride
        if ch.envBuf?.length != bytes {
            ch.envBuf = device.makeBuffer(length: bytes, options: .storageModePrivate)
            ch.holdBuf = device.makeBuffer(length: bytes, options: .storageModePrivate)
            ch.holdReset = true
        }
        guard let env = ch.envBuf, let hold = ch.holdBuf, let enc = cmd.makeComputeCommandEncoder() else { return }
        var args = EnvelopeArgs(roiShape: ch.selection?.shape.rawValue ?? 0, reset: ch.holdReset ? 1 : 0,
                                roi: ch.selection?.uniform ?? SIMD4(0, 0, 1, 1))
        ch.holdReset = false
        enc.setComputePipelineState(envelopePipeline)
        enc.setTexture(frame, index: 0)
        enc.setBuffer(env, offset: 0, index: 0)
        enc.setBuffer(hold, offset: 0, index: 1)
        enc.setBytes(&args, length: MemoryLayout<EnvelopeArgs>.stride, index: 2)
        enc.dispatchThreads(MTLSize(width: frame.width, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        enc.endEncoding()
    }

    private func computePeaks(_ cmd: MTLCommandBuffer, _ ch: ScopeChannel, frame: MTLTexture) {
        guard let buf = device.makeBuffer(length: 8, options: .storageModeShared),
              let enc = cmd.makeComputeCommandEncoder() else { return }
        let p = buf.contents().bindMemory(to: UInt32.self, capacity: 2)
        p[0] = 0; p[1] = .max
        var args = PeaksArgs(waveMode: waveMode.rawValue, roiShape: ch.selection?.shape.rawValue ?? 0,
                             roi: ch.selection?.uniform ?? SIMD4(0, 0, 1, 1))
        enc.setComputePipelineState(peaksPipeline)
        enc.setTexture(frame, index: 0)
        enc.setBuffer(buf, offset: 0, index: 0)
        enc.setBytes(&args, length: MemoryLayout<PeaksArgs>.stride, index: 1)
        enc.dispatchThreads(MTLSize(width: frame.width, height: frame.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
        enc.endEncoding()
        cmd.addCompletedHandler { [weak self, weak ch] _ in
            let p = buf.contents().bindMemory(to: UInt32.self, capacity: 2)   // keeps buf alive until here
            let decode = { (v: UInt32) in (Float(v) - 10000) / 10000 }
            let result = (max: decode(p[0]), min: decode(p[1]))
            DispatchQueue.main.async {
                ch?.peaks = result
                self?.onPeaks?()
            }
        }
    }

    private func panel(_ enc: MTLRenderCommandEncoder, tex: MTLTexture, kind: UInt32, gain: Float, rect: CGRect,
                       vecScale: Float = Renderer.vecScale, vecSignal: Float = 1, peaks: (max: Float, min: Float)? = nil, selection: Selection? = nil,
                       noiseView: NoiseView = .off, cardSize: SIMD2<Float> = .zero, cardRadius: Float = 0,
                       refTex: MTLTexture? = nil, skin: Bool = false, wipe: Float = -1, envelope: ScopeChannel? = nil,
                       mark: (ScopeMark.Kind, SIMD4<Float>)? = nil, showTargets: Bool = false) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        enc.setViewport(MTLViewport(originX: rect.minX.rounded(), originY: rect.minY.rounded(),
                                    width: rect.width.rounded(), height: rect.height.rounded(), znear: 0, zfar: 1))
        var u = PanelUniforms(kind: kind, gain: gain, vecScale: vecScale, waveMode: waveMode.rawValue,
                              peakMax: peaks?.max ?? -1, peakMin: peaks?.min ?? -1,
                              roiShape: selection?.shape.rawValue ?? 0, noiseView: noiseView.rawValue,
                              roi: selection?.uniform ?? SIMD4(0, 0, 1, 1), size: cardSize, radius: cardRadius,
                              skin: skin ? 1 : 0, wipe: wipe)
        u.vecSignal = vecSignal
        var targetBytes = targetData
        if showTargets, !targetBytes.isEmpty {
            u.targetCount = UInt32(targetBytes.count / 2)
            enc.setFragmentBytes(&targetBytes, length: MemoryLayout<SIMD4<Float>>.stride * targetBytes.count, index: 3)
        }
        if let (k, m) = mark {
            u.markKind = k.rawValue
            u.markRGB = waveMode == .rgb ? 1 : 0
            u.mark = m
        }
        if let ch = envelope, let env = ch.envBuf, let hold = ch.holdBuf, let frame = ch.frameTex,
           env.length == frame.width * 2 * MemoryLayout<SIMD4<Float>>.stride {
            u.envFlags = (showEnvelope ? 1 : 0) | (peakHold ? 2 : 0)
            u.envColumns = UInt32(frame.width)
            u.roi = ch.selection?.uniform ?? SIMD4(0, 0, 1, 1)
            enc.setFragmentBuffer(env, offset: 0, index: 1)
            enc.setFragmentBuffer(hold, offset: 0, index: 2)
        }
        enc.setFragmentBytes(&u, length: MemoryLayout<PanelUniforms>.stride, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentTexture(refTex ?? tex, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private func fit(_ r: CGRect, aspect: Double) -> CGRect {
        var w = r.width, h = r.width / aspect
        if h > r.height { h = r.height; w = h * aspect }
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    // MARK: - textures

    private func ensureFrameTexture(_ ch: ScopeChannel, srcWidth: Int, srcHeight: Int) {
        let w = min(Self.maxFrameWidth, srcWidth)
        let h = max(1, Int((Double(w) * Double(srcHeight) / Double(srcWidth)).rounded()))
        if let t = ch.frameTex, t.width == w, t.height == h { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        ch.frameTex = device.makeTexture(descriptor: d)
        // One waveform column per frame column, so no column of the accumulator is left empty.
        let a = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: Self.waveHeight, mipmapped: false)
        a.usage = [.renderTarget, .shaderRead]
        a.storageMode = .private
        ch.accWave = device.makeTexture(descriptor: a)
        ch.accStops = device.makeTexture(descriptor: a)
    }

    // MARK: - snapshot

    /// Saves the live channel's decoded frame (what its scopes are measuring) to the snapshots folder as a 16-bit PNG.
    func saveSnapshot(label: String, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let frame = live.frameTex, let cmd = queue.makeCommandBuffer() else {
            completion(.failure(NSError(domain: "Scopes", code: 12, userInfo: [NSLocalizedDescriptionKey: "No frame to capture yet"])))
            return
        }
        let w = frame.width, h = frame.height, bpr = w * 8
        guard let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
              let blit = cmd.makeBlitCommandEncoder() else {
            completion(.failure(NSError(domain: "Scopes", code: 13, userInfo: [NSLocalizedDescriptionKey: "Could not allocate the snapshot buffer"])))
            return
        }
        blit.copy(from: frame, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buf, destinationOffset: 0, destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
        blit.endEncoding()
        cmd.addCompletedHandler { _ in
            let halves = buf.contents().bindMemory(to: Float16.self, capacity: w * h * 4)
            var pixels = [UInt16](repeating: 0, count: w * h * 4)
            for i in 0..<(w * h * 4) {
                let v = min(max(Float(halves[i]), 0), 1)
                pixels[i] = i % 4 == 3 ? 65535 : UInt16(v * 65535 + 0.5)
            }
            let result = Result { try SnapshotStore.shared.save(pixels: pixels, width: w, height: h, label: label) }
            DispatchQueue.main.async { completion(result) }
        }
        cmd.commit()
    }

    // MARK: - stats & capture

    private func reportStats() {
        let now = CACurrentMediaTime()
        let elapsed = now - statStart
        guard elapsed >= 2 else { return }
        let msg = String(format: "draw %.1f fps | video %.1f fps | GPU %.2f ms/frame",
                         Double(statFrames) / elapsed, Double(statNewFrames) / elapsed,
                         statGPUTime / Double(max(statFrames, 1)) * 1000)
        onStats?(msg)
        statFrames = 0; statNewFrames = 0; statGPUTime = 0; statStart = now
    }

    private func enqueueCapture(_ cmd: MTLCommandBuffer, texture: MTLTexture, url: URL, overlay: [CaptureText]) {
        let w = texture.width, h = texture.height, bpr = w * 4
        guard let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
              let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: buf, destinationOffset: 0, destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
        blit.endEncoding()
        cmd.addCompletedHandler { _ in
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let ctx = CGContext(data: buf.contents(), width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue) else { return }
            // Draw the AppKit labels into the capture so it matches what is on screen.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            for t in overlay {
                if let bg = t.background { bg.setFill(); t.rect.fill(using: .sourceOver) }
                t.string.draw(with: t.rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let img = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
            print("captured \(url.path)")
        }
    }
}
