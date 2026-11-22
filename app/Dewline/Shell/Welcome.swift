import AppKit
import MdCore

/// Welcome.md: the bundled guide, written once into Dewline's own folder in Application Support, where it is a note
/// like any other.
@MainActor
enum Welcome {
    /// True once the guide has started, on any launch; upgraded copies carry it from their first launch.
    static let shownKey = "DewlineWelcomeShown"
    /// The demo's two edits: a word it swaps in the paragraph under the link, and the paragraph it inserts after the one
    /// that says what Keep and Revert do.
    static let replaced = "edits a note,"
    static let replacement = "edits a file,"
    static let anchor = "Revert puts the old text back.\n"
    static let inserted = "\nThis paragraph arrived the way an agent\u{2019}s edit does: written to the file while the note was open. "
        + "With hooks set up, the stamp reads CLAUDE CODE, CODEX or CURSOR.\n"

    /// Whether this launch runs the guide: never once it has started, and not on a launch that opens a file, which
    /// opens that file alone and leaves the guide for the next plain launch.
    static func due(opensFile: Bool, defaults: UserDefaults = .standard) -> Bool {
        !opensFile && !defaults.bool(forKey: shownKey)
    }

    static var bundled: URL {
        Bundle.main.url(forResource: "Welcome", withExtension: "md")!
    }

    /// Dewline's own folder, which holds its snapshots too.
    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "dev.arkwerx.dewline", directoryHint: .isDirectory)
    }

    static func url(in folder: URL = folder) -> URL {
        folder.appending(path: "Welcome.md")
    }

    /// Writes the bundled guide into `folder` unless a Welcome.md is already there; true when it wrote one.
    @discardableResult
    static func write(in folder: URL = folder) throws -> Bool {
        let url = url(in: folder)
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(contentsOf: bundled).write(to: url, options: .withoutOverwriting)
        return true
    }
}

/// The guide's demo: the demo writer swaps a word in the first paragraph and inserts a paragraph below the one that says
/// what Keep and Revert do, through the change engine, claimed as an agent's hooks claim a write, so two changes land
/// marked with Keep and Revert where the reader is looking.
@MainActor
final class WelcomeDemo {
    private static var running: WelcomeDemo?

    private weak var document: MarkdownDocument?
    private let url: URL
    private var start: Task<Void, Never>?

    private init(_ document: MarkdownDocument, url: URL) {
        self.document = document
        self.url = url
    }

    static func play(_ document: MarkdownDocument, at url: URL, after delay: Duration = .milliseconds(400)) {
        running?.stop()
        let demo = WelcomeDemo(document, url: url)
        running = demo
        demo.start = Task { [weak demo] in
            // Long enough to see the paragraph change once the note is in view.
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            demo?.write()
            if running === demo { running = nil }
        }
    }

    private func stop() {
        start?.cancel()
        if Self.running === self { Self.running = nil }
    }

    /// Stops a demo that hasn't written yet.
    static func cancel() {
        running?.stop()
    }

    /// Takes the demo's two edits back out of the note in `textView`, as edits of the reader's own, so it can play again:
    /// its open changes are kept first, then the swapped word goes back and the inserted paragraph goes.
    @discardableResult
    static func takeBack(_ textView: EditorTextView, live: LiveFile?) -> Bool {
        if let live { live.decide(Array(marks(in: live).keys), keep: true) }
        let text = textView.string as NSString
        let paragraph = text.range(of: Welcome.anchor + Welcome.inserted)
        var edited = false
        if paragraph.location != NSNotFound {
            edited = true
            textView.replaceAsOneEdit(NSRange(location: NSMaxRange(paragraph) - (Welcome.inserted as NSString).length, length: (Welcome.inserted as NSString).length), with: "")
        }
        let anchor = (textView.string as NSString).range(of: Welcome.anchor)
        let word = (textView.string as NSString).range(of: Welcome.replacement)
        if word.location != NSNotFound, anchor.location == NSNotFound || word.location < anchor.location {
            edited = true
            textView.replaceAsOneEdit(word, with: Welcome.replaced)
        }
        return edited
    }

