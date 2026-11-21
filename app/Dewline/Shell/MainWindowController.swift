import AppKit
import MdCore

/// One tab: the sidebar, the open note in the editor column with the status bar under it, and the right pane. The
/// window's content runs under a transparent title bar on the chrome ground, with a compact toolbar for its title row
/// and the window's title hidden; the tabs are in that row. Each tab has its own window; its `TabSet` keeps only the
/// selected one on screen.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarItemValidation {
    /// Every tab, kept here because a folder window has no document to own its controller.
    private static var all: Set<MainWindowController> = []
    /// The notes of tabs closed in this run, newest last, with their windows' folders, for Reopen Closed Tab.
    private static var closed: [(url: URL, folder: Folder?)] = []

    let folder: Folder?
    /// The folder's Markdown files for Quick Open, shared with the folder's other tabs.
    let index: FolderIndex?
    let sidebar: SidebarViewController
    private let split = StationSplitController()
    private let toolbar: WindowToolbar
    /// The editor column: the page and the status bar, top to bottom.
    private let column = PaperView()
    /// This window's tabs, shared with the tabs beside this one.
    private(set) var tabs: TabSet!
    private let page = NSView()
    private var pageContent: NSView?
    let statusBar = StatusBar()
    let pane: RightPane
    private let paneItem: NSSplitViewItem
    /// The right pane collapsed the sidebar to make room, so closing the pane brings it back.
    private var paneHidSidebar = false
    /// A window narrower than 700 pt collapsed the sidebar, so widening it brings it back.
    private var narrowHidSidebar = false
    private(set) var textView: EditorTextView?
    private var outlineUpdate: Task<Void, Never>?
    private var sectionUpdate: Task<Void, Never>?
    private var history = History() {
        didSet { updateNavigation() }
    }
    private var countUpdate: Task<Void, Never>?
    private var linkUpdate: Task<Void, Never>?
    private var loadsUpdate: Task<Void, Never>?
    /// "1,204 words", or "38 of 1,204 words" with a selection, for the tab's tooltip.
    private(set) var wordCount = ""
    /// What agents load for the note's folder, for Activity's menu.
    private(set) var agentLoads: [AgentRow] = []
    private var edited = false
    /// A resumed tab's file and place, read when the tab is first selected.
    private var pending: Session.Tab? {
        didSet { tabs?.post() }
    }

    /// A tab beside `neighbor`, in its window, or a window of its own.
    init(folder: Folder?, joining neighbor: MainWindowController? = nil) {
        self.folder = folder
        index = folder.map(FolderIndex.of)
        sidebar = SidebarViewController(folder: folder)
        pane = RightPane(folder: folder)
        // A plain item, which keeps its width as the window resizes; the sidebar draws the system's sidebar material.
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 320
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        let columnController = NSViewController()
        columnController.view = column
        let columnItem = NSSplitViewItem(viewController: columnController)
        columnItem.minimumThickness = 360
        paneItem = NSSplitViewItem(viewController: pane)
        paneItem.canCollapse = true
        paneItem.isCollapsed = true
        paneItem.minimumThickness = RightPane.widths.lowerBound
        paneItem.maximumThickness = RightPane.widths.upperBound
        paneItem.holdingPriority = NSLayoutConstraint.Priority(259)
        split.splitViewItems = [sidebarItem, columnItem, paneItem]
        toolbar = WindowToolbar(split: split.splitView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = MainWindowController.underTitleRow(split)
        window.setContentSize(NSSize(width: 1200, height: 760))
        // Dewline draws the tabs, so each keeps its own document, sheets and undo.
        window.tabbingMode = .disallowed
        // Resume reopens every window at launch, so AppKit restores none.
        window.isRestorable = false
        window.toolbar = toolbar.toolbar
        window.toolbarStyle = .unifiedCompact
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Chrome.color(.chrome)
        window.identifier = NSUserInterfaceItemIdentifier("Document")
        MainWindowController.lay(page: page, status: statusBar, in: column)
        sidebar.view.setFrameSize(NSSize(width: 264, height: sidebar.view.frame.height))
        if let front = neighbor?.window ?? NSApp.orderedWindows.first(where: { $0.isVisible && $0.windowController is MainWindowController }) {
            if neighbor == nil {
                window.cascadeTopLeft(from: front.cascadeTopLeft(from: .zero))
            } else {
                window.setFrame(front.frame, display: false)
            }
        } else {
            window.center()
        }
        super.init(window: window)
        if let neighbor {
            tabs = neighbor.tabs
            tabs.insert(self, after: neighbor)
            if !neighbor.paneItem.isCollapsed { adoptPane(from: neighbor) }
        } else {
            tabs = TabSet(self)
        }
        toolbar.strip.tabs = tabs
        // Activity counts the window's tabs' notes, so it gets the window once it has tabs.
        toolbar.window = window
        window.delegate = self
        sidebar.open = { [weak self] url, newTab in self?.open(url, newTab: newTab) }
        sidebar.jump = { [weak self] heading in self?.jump(to: heading) }
        sidebar.reveal = { [weak self] url, match, newTab in self?.reveal(match, in: url, newTab: newTab) }
        pane.picked = { [weak self] tab in self?.tabs.tabs.forEach { $0.showPane(tab) } }
        pane.backlinks.open = { [weak self] url, range in self?.open(url, selecting: range) }
        #if COLLAB
        NotificationCenter.default.addObserver(self, selector: #selector(updatePresence), name: Collaboration.changed, object: nil)
        #endif
        NotificationCenter.default.addObserver(self, selector: #selector(changesChanged), name: LiveFile.changesDidChange, object: nil)
        for name in [ClosedChanges.changed, TabSet.changed] {
            NotificationCenter.default.addObserver(self, selector: #selector(countChanges), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateMinimumSize), name: NSSplitView.didResizeSubviewsNotification, object: split.splitView)
        updateMinimumSize()
        statusBar.reserved = folder != nil
        Self.all.insert(self)
        if let folder {
            window.title = FileManager.default.displayName(atPath: folder.url.path)
            window.representedURL = folder.url
            setPage(emptyPage(in: folder.url))
        }
        updateTitle()
        updateNavigation()
        updateState()
    }

    required init?(coder: NSCoder) {
        fatalError("MainWindowController is built in code")
    }

    /// The split in a view that keeps it below the title row, whose ground is the window's chrome.
    private static func underTitleRow(_ split: NSSplitViewController) -> NSViewController {
        let root = NSViewController()
        root.view = NSView()
        root.addChild(split)
        split.view.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(split.view)
        NSLayoutConstraint.activate([
            split.view.topAnchor.constraint(equalTo: root.view.safeAreaLayoutGuide.topAnchor),
            split.view.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            split.view.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
        ])
        return root
    }

    /// The page, and the status bar along the bottom.
    private static func lay(page: NSView, status: StatusBar, in column: NSView) {
        for view in [page, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(view)
        }
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: column.topAnchor),
            page.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
    }

    /// The empty page's Set Up Agent Hooks… button, or "Agent hooks are on.", once `dewline doctor` answers.
    private let hookButton = NSButton(title: "Set Up Agent Hooks\u{2026}", target: nil, action: #selector(setUpAgentHooks(_:)))
    private let hookNote = NSTextField(labelWithString: "Agent hooks are on.")
    /// Under Copy a Test Prompt: how its edit shows, with hooks or without.
    private var hookHint: NSTextField?

    /// The page of a folder with no note open: what an agent's edit does, then what waits for review in the folder and
    /// what git has uncommitted, each file opening on Return or a click, or with nothing listed, how to pick or make a
    /// note; then Open CLAUDE.md (or README.md), the default, beside Set Up Agent Hooks… while no agent has them, and
    /// Copy a Test Prompt.
    private func emptyPage(in folder: URL) -> NSView {
        func label(_ text: String, _ ink: Token) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = Chrome.label
            label.textColor = Chrome.color(ink)
            label.alignment = .center
            label.preferredMaxLayoutWidth = 360
            return label
        }
        let title = label("Dewline is watching \(FileManager.default.displayName(atPath: folder.path)).", .ink)
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let prose = [
            label("Ask an agent to edit a note here; the change shows marked, ready to keep or revert.", .ink2),
            label("Pick a note in the sidebar, or press \u{2318}N\u{00A0}for\u{00A0}a\u{00A0}new\u{00A0}one.", .ink2),
        ]
        let waiting = WaitingNotes(in: folder, git: index?.git) { [weak self] url in self?.openAtFirstChange(url) }
        waiting.changed = { empty in prose[1].isHidden = !empty }
        let stack = NSStackView(views: [title, prose[0], waiting, prose[1]])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: title)
        stack.setCustomSpacing(12, after: prose[0])
        let buttons = NSStackView()
        buttons.distribution = .fillEqually
        buttons.spacing = 12
        if let suggested = ["CLAUDE.md", "README.md"].map({ folder.appending(path: $0) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            let open = NSButton(title: "Open \(suggested.lastPathComponent)", target: self, action: #selector(openSuggested(_:)))
            open.identifier = NSUserInterfaceItemIdentifier(suggested.path)
            open.keyEquivalent = "\r"
            buttons.addArrangedSubview(open)
        }
        hookButton.target = self
        hookButton.isHidden = true
        buttons.addArrangedSubview(hookButton)
        hookNote.font = Chrome.label
        hookNote.textColor = Chrome.color(.ink2)
        hookNote.isHidden = true
        let tryIt = label(Self.hookHint(on: false), .ink2)
        hookHint = tryIt
        let copy = NSButton(title: "Copy a Test Prompt", target: self, action: #selector(copyTestPrompt(_:)))
        copy.toolTip = Self.testPrompt(in: folder)
        let test = NSStackView(views: [hookNote, copy, tryIt])
        test.orientation = .vertical
        test.spacing = 6
        for view in [buttons, test] {
            stack.addView(view, in: .center)
            stack.setCustomSpacing(14, after: stack.views[stack.views.count - 2])
        }
        waiting.reload()
        updateHookLine(in: folder)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let empty = PaperView()
        empty.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: empty.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            waiting.widthAnchor.constraint(equalToConstant: 420),
        ])
        return empty
    }

    /// Set Up Agent Hooks… while no agent has them, else "Agent hooks are on." over Copy a Test Prompt. The test host
    /// runs no doctor.
    private func updateHookLine(in folder: URL) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Task { [weak self] in
            let on = await Task.detached { HookStatus.read(in: folder).any }.value
            guard let self else { return }
            hookButton.isHidden = on
            hookNote.isHidden = !on
            hookHint?.stringValue = Self.hookHint(on: on)
        }
    }

    /// How the test prompt's edit shows: named with hooks, as Another app without.
    static func hookHint(on: Bool) -> String {
        on ? "Run it in Claude Code here; the edit shows up marked." : "Run it in Claude Code here; without hooks, the edit lands marked as Another app."
    }

    /// A prompt that makes an agent edit a note here, for the first marked change.
    static func testPrompt(in folder: URL) -> String {
        let note = FileManager.default.fileExists(atPath: folder.appending(path: "README.md").path) ? "README.md" : "dewline-test.md"
        return "Add a line \"Dewline test\" to the end of \(note)."
    }

    @objc private func copyTestPrompt(_ sender: Any?) {
        guard let folder else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.testPrompt(in: folder.url), forType: .string)
        statusBar.post(.init(id: "prompt", kind: .result, text: "Copied. Paste it into Claude Code running in this folder.", untilTyping: true))
    }

    @objc private func openSuggested(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        open(URL(filePath: path), newTab: false)
    }

    @objc private func setUpAgentHooks(_ sender: Any?) {
        guard let folder else { return }
        HookSetup.install(from: window, in: folder.url) { [weak self] _ in self?.updateHookLine(in: folder.url) }
    }

    override func setDocumentEdited(_ dirtyFlag: Bool) {
        super.setDocumentEdited(dirtyFlag)
        guard dirtyFlag != edited else { return }
        edited = dirtyFlag
        updateState()
        tabs?.post()
    }

    /// The note's name without its extension, so the title and its rename popover read as the note.
    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        (displayName as NSString).deletingPathExtension.isEmpty ? displayName : (displayName as NSString).deletingPathExtension
    }

    /// The tab's name: its note's, or its folder's while the page is empty.
    var tabName: String {
        if let document = document as? NSDocument { return windowTitle(forDocumentDisplayName: document.displayName) }
        if let pending { return (FileManager.default.displayName(atPath: pending.path) as NSString).deletingPathExtension }
        return folder.map { FileManager.default.displayName(atPath: $0.url.path) } ?? "Untitled"
    }

    /// A rename or Save As changes the tab's name.
    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        tabs?.post()
    }

    /// The tab's file name with its extension, as the tab strip and the Window menu show it.
    var tabFileName: String {
        if let url = (document as? NSDocument)?.fileURL { return url.lastPathComponent }
        if let pending { return URL(filePath: pending.path).lastPathComponent }
        return tabName
    }

    @objc func showNextTab(_ sender: Any?) {
        tabs.tab(1)?.showWindow(sender)
    }

    @objc func showPreviousTab(_ sender: Any?) {
        tabs.tab(-1)?.showWindow(sender)
    }

    /// The title is the note's name, set by its document; the subtitle is the folder the note is in.
    private func updateTitle() {
        guard let window else { return }
        let url = (document as? NSDocument)?.fileURL
        let folderURL = url?.deletingLastPathComponent() ?? folder?.url
        window.subtitle = url == nil ? "" : folderURL.map { FileManager.default.displayName(atPath: $0.path) } ?? ""
        if document == nil, pageContent != nil, folder == nil { window.title = "Dewline" }
    }

    #if COLLAB
    /// The people editing the note with you, which File > Share counts.
    private var peers: Int {
        (document as? NSDocument).flatMap { Collaboration.of($0)?.share.peers.count } ?? 0
    }

    @objc private func updatePresence() {
        showRequest()
    }

    private static let requestMessage = "share-request"

    /// "Ana asks to join · Approve · Deny" for this window's shared note, so a closed popover still shows the request.
    private func showRequest() {
        guard let document = document as? NSDocument,
            let (collaboration, peer) = Collaboration.asking.first(where: { $0.collaboration.document === document })
        else { return statusBar.clear(Self.requestMessage) }
        statusBar.post(.init(id: Self.requestMessage, kind: .request, text: "\(peer.name) asks to join", actions: [
            .init(title: "Approve") { _ in collaboration.share.approve(peer.id) },
            .init(title: "Deny") { _ in collaboration.share.deny(peer.id) },
        ]))
    }
    #endif

    @objc private func changesChanged() {
        updateState()
        countChanges()
    }

    /// The Changes segment counts what Activity does: the window's marked changes and its notes changed while closed.
    @objc private func countChanges() {
        pane.changesCount = Review.waitingCount(in: window)
    }

    @objc private func themeDidChange() {
        window?.backgroundColor = Chrome.color(.chrome)
    }

    private static let awaitedMessage = "awaited"
    private static let heldMessage = "held"
    private static let draftMessage = "draft"

    /// A terminal waiting on the note, why its last autosave wrote nothing, and a draft kept from before it opened,
    /// in the status bar.
    private func updateState() {
        let document = document as? MarkdownDocument
        if document?.isAwaited == true {
            statusBar.post(.init(id: Self.awaitedMessage, kind: .request, text: "A terminal is waiting for this note", actions: [
                .init(title: "Done") { [weak self] _ in self?.window?.performClose(nil) },
            ]))
        } else {
            statusBar.clear(Self.awaitedMessage)
        }
        let live = document?.live
        if live?.changes.values.contains(where: \.conflict) == true {
            statusBar.post(.init(id: Self.heldMessage, kind: .problem, text: "Saving waits until you choose"))
        } else if let document, let reason = live?.refusal.flatMap(Self.reason) {
            statusBar.post(.init(id: Self.heldMessage, kind: .problem, text: "Not saved: \(reason)", actions: [
                .init(title: "Save Now") { _ in document.save(nil) },
            ]))
        } else {
            statusBar.clear(Self.heldMessage)
        }
        if let live, let draft = live.draft {
            statusBar.post(.init(id: Self.draftMessage, kind: .question, text: "Unsaved text from \(Self.time(draft.time)) was kept", actions: [
                .init(title: "Restore") { _ in Task { await live.restoreDraft() } },
                .init(title: "Discard") { _ in live.discardDraft() },
            ]))
        } else {
            statusBar.clear(Self.draftMessage)
        }
    }

    /// Why an autosave wrote nothing, for the status bar; nil for a wait that ends on its own soon, an IME composition
    /// or Writing Tools.
    private static func reason(_ refusal: ChangeEngine.Refusal) -> String? {
        switch refusal {
        case .held: "an agent is writing this note"
        case .changed: "the file changed on disk"
        case .deleted: "the file was deleted"
        case .unreadable: "the file can\u{2019}t be read"
        case .io(let message): message
        case .closed, .readOnly, .stale, .conflict, .composing, .writingTools: nil
        }
    }

    /// "Saved 15:31", or "Not saved yet" while an edit waits; nil for a tab without a note.
    var savedState: String? {
        guard let document = document as? NSDocument else { return nil }
        guard !edited, document.fileURL != nil else { return "Not saved yet" }
        guard let date = document.fileModificationDate else { return "Saved" }
        return "Saved \(Self.time(date))"
    }

    /// "15:31" today, else with the date.
    private static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Selects this tab, in its window's place, and brings it front.
    override func showWindow(_ sender: Any?) {
        if let window, !window.isVisible, !window.isMiniaturized, tabs.tabs.count == 1 { Self.fill(window) }
        let place = readPending()
        tabs.select(self)
        super.showWindow(sender)
        enterSharedFullScreen()
        (NSApp.delegate as? AppDelegate)?.closeLaunchWindow()
        if let window { Updates.shared.windowDidShow(window) }
        if let window, let folder { HookSetup.offer(on: window, in: folder.url) }
        shown(at: place)
    }

    /// A window opening on its own takes at least 1200 x 760, as much of that as its screen holds: one placed while the
    /// screen was locked or smaller keeps the smaller frame it was given.
    private static func fill(_ window: NSWindow) {
        guard let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = NSSize(width: min(max(window.frame.width, 1200), screen.width), height: min(max(window.frame.height, 760), screen.height))
        guard size != window.frame.size else { return }
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        window.center()
    }

    /// Selects this tab and puts its window just behind `front`.
    func show(behind front: NSWindow) {
        let place = readPending()
        tabs.select(self)
        window?.order(.below, relativeTo: front.windowNumber)
        shown(at: place)
    }

    /// Reads a resumed tab's file into it, returning the place to restore once the window is up.
    private func readPending() -> Place? {
        guard let tab = pending else { return nil }
        pending = nil
        let url = URL(filePath: tab.path)
        guard NSDocumentController.shared.document(for: url) == nil, let document = Self.load(url) else { return nil }
        display(document)
        return tab.place
    }

    private func shown(at place: Place?) {
        if let place { restore(place) }
        sidebar.fillAfterFirstFrame()
    }

    /// Shows `document` in this tab, closing the one it replaces, and pushes it on the tab's history unless asked not to.
    func display(_ document: MarkdownDocument, pushing: Bool = true) {
        let leaving = place
        let text = document.textView?.string ?? document.takeText()
        if let old = self.document as? NSDocument, old !== document {
            old.removeWindowController(self)
            old.close()
        }
        if self.document !== document {
            document.addWindowController(self)
        }
        let scrollView = EditorTextView.scrollView()
        let header = document.fileURL.flatMap { isAgentFile($0) ? frontMatterLine(of: text) : nil }
        setPage(header.map { frontMatterPage($0, above: scrollView) } ?? scrollView)
        // Rendered blocks fit the column, so the text arrives once the view has its width.
        window?.layoutIfNeeded()
        let textView = scrollView.documentView as! EditorTextView
        if let language = document.fileURL.flatMap(CodeFile.opened) { textView.showCode(language, indent: CodeFile.indentation(of: text)) }
        textView.documentFolder = document.fileURL?.deletingLastPathComponent()
        textView.noteFolder = folder?.url ?? textView.documentFolder
        textView.openNote = { [weak self] url, heading in self?.follow(url, heading: heading) }
        textView.findInFiles = folder == nil ? nil : { [weak self] tag in self?.sidebar.showSearch(tag) }
        textView.string = text
        // Front matter stays folded until the caret goes into it.
        if let first = textView.styler.map.blocks(in: NSRange(location: 0, length: 0)).first, first.kind == .frontMatter {
            textView.setSelectedRange(NSRange(location: min(NSMaxRange(first.range), textView.textStorage!.length), length: 0))
        }
        document.live?.attach(textView)
        // The editor's undo history is the document's, which counts its unsaved edits.
        document.undoManager = textView.styler.undoManager
        if let old = self.textView {
            NotificationCenter.default.removeObserver(self, name: NSText.didChangeNotification, object: old)
            NotificationCenter.default.removeObserver(self, name: BlockMap.didParse, object: old.styler.map)
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old.enclosingScrollView?.contentView)
            NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: old)
            NotificationCenter.default.removeObserver(self, name: NSText.didEndEditingNotification, object: old)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(wakeTitleRow), name: NSText.didEndEditingNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(countWords), name: NSTextView.didChangeSelectionNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(showPlace), name: NSTextView.didChangeSelectionNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(updateOutline), name: BlockMap.didParse, object: textView.styler.map)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        self.textView = textView
        #if COLLAB
        updatePresence()
        #endif
        changesChanged()
        pane.note = document.fileURL
        sidebar.show(document.fileURL, headings: outline(of: textView.textStorage!.mutableString, in: textView.styler.map))
        markBrokenLinks()
        if let url = document.fileURL {
            Library.noteOpened(url)
            if pushing { history.visit(url, leaving: leaving) }
        }
        updateTitle()
        countWords()
        showPlace()
        countLoads()
        tabs?.post()
        window?.makeFirstResponder(textView)
    }

    private(set) var placeUpdate: Task<Void, Never>?

    /// The status bar's idle line in a folder window, once the caret rests: the note's path from the folder and the
    /// caret's line and column.
    @objc private func showPlace() {
        placeUpdate?.cancel()
        guard let folder, let url = (document as? NSDocument)?.fileURL else { return statusBar.idle = nil }
        let root = folder.url.path + "/"
        let path = url.standardizedFileURL.path.hasPrefix(root) ? String(url.standardizedFileURL.path.dropFirst(root.count)) : url.lastPathComponent
        placeUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self, let textView else { return }
            statusBar.idle = Self.place(path, at: textView.selectedRange().location, in: textView.textStorage!.mutableString)
        }
    }

    /// "docs/spec.md:12:4": `path`, then the line and column of `index` in `text`, from 1.
    static func place(_ path: String, at index: Int, in text: NSString) -> String {
        let start = text.lineRange(for: NSRange(location: min(index, text.length), length: 0)).location
        var line = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: start), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        return "\(path):\(line):\(index - start + 1)"
    }

    private func setPage(_ content: NSView) {
        placeUpdate?.cancel()
        statusBar.idle = nil
        pageContent?.removeFromSuperview()
        pageContent = content
        page.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            content.topAnchor.constraint(equalTo: page.topAnchor),
            content.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])
    }

    /// Opens `url` here, in a new tab when asked or when this tab's text has edits or a terminal waits on it, or
    /// selects its tab.
    func open(_ url: URL, newTab: Bool) {
        if let open = NSDocumentController.shared.document(for: url) {
            open.showWindows()
            return
        }
        guard let document = Self.load(url) else { return }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        if newTab || hasEdits || (self.document as? MarkdownDocument)?.isAwaited == true {
            addTab(document)
        } else {
            display(document)
        }
    }

    /// The folder a file outside every window's folder opens in: its git repository's, else the one that holds it. A
    /// repository at the home folder counts as none, and so do the home folder, ~/Library and what it holds, and a
    /// volume's root: a note there opens in a window without a folder.
    static func folder(for file: URL) -> Folder? {
        let parent = file.standardizedFileURL.deletingLastPathComponent()
        let home = URL(filePath: NSHomeDirectory()).standardizedFileURL.path
        var directory = parent
        while directory.path != home, directory.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: directory.appending(path: ".git").path) { return Folder(directory) }
            directory = directory.deletingLastPathComponent()
        }
        let isVolume = (try? parent.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
        let library = Folder.library.path
        return isVolume || parent.path == home || parent.path == library || parent.path.hasPrefix(library + "/") ? nil : Folder(parent)
    }

    private static func load(_ url: URL) -> MarkdownDocument? {
        let controller = NSDocumentController.shared
        do {
            // Agent files such as .mdc rules and .cursorrules open as Markdown too.
            let document = try MarkdownDocument(contentsOf: url, ofType: "net.daringfireball.markdown")
            controller.addDocument(document)
            return document
        } catch {
            NSApp.presentError(error)
            return nil
        }
    }

    private var hasEdits: Bool {
        guard let textView, let document = document as? MarkdownDocument else { return false }
        return !document.isUnchanged(textView.string)
    }

    /// Opens a note a link points to and puts the caret on its heading.
    private func follow(_ url: URL, heading: String?) {
        open(url, newTab: false)
        guard let heading, let controller = NSDocumentController.shared.document(for: url)?.windowControllers.first as? MainWindowController else { return }
        controller.textView?.jump(toHeading: heading)
    }

    /// A new tab; with no folder here or remembered, asks for one first, as New Note does, so the note saves itself.
    override func newWindowForTab(_ sender: Any?) {
        guard folder != nil || (NSApp.delegate as? AppDelegate)?.frontFolder() != nil else { return }
        let document = MarkdownDocument()
        NSDocumentController.shared.addDocument(document)
        addTab(document)
        FileActions.nameFromFirstLine(document)
    }

    @discardableResult
    private func addTab(_ document: MarkdownDocument) -> MainWindowController {
        let tab = MainWindowController(folder: folder, joining: self)
        tab.display(document)
        tab.showWindow(nil)
        return tab
    }

    /// Opens the note of the tab closed last, in a new tab of this window.
    @objc func reopenClosedTab(_ sender: Any?) {
        while let last = Self.closed.popLast() {
            guard FileManager.default.fileExists(atPath: last.url.path) else { continue }
            if let open = NSDocumentController.shared.document(for: last.url) {
                open.showWindows()
            } else if let document = Self.load(last.url) {
                addTab(document)
            }
            return
        }
    }

    /// Scrolls the heading's line to the top of the page and puts the caret on it.
    func jump(to heading: Heading) {
        guard let textView, let scrollView = textView.enclosingScrollView,
            heading.location < textView.textStorage!.length,
            let baseline = textView.baseline(at: heading.location)
        else { return }
        if let url = (document as? NSDocument)?.fileURL { history.visit(url, leaving: place) }
        textView.setSelectedRange(NSRange(location: heading.location, length: 0))
        textView.scroll(NSPoint(x: 0, y: baseline - scrollView.contentInsets.top - 56))
        window?.makeFirstResponder(textView)
    }

    // MARK: Back and forward

    /// The caret and the top of the page, or nil without a file on the page.
    var place: Place? {
        guard let textView, let scrollView = textView.enclosingScrollView else { return nil }
        // A scroll that has not drawn yet leaves the viewport laid out at estimates, and laying it out moves the page;
        // the probe below would land in that stale geometry.
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let visible = textView.visibleRect
        // TextKit 2 answers a point in the top inset with an index near the end of the text, so the probe stays below it.
        let top = textView.characterIndexForInsertion(
            at: NSPoint(x: textView.textContainerOrigin.x + 4, y: max(visible.minY + scrollView.contentInsets.top + 8, textView.textContainerOrigin.y)))
        let baseline = textView.baseline(at: top)
        return Place(caret: textView.selectedRange().location, top: baseline == nil ? 0 : top, offset: visible.minY - (baseline ?? visible.minY))
    }

    /// Puts the caret and the page back where `place` left them. The baseline TextKit 2 first reports is an estimate
    /// the next layout replaces, so `hold` lays out, scrolls, and lays out again before it settles.
    func restore(_ place: Place) {
        guard let textView else { return }
        let length = textView.textStorage!.length
        textView.setSelectedRange(NSRange(location: min(max(place.caret, 0), length), length: 0))
        let top = min(max(place.top, 0), max(length - 1, 0))
        // Lays the text out to the anchor, so the page is tall enough to scroll there.
        textView.scrollRangeToVisible(NSRange(location: top, length: 0))
        textView.hold(top, at: -place.offset)
        // Past the first screen the text styles once the whole parse lands, and that pass keeps this line in place.
        textView.styler.restored = textView.styler.hasUnstyledText ? top : nil
    }

    @objc func goBack(_ sender: Any?) {
        go(to: history.back(leaving: place))
    }

    @objc func goForward(_ sender: Any?) {
        go(to: history.forward(leaving: place))
    }

    /// Shows a history entry without pushing it: here, or in a new tab when this tab's text has edits.
    private func go(to entry: History.Entry?) {
        guard let entry else { return }
        var tab = self
        if (document as? NSDocument)?.fileURL?.standardizedFileURL != entry.url.standardizedFileURL {
            if let open = NSDocumentController.shared.document(for: entry.url) {
                open.showWindows()
                return
            }
            guard let document = Self.load(entry.url) else { return }
            if hasEdits {
                tab = addTab(document)
            } else {
                display(document, pushing: false)
            }
        }
        if let place = entry.place { tab.restore(place) }
    }

    private func updateNavigation() {
        window?.toolbar?.validateVisibleItems()
    }

    private func validates(_ action: Selector?) -> Bool {
        switch action {
        case #selector(goBack(_:)): history.canGoBack
        case #selector(goForward(_:)): history.canGoForward
        case #selector(findInFiles(_:)): folder != nil
        case #selector(showNextTab(_:)), #selector(showPreviousTab(_:)): tabs.tabs.count > 1
        case #selector(reopenClosedTab(_:)): !Self.closed.isEmpty
        #if COLLAB
        case #selector(shareDocument(_:)), #selector(shareNote(_:)): (document as? NSDocument)?.fileURL != nil
        #endif
        default: true
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let open = !paneItem.isCollapsed
        switch menuItem.action {
        case #selector(toggleChanges(_:)): menuItem.state = open && pane.tab == .changes ? .on : .off
        case #selector(toggleBacklinks(_:)): menuItem.state = open && pane.tab == .backlinks ? .on : .off
        #if COLLAB
        case #selector(shareNote(_:)): menuItem.title = peers > 0 ? "Share\u{2026} (\(peers) editing)" : "Share\u{2026}"
        #endif
        default: break
        }
        return validates(menuItem.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        validates(item.action)
    }

    // MARK: Right pane

    @objc func toggleChanges(_ sender: Any?) {
        togglePane(.changes)
    }

    /// Whether the right pane is open on Changes.
    var showsChanges: Bool {
        !paneItem.isCollapsed && pane.tab == .changes
    }

    @objc func toggleBacklinks(_ sender: Any?) {
        togglePane(.backlinks)
    }

    /// Opens the pane on `tab`, or closes it. Changes takes the keyboard as it opens; pressed again with the keyboard
    /// in the list, it gives the keyboard back to the note and stays open.
    private func togglePane(_ tab: RightPane.Tab) {
        if !paneItem.isCollapsed, pane.tab == tab {
            if tab == .changes, (pane.changes as? ReviewViewController)?.hasFocus == true, let textView {
                window?.makeFirstResponder(textView)
                return
            }
            for each in tabs.tabs { each.hidePane() }
        } else {
            for each in tabs.tabs { each.showPane(tab) }
            if tab == .changes { (pane.changes as? ReviewViewController)?.focusList() }
        }
    }

    /// Opens the right pane on `tab`, as wide as the page leaves of 380 pt but at least 260. A window too narrow for the
    /// sidebar, a 480 pt page and a 260 pt pane loses the sidebar until the pane closes.
    func showPane(_ tab: RightPane.Tab) {
        let sidebarItem = split.splitViewItems[0]
        let least = RightPane.widths.lowerBound
        if paneItem.isCollapsed, !sidebarItem.isCollapsed, let window, window.frame.width < sidebar.view.frame.width + 480 + least {
            sidebarItem.isCollapsed = true
            paneHidSidebar = true
        }
        pane.select(tab)
        if paneItem.isCollapsed {
            paneItem.isCollapsed = false
            let room = split.splitView.bounds.width - (sidebarItem.isCollapsed ? 0 : sidebar.view.frame.width) - 480
            split.splitView.setPosition(split.splitView.bounds.width - min(RightPane.width, max(room, least)), ofDividerAt: 1)
        }
    }

    /// The least content width: the page's 420, and the sidebar's and the pane's least widths while they show.
    @objc private func updateMinimumSize() {
        let items = split.splitViewItems
        let width = 420 + items.filter { $0 !== items[1] && !$0.isCollapsed }.map(\.minimumThickness).reduce(0, +)
        if window?.contentMinSize.width != width { window?.contentMinSize = NSSize(width: width, height: 600) }
    }

    /// A window narrower than 700 pt collapses the sidebar, which comes back once it is wider again.
    func windowDidResize(_ notification: Notification) {
        guard let window, tabs.selected === self else { return }
        let sidebarItem = split.splitViewItems[0]
        if window.frame.width < 700, !sidebarItem.isCollapsed {
            sidebarItem.isCollapsed = true
            narrowHidSidebar = true
        } else if window.frame.width >= 700, narrowHidSidebar {
            narrowHidSidebar = false
            if !paneHidSidebar { sidebarItem.isCollapsed = false }
        }
    }

    func hidePane() {
        paneItem.isCollapsed = true
        if paneHidSidebar {
            paneHidSidebar = false
            split.splitViewItems[0].isCollapsed = false
        }
    }

    /// Writes what the window shares from this tab, the one going out.
    func saveWindowState() {
        let shared = tabs.shared
        shared.sidebarCollapsed = split.splitViewItems[0].isCollapsed
        if !shared.sidebarCollapsed { shared.sidebarWidth = sidebar.view.frame.width }
        shared.search = sidebar.searchQuery
        shared.paneHidSidebar = paneHidSidebar
    }

    /// Takes what the window shares, as the tab coming in: the sidebar and its width, its expanded folders, and Find
    /// in Files, which keeps the focus where this tab had it.
    func adoptWindowState() {
        let shared = tabs.shared
        window?.layoutIfNeeded()
        sidebar.adoptExpansion()
        if shared.search != sidebar.searchQuery {
            let focus = window?.firstResponder
            if let search = shared.search { sidebar.showSearch(search) } else { sidebar.showFiles() }
            let hidden = (focus as? NSView)?.isHiddenOrHasHiddenAncestor ?? false
            window?.makeFirstResponder(hidden ? textView : focus)
        }
        // After the search, which opens the sidebar.
        let item = split.splitViewItems[0]
        if item.isCollapsed != shared.sidebarCollapsed { item.isCollapsed = shared.sidebarCollapsed }
        if !shared.sidebarCollapsed { split.splitView.setPosition(shared.sidebarWidth, ofDividerAt: 0) }
        paneHidSidebar = shared.paneHidSidebar
    }

    /// Takes the window's full screen once no other tab's window holds it.
    private func enterSharedFullScreen() {
        guard tabs.shared.fullScreen, tabs.selected === self, let window, !window.styleMask.contains(.fullScreen),
            !tabs.tabs.contains(where: { $0.window?.styleMask.contains(.fullScreen) == true })
        else { return }
        window.toggleFullScreen(nil)
    }

    /// Takes the pane's state from the tab this one replaces, so every tab in a window shows the same pane.
    func adoptPane(from other: MainWindowController) {
        if other.paneItem.isCollapsed {
            if !paneItem.isCollapsed { hidePane() }
            return
        }
        pane.select(other.pane.tab)
        if paneItem.isCollapsed { paneItem.isCollapsed = false }
        split.splitView.setPosition(split.splitView.bounds.width - other.pane.view.frame.width, ofDividerAt: 1)
    }

    // MARK: Resume

    /// Every window's folder, tabs and places, back to front.
    static func session() -> Session {
        var windows: [Session.Window] = []
        var seen: Set<ObjectIdentifier> = []
        for window in NSApp.orderedWindows.reversed() {
            guard let set = (window.windowController as? MainWindowController)?.tabs, seen.insert(ObjectIdentifier(set)).inserted else { continue }
            let saved = set.tabs.compactMap { tab -> (Session.Tab, MainWindowController)? in
                if let pending = tab.pending { return (pending, tab) }
                guard let url = (tab.document as? NSDocument)?.fileURL, let place = tab.place else { return nil }
                return (Session.Tab(path: url.path, place: place), tab)
            }
            let folder = set.tabs.first?.folder?.url.path
            guard folder != nil || !saved.isEmpty else { continue }
            let selected = saved.firstIndex { $0.1 === set.selected } ?? 0
            windows.append(Session.Window(folder: folder, tabs: saved.map(\.0), selected: selected))
        }
        return Session(windows: windows)
    }

    /// Reopens each window of `session` with its tabs, skipping files and folders that are gone. Only each window's
    /// selected tab reads its file, with its caret and scroll; the others read theirs when first selected. With
    /// `front`, the windows open behind it.
    static func resume(_ session: Session, behind front: NSWindow? = nil) {
        let files = FileManager.default
        for saved in session.windows {
            var isFolder: ObjCBool = false
            // A window saved without a folder opens on its first note's.
            let folder = if let path = saved.folder {
                files.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue ? Folder(URL(filePath: path, directoryHint: .isDirectory)) : nil
            } else {
                saved.tabs.first { files.fileExists(atPath: $0.path) }.flatMap { Self.folder(for: URL(filePath: $0.path)) }
            }
            guard saved.folder == nil || folder != nil else { continue }
            var last: MainWindowController?
            var selected: MainWindowController?
            for (index, tab) in saved.tabs.enumerated() {
                guard files.fileExists(atPath: tab.path), NSDocumentController.shared.document(for: URL(filePath: tab.path)) == nil else { continue }
                let controller = MainWindowController(folder: folder, joining: last)
                controller.pending = tab
                last = controller
                if index == saved.selected || selected == nil { selected = controller }
            }
            if let tab = selected ?? folder.map({ MainWindowController(folder: $0) }) {
                if let front { tab.show(behind: front) } else { tab.showWindow(nil) }
            }
        }
    }

    /// Opens `url` as the sidebar does and selects `match` where the file's text still holds it.
    private func reveal(_ match: TextMatch?, in url: URL, newTab: Bool) {
        open(url, newTab: newTab)
        guard let match, let tab = NSDocumentController.shared.document(for: url)?.windowControllers.first as? MainWindowController,
            let textView = tab.textView
        else { return }
        let text = textView.textStorage!.mutableString
        let found = (match.preview as NSString).substring(with: match.previewRange)
        guard NSMaxRange(match.range) <= text.length, text.substring(with: match.range) == found else { return }
        tab.window?.makeFirstResponder(textView)
        textView.jump(to: match.range)
    }

    /// Opens `url` as a link does and selects `range` where the file's text still reaches it.
    private func open(_ url: URL, selecting range: NSRange) {
        open(url, newTab: false)
        guard let tab = NSDocumentController.shared.document(for: url)?.windowControllers.first as? MainWindowController,
            let textView = tab.textView, NSMaxRange(range) <= textView.textStorage!.length
        else { return }
        tab.window?.makeFirstResponder(textView)
        textView.jump(to: range)
    }

    @objc func findInFiles(_ sender: Any?) {
        sidebar.showSearch()
    }

    /// Counts the note's words, and the selection's, for the tab's tooltip 250 ms after the text or the selection last
    /// changed, once the map has the whole text. It counts on the main thread from the storage itself, a
    /// piece between events, and starts over when the text changes.
    @objc private func countWords() {
        countUpdate?.cancel()
        countUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            while let map = self?.textView?.styler.map, map.parsed < (self?.textView?.textStorage?.length ?? 0), !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            var count = (total: 0, selected: 0)
            var (start, version) = (0, self?.textView?.version)
            while !Task.isCancelled, let textView = self?.textView {
                let text = textView.textStorage!.mutableString
                if textView.version != version { (count, start, version) = ((0, 0), 0, textView.version) }
                guard start < text.length else { break }
                let piece = text.paragraphRange(for: NSRange(location: start, length: min(Self.countedPiece, text.length - start)))
                let found = WordCount.count(text, in: piece, blocks: textView.styler.map.blocks(in: piece), selection: textView.selectedRange())
                count = (count.total + found.total, count.selected + found.selected)
                start = NSMaxRange(piece)
                try? await Task.sleep(for: .milliseconds(1))
            }
            guard !Task.isCancelled, let self, let textView = self.textView else { return }
            self.wordCount = WordCount.label(total: count.total, selected: textView.selectedRange().length > 0 ? count.selected : nil)
        }
    }

    /// The text one step of the word count reads: a millisecond or two of work.
    private static let countedPiece = 1 << 15

    /// Reads what agents load for the note's folder off the main thread.
    private func countLoads() {
        loadsUpdate?.cancel()
        agentLoads = []
        guard let directory = (document as? NSDocument)?.fileURL?.deletingLastPathComponent() else { return }
        let root = folder?.url
        loadsUpdate = Task { [weak self] in
            let rows = await Task.detached(priority: .utility) { whatLoadsRows(in: directory, root: root) }.value
            guard !Task.isCancelled else { return }
            self?.agentLoads = rows
        }
    }

    /// Lists the headings 300 ms after typing stops, or once a whole parse lands. A result shown until the next keystroke
    /// goes.
    @objc private func textChanged() {
        countWords()
        statusBar.typed()
        if let event = NSApp.currentEvent, event.type == .keyDown, !event.modifierFlags.contains(.command) { toolbar.typed() }
        outlineUpdate?.cancel()
        outlineUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.updateOutline()
            self?.markBrokenLinks()
        }
    }

    /// A dotted underline under each relative link and CLAUDE.md `@import` whose file is missing, or whose import
    /// cycles or runs more than 5 deep. Drawn as rendering attributes, so the text's own attributes stay as they are.
    /// Found off the main thread, so a file's first frame never waits on the search, and drawn only on the text it read.
    private func markBrokenLinks() {
        linkUpdate?.cancel()
        guard let textView else { return }
        guard let url = (document as? MarkdownDocument)?.fileURL else { return underline([], in: textView) }
        let (text, version) = (TextCopy(textView.textStorage!.mutableString), textView.version)
        linkUpdate = Task { [weak self, weak textView] in
            let links = await Task.detached(priority: .utility) { brokenTargets(in: text, path: url.path, home: agentHome) }.value
            guard !Task.isCancelled, let self, let textView, textView === self.textView, textView.version == version else { return }
            underline(links.map(\.range), in: textView)
        }
    }

    private func underline(_ ranges: [NSRange], in textView: EditorTextView) {
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager else { return }
        layout.removeRenderingAttribute(.underlineStyle, for: content.documentRange)
        layout.removeRenderingAttribute(.underlineColor, for: content.documentRange)
        for link in ranges {
            guard let start = content.location(content.documentRange.location, offsetBy: link.location),
                let end = content.location(start, offsetBy: link.length),
                let range = NSTextRange(location: start, end: end)
            else { continue }
            layout.addRenderingAttribute(.underlineStyle, value: NSUnderlineStyle([.single, .patternDot]).rawValue, for: range)
            layout.addRenderingAttribute(.underlineColor, value: Chrome.color(.ink2), for: range)
        }
    }

    @objc private func updateOutline() {
        guard let textView else { return }
        sidebar.updateOutline(outline(of: textView.textStorage!.mutableString, in: textView.styler.map))
    }

    /// The outline marks the section at the top 160 ms after scrolling stops.
    @objc private func scrolled() {
        sectionUpdate?.cancel()
        sectionUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, let self, let textView = self.textView, let scrollView = textView.enclosingScrollView else { return }
            let top = NSPoint(
                x: textView.textContainerOrigin.x + 4, y: max(textView.visibleRect.minY + scrollView.contentInsets.top + 8, textView.textContainerOrigin.y))
            self.sidebar.markSection(at: textView.characterIndexForInsertion(at: top))
        }
    }

    @objc private func wakeTitleRow() {
        toolbar.wake()
    }

    func windowDidResignKey(_ notification: Notification) {
        toolbar.wake()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        toolbar.wake()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        if tabs.selected === self { tabs.shared.fullScreen = true }
    }

    /// A tab that left full screen as another took its place goes now, and that tab enters full screen.
    func windowDidExitFullScreen(_ notification: Notification) {
        if tabs.selected === self {
            tabs.shared.fullScreen = false
        } else {
            window?.orderOut(nil)
            tabs.selected?.enterSharedFullScreen()
        }
    }

    /// The title row stays in full screen.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        proposedOptions.subtracting(.autoHideToolbar)
    }

    /// Opens a note Activity lists, at its first waiting change.
    @objc func openWaiting(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openAtFirstChange(url)
    }

    /// Opens `url` at its first marked change, in a new tab when asked.
    func openAtFirstChange(_ url: URL, newTab: Bool = false) {
        open(url, newTab: newTab)
        guard let live = (NSDocumentController.shared.document(for: url) as? MarkdownDocument)?.live,
            let first = live.changes.filter(\.value.marked).min(by: { $0.value.range.location < $1.value.range.location })
        else { return }
        live.reveal(first.key, caret: true)
    }

    func windowWillClose(_ notification: Notification) {
        toolbar.wake()
        if let document = document as? MarkdownDocument { FileActions.stopNaming(document) }
        if let url = (document as? NSDocument)?.fileURL { Self.closed.append((url, folder)) }
        tabs.remove(self)
        Self.all.remove(self)
        // A full-screen tab's window is gone after this turn; the tab in its place then takes full screen.
        if tabs.shared.fullScreen { Task { self.tabs.selected?.enterSharedFullScreen() } }
        Task {
            if Self.all.isEmpty { (NSApp.delegate as? AppDelegate)?.nothingIsOpen() }
        }
    }

    #if COLLAB
    /// Shares the note live (D13): a popover at the window's top trailing corner, where nothing is shared until Copy
    /// Invite Link.
    @objc func shareDocument(_ sender: Any?) {
        guard let document = document as? MarkdownDocument, document.fileURL != nil, let content = window?.contentView else { return NSSound.beep() }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = Collaboration.sharePopover(for: document)
        let corner = NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - content.safeAreaInsets.top - 1, width: 1, height: 1)
        popover.show(relativeTo: corner, of: content, preferredEdge: .minY)
    }

    /// File > Share….
    @objc func shareNote(_ sender: Any?) {
        shareDocument(sender)
    }
    #endif
}

