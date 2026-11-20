import AppKit
import MdCore

/// Find in Files' search: the matches of a query in a list of files, searched off the main thread a batch of files at a
/// time so they arrive as they're found. Each search waits, 150 ms by default, and cancels the one before it, so typing
/// searches once it pauses. A search stops at `limit` matches.
@MainActor
final class FileSearch {
    private let limit: Int
    private let batch: Int
    private(set) var results: [FileMatches] = []
    private(set) var matchCount = 0
    /// The search stopped at `limit` with matches left.
    private(set) var stopped = false
    private(set) var isSearching = false
    /// Why the last search found nothing: its pattern doesn't compile.
    private(set) var problem: String?
    /// Called with true when a search's first batch, or an empty query, replaces the results, and with false when a
    /// later batch adds to them or the search ends.
    var changed: (_ replaced: Bool) -> Void = { _ in }
    private var task: Task<Void, Never>?

    init(limit: Int = 10_000, batch: Int = 64) {
        self.limit = limit
        self.batch = batch
    }

    /// Searches `files` in order for `query` after `delay`. The results stay until the first batch replaces them; an
    /// empty query clears them at once.
    func search(_ query: String, options: SearchOptions, in files: [URL], after delay: Duration = .milliseconds(150)) {
        task?.cancel()
        task = nil
        isSearching = !query.isEmpty
        problem = nil
        guard isSearching else {
            (results, matchCount, stopped) = ([], 0, false)
            changed(true)
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.run(query, options: options, files: files)
        }
    }

    /// Stops the search in flight and keeps the results it has found.
    func cancel() {
        task?.cancel()
        task = nil
        isSearching = false
    }

    private func run(_ query: String, options: SearchOptions, files: [URL]) async {
        var first = true
        var count = 0
        for start in stride(from: 0, to: files.count, by: batch) {
            let urls = Array(files[start..<min(start + batch, files.count)])
            let remaining = limit - count
            let found: (files: [FileMatches], stopped: Bool)
            do {
                found = try await Task.detached(priority: .utility) {
                    try textMatches(of: query, in: urls, options: options, limit: remaining)
                }.value
            } catch {
                guard !Task.isCancelled else { return }
                if case .pattern(let message) = error as? SearchFailure {
                    problem = message.split(separator: "\n").last.map { String($0.trimmingPrefix("error: ")) } ?? message
                }
                break
            }
            guard !Task.isCancelled else { return }
            let added = found.files
            count += added.reduce(0) { $0 + $1.matches.count }
            if first {
                results = added
            } else {
                results += added
            }
            (matchCount, stopped) = (count, found.stopped)
            if first || !added.isEmpty {
                changed(first)
                guard !Task.isCancelled else { return }
            }
            first = false
            if stopped { break }
        }
        if first {
            (results, matchCount, stopped) = ([], 0, false)
        }
        isSearching = false
        changed(first)
    }
}