    /// The demo's open changes in `live`.
    static func marks(in live: LiveFile) -> [UInt64: LiveFile.Change] {
        live.changes.filter { if case .agent(.demo, _) = $0.value.origin { $0.value.marked } else { false } }
    }

    /// The demo's claimed write: PreToolUse with the bytes it declares, the write, PostToolUse, then the turn's end.
    private func write() {
        guard let engine = document?.live?.engine, let before = try? Data(contentsOf: url),
            let real = realpath(url.path, nil)
        else { return }
        let path = String(cString: real)
        free(real)
        let text = String(decoding: before, as: UTF8.self)
        guard let replaced = text.range(of: Welcome.replaced), let anchor = text.range(of: Welcome.anchor), replaced.upperBound <= anchor.lowerBound,
            !text.contains(Welcome.inserted)
        else { return }
        let edited = text[..<replaced.lowerBound] + Welcome.replacement + text[replaced.upperBound..<anchor.upperBound] + Welcome.inserted
            + text[anchor.upperBound...]
        let after = Data(edited.utf8)
        let id = UUID().uuidString
        func claim(_ event: ControlSocket.Claim.Event) {
            LiveFile.claim(ControlSocket.Claim(vendor: .demo, session: "welcome", event: event), engine: engine)
        }
        claim(.preToolUse(.init(id: id, tool: .write, path: path, hash: Self.hex(before), declared: Self.hex(after))))
        guard (try? after.write(to: url)) != nil else { return }
        claim(.postToolUse(.init(id: id, tool: .write, path: path, hash: Self.hex(after), declared: nil)))
        claim(.turnEnd)
    }

