import AppKit

/// The 24 pt line under the editor column, on the chrome with a hairline above it, in SF 11 `ink2`: one message at a
/// time with its buttons, a problem's after a red octagon. With no message it is hidden and takes no height unless
/// `reserved`, so a message never moves the editor. With none, it shows `idle`, which a click copies. Results and
/// problems are read out to VoiceOver. Nothing in it blinks.
final class StatusBar: NSView {
    static let height: CGFloat = 24

    /// A line with its buttons. Other parts of the app post these: share requests, a terminal waiting on the note, a
    /// held save, an export's result and tracking problems.
    struct Message {
        enum Kind: Int, Comparable {
            // The one shown is the first that applies, in this order: what was just done, what is broken, what
            // someone waits on, what is asked once, then what is only worth knowing.
            case result, problem, request, setup, question, info

            static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        struct Action {
            let title: String
            let run: @MainActor (NSView) -> Void
        }

        /// Posting a message with the same id replaces it.
        let id: String
        let kind: Kind
        let text: String
        var actions: [Action] = []
        /// Gone at the next keystroke in the note, as an export's result is.
        var untilTyping = false
    }

    /// Shows `message` in `window`'s status bar, or in the main window's.
    static func post(_ message: Message, in window: NSWindow? = nil) {
        bar(in: window)?.post(message)
    }

    /// Takes the message with `id` out of `window`'s status bar, or the main window's.
    static func clear(_ id: String, in window: NSWindow? = nil) {
        bar(in: window)?.clear(id)
    }

    private static func bar(in window: NSWindow?) -> StatusBar? {
        ((window ?? NSApp.mainWindow)?.windowController as? MainWindowController)?.statusBar
    }

    /// Keeps the line's height with no message, as a folder window does.
    var reserved = false {
        didSet { if reserved != oldValue { rebuild() } }
    }
    /// Where the caret is in the note, "docs/spec.md:12:4", shown while no message is.
    var idle: String? {
        didSet { if idle != oldValue { rebuild() } }
    }
    private let line = NSStackView()
    private var messages: [Message] = []
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 0)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let rule = RuleLine()
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)
        line.spacing = 6
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightConstraint,
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            line.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Status")
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("StatusBar is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Chrome.color(.chrome).resolved(for: effectiveAppearance).cgColor
    }

    @objc private func themeDidChange() {
        needsDisplay = true
        rebuild()
    }

    func post(_ message: Message) {
        messages.removeAll { $0.id == message.id }
        messages.append(message)
        rebuild()
        if [.result, .problem].contains(message.kind) {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: message.text, .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
    }

    func clear(_ id: String) {
        guard messages.contains(where: { $0.id == id }) else { return }
        messages.removeAll { $0.id == id }
        rebuild()
    }

    /// The note took a keystroke: messages that last until then go.
    func typed() {
        guard messages.contains(where: \.untilTyping) else { return }
        messages.removeAll(where: \.untilTyping)
        rebuild()
    }

    /// The message on show: the first kind that applies, the latest of that kind.
    var shown: Message? {
        messages.enumerated().min { ($0.element.kind, -$0.offset) < ($1.element.kind, -$1.offset) }?.element
    }

    private func rebuild() {
        for view in line.arrangedSubviews { view.removeFromSuperview() }
        isHidden = shown == nil && idle == nil && !reserved
        heightConstraint.constant = isHidden ? 0 : Self.height
        guard let message = shown else {
            if let idle {
                let place = NSButton(title: idle, target: self, action: #selector(copyIdle))
                place.isBordered = false
                place.attributedTitle = NSAttributedString(string: idle, attributes: [.font: Chrome.status, .foregroundColor: Chrome.color(.ink2)])
                place.lineBreakMode = .byTruncatingHead
                place.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                place.toolTip = "Click to copy"
                line.addArrangedSubview(place)
            }
            return
        }
        if message.kind == .problem, let symbol = NSImage(systemSymbolName: "exclamationmark.octagon.fill", accessibilityDescription: "Problem") {
            let icon = NSImageView(image: symbol.withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) ?? symbol)
            icon.contentTintColor = .systemRed
            line.addArrangedSubview(icon)
        }
        let text = NSTextField(labelWithString: message.text)
        text.font = Chrome.status
        text.textColor = Chrome.color(.ink2)
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        line.addArrangedSubview(text)
        for action in message.actions {
            line.addArrangedSubview(ActionButton(action))
        }
    }

    @objc func copyIdle() {
        guard let idle else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(idle, forType: .string)
        post(.init(id: "place", kind: .result, text: "Copied \(idle)", untilTyping: true))
    }
}

/// A small push button in the status bar that runs its action.
private final class ActionButton: NSButton {
    private let run: @MainActor (NSView) -> Void

    init(_ action: StatusBar.Message.Action) {
        run = action.run
        super.init(frame: .zero)
        title = action.title
        bezelStyle = .push
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        target = self
        self.action = #selector(clicked)
    }

    required init?(coder: NSCoder) {
        fatalError("ActionButton is built in code")
    }

    @objc private func clicked() {
        run(self)
    }
}

/// A 1 pt hairline in the theme's rule color, horizontal unless a width constraint says otherwise.
final class RuleLine: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("RuleLine is built in code")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Chrome.color(.rule).resolved(for: effectiveAppearance).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc private func themeDidChange() {
        needsDisplay = true
    }
}
