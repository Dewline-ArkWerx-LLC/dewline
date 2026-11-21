import AppKit

/// The Move window, 480 by 300, shown alone when Dewline runs from a disk image or a translocated copy: the disk image's
/// picture again (the app, a Signal line, Applications), a title and one sentence, and Not Now and Move to Applications.
/// Return moves; Esc, Command-W and the close button are Not Now. Move copies the app, quits, opens the copy and ejects
/// the image, while the icon travels along the line into the folder.
@MainActor
final class MoveWindowController: NSWindowController, NSWindowDelegate {
    static let size = NSSize(width: 480, height: 300)
    private static var shown: MoveWindowController?

    private static let iconSize: CGFloat = 96
    private static let pictureY: CGFloat = 172
    private static let appX: CGFloat = 130
    private static let folderX: CGFloat = 350

    private let notNow: () -> Void
    private let picture = NSView()
    private let icon = NSImageView()
    private let folder = NSImageView()
    private let line = SignalLine()
    private let buttons = NSStackView()
    private var moving = false

    /// Shows the window, or brings it forward; `notNow` runs when it closes without a move.
    static func show(notNow: @escaping () -> Void = {}) {
        if let shown { return shown.showWindow(nil) }
        let controller = MoveWindowController(notNow: notNow)
        shown = controller
        controller.showWindow(nil)
    }

    /// The sentence under the title, for a disk image or a translocated copy, with a line more when the move goes to the
    /// home folder's Applications.
    static func sentence(translocated: Bool, home: Bool) -> String {
        (translocated ? "Dewline is running from a temporary copy." : "Dewline is running from the disk image.")
            + " Updates and agent hooks need it in Applications."
            + (home ? " This account can\u{2019}t change the main Applications folder, so Dewline goes in the one in your home folder." : "")
    }

    private init(notNow: @escaping () -> Void) {
        self.notNow = notNow
        let window = MoveWindow(
            contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Move Dewline to Applications"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        window.delegate = self
        window.onReturn = { [weak self] in self?.move() }
        window.onEscape = { [weak self] in self?.window?.performClose(nil) }
        window.contentView = content()
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("MoveWindowController is built in code")
    }

    private func content() -> NSView {
        let root = PaperView(frame: NSRect(origin: .zero, size: Self.size))
        let target = HookSetup.moveTarget()
        picture.frame = root.bounds
        picture.setAccessibilityElement(false)
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.frame = Self.iconFrame(midX: Self.appX)
        folder.image = NSWorkspace.shared.icon(forFile: target.deletingLastPathComponent().path)
        folder.imageScaling = .scaleProportionallyUpOrDown
        folder.frame = Self.iconFrame(midX: Self.folderX)
        line.frame = NSRect(x: Self.appX + Self.iconSize / 2 + 16, y: Self.pictureY - 8, width: Self.folderX - Self.appX - Self.iconSize - 32, height: 16)
        for view in [folder, line, icon] {
            view.setAccessibilityElement(false)
            picture.addSubview(view)
        }
        root.addSubview(picture)

        let title = NSTextField(labelWithString: "Move Dewline to Applications")
        title.font = .systemFont(ofSize: Chrome.size(.title3), weight: .semibold)
        title.textColor = Chrome.color(.ink)
        let translocated = HookSetup.translocatedOriginal(Bundle.main.bundleURL) != nil
        let sentence = NSTextField(wrappingLabelWithString: Self.sentence(translocated: translocated, home: !target.path.hasPrefix("/Applications/")))
        sentence.font = Chrome.label
        sentence.textColor = Chrome.color(.ink2)
        sentence.preferredMaxLayoutWidth = Self.size.width - 64
        let later = ChromeButton("Not Now") { [weak self] in self?.window?.performClose(nil) }
        let move = ChromeButton("Move to Applications", style: .filled) { [weak self] in self?.move() }
        buttons.setViews([later, move], in: .trailing)
        buttons.spacing = 8
        window?.setAccessibilityDefaultButton(move)
        window?.setAccessibilityCancelButton(later)
        for view in [title, sentence, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 176),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -32),
            sentence.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            sentence.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sentence.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        return root
    }

    /// The square an icon takes, centered on `midX` on the picture's line, from the window's bottom.
    private static func iconFrame(midX: CGFloat) -> NSRect {
        NSRect(x: midX - iconSize / 2, y: pictureY - iconSize / 2, width: iconSize, height: iconSize)
    }

    /// Return and Move to Applications: the buttons stop, the primary reads Moving…, and the icon goes into the folder
    /// while the copy runs. A refused or canceled move gives the buttons back.
    private func move() {
        guard !moving else { return }
        moving = true
        let views = buttons.views
        for case let button as ChromeButton in views { button.isEnabled = false }
        let busy = ChromeButton("Moving\u{2026}", style: .filled) {}
        busy.isEnabled = false
        buttons.setViews([views[0], busy], in: .trailing)
        HookSetup.moveToApplications(on: window, moving: { [weak self] in self?.travel() ?? .zero }) { [weak self] in
            guard let self else { return }
            moving = false
            for case let button as ChromeButton in views { button.isEnabled = true }
            buttons.setViews(views, in: .trailing)
            icon.alphaValue = 1
            icon.frame = Self.iconFrame(midX: Self.appX)
        }
    }

    /// The icon's trip along the line into the folder, 450 ms, fading over its last 150; under Reduce Motion it only
    /// fades, 150 ms. Returns how long it takes.
    private func travel() -> Duration {
        let calm = Motion.current == .calm
        let fade = { [icon] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                icon.animator().alphaValue = 0
            }
        }
        guard calm else {
            fade()
            return .milliseconds(150)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            icon.animator().frame = Self.iconFrame(midX: Self.folderX).insetBy(dx: Self.iconSize / 4, dy: Self.iconSize / 4)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { fade() } }
        return .milliseconds(450)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !moving
    }

    func windowWillClose(_ notification: Notification) {
        Self.shown = nil
        if !moving { notNow() }
    }
}

/// The Move window: Return moves and Esc is Not Now, as in an alert, wherever the focus is.
private final class MoveWindow: NSWindow {
    var onReturn: () -> Void = {}
    var onEscape: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
            onReturn()
        } else if event.keyCode == 53 {
            onEscape()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape()
    }
}

/// The disk image's line: 1.5 pt of Signal with round caps and an open chevron at its right end, never a filled arrow.
final class SignalLine: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        let y = bounds.midY
        path.move(to: NSPoint(x: 1, y: y))
        path.line(to: NSPoint(x: bounds.maxX - 1, y: y))
        let head: CGFloat = 9 / 2.squareRoot()
        path.move(to: NSPoint(x: bounds.maxX - 1 - head, y: y + head))
        path.line(to: NSPoint(x: bounds.maxX - 1, y: y))
        path.line(to: NSPoint(x: bounds.maxX - 1 - head, y: y - head))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        Chrome.color(.signal).setStroke()
        path.stroke()
    }
}
