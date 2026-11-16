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

/// A button that calls `action` when clicked: the prominent one filled with ink and set in paper, the others bare text
/// in `ink2`.
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
        NotificationCenter.default.addObserver(self, selector: #selector(paint), name: ThemeStore.didChange, object: nil)
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + (prominent ? 24 : 8), height: 24)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.backgroundColor = prominent ? ThemeStore.shared.color(.ink).resolved(for: effectiveAppearance).cgColor : nil
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

/// The focused change's stamp. In the margin, "CLAUDE 3:25 PM · 1 change" sits on the change's first text baseline
/// and Revert and Keep on its second, the stamp's right edge 26 pt left of the text column. Where the margin is
/// narrower than the stamp plus that 26 pt and a 24 pt gutter, it folds into a 30 pt bar under the block holding the
/// change, on the writer's ink at 8%: writer, time and count on the left, Revert and Keep on the right. The cursor
/// bar stands on the page just before Keep's leading edge: no dark orange reaches 3:1 on both the dark paper and
/// Keep's cream fill.
@MainActor
final class ChangeStamp: NSView {
    static let barHeight: CGFloat = 30
    /// From the stamp's right edge to the text column, and the least margin left of the stamp.
    static let inset: CGFloat = 26
    static let gutter: CGFloat = 24
    /// Between Revert and Keep, where the cursor bar stands.
    private static let gap: CGFloat = 10

    private let revert: StampButton
    private let keep: StampButton
    private let setUp: StampButton
    private var writer: MarkWriter?
    private var time = ""
    private var count = 0
    private var external = false
    private(set) var folded = false
    /// Line 1's baseline and left edge, in this view.
    private var baseline: CGFloat = 0
    private var textX: CGFloat = 0
    /// The size changed: the marks lay out again.
    var resized: () -> Void = {}
    /// The first stamp in a session to show another app's change, while no agent has hooks, offers hook setup.
    private var offering = false
    private static var offeredHooks = false
    private static var checkingHooks = false

    init(revert: @escaping () -> Void, keep: @escaping () -> Void) {
        self.revert = StampButton("Revert", keys: "\u{2325}\u{2318}\u{232B}", style: .outlined, revert)
        self.keep = StampButton("Keep", keys: "\u{2318}", returnKey: true, style: .filled, keep)
        setUp = StampButton("Set up agent hooks\u{2026}", keys: "", style: .link) {
            NSApp.sendAction(#selector(AppDelegate.setUpHooks(_:)), to: nil, from: nil)
        }
        super.init(frame: .zero)
        self.revert.toolTip = "Revert (\u{2325}\u{2318}\u{232B})"
        self.keep.toolTip = "Keep (\u{2318}\u{21A9})"
        setUp.toolTip = "Name this writer: set up agent hooks"
        setUp.isHidden = true
        for button in [self.revert, self.keep, setUp] { addSubview(button) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ChangeStamp is built in code")
    }

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    @objc private func themeDidChange() {
        for view in [self, revert, keep, setUp] { view.needsDisplay = true }
        resized()
    }

    /// Shows `writer`'s change, which landed at `time`, one of `count` from its session in the note.
    func show(_ writer: MarkWriter, at time: Date, count: Int, external: Bool) {
        let time = time.formatted(date: .omitted, time: .shortened)
        let changed = writer != self.writer || time != self.time || count != self.count
        self.writer = writer
        self.time = time
        self.count = count
        self.external = external
        setAccessibilityLabel("\(writer.name), \(time), \(count) \(count == 1 ? "change" : "changes")")
        revert.setAccessibilityLabel("Revert \(writer.possessive) change")
        keep.setAccessibilityLabel("Keep \(writer.possessive) change")
        setUp.isHidden = !(offering && external)
        if changed { needsDisplay = true }
        if external { offerHooks() }
    }

    private func offerHooks() {
        guard !Self.offeredHooks, !Self.checkingHooks, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Self.checkingHooks = true
        Task { [weak self] in
            let hooks = await Task.detached { HookStatus.read() }.value
            Self.checkingHooks = false
            guard !hooks.claude, !hooks.codex else { return Self.offeredHooks = true }
            guard let self, self.external, self.superview != nil else { return }
            Self.offeredHooks = true
            self.offering = true
            self.setUp.isHidden = false
            self.resized()
        }
    }

    /// "CLAUDE 3:25 PM · 1 change": the writer in SF Mono capitals in its ink, the time in SF Mono, the count in SF Pro.
    private var line: NSAttributedString {
        guard let writer else { return NSAttributedString() }
        let ink2 = ThemeStore.shared.color(.ink2)
        let line = NSMutableAttributedString(attributedString: writer.stamp)
        // The bar's 8% wash takes Claude's light ink to 4.1:1; a quarter of the way to ink keeps every writer over 4.5:1.
        if folded, let name = OKLCH(writer.color.resolved(for: effectiveAppearance)),
            let ink = OKLCH(ThemeStore.shared.color(.ink).resolved(for: effectiveAppearance)) {
            line.addAttribute(.foregroundColor, value: name.mixed(with: ink, by: 0.25).color, range: NSRange(location: 0, length: line.length))
        }
        line.append(NSAttributedString(string: "  " + time, attributes: [.font: Chrome.mono(10.5), .foregroundColor: ink2]))
        line.append(NSAttributedString(string: " \u{00B7} \(count) \(count == 1 ? "change" : "changes")", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: ink2,
        ]))
        return line
    }

    private var ascent: CGFloat {
        ceil(max(Chrome.mono(10.5, weight: .semibold).ascender, NSFont.systemFont(ofSize: 11).ascender))
    }

    private var buttonsWidth: CGFloat {
        revert.intrinsicContentSize.width + Self.gap + keep.intrinsicContentSize.width
    }

    /// The width the stamp takes in the margin.
    var marginWidth: CGFloat {
        ceil(max(line.size().width, buttonsWidth, setUp.isHidden ? 0 : setUp.intrinsicContentSize.width))
    }

    /// In the margin, its right edge at `right`: line 1 on `first`, the buttons' labels on `second`, both baselines
    /// in the superview.
    func placeInMargin(right: CGFloat, first: CGFloat, second: CGFloat) {
        folded = false
        let width = marginWidth
        let top = first - ascent
        baseline = ascent
        textX = width - ceil(line.size().width)
        // The buttons clear line 1's descent even when the second baseline sits close under the first.
        let buttons = max(second - StampButton.labelBaseline, first + 4) - top
        let keepWidth = keep.intrinsicContentSize.width
        keep.frame = NSRect(x: width - keepWidth, y: buttons, width: keepWidth, height: StampButton.height)
        let revertWidth = revert.intrinsicContentSize.width
        revert.frame = NSRect(x: keep.frame.minX - Self.gap - revertWidth, y: buttons, width: revertWidth, height: StampButton.height)
        var bottom = keep.frame.maxY
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
        let keepWidth = keep.intrinsicContentSize.width
        keep.frame = NSRect(x: rect.width - y - keepWidth, y: y, width: keepWidth, height: StampButton.height)
        let revertWidth = revert.intrinsicContentSize.width
        revert.frame = NSRect(x: keep.frame.minX - Self.gap - revertWidth, y: y, width: revertWidth, height: StampButton.height)
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
        // The 2 x 12 pt cursor bar, centered on Keep in the gap before it.
        ThemeStore.shared.color(.cursor).setFill()
        let bar = NSRect(x: keep.frame.minX - Self.gap / 2 - 1, y: keep.frame.midY - 6, width: 2, height: 12)
        NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
    }
}

/// Revert (outlined), Keep (filled with ink, set in paper) and a quiet link, each with its keys drawn as keycaps in
/// SF Pro: ⌥⌘⌫ for Revert, ⌘ and the SF Symbol `return` for Keep.
@MainActor
final class StampButton: NSButton {
    enum Style { case outlined, filled, link }