    private static func hex(_ data: Data) -> String {
        contentHash(data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The first-run guide in the real editor: one island docked at the bottom center of Welcome.md's editor that plays the
/// demo, asks for one Revert and one Keep, then offers the setup list. It is never modal and never takes the focus;
/// Skip, typing in the note, closing the window or opening another note ends it, keeping the demo's open changes.
@MainActor
final class WelcomeGuide {
    enum Beat: Int {
        case watch, revert, keep, done, setup
    }

    private(set) static var running: WelcomeGuide?

    private weak var controller: MainWindowController?
    private weak var document: MarkdownDocument?
    private weak var textView: EditorTextView?
    private(set) var beat = Beat.watch
    /// The demo's two changes once they land, top to bottom: the swapped word, then the new paragraph.
    private(set) var demo: [UInt64] = []
    let island = GuideIsland()
    private var observers: [NSObjectProtocol] = []
    private var keys: Any?
    /// The text view's next key view before the island joined the loop.
    private weak var after: NSView?
    private var rows: [SetupRow] = []

    private init(_ controller: MainWindowController, document: MarkdownDocument, textView: EditorTextView) {
        self.controller = controller
        self.document = document
        self.textView = textView
    }

    /// Plays the guide on `document`, Welcome.md at `url`, open in `controller`: the last demo's edits come back out,
    /// then the demo writes `delay` later. Marks the welcome shown, so no later launch starts it on its own.
    @discardableResult
    static func start(
        in controller: MainWindowController, document: MarkdownDocument, url: URL, defaults: UserDefaults = .standard,
        delay: Duration = .milliseconds(1200)
    ) -> WelcomeGuide? {
        running?.end()
        guard let textView = controller.textView else { return nil }
        defaults.set(true, forKey: Welcome.shownKey)
        let guide = WelcomeGuide(controller, document: document, textView: textView)
        running = guide
        let tookBack = WelcomeDemo.takeBack(textView, live: document.live)
        guide.attach()
        Task { [weak guide, weak document] in
            // The demo writes over the file, so the taken-back text is saved first.
            if tookBack { _ = await document?.live?.autosave() }
            guard let guide, let document, running === guide else { return }
            WelcomeDemo.play(document, at: url, after: delay)
        }
        return guide
    }

    private func attach() {
        guard let textView, let host = textView.enclosingScrollView?.superview, let window = textView.window else { return }
        island.dock(in: host, under: textView)
        island.onEscape = { [weak self] in self?.end() }
        after = textView.nextKeyView
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: LiveFile.changesDidChange, object: document?.live, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changesChanged() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.end() }
            },
            center.addObserver(forName: TabSet.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.controller?.textView !== self.textView else { return }
                    self.end()
                }
            },
            center.addObserver(forName: MarkdownDocument.didCloseNotification, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.end() }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.beat == .setup { self?.refreshSetup() } }
            },
        ]
        // Typing in the note ends the guide; the shortcuts that decide a change carry Command.
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.typed(event) }
            return event
        }
        show(.watch)
    }

    private func typed(_ event: NSEvent) {
        guard let textView, event.window === textView.window, textView.window?.firstResponder === textView,
            Self.isTyping(event)
        else { return }
        end()
    }

    /// A key that writes into the note: characters, Return or Delete, with neither Command nor Control.
    static func isTyping(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control]) else { return false }
        if [36, 76, 51, 117, 48].contains(event.keyCode) { return true }
        guard event.specialKey == nil, let characters = event.characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    /// Moves to the next beat once the demo's changes land and as each is decided, by either control.
    private func changesChanged() {
        guard Self.running === self, let live = document?.live else { return }
        if beat == .watch {
            let marks = WelcomeDemo.marks(in: live).sorted { $0.value.range.location < $1.value.range.location }
            guard marks.count >= 2 else { return }
            demo = marks.prefix(2).map(\.key)
            show(.revert)
            select(demo[0])
        }
        if beat == .revert, live.changes[demo[0]] == nil {
            show(.keep)
            select(demo[1])
        }
        if beat == .keep, live.changes[demo[1]] == nil { show(.done) }
    }

    /// Puts the caret at the start of change `id`, after the decision that led here has moved it.
    private func select(_ id: UInt64) {
        Task { [weak self] in
            guard let self, let textView, let range = document?.live?.changes[id]?.range else { return }
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            textView.scrollRangeToVisible(range)
        }
    }

    private func show(_ beat: Beat) {
        self.beat = beat
        switch beat {
        case .watch, .revert, .keep:
            let skip = ChromeButton("Skip") { [weak self] in self?.end() }
            island.onReturn = {}
            island.show(Self.sentences[beat.rawValue], key: Self.keys[beat.rawValue], spoken: Self.spoken[beat.rawValue], step: beat.rawValue + 1, buttons: [skip])
        case .done:
            let setUp = ChromeButton("Set Up\u{2026}", style: .bordered, label: "Set Up Dewline") { [weak self] in self?.show(.setup) }
            let open = ChromeButton("Open a Folder\u{2026}", style: .filled) { [weak self] in self?.openFolder() }
            island.show(Self.closing, key: nil, spoken: nil, step: nil, buttons: [setUp, open])
            island.onReturn = { [weak self] in self?.openFolder() }
        case .setup:
            refreshSetup()
        }
        joinKeyViewLoop()
    }

    /// The island's buttons come after the text view in the window's key-view loop: Control-Tab reaches them.
    private func joinKeyViewLoop() {
        let controls = island.controls
        textView?.nextKeyView = controls.first ?? after
        for (control, next) in zip(controls, controls.dropFirst()) { control.nextKeyView = next }
        controls.last?.nextKeyView = after
    }

    static let sentences = [
        "Watch the note. A demo agent is about to edit it.",
        "The agent swapped \u{201C}note\u{201D} for \u{201C}file.\u{201D} Revert it with the button beside the change, or",
        "It also added a paragraph. Keep this one.",
    ]
    static let keys: [String?] = [nil, "\u{2325}\u{2318}\u{232B}", "\u{2318}\u{21A9}"]
    static let spoken: [String?] = [nil, "Option Command Delete.", "Command Return."]
    static let closing = "Open the folder your agent works in. Its edits will land like these."

    // MARK: Setup list

    /// One row of the setup list: what it does, its state, with a command between backticks, and its button, or a
    /// checkmark once done.
    struct SetupRow: Equatable {
        let title: String
        let status: String
        var button: String?
        var done = false
    }

    /// Reads each row's real state, then shows the list.
    private func refreshSetup() {
        Task { [weak self] in
            let rows = await Self.setupRows()
            guard let self, Self.running === self, beat == .setup else { return }
            let changed = rows != self.rows
            self.rows = rows
            if changed { showSetup() }
        }
    }

    private func showSetup() {
        let actions: [() -> Void] = rows.map { row in
            switch row.title {
            case Self.moveTitle: { [weak self] in HookSetup.offerMove(on: self?.textView?.window) }
            case Self.hooksTitle: { [weak self] in HookSetup.install(from: self?.textView?.window) { _ in self?.refreshSetup() } }
            case Self.defaultTitle: { [weak self] in Task { _ = await DefaultApp.make(); self?.refreshSetup() } }
            default: { [weak self] in
                CommandLink.add(on: self?.textView?.window)
                self?.refreshSetup()
            }
            }
        }
        let done = ChromeButton("Done", style: .bordered) { [weak self] in self?.end() }
        let open = ChromeButton("Open a Folder\u{2026}", style: .filled) { [weak self] in self?.openFolder() }
        island.onReturn = { [weak self] in self?.openFolder() }
        island.showSetup(rows, actions: actions, footer: LaunchWindowController.emptyText, buttons: [done, open])
        joinKeyViewLoop()
    }

    static let moveTitle = "Move Dewline to Applications first"
    static let hooksTitle = "Name the agent on each edit"
    static let defaultTitle = "Open Markdown files in Dewline"
    static let commandTitle = "Add the dewline command"

    /// The rows as this Mac stands: on a disk image only the move, else the hooks, the default app and the command.
    static func setupRows(misplaced: Bool = HookSetup.misplaced(), status: HookStatus? = nil, isDefault: Bool? = nil) async -> [SetupRow] {
        if misplaced {
            return [SetupRow(title: moveTitle, status: "Hooks, the default app and the command need a copy that stays put.", button: "Move\u{2026}")]
        }
        let hooks: HookStatus
        if let status { hooks = status } else { hooks = await Task.detached { HookStatus.read() }.value }
        let installed = hooks.agents.filter(\.installed).map(\.title)
        let hooksRow =
            if !installed.isEmpty {
                SetupRow(title: hooksTitle, status: "Hooks are set up for \(ListFormatter.localizedString(byJoining: installed)).", done: true)
            } else if let agent = hooks.agents.first(where: { $0.file != nil }), let file = agent.file {
                SetupRow(
                    title: hooksTitle, status: "Adds a hook to \((file as NSString).abbreviatingWithTildeInPath) so the stamp says \(agent.title.uppercased()).",
                    button: "Set Up Agent Hooks\u{2026}")
            } else {
                SetupRow(title: hooksTitle, status: "No Claude Code, Codex or Cursor found. Set this up later in Settings > Agents.")
            }
        let isDewline = isDefault ?? DefaultApp.isDewline
        let defaultRow = isDewline
            ? SetupRow(title: defaultTitle, status: "Finder opens Markdown files in Dewline.", done: true)
            : SetupRow(title: defaultTitle, status: "Finder opens Markdown files in another app.", button: "Use Dewline")
        let commandRow =
            if let path = hooks.onPath {
                SetupRow(title: commandTitle, status: CommandLink.status(path), done: true)
            } else if let taken = CommandLink.taken() {
                SetupRow(title: commandTitle, status: "Another dewline is at \((taken.path as NSString).abbreviatingWithTildeInPath).")
            } else {
                SetupRow(title: commandTitle, status: "Opens notes from a terminal. `dewline open --wait` works as $EDITOR.", button: "Add")
            }
        return [hooksRow, defaultRow, commandRow]
    }

    /// Open a Folder…: the folder opens; from the setup list, whose hooks row just asked, with its hook offer already made.
    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if beat == .setup { HookSetup.askedThisLaunch.insert(Folder(url).url.path) }
        end()
        (NSApp.delegate as? AppDelegate)?.openFolder(at: url)
    }

    /// Ends the guide for good: the demo stops, its open changes are kept, and the island goes.
    func end() {
        guard Self.running === self else { return }
        Self.running = nil
        WelcomeDemo.cancel()
        if let live = document?.live {
            let open = Array(WelcomeDemo.marks(in: live).keys)
            if !open.isEmpty { live.decide(open, keep: true) }
        }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        textView?.nextKeyView = after
        island.dismiss()
    }
}

