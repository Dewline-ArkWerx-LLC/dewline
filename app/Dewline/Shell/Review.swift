import AppKit
import MdCore

/// The Changes tab: the marked changes in a window's open notes, and the notes changed while closed, by writer session.
@MainActor
enum Review {
    /// The window's tabs' files.
    static func files(in window: NSWindow?) -> [LiveFile] {
        documents(in: window).compactMap(\.live)
    }

    /// The window's tabs' notes.
    static func documents(in window: NSWindow?) -> [MarkdownDocument] {
        guard let window else { return [] }
        let windows = (window.windowController as? MainWindowController)?.tabs.tabs.compactMap(\.window) ?? [window]
        return windows.compactMap { $0.windowController?.document as? MarkdownDocument }
    }

    /// Groups changes by writer session: "claude:<id>", "git", "external".
    static func key(_ origin: ChangeEngine.Origin) -> String {
        switch origin {
        case .agent(let vendor, let session): "\(vendor):\(session)"
        case .git: "git"
        case .external: "external"
        case .user: "user"
        case .collaborator(let peer, _): "collab:\(peer)"
        }
    }

    /// The undecided marked changes in `files` from `origin`'s session, as places and files.
    static func count(_ origin: ChangeEngine.Origin, in files: [LiveFile]) -> (places: Int, files: Int) {
        let key = key(origin)
        let counts = files.map { $0.changes.values.count { $0.marked && Self.key($0.origin) == key } }
        return (counts.reduce(0, +), counts.count { $0 > 0 })
    }

    /// A marked change landed: its session's latest time.
    static func landed(_ live: LiveFile, _ change: UInt64) {
        if let origin = live.changes[change]?.origin { times[key(origin)] = Date() }
    }

    /// Next Change and Previous Change: reveals the marked change after or before the caret, or from offset `at` on,
    /// then the first or last one in each of the window's other tabs in order. Past the last one, Next Change opens the
    /// next note waiting outside the tabs at its first change, saying so in the status bar; else, and after a decision at
    /// `at`, both wrap back to
    /// `textView`'s file.
    static func step(from textView: EditorTextView, forward: Bool, at start: Int? = nil) {
        guard let live = textView.marks.live else { return }
        let files = files(in: textView.window)
        let caret = start.map { $0 - 1 } ?? textView.selectedRange().location
        // A decision moving on stays in the open notes.
        let crosses = forward && start == nil
        func marked(_ file: LiveFile) -> [UInt64] {
            file.changes.filter(\.value.marked).sorted { $0.value.range.location < $1.value.range.location }.map(\.key)
        }
        let here = marked(live)
        let ahead = here.filter { id in
            let at = live.changes[id]!.range.location
            return forward ? at > caret : at < caret
        }
        if let id = forward ? ahead.first : ahead.last { return live.reveal(id, caret: true) }
        let start = files.firstIndex { $0 === live } ?? 0
        for offset in 1..<max(files.count, 1) {
            let file = files[(start + (forward ? offset : files.count - offset)) % files.count]
            let ids = marked(file)
            if let id = forward ? ids.first : ids.last { return file.reveal(id, caret: true) }
        }
        let beyond = crosses ? notesBeyond(textView.window) : []
        if let next = beyond.first, let controller = textView.window?.windowController as? MainWindowController {
            controller.openAtFirstChange(next, newTab: !here.isEmpty)
            let name = next.lastPathComponent
            let more = beyond.count > 1 ? "; \(beyond.count - 1) more waiting \u{2303}\u{2318}\u{2193}" : ""
            let window = NSDocumentController.shared.document(for: next)?.windowControllers.first?.window
            return StatusBar.post(.init(id: "step", kind: .result, text: "Last change in open notes. Opened \(name)\(more)", untilTyping: true), in: window)
        }
        if let id = forward ? here.first : here.last { live.reveal(id, caret: true) }
    }

