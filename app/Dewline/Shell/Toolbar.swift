import AppKit
import MdCore

/// The title row, a `.unifiedCompact` toolbar: the sidebar toggle over the sidebar, then from its divider the tab
/// strip, Activity, Search and New Note. Each item but the system's sidebar toggle is a borderless button in a plain view, so no glass capsule draws behind it. The tabs outlast the others
/// when the window narrows. After 1.5 s of typing, everything but Activity and the selected tab fades out until the
/// pointer or a Command chord comes back.
@MainActor
final class WindowToolbar: NSObject, NSToolbarDelegate {
    static let divider = NSToolbarItem.Identifier("dev.arkwerx.dewline.divider")
    static let tabs = NSToolbarItem.Identifier("dev.arkwerx.dewline.tabs")
    static let activity = NSToolbarItem.Identifier("dev.arkwerx.dewline.activity")
    static let search = NSToolbarItem.Identifier("dev.arkwerx.dewline.search")
    static let newNote = NSToolbarItem.Identifier("dev.arkwerx.dewline.newNote")

    let toolbar = NSToolbar(identifier: "dev.arkwerx.dewline.main")
    /// The tab strip; it holds at least 160 pt and takes the row's free width.
    let strip = TabStrip()
    private let split: NSSplitView
    private let activity = ActivityButton()
    private var activityItem: NSToolbarItem?
    /// Search and New Note, which fade out while typing.
    private var fading: [NSView] = []
    /// Whether the title row has faded for typing.
    private var quiet = false
    /// When the current run of typing started and its last keystroke.
    private var typing: (start: Date, last: Date)?
    private var monitor: Any?
    /// The pointer on screen when the row faded.
    private var anchor = NSPoint.zero
    /// Counts fades, so a fade's end hides the controls only if no later fade began.
    private var fadeCount = 0

    /// The window whose notes Activity counts. A full-screen toolbar sits in a window of its own, so its views can't
    /// ask theirs.
    weak var window: NSWindow? {
        didSet { activity.owner = window }
    }

