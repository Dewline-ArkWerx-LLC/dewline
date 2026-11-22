import AppKit
import MdCore

/// File > Earlier Versions…: a sheet listing the note's snapshots, newest first ("Today, 9:41 AM · Claude Code") over
/// what each changed ("+12 words · Backoff"), and beside the list what restoring the selected one would change in the
/// current text. A row's pin shows while it is pinned, selected or under the pointer. It opens on the newest that differs
/// from the text, and keeps its selection as the list rereads. Restore is one undoable edit; Open as Copy writes it to a
/// new note beside this one; neither runs for a version that is the text.
@MainActor
final class EarlierVersions: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static var open: EarlierVersions?

    private weak var document: MarkdownDocument?
    private let live: LiveFile
    let sheet: NSWindow
    let table = NSTableView()
    private let diff = NSTextView()
    private let heading = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "No earlier versions yet.")
    let restore = NSButton(title: "Restore", target: nil, action: nil)
    private let copy = NSButton(title: "Open as Copy", target: nil, action: nil)
    /// The selected snapshot's text, once read.
    private(set) var text: String?
    private var reading: Task<Void, Never>?
    /// Each row's text and what it changed from the row below, by the id of the snapshot that names its writer.
    private var texts: [UInt64: String] = [:]
    private(set) var summaries: [UInt64: String] = [:]
    private var summarizing: Task<Void, Never>?
    static let minimumWidth: CGFloat = 420

    static func show(for document: MarkdownDocument, on window: NSWindow) {
        guard let live = document.live else { return }
        let versions = EarlierVersions(document, live)
        versions.sheet.setContentSize(NSSize(width: width(in: window.frame.width), height: 460))
        open = versions
        window.beginSheet(versions.sheet) { _ in open = nil }
        versions.sheet.makeFirstResponder(versions.table)
    }

    /// The sheet's width over a window `parent` points wide: 760, or 20 points in from each side of a narrower one.
    static func width(in parent: CGFloat) -> CGFloat {
        max(minimumWidth, min(760, parent - 40))
    }

    init(_ document: MarkdownDocument, _ live: LiveFile) {
        self.document = document
        self.live = live
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        super.init()
        sheet.title = "Earlier Versions"
        heading.stringValue = "Earlier Versions of \(document.fileURL?.lastPathComponent ?? document.displayName ?? "")"
        sheet.minSize = NSSize(width: Self.minimumWidth, height: 320)
        build()
        live.reloadSnapshots { [weak self] in self?.reload() }
        reload()
    }

    private func build() {
        let column = NSTableColumn(identifier: .init("Version"))
        column.resizingMask = .autoresizingMask
        let pins = NSTableColumn(identifier: .init("Pinned"))
        pins.width = 52
        pins.resizingMask = []
        table.addTableColumn(column)
        table.addTableColumn(pins)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 40
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Earlier versions")
        let list = NSScrollView()
        list.documentView = table
        list.hasVerticalScroller = true
        list.autohidesScrollers = true
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.lineBreakMode = .byTruncatingMiddle
        diff.isEditable = false
        diff.textContainerInset = NSSize(width: 12, height: 12)
        diff.setAccessibilityLabel("What restoring changes")
        let pane = NSScrollView()
        pane.documentView = diff
        pane.hasVerticalScroller = true
        pane.autohidesScrollers = true
        diff.autoresizingMask = [.width]
        diff.isVerticallyResizable = true
        empty.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
        cancel.keyEquivalent = "\u{1B}"
        copy.target = self
        copy.action = #selector(openCopy)
        restore.target = self
        restore.action = #selector(restoreSelected)
        restore.keyEquivalent = "\r"
        let buttons = NSStackView(views: [copy, NSView(), cancel, restore])
        buttons.spacing = 8
        let root = NSView()
        let share = list.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.4)
        share.priority = .defaultHigh
        for view in [heading, list, pane, buttons, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            list.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            list.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            share,
            list.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),
            pane.topAnchor.constraint(equalTo: list.topAnchor),
            pane.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 12),
            pane.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            pane.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            empty.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: list.centerYAnchor),
        ])
        sheet.contentView = root
        sheet.initialFirstResponder = table
    }

    /// The list's rows, newest first: snapshots of the same bytes taken within a second of each other, and an agent turn's
    /// writes, are one row.
    private(set) var rows: [[ChangeEngine.Snapshot]] = []

    private func reload() {
        let selected = self.selected?.id
        rows = Self.merged(live.snapshots)
        table.reloadData()
        empty.isHidden = !rows.isEmpty
        if !rows.isEmpty {
            let buffer = Data((document?.textView?.string ?? "").utf8)
            let row = rows.firstIndex { $0.contains { $0.id == selected } } ?? rows.firstIndex { !$0[0].holds(buffer) } ?? 0
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        selectionChanged()
        summarize()
    }

    /// Reads the rows' texts off the main thread, each once, then puts under each row what it changed from the one below.
    private func summarize() {
        summarizing?.cancel()
        guard let buffer = document?.textView?.string else { return }
        let shown = rows.map(Self.credited)
        let unread = shown.filter { texts[$0.id] == nil }
        let (engine, doc, known) = (live.engine, live.doc, texts)
        summarizing = Task { [weak self] in
            let (texts, summaries) = await Task.detached {
                var texts = known
                for snapshot in unread { texts[snapshot.id] = try? engine.restore(doc, snapshot: snapshot, buffer: buffer) }
                var summaries: [UInt64: String] = [:]
                for (newer, older) in zip(shown, shown.dropFirst()) {
                    guard let after = texts[newer.id], let before = texts[older.id] else { continue }
                    summaries[newer.id] = Self.summary(of: after, over: before)
                }
                return (texts, summaries)
            }.value
            guard let self, !Task.isCancelled else { return }
            (self.texts, self.summaries) = (texts, summaries)
            table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count), columnIndexes: [0])
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = VersionRow()
        view.hovered = { [weak self] in self?.showPins() }
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let snapshot = Self.credited(rows[row])
        guard tableColumn?.identifier.rawValue == "Pinned" else {
            let seconds = rows.contains { $0[0].id != rows[row][0].id && Calendar.current.isDate($0[0].time, equalTo: snapshot.time, toGranularity: .minute) }
            let title = NSTextField(labelWithString: Self.title(of: snapshot, seconds: seconds))
            let summary = NSTextField(labelWithString: summaries[snapshot.id] ?? "")
            summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            summary.textColor = .secondaryLabelColor
            let lines = NSStackView(views: [title, summary])
            lines.orientation = .vertical
            lines.alignment = .leading
            lines.spacing = 1
            for label in [title, summary] { label.lineBreakMode = .byTruncatingTail }
            lines.translatesAutoresizingMaskIntoConstraints = false
            let cell = NSTableCellView()
            cell.addSubview(lines)
            NSLayoutConstraint.activate([
                lines.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                lines.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                lines.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        let pin = NSButton(image: NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin") ?? NSImage(), target: self, action: #selector(pinChanged(_:)))
        pin.setButtonType(.toggle)
        pin.alternateImage = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
        pin.isBordered = false
        pin.contentTintColor = .secondaryLabelColor
        pin.state = rows[row].contains(where: \.pinned) ? .on : .off
        pin.tag = row
        pin.toolTip = "A pinned version is kept until you unpin it."
        pin.isHidden = pin.state == .off && row != tableView.selectedRow
        pin.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.addSubview(pin)
        NSLayoutConstraint.activate([
            pin.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            pin.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectionChanged()
        showPins()
    }

    @objc private func pinChanged(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        for snapshot in rows[sender.tag] { live.pin(snapshot, sender.state == .on) }
    }

    /// Shows each row's pin while it is pinned, selected or under the pointer.
    private func showPins() {
        table.enumerateAvailableRowViews { view, row in
            guard let pin = view.view(atColumn: 1).flatMap({ ($0 as? NSView)?.subviews.first as? NSButton }) else { return }
            pin.isHidden = pin.state == .off && !view.isSelected && (view as? VersionRow)?.isHovered != true
        }
    }

    var selected: ChangeEngine.Snapshot? {
        rows.indices.contains(table.selectedRow) ? Self.credited(rows[table.selectedRow]) : nil
    }

    /// Reads the selected version's text off the main thread. The engine snapshots the current text first, as Restore
    /// would, so browsing never loses it.
    private func selectionChanged() {
        reading?.cancel()
        text = nil
        restore.isEnabled = false
        copy.isEnabled = false
        diff.textStorage?.setAttributedString(NSAttributedString())
        guard let snapshot = selected, let buffer = document?.textView?.string else { return }
        let (engine, doc) = (live.engine, live.doc)
        reading = Task { [weak self] in
            let text = await Task.detached { try? engine.restore(doc, snapshot: snapshot, buffer: buffer) }.value
            guard let self, !Task.isCancelled, let text else { return }
            self.text = text
            restore.isEnabled = text != buffer
            copy.isEnabled = text != buffer
            // The first hunk starts at most two lines above its change, so the top of the pane shows it.
            diff.textStorage?.setAttributedString(Self.difference(from: buffer, to: text, ink: MarkWriter(snapshot.origin).color))
            diff.scroll(.zero)
        }
    }

    /// Selects the version at `index` and waits for its text, through any reread the list starts meanwhile.
    func select(_ index: Int) async {
        guard rows.indices.contains(index) else { return }
        table.selectRowIndexes([index], byExtendingSelection: false)
        var waited: Task<Void, Never>?
        while let current = reading, current != waited {
            waited = current
            await current.value
        }
    }

    @objc func restoreSelected() {
        guard let snapshot = selected else { return }
        let live = live
        close()
        Task { await live.restore(snapshot) }
    }

    @objc func openCopy() {
        guard let text, let url = document?.fileURL else { return }
        let copy = FileActions.free(url.deletingPathExtension().lastPathComponent + " copy", extension: "md", in: url.deletingLastPathComponent())
        do {
            try Data(text.utf8).write(to: copy, options: .withoutOverwriting)
            close()
            (document?.windowControllers.first as? MainWindowController)?.open(copy, newTab: true)
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc func close() {
        reading?.cancel()
        summarizing?.cancel()
        sheet.sheetParent?.endSheet(sheet)
    }
}

extension EarlierVersions {
    /// `snapshots`, newest first, with each run of the same bytes taken within a second of the one before, and each run
    /// of one agent session's writes no more than 30 seconds apart (its turn), as one row.
    static func merged(_ snapshots: [ChangeEngine.Snapshot]) -> [[ChangeEngine.Snapshot]] {
        var rows: [[ChangeEngine.Snapshot]] = []
        for snapshot in snapshots {
            guard let last = rows.last?.last else {
                rows.append([snapshot])
                continue
            }
            let gap = abs(last.time.timeIntervalSince(snapshot.time))
            let twin = hash(of: snapshot).map { $0 == hash(of: last) } == true && gap < 1
            let turn: Bool = if case .agent = snapshot.origin { snapshot.origin == last.origin && gap <= 30 } else { false }
            if twin || turn {
                rows[rows.count - 1].append(snapshot)
            } else {
                rows.append([snapshot])
            }
        }
        return rows
    }

    /// The bytes' hash MdCore keeps in each snapshot without making it public.
    private static func hash(of snapshot: ChangeEngine.Snapshot) -> Data? {
        Mirror(reflecting: snapshot).descendant("hash") as? Data
    }

    /// The row's snapshot that names its writer: an agent, git or a collaborator before you, and you before Another app.
    static func credited(_ row: [ChangeEngine.Snapshot]) -> ChangeEngine.Snapshot {
        func rank(_ origin: ChangeEngine.Origin) -> Int {
            switch origin {
            case .external: 2
            case .user: 1
            default: 0
            }
        }
        return row.min { rank($0.origin) < rank($1.origin) }!
    }

    /// "Today, 9:41 AM · Claude Code", with seconds when another snapshot shares its minute.
    static func title(of snapshot: ChangeEngine.Snapshot, seconds: Bool = false) -> String {
        let day = DateFormatter()
        day.dateStyle = .medium
        day.timeStyle = .none
        day.doesRelativeDateFormatting = true
        let time = snapshot.time.formatted(date: .omitted, time: seconds ? .standard : .shortened)
        let name = snapshot.label == "You (Revert)" ? snapshot.label : writer(snapshot.origin)
        return "\(day.string(from: snapshot.time)), \(time) \u{00B7} \(name)"
    }

    static func writer(_ origin: ChangeEngine.Origin) -> String {
        switch origin {
        case .user: "You"
        case .agent(.claude, _): "Claude Code"
        case .agent(.codex, _): "Codex"
        case .agent(.cursor, _): "Cursor"
        case .agent(.demo, _): "Demo agent"
        case .agent(.acp, let session): String(session.prefix { $0 != "#" })
        case .git(let action): action ?? "git"
        case .external: "Another app"
        case .collaborator(_, let name): name
        }
    }

    /// The diff's face: the body's, at the sheet's text size.
    static var font: NSFont {
        NSFont(descriptor: ThemeStore.shared.bodyFont.fontDescriptor, size: 13) ?? .systemFont(ofSize: 13)
    }

    private enum Kind { case same, back, gone }

    /// What restoring `old` over `current` does: each run of changed lines with two lines either side, under a
    /// "Lines 21–29" header in the current text's numbers when lines are left out. A line both texts hold with some words
    /// changed shows once, the words restoring takes out struck on the code-deleted tint and the words it brings back on
    /// `ink`'s wash (git-added's without one); a line only one holds is struck after − or washed after +. Context is in
    /// ink 2, and the same text shows whole. A wrapped line's rows start past the gutter.
    static func difference(from current: String, to old: String, ink: NSColor? = nil) -> NSAttributedString {
        let now = lines(current)
        let then = lines(old)
        var entries: [(text: String, kind: Kind, line: Int)] = []
        for (text, kind, index) in steps(from: now, to: then) {
            entries.append((text, kind, max(1, min(index + 1, now.count))))
        }
        let font = font
        func tint(_ color: NSColor, _ alpha: CGFloat) -> NSColor {
            NSColor(name: nil) { color.resolved(for: $0).withAlphaComponent(alpha) }
        }
        let added = ink ?? ThemeStore.shared.color(.gitAdded)
        let deleted = ThemeStore.shared.color(.codeDeleted)
        let hanging = NSMutableParagraphStyle()
        hanging.headIndent = ("+ " as NSString).size(withAttributes: [.font: font]).width
        let out = NSMutableAttributedString()
        func append(_ gutter: String, _ runs: [(String, Kind)], context: Bool = false) {
            let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: context ? NSColor.secondaryLabelColor : NSColor.labelColor, .paragraphStyle: hanging]
            out.append(NSAttributedString(string: gutter, attributes: plain.merging([.foregroundColor: NSColor.tertiaryLabelColor]) { $1 }))
            for (text, kind) in runs {
                var attributes = plain
                switch kind {
                case .same: break
                case .back: attributes[.backgroundColor] = tint(added, gutter == "  " ? 0.24 : 0.16)
                case .gone:
                    attributes[.backgroundColor] = tint(deleted, 0.14)
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                out.append(NSAttributedString(string: text, attributes: attributes))
            }
            out.append(NSAttributedString(string: "\n", attributes: plain))
        }
        let changed = entries.indices.filter { entries[$0].kind != .same }
        guard !changed.isEmpty else {
            for entry in entries { append("  ", [(entry.text, .same)], context: true) }
            return out
        }
        var hunks: [ClosedRange<Int>] = []
        for index in changed {
            let range = max(index - 2, 0)...min(index + 2, entries.count - 1)
            if let last = hunks.last, range.lowerBound <= last.upperBound + 1 {
                hunks[hunks.count - 1] = last.lowerBound...range.upperBound
            } else {
                hunks.append(range)
            }
        }
        let headed = hunks.count > 1 || hunks[0] != entries.indices.first!...entries.indices.last!
        for hunk in hunks {
            if headed {
                let numbers = entries[hunk].map(\.line)
                let (low, high) = (numbers.min()!, numbers.max()!)
                let style = hanging.mutableCopy() as! NSMutableParagraphStyle
                style.paragraphSpacingBefore = out.length > 0 ? 10 : 0
                out.append(NSAttributedString(string: low == high ? "Line \(low)\n" : "Lines \(low)\u{2013}\(high)\n", attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style,
                ]))
            }
            var index = hunk.lowerBound
            while index <= hunk.upperBound {
                guard entries[index].kind != .same else {
                    append("  ", [(entries[index].text, .same)], context: true)
                    index += 1
                    continue
                }
                var end = index
                while end <= hunk.upperBound, entries[end].kind != .same { end += 1 }
                let gone = entries[index..<end].filter { $0.kind == .gone }.map(\.text)
                let back = entries[index..<end].filter { $0.kind == .back }.map(\.text)
                for pair in 0..<max(gone.count, back.count) {
                    if pair < gone.count, pair < back.count, let words = words(from: gone[pair], to: back[pair]) {
                        append("  ", words)
                        continue
                    }
                    if pair < gone.count { append("\u{2212} ", [(gone[pair], .gone)]) }
                    if pair < back.count { append("+ ", [(back[pair], .back)]) }
                }
                index = end
            }
        }
        return out
    }

    private nonisolated static func lines(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        return text.hasSuffix("\n") ? Array(lines.dropLast()) : lines
    }

    /// `now` and `then` merged in reading order, each item kept, only in `now` (gone) or only in `then` (back), with
    /// its place in `now`.
    private nonisolated static func steps(from now: [String], to then: [String]) -> [(String, Kind, Int)] {
        let steps = then.difference(from: now)
        func offset(_ change: CollectionDifference<String>.Change) -> Int {
            switch change {
            case .insert(let offset, _, _), .remove(let offset, _, _): offset
            }
        }
        let removed = Set(steps.removals.map(offset))
        let inserted = Set(steps.insertions.map(offset))
        var out: [(String, Kind, Int)] = []
        var (i, j) = (0, 0)
        while i < now.count || j < then.count {
            if i < now.count, removed.contains(i) {
                out.append((now[i], .gone, i))
                i += 1
            } else if j < then.count, inserted.contains(j) {
                out.append((then[j], .back, i))
                j += 1
            } else {
                if i < now.count { out.append((now[i], .same, i)) }
                i += 1
                j += 1
            }
        }
        return out
    }

    /// Words, and the spaces and marks between them, one each.
    nonisolated static func tokens(_ line: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        for character in line {
            if character.isLetter || character.isNumber {
                word.append(character)
                continue
            }
            if !word.isEmpty { tokens.append(word) }
            word = ""
            tokens.append(String(character))
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens
    }

    private nonisolated static func isWord(_ token: String) -> Bool {
        token.contains { $0.isLetter || $0.isNumber }
    }

    /// `current` turning into `old` word by word, each changed run its removed words then its returned ones, with a
    /// space between two changed words joining them; nil when the lines share under half their words, which read better
    /// as one line struck and one brought back.
    private static func words(from current: String, to old: String) -> [(String, Kind)]? {
        let (now, then) = (tokens(current), tokens(old))
        let walk = steps(from: now, to: then).map { ($0.0, $0.1) }
        let kept = walk.count { $0.1 == .same && isWord($0.0) }
        guard kept * 2 >= min(now.count { isWord($0) }, then.count { isWord($0) }) else { return nil }
        var out: [(String, Kind)] = []
        var run: (gone: String, back: String) = ("", "")
        func flush() {
            if !run.gone.isEmpty { out.append((run.gone, .gone)) }
            if !run.back.isEmpty { out.append((run.back, .back)) }
            run = ("", "")
        }
        for (index, (text, kind)) in walk.enumerated() {
            switch kind {
            case .gone: run.gone += text
            case .back: run.back += text
            case .same:
                let joins = text.allSatisfy(\.isWhitespace) && !(run.gone + run.back).isEmpty
                    && index + 1 < walk.count && walk[index + 1].1 != .same
                if joins {
                    run.gone += text
                    run.back += text
                } else {
                    flush()
                    out.append((text, .same))
                }
            }
        }
        flush()
        return out
    }

    /// What `newer` changed from `older`, counted in words, and the heading over its first changed line:
    /// "+12 −3 words · Backoff".
    nonisolated static func summary(of newer: String, over older: String) -> String {
        let steps = tokens(newer).difference(from: tokens(older))
        func count(_ changes: [CollectionDifference<String>.Change]) -> Int {
            changes.count { change in
                switch change {
                case .insert(_, let token, _), .remove(_, let token, _): isWord(token)
                }
            }
        }
        let (added, removed) = (count(steps.insertions), count(steps.removals))
        let counted = switch (added, removed) {
        case (0, 0): newer == older ? "No change" : "Spacing only"
        case (_, 0): "+\(added) word\(added == 1 ? "" : "s")"
        case (0, _): "\u{2212}\(removed) word\(removed == 1 ? "" : "s")"
        default: "+\(added) \u{2212}\(removed) words"
        }
        let (after, before) = (lines(newer), lines(older))
        let shared = min(after.count, before.count)
        let first = (0..<shared).first { after[$0] != before[$0] } ?? shared
        let heading = after.prefix(first + 1).last { line in
            let marks = line.prefix { $0 == "#" }.count
            return (1...6).contains(marks) && line.dropFirst(marks).first == " "
        }
        guard let heading else { return counted }
        return "\(counted) \u{00B7} \(heading.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))"
    }
}

/// A row that says when the pointer enters or leaves it, so its pin can show.
private final class VersionRow: NSTableRowView {
    var hovered: (() -> Void)?
    private(set) var isHovered = false
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        hovered?()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        hovered?()
    }
}
