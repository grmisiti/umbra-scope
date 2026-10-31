import AppKit
import ImageIO

/// Strip across the top of the window with every image in the snapshots folder. Clicking one loads it into the
/// Snapshot column; the folder itself is the gallery, so files added or removed in the Finder show up here.
final class GalleryBar: NSView {
    static let height: CGFloat = 112

    var onSelect: ((URL) -> Void)?
    var onTakeSnapshot: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onTrash: ((URL) -> Void)?

    /// Images in display order (newest first).
    private(set) var urls: [URL] = []
    /// The image loaded in the Snapshot column, highlighted in the strip.
    var current: URL? { didSet { updateHighlight(scrollIntoView: true) } }

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let empty = NSTextField(labelWithString: "")
    private var items: [URL: GalleryItem] = [:]
    private let thumbnails = ThumbnailCache()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Palette.ink.cgColor

        let snap = button("Snapshot", symbol: "camera", tip: "Save the live frame to the folder and load it (S)") { [weak self] in
            self?.onTakeSnapshot?()
        }
        let folder = button("Folder", symbol: "folder", tip: "Open the snapshots folder in the Finder") { [weak self] in
            self?.onOpenFolder?()
        }
        let buttons = NSStackView(views: [snap, folder])
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)

        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .allowed
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        empty.stringValue = "No images yet — press S, or put images in the folder (Folder button)."
        empty.textColor = NSColor.white.withAlphaComponent(0.45)
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)

        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.widthAnchor.constraint(equalToConstant: 96),
            scroll.leadingAnchor.constraint(equalTo: buttons.trailingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            doc.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            doc.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            stack.heightAnchor.constraint(equalTo: doc.heightAnchor, constant: -12),
            empty.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 8),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Rebuilds the strip from the folder listing, reusing items (and thumbnails) that are still there.
    func reload(_ newURLs: [URL]) {
        urls = newURLs
        var kept: [URL: GalleryItem] = [:]
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for url in newURLs {
            let item = items[url] ?? makeItem(url)
            kept[url] = item
            stack.addArrangedSubview(item)
        }
        items = kept
        empty.isHidden = !newURLs.isEmpty
        if let c = current, !newURLs.contains(c) { current = nil }
        updateHighlight(scrollIntoView: false)
    }

    /// The image before/after the current one (wrapping), for the arrow keys.
    func neighbour(_ step: Int) -> URL? {
        guard !urls.isEmpty else { return nil }
        guard let c = current, let i = urls.firstIndex(of: c) else { return urls.first }
        return urls[(i + step + urls.count) % urls.count]
    }

    private func makeItem(_ url: URL) -> GalleryItem {
        let item = GalleryItem(url: url)
        item.onClick = { [weak self] in self?.onSelect?(url) }
        item.onTrash = { [weak self] in self?.onTrash?(url) }
        thumbnails.thumbnail(for: url) { [weak item] image in item?.image = image }
        return item
    }

    private func updateHighlight(scrollIntoView: Bool) {
        for (url, item) in items { item.isCurrent = url == current }
        if scrollIntoView, let c = current, let item = items[c] {
            layoutSubtreeIfNeeded()
            item.scrollToVisible(item.bounds.insetBy(dx: -40, dy: 0))
        }
    }

    private func button(_ title: String, symbol: String, tip: String, action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.imagePosition = .imageLeading
        b.bezelStyle = .rounded
        b.controlSize = .regular
        b.toolTip = tip
        return b
    }
}

/// One thumbnail with its file name; highlighted when it is the image in the Snapshot column.
private final class GalleryItem: NSView {
    let url: URL
    var onClick: (() -> Void)?
    var onTrash: (() -> Void)?
    var image: NSImage? { didSet { imageView.image = image } }
    var isCurrent = false {
        didSet {
            layer?.borderColor = isCurrent ? Palette.purple.cgColor : Palette.hairline.cgColor
            layer?.borderWidth = isCurrent ? 2 : 1
            label.textColor = isCurrent ? .white : NSColor.white.withAlphaComponent(0.6)
        }
    }
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = Palette.raised.cgColor
        toolTip = url.lastPathComponent

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = url.deletingPathExtension().lastPathComponent
        label.font = .systemFont(ofSize: 10)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 148),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            imageView.bottomAnchor.constraint(equalTo: label.topAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        isCurrent = false

        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Load in Snapshot") { [weak self] in self?.onClick?() })
        menu.addItem(ClosureMenuItem(title: "Reveal in Finder") { [weak self] in
            if let url = self?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Move to Trash") { [weak self] in self?.onTrash?() })
        self.menu = menu
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Thumbnails decoded off the main thread with ImageIO, cached by file and modification date.
private final class ThumbnailCache {
    private var cache: [URL: (Date, NSImage)] = [:]
    private let queue = DispatchQueue(label: "gallery.thumbnails", qos: .userInitiated)

    func thumbnail(for url: URL, completion: @escaping (NSImage?) -> Void) {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let (date, image) = cache[url], date == modified { return completion(image) }
        queue.async { [weak self] in
            var image: NSImage?
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: 320,
               ] as CFDictionary) {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            DispatchQueue.main.async {
                if let image { self?.cache[url] = (modified, image) }
                completion(image)
            }
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class ClosureButton: NSButton {
    private var handler: () -> Void = {}
    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        handler = action
        target = self
        self.action = #selector(fire)
    }
    @objc private func fire() { handler() }
}

private final class ClosureMenuItem: NSMenuItem {
    private var handler: () -> Void = {}
    convenience init(title: String, action: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        handler = action
        target = self
    }
    @objc private func fire() { handler() }
}