/// The guide's island: the raised fill with the `strokeSubtle` edge at a 12 pt radius over a contact shadow and an
/// ambient one, as wide as the text column and 16 pt above the bottom of the editor, which keeps a line more than that
/// clear under the note's end. It holds three step dots, a sentence, a keycap and its buttons, or the setup list.
/// VoiceOver reads it as one group and hears each sentence as it changes.
@MainActor
final class GuideIsland: NSView {
    private static let ease = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    private let stack = NSStackView()
    /// The fill, under the contents, casting the contact shadow; the island's own layer casts the ambient one.
    private let plate = NSView()
    private let dots = StepDots()
    private var bottom: NSLayoutConstraint?
    private var column: NSLayoutConstraint?
    private weak var scrollView: NSScrollView?
    private var adjusted = true
    /// The bottom inset the island adds to the editor.
    private var room: CGFloat = 0
    private(set) var controls: [ChromeButton] = []
    var onReturn: () -> Void = {}
    var onEscape: () -> Void = {}
    private(set) var sentence = ""
    private weak var label: NSTextField?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Guide")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 12)
        stack.wantsLayer = true
        plate.wantsLayer = true
        for view in [plate, stack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("GuideIsland is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    /// Contact shadow: radius 3, 12%, 1 pt down; ambient: radius 16, 8%, 4 pt down. Dark paper takes both darker.
    override func updateLayer() {
        let dark = effectiveAppearance.isDark
        guard let layer, let fill = plate.layer else { return }
        fill.backgroundColor = Chrome.color(.raised).cgColor
        fill.borderColor = Chrome.strokeSubtle.cgColor
        fill.borderWidth = 1
        for (layer, opacity, radius, offset) in [(fill, 0.12, 3.0, -1.0), (layer, 0.08, 16.0, -4.0)] {
            layer.cornerRadius = 12
            layer.cornerCurve = .continuous
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = Float(dark ? opacity * 2.5 : opacity)
            layer.shadowRadius = radius
            layer.shadowOffset = CGSize(width: 0, height: offset)
        }
    }

    override func layout() {
        super.layout()
        let shape = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        layer?.shadowPath = shape
        plate.layer?.shadowPath = shape
    }

    @objc private func themeDidChange() {
        needsDisplay = true
        dots.needsDisplay = true
        column?.constant = ThemeStore.shared.measure
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitSentence()
        makeRoom(newSize.height + 16 + ThemeStore.shared.bodySize * ThemeStore.shared.lineHeight)
    }

    /// Wraps the beat's sentence at the width its row leaves it beside the keycap and buttons, so every word shows.
    private func fitSentence() {
        guard let label, let row = label.superview as? NSStackView else { return }
        let others = row.arrangedSubviews.filter { $0 !== label }
        let width = (bounds.width - stack.edgeInsets.left - stack.edgeInsets.right - others.reduce(0) { $0 + $1.fittingSize.width }
            - row.spacing * CGFloat(others.count)).rounded(.down)
        if width > 0, width != label.preferredMaxLayoutWidth { label.preferredMaxLayoutWidth = width }
    }

    /// Sets the editor's bottom inset to `height` more than it had before the island, 0 to give it back, and scrolls the
    /// note by the difference, so the lines that showed above the island still do.
    private func makeRoom(_ height: CGFloat) {
        guard let scrollView, height != room else { return }
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets.bottom += height - room
        let clip = scrollView.contentView
        var bounds = clip.bounds
        bounds.origin.y += height - room
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
        room = height
        if room == 0 { scrollView.automaticallyAdjustsContentInsets = adjusted }
    }

    /// Docks over the text column of `textView` in `host`, at the bottom of its scroll view, then fades in, rising
    /// 12 pt (opacity only under Reduce Motion). The column is the measure, or the view less its 32 pt margins.
    func dock(in host: NSView, under textView: NSTextView) {
        guard let editor = textView.enclosingScrollView else { return }
        scrollView = editor
        adjusted = editor.automaticallyAdjustsContentInsets
        host.addSubview(self, positioned: .above, relativeTo: editor)
        let calm = Motion.current == .calm
        let bottom = bottomAnchor.constraint(equalTo: editor.bottomAnchor, constant: calm ? -4 : -16)
        self.bottom = bottom
        let column = widthAnchor.constraint(equalToConstant: ThemeStore.shared.measure)
        column.priority = .defaultHigh
        self.column = column
        let margins = 2 * (32 + (textView.textContainer?.lineFragmentPadding ?? 0))
        NSLayoutConstraint.activate([
            bottom, column, centerXAnchor.constraint(equalTo: editor.contentView.centerXAnchor),
            widthAnchor.constraint(lessThanOrEqualTo: editor.contentView.widthAnchor, constant: -margins),
        ])
        alphaValue = 0
        host.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = calm ? 0.2 : 0.15
            context.timingFunction = Self.ease
            animator().alphaValue = 1
            if calm { bottom.animator().constant = -16 }
        }
    }

    /// A beat: step `step` of three's dots, then `text` with the keycap `key` after it and `buttons` at the trailing
    /// edge; `spoken` reads the key. The island takes its new height, and the editor its inset, before the beat's change
    /// lands.
    func show(_ text: String, key: String?, spoken: String?, step: Int?, buttons: [ChromeButton]) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Chrome.label
        label.textColor = Chrome.color(.ink)
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let read = spoken.map { text + " " + $0 } ?? text
        label.setAccessibilityLabel(read)
        dots.step = step ?? 0
        var views: [NSView] = step == nil ? [label] : [dots, label]
        if let key { views.append(KeycapView([key])) }
        views += [Self.spacer()] + buttons as [NSView]
        let row = NSStackView(views: views)
        row.alignment = .centerY
        row.spacing = 10
        replace([row], buttons: buttons, animatedHeight: false)
        self.label = label
        fitSentence()
        sentence = text
        superview?.layoutSubtreeIfNeeded()
        announce(read)
    }