    /// The notes in the window's folder waiting outside every open note, in the order Next Change opens them: changed
    /// while closed, then different from the last commit. Deleted notes have no change to open at.
    static func notesBeyond(_ window: NSWindow?) -> [URL] {
        guard let controller = window?.windowController as? MainWindowController, let folder = controller.folder?.url.standardizedFileURL else { return [] }
        let open = Set(NSDocumentController.shared.documents.compactMap { $0.fileURL?.standardizedFileURL.path })
        let notes = FolderEntry.markdownExtensions.union(FolderEntry.dialectExtensions)
        let git = (controller.index?.git.changed ?? []).filter { $0.state != .deleted && notes.contains($0.url.pathExtension.lowercased()) }
        var seen: Set<String> = []
        return (closedNotes().map(\.url) + git.map(\.url)).filter { url in
            let path = url.standardizedFileURL.path
            return path.hasPrefix(folder.path + "/") && !open.contains(path) && seen.insert(path).inserted
        }
    }

    /// The window's open notes with marked changes, and the notes changed while closed that aren't among them.
    static func waiting(in window: NSWindow?) -> (open: [LiveFile], closed: [ClosedNote]) {
        let open = files(in: window).filter { $0.changes.values.contains(where: \.marked) }
        let paths = Set(open.map(\.url.standardizedFileURL.path))
        return (open, closedNotes().filter { !paths.contains($0.url.standardizedFileURL.path) })
    }

    /// The changes `waiting(in:)` holds, as Activity and the Changes segment count them.
    static func waitingCount(in window: NSWindow?) -> Int {
        let (open, closed) = waiting(in: window)
        return open.reduce(0) { $0 + $1.changes.values.count(where: \.marked) } + closed.reduce(0) { $0 + $1.count }
    }

    /// Whether any of the window's tabs holds a marked change.
    static func hasMarked(in window: NSWindow?) -> Bool {
        files(in: window).contains { $0.changes.values.contains(where: \.marked) }
    }

    /// When each writer session's turn last ended, or its last change landed, for "Claude Code · 2:36 PM"; the 64
    /// latest outlast a relaunch.
    private static var times: [String: Date] = (UserDefaults.standard.dictionary(forKey: timesKey) as? [String: Double] ?? [:])
        .mapValues { Date(timeIntervalSince1970: $0) } {
        didSet {
            let kept = times.sorted { $0.value > $1.value }.prefix(64).map { ($0.key, $0.value.timeIntervalSince1970) }
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: kept), forKey: timesKey)
        }
    }
    private static let timesKey = "ReviewSessionTimes"

    /// A session's turn ended; the Changes tab dates its notes by it.
    static func finished(vendor: ControlSocket.Claim.Vendor, session: String) {
        times["\(vendor.rawValue):\(session)"] = Date()
    }

    /// When `origin`'s session last finished a turn or landed a change.
    static func time(of origin: ChangeEngine.Origin) -> Date? {
        times[key(origin)]
    }

    /// The notes changed while closed, newest first, which the Changes tab lists.
    static var closedNotes: () -> [ClosedNote] = { [] }

    /// Keep Session and Revert Session: decides every marked change from writer session `key` in `window`'s notes,
    /// and opens the session's notes changed while closed to decide theirs once they land.
    static func decideSession(_ key: String, keep: Bool, in window: NSWindow?) {
        let files = files(in: window)
        for live in files { decide(key, keep: keep, in: live) }
        let open = Set(files.map(\.url.standardizedFileURL))
        for note in closedNotes() where Self.key(note.origin) == key && !open.contains(note.url.standardizedFileURL) {
            NSDocumentController.shared.openDocument(withContentsOf: note.url, display: true) { document, _, _ in
                guard let live = (document as? MarkdownDocument)?.live else { return }
                Task {
                    await live.refresh()
                    decide(key, keep: keep, in: live)
                }
            }
        }
    }

    private static func decide(_ key: String, keep: Bool, in live: LiveFile) {
        let ids = live.changes.filter { $0.value.marked && !$0.value.conflict && Self.key($0.value.origin) == key }.map(\.key)
        live.decide(ids, keep: keep, named: keep ? "Keep Session" : "Revert Session")
    }

    /// "Claude Code · 2:36 PM", or the name alone with no time known.
    static func byline(_ origin: ChangeEngine.Origin, at time: Date?) -> String {
        let name = EarlierVersions.writer(origin)
        return time.map { "\(name) \u{00B7} \($0.formatted(date: .omitted, time: .shortened))" } ?? name
    }
}

