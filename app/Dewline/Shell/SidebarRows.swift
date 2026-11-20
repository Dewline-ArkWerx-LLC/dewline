import AppKit
import MdCore

/// Git's state of a file in the tree: a letter on the row ("M" and "R" in `gitModified`, "A" in `gitAdded`, the rest in
/// `ink2`), the word for VoiceOver.
extension GitFileState {
    var letter: String {
        switch self {
        case .modified: "M"
        case .new: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .conflicted: "U"
        }
    }

    var word: String {
        switch self {
        case .modified: "modified"
        case .new: "new"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .conflicted: "conflicted"
        }
    }

    var tip: String {
        switch self {
        case .modified: "Modified since the last commit. Click to review the changes."
        case .new: "New, not yet committed"
        case .deleted: "Deleted since the last commit"
        case .renamed: "Renamed since the last commit"
        case .conflicted: "In conflict"
        }
    }

    var token: Token {
        switch self {
        case .modified, .renamed: .gitModified
        case .new: .gitAdded
        case .deleted, .conflicted: .ink2
        }
    }
}

/// One writer's undecided changes in a note. The count is nil for a note changed while closed, whose changes are
/// counted when it opens, and for a closed folder's roll-up.
struct WaitingCount {
    let writer: MarkWriter
    let count: Int?

    /// "Codex: 2 changes waiting", "Codex: changes waiting".
    var tip: String {
        guard let count else { return "\(writer.name): changes waiting" }
        return "\(writer.name): \(count) \(count == 1 ? "change" : "changes") waiting"
    }

    /// "2 Codex changes waiting".
    var spoken: String {
        guard let count else { return "\(writer.name) changes waiting" }
        return "\(count) \(writer.name) \(count == 1 ? "change" : "changes") waiting"
    }
}

/// The sidebar's header: the folder pop-up "tidepool main ⌄" from x 6, and "…" at the trailing edge, which shows
/// while the pointer is over the sidebar.
final class SidebarHeader: NSView {
    static let height: CGFloat = 32

    let picker = FolderPicker()
    private let more = NSButton()
    var actions: () -> NSMenu = { NSMenu() }

    var showsActions = false {
        didSet { more.isHidden = !showsActions }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Folder actions")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        more.image = image
        more.imagePosition = .imageOnly
        more.isBordered = false
        more.target = self
        more.action = #selector(showActions)
        more.toolTip = "Folder actions"
        more.setAccessibilityLabel("Folder actions")
        more.isHidden = true
        for view in [picker, more] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            picker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            picker.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            picker.trailingAnchor.constraint(lessThanOrEqualTo: more.leadingAnchor, constant: -4),
            more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            more.centerYAnchor.constraint(equalTo: picker.centerYAnchor),
            more.widthAnchor.constraint(equalToConstant: 24),
            more.heightAnchor.constraint(equalToConstant: 22),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
        themeDidChange()
    }

    required init?(coder: NSCoder) {
        fatalError("SidebarHeader is built in code")
    }

    @objc private func showActions() {
        actions().popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY + 4), in: more)
    }

    @objc private func themeDidChange() {
        more.contentTintColor = Chrome.color(.ink2)
    }
}

/// "tidepool main ⌄": the folder's name in 13 semibold `ink`, its branch in SF Mono 12 `ink2`, a chevron in `ink3`, on a
/// 22 pt pill that fills on hover. Text sits 6 pt in, in the same inks whether or not the window is key.
final class FolderPicker: NSView {
    var folderMenu: () -> NSMenu = { NSMenu() }
    private var name = ""
    private var branch: String?
    private var hovering = false {
        didSet { needsDisplay = true }
    }

    private static let nameFont = Chrome.labelStrong
    private static let branchFont = Chrome.mono(12)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("FolderPicker is built in code")
    }

    override var isFlipped: Bool { true }

    func show(_ name: String, branch: String?, openKey: String) {
        self.name = name
        self.branch = branch
        toolTip = openKey.isEmpty ? "Open Folder, Open Recent" : "Open Folder, Open Recent (\(openKey))"
        setAccessibilityLabel(branch.map { "Folder \(name) on branch \($0)" } ?? "Folder \(name)")
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private var nameWidth: CGFloat { ceil((name as NSString).size(withAttributes: [.font: Self.nameFont]).width) }
    private var branchWidth: CGFloat {
        branch.map { ceil(($0 as NSString).size(withAttributes: [.font: Self.branchFont]).width) + 6 } ?? 0
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 6 + nameWidth + branchWidth + 4 + 10 + 6, height: 22)
    }

    @objc private func redraw() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let appearance = effectiveAppearance
        if hovering {
            Chrome.hover.resolved(for: appearance).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let text = Chrome.color(.ink2).resolved(for: appearance)
        var x: CGFloat = 6
        let nameSize = (name as NSString).size(withAttributes: [.font: Self.nameFont])
        (name as NSString).draw(at: NSPoint(x: x, y: (bounds.height - nameSize.height) / 2),
            withAttributes: [.font: Self.nameFont, .foregroundColor: Chrome.color(.ink).resolved(for: appearance)])
        x += nameWidth
        if let branch {
            let size = (branch as NSString).size(withAttributes: [.font: Self.branchFont])
            (branch as NSString).draw(at: NSPoint(x: x + 6, y: (bounds.height - size.height) / 2), withAttributes: [.font: Self.branchFont, .foregroundColor: text])
            x += branchWidth
        }
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: x + 4 + 2, y: bounds.midY - 1.5))
        chevron.line(to: NSPoint(x: x + 4 + 5, y: bounds.midY + 1.5))
        chevron.line(to: NSPoint(x: x + 4 + 8, y: bounds.midY - 1.5))
        chevron.lineWidth = 1.25
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        Chrome.color(.ink3).resolved(for: appearance).setStroke()
        chevron.stroke()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }

    override func mouseDown(with event: NSEvent) {
        popUp()
    }

    override func accessibilityPerformPress() -> Bool {
        popUp()
        return true
    }

    private func popUp() {
        folderMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
        hovering = false
    }
}

