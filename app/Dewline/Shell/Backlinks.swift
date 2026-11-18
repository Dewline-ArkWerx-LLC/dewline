import AppKit
import MdCore

/// The lines in other notes that link to the open note, each under its note's name; a click opens the note at the
/// link. Reads the folder off the main thread each time it shows a note.
final class BacklinksPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// Opens a note with a link's range selected.
    var open: (URL, NSRange) -> Void = { _, _ in }

    private let table = NSTableView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private var links: [Backlink] = []
    private var folder: URL?
    private var listing: Task<Void, Never>?

    override func loadView() {
        let root = ChromeFill()
        let column = NSTableColumn(identifier: .init("link"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowHeight = 44
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.setAccessibilityLabel("Backlinks")
        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        empty.font = Chrome.small
        empty.textColor = Chrome.color(.ink2)
        empty.alignment = .center
        for view in [scrollView, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            empty.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            empty.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
        ])
        view = root
    }

    /// Lists the links to `note` from the other notes in `folder`.
    func show(_ note: URL?, in folder: URL?) {
        loadViewIfNeeded()
        listing?.cancel()
        self.folder = folder
        guard let note, let folder else {
            list([], empty: "Open a note in a folder to see the notes that link to it.")
            return
        }
        listing = Task { [weak self] in
            let found = await Task.detached { NoteLinks.backlinks(to: note, in: folder) }.value
            guard !Task.isCancelled else { return }
            self?.list(found, empty: "No notes link here.")
        }
    }

    private func list(_ found: [Backlink], empty text: String) {
        links = found
        table.reloadData()
        empty.stringValue = text
        empty.isHidden = !found.isEmpty
    }

    @objc private func clicked() {
        guard links.indices.contains(table.clickedRow) else { return }
        let link = links[table.clickedRow]
        open(link.url, link.range)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        links.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: BacklinkCell.identifier, owner: nil) as? BacklinkCell ?? BacklinkCell()
        let link = links[row]
        let path = folder.map { link.url.path.dropFirst($0.path.count + 1) } ?? Substring(link.url.lastPathComponent)
        cell.show(name: (String(path) as NSString).deletingPathExtension, line: link.line, preview: link.preview)
        return cell
    }
}

/// A backlink's row: the note's path from the folder and the line number over the linking line.
private final class BacklinkCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("backlink")

    private let name = NSTextField(labelWithString: "")
    private let preview = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.font = Chrome.label
        preview.font = Chrome.small
        for label in [name, preview] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            name.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            preview.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            preview.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            preview.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
        themeDidChange()
    }

    required init?(coder: NSCoder) {
        fatalError("BacklinkCell is built in code")
    }

    @objc private func themeDidChange() {
        name.textColor = Chrome.color(.ink)
        preview.textColor = Chrome.color(.ink2)
    }

    func show(name: String, line: Int, preview: String) {
        self.name.stringValue = "\(name)  :\(line)"
        self.preview.stringValue = preview
        toolTip = preview
    }
}