    init(split: NSSplitView) {
        self.split = split
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        strip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            strip.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            strip.widthAnchor.constraint(lessThanOrEqualToConstant: 10_000),
            strip.heightAnchor.constraint(equalToConstant: 28),
        ])
        activity.shown = { [weak self] shows in self?.activityItem?.isHidden = !shows }
        NotificationCenter.default.addObserver(self, selector: #selector(splitResized), name: NSSplitView.didResizeSubviewsNotification, object: split)
    }

    /// Activity carries the folder's branch and git count while the sidebar that shows them is collapsed.
    @objc private func splitResized() {
        activity.sidebarCollapsed = split.arrangedSubviews.first.map(split.isSubviewCollapsed) ?? false
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, Self.divider, Self.tabs, Self.activity, Self.search, Self.newNote]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.divider:
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: split, dividerIndex: 0)
        case Self.tabs:
            return Self.item(identifier, "Tabs", strip, priority: .high)
        case Self.activity:
            let view = ToolbarControl(activity, inset: 7)
            let item = Self.item(identifier, "Activity", view, priority: .user)
            activityItem = item
            item.isHidden = !activity.shows
            return item
        case Self.search:
            return Self.item(identifier, "Open Quickly", fades(ToolbarControl(Self.symbolButton(
                "magnifyingglass", "Open Quickly", tip: "Open Quickly (\u{21E7}\u{2318}O)", action: #selector(AppDelegate.quickOpen(_:))))), priority: .user)
        case Self.newNote:
            return Self.item(identifier, "New Note", fades(ToolbarControl(Self.symbolButton(
                "square.and.pencil", "New Note", tip: "New Note (\u{2318}N)", action: #selector(AppDelegate.newNote(_:))))), priority: .user)
        default:
            return nil
        }
    }

    private func fades(_ view: NSView) -> NSView {
        fading.append(view)
        return view
    }

    // MARK: Typing

    /// A keystroke in the note. Once a run of typing, with no pause over 1.5 s, has gone on 1.5 s, the row fades,
    /// unless the pointer is in it.
    func typed() {
        let now = Date.now
        let start = typing.flatMap { now.timeIntervalSince($0.last) <= 1.5 ? $0.start : nil } ?? now
        typing = (start, now)
        guard !quiet, now.timeIntervalSince(start) >= 1.5, let window, !inTitleRow(NSEvent.mouseLocation, of: window) else { return }
        fade(true)
    }

    /// Brings the row back: focus left the note, the window stopped being key, or it is entering full screen.
    func wake() {
        typing = nil
        fade(false)
    }

    private func inTitleRow(_ point: NSPoint, of window: NSWindow) -> Bool {
        window.frame.contains(point) && window.convertPoint(fromScreen: point).y >= window.contentLayoutRect.maxY
    }

    /// Fades the row's other controls and tabs out or in over 150 ms, at once under Reduce Motion. A faded control is
    /// hidden once the fade ends, so it takes no clicks and VoiceOver skips it; it shows again before fading in.
    private func fade(_ out: Bool) {
        guard out != quiet, let window else { return }
        quiet = out
        fadeCount += 1
        let count = fadeCount
        if out {
            anchor = NSEvent.mouseLocation
            window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .keyDown]) { [weak self] event in
                self?.woken(by: event)
                return event
            }
        } else {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            window.acceptsMouseMovedEvents = false
            for view in fading { view.isHidden = false }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            for view in fading { view.animator().alphaValue = out ? 0 : 1 }
            strip.animator().othersAlpha = out ? 0 : 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.quiet, self.fadeCount == count else { return }
                for view in self.fading { view.isHidden = true }
            }
        }
    }

    /// The pointer moving more than 3 pt or into the title row, or a Command chord, brings the row back.
    private func woken(by event: NSEvent) {
        guard let window else { return }
        let point = NSEvent.mouseLocation
        let wakes = switch event.type {
        case .mouseMoved: hypot(point.x - anchor.x, point.y - anchor.y) > 3 || inTitleRow(point, of: window)
        default: event.modifierFlags.contains(.command)
        }
        if wakes { wake() }
    }

    private static func item(_ identifier: NSToolbarItem.Identifier, _ label: String, _ view: NSView, priority: NSToolbarItem.VisibilityPriority) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.view = view
        item.isBordered = false
        item.visibilityPriority = priority
        return item
    }

    private static func symbolButton(_ symbol: String, _ label: String, tip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        let button = NSButton(image: image ?? NSImage(), target: nil, action: action)
        button.contentTintColor = Chrome.color(.ink2)
        button.toolTip = tip
        button.setAccessibilityLabel(label)
        return button
    }
}

/// A title-row control: a borderless button in a plain view, filled with the hover ink at radius 6 under the pointer.
final class ToolbarControl: NSView {
    private var hovering = false {
        didSet { needsDisplay = true }
    }

    /// `button` sits `inset` pt in from each side.
    init(_ button: NSButton, inset: CGFloat = 0) {
        super.init(frame: .zero)
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ToolbarControl is built in code")
    }

    @objc private func themeDidChange() {
        for case let button as NSButton in subviews where button.image?.isTemplate == true {
            button.contentTintColor = Chrome.color(.ink2)
        }
        needsDisplay = true
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        Chrome.hover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }
}

/// Activity: a dot in the ink of each writer with changes waiting in the window's notes, then "3 to review", after
/// "main ↑2 · 7 changed" while the sidebar is collapsed. It opens a menu of those notes on mouse down. A note changed
/// while closed counts once.
final class ActivityButton: NSButton {
    weak var owner: NSWindow? {
        didSet { update() }
    }
    /// Called when Activity comes or goes; it shows only while changes wait or it carries the git line.
    var shown: (Bool) -> Void = { _ in }
    private(set) var shows = false
    /// Whether the window's sidebar is collapsed, so the title carries the folder's branch and git count.
    var sidebarCollapsed = false {
        didSet { if sidebarCollapsed != oldValue { update() } }
    }
    /// The writers and counts the title last showed.
    private var counts: [(writer: MarkWriter, count: Int)] = []
    /// The git line the title last showed.
    private var git: String?
    /// The title's width: the toolbar keeps an item at the size it had when it went in, hidden and empty, unless
    /// told otherwise.
    private lazy var width = widthAnchor.constraint(equalToConstant: 0)

    init() {
        super.init(frame: .zero)
        bezelStyle = .regularSquare
        target = self
        action = #selector(showMenu(_:))
        sendAction(on: .leftMouseDown)
        setAccessibilityRole(.popUpButton)
        for name in [LiveFile.changesDidChange, ClosedChanges.changed, TabSet.changed, ThemeStore.didChange, GitStates.changed] {
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("ActivityButton is built in code")
    }

    /// Each writer's changes waiting for Keep or Revert among `origins`; git's uncommitted changes are not among them.
    private static func tally(_ origins: [ChangeEngine.Origin]) -> [(writer: MarkWriter, count: Int)] {
        var counts: [(writer: MarkWriter, count: Int)] = []
        for origin in origins {
            if case .git = origin { continue }
            let writer = MarkWriter(origin)
            if let index = counts.firstIndex(where: { $0.writer.name == writer.name }) {
                counts[index].count += 1
            } else {
                counts.append((writer, 1))
            }
        }
        return counts.sorted { $0.writer.name < $1.writer.name }
    }

    @objc private func changed(_ notification: Notification) {
        update(force: notification.name == ThemeStore.didChange)
    }

    /// "main ↑2 ↓1 · 7 uncommitted" for the window's folder while the sidebar is collapsed; nil when it is in no
    /// repository.
    private var gitLine: String? {
        guard sidebarCollapsed, let folder = (owner?.windowController as? MainWindowController)?.folder else { return nil }
        let states = FolderIndex.of(folder).git
        let branch = [gitBranch(at: folder.url), states.ahead > 0 ? "\u{2191}\(states.ahead)" : nil, states.behind > 0 ? "\u{2193}\(states.behind)" : nil]
            .compactMap { $0 }
        let changed = states.changed.count
        guard !branch.isEmpty || changed > 0 else { return nil }
        return ([branch.joined(separator: " ")].filter { !$0.isEmpty } + (changed > 0 ? ["\(changed) uncommitted"] : [])).joined(separator: " \u{00B7} ")
    }

    /// Rebuilds the title when the counts or the git line change; each keystroke before a pending change moves it
    /// without changing them.
    private func update(force: Bool = false) {
        let (open, closed) = Review.waiting(in: owner)
        let counts = Self.tally(
            open.flatMap { $0.changes.values.filter(\.marked).map(\.origin) } + closed.flatMap { Array(repeating: $0.origin, count: $0.count) })
        let git = gitLine
        let same = counts.map { "\($0.writer.name) \($0.count)" } == self.counts.map { "\($0.writer.name) \($0.count)" } && git == self.git
        guard force || !same else { return }
        self.counts = counts
        self.git = git
        attributedTitle = Self.title(counts, git: git)
        width.constant = ceil(attributedTitle.size().width) + 4
        width.isActive = true
        let spoken = counts.map { "\($0.writer.name) \($0.count)" }.joined(separator: ", ")
        setAccessibilityLabel(([git].compactMap { $0 } + (counts.isEmpty ? [] : ["Changes waiting for Keep or Revert: \(spoken)"])).joined(separator: ", "))
        toolTip = "Changes waiting for Keep or Revert (\u{21E7}\u{2318}R)"
        let shows = !counts.isEmpty || git != nil
        if self.shows != shows {
            self.shows = shows
            shown(shows)
        }
    }

    /// "main · 7 uncommitted   ● ● 4 to review ⌄": the git line in body `ink2`, a 7 pt dot in each writer's ink, then the
    /// total in body medium, all with monospaced digits.
    private static func title(_ counts: [(writer: MarkWriter, count: Int)], git: String?) -> NSAttributedString {
        let title = NSMutableAttributedString()
        if let git {
            let font = NSFont.monospacedDigitSystemFont(ofSize: Chrome.size(.body), weight: .regular)
            title.append(NSAttributedString(string: git + (counts.isEmpty ? " " : "   "), attributes: [.font: font, .foregroundColor: Chrome.color(.ink2)]))
        }
        for (writer, _) in counts {
            let color = writer.color
            let dot = NSImage(size: NSSize(width: 7, height: 7), flipped: false) { rect in
                color.setFill()
                NSBezierPath(ovalIn: rect).fill()
                return true
            }
            title.append(attachment(dot, size: dot.size))
            title.append(NSAttributedString(string: " "))
        }
        let total = counts.reduce(0) { $0 + $1.count }
        let font = NSFont.monospacedDigitSystemFont(ofSize: Chrome.size(.body), weight: .medium)
        if !counts.isEmpty {
            title.append(NSAttributedString(string: "\(total) to review ", attributes: [.font: font, .foregroundColor: Chrome.color(.ink)]))
        }
        if let chevron = Chrome.symbol("chevron.down", Chrome.color(.ink3)) {
            title.append(attachment(chevron, size: chevron.size))
        }
        return title
    }

    private static func attachment(_ image: NSImage, size: NSSize) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: (Chrome.label.capHeight - size.height) / 2, width: size.width, height: size.height)
        return NSAttributedString(attachment: attachment)
    }

    /// Each writer, under its name, with the notes it changed, newest first, by their paths in the folder; choosing one
    /// opens it at its first change.
    @objc private func showMenu(_ sender: Any?) {
        let menu = NSMenu()
        let folder = (owner?.windowController as? MainWindowController)?.folder
        let (open, closed) = Review.waiting(in: owner)
        var notes: [(writer: MarkWriter, url: URL, detail: String, time: Date)] = []
        for live in open {
            let time = (try? live.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            for (writer, count) in Self.tally(live.changes.values.filter(\.marked).map(\.origin)) {
                notes.append((writer, live.url, "\(count) \(count == 1 ? "change" : "changes")", time))
            }
        }
        for note in closed {
            guard let (writer, _) = Self.tally([note.origin]).first else { continue }
            notes.append((writer, note.url, "\(note.count) \(note.count == 1 ? "change" : "changes") while closed", note.time))
        }
        notes.sort { $0.time > $1.time }
        var writers: [String] = []
        for note in notes where !writers.contains(note.writer.name) {
            writers.append(note.writer.name)
        }
        for name in writers {
            menu.addItem(.sectionHeader(title: name))
            for note in notes where note.writer.name == name {
                menu.addItem(Self.note(note.url, folder?.relativePath(of: note.url) ?? note.url.lastPathComponent, note.detail))
            }
        }
        menu.addItem(.separator())
        let files = Set(loads.compactMap(\.url)).count
        if files > 0 {
            let item = menu.addItem(withTitle: "Agents Read \(files) \(files == 1 ? "File" : "Files") Here", action: #selector(showLoads(_:)), keyEquivalent: "")
            item.target = self
        }
        menu.addItem(withTitle: "Review All Changes", action: #selector(ShellActions.toggleChanges(_:)), keyEquivalent: "R")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
    }

    /// What agents load for the window's note's folder.
    private var loads: [AgentRow] {
        (owner?.windowController as? MainWindowController)?.agentLoads ?? []
    }

    /// Each agent and file the note's folder loads, with its estimate, under Activity.
    @objc private func showLoads(_ sender: Any?) {
        LoadsPopover.show(loads, under: self)
    }

    private static func note(_ url: URL, _ path: String, _ detail: String) -> NSMenuItem {
        let item = NSMenuItem(title: path, action: #selector(MainWindowController.openWaiting(_:)), keyEquivalent: "")
        let title = NSMutableAttributedString(string: path, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        title.append(NSAttributedString(string: "   \(detail)", attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]))
        item.attributedTitle = title
        item.representedObject = url
        return item
    }
}