    static let height: CGFloat = 22
    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    /// From the button's top to its label's baseline.
    static let labelBaseline = ((height + font.capHeight) / 2).rounded()

    private let style: Style
    private let keys: String
    private let returnKey: Bool
    private let handler: () -> Void

    init(_ title: String, keys: String, returnKey: Bool = false, style: Style, _ action: @escaping () -> Void) {
        self.style = style
        self.keys = keys
        self.returnKey = returnKey
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

    @objc private func clicked() {
        handler()
    }

    private var label: NSAttributedString {
        let store = ThemeStore.shared
        if style == .link {
            return NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: store.color(.ink2)])
        }
        return NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: store.color(style == .filled ? .paper : .ink)])
    }

    private var keycaps: NSAttributedString {
        let color = ThemeStore.shared.color(style == .filled ? .paper : .ink2)
        return NSAttributedString(string: keys, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color])
    }

    private var returnImage: NSImage? {
        guard returnKey else { return nil }
        let color = ThemeStore.shared.color(style == .filled ? .paper : .ink2)
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular).applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: "return", accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    override var intrinsicContentSize: NSSize {
        if style == .link { return NSSize(width: ceil(label.size().width), height: 18) }
        let keys = keycaps.size().width + (returnImage.map { $0.size.width + 1 } ?? 0)
        return NSSize(width: ceil(8 + label.size().width + 5 + keys + 7), height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let store = ThemeStore.shared
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5)
        switch style {
        case .filled:
            store.color(.ink).withAlphaComponent(isHighlighted ? 0.85 : 1).setFill()
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
            label.draw(at: .zero)
            return
        }
        let baseline = Self.labelBaseline
        label.draw(at: NSPoint(x: 8, y: baseline - Self.font.ascender))
        var x = 8 + label.size().width + 5
        keycaps.draw(at: NSPoint(x: x, y: baseline - NSFont.systemFont(ofSize: 12).ascender))
        x += keycaps.size().width
        if let image = returnImage {
            let rect = NSRect(x: x + 1, y: baseline - image.size.height + 1, width: image.size.width, height: image.size.height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}