/// A sidebar row: a 22 pt pill in its 24 pt pitch, 8 pt in from each side, and under it the indent guides: 1 pt, ink at
/// 10% (30% under Increase Contrast), one per enclosing folder.
final class SidebarRowView: StationRowView {
    var guides: [CGFloat] = [] {
        didSet { if guides != oldValue { needsDisplay = true } }
    }

    override var pill: NSRect { bounds.insetBy(dx: 8, dy: 1) }

    override func drawBackground(in dirtyRect: NSRect) {
        guard !isSelected, !guides.isEmpty else { return }
        Chrome.color(.ink).resolved(for: effectiveAppearance).withAlphaComponent(effectiveAppearance.isHighContrast ? 0.30 : 0.10).setFill()
        for x in guides {
            NSRect(x: x, y: bounds.minY, width: 1, height: bounds.height).fill()
        }
    }
}

/// A file or folder row: a chevron for a folder under its guide, the name 22 pt in (pane edge + 30), and on the trailing
/// edge the writer badge, then git's letter in SF Mono 11 in a 14 pt column; a closed folder holding changed files
/// shows a dot there. A ".md" extension shows in `ink2`. A name too long for the row loses its middle.
final class SidebarFileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("file")

    private let chevron = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let badge = WaitingBadge()
    private let git = NSTextField(labelWithString: "")
    private var fullName = ""
    private var dimmed = false
    /// A code file that opens, a little dimmer than a note.
    private var isCode = false
    private var word: GitFileState?
    private var holdsChanges = false
    private var goneTip: String?
    private var editing = false

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.font = Chrome.label
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        textField = name
        chevron.imageScaling = .scaleNone
        git.font = Chrome.mono(11)
        git.alignment = .center
        for view in [chevron, name, badge, git] { addSubview(view) }
        let click = NSClickGestureRecognizer(target: self, action: #selector(reviewUncommitted))
        click.delaysPrimaryMouseButtonEvents = false
        git.addGestureRecognizer(click)
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("SidebarFileCell is built in code")
    }

    /// A file or folder; one that has `gone` from disk, one .gitignore hides, and any file Dewline doesn't edit show
    /// dimmed. `holdsChanges` marks a closed folder with changed files under it.
    func show(_ entry: FolderEntry, gone: Bool, expanded: Bool, waiting: [WaitingCount], git word: GitFileState?, holdsChanges: Bool = false) {
        fullName = entry.url.lastPathComponent
        dimmed = gone || entry.isIgnored || !(entry.isFolder || entry.opens || isAgentFile(entry.url))
        isCode = entry.isCode
        self.word = word
        self.holdsChanges = word == nil && holdsChanges
        chevron.isHidden = !entry.isFolder
        setExpanded(expanded)
        badge.show(waiting, dots: entry.isFolder)
        git.stringValue = word?.letter ?? (self.holdsChanges ? "\u{2022}" : "")
        git.toolTip = word?.tip ?? (self.holdsChanges ? "Holds files changed since the last commit" : nil)
        git.isHidden = git.stringValue.isEmpty
        goneTip = gone ? "Moved or deleted" : nil
        let state = word.map { [$0.word] } ?? (self.holdsChanges ? ["changed files inside"] : [])
        setAccessibilityLabel(([fullName] + waiting.map(\.spoken) + state).joined(separator: ", "))
        paint()
        needsLayout = true
    }

    func setExpanded(_ expanded: Bool) {
        chevron.image = (expanded ? Glyph.disclosed : Glyph.disclosure).image
    }

    /// The whole name, plain, across the row while it is edited.
    func beginEditing() {
        editing = true
        name.stringValue = fullName
        name.textColor = Chrome.color(.ink)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func endEditing() {
        editing = false
        needsLayout = true
    }

    /// Clicking "M" opens the note, as clicking the row does, and the Changes pane, which lists its uncommitted changes.
    @objc private func reviewUncommitted() {
        guard word == .modified, let controller = window?.windowController as? MainWindowController, !controller.showsChanges else { return }
        controller.toggleChanges(nil)
    }

    @objc private func themeDidChange() {
        paint()
        needsLayout = true
    }

    private func paint() {
        chevron.contentTintColor = Chrome.color(.ink3)
        git.textColor = Chrome.color(word?.token ?? .gitModified)
        badge.needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        chevron.frame = NSRect(x: 0, y: (height - 12) / 2, width: 12, height: 12)
        let left: CGFloat = 22
        let lineHeight = ceil(Chrome.label.ascender - Chrome.label.descender + Chrome.label.leading) + 1
        badge.isHidden = badge.isEmpty || editing
        git.isHidden = git.stringValue.isEmpty || editing
        if editing {
            name.frame = NSRect(x: left - 2, y: (height - lineHeight) / 2, width: max(bounds.width - left + 2, 0), height: lineHeight)
            return
        }
        var right = bounds.width
        if !git.isHidden {
            let size = git.intrinsicContentSize
            git.frame = NSRect(x: right - 14, y: (height - size.height) / 2, width: 14, height: size.height)
            right = git.frame.minX - 6
        }
        if !badge.isHidden {
            let width = badge.intrinsicContentSize.width
            badge.frame = NSRect(x: right - width, y: (height - WaitingBadge.height) / 2, width: width, height: WaitingBadge.height)
            right = badge.frame.minX - 6
        }
        let room = max(right - left, 0)
        let full = ceil((fullName as NSString).size(withAttributes: [.font: Chrome.label]).width)
        name.attributedStringValue = display(fullName)
        let width = min(full, room)
        name.frame = NSRect(x: left - 2, y: (height - lineHeight) / 2, width: width + 4, height: lineHeight)
        toolTip = goneTip ?? (full <= room ? nil : fullName)
    }

    /// The name in `ink` (`ink2` when dimmed, `CodeFile.ink` for code), its ".md" in `ink2`: 4.5:1 or more on the
    /// chrome, the selection and the hover.
    private func display(_ text: String) -> NSAttributedString {
        let ink = dimmed ? Chrome.color(.ink2) : isCode ? CodeFile.ink : Chrome.color(.ink)
        let line = NSMutableParagraphStyle()
        line.lineBreakMode = .byTruncatingMiddle
        let string = NSMutableAttributedString(string: text, attributes: [.font: Chrome.label, .foregroundColor: ink, .paragraphStyle: line])
        if text.lowercased().hasSuffix(".md"), text.count > 3 {
            string.addAttribute(.foregroundColor, value: Chrome.color(.ink2), range: NSRange(location: (text as NSString).length - 3, length: 3))
        }
        return string
    }
}

