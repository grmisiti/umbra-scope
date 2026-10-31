import AppKit

/// Side panel left of the Source picture (Single layout): choose a LUT by maker → camera → profile, switch it on or
/// off, or open any .cube file. The LUT is applied before the scopes, so they read the converted picture.
final class LUTPanel: NSView {
    static let width: CGFloat = 220

    var onSelect: ((LUTEntry?) -> Void)?
    var onToggle: ((Bool) -> Void)?
    var onOpenFile: (() -> Void)?

    private var entries: [LUTEntry] = []
    private let title = NSTextField(labelWithString: "LUT")
    private let toggle = NSSwitch()
    private let maker = NSPopUpButton()
    private let camera = NSPopUpButton()
    private let profile = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private static let none = "None"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = Palette.raised.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Palette.hairline.cgColor

        title.attributedStringValue = NSAttributedString(string: "LUT", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: Palette.secondary, .kern: 1.5,
        ])
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.toolTip = "Apply the LUT to the picture and the scopes (U)"
        for (p, tip) in [(maker, "Maker"), (camera, "Camera / log format"), (profile, "Profile — what the LUT converts to")] {
            p.controlSize = .small
            p.font = .systemFont(ofSize: 11)
            p.target = self
            p.toolTip = tip
            (p.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle
        }
        maker.action = #selector(makerChanged)
        camera.action = #selector(cameraChanged)
        profile.action = #selector(profileChanged)
        let open = NSButton(title: "Open .cube…", target: self, action: #selector(openFile))
        open.controlSize = .small
        open.bezelStyle = .rounded
        open.font = .systemFont(ofSize: 11)
        status.font = .systemFont(ofSize: 10)
        status.textColor = Palette.secondary
        status.maximumNumberOfLines = 4

        let header = NSStackView(views: [title, NSView(), toggle])
        header.orientation = .horizontal
        let labels = ["Maker", "Camera", "Profile"].map { t -> NSTextField in
            let l = NSTextField(labelWithString: t.uppercased())
            l.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
            l.textColor = Palette.secondary.withAlphaComponent(0.8)
            return l
        }
        let stack = NSStackView(views: [header, labels[0], maker, labels[1], camera, labels[2], profile, open, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        for v in [header, maker, camera, profile] as [NSView] { stack.setCustomSpacing(10, after: v) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        var constraints = [
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ]
        for p in [maker, camera, profile] { constraints.append(p.widthAnchor.constraint(equalTo: stack.widthAnchor)) }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Fills the menus from the library and shows `current` (nil = none) and whether it is applied.
    func load(_ entries: [LUTEntry], current: LUTEntry?, enabled: Bool) {
        self.entries = entries
        toggle.state = enabled ? .on : .off
        fillMakers(select: current?.maker)
        fillCameras(select: current?.camera)
        fillProfiles(select: current?.profile)
        if let c = current, !entries.contains(c) { showExternal(c) }
    }

    func setEnabled(_ on: Bool) { toggle.state = on ? .on : .off }

    /// Shows `e` in the three menus (a file outside the library gets its own entry).
    func select(_ e: LUTEntry?) {
        guard let e, entries.contains(e) else {
            if let e { showExternal(e) } else { fillMakers(select: nil); fillCameras(select: nil); fillProfiles(select: nil) }
            return
        }
        fillMakers(select: e.maker)
        fillCameras(select: e.camera)
        fillProfiles(select: e.profile)
    }

    func setStatus(_ text: String) { status.stringValue = text }

    /// A file opened from disk (not in the library): shown as its own entry.
    func showExternal(_ e: LUTEntry) {
        for (p, t) in [(maker, e.maker), (camera, e.camera), (profile, e.profile)] {
            p.removeAllItems(); p.addItem(withTitle: t); p.selectItem(at: 0)
        }
    }

    private var makers: [String] { Array(NSOrderedSet(array: entries.map(\.maker))) as? [String] ?? [] }

    private func fillMakers(select: String?) {
        maker.removeAllItems()
        maker.addItem(withTitle: Self.none)
        maker.addItems(withTitles: makers)
        maker.selectItem(withTitle: select ?? Self.none)
    }

    private func fillCameras(select: String?) {
        camera.removeAllItems()
        let m = maker.titleOfSelectedItem ?? Self.none
        let cams = Array(NSOrderedSet(array: entries.filter { $0.maker == m }.map(\.camera))) as? [String] ?? []
        camera.addItems(withTitles: cams)
        camera.isEnabled = !cams.isEmpty
        if let s = select, cams.contains(s) { camera.selectItem(withTitle: s) }
    }

    private func fillProfiles(select: String?) {
        profile.removeAllItems()
        let m = maker.titleOfSelectedItem, c = camera.titleOfSelectedItem
        let names = entries.filter { $0.maker == m && $0.camera == c }.map(\.profile)
        profile.addItems(withTitles: names)
        profile.isEnabled = !names.isEmpty
        if let s = select, names.contains(s) { profile.selectItem(withTitle: s) }
    }

    private var selectedEntry: LUTEntry? {
        entries.first { $0.maker == maker.titleOfSelectedItem && $0.camera == camera.titleOfSelectedItem
            && $0.profile == profile.titleOfSelectedItem }
    }

    @objc private func makerChanged() {
        fillCameras(select: nil)
        fillProfiles(select: nil)
        onSelect?(selectedEntry)
    }

    @objc private func cameraChanged() {
        fillProfiles(select: nil)
        onSelect?(selectedEntry)
    }

    @objc private func profileChanged() { onSelect?(selectedEntry) }

    @objc private func toggled() { onToggle?(toggle.state == .on) }

    @objc private func openFile() { onOpenFile?() }
}
