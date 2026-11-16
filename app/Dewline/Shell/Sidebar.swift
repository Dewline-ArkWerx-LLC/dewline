import AppKit
import MdCore
import Quartz
import UniformTypeIdentifiers

/// A row in the sidebar.
@MainActor
final class SidebarNode {
    enum Kind {
        /// The open folder's tree under a "Files" header, when Pinned shows above it.
        case root(URL)
        /// A header: Pinned, or a folderless window's Outline.
        case section(String)
        /// A file or folder in the open folder's tree.
        case entry(FolderEntry)
        /// A pinned file or folder.
        case shortcut(FolderEntry)
        case heading(Heading)
        /// The last row of a folder: what its .gitignore hides.
        case ignored([String])
        /// The row after the first 12 headings that shows the rest.
        case more(Int)
    }

    let kind: Kind
    /// Nil until a folder first expands.
    var children: [SidebarNode]?

    init(_ kind: Kind, children: [SidebarNode]? = nil) {
        self.kind = kind
        self.children = children
    }

    var url: URL? {
        switch kind {
        case .root(let url): url
        case .entry(let entry), .shortcut(let entry): entry.url
        default: nil
        }
    }
}

/// The file commands the sidebar sends up the responder chain, each from a menu item whose represented object is the
/// row's URL: the folder to make a note or folder in, or the file to rename, duplicate or trash. The window answers
/// them through FileActions.
@MainActor
enum FileCommand {
    static let newNote = #selector(MainWindowController.newNoteInFolder(_:))
    static let newFolder = #selector(MainWindowController.newFolderInFolder(_:))
    /// The represented object is a `NewNoteRequest`.
    static let newNamedNote = #selector(MainWindowController.newNoteNamed(_:))
    /// The represented object is a `RenameRequest`.
    static let rename = #selector(MainWindowController.renameItem(_:))
    static let duplicate = #selector(MainWindowController.duplicateItem(_:))
    static let trash = #selector(MainWindowController.trashItem(_:))
    /// The represented object is a `MoveRequest`.
    static let move = #selector(MainWindowController.moveItems(_:))

    /// Sends `command` for `object` from `view`'s window, as a menu item would.
    @discardableResult
    static func send(_ command: Selector, _ object: Any, from view: NSView?) -> Bool {
        let item = NSMenuItem(title: "", action: command, keyEquivalent: "")
        item.representedObject = object
        return NSApp.sendAction(command, to: nil, from: item)
    }
}

/// A rename typed into a sidebar row: the file and its new name, extension included.
struct RenameRequest {
    let url: URL
    let name: String
}

/// A note to make from Quick Open: the folder and the file's name, extension included.
struct NewNoteRequest {
    let folder: URL
    let name: String
}

/// Rows dragged onto a folder in the sidebar.
struct MoveRequest {
    let urls: [URL]
    let folder: URL
}