/// The writer badge: a 16 pt capsule, radius 4, in the writer's ink at 14%, holding a 3 x 10 rule in that ink and the
/// count in SF Mono 11 medium `ink`. The count is every undecided change in the note; the ink is the writer with most.
/// Without a count it is the rule alone for a note changed while closed, and a 6 pt dot for a closed folder holding
/// changes, one per writer.
final class WaitingBadge: NSView {
    static let height: CGFloat = 16
    private static let font = Chrome.mono(11, weight: .medium)
    private var waiting: [WaitingCount] = []
    private var dots = false

    var isEmpty: Bool { waiting.isEmpty }
    private var counted: Bool { waiting.allSatisfy { $0.count != nil } }
    private var count: String { "\(waiting.reduce(0) { $0 + ($1.count ?? 0) })" }

    func show(_ waiting: [WaitingCount], dots: Bool = false) {
        self.waiting = waiting
        self.dots = dots
        toolTip = waiting.isEmpty ? nil : waiting.map(\.tip).joined(separator: "\n")
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        guard counted else { return NSSize(width: CGFloat(waiting.count) * (dots ? 9 : 6) - 3, height: Self.height) }
        return NSSize(width: 4 + 3 + 4 + ceil((count as NSString).size(withAttributes: [.font: Self.font]).width) + 5, height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let first = waiting.first else { return }
        let appearance = effectiveAppearance
        guard counted else {
            for (index, writer) in waiting.enumerated() {
                writer.writer.color.resolved(for: appearance).setFill()
                if dots {
                    NSBezierPath(ovalIn: NSRect(x: CGFloat(index) * 9, y: (bounds.height - 6) / 2, width: 6, height: 6)).fill()
                } else {
                    NSBezierPath(roundedRect: NSRect(x: CGFloat(index) * 6, y: (bounds.height - 10) / 2, width: 3, height: 10), xRadius: 1, yRadius: 1).fill()
                }
            }
            return
        }
        let ink = first.writer.color.resolved(for: appearance)
        ink.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        ink.setFill()
        NSBezierPath(roundedRect: NSRect(x: 4, y: (bounds.height - 10) / 2, width: 3, height: 10), xRadius: 1, yRadius: 1).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: Chrome.color(.ink).resolved(for: appearance)]
        let size = (count as NSString).size(withAttributes: attributes)
        (count as NSString).draw(at: NSPoint(x: 11, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}
