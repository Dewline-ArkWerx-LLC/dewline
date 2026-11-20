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
/// while the pointer is over the sidebar and opens on mouse down.
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
        more.sendAction(on: .leftMouseDown)
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

/// "tidepool main ↑2 · 7 changed ⌄": the folder's name in body semibold `ink`, its branch and the commits it is ahead
/// of its upstream in SF Mono 12 `ink2`, how many files differ from the last commit in `ink2`, all on one baseline,
/// then a chevron in `ink3`, on a 22 pt pill that fills on hover. Text sits 6 pt in, in the same inks whether or not
/// the window is key. Under Full Keyboard Access it takes the focus, with the system's ring, and Space or Return opens it.
final class FolderPicker: NSView {
    var folderMenu: () -> NSMenu = { NSMenu() }
    private var name = ""
    private var branch: String?
    private var changed = 0
    private var ahead = 0
    private var hovering = false {
        didSet { needsDisplay = true }
    }

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

    func show(_ name: String, branch: String?, changed: Int, ahead: Int, openKey: String) {
        self.name = name
        self.branch = branch
        self.changed = changed
        self.ahead = ahead
        toolTip = openKey.isEmpty ? "Open Folder, Open Recent" : "Open Folder, Open Recent (\(openKey))"
        let state = (ahead > 0 ? ["\(ahead) \(ahead == 1 ? "commit" : "commits") ahead"] : [])
            + (changed > 0 ? ["\(changed) changed \(changed == 1 ? "file" : "files")"] : [])
        setAccessibilityLabel(([branch.map { "Folder \(name) on branch \($0)" } ?? "Folder \(name)"] + state).joined(separator: ", "))
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// The name, branch, lead and count as one line, so they share a baseline.
    private var text: NSAttributedString {
        let line = NSMutableParagraphStyle()
        line.lineBreakMode = .byTruncatingTail
        let ink2 = Chrome.color(.ink2)
        let text = NSMutableAttributedString(string: name, attributes: [.font: Chrome.labelStrong, .foregroundColor: Chrome.color(.ink)])
        let mono = [branch, ahead > 0 ? "\u{2191}\(ahead)" : nil].compactMap { $0 }
        if !mono.isEmpty {
            text.append(NSAttributedString(string: " " + mono.joined(separator: " "), attributes: [.font: Chrome.mono(12), .foregroundColor: ink2]))
        }
        if changed > 0 {
            text.append(NSAttributedString(string: " \u{00B7} \(changed) changed", attributes: [.font: Chrome.small, .foregroundColor: ink2]))
        }
        text.addAttribute(.paragraphStyle, value: line, range: NSRange(location: 0, length: text.length))
        return text
    }

    private var chevron: NSImage? {
        Chrome.symbol("chevron.down", Chrome.color(.ink3))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 6 + ceil(text.size().width) + 4 + (chevron?.size.width ?? 10) + 6, height: 22)
    }

    @objc private func redraw() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Chrome.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let text = text
        let chevron = chevron
        let room = max(bounds.width - 6 - 4 - (chevron?.size.width ?? 10) - 6, 0)
        let size = text.size()
        let width = min(ceil(size.width), room)
        text.draw(with: NSRect(x: 6, y: (bounds.height - ceil(size.height)) / 2, width: width, height: ceil(size.height)),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let chevron {
            chevron.draw(in: NSRect(x: 6 + width + 4, y: (bounds.height - chevron.size.height) / 2, width: chevron.size.width, height: chevron.size.height))
        }
    }

    override var acceptsFirstResponder: Bool { takesKeyboardFocus }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard pressesOnKey(event) else { return super.keyDown(with: event) }
        popUp()
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

/// A sidebar row: a 22 pt pill in its 24 pt pitch, at the rows' inset, and under it the indent guides: 1 pt, ink at
/// 10% (30% under Increase Contrast), one per enclosing folder.
final class SidebarRowView: StationRowView {
    var guides: [CGFloat] = [] {
        didSet { if guides != oldValue { needsDisplay = true } }
    }

    override var pill: NSRect { super.pill.insetBy(dx: 0, dy: 1) }

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
/// shows a dot there. A ".md" extension shows in `ink2`. A name too long for the row loses its middle. A file gone from
/// disk is struck through. On the focused list's selection everything is `paper`.
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
    private var gone = false
    private var expanded = false
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
        self.gone = gone
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
        self.expanded = expanded
        chevron.image = Chrome.symbol(expanded ? "chevron.down" : "chevron.right", Chrome.color(.ink3))
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            guard backgroundStyle != oldValue else { return }
            paint()
            needsLayout = true
        }
    }

    /// On the selection of a list that has the keyboard.
    private var onAccent: Bool {
        backgroundStyle == .emphasized
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
        setExpanded(expanded)
        git.textColor = Chrome.color(onAccent ? .paper : word?.token ?? .gitModified)
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
    /// chrome, the selection and the hover. All `paper` on the accent.
    private func display(_ text: String) -> NSAttributedString {
        let ink = onAccent ? Chrome.color(.paper) : dimmed ? Chrome.color(.ink2) : isCode ? CodeFile.ink : Chrome.color(.ink)
        let line = NSMutableParagraphStyle()
        line.lineBreakMode = .byTruncatingMiddle
        var attributes: [NSAttributedString.Key: Any] = [.font: Chrome.label, .foregroundColor: ink, .paragraphStyle: line]
        if gone { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let string = NSMutableAttributedString(string: text, attributes: attributes)
        if !onAccent, text.lowercased().hasSuffix(".md"), text.count > 3 {
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
