import AppKit
import MdCore

/// A view that hangs under a paragraph in space the styler reserves for it.
@MainActor
protocol Hanging: NSView {
    func height(for width: CGFloat) -> CGFloat
}

@MainActor
private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: Token) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = Chrome.brand(size, weight: weight == .semibold ? 600 : 450)
    label.textColor = ThemeStore.shared.color(color)
    return label
}

/// A button that calls `action` when clicked: the prominent one filled with the theme's accent and set in paper, the
/// others bare text in `ink2`.
@MainActor
private final class ActionButton: NSButton {
    private var handler: () -> Void = {}
    private var prominent = false

    convenience init(_ title: String, prominent: Bool = false, shortcut: String? = nil, label: String, _ action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.prominent = prominent
        handler = action
        target = self
        self.action = #selector(clicked)
        isBordered = false
        wantsLayer = true
        toolTip = shortcut.map { "\(title) (\($0))" }
        setAccessibilityLabel(label)
        paint()
        NotificationCenter.default.addObserver(self, selector: #selector(paint), name: ThemeStore.didChange, object: ThemeStore.shared)
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + (prominent ? 24 : 8), height: 24)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.backgroundColor = prominent ? ThemeStore.shared.color(.accent).resolved(for: effectiveAppearance).cgColor : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    @objc private func paint() {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: prominent ? .medium : .regular),
            .foregroundColor: ThemeStore.shared.color(prominent ? .paper : .ink2),
        ])
        needsDisplay = true
    }

    @objc private func clicked() {
        handler()
    }
}

/// Removed text, struck, at ink 42% with the strike in the writer's color. A short removal on one line reads inline
/// at its deletion point, in a gap the styler opens there; a longer one hangs under its paragraph.
@MainActor
final class Ghost: NSView, Hanging {
    private let string: NSAttributedString
    private let text: NSTextField?
    /// The gap an inline ghost takes in its line, its text and a space; nil for a ghost that hangs.
    let inlineWidth: CGFloat?
    /// From an inline ghost's top to its baseline.
    let ascent: CGFloat

    /// A ghost no wider than `limit` reads inline.
    init(_ removed: String, writer: MarkWriter, inlineUpTo limit: CGFloat) {
        let shown = removed.hasSuffix("\n") ? String(removed.dropLast()) : removed
        let font = ThemeStore.shared.bodyFont
        string = NSAttributedString(string: shown, attributes: [
            .font: font,
            .foregroundColor: ThemeStore.shared.color(.ink).withAlphaComponent(0.42),
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: writer.color,
        ])
        let width = ceil(string.size().width)
        let inline = !shown.isEmpty && !shown.contains(where: \.isNewline) && width <= limit
        inlineWidth = inline ? width + ceil(NSAttributedString(string: " ", attributes: [.font: font]).size().width) : nil
        ascent = ceil(font.ascender)
        text = inline ? nil : NSTextField(wrappingLabelWithString: "")
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: ceil(font.ascender - font.descender)))
        let label = "Removed by \(writer.name): \(shown)"
        if let text {
            text.attributedStringValue = string
            text.isSelectable = false
            text.setAccessibilityLabel(label)
            addSubview(text)
        } else {
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(label)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("Ghost is built in code")
    }

    override var isFlipped: Bool { true }

    func height(for width: CGFloat) -> CGFloat {
        guard let text else { return frame.height }
        text.preferredMaxLayoutWidth = width
        return ceil(text.fittingSize.height)
    }

    override func layout() {
        super.layout()
        text?.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        if text == nil { string.draw(at: .zero) }
    }
}

/// "Two versions of this paragraph": your text stays editable above it; the other version shows here under "From
/// git" or "From another app", with Keep Yours (the default, ⌥⌘⌫), Use git’s (⌘↩) and Keep Both.
@MainActor
final class ConflictCard: NSView, Hanging {
    private let stack = NSStackView()
    private let theirs: NSTextField
    private static let padding: CGFloat = 12
    let keepYours: NSButton
    let useTheirs: NSButton
    let keepBoth: NSButton

