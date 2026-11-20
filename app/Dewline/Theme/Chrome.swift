import AppKit

/// The chrome's faces: SF Pro at the macOS text styles' sizes for every label Dewline draws (subheadline in the status
/// bar, body in the sidebar, tabs and panels), and SF Mono for branch names, counts, badges and keycaps.
@MainActor
enum Chrome {
    /// Section labels' tracking.
    static let sectionKern: CGFloat = 0

    /// The system face at `size`, at the nearest of its weights to `weight` on the 100 to 900 scale. `opticalSize` is
    /// kept for callers that name one; SF Pro picks its own.
    static func brand(_ size: CGFloat, weight: CGFloat = 400, opticalSize: CGFloat? = nil) -> NSFont {
        .systemFont(ofSize: size, weight: weight >= 590 ? .semibold : weight >= 500 ? .medium : .regular)
    }

    /// SF Mono at `size`.
    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// The size of a macOS text style.
    static func size(_ style: NSFont.TextStyle) -> CGFloat {
        NSFont.preferredFont(forTextStyle: style).pointSize
    }

    /// Sidebar rows, tabs, panels and Settings rows: body.
    static var label: NSFont { .systemFont(ofSize: size(.body)) }
    /// The selected tab and other emphasis in a row: body medium.
    static var labelActive: NSFont { .systemFont(ofSize: size(.body), weight: .medium) }
    /// The folder's name over its tree: body semibold.
    static var labelStrong: NSFont { .systemFont(ofSize: size(.body), weight: .semibold) }
    /// Section labels in the palette and Settings: subheadline medium.
    static var section: NSFont { .systemFont(ofSize: size(.subheadline), weight: .medium) }
    /// Outline headings and secondary rows: callout.
    static var small: NSFont { .systemFont(ofSize: size(.callout)) }
    /// The status bar: subheadline, with tabular digits.
    static var status: NSFont { .monospacedDigitSystemFont(ofSize: size(.subheadline), weight: .regular) }
    /// The palette input: title 2.
    static var title: NSFont { .systemFont(ofSize: size(.title2)) }

    /// An SF Symbol at the label's size, small scale, in `color`.
    static func symbol(_ name: String, _ color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(textStyle: .body, scale: .small).applying(.init(paletteColors: [color])))
    }

    /// Section label text with its tracking.
    static func sectionTitle(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: section, .foregroundColor: color, .kern: sectionKern])
    }

    // MARK: Colors

    static func color(_ token: Token) -> NSColor {
        ThemeStore.shared.color(token)
    }

    /// The accent at 15%, 25% under Increase Contrast: the selected row's fill.
    static var wash: NSColor {
        let accent = color(.accent)
        return NSColor(name: nil) { accent.resolved(for: $0).withAlphaComponent($0.isHighContrast ? 0.25 : 0.15) }
    }

    /// Ink at 8% in light and 7% in dark: a hovered tab, row or button.
    static var hover: NSColor {
        let ink = color(.ink)
        return NSColor(name: nil) { ink.resolved(for: $0).withAlphaComponent($0.isDark ? 0.07 : 0.08) }
    }

    /// Ink at 8%, 25% under Increase Contrast: the selected row in a window that isn't key.
    static var inactiveSelection: NSColor {
        let ink = color(.ink)
        return NSColor(name: nil) { ink.resolved(for: $0).withAlphaComponent($0.isHighContrast ? 0.25 : 0.08) }
    }

    /// The outer edge of islands and the palette: ink at 8% in light, ink2 at 10% in dark.
    static var strokeSubtle: NSColor {
        let (ink, ink2) = (color(.ink), color(.ink2))
        return NSColor(name: nil) { $0.isDark ? ink2.resolved(for: $0).withAlphaComponent(0.10) : ink.resolved(for: $0).withAlphaComponent(0.08) }
    }
}

/// One key as a cap: 20 pt tall, at least 20 wide, 5 pt radius, `keycap` fill with a `hairline` edge one step darker
/// at the bottom, the key in mono 11 `ink2`. On an ink fill the cap takes the island's color at low alpha instead.
@MainActor
enum Keycap {
    static let height: CGFloat = 20
    static let gap: CGFloat = 3

    static func width(_ key: String) -> CGFloat {
        max(height, ceil((key as NSString).size(withAttributes: [.font: Chrome.mono(11)]).width) + 10)
    }

    static func width(_ keys: [String]) -> CGFloat {
        keys.isEmpty ? 0 : keys.map(width).reduce(0, +) + gap * CGFloat(keys.count - 1)
    }