/// The folder's header, "tidepool main ⌄", over its tree; Pinned above the tree when something is pinned. Rows badge
/// the notes with changes waiting and carry git's word. A window with no folder says so, offers Open Folder, and lists
/// the note's headings. A folder's window can show Find in Files in place of the tree.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
    NSTextFieldDelegate, QLPreviewPanelDataSource
{
    var open: (URL, _ newTab: Bool) -> Void = { _, _ in }
    var jump: (Heading) -> Void = { _ in }
    /// Opens a file from Find in Files, at a match when there is one.
    var reveal: (URL, TextMatch?, _ newTab: Bool) -> Void = { _, _, _ in }

    private let folder: Folder?
    private let header: SidebarHeader?
    private let gitStates: GitStates?
    private let find: FindInFilesController?
    private let outlineView = SidebarOutlineView()
    private let pinned = SidebarNode(.section("Pinned"))
    private let outlineSection = SidebarNode(.section("Outline"), children: [])
    /// The folder's row; its children are the tree. Listed after the window's first frame.
    private var tree: SidebarNode?
    private var expandedOnce: Set<ObjectIdentifier> = []
    /// The open file's row in the tree.
    private var fileNode: SidebarNode?
    private var headings: [Heading] = []
    private var showsAllHeadings = false
    /// The location of the heading whose section is at the top of the page.
    private var section: Int?
    private var watch: FolderWatch?
    private var showsIgnored: Bool
    /// The rows are listed once the window has drawn its first frame; until then the sidebar shows empty.
    private var filled = false
    /// The open file as `show` last had it before the rows were listed.
    private var waiting: URL??
    /// The row whose name is being edited.
    private var renaming: SidebarNode?
    /// Folders the watch saw change during a rename, listed again once it ends.
    private var changedWhileRenaming: Set<String> = []
    /// Each note's undecided changes by writer, most first, by standardized path.
    private var waitingChanges: [String: [WaitingCount]] = [:]
    /// The file Quick Look shows.
    private var looking: URL?

    init(folder: Folder?) {
        self.folder = folder
        find = folder.map(FindInFilesController.init)
        header = folder.map { _ in SidebarHeader() }
        gitStates = folder.map { GitStates(folder: $0.url) }
        showsIgnored = Preferences.shared.showsIgnored
        super.init(nibName: nil, bundle: nil)
        find?.reveal = { [weak self] url, match, newTab in self?.reveal(url, match, newTab) }
        find?.close = { [weak self] in self?.showFiles() }
        gitStates?.changed = { [weak self] in self?.refreshRows() }
        watch = folder.map { folder in
            FolderWatch([folder.url]) { [weak self] folders in
                self?.foldersChanged(Set(folders.map(\.standardizedFileURL.path)))
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("SidebarViewController is built in code")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.autoresizesOutlineColumn = false
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .plain
        outlineView.floatsGroupRows = false
        outlineView.backgroundColor = .clear
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.indentationPerLevel = 16
        outlineView.focusRingType = .none
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(clicked(_:))
        outlineView.doubleAction = #selector(doubleClicked(_:))
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.returnPressed = { [weak self] in self?.renameSelected() }
        outlineView.clickedWithoutSelecting = { [weak self] node in
            switch node.kind {
            case .heading(let heading):
                self?.jump(heading)
            case .more:
                self?.showsAllHeadings = true
                self?.listHeadings()
            case .ignored:
                self?.showsIgnored.toggle()
                self?.relist { _ in true }
            default:
                return false
            }
            return true
        }
        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: header == nil ? 6 : 0, left: 0, bottom: 8, right: 0)
        let root = ChromeFill(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        var top = root.topAnchor
        if let header {
            header.picker.folderMenu = { [weak self] in self?.folderMenu() ?? NSMenu() }
            header.actions = { [weak self] in self?.actionsMenu() ?? NSMenu() }
            header.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(header)
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: root.topAnchor),
                header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
            top = header.bottomAnchor
            root.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        }
        if folder == nil {
            let empty = Self.noFolder()
            empty.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
                empty.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
                empty.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            ])
            top = empty.bottomAnchor
        }
        if let find { addChild(find) }
        for content in [scrollView] + (find.map { [$0.view] } ?? []) {
            content.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: top, constant: folder == nil ? 10 : 0),
                content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        find?.view.isHidden = true
        view = root
        refreshHeader()
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged), name: Library.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(changesChanged), name: LiveFile.changesDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: Preferences.didChange, object: nil)
    }

    /// "No folder open" over an Open Folder button.
    private static func noFolder() -> NSView {
        let label = NSTextField(labelWithString: "No folder open")
        label.font = Chrome.label
        label.textColor = Chrome.color(.ink2)
        let button = NSButton(title: "Open Folder…", target: nil, action: #selector(AppDelegate.openFolder(_:)))
        button.bezelStyle = .push
        button.controlSize = .regular
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeMainNotification, object: nil)
        if let window = view.window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowBecameMain), name: NSWindow.didBecomeMainNotification, object: window)
        }
    }

    /// The branch and the waiting changes may have moved while the window was in back.
    @objc private func windowBecameMain() {
        refreshHeader()
        changesChanged()
    }

    override func mouseEntered(with event: NSEvent) {
        header?.showsActions = true
    }

    override func mouseExited(with event: NSEvent) {
        header?.showsActions = false
    }

    /// Lists the rows after the window's first frame, so they never hold it back; they appear in the next one.
    func fillAfterFirstFrame() {
        guard !filled, let window = view.window else { return }
        window.afterDrawing { [weak self] in self?.fill() }
    }

    private func fill() {
        guard !filled else { return }
        filled = true
        tree = folder.map { folder in
            let listing = folder.children(of: folder.url, showingIgnored: showsIgnored)
            let rows = listing.entries.map { SidebarNode(.entry($0)) }
            return SidebarNode(.root(folder.url), children: rows + (listing.ignored.isEmpty ? [] : [SidebarNode(.ignored(listing.ignored))]))
        }
        libraryChanged()
        if let folder {
            for path in UserDefaults.standard.stringArray(forKey: "Expanded " + folder.url.path) ?? [] {
                _ = treeNode(for: folder.url.appending(path: path))
            }
        }
        if let waiting { show(waiting, headings: headings) }
        changesChanged()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        outlineView.sizeLastColumnToFit()
    }

    /// Shows Find in Files in place of the tree, with its field focused, opening the sidebar when it is collapsed.
    func showSearch(_ query: String? = nil) {
        guard let find else { return }
        (parent as? NSSplitViewController)?.splitViewItem(for: self)?.isCollapsed = false
        outlineView.enclosingScrollView?.isHidden = true
        find.view.isHidden = false
        find.begin(query)
    }

    /// Find in Files' query while it shows in place of the tree.
    var searchQuery: String? {
        find.flatMap { $0.view.isHidden ? nil : $0.query }
    }

    func showFiles() {
        find?.view.isHidden = true
        outlineView.enclosingScrollView?.isHidden = false
        view.window?.makeFirstResponder(outlineView)
    }

    /// Shows `url` as the open file: reveals and selects its row. A window without a folder lists its headings.
    func show(_ url: URL?, headings: [Heading]) {
        guard filled else {
            waiting = url
            self.headings = headings
            return
        }
        fileNode = url.flatMap(treeNode(for:))
        showsAllHeadings = false
        section = nil
        updateOutline(headings)
        if let fileNode { outlineView.scrollRowToVisible(outlineView.row(forItem: fileNode)) }
        selectOpenFile()
        refreshRows()
    }

    /// The open file's row is the selected one, through reloads and relisting.
    private func selectOpenFile() {
        let row = fileNode.map { outlineView.row(forItem: $0) } ?? -1
        if row >= 0 {
            if outlineView.selectedRow != row { outlineView.selectRowIndexes([row], byExtendingSelection: false) }
        } else {
            outlineView.deselectAll(nil)
        }
    }

    func updateOutline(_ headings: [Heading]) {
        self.headings = headings
        guard folder == nil else { return }
        listHeadings()
    }

    private func listHeadings() {
        var rows = headings.map { SidebarNode(.heading($0)) }
        if rows.count > 12, !showsAllHeadings {
            rows = rows.prefix(12) + [SidebarNode(.more(rows.count))]
        }
        outlineSection.children = rows
        reload()
    }

    /// Sets in medium the heading whose section holds `location`.
    func markSection(at location: Int) {
        guard folder == nil else { return }
        let current = headings.last { $0.location <= location }?.location
        guard current != section else { return }
        section = current
        outlineView.enumerateAvailableRowViews { rowView, row in
            guard let cell = rowView.view(atColumn: 0) as? SidebarCell,
                case .heading(let heading) = (outlineView.item(atRow: row) as? SidebarNode)?.kind
            else { return }
            cell.show(heading, current: heading.location == current)
        }
    }

    /// Whether the top level is section rows (Pinned, then the tree under "Files", or a folderless window's Outline)
    /// rather than the tree itself.
    private var sectioned: Bool {
        folder == nil || !(pinned.children ?? []).isEmpty
    }

    /// The top-level rows: the sections, or the tree's own rows when nothing is pinned.
    private var topLevel: [SidebarNode] {
        guard sectioned else { return tree.map(children(of:)) ?? [] }
        let main = tree ?? (outlineSection.children!.isEmpty ? nil : outlineSection)
        return ((pinned.children ?? []).isEmpty ? [] : [pinned]) + (main.map { [$0] } ?? [])
    }

    private func reload() {
        guard filled else { return }
        outlineView.sectioned = sectioned
        outlineView.reloadData()
        for section in sectioned ? topLevel : [] where expandedOnce.insert(ObjectIdentifier(section)).inserted {
            outlineView.expandItem(section)
        }
        selectOpenFile()
    }

    /// The tree row for `url`, expanding the folders above it.
    private func treeNode(for url: URL) -> SidebarNode? {
        guard let tree, let path = folder?.relativePath(of: url) else { return nil }
        if sectioned { outlineView.expandItem(tree) }
        var node = tree
        for name in path.split(separator: "/") {
            guard let child = children(of: node).first(where: { $0.url?.lastPathComponent == String(name) }) else { return nil }
            node = child
            if case .entry(let entry) = child.kind, entry.isFolder {
                outlineView.expandItem(child)
            }
        }
        return node
    }

    /// Folders the watch saw change. They wait while a name is edited, since listing them again would end the edit.
    private func foldersChanged(_ paths: Set<String>) {
        guard renaming == nil else {
            changedWhileRenaming.formUnion(paths)
            return
        }
        relist { paths.contains($0.path) }
    }

    /// Lists again each loaded folder that `matches`, keeping the rows that remain so their expansion holds.
    private func relist(_ matches: (URL) -> Bool) {
        guard let folder, let tree else { return }
        func visit(_ node: SidebarNode, _ url: URL) {
            guard let children = node.children else { return }
            if matches(url) {
                let listing = folder.children(of: url, showingIgnored: showsIgnored)
                var kept: [URL: SidebarNode] = [:]
                for child in children {
                    if case .entry(let entry) = child.kind { kept[entry.url] = child }
                }
                node.children = listing.entries.map { kept[$0.url] ?? SidebarNode(.entry($0)) }
                    + (node === tree && !listing.ignored.isEmpty ? [SidebarNode(.ignored(listing.ignored))] : [])
                outlineView.reloadItem(node === tree && !sectioned ? nil : node, reloadChildren: true)
            }
            for child in node.children ?? [] {
                if case .entry(let entry) = child.kind, entry.isFolder { visit(child, entry.url) }
            }
        }
        visit(tree, folder.url)
        if let url = fileNode?.url { fileNode = treeNode(for: url) }
        selectOpenFile()
    }

    private func children(of node: SidebarNode) -> [SidebarNode] {
        if let children = node.children { return children }
        guard case .entry(let entry) = node.kind, entry.isFolder, let folder else { return [] }
        let listing = folder.children(of: entry.url, showingIgnored: showsIgnored)
        let children = listing.entries.map { SidebarNode(.entry($0)) }
        node.children = children
        return children
    }

    @objc private func preferencesChanged() {
        guard Preferences.shared.showsIgnored != showsIgnored else { return }
        showsIgnored = Preferences.shared.showsIgnored
        relist { _ in true }
    }

    @objc private func libraryChanged() {
        guard filled else { return }
        pinned.children = Library.pins.map { url in
            SidebarNode(.shortcut(FolderEntry(url: url, isFolder: url.hasDirectoryPath)))
        }
        reload()
    }

    /// A click opens a note in this tab and a Command-click in a new one; any other file opens in Quick Look.
    @objc private func clicked(_ sender: Any?) {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode else { return }
        let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        switch node.kind {
        case .entry(let entry) where entry.isFolder:
            outlineView.isItemExpanded(node) ? outlineView.collapseItem(node) : outlineView.expandItem(node)
        case .entry(let entry) where entry.isMarkdown || isAgentFile(entry.url):
            open(entry.url, newTab)
        case .entry(let entry):
            quickLook(entry.url)
        case .shortcut(let entry):
            if entry.isFolder {
                (NSApp.delegate as? AppDelegate)?.openFolder(at: entry.url)
            } else {
                open(entry.url, newTab)
            }
        default:
            break
        }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode,
            case .entry(let entry) = node.kind, entry.isMarkdown
        else { return }
        open(entry.url, true)
    }

    /// A folder's chevron turns as it opens and closes.
    /// The chevron, and the roll-up a closed folder shows in place of its notes' badges.
    private func reloadChevron(_ node: SidebarNode) {
        let row = outlineView.row(forItem: node)
        guard row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarFileCell else { return }
        show(node, in: cell)
    }

    // MARK: The header

    /// File > Open Folder…, whose key the header shows.
    private static var openFolderItem: NSMenuItem? {
        NSApp.mainMenu?.items.lazy.compactMap { $0.submenu?.items.first { $0.action == #selector(AppDelegate.openFolder(_:)) } }.first
    }

    /// The folder's name and branch, and Open Folder's key as the main menu has it.
    private func refreshHeader() {
        guard let header, let folder else { return }
        let key = Self.openFolderItem.map { KeyEquivalent($0.keyEquivalent, $0.keyEquivalentModifierMask).glyphs } ?? ""
        header.picker.show(FileManager.default.displayName(atPath: folder.url.path), branch: gitBranch(at: folder.url), openKey: key)
    }

    /// The folder pop-up: Open Folder…, Open Recent, Copy Branch Name, Reveal in Finder.
    private func folderMenu() -> NSMenu {
        let menu = NSMenu()
        guard let folder else { return menu }
        let open = menu.addItem(withTitle: "Open Folder\u{2026}", action: #selector(AppDelegate.openFolder(_:)), keyEquivalent: "")
        if let item = Self.openFolderItem {
            open.keyEquivalent = item.keyEquivalent
            open.keyEquivalentModifierMask = item.keyEquivalentModifierMask
        }
        let recent = NSMenu()
        for visit in Library.recentFolders where visit.url.standardizedFileURL.path != folder.url.path {
            let item = recent.addItem(withTitle: FileManager.default.displayName(atPath: visit.url.path), action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = visit.url
            item.toolTip = abbreviatedPath(visit.url)
        }
        let recents = menu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        recents.submenu = recent
        recents.isEnabled = !recent.items.isEmpty
        let branch = gitBranch(at: folder.url)
        let copy = menu.addItem(withTitle: "Copy Branch Name", action: branch == nil ? nil : #selector(copyBranch(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = branch
        menu.addItem(.separator())
        let finder = menu.addItem(withTitle: "Reveal in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
        finder.target = self
        finder.representedObject = folder.url
        return menu
    }

    /// "…": New Folder and Collapse All.
    private func actionsMenu() -> NSMenu {
        let menu = NSMenu()
        guard let url = folder?.url else { return menu }
        menu.addItem(withTitle: "New Folder", action: FileCommand.newFolder, keyEquivalent: "").representedObject = url
        menu.addItem(withTitle: "Collapse All", action: #selector(collapseAll), keyEquivalent: "").target = self
        return menu
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        _ = (NSApp.delegate as? AppDelegate)?.openFolder(at: sender.representedObject as! URL)
    }

    @objc private func copyBranch(_ sender: NSMenuItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sender.representedObject as! String, forType: .string)
    }

    @objc private func collapseAll() {
        for child in tree?.children ?? [] where outlineView.isItemExpanded(child) {
            outlineView.collapseItem(child, collapseChildren: true)
        }
    }

    // MARK: Waiting changes and git

    /// Counts each note's undecided changes by writer, from the window's tabs, as Activity does; a note changed while
    /// closed gets its writer without a count.
    @objc private func changesChanged() {
        guard filled else { return }
        var waiting: [String: [WaitingCount]] = [:]
        for note in Review.closedNotes() {
            let path = note.url.standardizedFileURL.path
            let writer = MarkWriter(note.origin)
            if !(waiting[path] ?? []).contains(where: { $0.writer.name == writer.name }) {
                waiting[path, default: []].append(WaitingCount(writer: writer, count: nil))
            }
        }
        for live in Review.files(in: view.window) {
            var counts: [WaitingCount] = []
            for change in live.changes.values where change.marked {
                let writer = MarkWriter(change.origin)
                if let index = counts.firstIndex(where: { $0.writer.name == writer.name }) {
                    counts[index] = WaitingCount(writer: writer, count: (counts[index].count ?? 0) + 1)
                } else {
                    counts.append(WaitingCount(writer: writer, count: 1))
                }
            }
            if !counts.isEmpty { waiting[live.url.standardizedFileURL.path] = counts.sorted { $0.count ?? 0 > $1.count ?? 0 } }
        }
        waitingChanges = waiting
        refreshRows()
    }

    /// Shows the badges and git words again on the rows on screen.
    private func refreshRows() {
        outlineView.enumerateAvailableRowViews { rowView, row in
            guard let node = outlineView.item(atRow: row) as? SidebarNode, let cell = rowView.view(atColumn: 0) as? SidebarFileCell else { return }
            show(node, in: cell)
        }
    }

    private func show(_ node: SidebarNode, in cell: SidebarFileCell) {
        switch node.kind {
        case .entry(let entry):
            let path = entry.url.standardizedFileURL.path
            let expanded = entry.isFolder && outlineView.isItemExpanded(node)
            let badges = entry.isFolder ? expanded ? [] : rollUp(under: path) : node === fileNode ? [] : waitingChanges[path] ?? []
            cell.show(entry, gone: false, expanded: expanded, waiting: badges, git: gitStates?.state(of: entry.url))
        case .shortcut(let entry):
            let path = entry.url.standardizedFileURL.path
            cell.show(entry, gone: !FileManager.default.fileExists(atPath: entry.url.path), expanded: false,
                waiting: path == fileNode?.url?.standardizedFileURL.path ? [] : waitingChanges[path] ?? [], git: nil)
        default:
            break
        }
    }

    /// A closed folder's roll-up: each writer with changes waiting in a note under it, without counts.
    private func rollUp(under folder: String) -> [WaitingCount] {
        let open = fileNode?.url?.standardizedFileURL.path
        var writers: [WaitingCount] = []
        for (path, counts) in waitingChanges.sorted(by: { $0.key < $1.key }) where path.hasPrefix(folder + "/") && path != open {
            for count in counts where !writers.contains(where: { $0.writer.name == count.writer.name }) {
                writers.append(WaitingCount(writer: count.writer, count: nil))
            }
        }
        return writers
    }

    /// The row's indent guides: one per enclosing folder, under its chevron.
    private func decorate(_ rowView: NSTableRowView, row: Int) {
        guard let rowView = rowView as? SidebarRowView else { return }
        rowView.guides = (0..<outlineView.depth(ofRow: row)).map { SidebarOutlineView.guideX($0) }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode else {
            if let url = folder?.url {
                menu.addItem(withTitle: "New Note", action: FileCommand.newNote, keyEquivalent: "").representedObject = url
                menu.addItem(withTitle: "New Folder", action: FileCommand.newFolder, keyEquivalent: "").representedObject = url
                menu.addItem(.separator())
                let finder = menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
                finder.target = self
                finder.representedObject = url
            }
            return
        }
        guard let url = node.url else { return }
        let isFolder: Bool
        switch node.kind {
        case .root: isFolder = true
        case .entry(let entry), .shortcut(let entry): isFolder = entry.isFolder
        default: return
        }
        func add(_ title: String, _ action: Selector, _ object: Any = url, mine: Bool = false) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = mine ? self : nil
            item.representedObject = object
        }
        if !isFolder, url.pathExtension.lowercased() == "md" || isAgentFile(url) {
            add("Open in New Tab", #selector(openInNewTab(_:)), mine: true)
        }
        let container = isFolder ? url : url.deletingLastPathComponent()
        add("New Note", FileCommand.newNote, container)
        add("New Folder", FileCommand.newFolder, container)
        menu.addItem(.separator())
        if case .entry = node.kind {
            add("Rename", #selector(renameClicked(_:)), node, mine: true)
            add("Duplicate", FileCommand.duplicate)
            add("Move to Trash", FileCommand.trash)
            menu.addItem(.separator())
        }
        let isPinned = Library.pins.contains { $0.path == url.path }
        add(isPinned ? "Unpin" : "Pin", isPinned ? #selector(unpin(_:)) : #selector(pin(_:)), mine: true)
        add("Show in Finder", #selector(showInFinder(_:)), mine: true)
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        open(sender.representedObject as! URL, true)
    }

    @objc private func pin(_ sender: NSMenuItem) {
        Library.setPinned(sender.representedObject as! URL, true)
    }

    @objc private func unpin(_ sender: NSMenuItem) {
        Library.setPinned(sender.representedObject as! URL, false)
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        NSWorkspace.shared.activateFileViewerSelecting([sender.representedObject as! URL])
    }

    // MARK: Rename in place

    @objc private func renameClicked(_ sender: NSMenuItem) {
        beginRename(sender.representedObject as! SidebarNode)
    }

    /// Return on a selected file or folder edits its name in place.
    private func renameSelected() {
        guard let node = outlineView.item(atRow: outlineView.selectedRow) as? SidebarNode, case .entry = node.kind else { return }
        beginRename(node)
    }

    /// Lists the new folder at `url` at once, reveals it and makes its name editable.
    func renameNew(_ url: URL) {
        guard filled else { return }
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        relist { $0.standardizedFileURL.path == parent }
        guard let node = treeNode(for: url) else { return }
        outlineView.collapseItem(node)
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.scrollRowToVisible(row)
        beginRename(node)
    }

    /// Makes the row's name editable, its base name selected.
    func beginRename(_ node: SidebarNode) {
        let row = outlineView.row(forItem: node)
        guard row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarFileCell,
            let field = cell.textField
        else { return }
        cell.beginEditing()
        renaming = node
        field.isEditable = true
        field.delegate = self
        guard view.window?.makeFirstResponder(field) == true else {
            renaming = nil
            field.isEditable = false
            field.delegate = nil
            cell.endEditing()
            return
        }
        let name = field.stringValue as NSString
        let base = name.deletingPathExtension as NSString
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: base.length == 0 ? name.length : base.length)
    }

    /// Return asks FileActions for the rename; Escape puts the old name back.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let node = renaming, let url = node.url else { return }
        renaming = nil
        field.isEditable = false
        field.delegate = nil
        let cancelled = (notification.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.cancel.rawValue
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        (field.superview as? SidebarFileCell)?.endEditing()
        if !changedWhileRenaming.isEmpty {
            let changed = changedWhileRenaming
            changedWhileRenaming = []
            relist { changed.contains($0.path) }
        }
        if !cancelled, !name.isEmpty, name != url.lastPathComponent, !name.contains("/") {
            FileCommand.send(FileCommand.rename, RenameRequest(url: url, name: name), from: outlineView)
        }
        view.window?.makeFirstResponder(outlineView)
    }

    // MARK: Quick Look

    private func quickLook(_ url: URL) {
        looking = url
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        looking != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { looking == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { looking as NSURL? }
    }

    // MARK: Moving rows

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard case .entry(let entry) = (item as! SidebarNode).kind else { return nil }
        return entry.url as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let target = dropFolder(item), info.draggingSource as? NSOutlineView === outlineView else { return [] }
        let urls = draggedURLs(info)
        guard !urls.isEmpty, !urls.contains(where: { $0 == target || target.path.hasPrefix($0.path + "/") || $0.deletingLastPathComponent() == target }) else { return [] }
        outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let target = dropFolder(item) else { return false }
        return FileCommand.send(FileCommand.move, MoveRequest(urls: draggedURLs(info), folder: target), from: outlineView)
    }

    /// The folder a drop on `item` lands in: the row's folder, or the folder of the file it is on. A drop between
    /// top-level rows of an unsectioned tree lands in the root.
    private func dropFolder(_ item: Any?) -> URL? {
        guard let node = item as? SidebarNode else { return sectioned ? nil : folder?.url }
        switch node.kind {
        case .root(let url): return url
        case .entry(let entry): return entry.isFolder ? entry.url : entry.url.deletingLastPathComponent()
        default: return nil
        }
    }

    private func draggedURLs(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    // MARK: Data source and delegate

    func outlineViewItemDidExpand(_ notification: Notification) {
        rememberExpansion(notification, expanded: true)
        (notification.userInfo?["NSObject"] as? SidebarNode).map(reloadChevron)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        rememberExpansion(notification, expanded: false)
        (notification.userInfo?["NSObject"] as? SidebarNode).map(reloadChevron)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        if case .entry = (item as! SidebarNode).kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        decorate(rowView, row: row)
    }

    /// Expands and collapses the tree to the folders kept in user defaults, which another tab may have changed.
    func adoptExpansion() {
        guard filled, let folder, tree != nil else { return }
        let kept = Set(UserDefaults.standard.stringArray(forKey: "Expanded " + folder.url.path) ?? [])
        for row in (0..<outlineView.numberOfRows).reversed() {
            guard let node = outlineView.item(atRow: row) as? SidebarNode, outlineView.isItemExpanded(node), case .entry(let entry) = node.kind,
                entry.isFolder, let path = folder.relativePath(of: entry.url), !kept.contains(path)
            else { continue }
            outlineView.collapseItem(node)
        }
        for path in kept.sorted() {
            _ = treeNode(for: folder.url.appending(path: path))
        }
    }

    /// Keeps each root's expanded folders in user defaults; collapsing a folder forgets the folders inside it.
    private func rememberExpansion(_ notification: Notification, expanded: Bool) {
        guard let folder, let node = notification.userInfo?["NSObject"] as? SidebarNode,
            case .entry(let entry) = node.kind, entry.isFolder, let path = folder.relativePath(of: entry.url)
        else { return }
        let key = "Expanded " + folder.url.path
        var paths = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        if expanded {
            paths.insert(path)
        } else {
            paths = paths.filter { $0 != path && !$0.hasPrefix(path + "/") }
        }
        UserDefaults.standard.set(paths.sorted(), forKey: key)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode).map { children(of: $0).count } ?? (filled ? topLevel.count : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode).map { children(of: $0)[index] } ?? topLevel[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        let node = item as! SidebarNode
        switch node.kind {
        case .section, .root: return true
        case .entry(let entry): return entry.isFolder
        default: return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        switch (item as! SidebarNode).kind {
        case .entry(let entry), .shortcut(let entry): entry.url.lastPathComponent
        default: nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        switch (item as! SidebarNode).kind {
        case .section, .root: true
        default: false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        switch (item as! SidebarNode).kind {
        case .entry, .shortcut: true
        default: false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! SidebarNode
        switch node.kind {
        case .root:
            let cell = cell(SidebarCell.header)
            cell.show("Files")
            return cell
        case .section(let title):
            let cell = cell(SidebarCell.header)
            cell.show(title)
            return cell
        case .entry, .shortcut:
            let cell = outlineView.makeView(withIdentifier: SidebarFileCell.identifier, owner: nil) as? SidebarFileCell ?? SidebarFileCell()
            show(node, in: cell)
            return cell
        case .heading(let heading):
            let cell = cell(SidebarCell.heading)
            cell.show(heading, current: heading.location == section)
            cell.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Go to Heading") { [weak self] in
                self?.jump(heading)
                return true
            }])
            return cell
        case .ignored(let names):
            let cell = cell(SidebarCell.note)
            cell.textField?.stringValue = showsIgnored ? "Hide what .gitignore hides"
                : names.count > 2 ? "\(names.count) items hidden by .gitignore"
                : names.joined(separator: ", ") + " hidden by .gitignore"
            cell.toolTip = names.joined(separator: "\n")
            cell.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: showsIgnored ? "Hide Ignored Items" : "Show Ignored Items") { [weak self] in
                self?.showsIgnored.toggle()
                self?.relist { _ in true }
                return true
            }])
            return cell
        case .more(let count):
            let cell = cell(SidebarCell.note)
            cell.textField?.stringValue = "Show all \(count)"
            cell.toolTip = nil
            cell.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Show All Headings") { [weak self] in
                self?.showsAllHeadings = true
                self?.listHeadings()
                return true
            }])
            return cell
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch (item as! SidebarNode).kind {
        case .heading, .more: 22
        default: 24
        }
    }

    private func cell(_ identifier: NSUserInterfaceItemIdentifier) -> SidebarCell {
        outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarCell ?? SidebarCell(identifier)
    }
}

/// Headings and Show All act on mouse down and never take the selection, which stays on the open file. Rows draw
/// their own chevrons, so the system's disclosure triangles are gone. A top-level cell starts 8 pt in, each level
/// 16 pt further, so names sit on the pane edge + 30. Return on a row renames it.
private final class SidebarOutlineView: NSOutlineView {
    /// The guide for the folder at `depth` runs under its chevron: x 14, then 16 pt a level.
    static func guideX(_ depth: Int) -> CGFloat {
        14 + CGFloat(depth) * 16
    }

    var clickedWithoutSelecting: (SidebarNode) -> Bool = { _ in false }
    var returnPressed: () -> Void = {}
    /// Whether the top level is section rows, so the tree starts a level down.
    var sectioned = false

    /// The row's level within the tree or its section, from 0.
    func depth(ofRow row: Int) -> Int {
        max(level(forRow: row) - (sectioned ? 1 : 0), 0)
    }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if let node = item(atRow: row) as? SidebarNode, clickedWithoutSelecting(node) { return }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            returnPressed()
            return
        }
        super.keyDown(with: event)
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        .zero
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        let x = 8 + CGFloat(depth(ofRow: row)) * indentationPerLevel
        return NSRect(x: x, y: frame.minY, width: max(bounds.width - x - 16, 0), height: frame.height)
    }
}

/// "now", "2m", "3h", "4d", then the date: short relative times for lists.
func relativeTime(_ date: Date, now: Date = .now) -> String {
    let seconds = now.timeIntervalSince(date)
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(Int(seconds / 60))m"
    case ..<86_400: return "\(Int(seconds / 3600))h"
    case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
    default: return shortDate(date, now: now)
    }
}

/// One sidebar row other than a file's: a section label, a heading, or a note, which lines up with file names. Text is
/// `ink2`; the current heading's is `ink`.
private final class SidebarCell: NSTableCellView, ChromeSelectable {
    static let header = NSUserInterfaceItemIdentifier("header")
    static let heading = NSUserInterfaceItemIdentifier("heading")
    static let note = NSUserInterfaceItemIdentifier("note")

    private var indent: NSLayoutConstraint?
    private var current = false

    var selected = false {
        didSet { paint() }
    }

    init(_ identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.font = Chrome.label
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = label
        addSubview(label)
        var constraints = [
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ]
        switch identifier {
        case Self.header:
            label.font = Chrome.section
            constraints.append(label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4))
        case Self.heading:
            label.font = Chrome.small
            let indent = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20)
            self.indent = indent
            constraints.append(indent)
        default:
            label.font = Chrome.small
            constraints.append(label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22))
        }
        NSLayoutConstraint.activate(constraints)
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
        paint()
    }

    required init?(coder: NSCoder) {
        fatalError("SidebarCell is built in code")
    }

    @objc private func themeDidChange() {
        paint()
    }

    private func paint() {
        if identifier == Self.header {
            textField?.textColor = Chrome.color(.ink2)
            return
        }
        if identifier == Self.heading {
            textField?.font = current ? .systemFont(ofSize: 12, weight: .medium) : Chrome.small
        }
        textField?.textColor = Chrome.color(selected || current ? .ink : .ink2)
    }

    func show(_ title: String) {
        textField?.stringValue = title
        paint()
    }

    func show(_ heading: Heading, current: Bool) {
        self.current = current
        textField?.stringValue = heading.title
        indent?.constant = 4 + CGFloat(heading.level - 1) * 10
        paint()
    }
}
