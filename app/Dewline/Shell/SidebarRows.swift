import AppKit
import MdCore

/// Git's word for a file in the tree: "modified" and "renamed" in `gitModified`, "new" in `gitAdded`, the rest in
/// `ink2`.
extension GitFileState {
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
        case .modified: "Modified since the last commit"
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

/// "tidepool main ⌄": the folder's name in 11 semibold, its branch in SF Mono 11, a chevron in `ink3`, on a 22 pt pill
/// that fills on hover. Text sits 6 pt in. In a window that isn't main, the text goes to `ink3`.
final class FolderPicker: NSView {
    var folderMenu: () -> NSMenu = { NSMenu() }
    private var name = ""
    private var branch: String?
    private var hovering = false {
        didSet { needsDisplay = true }
    }

    private static let nameFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let branchFont = Chrome.mono(11)

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for name in [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
            if let window { NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: name, object: window) }
        }
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
        let active = window?.isMainWindow ?? true
        let text = Chrome.color(active ? .ink2 : .ink3).resolved(for: appearance)
        var x: CGFloat = 6
        let nameSize = (name as NSString).size(withAttributes: [.font: Self.nameFont])
        (name as NSString).draw(at: NSPoint(x: x, y: (bounds.height - nameSize.height) / 2), withAttributes: [.font: Self.nameFont, .foregroundColor: text])
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
/// 10% (30% under Increase Contrast), one per enclosing folder. The selected row's pill carries the 2 x 12 cursor bar while its window is main.
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

    override func drawSelection(in dirtyRect: NSRect) {
        super.drawSelection(in: dirtyRect)
        guard isWindowActive else { return }
        Chrome.color(.cursor).resolved(for: effectiveAppearance).setFill()
        NSBezierPath(roundedRect: NSRect(x: pill.minX + 3, y: pill.midY - 6, width: 2, height: 12), xRadius: 1, yRadius: 1).fill()
    }
}

/// A file or folder row: a chevron for a folder under its guide, the name 22 pt in (pane edge + 30), the writer badge
/// right after it, and git's word alone on the trailing edge, at least 12 pt clear of the badge. A ".md" extension
/// shows in `ink3`. A name too long for the row keeps its head through the first word and whole words from its end.
final class SidebarFileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("file")

    private let chevron = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let badge = WaitingBadge()
    private let git = NSTextField(labelWithString: "")
    private var fullName = ""
    private var dimmed = false
    private var word: GitFileState?
    private var goneTip: String?
    private var editing = false

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.font = Chrome.label
        name.lineBreakMode = .byClipping
        name.maximumNumberOfLines = 1
        textField = name
        chevron.imageScaling = .scaleNone
        git.font = .systemFont(ofSize: 11, weight: .medium)
        for view in [chevron, name, badge, git] { addSubview(view) }
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("SidebarFileCell is built in code")
    }

    /// A file or folder; one that has `gone` from disk, one .gitignore hides, and any file Dewline doesn't edit show
    /// dimmed. `waiting` is empty for the open note, whose changes show beside its text.
    func show(_ entry: FolderEntry, gone: Bool, expanded: Bool, waiting: [WaitingCount], git word: GitFileState?) {
        fullName = entry.url.lastPathComponent
        dimmed = gone || entry.isIgnored || !(entry.isFolder || entry.isMarkdown || isAgentFile(entry.url))
        self.word = word
        chevron.isHidden = !entry.isFolder
        setExpanded(expanded)
        badge.show(waiting)
        git.stringValue = word?.word ?? ""
        git.toolTip = word?.tip
        git.isHidden = word == nil
        goneTip = gone ? "Moved or deleted" : nil
        setAccessibilityLabel(([fullName] + waiting.map(\.spoken) + (word.map { [$0.word] } ?? [])).joined(separator: ", "))
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

    @objc private func themeDidChange() {
        paint()
        needsLayout = true
    }

    private func paint() {
        chevron.contentTintColor = Chrome.color(.ink3)
        git.textColor = word.map { Chrome.color($0.token) }
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
        git.isHidden = word == nil || editing
        if editing {
            name.frame = NSRect(x: left - 2, y: (height - lineHeight) / 2, width: max(bounds.width - left + 2, 0), height: lineHeight)
            return
        }
        var right = bounds.width
        if !git.isHidden {
            let size = git.intrinsicContentSize
            git.frame = NSRect(x: right - size.width, y: (height - size.height) / 2, width: size.width, height: size.height)
            right = git.frame.minX - 12
        }
        let badgeWidth = badge.isHidden ? 0 : badge.intrinsicContentSize.width + 6
        let room = max(right - left - badgeWidth, 0)
        let font = Chrome.label
        let shown = truncatedName(fullName) { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) <= room }
        name.attributedStringValue = display(shown)
        let width = min(ceil((shown as NSString).size(withAttributes: [.font: font]).width), room)
        name.frame = NSRect(x: left - 2, y: (height - lineHeight) / 2, width: width + 4, height: lineHeight)
        toolTip = goneTip ?? (shown == fullName ? nil : fullName)
        if !badge.isHidden {
            badge.frame = NSRect(x: left + width + 6, y: (height - WaitingBadge.height) / 2, width: badge.intrinsicContentSize.width, height: WaitingBadge.height)
        }
    }

    /// The name in `ink` (`ink3` when dimmed), its ".md" in `ink3`.
    private func display(_ text: String) -> NSAttributedString {
        let ink = Chrome.color(dimmed ? .ink3 : .ink)
        let string = NSMutableAttributedString(string: text, attributes: [.font: Chrome.label, .foregroundColor: ink])
        if text.lowercased().hasSuffix(".md"), text.count > 3 {
            string.addAttribute(.foregroundColor, value: Chrome.color(.ink3), range: NSRange(location: (text as NSString).length - 3, length: 3))
        }
        return string
    }
}

