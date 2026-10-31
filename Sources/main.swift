import AppKit
import MetalKit
import UniformTypeIdentifiers

/// MTKView that takes keyboard, mouse and trackpad input and accepts dropped image files.
final class ScopeView: MTKView {
    var onKey: ((NSEvent) -> Bool)?
    /// Dropped image or video files, with the drop point in view coordinates.
    var onDropFiles: (([URL], NSPoint) -> Void)?
    weak var controller: ScopesWindow?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    // Scroll or pinch over a vectorscope zooms it; double-click resets it to 100%.
    override func scrollWheel(with event: NSEvent) {
        guard let c = controller, let ch = c.vectorscope(at: event) else { return super.scrollWheel(with: event) }
        let step = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
        c.zoom(ch, by: Float(exp(Double(event.scrollingDeltaY) * step)))
    }
    override func magnify(with event: NSEvent) {
        guard let c = controller, let ch = c.vectorscope(at: event) else { return }
        c.zoom(ch, by: Float(1 + event.magnification))
    }
    override func mouseDown(with event: NSEvent) {
        guard let c = controller else { return super.mouseDown(with: event) }
        c.focusPanel(at: event)
        if c.beginColumnResize(event) { return }
        if event.clickCount == 2, let ch = c.vectorscope(at: event) { c.setZoom(ch, 1) }
        else if !c.beginSelection(event) { super.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let c = controller else { return super.mouseDragged(with: event) }
        if c.dragColumnResize(event) || c.dragSelection(event) { return }
        super.mouseDragged(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        guard let c = controller else { return super.mouseUp(with: event) }
        if c.endColumnResize(event) || c.endSelection(event) { return }
        super.mouseUp(with: event)
    }
    // Left-right resize cursor over the dividers between bottom-row panels.
    override func resetCursorRects() {
        for r in controller?.dividerRects() ?? [] { addCursorRect(r, cursor: .resizeLeftRight) }
    }

    func enableImageDrops() { registerForDraggedTypes([.fileURL]) }

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).filter { url in
            if FileDecodeSource.extensions.contains(url.pathExtension.lowercased()) { return true }
            guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
            return type.conforms(to: .image) || type.conforms(to: .movie)
        }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? [] : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFiles(sender)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls, convert(sender.draggingLocation, from: nil))
        return true
    }
}

/// Umbra Scope "Phantom" palette (see the design canvas).
enum Palette {
    static let ink = NSColor(srgbRed: 0.145, green: 0.141, blue: 0.125, alpha: 1)        // #252420 carvão profundo
    static let panel = NSColor(srgbRed: 0.188, green: 0.184, blue: 0.169, alpha: 1)      // #302F2B carvão
    static let raised = NSColor(srgbRed: 0.227, green: 0.224, blue: 0.204, alpha: 1)     // #3A3934 elevado
    static let text = NSColor(srgbRed: 0.902, green: 0.902, blue: 0.902, alpha: 1)       // #E6E6E6 branco-gelo
    static let secondary = NSColor(srgbRed: 0.604, green: 0.596, blue: 0.565, alpha: 1) // #9A9890
    static let purple = NSColor(srgbRed: 0.541, green: 0.169, blue: 0.886, alpha: 1)      // #8A2BE2 Roxo Umbra (brand book)
    static let purpleText = NSColor(srgbRed: 0.741, green: 0.549, blue: 0.961, alpha: 1)  // #BD8CF5 roxo para texto pequeno
    static let mint = NSColor(srgbRed: 0.498, green: 0.812, blue: 0.616, alpha: 1)       // #7FCF9D verde de estado
    static let hairline = NSColor(srgbRed: 0.275, green: 0.267, blue: 0.247, alpha: 1)   // #46443F linhas
}

/// A label over the Metal view. `kern` and `uppercase` give the spaced small-caps look of the panel titles;
/// a leading "●" is drawn in `dotColor`.
final class StyledLabel: NSTextField {
    var kern: CGFloat = 0
    var uppercase = false
    var dotColor: NSColor?

    func setText(_ text: String) {
        let t = uppercase ? text.uppercased() : text
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = lineBreakMode
        let s = NSMutableAttributedString(string: t, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 11), .foregroundColor: textColor ?? Palette.text,
            .kern: kern, .paragraphStyle: para,
        ])
        if let dot = dotColor, t.hasPrefix("●") { s.addAttribute(.foregroundColor, value: dot, range: NSRange(location: 0, length: 1)) }
        attributedStringValue = s
    }
}

private func overlayLabel(size: CGFloat = 11, weight: NSFont.Weight = .regular, color: NSColor = Palette.secondary,
                          mono: Bool = true, kern: CGFloat = 0, uppercase: Bool = false) -> StyledLabel {
    let l = StyledLabel(labelWithString: "")
    l.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.kern = kern
    l.uppercase = uppercase
    l.isHidden = true
    return l
}

/// Colour of target i (T1…T4); the same list as kTargetColors in Scopes.metal.
private func targetColor(_ i: Int) -> NSColor {
    [Palette.purple, Palette.mint, NSColor(srgbRed: 1, green: 0.78, blue: 0.35, alpha: 1),
     NSColor(srgbRed: 1, green: 0.55, blue: 0.75, alpha: 1)][i % 4]
}

/// Panel titles: small spaced monospaced capitals, like "WAVEFORM · SOURCE".
private func titleLabel() -> StyledLabel { overlayLabel(size: 11, weight: .medium, kern: 1.5, uppercase: true) }

/// The labels belonging to one channel's three panels.
private final class ChannelLabels {
    let pictureTitle = titleLabel()
    let pictureStatus = titleLabel()
    let waveTitle = titleLabel()
    let vecTitle = titleLabel()
    let zoom = overlayLabel(size: 11, weight: .medium)
    let placeholder = overlayLabel(size: 13, mono: false)
    let scale = (0...10).map { _ in overlayLabel(size: 10, color: Palette.secondary.withAlphaComponent(0.8)) }
    let peakMax = overlayLabel(size: 11, weight: .semibold, color: Palette.purpleText)
    let peakMin = overlayLabel(size: 11, weight: .semibold, color: Palette.purpleText)
    let waveMode = overlayLabel(size: 10, kern: 0.8, uppercase: true)
    let vecSelection = overlayLabel(size: 10, kern: 0.8, uppercase: true)
    /// "Show 2x Zoom" under the vectorscope title.
    let vec2x: NSButton = {
        let b = NSButton(checkboxWithTitle: "2x", target: nil, action: nil)
        b.attributedTitle = NSAttributedString(string: "Show 2x Zoom", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Palette.text])
        b.controlSize = .small
        b.toolTip = "Chroma doubled on the vectorscope; graticule unchanged (V)"
        b.sizeToFit()
        return b
    }()
    let noise: StyledLabel = {
        let l = overlayLabel(size: 11, color: Palette.text)
        l.drawsBackground = true
        l.backgroundColor = Palette.ink.withAlphaComponent(0.85)
        l.maximumNumberOfLines = 0
        return l
    }()
    let notice: StyledLabel = {
        let l = overlayLabel(size: 12, weight: .semibold, color: .black, mono: false)
        l.drawsBackground = true
        l.backgroundColor = NSColor(srgbRed: 1, green: 0.78, blue: 0.25, alpha: 0.92)
        return l
    }()
    /// Readout chip, placed next to the probe (or the selection) with a thin purple border.
    let readout: StyledLabel = {
        let l = overlayLabel(size: 11, color: Palette.text)
        l.drawsBackground = true
        l.backgroundColor = Palette.ink.withAlphaComponent(0.88)
        l.maximumNumberOfLines = 0
        l.wantsLayer = true
        l.layer?.cornerRadius = 6
        l.layer?.borderWidth = 1
        l.layer?.borderColor = Palette.purple.withAlphaComponent(0.4).cgColor
        return l
    }()
    let probeMark = overlayLabel(size: 14, weight: .bold, color: Palette.purple, mono: false)
    /// T1…T4 next to the target lines on the waveform and the rings on the vectorscope.
    let waveTargets = (0..<ScopeTarget.maxCount * 2).map { _ in overlayLabel(size: 10, weight: .semibold) }
    let vecTargets = (0..<ScopeTarget.maxCount * 2).map { _ in overlayLabel(size: 10, weight: .semibold) }
    /// Waveform title row, while peak hold is on: click to start the hold over.
    let hold = overlayLabel(size: 10, weight: .medium, color: NSColor(srgbRed: 1, green: 0.78, blue: 0.35, alpha: 1),
                            kern: 0.8, uppercase: true)
    let wipeLeft = overlayLabel(size: 10, weight: .medium, color: Palette.text, kern: 1.2, uppercase: true)
    let wipeRight = overlayLabel(size: 10, weight: .medium, color: Palette.text, kern: 1.2, uppercase: true)
    var all: [StyledLabel] { [pictureTitle, pictureStatus, waveTitle, waveMode, vecTitle, vecSelection, zoom, placeholder, peakMax, peakMin, noise, notice,
                              readout, probeMark, wipeLeft, wipeRight, hold] + scale + waveTargets + vecTargets }
}