    /// The setup list: each row's title and state with its button or a checkmark, then the footer's line and buttons.
    func showSetup(_ rows: [WelcomeGuide.SetupRow], actions: [() -> Void], footer: String, buttons: [ChromeButton]) {
        var views: [NSView] = []
        var controls: [ChromeButton] = []
        for (row, action) in zip(rows, actions) {
            let title = NSTextField(labelWithString: row.title)
            title.font = Chrome.labelActive
            title.textColor = Chrome.color(.ink)
            let status = NSTextField(wrappingLabelWithString: "")
            status.attributedStringValue = Self.status(row.status)
            status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let words = NSStackView(views: [title, status])
            words.orientation = .vertical
            words.alignment = .leading
            words.spacing = 2
            words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let trailing: NSView
            if row.done {
                let check = NSImageView(image: Chrome.symbol("checkmark", Chrome.color(.ink2)) ?? NSImage())
                check.setAccessibilityElement(false)
                trailing = check
            } else if let name = row.button {
                let button = ChromeButton(name, style: .bordered, label: "\(name.replacingOccurrences(of: "\u{2026}", with: "")) \(row.title)", action)
                controls.append(button)
                trailing = button
            } else {
                trailing = NSView()
            }
            let line = NSStackView(views: [words, Self.spacer(), trailing])
            line.alignment = .centerY
            line.spacing = 16
            line.setAccessibilityElement(true)
            line.setAccessibilityRole(.group)
            line.setAccessibilityLabel(row.title + ". " + Self.spoken(row.status) + (row.done ? " Done." : ""))
            views.append(line)
        }
        let note = NSTextField(wrappingLabelWithString: footer)
        note.font = Chrome.small
        note.textColor = Chrome.color(.ink2)
        let actionsRow = NSStackView(views: buttons)
        actionsRow.spacing = 8
        let foot = NSStackView(views: [note, Self.spacer(), actionsRow])
        foot.alignment = .centerY
        foot.spacing = 16
        views.append(foot)
        label = nil
        replace(views, buttons: controls + buttons, animatedHeight: true)
        sentence = rows.map(\.title).joined(separator: ". ")
        superview?.layoutSubtreeIfNeeded()
        announce("Set up Dewline. " + rows.map { $0.title + ". " + Self.spoken($0.status) }.joined(separator: " "))
    }