/// The writer badge: a 16 pt capsule, radius 4, in the writer's ink at 14%, holding a 3 x 10 rule in that ink and the
/// count in SF Mono 11 medium `ink`. The count is every undecided change in the note; the ink is the writer with most.
/// Without a count (a note changed while closed, a closed folder holding changes) it is the rule alone, one per
/// writer.
final class WaitingBadge: NSView {
    static let height: CGFloat = 16
    private static let font = Chrome.mono(11, weight: .medium)
    private var waiting: [WaitingCount] = []

    var isEmpty: Bool { waiting.isEmpty }
    private var counted: Bool { waiting.allSatisfy { $0.count != nil } }
    private var count: String { "\(waiting.reduce(0) { $0 + ($1.count ?? 0) })" }

    func show(_ waiting: [WaitingCount]) {
        self.waiting = waiting
        toolTip = waiting.isEmpty ? nil : waiting.map(\.tip).joined(separator: "\n")
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        guard counted else { return NSSize(width: CGFloat(waiting.count) * 6 - 3, height: Self.height) }
        return NSSize(width: 4 + 3 + 4 + ceil((count as NSString).size(withAttributes: [.font: Self.font]).width) + 5, height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let first = waiting.first else { return }
        let appearance = effectiveAppearance
        guard counted else {
            for (index, writer) in waiting.enumerated() {
                writer.writer.color.resolved(for: appearance).setFill()
                NSBezierPath(roundedRect: NSRect(x: CGFloat(index) * 6, y: (bounds.height - 10) / 2, width: 3, height: 10), xRadius: 1, yRadius: 1).fill()
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

/// `name` cut to what `fits`: the head through its first word ("0003-fitter-"), an ellipsis, then as many whole words
/// from the end as fit, then the start of the next word when 3 letters or more of it fit. An extension stays, after a
/// thin space when no word does. A name with no word break keeps its start.
nonisolated func truncatedName(_ name: String, fits: (String) -> Bool) -> String {
    if fits(name) { return name }
    let ext = (name as NSString).pathExtension
    let suffix = ext.isEmpty ? "" : "." + ext
    let stem = String(name.dropLast(suffix.count))
    let breaks: Set<Character> = ["-", "_", " "]
    let head: String
    if let match = stem.firstMatch(of: /^(\d+[-_ ])?[^-_ ]+[-_ ]?/) {
        head = String(match.output.0)
    } else {
        head = String(stem.prefix(6))
    }
    var words: [String] = []
    for character in stem.dropFirst(head.count) {
        if words.isEmpty || breaks.contains(words[words.count - 1].last!) { words.append("") }
        words[words.count - 1].append(character)
    }
    func trimmed(_ text: String) -> String {
        breaks.contains(text.last ?? "x") ? String(text.dropLast()) : text
    }
    func make(_ start: String, _ tail: String) -> String {
        start + "\u{2026}" + (tail.isEmpty && !suffix.isEmpty ? "\u{2009}" : "") + tail + suffix
    }
    for kept in stride(from: words.count - 1, through: 0, by: -1) {
        let tail = words.suffix(kept).joined()
        let start = kept > 0 ? head : trimmed(head)
        guard fits(make(start, tail)) else { continue }
        if let next = words.first, next.count > 3 {
            for length in stride(from: next.count - 1, through: 3, by: -1) {
                let candidate = make(head + trimmed(String(next.prefix(length))), tail)
                if fits(candidate) { return candidate }
            }
        }
        return make(start, tail)
    }
    for length in stride(from: head.count - 1, to: 3, by: -1) {
        let candidate = make(String(head.prefix(length)), "")
        if fits(candidate) { return candidate }
    }
    return make(String(name.prefix(4)), "")
}