/// A note an outside writer changed while it was closed, in `count` places.
struct ClosedNote: Equatable {
    let url: URL
    let origin: ChangeEngine.Origin
    let count: Int
    let time: Date
}


/// The right pane's Changes tab, by writer session, newest first: "Claude Code · 2:36 PM" with Keep Session and Revert
/// Session, then each open note with its undecided changes from that session, then the session's notes changed while
/// closed. Each change row is the changed line, its changed words in the writer's ink, and "line 17", or "+3 / −2
/// lines" for a change over several lines, which Right Arrow or Space opens in place in full. Keep and Revert show on
/// the selected or hovered row; with Option they decide the whole note. Up and Down select rows and J and K changes;
/// Y or Return keeps the selected change, X reverts it and O reveals it, keeping focus here, and Cmd-Return or
/// Option-Cmd-Delete decides it.
@MainActor
final class ReviewViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    enum Row {
        case session(String, String)
        case note(LiveFile)
        case change(LiveFile, UInt64, NSString?)
        case closed(ClosedNote)
    }

    private(set) var rows: [Row] = []
    private weak var source: NSWindow?
    private let table = ReturnTable()
    private let empty = NSTextField(wrappingLabelWithString: """
        Nothing to review.

        When Claude Code, Codex or git changes a note in this folder, the change shows here and in the note, waiting \
        for Keep or Revert.
        """)
    private var reloading = false
    private var flags: Any?
    private(set) var optionDown = false
    /// The multi-line changes shown in full.
    private var expanded: Set<UInt64> = []

    /// Lists `window`'s notes, or the notes of the window this tab is in.
    init(for window: NSWindow? = nil) {
        source = window
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ReviewViewController is built in code")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("Change"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.returned = { [weak self] in self?.decideSelected(keep: true) }
        table.pressed = { [weak self] event in self?.pressed(event) ?? false }
        table.setAccessibilityLabel("Changes")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        empty.font = .systemFont(ofSize: 13)
        empty.alignment = .center
        let root = NSView()
        for view in [scroll, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            empty.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            empty.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
        for name in [LiveFile.changesDidChange, NSWindow.didBecomeMainNotification, MarkdownDocument.didCloseNotification, ThemeStore.didChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(scheduleReload), name: name, object: nil)
        }
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reload()
        flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.setOption(event.modifierFlags.contains(.option)) }
            return event
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let flags { NSEvent.removeMonitor(flags) }
        flags = nil
    }

    /// With Option down, Keep and Revert read "Keep All in Note" and "Revert All in Note".
    func setOption(_ down: Bool) {
        guard down != optionDown else { return }
        optionDown = down
        table.enumerateAvailableRowViews { row, _ in (row.view(atColumn: 0) as? ChangeRow)?.optionDown = down }
    }

    @objc private func scheduleReload() {
        guard !reloading else { return }
        reloading = true
        DispatchQueue.main.async { [weak self] in
            self?.reloading = false
            self?.reload()
        }
    }

    func reload() {
        let decided = rows.indices.contains(table.selectedRow) && isChange(table.selectedRow) ? table.selectedRow : nil
        let files = Review.files(in: source ?? view.window)
        var sessions: [String: (origin: ChangeEngine.Origin, time: Date?, rows: [Row])] = [:]
        func add(_ row: Row, from origin: ChangeEngine.Origin, at time: Date?) {
            let key = Review.key(origin)
            var session = sessions[key] ?? (origin, nil, [])
            if let time { session.time = max(session.time ?? time, time) }
            session.rows.append(row)
            sessions[key] = session
        }
        for live in files {
            let text = live.text
            let marked = live.changes.filter(\.value.marked).sorted { $0.value.range.location < $1.value.range.location }
            var keys: [String] = []
            for (_, change) in marked where !keys.contains(Review.key(change.origin)) { keys.append(Review.key(change.origin)) }
            for key in keys {
                let mine = marked.filter { Review.key($0.value.origin) == key }
                let origin = mine[0].value.origin
                add(.note(live), from: origin, at: Review.time(of: origin))
                for (id, _) in mine { add(.change(live, id, text), from: origin, at: nil) }
            }
        }
        let open = Set(files.map(\.url.standardizedFileURL))
        for note in Review.closedNotes() where !open.contains(note.url.standardizedFileURL) {
            add(.closed(note), from: note.origin, at: note.time)
        }
        rows = sessions.sorted { ($0.value.time ?? .distantPast, $0.key) > ($1.value.time ?? .distantPast, $1.key) }.flatMap { key, session -> [Row] in
            [.session(key, Review.byline(session.origin, at: session.time))] + session.rows
        }
        empty.textColor = ThemeStore.shared.color(.ink2)
        empty.isHidden = !rows.isEmpty
        table.reloadData()
        // A selected change that was decided passes the selection to the next change, else the last.
        if let decided, let next = rows.indices.first(where: { $0 >= decided && isChange($0) }) ?? rows.indices.last(where: isChange) {
            table.selectRowIndexes([next], byExtendingSelection: false)
        }
    }

    private func isChange(_ index: Int) -> Bool {
        if case .change = rows[index] { return true }
        return false
    }

    /// Puts the keyboard in the list, on its selected change or else its first.
    func focusList() {
        if !(rows.indices.contains(table.selectedRow) && isChange(table.selectedRow)), let first = rows.indices.first(where: isChange) {
            select(first)
        }
        view.window?.makeFirstResponder(table)
    }

    /// Whether the keyboard is in the list.
    var hasFocus: Bool {
        isViewLoaded && view.window?.firstResponder === table
    }

    private func select(_ row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    /// The list's keys without Command, Option or Control; false for a key it leaves to the table.
    private func pressed(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 124: return expand(true)
        case 123: return expand(false)
        case 49: return expand(nil)
        default: break
        }
        switch event.charactersIgnoringModifiers {
        case "j": move(1)
        case "k": move(-1)
        case "y": decideSelected(keep: true)
        case "x": decideSelected(keep: false)
        case "o": revealSelected()
        default: return false
        }
        return true
    }

    /// Selects the next or previous change or note changed while closed.
    private func move(_ step: Int) {
        let from = table.selectedRow
        let ahead = step > 0 ? Array(rows.indices.filter { $0 > from }) : rows.indices.filter { $0 < from }.reversed()
        let next = ahead.first { index in
            switch rows[index] {
            case .change, .closed: true
            case .session, .note: false
            }
        }
        if let next { select(next) }
    }

    /// Opens the selected multi-line change in full, or closes it; nil toggles it.
    private func expand(_ open: Bool?) -> Bool {
        let row = table.selectedRow
        guard rows.indices.contains(row), case .change(let live, let id, let text) = rows[row], Self.size(of: id, in: live, text: text) != nil else { return false }
        let opened = open ?? !expanded.contains(id)
        guard opened != expanded.contains(id) else { return true }
        if opened { expanded.insert(id) } else { expanded.remove(id) }
        table.reloadData(forRowIndexes: [row], columnIndexes: [0])
        table.noteHeightOfRows(withIndexesChanged: [row])
        return true
    }

    private func revealSelected() {
        guard rows.indices.contains(table.selectedRow) else { return }
        switch rows[table.selectedRow] {
        case .change(let live, let id, _): live.reveal(id, caret: true)
        case .closed(let note): NSDocumentController.shared.openDocument(withContentsOf: note.url, display: true) { _, _, _ in }
        case .session, .note: return
        }
        table.window?.makeFirstResponder(table)
    }

    /// Cmd-Return with the list focused: keeps the selected change.
    @objc func keepChange(_ sender: Any?) {
        decideSelected(keep: true)
    }

    /// Option-Cmd-Delete with the list focused: reverts the selected change.
    @objc func revertChange(_ sender: Any?) {
        decideSelected(keep: false)
    }

    /// Keep Session and Revert Session from the menu with the list focused: the selected row's session, else the newest.
    @objc func keepSession(_ sender: Any?) {
        if let key = selectedSession { Review.decideSession(key, keep: true, in: source ?? view.window) }
    }

    @objc func revertSession(_ sender: Any?) {
        if let key = selectedSession { Review.decideSession(key, keep: false, in: source ?? view.window) }
    }

    private var selectedSession: String? {
        let end = rows.indices.contains(table.selectedRow) ? table.selectedRow : 0
        for row in rows.prefix(end + 1).reversed() { if case .session(let key, _) = row { return key } }
        return nil
    }

    private func decideSelected(keep: Bool) {
        guard rows.indices.contains(table.selectedRow), case .change(let live, let id, _) = rows[table.selectedRow] else { return }
        decide(live, id, keep: keep)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if [#selector(keepSession(_:)), #selector(revertSession(_:))].contains(menuItem.action) { return selectedSession != nil }
        guard [#selector(keepChange(_:)), #selector(revertChange(_:))].contains(menuItem.action) else { return true }
        guard rows.indices.contains(table.selectedRow), case .change = rows[table.selectedRow] else { return false }
        return true
    }

    @objc private func clicked() {
        guard rows.indices.contains(table.clickedRow) else { return }
        switch rows[table.clickedRow] {
        case .change(let live, let id, _): live.reveal(id, caret: true)
        case .note(let live):
            if let first = live.changes.filter(\.value.marked).min(by: { $0.value.range.location < $1.value.range.location }) {
                live.reveal(first.key, caret: true)
            }
        case .closed(let note):
            NSDocumentController.shared.openDocument(withContentsOf: note.url, display: true) { _, _, _ in }
        case .session: break
        }
    }

    /// Keep or Revert on a row; with Option, every change in its note.
    func decide(_ live: LiveFile, _ id: UInt64, keep: Bool) {
        if optionDown { return live.decideAll(keep: keep) }
        keep ? live.keep(id) : live.revert(id)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .session: return 36
        case .note: return 28
        case .closed: return 24
        case .change(let live, let id, let text):
            guard expanded.contains(id) else { return 24 }
            return CGFloat(Self.hunk(of: id, in: live, text: text).string.split(separator: "\n", omittingEmptySubsequences: false).count) * 17 + 8
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        table.enumerateAvailableRowViews { row, index in (row.view(atColumn: 0) as? ChangeRow)?.selected = index == table.selectedRow }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let store = ThemeStore.shared
        switch rows[row] {
        case .session(let key, let byline):
            return SessionRow(byline) { [weak self] keep in
                guard let self else { return }
                Review.decideSession(key, keep: keep, in: source ?? view.window)
            }
        case .note(let live):
            return HeadingRow(relative(live.url), detail: nil)
        case .closed(let note):
            let title = NSAttributedString(string: relative(note.url), attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: store.color(.ink),
            ])
            return ChangeRow(title, detail: "closed \u{00B7} \(note.count) \(note.count == 1 ? "change" : "changes")", decide: nil)
        case .change(let live, let id, let text):
            let size = Self.size(of: id, in: live, text: text)
            let open = expanded.contains(id)
            let title = open ? Self.hunk(of: id, in: live, text: text) : Self.line(of: id, in: live, text: text)
            let detail = size.map { "+\($0.added) / \u{2212}\($0.removed) lines" } ?? "line \(live.line(id))"
            let cell = ChangeRow(title, detail: detail, lines: open ? 0 : 1) { [weak self, weak live] keep in
                guard let live else { return }
                self?.decide(live, id, keep: keep)
            }
            cell.optionDown = optionDown
            cell.selected = row == tableView.selectedRow
            return cell
        }
    }

    /// The note's path in the window's folder without its extension, or its name outside the folder.
    private func relative(_ url: URL) -> String {
        let path = url.standardizedFileURL.deletingPathExtension().path
        let folder = ((source ?? view.window)?.windowController as? MainWindowController)?.folder?.url.standardizedFileURL.path
        guard let folder, path.hasPrefix(folder + "/") else { return url.deletingPathExtension().lastPathComponent }
        return String(path.dropFirst(folder.count + 1))
    }

    /// The lines a change put in and took out, when either is more than one; nil for a change within one line.
    static func size(of id: UInt64, in live: LiveFile, text: NSString?) -> (added: Int, removed: Int)? {
        guard let change = live.changes[id] else { return nil }
        let added = lines(landed(change, in: text)).count
        let removed = lines(change.removed).count
        return added > 1 || removed > 1 ? (added, removed) : nil
    }

    private static func landed(_ change: LiveFile.Change, in text: NSString?) -> String {
        guard let text else { return "" }
        return text.substring(with: NSIntersectionRange(change.range, NSRange(location: 0, length: text.length)))
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return (text.hasSuffix("\n") ? String(text.dropLast()) : text).components(separatedBy: "\n")
    }

    /// A change in full: the lines it took out struck in `ink2`, then the lines it put in, in the writer's ink; at
    /// most 40 of each.
    static func hunk(of id: UInt64, in live: LiveFile, text: NSString?) -> NSAttributedString {
        guard let change = live.changes[id] else { return NSAttributedString() }
        let store = ThemeStore.shared
        let font = NSFont.systemFont(ofSize: 13)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let struck: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: store.color(.ink2), .strikethroughStyle: NSUnderlineStyle.single.rawValue, .paragraphStyle: style,
        ]
        let put: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: MarkWriter(change.origin).color, .paragraphStyle: style]
        let shown = lines(change.removed).prefix(40).map { ($0, struck) } + lines(landed(change, in: text)).prefix(40).map { ($0, put) }
        let hunk = NSMutableAttributedString()
        for (index, (line, attributes)) in shown.enumerated() {
            hunk.append(NSAttributedString(string: (index > 0 ? "\n" : "") + (line.isEmpty ? " " : line), attributes: attributes))
        }
        return hunk
    }

    /// The change's line without its Markdown markers, trimmed, with the changed words in the writer's ink after the words they
    /// replaced, struck; a change that only removed text shows the line with the removed words struck. A change more
    /// than 24 characters into its line shows from a word just before it, after an ellipsis.
    static func line(of id: UInt64, in live: LiveFile, text: NSString?) -> NSAttributedString {
        let store = ThemeStore.shared
        let regular: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: store.color(.ink)]
        guard let change = live.changes[id], let text else { return NSAttributedString(string: live.excerpt(id), attributes: regular) }
        let range = NSIntersectionRange(change.range, NSRange(location: 0, length: text.length))
        var line = text.lineRange(for: NSRange(location: range.location, length: 0))
        if range.length > 0, !text.substring(with: line).contains(where: { !$0.isWhitespace }) {
            line = text.lineRange(for: NSRange(location: min(range.location + 1, max(text.length - 1, 0)), length: 0))
        }
        let shown = NSMutableAttributedString(string: text.substring(with: line), attributes: regular)
        let local = NSIntersectionRange(NSRange(location: range.location - line.location, length: range.length), NSRange(location: 0, length: shown.length))
        let changed = MarkWriter(change.origin).color
        if local.length > 0 { shown.addAttribute(.foregroundColor, value: changed, range: local) }
        // A conflict's other version is no removal once the change holds text.
        let removed = change.conflict ? (local.length > 0 ? "" : change.theirs) : change.removed
        if let first = removed.split(whereSeparator: \.isNewline).first {
            let struck = NSMutableAttributedString(string: String(first), attributes: regular.merging([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: store.color(.ink2),
            ]) { $1 })
            if local.length > 0 { struck.append(NSAttributedString(string: " ", attributes: regular)) }
            shown.insert(struck, at: min(max(range.location - line.location, 0), shown.length))
        }
        strip(shown)
        let trimmed = shown.string
        let lead = trimmed.prefix { $0.isWhitespace }.utf16.count
        let tail = String(trimmed.reversed().prefix { $0.isWhitespace }).utf16.count
        guard lead + tail < shown.length else { return NSAttributedString(string: "Blank lines", attributes: regular) }
        let excerpt = NSMutableAttributedString(attributedString: shown.attributedSubstring(from: NSRange(location: lead, length: shown.length - lead - tail)))
        var first = excerpt.length
        excerpt.enumerateAttributes(in: NSRange(location: 0, length: excerpt.length)) { attributes, range, stop in
            if (attributes[.foregroundColor] as? NSColor) === changed || attributes[.strikethroughStyle] != nil {
                first = range.location
                stop.pointee = true
            }
        }
        if first > 24 {
            let string = excerpt.string as NSString
            let space = string.range(of: " ", range: NSRange(location: first - 24, length: 24)).location
            let start = space == NSNotFound ? first - 24 : space + 1
            excerpt.replaceCharacters(in: NSRange(location: 0, length: start), with: "\u{2026}")
        }
        return excerpt
    }

    /// Takes a line's Markdown markers out, keeping the attributes of the text they wrap: a quote, list or heading
    /// marker at its start, emphasis, code and highlight markers, and a link's target.
    private static func strip(_ line: NSMutableAttributedString) {
        let patterns = [
            #"^\s*(?:(?:>\s?)+|#{1,6}\s+)?(?:(?:[-*+]|\d+[.)])\s+)?(?:\[[ xX]\]\s+)?"#, #"\[(?=[^\]]*\]\()"#, #"\]\([^)]*\)"#,
            #"\*\*|__|~~|==|`"#, #"(?<![\w*])\*(?=\S)|(?<=\S)\*(?![\w*])"#,
        ]
        for pattern in patterns {
            let regex = try! NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: line.string, range: NSRange(location: 0, length: line.length)).reversed() where match.range.length > 0 {
                line.deleteCharacters(in: match.range)
            }
        }
    }
}