    /// A row's state in `ink2`, its backticked command in SF Mono at the same size.
    static func status(_ text: String) -> NSAttributedString {
        let styled = NSMutableAttributedString()
        for (index, part) in text.split(separator: "`", omittingEmptySubsequences: false).enumerated() {
            let font = index % 2 == 1 ? Chrome.mono(Chrome.small.pointSize) : Chrome.small
            styled.append(NSAttributedString(string: String(part), attributes: [.font: font, .foregroundColor: Chrome.color(.ink2)]))
        }
        return styled
    }

    private static func spoken(_ status: String) -> String {
        status.replacingOccurrences(of: "`", with: "")
    }

    private func replace(_ views: [NSView], buttons: [ChromeButton], animatedHeight: Bool) {
        controls = buttons
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.15
        stack.layer?.add(fade, forKey: "beat")
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in views {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        }
        guard animatedHeight, Motion.current == .calm, let host = superview else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = Self.ease
            context.allowsImplicitAnimation = true
            host.layoutSubtreeIfNeeded()
        }
    }

    /// Takes the room between a row's words and its buttons, so the buttons sit at the trailing edge.
    private static func spacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return spacer
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// With the focus on one of its buttons, Return presses the filled one and Esc is Done.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn()
        case 53: onEscape()
        default: super.keyDown(with: event)
        }
    }

    /// Gives the editor its inset back, fades out, 150 ms, and leaves.
    func dismiss() {
        makeRoom(0)
        scrollView = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.removeFromSuperview() }
        }
    }
}

/// The guide's progress inside the island: three 4 pt dots 4 pt apart, those up to the current step in Signal, the
/// rest in `ink3`. The sentence says the step, so VoiceOver skips them.
private final class StepDots: NSView {
    var step = 0 {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("StepDots is built in code")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 20, height: 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        for index in 0..<3 {
            Chrome.color(index < step ? .signal : .ink3).setFill()
            NSBezierPath(ovalIn: NSRect(x: CGFloat(index) * 8, y: bounds.midY - 2, width: 4, height: 4)).fill()
        }
    }
}

/// A keycap in a sentence. VoiceOver reads the keys inside the sentence, so the cap is not an element of its own.
private final class KeycapView: NSView {
    private let keys: [String]

    init(_ keys: [String]) {
        self.keys = keys
        super.init(frame: .zero)
        setAccessibilityElement(false)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("KeycapView is built in code")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Keycap.width(keys), height: Keycap.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Keycap.draw(keys, x: 0, midY: bounds.midY, onFill: false)
    }
}
