import AppKit
import MdCore

/// The title row, a `.unifiedCompact` toolbar: the folder's tile over the sidebar, then from the sidebar's divider the
/// tab strip, Activity, Search and New Note. Each item is a borderless button in a plain view, so no glass capsule
/// draws behind it. The tile and the tabs outlast the others when the window narrows.
@MainActor
final class WindowToolbar: NSObject, NSToolbarDelegate {
    static let tile = NSToolbarItem.Identifier("dev.arkwerx.dewline.tile")
    static let divider = NSToolbarItem.Identifier("dev.arkwerx.dewline.divider")
    static let tabs = NSToolbarItem.Identifier("dev.arkwerx.dewline.tabs")
    static let activity = NSToolbarItem.Identifier("dev.arkwerx.dewline.activity")
    static let search = NSToolbarItem.Identifier("dev.arkwerx.dewline.search")
    static let newNote = NSToolbarItem.Identifier("dev.arkwerx.dewline.newNote")

    let toolbar = NSToolbar(identifier: "dev.arkwerx.dewline.main")
    /// The tab strip's place; it holds at least 160 pt and takes the row's free width.
    let strip = NSView()
    private let split: NSSplitView
    private let folder: Folder?
    private let activity = ActivityButton()
    private var activityItem: NSToolbarItem?

    /// The window whose notes Activity counts. A full-screen toolbar sits in a window of its own, so its views can't
    /// ask theirs.
    weak var window: NSWindow? {
        didSet { activity.owner = window }
    }