    init(_ writer: MarkWriter, theirs text: String, decide: @escaping (ChangeEngine.Decision) -> Void) {
        let shown = text.hasSuffix("\n") ? String(text.dropLast()) : text
        theirs = NSTextField(wrappingLabelWithString: shown)
        theirs.font = ThemeStore.shared.bodyFont
        theirs.textColor = ThemeStore.shared.color(.ink2)
        theirs.isSelectable = true
        theirs.setAccessibilityLabel("\(writer.name)'s version: \(shown)")
        keepYours = ActionButton("Keep Yours", prominent: true, shortcut: "\u{2325}\u{2318}\u{232B}", label: "Keep your version") { decide(.keep) }
        useTheirs = ActionButton(Self.useTheirs(writer), shortcut: "\u{2318}\u{21A9}", label: Self.useTheirs(writer)) { decide(.other) }
        keepBoth = ActionButton("Keep Both", label: "Keep both versions") { decide(.both) }
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Two versions of this paragraph")

        let title = label("Two versions of this paragraph", size: 13, weight: .semibold, color: .ink)
        let stamp = label(Self.from(writer), size: 13, color: .ink2)
        let buttons = NSStackView(views: [keepYours, useTheirs, keepBoth])
        buttons.spacing = 8
        let waits = label("Saving waits until you choose.", size: 11, color: .ink2)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for view in [title, stamp, theirs, buttons, waits] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(10, after: theirs)
        stack.edgeInsets = NSEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("ConflictCard is built in code")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// A 1 pt rule around paper, no shadow.
    override func updateLayer() {
        guard let layer else { return }
        let store = ThemeStore.shared
        layer.backgroundColor = store.color(.paper).resolved(for: effectiveAppearance).cgColor
        layer.borderColor = store.color(.ink).resolved(for: effectiveAppearance).withAlphaComponent(effectiveAppearance.isDark ? 0.16 : 0.10).cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 8
    }

    /// "From git", "From another app", "From Claude".
    static func from(_ writer: MarkWriter) -> String {
        writer.dashed ? "From another app" : "From \(writer.name)"
    }

    /// "Use git\u{2019}s", "Use the other version".
    static func useTheirs(_ writer: MarkWriter) -> String {
        writer.dashed ? "Use the other version" : "Use \(writer.name)\u{2019}s"
    }

    /// The other version's text, as the card shows it.
    var otherVersion: String {
        theirs.stringValue
    }

    func height(for width: CGFloat) -> CGFloat {
        theirs.preferredMaxLayoutWidth = width - 2 * Self.padding
        return ceil(stack.fittingSize.height)
    }
}

/// The focused change's stamp. In the margin, "CLAUDE 3:25 PM · 3 of 4" sits on the change's first text baseline
/// and Revert and Keep on its second, the stamp's right edge 26 pt left of the text column; a narrower margin takes
/// the compact stamp, "CLAUDE · 3 of 4" over Revert and Keep in 11 pt text. Only where the margin is narrower than the
/// compact stamp plus that 26 pt and a 24 pt gutter does it fold into a 30 pt bar under the block holding the change,
/// on the writer's ink at 8%: writer, time and count on the left, Revert and Keep on the right. Revert and Keep share
/// one width. Keep and Revert show on the stamp of the change at the caret and on a stamp under the pointer. No cursor
/// bar: no dark orange reaches 3:1 on Keep's cream fill, and in the gap it read as a separator.
@MainActor
final class ChangeStamp: NSView {
    static let barHeight: CGFloat = 30
    /// From the stamp's right edge to the text column, and the least margin left of the stamp.
    static let inset: CGFloat = 26
    static let gutter: CGFloat = 24
    /// Between Revert and Keep.
    private static let gap: CGFloat = 10
    /// What an unnamed change that landed while Claude Code ran a shell command says (X2).
    static let duringShell = "During Claude Code\u{2019}s shell command"
    /// What a change says once Revert finds text typed inside it; Revert then asks before it puts the old text back.
    static let typedInside = "You edited inside it"
    /// Whether a change was ever kept or reverted, after which the stamp shows Next Change's keys.
    private static var decided: Bool {
        get { UserDefaults.standard.bool(forKey: "DecidedAChange") }
        set { if newValue != decided { UserDefaults.standard.set(newValue, forKey: "DecidedAChange") } }
    }

    private let revert: StampButton
    private let keep: StampButton
    private let setUp: StampButton
    private let note = NSTextField(labelWithString: duringShell)
    private var writer: MarkWriter?
    private var time = ""
    /// The stamped change's place among the window's waiting changes, in the order Next Change walks them.
    private var index = 0
    private var total = 0
    private var external = false
    private var shell = false
    private(set) var folded = false
    /// Whether Keep and Revert show without the pointer on the stamp.
    var active = true {
        didSet { showButtons() }
    }
    private var hovering = false {
        didSet { showButtons() }
    }
    private var flags: Any?
    /// Line 1's baseline and left edge, in this view.
    private var baseline: CGFloat = 0
    private var textX: CGFloat = 0
    /// The size changed: the marks lay out again.
    var resized: () -> Void = {}
    /// The first stamp in a session to show another app's change, while an installed agent lacks hooks, offers hook setup.
    private var offering = false
    private static var offeredHooks = false
    private static var checkingHooks = false