/// What agents load for the note's folder, under Activity: each agent with its total, then its files.
@MainActor
enum LoadsPopover {
    static func show(_ rows: [AgentRow], under view: NSView) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for row in rows {
            let name = NSTextField(labelWithString: row.title)
            name.font = row.url == nil ? Chrome.labelStrong : Chrome.label
            name.textColor = Chrome.color(.ink)
            name.lineBreakMode = .byTruncatingMiddle
            name.toolTip = row.tip
            // A long path truncates in the middle instead of widening the popover past the screen.
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
            let detail = NSTextField(labelWithString: row.detail)
            detail.font = Chrome.status
            detail.textColor = Chrome.color(.ink2)
            let line = NSStackView(views: [name, detail])
            line.spacing = 12
            if row.url == nil, stack.arrangedSubviews.count > 0 { stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!) }
            stack.addArrangedSubview(line)
        }
        let controller = NSViewController()
        controller.view = stack
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = stack.fittingSize
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }
}

/// The files in a folder with something to look at, each once under the first that applies: "Waiting for you", marked
/// changes in an open note or changes made while it was closed, led by who wrote them; then "Uncommitted in git", every
/// file that differs from the last commit. Up to eight rows show at once; Return or a click opens the file.
@MainActor
final class WaitingNotes: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    /// A section's heading when `url` is nil, else a file: its path from the folder, the writer of a change waiting
    /// in it, and what waits.
    struct Row {
        var url: URL?
        var text: String
        var writer: MarkWriter?
        var detail = ""
    }

    private let folder: URL
    private weak var git: GitStates?
    private let open: (URL) -> Void
    private let table = ReturnTable()
    private(set) var rows: [Row] = []
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)
    /// Called after each reload with whether the list is empty.
    var changed: (Bool) -> Void = { _ in }

    init(in folder: URL, git: GitStates?, open: @escaping (URL) -> Void) {
        self.folder = folder.standardizedFileURL
        self.git = git
        self.open = open
        super.init(frame: .zero)
        table.addTableColumn(NSTableColumn(identifier: .init("Note")))
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.returned = { [weak self] in self?.openRow(self?.table.selectedRow ?? -1) }
        table.setAccessibilityLabel("Waiting for review")
        documentView = table
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        height.isActive = true
        for name in [LiveFile.changesDidChange, ClosedChanges.changed] {
            NotificationCenter.default.addObserver(self, selector: #selector(reload), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: GitStates.changed, object: git)
    }

    required init?(coder: NSCoder) {
        fatalError("WaitingNotes is built in code")
    }

    @objc func reload() {
        var waiting: [Row] = []
        var uncommitted: [Row] = []
        var seen: Set<String> = []
        func row(_ url: URL) -> Row? {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(folder.path + "/"), seen.insert(path).inserted else { return nil }
            return Row(url: url, text: String(path.dropFirst(folder.path.count + 1)))
        }
        for live in NSDocumentController.shared.documents.compactMap({ ($0 as? MarkdownDocument)?.live }) {
            let marked = live.changes.values.filter(\.marked)
            guard let first = marked.first, var row = row(live.url) else { continue }
            (row.writer, row.detail) = (MarkWriter(first.origin), "\(marked.count) to review")
            waiting.append(row)
        }
        for note in Review.closedNotes() {
            if case .git = note.origin { continue }
            guard var row = row(note.url) else { continue }
            (row.writer, row.detail) = (MarkWriter(note.origin), "changed while closed")
            waiting.append(row)
        }
        for (url, state) in git?.changed ?? [] {
            guard var row = row(url) else { continue }
            row.detail = switch state {
            case .new: "New"
            case .conflicted: "Merge conflict"
            case .deleted: "Deleted"
            case .modified, .renamed: "Modified"
            }
            uncommitted.append(row)
        }
        rows = (waiting.isEmpty ? [] : [Row(text: "Waiting for you (\(waiting.count))")] + waiting)
            + (uncommitted.isEmpty ? [] : [Row(text: "Uncommitted in git (\(uncommitted.count))")] + uncommitted)
        table.reloadData()
        if table.selectedRow < 0, let first = rows.firstIndex(where: { $0.url != nil }) { table.selectRowIndexes([first], byExtendingSelection: false) }
        height.constant = CGFloat(min(rows.count, 8)) * table.rowHeight
        isHidden = rows.isEmpty
        changed(rows.isEmpty)
    }

    @objc private func clicked() {
        openRow(table.clickedRow)
    }

    private func openRow(_ row: Int) {
        guard rows.indices.contains(row), let url = rows[row].url else { return }
        guard git?.state(of: url) == .deleted else { return open(url) }
        let folder = folder
        Task { [weak self] in
            let text = await Task.detached { Self.committedText(of: url, in: folder) }.value
            guard let self, let window, let text else { return NSSound.beep() }
            let alert = NSAlert()
            alert.messageText = "\(url.lastPathComponent) was deleted"
            alert.informativeText = "Its text at the last commit, read-only."
            alert.accessoryView = readOnlyText(NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.textColor,
            ]))
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }

    /// `url`'s text in the last commit, read with git; nil when git can't read it.
    private nonisolated static func committedText(of url: URL, in folder: URL) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", folder.path, "show", "HEAD:./" + String(url.standardizedFileURL.path.dropFirst(folder.path.count + 1))]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows[row].url != nil
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        rows[row].url == nil ? NSTableRowView() : WaitingRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let row = rows[row]
        let name = NSTextField(labelWithString: row.text)
        name.font = row.url == nil ? Chrome.status : Chrome.label
        name.textColor = Chrome.color(row.url == nil ? .ink2 : .ink)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let note = NSTextField(labelWithString: row.detail)
        note.font = Chrome.status
        note.textColor = Chrome.color(.ink2)
        note.setContentCompressionResistancePriority(.required, for: .horizontal)
        let writer = NSTextField(labelWithAttributedString: row.writer?.stamp ?? NSAttributedString())
        writer.setContentCompressionResistancePriority(.required, for: .horizontal)
        let line = NSStackView(views: (row.writer == nil ? [] : [writer]) + [name, note])
        line.spacing = 12
        line.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -14),
            line.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityLabel([row.writer?.name, row.text, row.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        return cell
    }
}

/// A waiting file's row: its selection is the wash, never the solid accent, so the writer's ink and the text keep their
/// colors.
private final class WaitingRowView: StationRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// A view filled with the theme's paper, following the theme and the appearance.
final class PaperView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange(_:)), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("PaperView is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = ThemeStore.shared.color(.paper).cgColor
    }

    @objc private func themeDidChange(_ notification: Notification) {
        needsDisplay = true
    }
}

extension NSWindow {
    /// Draws the window now and commits the frame, then runs `body` on a later turn of the main run loop, so
    /// nothing `body` does holds back this frame.
    func afterDrawing(_ body: @escaping @MainActor () -> Void) {
        displayIfNeeded()
        CATransaction.flush()
        Task { @MainActor in body() }
    }
}