/// The Changes list's table: Return calls `returned`; other keys without Command, Option or Control go to `pressed`
/// first, which says whether it took the key.
final class ReturnTable: NSTableView {
    var returned: () -> Void = {}
    var pressed: (NSEvent) -> Bool = { _ in false }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        if plain, pressed(event) { return }
        guard plain, [36, 76].contains(event.keyCode), !event.modifierFlags.contains(.shift) else { return super.keyDown(with: event) }
        returned()
    }
}

/// A writer session's byline as a section label, 11 pt medium in `ink2`, with Revert Session and Keep Session in the
/// stamp's buttons, Keep filled.
private final class SessionRow: NSTableCellView {
    init(_ byline: String, decide: @escaping (Bool) -> Void) {
        super.init(frame: .zero)
        let name = NSTextField(labelWithString: byline)
        name.font = Chrome.section
        name.textColor = ThemeStore.shared.color(.ink2)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let revert = StampButton("Revert Session", keys: "", style: .outlined) { decide(false) }
        let keep = StampButton("Keep Session", keys: "", style: .filled) { decide(true) }
        revert.toolTip = "Puts back the old text of every change in this session. Revert Session (\u{2303}\u{2318}\u{232B})"
        keep.toolTip = "Clears the marks on every change in this session. Keep Session (\u{2325}\u{21E7}\u{2318}\u{21A9})"
        let row = NSStackView(views: [name, revert, keep])
        revert.widthAnchor.constraint(equalTo: keep.widthAnchor).isActive = true
        row.spacing = 4
        row.setCustomSpacing(8, after: name)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        setAccessibilityLabel(byline)
    }