/// Find in Files in the sidebar (synthesis 2.7): a search field and a close button back to Files, Match Case, Whole Word
/// and Regular Expression under it, a replace field, a line counting the matches, then the matches grouped by file, each
/// on its line with the match marked. A `path:` term in the query searches only the files whose path in the folder
/// holds it.
final class FindInFilesController: NSViewController, NSSearchFieldDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// Opens a file from the results, at a match when there is one, in a new tab when asked.
    var reveal: (URL, TextMatch?, _ newTab: Bool) -> Void = { _, _, _ in }
    /// Leaves the search for the file tree.
    var close: () -> Void = {}

    private let folder: Folder
    private let index: FolderIndex
    private let search = FileSearch()
    private let field = NSSearchField()
    private let options = NSSegmentedControl()
    private let replacement = NSTextField()
    private let replaceButton = NSButton(title: "Replace All", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    /// Under a search that found nothing: turns off the options it ran with.
    private let clearOptions = NSButton(title: "Turn Off Options", target: nil, action: nil)
    private let closeButton = NSButton()
    private let outlineView = ResultsOutlineView()
    private var files: [ResultFile] = []
    /// Set while a query waits for the folder's first listing.
    private var waitsForFiles = false
    /// Set from a query's search until its first batch replaces the results.
    private var pending = false
    private var wasSearching = false
    /// What the last search looked for, in which files, for Replace All.
    private var searched = (query: "", options: SearchOptions(), files: [URL]())

    init(folder: Folder) {
        self.folder = folder
        index = FolderIndex.of(folder)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("FindInFilesController is built in code")
    }

    override func loadView() {
        field.placeholderString = "Find in Files"
        field.setAccessibilityLabel("Find in Files")
        field.delegate = self
        if let cancel = (field.cell as? NSSearchFieldCell)?.cancelButtonCell {
            cancel.target = self
            cancel.action = #selector(clear)
        }
        options.trackingMode = .selectAny
        options.segmentCount = 3
        let segments = [("textformat", "Match Case"), ("character.textbox", "Whole Word")]
        for (segment, (symbol, name)) in segments.enumerated() {
            options.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: name), forSegment: segment)
        }
        options.setLabel(".*", forSegment: 2)
        options.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        for (segment, name) in Self.optionNames.enumerated() {
            options.setToolTip(name, forSegment: segment)
            options.setWidth(28, forSegment: segment)
        }
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Back to Files")
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.toolTip = "Back to Files (⎋)"
        closeButton.target = self
        closeButton.action = #selector(closeSearch)
        clearOptions.controlSize = .small
        clearOptions.bezelStyle = .push
        clearOptions.target = self
        clearOptions.action = #selector(turnOffOptions)
        clearOptions.isHidden = true
        options.target = self
        options.action = #selector(optionsChanged)
        field.toolTip = "Add path:docs to search only the files whose path holds docs."
        replacement.placeholderString = "Replace"
        replacement.setAccessibilityLabel("Replace with")
        replacement.target = self
        replacement.action = #selector(replaceAll)
        replaceButton.target = self
        replaceButton.action = #selector(replaceAll)
        replaceButton.controlSize = .small
        replaceButton.setContentHuggingPriority(.required, for: .horizontal)
        replaceButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: .init("match"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.autoresizesOutlineColumn = false
        outlineView.headerView = nil
        outlineView.style = .plain
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.floatsGroupRows = false
        outlineView.backgroundColor = .clear
        outlineView.allowsTypeSelect = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(clicked)
        outlineView.setAccessibilityLabel("Matches")
        outlineView.opens = { [weak self] row, newTab in self?.open(row, newTab: newTab) }
        outlineView.closes = { [weak self] in self?.leave() }
        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        for view in [field, closeButton, options, replacement, replaceButton, status, scrollView, clearOptions] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let safe = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            field.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 10),
            closeButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            options.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            options.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            replacement.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 6),
            replacement.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            replaceButton.leadingAnchor.constraint(equalTo: replacement.trailingAnchor, constant: 6),
            replaceButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -10),
            replaceButton.centerYAnchor.constraint(equalTo: replacement.centerYAnchor),
            status.topAnchor.constraint(equalTo: replacement.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 2),
            status.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -10),
            clearOptions.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 4),
            clearOptions.leadingAnchor.constraint(equalTo: status.leadingAnchor, constant: -2),
            scrollView.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        search.changed = { [weak self] replaced in self?.resultsChanged(replaced: replaced) }
        NotificationCenter.default.addObserver(self, selector: #selector(indexChanged(_:)), name: FolderIndex.changed, object: index)
        showStatus()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        outlineView.sizeLastColumnToFit()
    }

    var query: String {
        field.stringValue
    }

    /// Focuses the field with its text selected, or with `query` in it, and searches again, since the files may have
    /// changed.
    func begin(_ query: String? = nil) {
        if let query { field.stringValue = query }
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        run(after: .zero)
    }

    private func run(after delay: Duration = .milliseconds(150)) {
        let (query, paths) = Self.scope(field.stringValue)
        let chosen = SearchOptions(
            matchCase: options.isSelected(forSegment: 0), wholeWord: options.isSelected(forSegment: 1),
            regex: options.isSelected(forSegment: 2)
        )
        let files = (index.files ?? []).map(\.url).filter { url in
            let path = folder.relativePath(of: url) ?? url.path
            return paths.allSatisfy { path.localizedCaseInsensitiveContains($0) }
        }
        waitsForFiles = !query.isEmpty && index.files == nil
        pending = true
        searched = (query, chosen, files)
        search.search(waitsForFiles ? "" : query, options: chosen, in: files, after: delay)
        showStatus()
    }

    /// `query` without its `path:` terms, and the terms.
    private static func scope(_ query: String) -> (query: String, paths: [String]) {
        var paths: [String] = []
        let rest = query.replacing(#/(?:^|\s+)path:(\S*)/#) { match in
            if !match.1.isEmpty { paths.append(String(match.1)) }
            return ""
        }
        return rest == query ? (query, []) : (rest.trimmingCharacters(in: .whitespaces), paths)
    }

    /// Asks before replacing every match the search found with the replace field's text, then replaces them: in an open
    /// note as one edit that Undo takes back, in any other file by saving it, unless it changed since it was read.
    @objc private func replaceAll() {
        guard search.matchCount > 0, !search.isSearching, !pending, let window = view.window else { return }
        let (query, chosen, all) = searched
        let with = replacement.stringValue
        let files = search.stopped ? all : search.results.map(\.url)
        let alert = NSAlert()
        let verb = with.isEmpty ? "Delete" : "Replace"
        alert.messageText = search.stopped
            ? "\(verb) every match in \(Self.count(all.count, "file"))?"
            : "\(verb) \(Self.count(search.matchCount, "match", "matches")) in \(Self.count(files.count, "file"))?"
        alert.informativeText = (with.isEmpty ? "The Replace field is empty, so each match is removed. " : "")
            + "Open notes take it as one edit you can undo. Other files are saved at once."
        alert.addButton(withTitle: "Replace All")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.replace(query, with: with, options: chosen, in: files)
        }
    }

    private func replace(_ query: String, with replacement: String, options: SearchOptions, in files: [URL]) {
        var closed: [URL] = []
        var skipped: [URL] = []
        let root = folder.url
        let realRoot = root.resolvingSymlinksInPath().path + "/"
        for url in files {
            // A link out of the folder keeps its matches, open or not.
            guard url.resolvingSymlinksInPath().path.hasPrefix(realRoot) else {
                skipped.append(url)
                continue
            }
            guard let document = NSDocumentController.shared.document(for: url) else {
                closed.append(url)
                continue
            }
            guard let textView = (document as? MarkdownDocument)?.textView,
                let replaced = try? replacingMatches(of: query, in: textView.string, with: replacement, options: options)
            else {
                skipped.append(url)
                continue
            }
            if replaced.text != textView.string { Self.replaceChanged(in: textView, with: replaced.text) }
        }
        Task { [weak self, closed, skipped] in
            let failed = await Task.detached(priority: .userInitiated) {
                closed.filter { url in
                    (try? replaceMatches(
                        of: query, inFile: url, under: root, with: replacement, options: options, engine: MarkdownDocument.sharedEngine
                    )) == nil
                }
            }.value
            guard let self else { return }
            self.run(after: .zero)
            let left = skipped + failed
            guard !left.isEmpty, let window = self.view.window else { return }
            let alert = NSAlert()
            alert.messageText = "\(Self.count(left.count, "file")) kept \(left.count == 1 ? "its" : "their") matches"
            alert.informativeText = "These lead outside the folder, changed while replacing, or couldn\u{2019}t be written:\n"
                + left.map { self.folder.relativePath(of: $0) ?? $0.path }.joined(separator: "\n")
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }

    /// Replaces the text view's text with `text` as one edit over the part that differs, so the caret and the rest
    /// stay put.
    private static func replaceChanged(in textView: EditorTextView, with text: String) {
        let old = textView.string as NSString
        let new = text as NSString
        let shorter = min(old.length, new.length)
        var start = 0
        while start < shorter, old.character(at: start) == new.character(at: start) { start += 1 }
        if start < old.length { start = old.rangeOfComposedCharacterSequence(at: start).location }
        var end = 0
        while end < shorter - start, old.character(at: old.length - 1 - end) == new.character(at: new.length - 1 - end) { end += 1 }
        if end > 0, end < old.length - start {
            end = old.length - NSMaxRange(old.rangeOfComposedCharacterSequence(at: old.length - end - 1))
        }
        textView.replaceAsOneEdit(
            NSRange(location: start, length: old.length - start - end),
            with: new.substring(with: NSRange(location: start, length: new.length - start - end)), named: "Replace All"
        )
    }

    private static func count(_ number: Int, _ one: String, _ many: String? = nil) -> String {
        "\(number.formatted()) \(number == 1 ? one : many ?? one + "s")"
    }

    /// Returns to the file tree, stopping the search; the next `begin` runs it again.
    private func leave() {
        search.cancel()
        close()
    }

    @objc private func indexChanged(_ notification: Notification) {
        if waitsForFiles { run(after: .zero) }
    }

    @objc private func optionsChanged() {
        run(after: .zero)
    }

    @objc private func turnOffOptions() {
        for segment in 0..<options.segmentCount { options.setSelected(false, forSegment: segment) }
        run(after: .zero)
    }

    @objc private func closeSearch() {
        leave()
    }

    /// The field's clear button ends the search.
    @objc private func clear() {
        field.stringValue = ""
        leave()
    }

    func controlTextDidChange(_ notification: Notification) {
        run()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)):
            run(after: .zero)
        case #selector(cancelOperation(_:)):
            leave()
        case #selector(moveDown(_:)):
            guard !files.isEmpty else { return false }
            view.window?.makeFirstResponder(outlineView)
            if outlineView.selectedRow < 0 { outlineView.selectRowIndexes([1], byExtendingSelection: false) }
        default:
            return false
        }
        return true
    }

    // MARK: Results

    private func resultsChanged(replaced: Bool) {
        if replaced {
            pending = false
            files = search.results.map(ResultFile.init)
            outlineView.reloadData()
            outlineView.expandItem(nil, expandChildren: true)
        } else if search.results.count > files.count {
            let added = search.results[files.count...].map(ResultFile.init)
            let rows = IndexSet(integersIn: files.count..<files.count + added.count)
            files += added
            outlineView.insertItems(at: rows, inParent: nil, withAnimation: [])
            for file in added {
                outlineView.expandItem(file)
            }
        }
        showStatus()
        // The keyboard stays in the field, so VoiceOver hears what a search found when it ends.
        if wasSearching, !search.isSearching {
            NSAccessibility.post(element: field, notification: .announcementRequested, userInfo: [
                .announcement: status.stringValue,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
        wasSearching = search.isSearching
    }

    private func showStatus() {
        let (matches, count) = (search.matchCount, search.results.count)
        let found = "\(matches.formatted()) \(matches == 1 ? "match" : "matches") in \(count.formatted()) \(count == 1 ? "file" : "files")"
        replaceButton.isEnabled = matches > 0 && !search.isSearching && !pending
        status.stringValue = if field.stringValue.isEmpty {
            "Search the notes in \(FileManager.default.displayName(atPath: folder.url.path))."
        } else if let problem = search.problem {
            "Not a valid pattern: \(problem)"
        } else if waitsForFiles {
            "Listing files…"
        } else if pending {
            "Searching…"
        } else if search.stopped {
            "Stopped at \(found)"
        } else if search.isSearching {
            matches == 0 ? "Searching…" : "\(found) so far"
        } else if matches == 0 {
            noMatches
        } else {
            found
        }
        clearOptions.isHidden = !(matches == 0 && !search.isSearching && !pending && !field.stringValue.isEmpty && !chosenOptions.isEmpty)
    }

    private static let optionNames = ["Match Case", "Whole Word", "Regular Expression"]

    /// The names of the options switched on.
    private var chosenOptions: [String] {
        Self.optionNames.indices.filter { options.isSelected(forSegment: $0) }.map { Self.optionNames[$0] }
    }

    /// "No matches for “kafka” in 9 notes in relay, with Whole Word on. Files .gitignore hides are skipped."
    private var noMatches: String {
        let (query, _) = Self.scope(field.stringValue)
        var line = "No matches for \u{201C}\(query)\u{201D} in \(Self.count(searched.files.count, "note")) in "
            + FileManager.default.displayName(atPath: folder.url.path)
        let on = chosenOptions
        if !on.isEmpty { line += ", with " + ListFormatter.localizedString(byJoining: on) + " on" }
        line += "."
        if !Preferences.shared.showsIgnored { line += " Files .gitignore hides are skipped." }
        return line
    }

    /// A click opens in this tab and a Command-click in a new one.
    @objc private func clicked() {
        open(outlineView.clickedRow, newTab: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    private func open(_ row: Int, newTab: Bool) {
        switch outlineView.item(atRow: row) {
        case let line as ResultLine: reveal(line.url, line.match, newTab)
        case let file as ResultFile: reveal(file.url, nil, newTab)
        default: break
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? ResultFile)?.lines.count ?? (item == nil ? files.count : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? ResultFile)?.lines[index] ?? files[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is ResultFile
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is ResultFile ? 26 : 22
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        StationRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let file = item as? ResultFile {
            let cell = outlineView.makeView(withIdentifier: FileResultCell.identifier, owner: nil) as? FileResultCell ?? FileResultCell()
            let path = folder.relativePath(of: file.url.deletingLastPathComponent()) ?? ""
            cell.show(file.url.lastPathComponent, in: path, count: file.lines.count)
            return cell
        }
        let line = item as! ResultLine
        let cell = outlineView.makeView(withIdentifier: LineResultCell.identifier, owner: nil) as? LineResultCell ?? LineResultCell()
        cell.show(line.match)
        cell.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Go to Match") { [weak self] in
            self?.reveal(line.url, line.match, false)
            return true
        }])
        return cell
    }
}

/// A file in the results, with its matches as the rows under it.
private final class ResultFile {
    let url: URL
    let lines: [ResultLine]

    init(_ found: FileMatches) {
        url = found.url
        lines = found.matches.map { ResultLine(url: found.url, match: $0) }
    }
}

private final class ResultLine {
    let url: URL
    let match: TextMatch

    init(url: URL, match: TextMatch) {
        self.url = url
        self.match = match
    }
}

/// The results: Return opens the selected row, Command-Return in a new tab, and Escape leaves the search.
private final class ResultsOutlineView: NSOutlineView {
    var opens: (_ row: Int, _ newTab: Bool) -> Void = { _, _ in }
    var closes: () -> Void = {}

    /// The chevron and the rows sit on the sidebar's 8 pt inset.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        super.frameOfOutlineCell(atRow: row).offsetBy(dx: 8, dy: 0)
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        return NSRect(x: frame.minX + 8, y: frame.minY, width: max(frame.width - 8, 0), height: frame.height)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: opens(selectedRow, event.modifierFlags.contains(.command))
        case 53: closes()
        default: super.keyDown(with: event)
        }
    }
}

