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

/// A small push button that calls `action` when clicked, the prominent one with the theme's accent bezel.
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
        bezelStyle = .push
        controlSize = .small
        font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        toolTip = shortcut.map { "\(title) (\($0))" }
        setAccessibilityLabel(label)
        paint()
        NotificationCenter.default.addObserver(self, selector: #selector(paint), name: ThemeStore.didChange, object: ThemeStore.shared)
    }

    @objc private func paint() {
        bezelColor = prominent ? ThemeStore.shared.color(.accent) : nil
    }

    @objc private func clicked() {
        handler()
    }
}

/// Removed text, struck, at ink 58% with the strike in the writer's color. A short removal on one line reads inline
/// at its deletion point, in a gap the styler opens there; a longer one, and the old text of a rewrite, hang under
/// their paragraph.
@MainActor
final class Ghost: NSView, Hanging {
    private let string: NSAttributedString
    private let text: NSTextField?
    /// The text as it reads, without a final line break.
    let shown: String
    /// The gap an inline ghost takes in its line: its text, and a space on a side where it would join a word; nil for
    /// a ghost that hangs.
    let inlineWidth: CGFloat?
    /// From the start of an inline ghost's gap to its text.
    let lead: CGFloat
    /// From an inline ghost's top to its baseline.
    let ascent: CGFloat

    /// The width its text takes unwrapped.
    var naturalWidth: CGFloat {
        ceil(string.size().width) + 4
    }

