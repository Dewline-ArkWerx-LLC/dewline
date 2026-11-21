import AppKit
import MdCore

/// File > Earlier Versions…: a sheet listing the note's snapshots, newest first ("Today, 9:41 AM · Claude Code"),
/// with a pin on each, and beside the list what restoring the selected one would change in the current text. It opens
/// on the newest that differs from the text, and keeps its selection as the list rereads. Restore is one undoable edit; Open as Copy writes it to a new note beside
/// this one; neither runs for a version that is the text.
@MainActor
final class EarlierVersions: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static var open: EarlierVersions?

    private weak var document: MarkdownDocument?
    private let live: LiveFile
    let sheet: NSWindow
    private let table = NSTableView()
    private let diff = NSTextView()
    private let heading = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "No earlier versions yet.")
    let restore = NSButton(title: "Restore", target: nil, action: nil)
    private let copy = NSButton(title: "Open as Copy", target: nil, action: nil)
    /// The selected snapshot's text, once read.
    private(set) var text: String?
    private var reading: Task<Void, Never>?

    static func show(for document: MarkdownDocument, on window: NSWindow) {
        guard let live = document.live else { return }
        let versions = EarlierVersions(document, live)
        open = versions
        window.beginSheet(versions.sheet) { _ in open = nil }
    }

    init(_ document: MarkdownDocument, _ live: LiveFile) {
        self.document = document
        self.live = live
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        super.init()
        sheet.title = "Earlier Versions"
        heading.stringValue = "Earlier Versions of \(document.fileURL?.lastPathComponent ?? document.displayName ?? "")"
        sheet.minSize = NSSize(width: 560, height: 320)
        build()
        live.reloadSnapshots { [weak self] in self?.reload() }
        reload()
    }

    private func build() {
        let column = NSTableColumn(identifier: .init("Version"))
        column.title = "Version"
        column.resizingMask = .autoresizingMask
        let pins = NSTableColumn(identifier: .init("Pinned"))
        pins.title = "Pinned"
        pins.width = 52
        pins.resizingMask = []
        table.addTableColumn(column)
        table.addTableColumn(pins)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.style = .inset
        table.rowHeight = 32
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
            list.widthAnchor.constraint(equalToConstant: 300),
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

    /// The list's rows, newest first: snapshots of the same bytes taken within a second of each other are one row.
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
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let snapshot = Self.credited(rows[row])
        guard tableColumn?.identifier.rawValue == "Pinned" else {
            let seconds = rows.contains { $0[0].id != rows[row][0].id && Calendar.current.isDate($0[0].time, equalTo: snapshot.time, toGranularity: .minute) }
            let title = NSTextField(labelWithString: Self.title(of: snapshot, seconds: seconds))
            title.lineBreakMode = .byTruncatingTail
            title.translatesAutoresizingMaskIntoConstraints = false
            let cell = NSTableCellView()
            cell.addSubview(title)
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
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
    }

    @objc private func pinChanged(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        for snapshot in rows[sender.tag] { live.pin(snapshot, sender.state == .on) }
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
            diff.textStorage?.setAttributedString(Self.difference(from: buffer, to: text))
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
        sheet.sheetParent?.endSheet(sheet)
    }
}

extension EarlierVersions {
    /// `snapshots`, newest first, with each run of the same bytes taken within a second of the one before as one row.
    static func merged(_ snapshots: [ChangeEngine.Snapshot]) -> [[ChangeEngine.Snapshot]] {
        var rows: [[ChangeEngine.Snapshot]] = []
        for snapshot in snapshots {
            if let last = rows.last?.last, let bytes = hash(of: snapshot), bytes == hash(of: last), abs(last.time.timeIntervalSince(snapshot.time)) < 1 {
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

    /// What restoring `old` over `current` does, line by line, in full: lines it brings back after + on the theme's
    /// git-added tint, lines it removes struck after − on its code-deleted tint, the rest in ink 2. The same text shows
    /// all in ink 2.
    static func difference(from current: String, to old: String) -> NSAttributedString {
        func lines(_ text: String) -> [String] {
            let lines = text.components(separatedBy: "\n")
            return text.hasSuffix("\n") ? Array(lines.dropLast()) : lines
        }
        let now = lines(current)
        let then = lines(old)
        let steps = then.difference(from: now)
        func offset(_ change: CollectionDifference<String>.Change) -> Int {
            switch change {
            case .insert(let offset, _, _), .remove(let offset, _, _): offset
            }
        }
        let removed = Set(steps.removals.map(offset))
        let inserted = Set(steps.insertions.map(offset))
        enum Kind { case same, back, gone }
        var lines: [(String, Kind)] = []
        var (i, j) = (0, 0)
        while i < now.count || j < then.count {
            if i < now.count, removed.contains(i) {
                lines.append((now[i], .gone))
                i += 1
            } else if j < then.count, inserted.contains(j) {
                lines.append((then[j], .back))
                j += 1
            } else {
                if i < now.count { lines.append((now[i], .same)) }
                i += 1
                j += 1
            }
        }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        func tint(_ token: Token, _ alpha: CGFloat) -> NSColor {
            let color = ThemeStore.shared.color(token)
            return NSColor(name: nil) { color.resolved(for: $0).withAlphaComponent(alpha) }
        }
        let added = tint(.gitAdded, 0.16)
        let deleted = tint(.codeDeleted, 0.14)
        let out = NSMutableAttributedString()
        for (line, kind) in lines {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let gutter: String
            switch kind {
            case .same:
                gutter = "  "
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            case .back:
                gutter = "+ "
                attributes[.backgroundColor] = added
            case .gone:
                gutter = "\u{2212} "
                attributes[.backgroundColor] = deleted
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            var mark = attributes
            mark[.strikethroughStyle] = nil
            mark[.foregroundColor] = NSColor.tertiaryLabelColor
            out.append(NSAttributedString(string: gutter, attributes: mark))
            out.append(NSAttributedString(string: line + "\n", attributes: attributes))
        }
        return out
    }
}