    init(revert: @escaping () -> Void, keep: @escaping () -> Void) {
        self.revert = StampButton(
            "Revert", keys: "\u{2325}\u{2318}\u{232B}", style: .outlined, symbol: "arrow.uturn.backward",
            alternate: ("Revert All", "\u{2325}\u{21E7}\u{2318}\u{232B}", #selector(EditorTextView.revertAllChanges(_:))), revert)
        self.keep = StampButton(
            "Keep", keys: "\u{2318}\u{21A9}", style: .filled, symbol: "checkmark",
            alternate: ("Keep All", "\u{21E7}\u{2318}\u{21A9}", #selector(EditorTextView.keepAllChanges(_:))), keep)
        setUp = StampButton("Set up agent hooks\u{2026}", keys: "", style: .link) {
            NSApp.sendAction(#selector(AppDelegate.setUpHooks(_:)), to: nil, from: nil)
        }
        super.init(frame: .zero)
        self.revert.handler = {
            Self.decided = true
            revert()
        }
        self.keep.handler = {
            Self.decided = true
            keep()
        }
        self.revert.toolTip = "Puts the old text back. Revert (\u{2325}\u{2318}\u{232B}). Option-click: Revert All (\u{2325}\u{21E7}\u{2318}\u{232B})"
        self.keep.toolTip = "Already saved; Keep clears the mark. Keep (\u{2318}\u{21A9}). Option-click: Keep All (\u{21E7}\u{2318}\u{21A9})"
        setUp.toolTip = "Name this writer: set up agent hooks"
        setUp.isHidden = true
        note.font = .systemFont(ofSize: 11)
        note.textColor = ThemeStore.shared.color(.ink2)
        note.lineBreakMode = .byTruncatingTail
        note.isHidden = true
        for view in [self.revert, self.keep, setUp, note] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: ThemeStore.shared)
        NotificationCenter.default.addObserver(self, selector: #selector(revertRefused(_:)), name: LiveFile.revertRefused, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ChangeStamp is built in code")
    }

    private func showButtons() {
        revert.isHidden = !(active || hovering)
        keep.isHidden = revert.isHidden
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }

    override func accessibilityChildren() -> [Any]? {
        [revert, keep, setUp].filter { !$0.isHidden }
    }

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    /// While the stamp is in a window, holding Option retitles Keep and Revert to Keep All and Revert All.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let flags { NSEvent.removeMonitor(flags) }
        flags = nil
        setOption(false)
        guard window != nil else { return }
        flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.setOption(event.modifierFlags.contains(.option)) }
            return event
        }
    }

    func setOption(_ down: Bool) {
        keep.optionDown = down
        revert.optionDown = down
    }

    @objc private func themeDidChange() {
        note.textColor = ThemeStore.shared.color(.ink2)
        for view in [self, revert, keep, setUp] { view.needsDisplay = true }
        resized()
    }

    /// Shows `writer`'s change that landed at `time`, `index` of the window's `total` waiting changes, during Claude
    /// Code's shell command when `shell`, and why Revert left one when `refused`; Keep and Revert decide it, "Keep 3 of 4"
    /// when the window has more.
    func show(_ writer: MarkWriter, at time: Date, index: Int, of total: Int, external: Bool, shell: Bool, refused: Bool) {
        let time = time.formatted(date: .omitted, time: .shortened)
        let changed = writer != self.writer || time != self.time || index != self.index || total != self.total
        if writer == self.writer, total < self.total { Self.decided = true }
        self.writer = writer
        self.time = time
        self.index = index
        self.total = total
        self.external = external
        self.shell = shell
        note.stringValue = refused ? Self.typedInside : Self.duringShell
        note.isHidden = !(shell || refused)
        setAccessibilityLabel("\(writer.name), \(time), saved, \(index) of \(total)" + (note.isHidden ? "" : ", \(note.stringValue)"))
        let of = total == 1 ? "" : ", \(index) of \(total)"
        revert.setAccessibilityLabel("Revert \(writer.possessive) change" + of)
        keep.setAccessibilityLabel("Keep \(writer.possessive) change" + of)
        // Set Up names no shell command's change, so a change during one doesn't offer it.
        setUp.isHidden = !(offering && external && !shell)
        if changed { needsDisplay = true }
        if external && !shell { offerHooks() }
    }

    /// Every Revert that finds your typing inside a change in this stamp's note asks, once however many stamps the note
    /// shows, after the revert's other changes are decided.
    @objc private func revertRefused(_ notification: Notification) {
        guard let textView = superview as? EditorTextView, textView.marks.live === notification.object as? LiveFile else { return }
        Task { [weak self] in self?.confirmRevert() }
    }

    /// Revert found your typing inside the change: asks, showing what reverting does to its lines, then puts the old
    /// text back over it as one undoable edit.
    private func confirmRevert() {
        guard let textView = superview as? EditorTextView, let window = textView.window, window.attachedSheet == nil,
            let live = textView.marks.live else { return }
        let refused = live.changes.filter { $0.value.refused && $0.value.marked }.sorted { $0.value.range.location > $1.value.range.location }
        guard let first = refused.last?.value.range, let last = refused.first?.value.range else { return }
        let text = textView.string as NSString
        let lines = text.lineRange(for: NSRange(location: first.location, length: NSMaxRange(last) - first.location))
        let reverted = NSMutableString(string: text.substring(with: lines))
        for (_, change) in refused {
            reverted.replaceCharacters(in: NSRange(location: change.range.location - lines.location, length: change.range.length), with: change.removed)
        }
        let alert = NSAlert()
        alert.messageText = "Revert over your typing?"
        alert.informativeText = "You edited inside this change. Reverting puts the old text back and drops what you typed there:"
        alert.accessoryView = readOnlyText(EarlierVersions.difference(from: text.substring(with: lines), to: reverted as String))
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Self.decided = true
            textView.history.perform("Revert Change") {
                for (id, change) in refused where live.changes[id] != nil {
                    live.keep(id)
                    textView.replaceAsOneEdit(change.range, with: change.removed)
                }
            }
        }
    }

    private func offerHooks() {
        guard !Self.offeredHooks, !Self.checkingHooks, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Self.checkingHooks = true
        Task { [weak self] in
            let report = await HookSetup.run(HookSetup.command(), ["doctor"], answers: 0)
            Self.checkingHooks = false
            guard report.ran, !HookSetup.missing(in: report.output).isEmpty else { return Self.offeredHooks = true }
            guard let self, self.external, !self.shell, self.superview != nil else { return }
            Self.offeredHooks = true
            self.offering = true
            self.setUp.isHidden = false
            self.resized()
        }
    }

    /// "CLAUDE 3:25 PM · 3 of 4 ⌃⌘↓": the writer in small capitals in its ink, the time with fixed-width digits, the
    /// change's place in the window and, once a change was decided, Next Change's keys; "CLAUDE · 3 of 4" in the compact
    /// stamp.
    private var line: NSAttributedString {
        line(compact: keep.form != .full && !folded)
    }

    private func line(compact: Bool) -> NSAttributedString {
        guard let writer else { return NSAttributedString() }
        let ink2 = ThemeStore.shared.color(.ink2)
        let line = NSMutableAttributedString(attributedString: writer.stamp)
        // The bar's 8% wash takes Claude's light ink to 4.1:1; a quarter of the way to ink keeps every writer over 4.5:1.
        if folded, let name = OKLCH(writer.color.resolved(for: effectiveAppearance)),
            let ink = OKLCH(ThemeStore.shared.color(.ink).resolved(for: effectiveAppearance)) {
            line.addAttribute(.foregroundColor, value: name.mixed(with: ink, by: 0.25).color, range: NSRange(location: 0, length: line.length))
        }
        if !compact {
            line.append(NSAttributedString(string: "  " + time, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: ink2]))
        }
        line.append(NSAttributedString(string: " \u{00B7} \(index) of \(total)", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: ink2]))
        if !compact && Self.decided {
            line.append(NSAttributedString(string: "  \u{2303}\u{2318}\u{2193}", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: ink2]))
        }
        return line
    }

    private var ascent: CGFloat {
        ceil(max(MarkWriter.stampFont.ascender, NSFont.systemFont(ofSize: 11).ascender))
    }

    private func buttonsWidth(_ form: StampButton.Form) -> CGFloat {
        2 * buttonWidth(form) + Self.gap
    }

    /// Revert's and Keep's one width.
    private func buttonWidth(_ form: StampButton.Form) -> CGFloat {
        max(revert.width(form), keep.width(form))
    }

    /// The width the compact stamp takes in the margin: the least margin that holds it.
    var marginWidth: CGFloat {
        width(compact: true)
    }

    private func width(compact: Bool) -> CGFloat {
        ceil(max(
            line(compact: compact).size().width, buttonsWidth(compact ? .short : .full), setUp.isHidden ? 0 : setUp.intrinsicContentSize.width,
            note.isHidden ? 0 : note.intrinsicContentSize.width))
    }

    /// Where their full titles don't fit, Keep and Revert take short ones in the margin and icons in the folded bar.
    private func setCompact(_ compact: Bool) {
        keep.form = compact ? (folded ? .icon : .short) : .full
        revert.form = keep.form
    }

    /// In the margin, its right edge at `right`: line 1 on `first`, the buttons' labels on `second`, both baselines
    /// in the superview.
    func placeInMargin(right: CGFloat, first: CGFloat, second: CGFloat) {
        folded = false
        setCompact(width(compact: false) > right - Self.gutter)
        let width = width(compact: keep.form != .full)
        let top = first - ascent
        baseline = ascent
        textX = width - ceil(line.size().width)
        // The buttons clear line 1's descent even when the second baseline sits close under the first.
        let buttons = max(second - StampButton.labelBaseline, first + 4) - top
        let buttonWidth = buttonWidth(keep.form)
        keep.frame = NSRect(x: width - buttonWidth, y: buttons, width: buttonWidth, height: StampButton.height)
        revert.frame = NSRect(x: keep.frame.minX - Self.gap - buttonWidth, y: buttons, width: buttonWidth, height: StampButton.height)
        var bottom = keep.frame.maxY
        if !note.isHidden {
            let size = note.intrinsicContentSize
            note.frame = NSRect(x: width - ceil(size.width), y: bottom + 4, width: ceil(size.width), height: size.height)
            bottom = note.frame.maxY
        }
        if !setUp.isHidden {
            let size = setUp.intrinsicContentSize
            setUp.frame = NSRect(x: width - size.width, y: bottom + 4, width: size.width, height: size.height)
            bottom = setUp.frame.maxY
        }
        frame = NSRect(x: right - width, y: top, width: width, height: bottom)
        needsDisplay = true
    }

    /// Folded into a bar filling `rect`.
    func placeAsBar(_ rect: NSRect) {
        folded = true
        frame = rect
        baseline = ((Self.barHeight + NSFont.systemFont(ofSize: 11).capHeight) / 2).rounded()
        textX = 10
        let y = (Self.barHeight - StampButton.height) / 2
        let noted = note.isHidden ? 0 : ceil(note.intrinsicContentSize.width) + 8
        setCompact(textX + ceil(line.size().width) + 8 + noted + buttonsWidth(.full) + y > rect.width)
        let buttonWidth = buttonWidth(keep.form)
        keep.frame = NSRect(x: rect.width - y - buttonWidth, y: y, width: buttonWidth, height: StampButton.height)
        revert.frame = NSRect(x: keep.frame.minX - Self.gap - buttonWidth, y: y, width: buttonWidth, height: StampButton.height)
        if !note.isHidden {
            let size = note.intrinsicContentSize
            let x = textX + ceil(line.size().width) + 8
            note.frame = NSRect(x: x, y: (Self.barHeight - size.height) / 2, width: max(min(ceil(size.width), revert.frame.minX - 8 - x), 0), height: size.height)
        }
        if !setUp.isHidden {
            let size = setUp.intrinsicContentSize
            setUp.frame = NSRect(x: textX + ceil(line.size().width) + 8, y: (Self.barHeight - size.height) / 2, width: size.width, height: size.height)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let writer else { return }
        if folded {
            writer.color.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        line.draw(at: NSPoint(x: textX, y: baseline - ascent))
    }
}

/// `text` in a selectable, read-only scroll view 480 x 240, for an alert.
@MainActor
func readOnlyText(_ text: NSAttributedString) -> NSScrollView {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
    let view = NSTextView(frame: scroll.bounds)
    view.isEditable = false
    view.textStorage?.setAttributedString(text)
    view.textContainerInset = NSSize(width: 6, height: 6)
    view.isVerticallyResizable = true
    view.autoresizingMask = [.width]
    scroll.documentView = view
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    return scroll
}

/// Revert (outlined), Keep (filled with the theme's accent, set in paper) and a quiet link, each with its keys in one
/// `Keycap`: ⌥⌘⌫ for Revert, ⌘↩ for Keep. Its width holds its title and its Option title, so holding Option moves
/// nothing; the short form sets the title alone at 11 pt, the icon form its symbol alone.
@MainActor
final class StampButton: NSButton {
    enum Style { case outlined, filled, link }
    enum Form { case full, short, icon }

    static let height: CGFloat = 22
    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let shortFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// From the button's top to its label's baseline.
    static let labelBaseline = ((height + font.capHeight) / 2).rounded()

    private let style: Style
    private let keys: String
    private let symbol: String?
    /// The title, keys and action the button takes while Option is down.
    private let alternate: (title: String, keys: String, action: Selector)?
    var handler: () -> Void
    var optionDown = false {
        didSet { if optionDown != oldValue, alternate != nil { needsDisplay = true } }
    }
    var form = Form.full {
        didSet { if form != oldValue { needsDisplay = true } }
    }

    init(
        _ title: String, keys: String, style: Style, symbol: String? = nil,
        alternate: (title: String, keys: String, action: Selector)? = nil, _ action: @escaping () -> Void
    ) {
        self.style = style
        self.keys = keys
        self.symbol = symbol
        self.alternate = alternate
        handler = action
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        target = self
        self.action = #selector(clicked)
    }

    required init?(coder: NSCoder) {
        fatalError("StampButton is built in code")
    }

    override var isFlipped: Bool { true }

    /// With Option down, the alternate action goes to the text view the stamp is in.
    @objc private func clicked() {
        guard NSEvent.modifierFlags.contains(.option), let alternate else { return handler() }
        let textView = sequence(first: self as NSView, next: \.superview).first { $0 is EditorTextView }
        NSApp.sendAction(alternate.action, to: textView, from: self)
    }

    private var shownTitle: String {
        optionDown ? alternate?.title ?? title : title
    }

    private func label(_ title: String, _ form: Form = .full) -> NSAttributedString {
        let store = ThemeStore.shared
        if style == .link {
            return NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: store.color(.ink2)])
        }
        let font = form == .short ? Self.shortFont : Self.font
        return NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: store.color(style == .filled ? .paper : .ink)])
    }

    private static func caps(_ keys: String) -> [String] {
        keys.isEmpty ? [] : [keys]
    }

    private var symbolImage: NSImage? {
        let color = ThemeStore.shared.color(style == .filled ? .paper : .ink)
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold).applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(config) }
    }

    /// The label and keys' width for `title` in `form`; the short form drops the keys.
    private func content(_ title: String, _ keys: String, _ form: Form) -> CGFloat {
        label(title, form).size().width + (keys.isEmpty || form == .short ? 0 : 5 + Keycap.width(Self.caps(keys)))
    }

    /// The button's width in `form`.
    func width(_ form: Form) -> CGFloat {
        if style == .link { return ceil(label(title).size().width) }
        if form == .icon, symbolImage != nil { return 26 }
        return ceil(8 + max(content(title, keys, form), alternate.map { content($0.title, $0.keys, form) } ?? 0) + 7)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: width(form), height: style == .link ? 18 : Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let store = ThemeStore.shared
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5)
        switch style {
        case .filled:
            store.color(.accent).withAlphaComponent(isHighlighted ? 0.85 : 1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        case .outlined:
            if isHighlighted {
                store.color(.ink).withAlphaComponent(0.08).setFill()
                box.fill()
            }
            store.color(.rule).setStroke()
            box.lineWidth = 1
            box.stroke()
        case .link:
            label(title).draw(at: .zero)
            return
        }
        if form == .icon, let image = symbolImage {
            let rect = NSRect(
                x: ((bounds.width - image.size.width) / 2).rounded(), y: ((bounds.height - image.size.height) / 2).rounded(),
                width: image.size.width, height: image.size.height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        let font = form == .short ? Self.shortFont : Self.font
        let baseline = ((Self.height + font.capHeight) / 2).rounded()
        let title = shownTitle
        let shownKeys = form == .short ? "" : optionDown ? alternate?.keys ?? keys : keys
        let text = label(title, form)
        let x = ((bounds.width - content(title, shownKeys, form)) / 2).rounded()
        text.draw(at: NSPoint(x: x, y: baseline - font.ascender))
        Keycap.draw(Self.caps(shownKeys), x: x + text.size().width + 5, midY: bounds.midY, onFill: style == .filled)
    }
}
