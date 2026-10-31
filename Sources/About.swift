import AppKit

/// "About Umbra Scope": what the app is, that it is open source and in development, and where to reach the author.
final class AboutWindow: NSPanel {
    static let repo = URL(string: "https://github.com/grmisiti/umbra-scope")!
    static let issues = URL(string: "https://github.com/grmisiti/umbra-scope/issues")!

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 10),
                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        title = "About Umbra Scope"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = Palette.ink

        let logo = NSImageView()
        if let url = Bundle.main.url(forResource: "wordmark", withExtension: "png") { logo.image = NSImage(contentsOf: url) }
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.setAccessibilityLabel("Umbra Scope")
        logo.translatesAutoresizingMaskIntoConstraints = false

        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String).map { "VERSION \($0)" } ?? ""
        let versionLabel = Self.label(version, size: 10, color: Palette.secondary, mono: true, kern: 1.5)

        let body = Self.label("""
            Umbra Scope is a real-time video scope for macOS. Waveform, vectorscope, false colour, HML and stops, \
            fed by DaVinci Resolve, a capture card or a video file.

            It is open source and still in development. Feedback, bug reports and help are welcome. \
            Open an issue on GitHub to get in touch.
            """, size: 13, color: Palette.text)
        body.preferredMaxLayoutWidth = 360

        let repoLink = Self.link("github.com/grmisiti/umbra-scope", url: Self.repo)
        let issuesLink = Self.link("Feedback & help — GitHub Issues", url: Self.issues)

        let stack = NSStackView(views: [logo, versionLabel, body, repoLink, issuesLink])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(6, after: logo)
        stack.setCustomSpacing(22, after: versionLabel)
        stack.setCustomSpacing(20, after: body)
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 40, bottom: 36, right: 40)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView = stack
        NSLayoutConstraint.activate([
            logo.heightAnchor.constraint(equalToConstant: 48),
            logo.widthAnchor.constraint(equalTo: logo.heightAnchor, multiplier: logoAspect(logo.image)),
            stack.widthAnchor.constraint(equalToConstant: 440),
        ])
        layoutIfNeeded()
        center()
    }

    private func logoAspect(_ image: NSImage?) -> CGFloat {
        guard let s = image?.size, s.height > 0 else { return 2.7 }
        return s.width / s.height
    }

    private static func label(_ text: String, size: CGFloat, color: NSColor, mono: Bool = false, kern: CGFloat = 0) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: "")
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        l.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .medium) : NSFont.systemFont(ofSize: size),
            .foregroundColor: color, .kern: kern, .paragraphStyle: para,
        ])
        l.isSelectable = false
        return l
    }

    private static func link(_ text: String, url: URL) -> NSButton {
        let b = NSButton(title: text, target: nil, action: nil)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: Palette.purpleText,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        b.toolTip = url.absoluteString
        b.setAccessibilityRole(.link)
        b.target = LinkOpener.shared
        b.action = #selector(LinkOpener.open(_:))
        b.identifier = NSUserInterfaceItemIdentifier(url.absoluteString)
        return b
    }
}

private final class LinkOpener: NSObject {
    static let shared = LinkOpener()
    @objc func open(_ sender: NSButton) {
        if let s = sender.identifier?.rawValue, let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
