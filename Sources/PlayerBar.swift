import AppKit

/// Transport under the Source picture when it is a video file: play/pause, a scrubber to drag through the clip,
/// and the timecode. Dragging pauses; letting go resumes if it was playing.
final class PlayerBar: NSView {
    static let height: CGFloat = 30

    var source: SeekableSource? {
        didSet {
            guard source !== oldValue else { return }
            timer?.invalidate()
            timer = nil
            if source != nil {
                timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.refresh() }
            }
            refresh()
        }
    }
    /// Whether the source has more than one frame (stills and photo RAW get no bar).
    var hasTimeline: Bool { (source?.frameCount ?? 0) > 1 }

    private let play = NSButton()
    private let slider = NSSlider()
    private let time = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var scrubbing = false
    private var resumeAfterScrub = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = Palette.ink.withAlphaComponent(0.6).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Palette.hairline.cgColor

        play.isBordered = false
        play.imagePosition = .imageOnly
        play.contentTintColor = Palette.text
        play.target = self
        play.action = #selector(togglePlay)
        play.toolTip = "Play / Pause (Space)"
        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.controlSize = .small
        slider.trackFillColor = Palette.purple
        slider.target = self
        slider.action = #selector(scrub(_:))
        slider.toolTip = "Drag to choose the frame (, and . step one frame)"
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = Palette.secondary
        time.alignment = .right
        for v in [play, slider, time] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            play.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            play.centerYAnchor.constraint(equalTo: centerYAnchor),
            play.widthAnchor.constraint(equalToConstant: 22),
            slider.leadingAnchor.constraint(equalTo: play.trailingAnchor, constant: 8),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            time.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 12),
            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            time.centerYAnchor.constraint(equalTo: centerYAnchor),
            time.widthAnchor.constraint(equalToConstant: 196),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { timer?.invalidate() }

    @objc private func togglePlay() {
        source?.togglePlay()
        refresh()
    }

    @objc private func scrub(_ sender: NSSlider) {
        guard let s = source else { return }
        switch NSApp.currentEvent?.type {
        case .leftMouseDown?:
            if !scrubbing { scrubbing = true; resumeAfterScrub = s.isPlaying }
        case .leftMouseUp?:
            scrubbing = false
        default:
            if !scrubbing { scrubbing = true; resumeAfterScrub = s.isPlaying }
        }
        s.seek(toFrame: Int(sender.doubleValue.rounded()))
        if !scrubbing && resumeAfterScrub { s.setPlaying(true) }
        refresh()
    }

    func refresh() {
        guard let s = source, hasTimeline else { return }
        let count = s.frameCount, frame = min(s.currentFrame, count - 1)
        slider.maxValue = Double(count - 1)
        if !scrubbing { slider.doubleValue = Double(frame) }
        let shown = scrubbing ? Int(slider.doubleValue.rounded()) : frame
        play.image = NSImage(systemSymbolName: s.isPlaying ? "pause.fill" : "play.fill", accessibilityDescription: "Play / Pause")
        time.stringValue = "\(timecode(shown, fps: s.framesPerSecond))  \(shown + 1)/\(count)"
    }

    private func timecode(_ frame: Int, fps: Double) -> String {
        let rate = max(1, Int(fps.rounded()))
        return String(format: "%02d:%02d:%02d:%02d", frame / (rate * 3600), frame / (rate * 60) % 60, frame / rate % 60, frame % rate)
    }
}