/// A file's row: its name in `ink`, the folder it is in and how many matches it holds in `ink2`, the symbol in `ink3`;
/// `paper` on the focused list's selection.
private final class FileResultCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("searchFile")

    private let folder = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        let name = NSTextField(labelWithString: "")
        name.font = Chrome.label
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        folder.font = .systemFont(ofSize: Chrome.size(.subheadline))
        folder.lineBreakMode = .byTruncatingHead
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.font = .monospacedDigitSystemFont(ofSize: Chrome.size(.subheadline), weight: .regular)
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        imageView = icon
        textField = name
        for view in [icon, name, folder, count] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            folder.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            folder.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            folder.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            count.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(paint), name: ThemeStore.didChange, object: nil)
        paint()
    }

    required init?(coder: NSCoder) {
        fatalError("FileResultCell is built in code")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { paint() }
    }

    @objc private func paint() {
        let onAccent = backgroundStyle == .emphasized
        imageView?.contentTintColor = Chrome.color(onAccent ? .paper : .ink3)
        textField?.textColor = Chrome.color(onAccent ? .paper : .ink)
        for label in [folder, count] { label.textColor = Chrome.color(onAccent ? .paper : .ink2) }
    }

    func show(_ name: String, in path: String, count matches: Int) {
        textField?.stringValue = name
        folder.stringValue = path
        count.stringValue = matches.formatted()
        let label = [name, path, "\(matches.formatted()) \(matches == 1 ? "match" : "matches")"].filter { !$0.isEmpty }
        setAccessibilityLabel(label.joined(separator: ", "))
    }
}