    /// `parts` of the old text, struck where `struck`. One struck part on one line whose gap is no wider than `limit`
    /// reads inline, spaced from a word `before` or `after` it.
    /// In `font` and `style`: a code file's ghost sets its lines as the code's.
    init(
        _ parts: [(text: String, struck: Bool)], writer: MarkWriter, inlineUpTo limit: CGFloat, spaced: (before: Bool, after: Bool) = (false, false),
        font: NSFont = ThemeStore.shared.bodyFont, style: NSParagraphStyle = .default
    ) {
        let shown = Self.shown(parts)
        self.shown = shown
        let ink = ThemeStore.shared.color(.ink).withAlphaComponent(0.58)
        let built = NSMutableAttributedString()
        for part in parts {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .paragraphStyle: style]
            if part.struck {
                // Under four characters, a single strike is lost in the letters.
                let short = part.text.trimmingCharacters(in: .whitespacesAndNewlines).count < 4
                attributes[.strikethroughStyle] = (short ? NSUnderlineStyle.thick : .single).rawValue
                attributes[.strikethroughColor] = writer.color
            }
            built.append(NSAttributedString(string: part.text, attributes: attributes))
        }
        string = built.attributedSubstring(from: NSRange(location: 0, length: (shown as NSString).length))
        let width = ceil(string.size().width)
        let space = ceil(NSAttributedString(string: " ", attributes: [.font: font]).size().width)
        let gap = width + (spaced.before ? space : 0) + (spaced.after ? space : 0)
        let inline = parts.count == 1 && !shown.isEmpty && !shown.contains(where: \.isNewline) && gap <= limit
        inlineWidth = inline ? gap : nil
        lead = spaced.before ? space : 0
        ascent = ceil(font.ascender)
        text = inline ? nil : NSTextField(wrappingLabelWithString: "")
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: ceil(font.ascender - font.descender)))
        let label = parts.count == 1 ? "Removed by \(writer.name): \(shown)" : "Before \(writer.possessive) change: \(shown)"
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

    /// `parts` joined, without a final line break.
    static func shown(_ parts: [(text: String, struck: Bool)]) -> String {
        let joined = parts.map(\.text).joined()
        return joined.hasSuffix("\n") ? String(joined.dropLast()) : joined
    }

    override var isFlipped: Bool { true }

    /// The label's text sits 2 pt in from its edges, so the label runs 2 pt past each of the ghost's, and its text
    /// lines up with the column's.
    func height(for width: CGFloat) -> CGFloat {
        guard let text else { return frame.height }
        text.preferredMaxLayoutWidth = width + 4
        return ceil(text.fittingSize.height)
    }

    override func layout() {
        super.layout()
        text?.frame = bounds.insetBy(dx: -2, dy: 0)
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

/// The focused change's stamp. In the margin, "CLAUDE CODE 3:25 PM · 3 of 4" sits on the change's first text baseline
/// and Revert and Keep on its second, the stamp's right edge 26 pt left of the text column, the keys in the buttons
/// where the margin has room; a narrower margin takes the compact stamp, "CLAUDE CODE · 3 of 4" over Revert and Keep
/// in smaller titles. Only where the margin is narrower than the compact stamp plus that 26 pt and a 24 pt gutter does
/// it fold into a bar under the block holding the change, on the writer's ink at 8%: writer, time and count on the
/// left, Revert and Keep on the right. Its text is 0.69 of the body text. Revert and Keep share one width, show on
/// every stamp, and Keep is filled on every stamp; the change Keep and Revert decide takes the heavier margin rule. A
/// change that breaks a typeset build says so under the buttons.
@MainActor
final class ChangeStamp: NSView {
    static var barHeight: CGFloat {
        StampButton.height + 8
    }

    /// The stamp's text size: 0.69 of the body text, at least 10 pt, so it follows Text size.
    static var textSize: CGFloat {
        max(10, (ThemeStore.shared.bodyFont.pointSize * 0.69).rounded())
    }

    /// From the stamp's right edge to the text column, and the least margin left of the stamp.
    static let inset: CGFloat = 26
    static let gutter: CGFloat = 24
    /// Between Revert and Keep.
    private static let gap: CGFloat = 10
    /// What an unnamed change that landed while Claude Code ran a shell command says (X2).
    static let duringShell = "During Claude Code\u{2019}s shell command"
    /// What a change says once Revert finds text typed inside it; Revert then asks before it puts the old text back.
    static let typedInside = "You edited inside it"
    /// What the hook link says while Codex has Dewline's hook but hasn't trusted it, so it names none of its edits.
    static let trustCodex = "Trust Dewline\u{2019}s hook in Codex: /hooks"
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
    /// The typesetting error on the change's lines.
    private var error: String?
    private(set) var folded = false
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
            "Revert", style: .outlined, symbol: "arrow.uturn.backward", keys: "\u{2325}\u{2318}\u{232B}",
            alternate: ("Revert All", "\u{2325}\u{21E7}\u{2318}\u{232B}", #selector(EditorTextView.revertAllChanges(_:))), revert)
        self.keep = StampButton(
            "Keep", style: .filled, symbol: "checkmark", keys: "\u{2318}\u{21A9}",
            alternate: ("Keep All", "\u{21E7}\u{2318}\u{21A9}", #selector(EditorTextView.keepAllChanges(_:))), keep)
        setUp = StampButton("Set up agent hooks\u{2026}", style: .link) {
            NSApp.sendAction(#selector(AppDelegate.setUpHooks(_:)), to: nil, from: nil)
        }
        super.init(frame: .zero)
        // VoiceOver reads the keys as help.
        for (button, tip) in [
            (self.revert, "Puts the old text back. Revert (\u{2325}\u{2318}\u{232B}). Option-click: Revert All (\u{2325}\u{21E7}\u{2318}\u{232B})"),
            (self.keep, "Already saved; Keep clears the mark. Keep (\u{2318}\u{21A9}). Option-click: Keep All (\u{21E7}\u{2318}\u{21A9})"),
        ] {
            button.toolTip = tip
            button.setAccessibilityHelp(tip)
        }
        setUp.toolTip = "Name this writer: set up agent hooks"
        setUp.isHidden = true
        note.lineBreakMode = .byTruncatingTail
        note.isHidden = true
        for view in [self.revert, self.keep, setUp, note] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: ThemeStore.shared)
        NotificationCenter.default.addObserver(self, selector: #selector(revertRefused(_:)), name: LiveFile.revertRefused, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ChangeStamp is built in code")
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
        paintNote()
        for view in [self, revert, keep, setUp] { view.needsDisplay = true }
        resized()
    }

    private func paintNote() {
        note.font = .systemFont(ofSize: Self.textSize)
        note.textColor = ThemeStore.shared.color(error != nil && !note.isHidden && note.stringValue != Self.typedInside ? .codeDeleted : .ink2)
    }

    /// Shows `writer`'s change that landed at `time`, `index` of the window's `total` waiting changes, during Claude
    /// Code's shell command when `shell`, why Revert left one when `refused`, and the typesetting `error` on its lines;
    /// Keep and Revert decide it, "Keep 3 of 4" when the window has more.
    func show(_ writer: MarkWriter, at time: Date, index: Int, of total: Int, external: Bool, shell: Bool, refused: Bool, error: String? = nil) {
        let time = time.formatted(date: .omitted, time: .shortened)
        let changed = writer != self.writer || time != self.time || index != self.index || total != self.total || error != self.error
        self.writer = writer
        self.time = time
        self.index = index
        self.total = total
        self.external = external
        self.shell = shell
        self.error = error
        note.stringValue = refused ? Self.typedInside : error.map { "Breaks the build: \($0)" } ?? Self.duringShell
        note.isHidden = !(shell || refused || error != nil)
        paintNote()
        setAccessibilityLabel("\(writer.name), \(time), saved, \(index) of \(total)" + (note.isHidden ? "" : ", \(note.stringValue)"))
        let of = total == 1 ? "" : ", \(index) of \(total)"
        revert.setAccessibilityLabel("Revert \(writer.possessive) change" + of)
        keep.setAccessibilityLabel("Keep \(writer.possessive) change" + of)
        // Set Up names no shell command's change, so a change during one doesn't offer it.
        setUp.isHidden = !(offering && external && !shell) || offeredHere
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
            textView.history.perform("Revert Change") {
                for (id, change) in refused where live.changes[id] != nil {
                    live.keep(id)
                    textView.replaceAsOneEdit(change.range, with: change.removed)
                }
            }
        }
    }

    /// The hook sheet has shown for this note's folder, so its Not Now holds for the link too.
    private var offeredHere: Bool {
        (window?.windowController as? MainWindowController)?.folder.map { HookSetup.offered(in: $0.url) } ?? false
    }

    private func offerHooks() {
        guard !Self.offeredHooks, !Self.checkingHooks, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Self.checkingHooks = true
        Task { [weak self] in
            let report = await HookSetup.run(HookSetup.command(), ["doctor"], answers: 0)
            Self.checkingHooks = false
            let trust = Self.codexNeedsTrust(report.output)
            guard report.ran, trust || !HookSetup.missing(in: report.output).isEmpty else { return Self.offeredHooks = true }
            guard let self, self.external, !self.shell, self.superview != nil, !self.offeredHere else { return }
            Self.offeredHooks = true
            self.offering = true
            if trust { self.offerTrust() }
            self.setUp.isHidden = false
            self.resized()
        }
    }

    /// Whether the doctor's report has Codex holding Dewline's hooks it hasn't trusted, so they never run.
    static func codexNeedsTrust(_ report: String) -> Bool {
        report.split(separator: "\n").contains { $0.hasPrefix("  Codex: installed in ") && $0.contains("; needs trust") }
    }

    /// The link asks for Codex's trust instead of setup, and copies `/hooks` to paste into Codex.
    func offerTrust() {
        setUp.retitle(Self.trustCodex) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("/hooks", forType: .string)
        }
        setUp.toolTip = "In Codex, run /hooks and trust Dewline\u{2019}s hook. Click to copy /hooks."
    }

    /// "CLAUDE CODE 3:25 PM · 3 of 4": the writer in small capitals in its ink, the time with fixed-width digits and the
    /// change's place in the window; "CLAUDE CODE · 3 of 4" in the compact stamp.
    private var line: NSAttributedString {
        line(compact: keep.form == .short && !folded)
    }

    private func line(compact: Bool) -> NSAttributedString {
        guard let writer else { return NSAttributedString() }
        let ink2 = ThemeStore.shared.color(.ink2)
        let size = Self.textSize
        let line = NSMutableAttributedString(attributedString: writer.stamp)
        // The bar's 8% wash takes Claude's light ink to 4.1:1; a quarter of the way to ink keeps every writer over 4.5:1.
        if folded, let name = OKLCH(writer.color.resolved(for: effectiveAppearance)),
            let ink = OKLCH(ThemeStore.shared.color(.ink).resolved(for: effectiveAppearance)) {
            line.addAttribute(.foregroundColor, value: name.mixed(with: ink, by: 0.25).color, range: NSRange(location: 0, length: line.length))
        }
        if !compact {
            line.append(NSAttributedString(string: "  " + time, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular), .foregroundColor: ink2]))
        }
        line.append(NSAttributedString(string: " \u{00B7} \(index) of \(total)", attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: ink2]))
        return line
    }

    private var ascent: CGFloat {
        ceil(max(MarkWriter.stampFont.ascender, NSFont.systemFont(ofSize: Self.textSize).ascender))
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
        width(.short)
    }

    private func width(_ form: StampButton.Form) -> CGFloat {
        ceil(max(
            line(compact: form == .short).size().width, buttonsWidth(form), setUp.isHidden ? 0 : setUp.intrinsicContentSize.width,
            note.isHidden ? 0 : note.intrinsicContentSize.width))
    }

    private func setForm(_ form: StampButton.Form) {
        keep.form = form
        revert.form = form
    }

    /// In the margin, its right edge at `right`: line 1 on `first`, the buttons' labels on `second`, both baselines
    /// in the superview. The buttons show their keys where the margin holds them, and short titles where it holds
    /// only the compact stamp.
    func placeInMargin(right: CGFloat, first: CGFloat, second: CGFloat) {
        folded = false
        setForm([StampButton.Form.keyed, .full].first { width($0) <= right - Self.gutter } ?? .short)
        let width = width(keep.form)
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
        let barHeight = Self.barHeight
        baseline = ((barHeight + NSFont.systemFont(ofSize: Self.textSize).capHeight) / 2).rounded()
        textX = 10
        let y = (barHeight - StampButton.height) / 2
        let noted = note.isHidden ? 0 : ceil(note.intrinsicContentSize.width) + 8
        setForm([StampButton.Form.keyed, .full].first { textX + ceil(line.size().width) + 8 + noted + buttonsWidth($0) + y <= rect.width } ?? .icon)
        let buttonWidth = buttonWidth(keep.form)
        keep.frame = NSRect(x: rect.width - y - buttonWidth, y: y, width: buttonWidth, height: StampButton.height)
        revert.frame = NSRect(x: keep.frame.minX - Self.gap - buttonWidth, y: y, width: buttonWidth, height: StampButton.height)
        if !note.isHidden {
            let size = note.intrinsicContentSize
            let x = textX + ceil(line.size().width) + 8
            note.frame = NSRect(x: x, y: (barHeight - size.height) / 2, width: max(min(ceil(size.width), revert.frame.minX - 8 - x), 0), height: size.height)
        }
        if !setUp.isHidden {
            let size = setUp.intrinsicContentSize
            setUp.frame = NSRect(x: textX + ceil(line.size().width) + 8, y: (barHeight - size.height) / 2, width: size.width, height: size.height)
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

/// Revert and Keep as push buttons, Keep with the theme's accent bezel on every stamp, and a quiet link in the accent.
/// Their titles are 0.69 of the body text, their control size following; the keyed form adds the keys after the title,
/// in `ink3` (on Keep's fill, its title's color at 70%). The width holds the title and the Option title, so holding
/// Option moves nothing; the short form sets the title a point smaller, the icon form its symbol alone.
@MainActor
final class StampButton: NSButton {
    enum Style { case outlined, filled, link }
    enum Form { case keyed, full, short, icon }

    /// The push button's control size for the stamp's text size.
    static var controlSize: NSControl.ControlSize {
        let size = ChangeStamp.textSize
        return size < 13 ? .small : size < 17 ? .regular : .large
    }

    private static var heights: [NSControl.ControlSize: CGFloat] = [:]

    /// A push button's height at `controlSize`, at least 22.
    static var height: CGFloat {
        let size = controlSize
        if let height = heights[size] { return height }
        let probe = NSButton(title: "Keep", target: nil, action: nil)
        probe.bezelStyle = .push
        probe.controlSize = size
        let height = max(22, ceil(probe.intrinsicContentSize.height))
        heights[size] = height
        return height
    }

    private static var font: NSFont {
        .systemFont(ofSize: ChangeStamp.textSize)
    }

    private static var shortFont: NSFont {
        .systemFont(ofSize: ChangeStamp.textSize - 1)
    }

    /// From the button's top to its label's baseline.
    static var labelBaseline: CGFloat {
        ((height + font.capHeight) / 2).rounded()
    }

    private let style: Style
    private let symbol: String?
    private let keys: String?
    /// The title, keys and action the button takes while Option is down.
    private let alternate: (title: String, keys: String, action: Selector)?
    private var plainTitle: String
    var handler: () -> Void
    var optionDown = false {
        didSet { if optionDown != oldValue, alternate != nil { show() } }
    }
    var form = Form.full {
        didSet { if form != oldValue { show() } }
    }

    init(
        _ title: String, style: Style, symbol: String? = nil, keys: String? = nil, alternate: (title: String, keys: String, action: Selector)? = nil,
        _ action: @escaping () -> Void
    ) {
        self.style = style
        self.symbol = symbol
        self.keys = keys
        self.alternate = alternate
        plainTitle = title
        handler = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(clicked)
        if style == .link {
            isBordered = false
        } else {
            bezelStyle = .push
            if style == .filled { bezelColor = ThemeStore.shared.color(.accent) }
        }
        show()
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: ThemeStore.shared)
    }

    required init?(coder: NSCoder) {
        fatalError("StampButton is built in code")
    }

    @objc private func themeDidChange() {
        if style == .filled { bezelColor = ThemeStore.shared.color(.accent) }
        show()
    }

    /// The link's new title and what a click does.
    func retitle(_ title: String, _ action: @escaping () -> Void) {
        plainTitle = title
        handler = action
        show()
    }

    /// With Option down, the alternate action goes to the text view the stamp is in.
    @objc private func clicked() {
        guard NSEvent.modifierFlags.contains(.option), let alternate else { return handler() }
        let textView = sequence(first: self as NSView, next: \.superview).first { $0 is EditorTextView }
        NSApp.sendAction(alternate.action, to: textView, from: self)
    }

    private var shownTitle: (title: String, keys: String?) {
        optionDown ? alternate.map { ($0.title, $0.keys) } ?? (plainTitle, keys) : (plainTitle, keys)
    }

    private func show() {
        if style == .link {
            attributedTitle = NSAttributedString(string: plainTitle, attributes: [.font: NSFont.systemFont(ofSize: ChangeStamp.textSize), .foregroundColor: ThemeStore.shared.color(.accent)])
            return
        }
        controlSize = Self.controlSize
        if form == .icon, let symbolImage {
            image = symbolImage
            imagePosition = .imageOnly
            return
        }
        image = nil
        imagePosition = .noImage
        font = form == .short ? Self.shortFont : Self.font
        title = shownTitle.title
        guard form == .keyed, let keys = shownTitle.keys else { return }
        let keyed = NSMutableAttributedString(attributedString: attributedTitle)
        let ink = style == .filled ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.7) : ThemeStore.shared.color(.ink3)
        keyed.append(NSAttributedString(string: "  " + keys, attributes: [.font: Self.font, .foregroundColor: ink]))
        attributedTitle = keyed
    }

    private var symbolImage: NSImage? {
        symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: ChangeStamp.textSize, weight: .semibold)) }
    }

    /// The button's width in `form`.
    func width(_ form: Form) -> CGFloat {
        if style == .link { return ceil(attributedTitle.size().width) }
        if form == .icon, symbolImage != nil { return Self.height + 4 }
        let font = form == .short ? Self.shortFont : Self.font
        let titles = [(plainTitle, keys)] + (alternate.map { [($0.title, $0.keys as String?)] } ?? [])
        let widest = titles.map { title, keys in
            NSAttributedString(string: form == .keyed ? title + "  " + (keys ?? "") : title, attributes: [.font: font]).size().width
        }.max() ?? 0
        return ceil(widest + 20)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: width(form), height: style == .link ? 18 : Self.height)
    }
}