    /// Draws `keys` left to right from `origin`, vertically centered on `midY`, in the current appearance.
    static func draw(_ keys: [String], x origin: CGFloat, midY: CGFloat, onFill: Bool, alpha: CGFloat = 1) {
        var x = origin
        for key in keys {
            let width = width(key)
            let rect = NSRect(x: x, y: midY - height / 2, width: width, height: height)
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            let text: NSColor
            if onFill {
                Chrome.color(.islandEditor).withAlphaComponent(0.16 * alpha).setFill()
                shape.fill()
                text = Chrome.color(.islandEditor).withAlphaComponent(alpha)
            } else {
                Chrome.color(.keycap).withAlphaComponent(alpha).setFill()
                shape.fill()
                Chrome.color(.hairline).withAlphaComponent(alpha).setStroke()
                shape.lineWidth = 1
                shape.stroke()
                // The bottom edge one step darker, so the cap reads as a key.
                let bottom = NSBezierPath()
                let y = NSGraphicsContext.current?.isFlipped == true ? rect.maxY - 0.5 : rect.minY + 0.5
                bottom.move(to: NSPoint(x: rect.minX + 4, y: y))
                bottom.line(to: NSPoint(x: rect.maxX - 4, y: y))
                bottom.lineWidth = 1
                Chrome.color(.ink3).withAlphaComponent(0.35 * alpha).setStroke()
                bottom.stroke()
                text = Chrome.color(.ink2).withAlphaComponent(alpha)
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: Chrome.mono(11), .foregroundColor: text]
            let size = (key as NSString).size(withAttributes: attributes)
            (key as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            x += width + gap
        }
    }
}

/// A chrome button drawn by Dewline: a text button in `ink2` (`ink` under the pointer), or, filled, the accent with
/// `paper` for its text, 6 pt radius, 28 pt tall. Keycaps follow the title. Under Full Keyboard Access it takes the
/// focus, with the system's ring, and Space or Return presses it.
final class ChromeButton: NSControl {
    enum Style {
        case text, filled
    }

    private let title: String
    private let keys: [String]
    private let style: Style
    private let handler: () -> Void
    private var hovering = false {
        didSet { needsDisplay = true }
    }
    private var pressed = false {
        didSet { needsDisplay = true }
    }

    init(_ title: String, keys: [String] = [], style: Style = .text, label: String? = nil, _ handler: @escaping () -> Void) {
        self.title = title
        self.keys = keys
        self.style = style
        self.handler = handler
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label ?? title)
        toolTip = keys.isEmpty ? nil : "\(title) (\(keys.joined()))"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ChromeButton is built in code")
    }

    override var isFlipped: Bool { true }

    private var titleFont: NSFont { style == .filled ? Chrome.labelActive : Chrome.label }

    override var intrinsicContentSize: NSSize {
        let text = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
        let caps = keys.isEmpty ? 0 : 8 + Keycap.width(keys)
        return NSSize(width: (style == .filled ? 14 : 6) * 2 + text + caps, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        let filled = style == .filled
        if filled {
            Chrome.color(.accent).withAlphaComponent(pressed ? 0.82 : 1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let color: NSColor = filled ? Chrome.color(.paper) : Chrome.color(hovering || pressed ? .ink : .ink2)
        let attributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attributes)
        let x: CGFloat = filled ? 14 : 6
        (title as NSString).draw(at: NSPoint(x: x, y: bounds.midY - size.height / 2), withAttributes: attributes)
        if !keys.isEmpty {
            Keycap.draw(keys, x: x + ceil(size.width) + 8, midY: bounds.midY, onFill: filled, alpha: isEnabled ? 1 : 0.6)
        }
    }

    override var acceptsFirstResponder: Bool { isEnabled && takesKeyboardFocus }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, pressesOnKey(event) else { return super.keyDown(with: event) }
        handler()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                pressed = false
                if inside { handler() }
                return
            }
            pressed = inside
        }
    }

    override func accessibilityPerformPress() -> Bool {
        handler()
        return true
    }

    @objc private func themeDidChange() {
        needsDisplay = true
    }
}