/// A match's row: its line number in `ink2`, then the line in `ink` with the match on the theme's find highlight, all
/// `paper` on the focused list's selection. The line is not the cell's `textField`, which a source list restyles,
/// dropping the highlight.
private final class LineResultCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("searchLine")

    private let number = NSTextField(labelWithString: "")
    private let line = NSTextField(labelWithString: "")
    private var match: TextMatch?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        number.font = .monospacedDigitSystemFont(ofSize: Chrome.size(.subheadline), weight: .regular)
        number.alignment = .right
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [number, line] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: leadingAnchor),
            number.widthAnchor.constraint(equalToConstant: 30),
            number.firstBaselineAnchor.constraint(equalTo: line.firstBaselineAnchor),
            line.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 6),
            line.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(render), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("LineResultCell is built in code")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
    }

    func show(_ match: TextMatch) {
        self.match = match
        number.stringValue = String(match.line)
        render()
        setAccessibilityLabel("Line \(match.line): \(match.preview)")
    }

    /// On the focused list's selection the line is `paper` and the match a lighter wash of it.
    @objc private func render() {
        guard let match else { return }
        let selected = backgroundStyle == .emphasized
        number.textColor = Chrome.color(selected ? .paper : .ink2)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let ink = Chrome.color(selected ? .paper : .ink)
        let (preview, range) = Self.centered(match.preview, on: match.previewRange)
        let text = NSMutableAttributedString(string: preview, attributes: [
            .font: Chrome.small, .foregroundColor: ink, .paragraphStyle: style,
        ])
        text.addAttributes([
            .backgroundColor: selected ? ink.withAlphaComponent(0.25) : Self.findMatch,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: ThemeStore.shared.color(.signal),
        ], range: range)
        line.attributedStringValue = text
    }

    /// The line from a word about 20 characters before the match, after an ellipsis, so a match far along a line shows
    /// with the words around it.
    static func centered(_ preview: String, on match: NSRange) -> (String, NSRange) {
        let text = preview as NSString
        guard match.location > 24 else { return (preview, match) }
        var start = match.location - 20
        while start > 0, !CharacterSet.whitespaces.contains(UnicodeScalar(text.character(at: start - 1)) ?? " ") { start -= 1 }
        if start < 2 { return (preview, match) }
        start = text.rangeOfComposedCharacterSequence(at: start).location
        return ("\u{2026}" + text.substring(from: start), NSRange(location: match.location - start + 1, length: match.length))
    }

    /// Signal at 12%, the most a signal fill takes; the match's underline carries it.
    private static var findMatch: NSColor {
        let signal = ThemeStore.shared.color(.signal)
        return NSColor(name: nil) { signal.resolved(for: $0).withAlphaComponent(0.12) }
    }
}