    required init?(coder: NSCoder) {
        fatalError("SessionRow is built in code")
    }
}

/// A note's path in the folder in 13 pt semibold, truncated in the middle, over its byline.
private final class HeadingRow: NSTableCellView {
    init(_ title: String, detail: String?) {
        super.init(frame: .zero)
        let store = ThemeStore.shared
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = store.color(.ink)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [name])
        row.spacing = 8
        if let detail {
            let byline = NSTextField(labelWithString: detail)
            byline.font = .systemFont(ofSize: 11)
            byline.textColor = store.color(.ink2)
            row.addArrangedSubview(byline)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityLabel([title, detail].compactMap(\.self).joined(separator: ", "))
    }

    required init?(coder: NSCoder) {
        fatalError("HeadingRow is built in code")
    }
}

/// A change's line and "line 17", with Keep and Revert in place of the line number while the row is hovered or
/// selected. A closed note's row has no decisions.
final class ChangeRow: NSTableCellView {
    private let detail: NSTextField
    private let keep: FlowButton
    private let revert: FlowButton
    private let decides: Bool
    private var hovering = false {
        didSet { update() }
    }
    var selected = false {
        didSet { update() }
    }
    var optionDown = false {
        didSet {
            keep.title = optionDown ? "Keep All in Note" : "Keep"
            revert.title = optionDown ? "Revert All in Note" : "Revert"
        }
    }