/// The mark: the icon's monospace d in the theme's ink and its text cursor in the cursor orange, fitted to the view and
/// resting on its bottom edge. Drawn on the icon's 1024 grid, where the mark spans x 265 to 760 and y 257 to 767.
final class DewMark: NSView {
    init(size: NSSize = NSSize(width: 12, height: 12)) {
        super.init(frame: NSRect(origin: .zero, size: size))
        setAccessibilityElement(false)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("DewMark is built in code")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = min(bounds.width / 495, bounds.height / 510)
        context.translateBy(x: (bounds.width - 495 * scale) / 2, y: bounds.height - 510 * scale)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -265, y: -257)
        Chrome.color(.ink).resolved(for: effectiveAppearance).setFill()
        // The d's outer contour and its counter, wound against each other.
        let d = NSBezierPath()
        d.move(to: NSPoint(x: 430, y: 257))
        d.line(to: NSPoint(x: 595, y: 257))
        d.line(to: NSPoint(x: 595, y: 767))
        d.line(to: NSPoint(x: 415, y: 767))
        d.curve(to: NSPoint(x: 265, y: 617), controlPoint1: NSPoint(x: 322, y: 767), controlPoint2: NSPoint(x: 265, y: 710))
        d.line(to: NSPoint(x: 265, y: 572))
        d.curve(to: NSPoint(x: 415, y: 422), controlPoint1: NSPoint(x: 265, y: 479), controlPoint2: NSPoint(x: 322, y: 422))
        d.line(to: NSPoint(x: 490, y: 422))
        d.line(to: NSPoint(x: 490, y: 347))
        d.line(to: NSPoint(x: 430, y: 347))
        d.close()
        d.move(to: NSPoint(x: 415, y: 512))
        d.line(to: NSPoint(x: 445, y: 512))
        d.curve(to: NSPoint(x: 490, y: 557), controlPoint1: NSPoint(x: 472.9, y: 512), controlPoint2: NSPoint(x: 490, y: 529.1))
        d.line(to: NSPoint(x: 490, y: 632))
        d.curve(to: NSPoint(x: 445, y: 677), controlPoint1: NSPoint(x: 490, y: 659.9), controlPoint2: NSPoint(x: 472.9, y: 677))
        d.line(to: NSPoint(x: 415, y: 677))
        d.curve(to: NSPoint(x: 355, y: 617), controlPoint1: NSPoint(x: 377.8, y: 677), controlPoint2: NSPoint(x: 355, y: 654.2))
        d.line(to: NSPoint(x: 355, y: 572))
        d.curve(to: NSPoint(x: 415, y: 512), controlPoint1: NSPoint(x: 355, y: 534.8), controlPoint2: NSPoint(x: 377.8, y: 512))
        d.close()
        d.windingRule = .evenOdd
        d.fill()
        Chrome.color(.cursor).resolved(for: effectiveAppearance).setFill()
        NSBezierPath(roundedRect: NSRect(x: 655, y: 257, width: 105, height: 510), xRadius: 8, yRadius: 8).fill()
    }

    @objc private func themeDidChange() {
        needsDisplay = true
    }
}

/// A selected row: a 6 pt radius pill 6 pt in from each side. While the list has the keyboard in the key window it is
/// the solid accent and its cells, their background style `.emphasized`, draw in `paper`; otherwise the accent at 15%
/// while the window is key, ink at 8% when it isn't. No hover, no system highlight. Cells that conform to
/// `ChromeSelectable` hear about selection.
class StationRowView: NSTableRowView {
    /// Where the selection draws.
    var pill: NSRect { bounds.insetBy(dx: 6, dy: 0) }

    /// Whether the row's window is key, so the selection shows in the accent, as the tab bar's cursor bar and the caret do.
    var isWindowActive: Bool { window?.isKeyWindow ?? false }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            for index in 0..<numberOfColumns {
                (view(atColumn: index) as? ChromeSelectable)?.selected = isSelected
            }
        }
    }

    override var isEmphasized: Bool {
        didSet { if isSelected { needsDisplay = true } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
            if let window { NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: name, object: window) }
        }
    }

    @objc private func keyChanged() {
        if isSelected { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        (!isWindowActive ? Chrome.inactiveSelection : isEmphasized ? Chrome.color(.accent) : Chrome.wash).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? ChromeSelectable)?.selected = isSelected
    }
}

/// A cell that changes its ink when its row is selected.
@MainActor
protocol ChromeSelectable: AnyObject {
    var selected: Bool { get set }
}

/// Whether a control Dewline draws takes the focus: under Full Keyboard Access, and not from a click, which leaves the
/// focus where it was.
@MainActor var takesKeyboardFocus: Bool {
    NSApp.isFullKeyboardAccessEnabled && NSApp.currentEvent?.type != .leftMouseDown
}

/// Space, Return or Enter with no modifier: the keys that press a focused control.
func pressesOnKey(_ event: NSEvent) -> Bool {
    event.modifierFlags.intersection([.command, .control, .option]).isEmpty && [49, 36, 76].contains(event.keyCode)
}