    init(split: NSSplitView, folder: Folder?) {
        self.split = split
        self.folder = folder
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
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.tile, Self.divider, Self.tabs, Self.activity, Self.search, Self.newNote]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.divider:
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: split, dividerIndex: 0)
        case Self.tile:
            let item = Self.item(identifier, "Folder", ToolbarControl(tileButton()), priority: .high)
            item.isHidden = folder == nil
            return item
        case Self.tabs:
            return Self.item(identifier, "Tabs", strip, priority: .high)
        case Self.activity:
            let item = Self.item(identifier, "Activity", ToolbarControl(activity, inset: 7), priority: .user)
            activityItem = item
            item.isHidden = !activity.shows
            return item
        case Self.search:
            return Self.item(identifier, "Open Quickly", ToolbarControl(Self.symbolButton(
                "magnifyingglass", "Open Quickly", tip: "Open Quickly (\u{21E7}\u{2318}O)", action: #selector(AppDelegate.quickOpen(_:)))), priority: .user)
        case Self.newNote:
            return Self.item(identifier, "New Note", ToolbarControl(Self.symbolButton(
                "square.and.pencil", "New Note", tip: "New Note (\u{2318}N)", action: #selector(AppDelegate.newNote(_:)))), priority: .user)
        default:
            return nil
        }
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

    /// The folder's first letter on a 20 pt green tile; it opens the folder menu.
    private func tileButton() -> NSButton {
        let name = folder.map { FileManager.default.displayName(atPath: $0.url.path) } ?? ""
        let letter = String(name.prefix(1))
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            Chrome.color(.accent).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            let text = NSAttributedString(string: letter, attributes: [.font: Chrome.mono(11, weight: .semibold), .foregroundColor: Chrome.color(.paper)])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
        let button = NSButton(image: image, target: self, action: #selector(showFolderMenu(_:)))
        button.toolTip = "Open Folder, Open Recent"
        button.setAccessibilityLabel(name)
        button.setAccessibilityRole(.popUpButton)
        return button
    }

    @objc private func showFolderMenu(_ sender: NSButton) {
        FolderMenu.menu(for: folder).popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
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

/// Activity: each writer with changes waiting in the window's notes, as its rule, name and count, then "waiting". It
/// opens a menu of those notes. A note changed while closed counts once.
final class ActivityButton: NSButton {
    weak var owner: NSWindow? {
        didSet { update() }
    }
    /// Called when Activity comes or goes; it shows only while changes wait.
    var shown: (Bool) -> Void = { _ in }
    private(set) var shows = false
    /// The writers and counts the title last showed.
    private var counts: [(writer: MarkWriter, count: Int)] = []

    init() {
        super.init(frame: .zero)
        bezelStyle = .regularSquare
        target = self
        action = #selector(showMenu(_:))
        setAccessibilityRole(.popUpButton)
        for name in [LiveFile.changesDidChange, TabSet.changed, ThemeStore.didChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("ActivityButton is built in code")
    }

    /// The window's open notes with marked changes, and the notes changed while closed that aren't among them.
    private var waiting: (open: [LiveFile], closed: [ClosedNote]) {
        let open = Review.files(in: owner).filter { $0.changes.values.contains(where: \.marked) }
        let paths = Set(open.map(\.url.standardizedFileURL.path))
        return (open, Review.closedNotes().filter { !paths.contains($0.url.standardizedFileURL.path) })
    }

    private static func tally(_ origins: [ChangeEngine.Origin]) -> [(writer: MarkWriter, count: Int)] {
        var counts: [(writer: MarkWriter, count: Int)] = []
        for origin in origins {
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

    /// Rebuilds the title when the counts change; each keystroke before a pending change moves it without changing them.
    private func update(force: Bool = false) {
        let (open, closed) = waiting
        let counts = Self.tally(open.flatMap { $0.changes.values.filter(\.marked).map(\.origin) } + closed.map(\.origin))
        let same = counts.map { "\($0.writer.name) \($0.count)" } == self.counts.map { "\($0.writer.name) \($0.count)" }
        guard force || !same else { return }
        self.counts = counts
        attributedTitle = Self.title(counts)
        let spoken = counts.map { "\($0.writer.name) \($0.count)" }.joined(separator: ", ")
        setAccessibilityLabel("Changes waiting: \(spoken)")
        toolTip = "Changes waiting (\u{21E7}\u{2318}R)"
        if shows != !counts.isEmpty {
            shows = !counts.isEmpty
            shown(shows)
        }
    }

    /// "▍Claude 1  ▍Codex 3  waiting ⌄": a 3 x 12 rule in each writer's ink, the name in 13 medium, the count in SF Mono.
    private static func title(_ counts: [(writer: MarkWriter, count: Int)]) -> NSAttributedString {
        let title = NSMutableAttributedString()
        let ink: [NSAttributedString.Key: Any] = [.font: Chrome.labelActive, .foregroundColor: Chrome.color(.ink)]
        for (writer, count) in counts {
            let color = writer.color
            let rule = NSImage(size: NSSize(width: 3, height: 12), flipped: false) { rect in
                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
                return true
            }
            title.append(attachment(rule, size: rule.size))
            title.append(NSAttributedString(string: " \(writer.name) ", attributes: ink))
            title.append(NSAttributedString(string: "\(count)   ", attributes: [.font: Chrome.mono(13, weight: .medium), .foregroundColor: Chrome.color(.ink)]))
        }
        title.append(NSAttributedString(string: "waiting ", attributes: [.font: Chrome.label, .foregroundColor: Chrome.color(.ink2)]))
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [Chrome.color(.ink3)])))
        {
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

    /// Each note with changes waiting and who made them; choosing one opens it at its first change.
    @objc private func showMenu(_ sender: Any?) {
        let menu = NSMenu()
        let (open, closed) = waiting
        for live in open {
            let counts = Self.tally(live.changes.values.filter(\.marked).map(\.origin))
            let detail = counts.map { "\($0.writer.name) \($0.count)" }.joined(separator: ", ")
            menu.addItem(Self.note(live.url, detail))
        }
        for note in closed {
            menu.addItem(Self.note(note.url, "\(MarkWriter(note.origin).name), changed while closed"))
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Review All Changes", action: #selector(ShellActions.toggleChanges(_:)), keyEquivalent: "R")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
    }

    private static func note(_ url: URL, _ detail: String) -> NSMenuItem {
        let item = NSMenuItem(title: url.lastPathComponent, action: #selector(MainWindowController.openWaiting(_:)), keyEquivalent: "")
        let title = NSMutableAttributedString(string: url.lastPathComponent, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        title.append(NSAttributedString(string: "   \(detail)", attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]))
        item.attributedTitle = title
        item.representedObject = url
        return item
    }
}

/// The folder menu, from the title row's tile and the sidebar's header: Open Folder, Open Recent, Copy Branch Name and
/// Reveal in Finder.
@MainActor
final class FolderMenu: NSObject {
    static func menu(for folder: Folder?) -> NSMenu {
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Open Folder\u{2026}", action: #selector(AppDelegate.openFolder(_:)), keyEquivalent: "o")
        open.keyEquivalentModifierMask = [.command, .option]
        let recent = NSMenu()
        for visit in Library.recentFolders where visit.url.path != folder?.url.path {
            let item = recent.addItem(withTitle: FileManager.default.displayName(atPath: visit.url.path), action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = FolderMenu.self
            item.representedObject = visit.url
            item.toolTip = abbreviatedPath(visit.url)
        }
        menu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "").submenu = recent
        guard let folder else { return menu }
        menu.addItem(.separator())
        if let branch = gitBranch(at: folder.url) {
            let copy = menu.addItem(withTitle: "Copy Branch Name", action: #selector(copyBranch(_:)), keyEquivalent: "")
            copy.target = FolderMenu.self
            copy.representedObject = branch
        }
        let reveal = menu.addItem(withTitle: "Reveal in Finder", action: #selector(reveal(_:)), keyEquivalent: "")
        reveal.target = FolderMenu.self
        reveal.representedObject = folder.url
        return menu
    }

    @objc private static func openRecent(_ sender: NSMenuItem) {
        (NSApp.delegate as? AppDelegate)?.openFolder(at: sender.representedObject as! URL)
    }

    @objc private static func copyBranch(_ sender: NSMenuItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sender.representedObject as! String, forType: .string)
    }

    @objc private static func reveal(_ sender: NSMenuItem) {
        NSWorkspace.shared.activateFileViewerSelecting([sender.representedObject as! URL])
    }
}