/// The main window: Source Signal and Snapshot side by side, each with its own waveform and vectorscope.
final class ScopesWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let view: ScopeView
    let renderer: Renderer
    let gallery: GalleryBar
    let rail: RailView
    private let liveLabels = ChannelLabels()
    private let snapLabels = ChannelLabels()
    private let status: StyledLabel = {
        let l = overlayLabel(size: 11, kern: 1.0, uppercase: true)
        l.dotColor = Palette.mint
        return l
    }()
    /// UMBRA / SCOPE lockup from the brand book (Resources/wordmark.png, made by tools/make_brand_assets.py).
    private let wordmark: NSImageView = {
        let v = NSImageView()
        if let url = Bundle.main.url(forResource: "wordmark", withExtension: "png") { v.image = NSImage(contentsOf: url) }
        v.imageScaling = .scaleProportionallyUpOrDown
        v.setAccessibilityLabel("Umbra Scope")
        return v
    }()
    private let falseColorTitle = titleLabel()
    /// "● S1" / "● R1" on the pictures where the points are.
    private let pinMarks = (0..<ScopeTarget.maxCount * 2).map { _ -> StyledLabel in
        let l = overlayLabel(size: 11, weight: .semibold)
        l.drawsBackground = true
        l.backgroundColor = Palette.ink.withAlphaComponent(0.55)
        return l
    }
    /// Source − Reference for each pair of points (S1 − R1 …).
    private let pointsTable: StyledLabel = {
        let l = overlayLabel(size: 11, color: Palette.text)
        l.drawsBackground = true
        l.backgroundColor = Palette.ink.withAlphaComponent(0.88)
        l.maximumNumberOfLines = 0
        return l
    }()
    /// Single layout: tabs in the tool slot's title row (HML · Stops · False Color).
    private let toolTabs: [StyledLabel] = ToolTab.allCases.map { _ in
        let l = overlayLabel(size: 11, weight: .medium, kern: 1.5, uppercase: true)
        l.wantsLayer = true
        l.layer?.cornerRadius = 7
        return l
    }
    private let hmlTitle = titleLabel()
    private let hmlZones = ["Shadows", "Mids", "Highlights"].map { _ in overlayLabel(size: 10, kern: 1.0, uppercase: true) }
    private let stopsTitle = titleLabel()
    private let stopsCurve = overlayLabel(size: 10, kern: 0.8, uppercase: true)
    private let stopsScale = stride(from: -8, through: 6, by: 2).map { _ in overlayLabel(size: 10, color: Palette.secondary.withAlphaComponent(0.8)) }
    private let falseColorScale = [0, 50, 100].map { _ in overlayLabel(size: 10) }
    private var lastStats = ""
    private var labelTimer: Timer?
    /// Play/pause and scrubber under the Source picture, for video files.
    let playerBar = PlayerBar(frame: .zero)
    /// LUT choice left of the Source picture (Single layout).
    let lutPanel = LUTPanel(frame: .zero)
    private var lutEntries: [LUTEntry] = []
    private(set) var lutEntry: LUTEntry?

    init(frame: NSRect) throws {
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 640)
        window.title = "Umbra Scope"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.ink
        // Side rail on the left; gallery strip on top of the right side, scopes below it.
        let content = NSView(frame: window.contentView!.bounds)
        let galleryH = GalleryBar.height, railW = RailView.width
        rail = RailView(frame: NSRect(x: 0, y: 0, width: railW, height: content.bounds.height))
        rail.autoresizingMask = [.height]
        gallery = GalleryBar(frame: NSRect(x: railW, y: content.bounds.height - galleryH, width: content.bounds.width - railW, height: galleryH))
        gallery.autoresizingMask = [.width, .minYMargin]
        view = ScopeView(frame: NSRect(x: railW, y: 0, width: content.bounds.width - railW, height: content.bounds.height - galleryH))
        view.autoresizingMask = [.width, .height]
        content.addSubview(rail)
        content.addSubview(gallery)
        content.addSubview(view)
        window.contentView = content
        renderer = try Renderer(view: view)
        super.init()
        view.delegate = renderer
        view.controller = self
        window.delegate = self
        allLabels.forEach(view.addSubview)
        view.addSubview(wordmark)
        for b in [liveLabels.vec2x, snapLabels.vec2x] {
            b.target = self
            b.action = #selector(toggleVec2x(_:))
            view.addSubview(b)
        }
        playerBar.isHidden = true
        view.addSubview(playerBar)
        lutPanel.isHidden = true
        view.addSubview(lutPanel)
        setUpLUTPanel()
        loadTargets()
        renderer.onStats = { [weak self] s in self?.lastStats = s }
        renderer.onLayout = { [weak self] _ in
            guard let self else { return }
            layoutLabels()
            window.invalidateCursorRects(for: view)
        }
        loadLayoutPreferences()
        renderer.onPeaks = { [weak self] in self?.schedulePeaksLayout() }
        // Connection state and frame info change without a layout change, so refresh the text on a timer.
        labelTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.layoutLabels() }
    }

    var isGalleryVisible: Bool { !gallery.isHidden }

    func setGalleryVisible(_ visible: Bool) {
        guard visible != isGalleryVisible, let content = window.contentView else { return }
        gallery.isHidden = !visible
        view.frame = NSRect(x: RailView.width, y: 0, width: content.bounds.width - RailView.width,
                            height: content.bounds.height - (visible ? GalleryBar.height : 0))
        layoutLabels()
    }

    /// Writes the side rail as a PNG (AppKit view, not part of the Metal capture).
    func captureRail(to url: URL) {
        guard let rep = rail.bitmapImageRepForCachingDisplay(in: rail.bounds) else { return }
        rail.cacheDisplay(in: rail.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Writes the player bar as a PNG (AppKit view, not in the Metal capture).
    func capturePlayerBar(to url: URL) {
        guard !playerBar.isHidden, let rep = playerBar.bitmapImageRepForCachingDisplay(in: playerBar.bounds) else { return }
        playerBar.cacheDisplay(in: playerBar.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func captureLUTPanel(to url: URL) {
        guard !lutPanel.isHidden, let rep = lutPanel.bitmapImageRepForCachingDisplay(in: lutPanel.bounds) else { return }
        lutPanel.cacheDisplay(in: lutPanel.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Writes the gallery strip as a PNG (it is an AppKit view, so it is not part of the Metal capture).
    func captureGallery(to url: URL) {
        guard !gallery.isHidden, let rep = gallery.bitmapImageRepForCachingDisplay(in: gallery.bounds) else { return }
        gallery.cacheDisplay(in: gallery.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    func windowWillClose(_ notification: Notification) {
        labelTimer?.invalidate()
        renderer.channels.forEach { $0.source = nil }
        view.isPaused = true
    }

    // MARK: - scope controls

    /// Whether a view point falls on the Source (left) picture panel.
    func isOverSourcePicture(_ p: NSPoint) -> Bool {
        pointsRect(renderer.layout.live.pictureArea).contains(p)
    }

    func vectorscope(at event: NSEvent) -> ScopeChannel? {
        vectorscope(atPoint: view.convert(event.locationInWindow, from: nil))
    }

    private func vectorscope(atPoint p: NSPoint) -> ScopeChannel? {
        if pointsRect(renderer.layout.live.vectorscope).contains(p) { return renderer.live }
        if pointsRect(renderer.layout.snapshot.vectorscope).contains(p) { return renderer.snapshot }
        return nil
    }

    func zoom(_ ch: ScopeChannel, by factor: Float) { setZoom(ch, ch.vecZoom * factor) }

    func setZoom(_ ch: ScopeChannel, _ zoom: Float) {
        ch.vecZoom = zoom
        layoutLabels()
    }

    func zoomUnderPointer(by factor: Float = 1, reset: Bool = false) {
        let p = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let targets = vectorscope(atPoint: p).map { [$0] } ?? renderer.channels
        targets.forEach { reset ? setZoom($0, 1) : zoom($0, by: factor) }
    }

    @objc private func toggleVec2x(_ sender: NSButton) {
        renderer.vecDouble = sender.state == .on
        layoutLabels()
    }

    private var allLabels: [StyledLabel] {
        liveLabels.all + snapLabels.all + toolTabs + pinMarks + [pointsTable, status, falseColorTitle, hmlTitle, stopsTitle, stopsCurve]
            + falseColorScale + hmlZones + stopsScale
    }

    /// Readout box over each picture (toggle with R).
    var showReadout = true { didSet { layoutLabels() } }

    /// Noise meter box over each picture.
    var showNoiseMeter = false { didSet { renderer.noiseMeterShown = showNoiseMeter; layoutLabels() } }

    func nextNoiseView() {
        renderer.noiseView = renderer.noiseView.next
        layoutLabels()
    }

    func toggleFalseColorSource() {
        renderer.toolShowsSnapshot.toggle()
        layoutLabels()
    }

    // MARK: - column widths (drag the dividers between bottom-row panels; double-click resets)

    private var columnDrag: (index: Int, startX: CGFloat, startWeights: [Double])?
    private static let weightsKey = "bottomColumnWeights"

    /// Divider i sits between column i and i + 1, as a strip of view points.
    func dividerRects() -> [NSRect] {
        guard renderer.zoomedPanel == nil else { return [] }
        let cols = renderer.layout.columns.map(pointsRect)
        guard cols.count > 1 else { return [] }
        return (0..<cols.count - 1).map { i in
            let x = (cols[i].maxX + cols[i + 1].minX) / 2
            return NSRect(x: x - 4, y: cols[i].minY, width: 8, height: cols[i].height + 20)
        }
    }

    func beginColumnResize(_ event: NSEvent) -> Bool {
        let p = view.convert(event.locationInWindow, from: nil)
        guard let i = dividerRects().firstIndex(where: { $0.contains(p) }) else { return false }
        if event.clickCount == 2 {
            renderer.columnWeights = renderer.layoutMode.defaultWeights
            saveColumnWeights()
            return true
        }
        columnDrag = (i, p.x, renderer.columnWeights)
        return true
    }

    func dragColumnResize(_ event: NSEvent) -> Bool {
        guard let d = columnDrag else { return false }
        let p = view.convert(event.locationInWindow, from: nil)
        let cols = renderer.layout.columns.map(pointsRect)
        let slots = renderer.layout.columnSlots
        guard slots.indices.contains(d.index + 1) else { return true }
        let rowWidth = cols.reduce(0) { $0 + $1.width }
        let total = slots.reduce(0) { $0 + d.startWeights[$1] }
        guard rowWidth > 0 else { return true }
        // Move weight between the two visible columns either side of the divider; keep each at least 80 pt wide.
        let a = slots[d.index], b = slots[d.index + 1]
        let minW = 80 / rowWidth * total
        var delta = Double(p.x - d.startX) / Double(rowWidth) * total
        delta = min(max(delta, -(d.startWeights[a] - minW)), d.startWeights[b] - minW)
        var w = d.startWeights
        w[a] += delta
        w[b] -= delta
        renderer.columnWeights = w
        return true
    }

    func endColumnResize(_ event: NSEvent) -> Bool {
        guard columnDrag != nil else { return false }
        columnDrag = nil
        saveColumnWeights()
        return true
    }

    private func saveColumnWeights() {
        UserDefaults.standard.set(renderer.columnWeights, forKey: "\(Self.weightsKey).\(renderer.layoutMode.rawValue)")
    }

    /// Restores each layout's column widths and the last layout used.
    private func loadLayoutPreferences() {
        let d = UserDefaults.standard
        for mode in LayoutMode.allCases {
            if let w = d.array(forKey: "\(Self.weightsKey).\(mode.rawValue)") as? [Double], w.count == mode.defaultWeights.count,
               w.allSatisfy({ $0 > 0 }) {
                renderer.setColumnWeights(w, for: mode)
            }
        }
        if let m = d.string(forKey: "layoutMode").flatMap(LayoutMode.init) { renderer.layoutMode = m }
        if let hidden = d.array(forKey: "hiddenPanels.v2") as? [Int] { renderer.hiddenPanels = Set(hidden.compactMap(ScopePanel.init)) }
        if let t = ToolTab(rawValue: d.integer(forKey: "toolTab")) { renderer.toolTab = t }
    }

    // MARK: - LUT

    private func setUpLUTPanel() {
        lutPanel.onSelect = { [weak self] e in self?.setLUT(e) }
        lutPanel.onToggle = { [weak self] on in self?.setLUTEnabled(on) }
        lutPanel.onOpenFile = { [weak self] in self?.openLUTFile() }
        renderer.lutEnabled = UserDefaults.standard.object(forKey: "lutEnabled") as? Bool ?? true
        // Scanning ~600 files takes a moment: off the main thread, then restore the last LUT.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries = LUTLibrary.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.lutEntries = entries
                var current: LUTEntry?
                if let path = UserDefaults.standard.string(forKey: "lutPath") {
                    let url = URL(fileURLWithPath: path)
                    current = entries.first { $0.url == url } ?? (FileManager.default.fileExists(atPath: path) ? Self.externalEntry(url) : nil)
                    // The saved LUT is gone: forget it rather than looking for it on every launch.
                    if current == nil { UserDefaults.standard.removeObject(forKey: "lutPath") }
                }
                self.lutPanel.load(entries, current: current, enabled: self.renderer.lutEnabled)
                self.lutPanel.setStatus("\(entries.count) LUTs from DaVinci Resolve's LUT folders")
                if let c = current { self.setLUT(c) }
            }
        }
    }

    private static func externalEntry(_ url: URL) -> LUTEntry {
        LUTEntry(maker: "File", camera: url.deletingLastPathComponent().lastPathComponent,
                 profile: url.deletingPathExtension().lastPathComponent, url: url)
    }

    /// Loads a LUT (nil = none) for the Source; the picture and every scope go through it.
    func setLUT(_ e: LUTEntry?) {
        guard let e else {
            lutEntry = nil
            renderer.lut = nil
            UserDefaults.standard.removeObject(forKey: "lutPath")
            lutPanel.setStatus("No LUT")
            layoutLabels()
            return
        }
        do {
            let gpu = try GPULUT(entry: e, device: renderer.device)
            lutEntry = e
            renderer.lut = gpu
            lutPanel.select(e)
            UserDefaults.standard.set(e.url.path, forKey: "lutPath")
            let d = gpu.data
            let kind = [d.shaper.isEmpty ? nil : "1D \(d.shaper.count)", d.cubeSize > 0 ? "3D \(d.cubeSize)³" : nil]
                .compactMap { $0 }.joined(separator: " + ")
            lutPanel.setStatus("\(e.url.lastPathComponent)\n\(kind)")
        } catch {
            NSSound.beep()
            // Keep the panel on the LUT the renderer is still using.
            lutPanel.select(lutEntry)
            lutPanel.setStatus("Can't read \(e.url.lastPathComponent)")
        }
        layoutLabels()
    }

    func setLUTEnabled(_ on: Bool) {
        renderer.lutEnabled = on
        UserDefaults.standard.set(on, forKey: "lutEnabled")
        lutPanel.setEnabled(on)
        layoutLabels()
    }

    func openLUTFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = LUTLibrary.extensions.compactMap { UTType(filenameExtension: $0) }
        p.allowsOtherFileTypes = true
        guard p.runModal() == .OK, let url = p.url else { return }
        let e = lutEntries.first { $0.url == url } ?? Self.externalEntry(url)
        lutPanel.showExternal(e)
        setLUT(e)
    }

    /// Shows a tab in the Single layout's tool slot (bringing the slot back if it was hidden).
    func selectToolTab(_ t: ToolTab) {
        renderer.toolTab = t
        renderer.hiddenPanels.remove(.tools)
        UserDefaults.standard.set(t.rawValue, forKey: "toolTab")
        UserDefaults.standard.set(renderer.hiddenPanels.map(\.rawValue).sorted(), forKey: "hiddenPanels.v2")
        layoutLabels()
    }

    /// Shows or hides one bottom-row panel; the others share its width. Remembered between launches.
    func togglePanel(_ p: ScopePanel) {
        renderer.zoomedPanel = nil
        if renderer.hiddenPanels.contains(p) { renderer.hiddenPanels.remove(p) } else { renderer.hiddenPanels.insert(p) }
        UserDefaults.standard.set(renderer.hiddenPanels.map(\.rawValue).sorted(), forKey: "hiddenPanels.v2")
        layoutLabels()
    }

    // MARK: - full-screen panel (Cmd+F)

    /// The panel last clicked; Cmd+F uses the one under the pointer, else this one.
    var focusedPanel: ZoomTarget?

    private func panelTarget(at p: NSPoint) -> ZoomTarget? {
        let l = renderer.layout
        let cards: [(ZoomTarget, CGRect)] = [
            (.livePicture, l.live.pictureCard), (.snapPicture, l.snapshot.pictureCard),
            (.liveWave, l.live.waveCard), (.snapWave, l.snapshot.waveCard),
            (.liveVec, l.live.vecCard), (.snapVec, l.snapshot.vecCard), (.tool, l.toolCard),
        ]
        return cards.first { !$0.1.isEmpty && pointsRect($0.1).contains(p) }?.0
    }

    func focusPanel(at event: NSEvent) {
        if let t = panelTarget(at: view.convert(event.locationInWindow, from: nil)) { focusedPanel = t }
    }

    /// Cmd+F: the panel under the pointer (or last clicked) fills the window; again, or Esc, to go back.
    func toggleZoomedPanel() {
        if renderer.zoomedPanel != nil {
            exitZoomedPanel()
            return
        }
        let p = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard let t = panelTarget(at: p) ?? focusedPanel, t.slot(in: renderer.layoutMode) != nil || t == .livePicture
                || (t == .snapPicture && renderer.layoutMode == .comparison) else { return }
        renderer.zoomedPanel = t
        focusedPanel = t
        layoutLabels()
        window.invalidateCursorRects(for: view)
    }

    @discardableResult
    func exitZoomedPanel() -> Bool {
        guard renderer.zoomedPanel != nil else { return false }
        renderer.zoomedPanel = nil
        layoutLabels()
        window.invalidateCursorRects(for: view)
        return true
    }

    // MARK: - layout presets

    var layoutMode: LayoutMode { renderer.layoutMode }

    func setLayout(_ mode: LayoutMode) {
        guard mode != renderer.layoutMode else { return }
        renderer.zoomedPanel = nil
        renderer.layoutMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "layoutMode")
        layoutLabels()
        window.invalidateCursorRects(for: view)
    }

    // MARK: - selection (drag on a picture: rectangle; with Option: ellipse; click without dragging clears)

    private var drag: (channel: ScopeChannel, start: CGPoint, shape: Selection.Shape, moved: Bool, shift: Bool)?
    private var draggingWipe = false
    /// Drag on a waveform or vectorscope: marks a region there, and the picture shows which pixels are in it.
    private var scopeDrag: (channel: ScopeChannel, kind: ScopeMark.Kind, panel: NSRect, start: CGPoint, moved: Bool)?

    /// Waveform or vectorscope panel under a point (view points), with its channel.
    private func scopePanel(at p: NSPoint) -> (ScopeChannel, ScopeMark.Kind, NSRect)? {
        let l = renderer.layout
        let single = renderer.layoutMode == .single
        for (ch, cl) in [(renderer.live, l.live), (renderer.snapshot, l.snapshot)] where ch.hasFrame && (ch === renderer.live || !single) {
            let w = pointsRect(cl.waveform), v = pointsRect(cl.vectorscope)
            if !w.isEmpty, w.contains(p) { return (ch, .waveform, w) }
            if !v.isEmpty, v.contains(p) { return (ch, .vectorscope, v) }
        }
        return nil
    }

    /// Point in a panel as uv, 0…1 with y down (the scopes' panel convention).
    private func panelUV(_ p: NSPoint, in r: NSRect) -> CGPoint {
        CGPoint(x: min(max((p.x - r.minX) / max(r.width, 1), 0), 1), y: min(max((r.maxY - p.y) / max(r.height, 1), 0), 1))
    }

    /// Whether the wipe line is shown over the Source picture (Single layout, a Reference loaded, X on).
    private var wipeActive: Bool { renderer.layoutMode == .single && renderer.wipeEnabled && renderer.snapshot.hasFrame }

    /// Picture under a view point, with the point in that picture's uv (0..1, origin top-left).
    private func picture(at p: NSPoint) -> (ScopeChannel, CGPoint)? {
        for (ch, cl) in [(renderer.live, renderer.layout.live), (renderer.snapshot, renderer.layout.snapshot)] where ch.hasFrame {
            let r = pointsRect(cl.picture)
            if r.insetBy(dx: -4, dy: -4).contains(p) {
                let uv = CGPoint(x: (p.x - r.minX) / r.width, y: (r.maxY - p.y) / r.height)
                let clamped = CGPoint(x: min(max(uv.x, 0), 1), y: min(max(uv.y, 0), 1))
                // Wipe: right of the line the picture shows the Reference, so a click there measures the Reference.
                if ch === renderer.live, wipeActive, clamped.x >= renderer.wipePosition { return (renderer.snapshot, clamped) }
                return (ch, clamped)
            }
        }
        return nil
    }

    func beginSelection(_ event: NSEvent) -> Bool {
        let p = view.convert(event.locationInWindow, from: nil)
        if [liveLabels.hold, snapLabels.hold].contains(where: { !$0.isHidden && $0.frame.insetBy(dx: -6, dy: -6).contains(p) }) {
            renderer.resetPeakHold()
            return true
        }
        if let i = toolTabs.firstIndex(where: { !$0.isHidden && $0.frame.insetBy(dx: -4, dy: -4).contains(p) }) {
            selectToolTab(ToolTab.allCases[i])
            return true
        }
        // Grab the wipe line when the click is on it.
        if wipeActive {
            let r = pointsRect(renderer.layout.live.picture)
            let lineX = r.minX + r.width * renderer.wipePosition
            if abs(p.x - lineX) < 8, p.y >= r.minY, p.y <= r.maxY { draggingWipe = true; return true }
        }
        if let (ch, kind, r) = scopePanel(at: p) {
            scopeDrag = (ch, kind, r, panelUV(p, in: r), false)
            return true
        }
        guard let (ch, uv) = picture(at: p) else { return false }
        drag = (ch, uv, event.modifierFlags.contains(.option) ? .ellipse : .rectangle, false, event.modifierFlags.contains(.shift))
        return true
    }

    func dragSelection(_ event: NSEvent) -> Bool {
        if draggingWipe {
            let r = pointsRect(renderer.layout.live.picture)
            let p = view.convert(event.locationInWindow, from: nil)
            renderer.wipePosition = min(max(Double((p.x - r.minX) / max(r.width, 1)), 0.02), 0.98)
            layoutLabels()
            return true
        }
        if var s = scopeDrag {
            let p = view.convert(event.locationInWindow, from: nil)
            let uv = panelUV(p, in: s.panel)
            let rect = CGRect(x: min(s.start.x, uv.x), y: min(s.start.y, uv.y),
                              width: abs(uv.x - s.start.x), height: abs(uv.y - s.start.y))
            if rect.width * s.panel.width > 3 || rect.height * s.panel.height > 3 {
                s.moved = true
                s.channel.mark = renderer.scopeMark(s.channel, kind: s.kind, panel: rect)
                layoutLabels()
            }
            scopeDrag = s
            return true
        }
        guard var d = drag else { return false }
        // Dragging selects on the Source even when it starts on the wipe's Reference side (only clicks probe there).
        if d.channel === renderer.snapshot && renderer.layoutMode == .single { d.channel = renderer.live }
        let r = pointsRect(d.channel === renderer.live ? renderer.layout.live.picture : renderer.layout.snapshot.picture)
        let p = view.convert(event.locationInWindow, from: nil)
        let uv = CGPoint(x: min(max((p.x - r.minX) / r.width, 0), 1), y: min(max((r.maxY - p.y) / r.height, 0), 1))
        let rect = CGRect(x: min(d.start.x, uv.x), y: min(d.start.y, uv.y),
                          width: abs(uv.x - d.start.x), height: abs(uv.y - d.start.y))
        // Ignore the first pixel or two of movement, so a click doesn't become a tiny selection.
        if rect.width * r.width > 3 || rect.height * r.height > 3 {
            d.moved = true
            d.channel.selection = Selection(rect: rect, shape: d.shape)
            layoutLabels()
        }
        drag = d
        return true
    }

    func endSelection(_ event: NSEvent) -> Bool {
        if draggingWipe { draggingWipe = false; return true }
        if let s = scopeDrag {
            scopeDrag = nil
            if !s.moved { s.channel.mark = nil }   // a click on the scope drops its mark
            layoutLabels()
            return true
        }
        guard let d = drag else { return false }
        drag = nil
        // A plain click measures that point (readout) and drops this picture's selection.
        if !d.moved && d.shift {
            // Shift-click: a point (S1…S4 / R1…R4) there, or removes the one under the click.
            let shown = d.channel === renderer.snapshot && renderer.layoutMode == .single ? renderer.layout.live.picture
                : (d.channel === renderer.live ? renderer.layout.live.picture : renderer.layout.snapshot.picture)
            togglePoint(at: d.start, on: d.channel, pictureSize: pointsRect(shown).size)
        } else if !d.moved {
            d.channel.selection = nil
            d.channel.probe = d.start
        }
        layoutLabels()
        return true
    }

    func clearSelectionUnderPointer() {
        let p = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let targets = picture(at: p).map { [$0.0] } ?? renderer.channels
        targets.forEach { $0.selection = nil; $0.probe = nil; $0.mark = nil }
        layoutLabels()
    }

    // MARK: - points (S1…S4 on the Source, R1…R4 on the Reference)

    /// Pins the probe (or the selection's centre) of the picture under the pointer — else the Source, else the
    /// Reference — as its next point.
    func pinTarget(from only: ScopeChannel? = nil) {
        let p = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let candidates = only.map { [$0] } ?? [picture(at: p)?.0, renderer.live, renderer.snapshot].compactMap { $0 }
        guard let ch = candidates.first(where: { $0.selection != nil || $0.probe != nil }),
              let point = ch.selection.map({ CGPoint(x: $0.rect.midX, y: $0.rect.midY) }) ?? ch.probe
        else { NSSound.beep(); return }
        addPoint(point, to: ch)
    }

    /// Puts a point in the picture's first free slot (when all four are used, the oldest is replaced).
    func addPoint(_ uv: CGPoint, to ch: ScopeChannel) {
        var pts = ch.points
        if let free = pts.firstIndex(where: { $0 == nil }) { pts[free] = uv }
        else { pts[pointCursor(ch)] = uv; advancePointCursor(ch) }
        ch.points = pts
        savePoints()
        layoutLabels()
    }

    private var replaceCursor: [ObjectIdentifier: Int] = [:]
    private func pointCursor(_ ch: ScopeChannel) -> Int { replaceCursor[ObjectIdentifier(ch)] ?? 0 }
    private func advancePointCursor(_ ch: ScopeChannel) {
        replaceCursor[ObjectIdentifier(ch)] = (pointCursor(ch) + 1) % ScopeTarget.maxCount
    }

    /// Shift-click: removes the point under the click (within 10 pt) or adds one there.
    func togglePoint(at uv: CGPoint, on ch: ScopeChannel, pictureSize: CGSize) {
        if let i = ch.points.firstIndex(where: { p in
            guard let p else { return false }
            return hypot((p.x - uv.x) * pictureSize.width, (p.y - uv.y) * pictureSize.height) < 10 }) {
            ch.points[i] = nil
            savePoints()
            layoutLabels()
        } else {
            addPoint(uv, to: ch)
        }
    }

    /// Clears the points of the picture under the pointer, or of both.
    func clearPoints() {
        let p = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let targets = picture(at: p).map { [$0.0] } ?? renderer.channels
        targets.forEach { $0.points = Array(repeating: nil, count: ScopeTarget.maxCount) }
        savePoints()
        layoutLabels()
    }

    private func savePoints() {
        for (ch, key) in [(renderer.live, "points.source"), (renderer.snapshot, "points.reference")] {
            UserDefaults.standard.set(ch.points.map { p -> [Double] in p.map { [Double($0.x), Double($0.y)] } ?? [] }, forKey: key)
        }
    }

    func loadTargets() {
        UserDefaults.standard.removeObject(forKey: "targets")   // the earlier fixed-colour targets
        for (ch, key) in [(renderer.live, "points.source"), (renderer.snapshot, "points.reference")] {
            guard let saved = UserDefaults.standard.array(forKey: key) as? [[Double]], saved.count == ScopeTarget.maxCount else { continue }
            ch.points = saved.map { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        }
    }

    /// Source − Reference for each numbered pair: both values, the channel differences, vectorscope angle and stops.
    private func pointsTableText() -> String? {
        let s = renderer.live.pointValues, r = renderer.snapshot.hasFrame ? renderer.snapshot.pointValues : []
        let tr = renderer.stopsTransfer
        let rgb = { (v: Readout) in String(format: "%5.1f %5.1f %5.1f", v.r * 100, v.g * 100, v.b * 100) }
        let none = "    —     —     —"
        var rows = [String]()
        for i in 0..<ScopeTarget.maxCount {
            let sv = renderer.live.points[i] != nil ? s[i] : nil
            let rv = r.indices.contains(i) && renderer.snapshot.points[i] != nil ? r[i] : nil
            guard sv != nil || rv != nil else { continue }
            var row = " \(i + 1)  S \(sv.map(rgb) ?? none)   R \(rv.map(rgb) ?? none)"
            if let a = sv, let b = rv {
                let cb = { (v: Readout) -> (Double, Double) in
                    let y = 0.2126 * v.r + 0.7152 * v.g + 0.0722 * v.b
                    return ((v.b - y) / 1.8556, (v.r - y) / 1.5748)
                }
                let (acb, acr) = cb(a), (bcb, bcr) = cb(b)
                var angle = (atan2(acr, acb) - atan2(bcr, bcb)) * 180 / .pi
                if angle > 180 { angle -= 360 } else if angle < -180 { angle += 360 }
                let lin = { (v: Readout) in 0.2126 * tr.toLinear(v.r) + 0.7152 * tr.toLinear(v.g) + 0.0722 * tr.toLinear(v.b) }
                let la = lin(a), lb = lin(b)
                let st = la > 1e-6 && lb > 1e-6 ? String(format: "%+4.1f st", log2(la / lb)) : "  — st"
                row += String(format: "   Δ %+5.1f %+5.1f %+5.1f  vec %+4.0f°  %@", (a.r - b.r) * 100, (a.g - b.g) * 100,
                              (a.b - b.b) * 100, angle, st)
            }
            rows.append(row + " ")
        }
        guard !rows.isEmpty else { return nil }
        return ([" POINTS     Source R  G  B (%)   Reference R  G  B   S − R "] + rows).joined(separator: "\n")
    }

    func nextDitherMode() {
        renderer.ditherMode = renderer.ditherMode.next
        layoutLabels()
    }

    /// Readout chip and probe mark of one picture, inside `img` (view points). `header` names the picture when two
    /// share one frame (wipe).
    private func placeProbe(_ ch: ScopeChannel, _ labels: ChannelLabels, in img: CGRect, header: String?) {
        // With the wipe on, each chip stays on its own side of the line.
        var area = img
        if wipeActive && renderer.layoutMode == .single {
            let lineX = img.minX + img.width * renderer.wipePosition
            area = ch === renderer.snapshot ? CGRect(x: lineX, y: img.minY, width: img.maxX - lineX, height: img.height)
                                            : CGRect(x: img.minX, y: img.minY, width: lineX - img.minX, height: img.height)
        }
        if showReadout, ch.hasFrame, let r = ch.readout {
            place(labels.readout, readoutText(r, header: header), x: 0, y: 0)
            // Below-right of the probe (or the selection's bottom-right corner); flipped to the other side
            // when it would leave the picture.
            let anchor: CGPoint
            if let s = ch.selection { anchor = CGPoint(x: s.rect.maxX, y: s.rect.maxY) }
            else { anchor = ch.probe ?? CGPoint(x: 1, y: 0) }
            let ax = img.minX + img.width * anchor.x, ay = img.maxY - img.height * anchor.y
            let size = labels.readout.frame.size
            var x = ax + 14, y = ay - 14 - size.height
            if x + size.width > area.maxX - 4 { x = ax - 14 - size.width }
            if y < area.minY + 4 { y = ay + 14 }
            x = max(min(x, area.maxX - size.width - 4), area.minX + 4)
            y = min(max(y, area.minY + 4), area.maxY - size.height - 4)
            labels.readout.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            labels.readout.isHidden = true
        }
        if let pr = ch.probe, ch.selection == nil, ch.hasFrame, showReadout {
            place(labels.probeMark, "+", x: 0, y: 0)
            let f = labels.probeMark.frame
            labels.probeMark.setFrameOrigin(NSPoint(x: img.minX + img.width * pr.x - f.width / 2,
                                                    y: img.maxY - img.height * pr.y - f.height / 2))
        } else {
            labels.probeMark.isHidden = true
        }
    }

    /// Text of the readout box: values in %, 10-bit codes, Y′CbCr, hue/saturation, neutrality and stops.
    private func readoutText(_ r: Readout, header: String? = nil) -> String {
        let (R, G, B) = (r.r, r.g, r.b)
        let y = 0.2126 * R + 0.7152 * G + 0.0722 * B
        let cb = (B - y) / 1.8556, cr = (R - y) / 1.5748
        let mx = max(R, G, B), mn = min(R, G, B), l = (mx + mn) / 2
        let sat = mx - mn < 1e-6 ? 0 : (mx - mn) / max(1e-6, 1 - abs(2 * l - 1))
        var hue = 0.0
        if mx - mn > 1e-6 {
            if mx == R { hue = 60 * ((G - B) / (mx - mn)).truncatingRemainder(dividingBy: 6) }
            else if mx == G { hue = 60 * ((B - R) / (mx - mn) + 2) }
            else { hue = 60 * ((R - G) / (mx - mn) + 4) }
            if hue < 0 { hue += 360 }
        }
        // Neutral when the channels are within 1% of each other. Near the skin line, how far from it (vectorscope
        // degrees, 123° from +Cb). Otherwise a cast is only named for weak colours (greys that are slightly off).
        let spread = (mx - mn) * 100
        let names = ["red", "yellow", "green", "cyan", "blue", "magenta"]
        let skinOffset = atan2(cr, cb) * 180 / .pi - 123
        let cast: String
        if spread < 1 { cast = "neutral" }
        else if abs(skinOffset) < 20 { cast = String(format: "skin line %+.0f°", skinOffset) }
        else if sat < 0.15 { cast = String(format: "cast %@ (%.1f%%)", names[Int(((hue + 30).truncatingRemainder(dividingBy: 360)) / 60)], spread) }
        else { cast = "" }
        let t = renderer.stopsTransfer
        let lin = 0.2126 * t.toLinear(R) + 0.7152 * t.toLinear(G) + 0.0722 * t.toLinear(B)
        let stops = lin > 1e-6 ? String(format: "%+.1f", log2(lin / 0.18)) : "—"
        let pct = { (v: Double) in String(format: "%5.1f", v * 100) }
        let code = { (v: Double) in String(format: "%4d", Int((v * 1023).rounded())) }
        var lines = header.map { [" \($0.uppercased()) "] } ?? []
        if r.isSelection { lines.append(" selection · \(r.pixels) px ") }
        lines += [
            " R\(pct(R))  G\(pct(G))  B\(pct(B)) ",
            " 10-bit \(code(R)) \(code(G)) \(code(B)) ",
            String(format: " Y′ %.1f · Cb %+.1f · Cr %+.1f ", y * 100, cb * 100, cr * 100),
            String(format: " hue %.0f° · sat %.1f ", hue, sat * 100),
            " " + ([cast, "\(stops) st (\(t.title))"].filter { !$0.isEmpty }.joined(separator: " · ")) + " ",
        ]
        return lines.joined(separator: "\n")
    }

    func nextWaveformMode() {
        renderer.waveMode = renderer.waveMode.next
        layoutLabels()
    }

    // MARK: - labels

    /// Converts a rect in drawable pixels (origin top-left) to view points (origin bottom-left).
    func pointsRectPublic(_ r: CGRect) -> CGRect { pointsRect(r) }

    private func pointsRect(_ r: CGRect) -> CGRect {
        let scale = view.drawableSize.width / max(view.bounds.width, 1)
        guard scale > 0 else { return .zero }
        return CGRect(x: r.minX / scale, y: view.bounds.height - r.maxY / scale,
                      width: r.width / scale, height: r.height / scale)
    }

    private func place(_ label: NSTextField, _ text: String, x: CGFloat, y: CGFloat, alignRight: Bool = false, visible: Bool = true,
                       maxWidth: CGFloat = .greatestFiniteMagnitude) {
        if let styled = label as? StyledLabel { styled.setText(text) } else { label.stringValue = text }
        label.sizeToFit()
        if label.frame.width > maxWidth {
            // Too long for its panel: cut the middle, so the start (what it is) and the end (timecode) stay readable.
            label.lineBreakMode = .byTruncatingMiddle
            label.setFrameSize(NSSize(width: max(maxWidth, 20), height: label.frame.height))
        }
        label.setFrameOrigin(NSPoint(x: alignRight ? x - label.frame.width : x, y: y))
        label.isHidden = !visible || text.isEmpty
    }

    /// Measured values arrive up to 60 times a second; one label layout per burst is enough (and the trailing
    /// call keeps a single update, on a still frame, from being lost).
    private var peaksLayoutPending = false
    private func schedulePeaksLayout() {
        guard !peaksLayoutPending else { return }
        peaksLayoutPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 15) { [weak self] in
            guard let self else { return }
            self.peaksLayoutPending = false
            self.layoutLabels()
        }
    }

    func layoutLabels() {
        let l = renderer.layout
        let scale = view.drawableSize.width / max(view.bounds.width, 1)
        let titleH = scale > 0 ? l.titleHeight / scale : 22

        let single = renderer.layoutMode == .single
        snapLabels.all.forEach { $0.isHidden = single }
        if single { snapLabels.vec2x.isHidden = true }
        for (ch, cl, labels) in [(renderer.live, l.live, liveLabels), (renderer.snapshot, l.snapshot, snapLabels)]
            where ch === renderer.live || !single {
            let pic = pointsRect(cl.pictureArea), wave = pointsRect(cl.waveform), vec = pointsRect(cl.vectorscope)
            let titleY = { (r: CGRect) in r.maxY + (titleH - 16) / 2 }
            // Title row of a card (view points): same height as titleY gives for the card's content.
            let cardTitleY = { (c: CGRect) in c.maxY - (titleH + 16) / 2 }

            // Every title says where its picture comes from: the live signal (Source, and which input) or the
            // snapshot (Reference, and which file).
            let isLive = ch === renderer.live
            let role = isLive ? "Source" : "Reference"
            let origin = ch.source?.title ?? (isLive ? "no input" : "no snapshot")
            var picTitle = "\(role) · \(origin)"
            if isLive, renderer.lutActive, let e = lutEntry { picTitle += " · LUT \(e.displayName)" }
            if renderer.noiseView != .off { picTitle += " · noise view \(renderer.noiseView.title)" }
            if let m = ch.mark { picTitle += m.kind == .waveform ? " · waveform mark" : " · vectorscope mark" }
            let card = pointsRect(cl.pictureCard)
            let right = isLive ? (ch.source?.status ?? "") : (ch.hasFrame ? "reference" : "")
            place(labels.pictureStatus, right, x: card.maxX - 14, y: titleY(pic), alignRight: true)
            let statusW = labels.pictureStatus.isHidden ? 0 : labels.pictureStatus.frame.width + 16
            place(labels.pictureTitle, picTitle, x: card.minX + 14, y: titleY(pic), maxWidth: card.width - 28 - statusW)

            // Noise meter in the picture's bottom-left corner (inside the fitted image).
            let img = pointsRect(cl.picture)
            // Caveat from the source (e.g. LibRaw rendering of a Canon CRM) across the top of the picture.
            if let n = ch.source?.notice, ch.hasFrame {
                place(labels.notice, " ⚠︎ \(n) ", x: img.minX + 6, y: img.maxY - 26, maxWidth: img.width - 12)
            } else {
                labels.notice.isHidden = true
            }
            if showNoiseMeter, ch.hasFrame, let n = ch.noise {
                let codes = { (sigma: Float) in String(format: "%.2f%% (%.1f)", sigma * 100, sigma * 1023) }
                let area = ch.selection == nil ? "frame" : "selection"
                let snr = n.snrDB.map { String(format: "   SNR %.1f dB", $0) } ?? ""
                let text = [
                    " Noise σ · \(area) · \(n.width)×\(n.height)   (%  /  10-bit codes) ",
                    " Y  \(codes(n.sigmaY))\(snr) ",
                    " Cb \(codes(n.sigmaCb))   Cr \(codes(n.sigmaCr)) ",
                    " R  \(codes(n.sigmaR))   G \(codes(n.sigmaG))   B \(codes(n.sigmaB)) ",
                ].joined(separator: "\n")
                place(labels.noise, text, x: img.minX + 6, y: img.minY + 6)
            } else {
                labels.noise.isHidden = true
            }
            // Readout: mean colour at the probe or in the selection, top-right of the picture.
            placeProbe(ch, labels, in: img, header: single && wipeActive && isLive ? "Source" : nil)
            if isLive && wipeActive {
                let lineX = img.minX + img.width * renderer.wipePosition
                place(labels.wipeLeft, "Source", x: lineX - 8, y: img.minY + 8, alignRight: true)
                place(labels.wipeRight, "Reference", x: lineX + 8, y: img.minY + 8)
            } else {
                labels.wipeLeft.isHidden = true
                labels.wipeRight.isHidden = true
            }
            place(labels.placeholder, ch === renderer.live ? "Waiting for a frame…" : "No snapshot — press S, or drop an image here",
                  x: pic.midX, y: pic.midY, visible: !ch.hasFrame)
            labels.placeholder.setFrameOrigin(NSPoint(x: pic.midX - labels.placeholder.frame.width / 2, y: pic.midY))
            // Another panel is full screen: nothing of this picture is on screen.
            if cl.pictureCard.isEmpty {
                [labels.pictureTitle, labels.pictureStatus, labels.notice, labels.noise, labels.readout, labels.probeMark,
                 labels.wipeLeft, labels.wipeRight, labels.placeholder].forEach { $0.isHidden = true }
            }

            // Bottom-row titles sit above the row; the vectorscope is centred vertically inside it.
            let sel = ch.selection.map { $0.shape == .ellipse ? "Ellipse selection" : "Selection" }
            // Titles name the picture; display settings and the selection sit inside the panels' top corners.
            let waveCard = pointsRect(cl.waveCard), waveOn = !cl.waveCard.isEmpty
            // The title keeps its room; the mode on the right gives way (hidden) in a narrow column.
            place(labels.waveTitle, "Waveform · \(role)", x: waveCard.minX + 14, y: cardTitleY(waveCard), visible: waveOn,
                  maxWidth: waveCard.width - 28)
            let modeRoom = waveCard.width - labels.waveTitle.frame.width - 44
            place(labels.waveMode, ([renderer.waveMode.title, renderer.ditherMode.title] + (sel.map { [$0] } ?? [])).joined(separator: "  ·  "),
                  x: waveCard.maxX - 14, y: cardTitleY(waveCard) + 1, alignRight: true, visible: waveOn)
            if labels.waveMode.frame.width > modeRoom { labels.waveMode.isHidden = true }
            // Peak hold: "↺ Hold" left of the mode text (or at the right edge when that is hidden); click resets.
            let holdRight = labels.waveMode.isHidden ? waveCard.maxX - 14 : labels.waveMode.frame.minX - 12
            place(labels.hold, "↺ Hold", x: holdRight, y: cardTitleY(waveCard) + 1, alignRight: true,
                  visible: waveOn && renderer.peakHold)
            if labels.hold.frame.minX < labels.waveTitle.frame.maxX + 8 { labels.hold.isHidden = true }
            // The vectorscope is a square inside its column: title at the column's left edge.
            let vecColumn = pointsRect(cl.vecCard), vecOn = !cl.vecCard.isEmpty
            labels.zoom.textColor = ch.vecZoom != 1 ? Palette.purpleText : Palette.secondary
            place(labels.zoom, String(format: "%.0f%%", ch.vecZoom * 100), x: vecColumn.maxX - 14, y: cardTitleY(vecColumn),
                  alignRight: true, visible: vecOn)
            // The title gives way to the zoom value in a narrow column.
            let vecRoom = vecColumn.width - 36 - labels.zoom.frame.width
            for name in ["Vectorscope", "Vec"] {
                place(labels.vecTitle, "\(name) · \(role)", x: vecColumn.minX + 14, y: cardTitleY(vecColumn), visible: vecOn,
                      maxWidth: name == "Vec" ? vecRoom : .greatestFiniteMagnitude)
                if labels.vecTitle.frame.width <= vecRoom { break }
            }
            labels.vec2x.state = renderer.vecDouble ? .on : .off
            labels.vec2x.setFrameOrigin(NSPoint(x: vecColumn.minX + 10, y: cardTitleY(vecColumn) - 22))
            labels.vec2x.isHidden = !vecOn
            place(labels.vecSelection, sel ?? "", x: vec.minX + 6, y: vec.maxY - 18, visible: vecOn)

            // Same mapping as wave_value_to_ndc in Scopes.metal: 5% margin above 100 and below 0.
            let margin: CGFloat = 0.05
            let waveY = { (v: CGFloat) in wave.minY + wave.height * (v + margin) / (1 + 2 * margin) }
            for (i, label) in labels.scale.enumerated() {
                place(label, "\(i * 10)", x: wave.minX - 4, y: waveY(CGFloat(i) / 10) - 7, alignRight: true, visible: !wave.isEmpty)
            }
            // Point names: on the waveform at the point's level (luma, or green in RGB mode), left edge; on the
            // vectorscope beside its ring. Every scope shows both pictures' points.
            let vecScale = CGFloat(Renderer.vecScale * ch.vecView)
            let pts = ch.hasFrame ? renderer.targets : []
            for i in 0..<labels.waveTargets.count {
                guard i < pts.count else { labels.waveTargets[i].isHidden = true; labels.vecTargets[i].isHidden = true; continue }
                let t = pts[i]
                labels.waveTargets[i].textColor = targetColor(t.slot)
                labels.vecTargets[i].textColor = targetColor(t.slot)
                let level = renderer.waveMode == .rgb ? t.g : 0.2126 * t.r + 0.7152 * t.g + 0.0722 * t.b
                place(labels.waveTargets[i], t.name, x: wave.minX + 6 + CGFloat(t.slot) * 24 + (t.fromReference ? 12 : 0),
                      y: waveY(CGFloat(level)) + 1, visible: waveOn && !wave.isEmpty)
                let ty = 0.2126 * t.r + 0.7152 * t.g + 0.0722 * t.b
                let p = CGPoint(x: vec.midX + CGFloat((t.b - ty) / 1.8556) * vecScale * vec.width / 2,
                                y: vec.midY + CGFloat((t.r - ty) / 1.5748) * vecScale * vec.height / 2)
                place(labels.vecTargets[i], t.name, x: p.x + 10, y: p.y + (t.fromReference ? -14 : 2), visible: vecOn && vec.contains(p))
            }

            // Peak values sit just above the max line and just below the min line, at the right edge.
            let peaks = ch.hasFrame && waveOn ? ch.peaks : nil
            if let pk = peaks {
                place(labels.peakMax, String(format: "%.0f", pk.max * 100), x: wave.maxX - 6, y: waveY(CGFloat(pk.max)) + 1, alignRight: true)
                place(labels.peakMin, String(format: "%.0f", pk.min * 100), x: wave.maxX - 6,
                      y: waveY(CGFloat(pk.min)) - labels.peakMin.frame.height - 1, alignRight: true)
                // Keep the two values apart when the trace is nearly flat.
                if labels.peakMax.frame.minY < labels.peakMin.frame.maxY {
                    labels.peakMin.setFrameOrigin(NSPoint(x: labels.peakMin.frame.minX, y: labels.peakMax.frame.minY - labels.peakMin.frame.height))
                }
            } else {
                labels.peakMax.isHidden = true
                labels.peakMin.isHidden = true
            }
        }

        // Single layout with the wipe on: the Reference side of the picture has its own probe and readout chip.
        if single && wipeActive {
            placeProbe(renderer.snapshot, snapLabels, in: pointsRect(l.live.picture), header: "Reference")
        }
        // Point dots, on the picture each point belongs to (in Single, Reference points show on the wipe's Reference
        // side only).
        let pts = renderer.targets
        for (i, mark) in pinMarks.enumerated() {
            guard i < pts.count else { mark.isHidden = true; continue }
            let t = pts[i], p = t.point
            let rect: CGRect
            if !single { rect = pointsRect(t.fromReference ? l.snapshot.picture : l.live.picture) }
            else if !t.fromReference || (wipeActive && p.x >= renderer.wipePosition) { rect = pointsRect(l.live.picture) }
            else { mark.isHidden = true; continue }
            mark.textColor = targetColor(t.slot)
            place(mark, "●\u{2009}\(t.name)", x: 0, y: 0, visible: !rect.isEmpty)
            // The dot's centre on the point: the glyph is about 0.6 em wide.
            let dot = (mark.font?.pointSize ?? 11) * 0.62
            mark.setFrameOrigin(NSPoint(x: rect.minX + rect.width * p.x - dot / 2 - 2,
                                        y: rect.maxY - rect.height * p.y - mark.frame.height / 2))
        }
        // The pairs table: bottom-left of the Source picture (above the noise meter when it shows).
        if showReadout, !l.live.pictureCard.isEmpty, let text = pointsTableText() {
            let img = pointsRect(l.live.picture)
            place(pointsTable, text, x: img.minX + 6, y: 0)
            let above = liveLabels.noise.isHidden ? 0 : liveLabels.noise.frame.height + 6
            pointsTable.setFrameOrigin(NSPoint(x: img.minX + 6, y: img.minY + 6 + above))
        } else {
            pointsTable.isHidden = true
        }

        let legend = pointsRect(l.falseColorLegend)
        let fcRole = renderer.toolChannel === renderer.snapshot ? "Reference" : "Source"
        // Single layout: HML zone names under each small vectorscope, stops scale left of the stops display.
        let cardTitleY = { (c: CGRect) in c.maxY - (titleH + 16) / 2 }
        // Single: the tool slot's title row holds its tabs; the active one is purple on a soft purple pill.
        let toolCard = pointsRect(l.toolCard)
        var tabX = toolCard.minX + 10
        for (label, tab) in zip(toolTabs, ToolTab.allCases) {
            let active = tab == renderer.toolTab
            label.textColor = active ? Palette.purpleText : Palette.secondary
            label.layer?.backgroundColor = active ? Palette.purple.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
            place(label, " \(tab.title) ", x: tabX, y: cardTitleY(toolCard) - 2, visible: !l.toolCard.isEmpty)
            label.setFrameSize(NSSize(width: label.frame.width + 8, height: label.frame.height + 4))
            tabX = label.frame.maxX + 4
        }
        // Right of the tabs: which picture the slot analyses (Comparison) and the stops curve (Stops tab).
        // Falls back to "Src"/"Ref" when the full words don't fit next to the tabs.
        let infoRoom = toolCard.maxX - 24 - tabX
        for role in [fcRole, fcRole == "Source" ? "Src" : "Ref"] {
            let toolInfo = [single ? nil : role, renderer.toolTab == .stops ? renderer.stopsTransfer.title : nil].compactMap { $0 }
            place(stopsCurve, toolInfo.joined(separator: " · "), x: toolCard.maxX - 14, y: cardTitleY(toolCard) + 1, alignRight: true,
                  visible: !l.toolCard.isEmpty)
            if stopsCurve.frame.width <= infoRoom { break }
        }
        if stopsCurve.frame.width > infoRoom { stopsCurve.isHidden = true }
        if !l.hmlCard.isEmpty {
            hmlTitle.isHidden = true
            for (label, (name, r)) in zip(hmlZones, zip(["Shadows", "Mids", "Highlights"], l.hml.map(pointsRect))) {
                place(label, name, x: r.midX, y: r.minY - 16)
                label.setFrameOrigin(NSPoint(x: r.midX - label.frame.width / 2, y: r.minY - 16))
            }
        } else {
            ([hmlTitle] + hmlZones).forEach { $0.isHidden = true }
        }
        if !l.stopsCard.isEmpty {
            let st = pointsRect(l.stops)
            stopsTitle.isHidden = true
            for (label, stop) in zip(stopsScale, stride(from: -8, through: 6, by: 2)) {
                let y = st.minY + st.height * CGFloat(stop + 8) / 14
                place(label, stop > 0 ? "+\(stop)" : "\(stop)", x: st.minX - 4, y: y - 7, alignRight: true)
            }
        } else {
            ([stopsTitle] + stopsScale).forEach { $0.isHidden = true }
        }

        let fcCard = pointsRect(l.falseColorCard)
        place(falseColorTitle, "False Color · \(fcRole)", x: fcCard.minX + 14, y: cardTitleY(fcCard), visible: false,
              maxWidth: fcCard.width - 28)
        for (label, v) in zip(falseColorScale, [0, 50, 100]) {
            place(label, "\(v)", x: legend.minX - 3, y: legend.minY + legend.height * CGFloat(v) / 100 - 7, alignRight: true,
                  visible: !legend.isEmpty)
        }

        // Player bar at the bottom of the Source card (the renderer leaves room for it under the picture).
        playerBar.source = renderer.live.source as? SeekableSource
        let showBar = playerBar.hasTimeline && (renderer.zoomedPanel == nil || renderer.zoomedPanel == .livePicture)
        let barH = showBar ? Double(PlayerBar.height) : 0
        if renderer.playerBarHeight != barH { renderer.playerBarHeight = barH }
        playerBar.isHidden = !showBar
        if showBar {
            let card = pointsRect(l.live.pictureCard)
            playerBar.frame = NSRect(x: card.minX + 12, y: card.minY + 12, width: card.width - 24, height: PlayerBar.height)
        }

        // LUT panel at the left of the Source card, above the player bar (Single layout only).
        let showLUT = single && (renderer.zoomedPanel == nil || renderer.zoomedPanel == .livePicture)
        let panelW = showLUT ? Double(LUTPanel.width) : 0
        if renderer.lutPanelWidth != panelW { renderer.lutPanelWidth = panelW }
        lutPanel.isHidden = !showLUT
        if showLUT {
            let card = pointsRect(l.live.pictureCard)
            let bottom = card.minY + 12 + (showBar ? PlayerBar.height + 6 : 0)
            lutPanel.frame = NSRect(x: card.minX + 12, y: bottom, width: LUTPanel.width,
                                    height: max(60, card.maxY - titleH - bottom))
        }

        // Top bar: wordmark on the left, signal status on the right.
        let bar = pointsRect(l.status)
        let markH: CGFloat = 32, markSize = wordmark.image?.size ?? NSSize(width: 1, height: 1)
        wordmark.frame = NSRect(x: bar.minX + 4, y: bar.midY - markH / 2,
                                width: markH * markSize.width / max(markSize.height, 1), height: markH)
        var info = [String]()
        if let src = renderer.live.source {
            let st = src.status.lowercased()
            let live = st.hasPrefix("live") || st.hasPrefix("playing")
            info.append("\(live ? "● " : "")\(src.title) \(src.status)")
        }
        if !renderer.live.frameInfo.isEmpty { info.append(renderer.live.frameInfo) }
        if let gpu = lastStats.components(separatedBy: "|").last, !lastStats.isEmpty { info.append(gpu.trimmingCharacters(in: .whitespaces)) }
        place(status, info.joined(separator: "    "), x: bar.maxX - 4, y: bar.midY - 8, alignRight: true,
              maxWidth: bar.width - wordmark.frame.maxX - 24)
        rail.update(layout: renderer.layoutMode, galleryVisible: isGalleryVisible, meterVisible: showNoiseMeter,
                    readout: showReadout, wipe: renderer.wipeEnabled, skin: renderer.skinIsolation,
                    panels: Set(ScopePanel.allCases.filter { !renderer.hiddenPanels.contains($0) }))
    }

    /// Visible labels as attributed strings in drawable pixels, so a capture of the drawable shows them too.
    func captureOverlay() -> [Renderer.CaptureText] {
        let scale = view.drawableSize.width / max(view.bounds.width, 1)
        return allLabels.filter { !$0.isHidden }.map { label in
            // The label's own attributed text, with fonts and tracking scaled to drawable pixels.
            let s = NSMutableAttributedString(attributedString: label.attributedStringValue)
            let all = NSRange(location: 0, length: s.length)
            s.enumerateAttribute(.font, in: all) { value, range, _ in
                if let f = value as? NSFont, let scaled = NSFont(descriptor: f.fontDescriptor, size: f.pointSize * scale) {
                    s.addAttribute(.font, value: scaled, range: range)
                }
            }
            s.enumerateAttribute(.kern, in: all) { value, range, _ in
                if let k = value as? CGFloat { s.addAttribute(.kern, value: k * scale, range: range) }
            }
            let f = label.frame
            return Renderer.CaptureText(string: s, rect: CGRect(x: f.minX * scale, y: (view.bounds.height - f.maxY) * scale,
                                                                width: f.width * scale, height: f.height * scale),
                                        background: label.drawsBackground ? label.backgroundColor : nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var main: ScopesWindow!
    private var renderer: Renderer { main.renderer }
    private let store = SnapshotStore.shared
    private var knownSnapshots = Set<URL>()
    private var autoOpenNewImages = true
    private var snapshotsMenu: NSMenu!
    private var viewMenu: NSMenu!
    private var captureMenu: NSMenu!

    // Command line: ScopesPrototype [file] [--snapshot <image>]
    //               [--take-snapshot-after <s>] [--zoom <live%> <snapshot%>] [--wave color|rgb|luma]
    //               [--capture <prefix>] [--quit-after <seconds>]
    private var initialVideo: URL?
    private var initialSnapshot: URL?
    private var takeSnapshotAfter: Double?
    private var initialZoom: (Float, Float)?
    private var initialWave: WaveformMode?
    private var initialDither: DitherMode?
    private var falseColorSnapshot = false
    private var initialSelections: (live: Selection?, snapshot: Selection?) = (nil, nil)
    private var capturePrefix: String?
    private var startOnCaptureDevice = false
    private var quitAfter: Double?
    private var checkViewMenu = false
    private var initialLayout: LayoutMode?
    private var initialProbe: CGPoint?
    private var initialWipe: Double?
    private var initialSkin = false
    private var initialVec2x = false
    private var initialAbout = false
    private var initialHidden: Set<ScopePanel>?
    private var initialTab: ToolTab?
    private var initialZoomPanel: ZoomTarget?
    private var initialSeek: Int?
    private var initialEnvelope = false
    private var initialMark: ScopeMark?
    private var checkMarkDrag: String?
    private var pinAfter: Double?
    private var initialRefProbe: CGPoint?
    private var pinRefAfter: Double?
    private var initialPoints: [CGPoint]?
    private var initialRefPoints: [CGPoint]?
    private var checkClicks = false
    private var checkSourceSwitch: Int?
    private var printPluginCommand = false
    private var checkShiftClicks = false
    private var initialHold = false
    private var initialLUT: String?
    private var initialCurve: StopsTransfer?
    private var checkDividerDrag = false
    private var dragCheck = (index: 0, dx: 200.0)
    private var initialNoiseView: NoiseView?
    /// Preferences as they were before a run driven by command-line flags (self-tests, captures), put back on exit
    /// so those runs never change the user's settings. nil = not a scripted run.
    private var savedPrefs: [String: Any]??

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.migrateSettings()
        parseArguments()
        if CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }), let id = Bundle.main.bundleIdentifier {
            savedPrefs = .some(UserDefaults.standard.persistentDomain(forName: id))
        }

        do {
            main = try ScopesWindow(frame: NSRect(x: 0, y: 0, width: 1700, height: 1000))
        } catch {
            fatal("Metal setup failed: \(error)")
        }
        main.window.center()
        buildMenu()   // after the window: View item titles show the renderer's current modes
        main.gallery.onSelect = { [weak self] url in self?.openSnapshot(url) }
        main.rail.onComparison = { [weak self] in self?.main.setLayout(.comparison) }
        main.rail.onSingle = { [weak self] in self?.main.setLayout(.single) }
        main.rail.onSnapshot = { [weak self] in self?.takeSnapshot(nil) }
        main.rail.onGallery = { [weak self] in self?.toggleGallery(nil) }
        main.rail.onNoiseMeter = { [weak self] in self?.main.showNoiseMeter.toggle() }
        main.rail.onReadout = { [weak self] in self?.main.showReadout.toggle() }
        main.rail.onWipe = { [weak self] in self?.renderer.wipeEnabled.toggle(); self?.main.layoutLabels() }
        main.rail.onSkin = { [weak self] in self?.renderer.skinIsolation.toggle(); self?.main.layoutLabels() }
        main.rail.onPanel = { [weak self] p in self?.main.togglePanel(p) }
        main.gallery.onTakeSnapshot = { [weak self] in self?.takeSnapshot(nil) }
        main.gallery.onOpenFolder = { [weak self] in self?.showSnapshotsFolder(nil) }
        main.gallery.onTrash = { [weak self] url in self?.trashSnapshot(url) }
        main.view.onKey = { [weak self] in self?.handleKey($0) ?? false }
        main.view.enableImageDrops()
        // Videos always become the Source; images dropped on the Source picture too, elsewhere they become the Reference.
        main.view.onDropFiles = { [weak self] urls, point in
            guard let self, let url = urls.last else { return }
            if Self.isMovie(url) || main.isOverSourcePicture(point) { openSourceFile(url) } else { openSnapshot(url) }
        }
        main.setGalleryVisible(false)   // opens with G or View → Show Gallery
        main.show()
        // Offer the Resolve plugin once the window is up (skipped in the command-line test runs).
        if capturePrefix == nil && quitAfter == nil {
            DispatchQueue.main.async { PluginInstaller.offerIfNeeded() }
        }
        if printPluginCommand { print(PluginInstaller.installCommand() ?? "no bundled plugin", "| state:", PluginInstaller.state) }
        NSApp.activate(ignoringOtherApps: true)

        if let url = initialVideo { openSourceFile(url) }
        else if startOnCaptureDevice { connectCaptureDevice(nil) }
        else { connectUmbraLink(nil) }
        if let z = initialZoom { main.setZoom(renderer.live, z.0); main.setZoom(renderer.snapshot, z.1) }
        if let w = initialWave { renderer.waveMode = w }
        if let d = initialDither { renderer.ditherMode = d }
        if let m = initialLayout { main.setLayout(m) }
        renderer.live.probe = initialProbe
        if let p = initialRefProbe {
            // The Reference loads a moment after launch; probe it once it has a frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.renderer.snapshot.probe = p }
        }
        if let w = initialWipe { renderer.wipeEnabled = true; renderer.wipePosition = w }
        renderer.skinIsolation = initialSkin
        if initialVec2x { renderer.vecDouble = true }
        if initialAbout { showAbout(nil) }
        if let h = initialHidden { renderer.hiddenPanels = h; main.layoutLabels() }
        if let t = initialTab { renderer.toolTab = t; main.layoutLabels() }
        if let z = initialZoomPanel { renderer.zoomedPanel = z; main.layoutLabels() }
        if initialEnvelope { renderer.showEnvelope = true }
        if let m = initialMark { renderer.live.mark = m; main.layoutLabels() }
        if initialHold { renderer.peakHold = true; main.layoutLabels() }
        if let path = initialLUT {
            // After the library scan restores the saved LUT.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                let url = URL(fileURLWithPath: path)
                self?.main.setLUT(LUTLibrary.scan().first { $0.url == url }
                    ?? LUTEntry(maker: "File", camera: "", profile: url.deletingPathExtension().lastPathComponent, url: url))
            }
        }
        if let f = initialSeek {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                (self?.renderer.live.source as? SeekableSource)?.seek(toFrame: f)
            }
        }
        if let c = initialCurve { renderer.stopsTransfer = c }
        if let v = initialNoiseView { renderer.noiseView = v }
        if falseColorSnapshot { main.toggleFalseColorSource() }
        renderer.live.selection = initialSelections.live

        knownSnapshots = Set(store.list())
        main.gallery.reload(store.list())
        store.onChange = { [weak self] in self?.snapshotFolderChanged() }
        if let url = initialSnapshot { openSnapshot(url, reveal: false) }
        renderer.snapshot.selection = initialSelections.snapshot

        if let t = takeSnapshotAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.takeSnapshot(nil) }
        }
        if let prefix = capturePrefix {
            // Two captures a few seconds apart show the scopes following the source.
            for (i, t) in [3.0, 5.5].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                    guard let self else { return }
                    self.renderer.requestCapture(to: URL(fileURLWithPath: "\(prefix)_\(i + 1).png"), overlay: self.main.captureOverlay())
                    self.main.captureGallery(to: URL(fileURLWithPath: "\(prefix)_\(i + 1)_gallery.png"))
                    self.main.captureRail(to: URL(fileURLWithPath: "\(prefix)_\(i + 1)_rail.png"))
                    self.main.capturePlayerBar(to: URL(fileURLWithPath: "\(prefix)_\(i + 1)_player.png"))
                    self.main.captureLUTPanel(to: URL(fileURLWithPath: "\(prefix)_\(i + 1)_lut.png"))
                }
            }
        }
        if let t = pinAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                self?.main.pinTarget()
                print("points:", self?.renderer.live.points.compactMap { $0 } ?? [])
            }
        }
        if initialPoints != nil || initialRefPoints != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                for (ch, pts) in [(self.renderer.live, self.initialPoints), (self.renderer.snapshot, self.initialRefPoints)] {
                    guard let pts else { continue }
                    ch.points = (0..<ScopeTarget.maxCount).map { $0 < pts.count ? pts[$0] : nil }
                }
                self.main.layoutLabels()
            }
        }
        if let t = pinRefAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self else { return }
                self.main.pinTarget(from: self.renderer.snapshot)
            }
        }
        if checkClicks { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.runClickCheck() } }
        if checkShiftClicks { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.runClickCheck(shift: true) } }
        if let which = checkMarkDrag {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.runMarkDragCheck(which) }
        }
        if checkDividerDrag {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.runDividerDragCheck() }
        }
        if checkViewMenu {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runViewMenuCheck() }
        }
        if let n = checkSourceSwitch {
            // Fast capture ↔ Link switching (fix-11/14), starting on capture: an odd count ends on capture, an even
            // one on Link. The card is released each time and no source shows the other one's picture.
            for i in 0..<n {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(i) * 0.1) { [weak self] in
                    guard let self else { return }
                    if i % 2 == 0 { self.connectCaptureDevice(nil) } else { self.connectUmbraLink(nil) }
                    if i == n - 1 { print("source switch: \(n) switches, now \(self.renderer.live.source?.title ?? "none")") }
                }
            }
        }
        if let q = quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + q) { NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        main?.renderer.channels.forEach { $0.source = nil }
        restorePrefs()
    }

    private func restorePrefs() {
        guard case .some(let prefs) = savedPrefs, let id = Bundle.main.bundleIdentifier else { return }
        if let prefs { UserDefaults.standard.setPersistentDomain(prefs, forName: id) }
        else { UserDefaults.standard.removePersistentDomain(forName: id) }
        UserDefaults.standard.synchronize()
    }

    private func parseArguments() {
        var args = Array(CommandLine.arguments.dropFirst())
        func next() -> String? { args.isEmpty ? nil : args.removeFirst() }
        while let a = next() {
            switch a {
            case "--snapshot": initialSnapshot = next().map { URL(fileURLWithPath: $0) }
            case "--take-snapshot-after": takeSnapshotAfter = next().flatMap(Double.init)
            case "--zoom":
                if let a = next().flatMap(Float.init), let b = next().flatMap(Float.init) { initialZoom = (a / 100, b / 100) }
            case "--dither": initialDither = ["10": .tenBit, "8": .eightBit, "off": .off][next() ?? ""]
            case "--wave": initialWave = ["color": .color, "rgb": .rgb, "luma": .luma][next() ?? ""]
            case "--false-color-snapshot": falseColorSnapshot = true
            case "--select-live", "--select-snapshot":
                // x,y,w,h in picture fractions, optionally ",ellipse"
                if let spec = next() {
                    let parts = spec.split(separator: ",")
                    let n = parts.prefix(4).compactMap { Double($0) }
                    if n.count == 4 {
                        let sel = Selection(rect: CGRect(x: n[0], y: n[1], width: n[2], height: n[3]),
                                            shape: parts.count > 4 && parts[4] == "ellipse" ? .ellipse : .rectangle)
                        if a == "--select-live" { initialSelections.live = sel } else { initialSelections.snapshot = sel }
                    }
                }
            case "--capture": capturePrefix = next()
            case "--capture-input": startOnCaptureDevice = true   // live source from the first capture card
            case "--quit-after": quitAfter = next().flatMap(Double.init)
            case "--check-view-menu": checkViewMenu = true
            case "--layout": initialLayout = next().flatMap(LayoutMode.init)
            case "--probe":   // x,y in picture fractions
                if let v = next()?.split(separator: ",").compactMap({ Double($0) }), v.count == 2 { initialProbe = CGPoint(x: v[0], y: v[1]) }
            case "--probe-ref":   // x,y on the Reference picture
                if let v = next()?.split(separator: ",").compactMap({ Double($0) }), v.count == 2 { initialRefProbe = CGPoint(x: v[0], y: v[1]) }
            case "--wipe": initialWipe = next().flatMap(Double.init)
            case "--skin": initialSkin = true
            case "--about": initialAbout = true
            case "--vec2x": initialVec2x = true
            case "--seek": initialSeek = next().flatMap(Int.init)   // frame, a second after opening (player bar test)
            case "--lut": initialLUT = next()   // path of a LUT file, applied for this run
            case "--list-luts":
                for e in LUTLibrary.scan() { print("\(e.maker) | \(e.camera) | \(e.profile)") }
                exit(0)
            case "--envelope": initialEnvelope = true
            case "--check-mark-drag": checkMarkDrag = next()
            case "--check-clicks": checkClicks = true
            case "--check-source-switch": checkSourceSwitch = next().flatMap(Int.init)   // number of Link ↔ capture switches
            case "--print-plugin-install": printPluginCommand = true
            case "--check-shift-clicks": checkShiftClicks = true
            case "--pin-after": pinAfter = next().flatMap(Double.init)   // seconds; pins the Readout like T
            case "--pin-ref-after": pinRefAfter = next().flatMap(Double.init)   // seconds; pins the Reference's Readout
            case "--points", "--points-ref":   // x,y;x,y… (picture fractions), up to four
                let pts = (next() ?? "").split(separator: ";").compactMap { pair -> CGPoint? in
                    let v = pair.split(separator: ",").compactMap { Double($0) }
                    return v.count == 2 ? CGPoint(x: v[0], y: v[1]) : nil
                }
                if a == "--points" { initialPoints = pts } else { initialRefPoints = pts }
            case "--mark-wave", "--mark-vec":   // x0,x1,lo,hi (frame x, signal) or cb0,cb1,cr0,cr1
                if let v = next()?.split(separator: ",").compactMap({ Float($0) }), v.count == 4 {
                    initialMark = ScopeMark(kind: a == "--mark-wave" ? .waveform : .vectorscope, bounds: SIMD4(v[0], v[1], v[2], v[3]))
                }
            case "--peak-hold": initialHold = true
            case "--zoom-panel":   // livePicture, snapPicture, liveWave, snapWave, liveVec, snapVec, tool (full screen, not saved)
                initialZoomPanel = ["livePicture": .livePicture, "snapPicture": .snapPicture, "liveWave": .liveWave,
                                    "snapWave": .snapWave, "liveVec": .liveVec, "snapVec": .snapVec, "tool": .tool][next() ?? ""]
            case "--tool-tab": initialTab = next().flatMap(Int.init).flatMap(ToolTab.init)
            case "--hide-panels":   // e.g. 0,2 = waveform and tool slot (0 waveform, 1 vectorscope, 2 tool slot); not saved
                initialHidden = Set((next() ?? "").split(separator: ",").compactMap { Int($0).flatMap(ScopePanel.init) })
            case "--stops-curve": initialCurve = next().flatMap(UInt32.init).flatMap(StopsTransfer.init)
            case "--check-divider-drag":
                // optional: divider index and distance in points, e.g. --check-divider-drag 2 -150
                checkDividerDrag = true
                if let i = args.first.flatMap(Int.init) { _ = next(); dragCheck.index = i }
                if let dx = args.first.flatMap(Double.init) { _ = next(); dragCheck.dx = dx }
            case "--noise-view": initialNoiseView = ["luma": .luma, "chroma": .chroma][next() ?? ""]
            case _ where a.hasPrefix("-"): break   // ignore AppKit's -NSDocumentRevisionsDebugMode etc.
            default: initialVideo = URL(fileURLWithPath: a)
            }
        }
    }

    // MARK: - sources

    @objc func connectUmbraLink(_ sender: Any?) {
        renderer.live.source = nil  // stop the old source first (releases the capture card)
        renderer.live.source = LinkSource(device: renderer.device)
        main.layoutLabels()
    }

    /// Live input from a capture card (HDMI-to-USB UVC) or camera; ⌘2 picks the first external device.
    @objc func connectCaptureDevice(_ sender: Any?) {
        let devices = CaptureSource.devices()
        let wanted = (sender as? NSMenuItem)?.representedObject as? String
        guard let device = devices.first(where: { $0.uniqueID == wanted }) ?? devices.first else {
            let alert = NSAlert()
            alert.messageText = "No capture device found"
            alert.informativeText = "Connect a USB capture card (UVC) and try again."
            alert.beginSheetModal(for: main.window)
            return
        }
        renderer.live.source = nil  // stop the old source first (releases the capture card)
        renderer.live.source = CaptureSource(device: device, metal: renderer.device)
        main.layoutLabels()
    }

    static func isMovie(_ url: URL) -> Bool {
        if FileDecodeSource.extensions.contains(url.pathExtension.lowercased()) { return true }
        return (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .movie) ?? false
    }

    /// Analyses a file from the Finder instead of the Resolve plugin. QuickTime/MP4 go through AVFoundation;
    /// BRAW, MXF (XAVC, XDCAM…) and other containers through FFmpeg or the Blackmagic RAW SDK; images are stills.
    private func openSourceFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        do {
            if FileDecodeSource.extensions.contains(ext) {
                renderer.live.source = try FileDecodeSource(url: url, device: renderer.device)
            } else if Self.isMovie(url) {
                renderer.live.source = VideoSource(url: url, device: renderer.device)
            } else {
                renderer.live.source = try StillImageSource(url: url, device: renderer.device)
            }
        } catch {
            NSSound.beep()
            let alert = NSAlert()
            alert.messageText = "Could not open \(url.lastPathComponent)"
            var text = error.localizedDescription
            if ["r3d", "ari"].contains(ext) || (ext == "mxf" && text.contains("decoder")) {
                text += "\n\nSony RAW/X-OCN, RED and ARRIRAW need their manufacturers' SDKs. "
                    + "Open the clip in DaVinci Resolve and analyse it through the Umbra Link node instead."
            }
            alert.informativeText = text
            alert.beginSheetModal(for: main.window)
            print("could not open \(url.path): \(error.localizedDescription)")
        }
        main.layoutLabels()
    }


    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image] + FileDecodeSource.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a video or an image to analyse as the Source"
        panel.beginSheetModal(for: main.window) { [weak self] r in
            if r == .OK, let url = panel.url { self?.openSourceFile(url) }
        }
    }

    // MARK: - snapshots

    /// Saves the live frame to the snapshots folder and shows it in the Snapshot column.
    @objc func takeSnapshot(_ sender: Any?) {
        let lut = renderer.lutActive ? main.lutEntry.map { "LUT \($0.displayName)" } : nil
        let label = [renderer.live.source?.title, timecode(of: renderer.live.frameInfo), lut].compactMap { $0 }.joined(separator: " ")
        renderer.saveSnapshot(label: label) { [weak self] result in
            switch result {
            case .success(let url):
                print("snapshot \(url.path)")
                self?.knownSnapshots.insert(url)
                self?.openSnapshot(url, reveal: false)
            case .failure(let error):
                NSSound.beep()
                print("snapshot failed: \(error.localizedDescription)")
            }
        }
    }

    @objc func openSnapshotPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.directoryURL = store.folder
        panel.beginSheetModal(for: main.window) { [weak self] r in
            if r == .OK, let url = panel.url { self?.openSnapshot(url) }
        }
    }

    @objc func openSnapshotItem(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { openSnapshot(url) }
    }

    @objc func clearSnapshot(_ sender: Any?) {
        renderer.snapshot.clear()
        main.gallery.current = nil
        main.layoutLabels()
    }

    @objc func showSnapshotsFolder(_ sender: Any?) {
        NSWorkspace.shared.open(store.folder)
    }

    @objc func toggleAutoOpen(_ sender: NSMenuItem) {
        autoOpenNewImages.toggle()
    }

    /// Moves an image from the gallery to the Trash (recoverable from there).
    private func trashSnapshot(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if main.gallery.current == url { clearSnapshot(nil) }
            refreshGallery()
        } catch {
            NSSound.beep()
            print("could not move \(url.path) to the Trash: \(error.localizedDescription)")
        }
    }

    private func refreshGallery() {
        main.gallery.reload(store.list())
    }

    @objc func toggleZoomedPanel(_ sender: Any?) {
        main.toggleZoomedPanel()
    }

    @objc func toggleGallery(_ sender: Any?) {
        main.setGalleryVisible(!main.isGalleryVisible)
    }

    private func stepSnapshot(_ step: Int) {
        if let url = main.gallery.neighbour(step) { openSnapshot(url) }
    }


    /// Loads an image as the Reference. `reveal` switches a Single layout to Comparison so it can be seen;
    /// a snapshot taken with S doesn't, it just lands in the gallery.
    func openSnapshot(_ url: URL, reveal: Bool = true) {
        do {
            renderer.snapshot.source = try StillImageSource(url: url, device: renderer.device)
            main.gallery.current = url
            if reveal { main.setLayout(.comparison) }
            main.layoutLabels()
        } catch {
            NSSound.beep()
            print("could not open \(url.path): \(error.localizedDescription)")
        }
    }

    /// Images that appear in the folder (copied there by you, not taken by the app) open in the Snapshot column.
    private func snapshotFolderChanged() {
        refreshGallery()
        let now = Set(store.list())
        let added = now.subtracting(knownSnapshots)
        knownSnapshots = now
        guard autoOpenNewImages, let newest = added.sorted(by: { $0.path < $1.path }).last else { return }
        // Give the copy a moment to finish writing before reading it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.openSnapshot(newest) }
    }

    private func timecode(of info: String) -> String? {
        info.split(separator: " ").last.map(String.init).flatMap { $0.contains(":") ? $0 : nil }
    }

    // MARK: - keys & menus

    /// Every keyboard command, in View-menu order. The menu and the key handler are both built from this list,
    /// so a shortcut always appears in the menu next to what it does.
    private struct ViewCommand {
        var section: String
        var title: () -> String
        var key: String                  // menu key equivalent (no modifier)
        var keyCodes: [UInt16]           // physical keys accepted when the menu doesn't see the event
        var isOn: (() -> Bool)? = nil    // checkmark for toggles
        var run: () -> Void
    }

    private lazy var viewCommands: [ViewCommand] = {
        let arrow = { (k: Int) in String(Character(UnicodeScalar(UInt16(k))!)) }
        return [
            ViewCommand(section: "Layout", title: { "Single (Source only)" }, key: "1", keyCodes: [18],
                        isOn: { [unowned self] in main.layoutMode == .single }) { [unowned self] in main.setLayout(.single) },
            ViewCommand(section: "Layout", title: { "Comparison (Source × Reference)" }, key: "2", keyCodes: [19],
                        isOn: { [unowned self] in main.layoutMode == .comparison }) { [unowned self] in main.setLayout(.comparison) },
            panelCommand(.waveform, key: "3", keyCode: 20),
            panelCommand(.vectorscope, key: "4", keyCode: 21),
            panelCommand(.tools, key: "5", keyCode: 23),
            toolTabCommand(.hml, key: "6", keyCode: 22),
            toolTabCommand(.stops, key: "7", keyCode: 26),
            toolTabCommand(.falseColor, key: "8", keyCode: 28),
            ViewCommand(section: "Tool Slot",
                        title: { [unowned self] in "Tool Slot Analyses: \(renderer.toolShowsSnapshot ? "Reference" : "Source") (Comparison)" },
                        key: "f", keyCodes: [3]) { [unowned self] in main.toggleFalseColorSource() },
            ViewCommand(section: "Waveform", title: { [unowned self] in "Waveform Mode: \(renderer.waveMode.title)" },
                        key: "w", keyCodes: [13]) { [unowned self] in main.nextWaveformMode() },
            ViewCommand(section: "Waveform", title: { [unowned self] in "Smoothing: \(renderer.ditherMode.title)" },
                        key: "d", keyCodes: [2]) { [unowned self] in main.nextDitherMode() },
            ViewCommand(section: "Waveform", title: { "Min/Max Envelope" }, key: "e", keyCodes: [14],
                        isOn: { [unowned self] in renderer.showEnvelope }) { [unowned self] in renderer.showEnvelope.toggle() },
            ViewCommand(section: "Waveform", title: { "Peak Hold" }, key: "h", keyCodes: [4],
                        isOn: { [unowned self] in renderer.peakHold }) { [unowned self] in renderer.peakHold.toggle(); main.layoutLabels() },
            ViewCommand(section: "Waveform", title: { "Reset Peak Hold" }, key: "z", keyCodes: [6]) {
                [unowned self] in renderer.resetPeakHold() },
            ViewCommand(section: "Waveform", title: { "Brighter Traces" }, key: arrow(NSUpArrowFunctionKey), keyCodes: [126]) {
                [unowned self] in renderer.gainScale *= 1.25 },
            ViewCommand(section: "Waveform", title: { "Dimmer Traces" }, key: arrow(NSDownArrowFunctionKey), keyCodes: [125]) {
                [unowned self] in renderer.gainScale /= 1.25 },
            ViewCommand(section: "Vectorscope", title: { "Zoom In" }, key: "=", keyCodes: [24, 69]) {
                [unowned self] in main.zoomUnderPointer(by: 1.25) },
            ViewCommand(section: "Vectorscope", title: { "Zoom Out" }, key: "-", keyCodes: [27, 78]) {
                [unowned self] in main.zoomUnderPointer(by: 1 / 1.25) },
            ViewCommand(section: "Vectorscope", title: { "Zoom 100%" }, key: "0", keyCodes: [29, 82]) {
                [unowned self] in main.zoomUnderPointer(reset: true) },
            ViewCommand(section: "Noise", title: { [unowned self] in "Noise View: \(renderer.noiseView.title)" },
                        key: "n", keyCodes: [45]) { [unowned self] in main.nextNoiseView() },
            ViewCommand(section: "Noise", title: { "Show Noise Meter" }, key: "m", keyCodes: [46],
                        isOn: { [unowned self] in main.showNoiseMeter }) { [unowned self] in main.showNoiseMeter.toggle() },
            ViewCommand(section: "Selection", title: { "Clear Selection and Probe" }, key: "\u{1b}", keyCodes: [53]) {
                [unowned self] in if !main.exitZoomedPanel() { main.clearSelectionUnderPointer() } },
            ViewCommand(section: "Tools", title: { "Readout" }, key: "r", keyCodes: [15],
                        isOn: { [unowned self] in main.showReadout }) { [unowned self] in main.showReadout.toggle() },
            ViewCommand(section: "Tools", title: { "Wipe Source / Reference (Single)" }, key: "x", keyCodes: [7],
                        isOn: { [unowned self] in renderer.wipeEnabled }) { [unowned self] in renderer.wipeEnabled.toggle(); main.layoutLabels() },
            ViewCommand(section: "Tools", title: { "Skin Tone Isolation" }, key: "k", keyCodes: [40],
                        isOn: { [unowned self] in renderer.skinIsolation }) { [unowned self] in renderer.skinIsolation.toggle(); main.layoutLabels() },
            ViewCommand(section: "Vectorscope", title: { "Show 2x Zoom" }, key: "v", keyCodes: [9],
                        isOn: { [unowned self] in renderer.vecDouble }) { [unowned self] in renderer.vecDouble.toggle(); main.layoutLabels() },
            ViewCommand(section: "Tools", title: { [unowned self] in "Stops Curve: \(renderer.stopsTransfer.title)" }, key: "l", keyCodes: [37]) {
                [unowned self] in renderer.stopsTransfer = renderer.stopsTransfer.next; main.layoutLabels() },
            ViewCommand(section: "LUT", title: { [unowned self] in "Apply LUT (Single)" + (main.lutEntry.map { ": \($0.displayName)" } ?? "") },
                        key: "u", keyCodes: [32], isOn: { [unowned self] in renderer.lutEnabled }) {
                [unowned self] in main.setLUTEnabled(!renderer.lutEnabled) },
            ViewCommand(section: "Points", title: { "Pin Probe as Point (Shift-click adds one)" }, key: "t", keyCodes: [17]) {
                [unowned self] in main.pinTarget() },
            ViewCommand(section: "Points", title: { [unowned self] in "Clear Points (\(renderer.targets.count))" },
                        key: "\u{8}", keyCodes: [51]) { [unowned self] in main.clearPoints() },
            ViewCommand(section: "Snapshots", title: { "Take Snapshot" }, key: "s", keyCodes: [1]) {
                [unowned self] in takeSnapshot(nil) },
            ViewCommand(section: "Snapshots", title: { "Previous Snapshot" }, key: arrow(NSLeftArrowFunctionKey), keyCodes: [123]) {
                [unowned self] in stepSnapshot(-1) },
            ViewCommand(section: "Snapshots", title: { "Next Snapshot" }, key: arrow(NSRightArrowFunctionKey), keyCodes: [124]) {
                [unowned self] in stepSnapshot(1) },
            ViewCommand(section: "Snapshots", title: { "Show Gallery" }, key: "g", keyCodes: [5],
                        isOn: { [unowned self] in main.isGalleryVisible }) { [unowned self] in toggleGallery(nil) },
            ViewCommand(section: "Playback (video file)", title: { "Play / Pause" }, key: " ", keyCodes: [49]) {
                [unowned self] in renderer.live.source?.togglePlay() },
            ViewCommand(section: "Playback (video file)", title: { "Previous Frame" }, key: ",", keyCodes: [43]) {
                [unowned self] in stepSource(-1) },
            ViewCommand(section: "Playback (video file)", title: { "Next Frame" }, key: ".", keyCodes: [47]) {
                [unowned self] in stepSource(1) },
        ]
    }()

    private func toolTabCommand(_ t: ToolTab, key: String, keyCode: UInt16) -> ViewCommand {
        ViewCommand(section: "Tool Slot", title: { t.title }, key: key, keyCodes: [keyCode],
                    isOn: { [unowned self] in renderer.toolTab == t }) { [unowned self] in main.selectToolTab(t) }
    }

    private func panelCommand(_ p: ScopePanel, key: String, keyCode: UInt16) -> ViewCommand {
        ViewCommand(section: "Panels", title: { p.title }, key: key, keyCodes: [keyCode],
                    isOn: { [unowned self] in !renderer.hiddenPanels.contains(p) }) { [unowned self] in main.togglePanel(p) }
    }

    /// Mouse and trackpad gestures, listed in the View menu for reference (they can't be menu shortcuts).
    private let gestureHints = [
        "Drag on a picture: select an area (⌥ for an ellipse)",
        "Click on a picture: measure that point (readout); Esc clears",
        "Drag the wipe line (Single, X on): move the Source / Reference split",
        "Drag on a waveform or vectorscope: highlight those pixels in the picture (click or Esc clears)",
        "Shift-click a picture: add a point (S1–S4 on the Source, R1–R4 on the Reference); Shift-click a point: remove it",
        "Noise meter: select a flat area (sky, wall, grey card)",
        "Scroll or pinch on a vectorscope: zoom it",
        "Double-click a vectorscope: back to 100%",
        "Drop a file on the Source picture: analyse it as Source",
        "Drop images elsewhere or in the folder: load as Reference",
    ]

    /// The app's identifier changed from the prototype's; carry its saved settings over once.
    private static func migrateSettings() {
        let old = "local.scopes.prototype", d = UserDefaults.standard
        guard old != Bundle.main.bundleIdentifier, let saved = d.persistentDomain(forName: old) else { return }
        for (key, value) in saved where d.object(forKey: key) == nil { d.set(value, forKey: key) }
        d.removePersistentDomain(forName: old)
    }

    private func stepSource(_ frames: Int) {
        (renderer.live.source as? VideoSource)?.step(frames)
        (renderer.live.source as? FileDecodeSource)?.step(frames)
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        guard e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let cmd = viewCommands.first(where: { $0.keyCodes.contains(e.keyCode) }) else { return false }
        cmd.run()
        return true
    }

    @objc private func runViewCommand(_ sender: NSMenuItem) {
        viewCommands[sender.tag].run()
    }

    /// Development check (--check-clicks): clicks the Source, then the Reference, through the real mouse handlers
    /// and prints both probes.
    private func runClickCheck(shift: Bool = false) {
        let l = renderer.layout
        for (rect, f) in [(l.live.picture, CGPoint(x: 0.37, y: 0.62)), (l.snapshot.picture, CGPoint(x: 0.6, y: 0.4))] {
            let r = main.pointsRectPublic(rect)
            let p = main.view.convert(NSPoint(x: r.minX + r.width * f.x, y: r.maxY - r.height * f.y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: main.window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                type == .leftMouseDown ? main.view.mouseDown(with: e) : main.view.mouseUp(with: e)
            }
        }
        print("probes: source", renderer.live.probe.map { "\($0)" } ?? "none", "reference", renderer.snapshot.probe.map { "\($0)" } ?? "none")
        print("points: source", renderer.live.points.compactMap { $0 }, "reference", renderer.snapshot.points.compactMap { $0 })
    }

    /// Development check (--check-mark-drag wave|vec): drags across part of the live scope through the real mouse
    /// handlers and prints the mark it produced.
    private func runMarkDragCheck(_ which: String) {
        let l = renderer.layout
        let r = main.pointsRectPublic(which == "vec" ? l.live.vectorscope : l.live.waveform)
        let a = NSPoint(x: r.minX + r.width * 0.55, y: r.minY + r.height * 0.45)
        let b = NSPoint(x: r.minX + r.width * 0.75, y: r.minY + r.height * 0.75)
        func ev(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: main.view.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: main.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        main.view.mouseDown(with: ev(.leftMouseDown, a))
        for i in 1...8 {
            let t = CGFloat(i) / 8
            main.view.mouseDragged(with: ev(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
        }
        main.view.mouseUp(with: ev(.leftMouseUp, b))
        print("mark after drag:", renderer.live.mark.map { "\($0.kind) \($0.bounds)" } ?? "none")
    }

    /// Development check (--check-divider-drag [index] [points]): sends mouse events that drag a bottom-row
    /// divider (default: the first, 200 pt right) through the same handlers a real drag uses; prints the widths.
    private func runDividerDragCheck() {
        let widths = { [self] in renderer.layout.columns.map { Int($0.width / (main.window.backingScaleFactor)) } }
        print("columns before (pt):", widths())
        let dividers = main.dividerRects()
        guard dividers.indices.contains(dragCheck.index) else { return print("no such divider") }
        let d = dividers[dragCheck.index]
        let start = main.view.convert(NSPoint(x: d.midX, y: d.midY), to: nil)
        func ev(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: main.window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        main.view.mouseDown(with: ev(.leftMouseDown, start))
        let dx = CGFloat(dragCheck.dx)
        for step in 1...10 { main.view.mouseDragged(with: ev(.leftMouseDragged, NSPoint(x: start.x + dx * CGFloat(step) / 10, y: start.y))) }
        main.view.mouseUp(with: ev(.leftMouseUp, NSPoint(x: start.x + dx, y: start.y)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { print("columns after (pt): ", widths()) }
    }

    /// Development check (--check-view-menu): prints the View menu and sends each item's key, without modifiers,
    /// through the main menu the way AppKit does for a key press, reporting whether a menu item handled it.
    private func runViewMenuCheck() {
        menuNeedsUpdate(viewMenu)
        for item in viewMenu.items {
            if item.isSeparatorItem { print("  ----"); continue }
            let key = item.keyEquivalent
            let shown = key == " " ? "Space" : key == "\u{1b}" ? "Esc" : key.unicodeScalars.first.map { s -> String in
                switch Int(s.value) {
                case NSUpArrowFunctionKey: return "↑"
                case NSDownArrowFunctionKey: return "↓"
                case NSLeftArrowFunctionKey: return "←"
                case NSRightArrowFunctionKey: return "→"
                default: return key.uppercased()
                }
            } ?? ""
            print(String(format: "  %@%-48@ %@", item.indentationLevel > 0 ? "  " : "", item.title, shown))
        }
        let before = renderer.waveMode.title
        if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: main.window.windowNumber, context: nil, characters: "w",
                                     charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13) {
            let handled = NSApp.mainMenu?.performKeyEquivalent(with: ev) ?? false
            print("key W through the menu: handled=\(handled), waveform \(before) -> \(renderer.waveMode.title)")
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let item = pluginMenuItem, menu === item.menu {
            switch PluginInstaller.state {
            case .notInstalled: item.title = "Install DaVinci Resolve Plugin…"
            case .outdated: item.title = "Update DaVinci Resolve Plugin…"
            case .current: item.title = "Reinstall DaVinci Resolve Plugin (installed)…"
            case .unavailable: item.title = "DaVinci Resolve Plugin (missing from this copy)"
            }
        }
        if menu === viewMenu {
            // Titles show the current mode; toggles show a checkmark.
            for item in menu.items where item.action == #selector(runViewCommand(_:)) {
                let cmd = viewCommands[item.tag]
                item.title = cmd.title()
                item.state = cmd.isOn?() == true ? .on : .off
            }
            return
        }
        if menu === captureMenu {
            menu.removeAllItems()
            let devices = CaptureSource.devices()
            if devices.isEmpty {
                let empty = NSMenuItem(title: "No devices connected", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            }
            let current = renderer.live.source as? CaptureSource
            for device in devices {
                let item = NSMenuItem(title: device.localizedName, action: #selector(connectCaptureDevice(_:)), keyEquivalent: "")
                item.representedObject = device.uniqueID
                item.target = self
                item.state = current?.deviceID == device.uniqueID ? .on : .off
                menu.addItem(item)
            }
            return
        }
        guard menu === snapshotsMenu else { return }
        while menu.items.count > 7 { menu.removeItem(at: 7) }
        menu.item(at: 5)?.state = autoOpenNewImages ? .on : .off
        let recent = store.list().prefix(20)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No snapshots yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for url in recent {
            let item = NSMenuItem(title: url.deletingPathExtension().lastPathComponent, action: #selector(openSnapshotItem(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            menu.addItem(item)
        }
    }

    private var pluginMenuItem: NSMenuItem?

    @objc func installPlugin(_ sender: Any?) { PluginInstaller.install() }
    @objc func uninstallPlugin(_ sender: Any?) { PluginInstaller.uninstall() }
    private lazy var aboutWindow = AboutWindow()

    @objc func showAbout(_ sender: Any?) {
        aboutWindow.makeKeyAndOrderFront(nil)
    }

    @objc func showLicenses(_ sender: Any?) {
        if let url = Bundle.main.url(forResource: "Licenses", withExtension: nil) { NSWorkspace.shared.open(url) }
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(); mainMenu.addItem(item)
            let m = NSMenu(title: title); item.submenu = m
            return m
        }
        let appMenu = submenu("Umbra Scope")
        appMenu.delegate = self
        appMenu.addItem(withTitle: "About Umbra Scope", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        pluginMenuItem = appMenu.addItem(withTitle: "Install DaVinci Resolve Plugin…", action: #selector(installPlugin(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Uninstall DaVinci Resolve Plugin…", action: #selector(uninstallPlugin(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Licenses", action: #selector(showLicenses(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Umbra Scope", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let source = submenu("Source")
        source.addItem(withTitle: "Umbra Link Plugin (Resolve)", action: #selector(connectUmbraLink(_:)), keyEquivalent: "1")
        source.addItem(withTitle: "Capture Device", action: #selector(connectCaptureDevice(_:)), keyEquivalent: "2")
        let captureItem = source.addItem(withTitle: "Capture Devices", action: nil, keyEquivalent: "")
        captureMenu = NSMenu(title: "Capture Devices")
        captureMenu.delegate = self
        captureItem.submenu = captureMenu
        source.addItem(.separator())
        source.addItem(withTitle: "Open File as Source…", action: #selector(openDocument(_:)), keyEquivalent: "o")

        snapshotsMenu = submenu("Snapshots")
        snapshotsMenu.delegate = self
        snapshotsMenu.addItem(withTitle: "Take Snapshot", action: #selector(takeSnapshot(_:)), keyEquivalent: "s")
        let open = snapshotsMenu.addItem(withTitle: "Open Image…", action: #selector(openSnapshotPanel(_:)), keyEquivalent: "o")
        open.keyEquivalentModifierMask = [.command, .shift]
        snapshotsMenu.addItem(withTitle: "Clear Snapshot", action: #selector(clearSnapshot(_:)), keyEquivalent: "")
        snapshotsMenu.addItem(withTitle: "Show Snapshots Folder", action: #selector(showSnapshotsFolder(_:)), keyEquivalent: "")
        snapshotsMenu.addItem(.separator())
        snapshotsMenu.addItem(withTitle: "Load Images Added to the Folder", action: #selector(toggleAutoOpen(_:)), keyEquivalent: "")
        snapshotsMenu.addItem(.separator())

        // View: every keyboard command, grouped, with its key shown on the right; then the mouse gestures.
        viewMenu = submenu("View")
        viewMenu.delegate = self
        var section = ""
        for (i, cmd) in viewCommands.enumerated() {
            if cmd.section != section {
                if !section.isEmpty { viewMenu.addItem(.separator()) }
                section = cmd.section
                let header = NSMenuItem(title: section, action: nil, keyEquivalent: "")
                header.isEnabled = false
                viewMenu.addItem(header)
            }
            let item = NSMenuItem(title: cmd.title(), action: #selector(runViewCommand(_:)), keyEquivalent: cmd.key)
            item.keyEquivalentModifierMask = []
            item.target = self
            item.tag = i
            item.indentationLevel = 1
            viewMenu.addItem(item)
        }
        viewMenu.addItem(.separator())
        let zoomItem = NSMenuItem(title: "Full Screen Panel", action: #selector(toggleZoomedPanel(_:)), keyEquivalent: "f")
        zoomItem.keyEquivalentModifierMask = [.command]
        zoomItem.target = self
        viewMenu.addItem(zoomItem)
        viewMenu.addItem(.separator())
        let mouse = NSMenuItem(title: "Mouse & Trackpad", action: nil, keyEquivalent: "")
        mouse.isEnabled = false
        viewMenu.addItem(mouse)
        for hint in gestureHints {
            let item = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = 1
            viewMenu.addItem(item)
        }

        let windowMenu = submenu("Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = mainMenu
    }

    private func fatal(_ msg: String) -> Never {
        FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
        // Opened from the Finder, the app would otherwise just vanish; scripted runs only get the stderr line.
        if savedPrefs == nil {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Umbra Scope needs a Metal GPU"
            alert.informativeText = msg
            alert.runModal()
        }
        restorePrefs()
        exit(1)
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