    /// `lines` 0 shows every line of `title`.
    init(_ title: NSAttributedString, detail text: String, lines: Int = 1, decide: ((Bool) -> Void)?) {
        detail = NSTextField(labelWithString: text)
        keep = FlowButton("Keep", style: .plain) { decide?(true) }
        revert = FlowButton("Revert", style: .plain) { decide?(false) }
        decides = decide != nil
        super.init(frame: .zero)
        let truncated = NSMutableAttributedString(attributedString: title)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        truncated.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: truncated.length))
        let label = NSTextField(labelWithAttributedString: truncated)
        label.maximumNumberOfLines = lines
        label.cell?.truncatesLastVisibleLine = true
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = ThemeStore.shared.color(.ink2)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        keep.toolTip = "Keep (\u{2318}\u{21A9}). Option-click: Keep All in Note (\u{21E7}\u{2318}\u{21A9})"
        revert.toolTip = "Revert (\u{2325}\u{2318}\u{232B}). Option-click: Revert All in Note (\u{2325}\u{21E7}\u{2318}\u{232B})"
        let row = NSStackView(views: [label, detail, revert, keep])
        row.spacing = 4
        row.setCustomSpacing(8, after: label)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityLabel("\(title.string), \(text)")
        update()
    }

    required init?(coder: NSCoder) {
        fatalError("ChangeRow is built in code")
    }

    /// Whether Keep and Revert show.
    var showsDecisions: Bool {
        !keep.isHidden
    }

    private func update() {
        let decisions = decides && (hovering || selected)
        keep.isHidden = !decisions
        revert.isHidden = !decisions
        detail.isHidden = decisions
        wantsLayer = true
        layer?.backgroundColor = hovering || selected ? FlowColors.selection.resolved(for: effectiveAppearance).cgColor : nil
        layer?.cornerRadius = 6
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }
}

extension EditorTextView {
    func vimStepChange(forward: Bool) {
        Review.step(from: self, forward: forward)
    }

    /// Keep Session: keeps every change from the session of the change the stamp shows, in every note it touched.
    @objc func keepSession(_ sender: Any?) {
        decideSession(keep: true)
    }

    /// Revert Session: reverts every change from the session of the change the stamp shows, in every note it touched.
    @objc func revertSession(_ sender: Any?) {
        decideSession(keep: false)
    }

    private func decideSession(keep: Bool) {
        guard let id = marks.stamped, let origin = marks.live?.changes[id]?.origin else { return NSSound.beep() }
        Review.decideSession(Review.key(origin), keep: keep, in: window)
    }
}
