import AppKit

/// Icon button of the side rail; `isActive` shows the purple selected state.
final class RailButton: NSButton {
    static let side: CGFloat = 38
    var isActive = false { didSet { restyle() } }
    private var handler: () -> Void = {}

    convenience init(symbol: String, tip: String, action: @escaping () -> Void) {
        self.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        imagePosition = .imageOnly
        isBordered = false
        toolTip = tip
        setAccessibilityLabel(tip)
        handler = action
        target = self
        self.action = #selector(fire)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: Self.side), heightAnchor.constraint(equalToConstant: Self.side)])
        restyle()
    }

    @objc private func fire() { handler() }

    /// Constraints size the frame itself (borderless buttons otherwise add insets around the 38 pt square).
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    private func restyle() {
        layer?.backgroundColor = isActive ? Palette.purple.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
        layer?.borderColor = isActive ? Palette.purple.withAlphaComponent(0.5).cgColor : NSColor.clear.cgColor
        contentTintColor = isActive ? Palette.purple : Palette.secondary
    }
}

/// Narrow column on the left with the ghost and every toggle: layouts, snapshots, the bottom-row panels and the
/// picture tools. Purple = on.
final class RailView: NSView {
    static let width: CGFloat = 68

    var onComparison: (() -> Void)?
    var onSingle: (() -> Void)?
    var onSnapshot: (() -> Void)?
    var onGallery: (() -> Void)?
    var onNoiseMeter: (() -> Void)?
    var onReadout: (() -> Void)?
    var onWipe: (() -> Void)?
    var onSkin: (() -> Void)?
    var onPanel: ((ScopePanel) -> Void)?

    private var comparison: RailButton!
    private var single: RailButton!
    private var gallery: RailButton!
    private var meter: RailButton!
    private var readout: RailButton!
    private var wipe: RailButton!
    private var skin: RailButton!
    private var panels: [ScopePanel: RailButton] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        let logo = NSImageView()
        if let url = Bundle.main.url(forResource: "ghost-outline", withExtension: "png") { logo.image = NSImage(contentsOf: url) }
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.setAccessibilityLabel("Umbra Scope")
        logo.translatesAutoresizingMaskIntoConstraints = false

        single = RailButton(symbol: "rectangle", tip: "Single — Source only (1)") { [weak self] in self?.onSingle?() }
        comparison = RailButton(symbol: "rectangle.split.2x1", tip: "Comparison — Source × Reference (2)") { [weak self] in self?.onComparison?() }
        let snapshot = RailButton(symbol: "camera", tip: "Take snapshot (S)") { [weak self] in self?.onSnapshot?() }
        gallery = RailButton(symbol: "square.grid.2x2", tip: "Snapshot gallery (G)") { [weak self] in self?.onGallery?() }
        let panelInfo: [(ScopePanel, String, String)] = [
            (.waveform, "waveform", "Waveform panel (3)"),
            (.vectorscope, "scope", "Vectorscope panel (4)"),
            (.tools, "rectangle.stack", "Tool slot — HML · Stops · False Color (5)"),
        ]
        for (p, symbol, tip) in panelInfo {
            panels[p] = RailButton(symbol: symbol, tip: tip) { [weak self] in self?.onPanel?(p) }
        }
        readout = RailButton(symbol: "eyedropper", tip: "Readout — click the picture to probe (R)") { [weak self] in self?.onReadout?() }
        wipe = RailButton(symbol: "rectangle.lefthalf.inset.filled", tip: "Wipe Source / Reference, Single (X)") { [weak self] in self?.onWipe?() }
        skin = RailButton(symbol: "person.crop.circle", tip: "Skin tone isolation (K)") { [weak self] in self?.onSkin?() }
        meter = RailButton(symbol: "aqi.medium", tip: "Noise meter (M)") { [weak self] in self?.onNoiseMeter?() }

        func separator() -> NSBox {
            let b = NSBox()
            b.boxType = .custom
            b.borderWidth = 0
            b.fillColor = Palette.hairline
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 24), b.heightAnchor.constraint(equalToConstant: 1)])
            return b
        }
        let sep1 = separator(), sep2 = separator(), sep3 = separator()
        var views: [NSView] = [logo, single, comparison, sep1, snapshot, gallery, sep2]
        for (p, _, _) in panelInfo { if let b = panels[p] { views.append(b) } }
        views += [sep3, readout, wipe, skin, meter] as [NSView]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(22, after: logo)
        for v in [comparison!, sep1, gallery!, sep2, panels[.tools]!, sep3] as [NSView] { stack.setCustomSpacing(10, after: v) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            logo.heightAnchor.constraint(equalToConstant: 30), logo.widthAnchor.constraint(equalToConstant: 30),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(layout: LayoutMode, galleryVisible: Bool, meterVisible: Bool, readout readoutOn: Bool, wipe wipeOn: Bool, skin skinOn: Bool,
                panels shown: Set<ScopePanel>) {
        comparison.isActive = layout == .comparison
        single.isActive = layout == .single
        gallery.isActive = galleryVisible
        meter.isActive = meterVisible
        readout.isActive = readoutOn
        wipe.isActive = wipeOn
        skin.isActive = skinOn
        for (p, b) in panels { b.isActive = shown.contains(p) }
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.ink.setFill()
        bounds.fill()
        Palette.hairline.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}
