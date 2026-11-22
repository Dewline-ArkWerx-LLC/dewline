import AppKit

/// The dew line: the editor's vertical scroller. Its hairline is the whole note, a tick marks each H1, H2 and H3 (13, 9
/// and 5 pt long), a bracket filled with ink at 16% spans what is on screen, and each waiting change is a 3 x 10 pt rule
/// in its writer's ink at its place in the note, hollow for another app.
/// Hovering a mark lights its change. A click on a tick scrolls to its heading and a click on a mark scrolls its
/// change to the middle of the view; the track and the bracket scroll as the system's scroller does. Its labels draw in `labels`, over the page.
/// It follows the system's scroller style: legacy keeps it on screen, overlay shows it while the note scrolls or the
/// pointer is on it, and fades it 1 s after. While a change waits for Keep or Revert, an overlay rail at rest still draws
/// the waiting changes' marks, without the hairline or the bracket.
final class Rail: NSScroller {
    static let width: CGFloat = 22
    /// The hairline's left edge; the ticks, marks and bracket caps center on it.
    private static let line: CGFloat = 11
    /// The hairline stops this far from the rail's ends.
    private static let inset: CGFloat = 10

    let labels = RailLabels()
    private weak var textView: EditorTextView?
    /// The note's H1 to H3 headings, which name changes and are ticks.
    private var headings: [Heading] = []
    private var ticks: [(heading: Heading, y: CGFloat)] = []
    private var marks: [(id: UInt64, change: LiveFile.Change, y: CGFloat)] = []
    /// The file whose changes `seen` holds; changes already waiting when the rail first sees it never announce
    /// themselves.
    private weak var live: LiveFile?
    private var seen: Set<UInt64> = []
    private var hovering: NSPoint?
    /// A change that landed off screen: its chip stays at the rail's end toward it until it is on screen or decided.
    private var arrival: UInt64?
    private var remeasure: Task<Void, Never>?
    private var items: [RailItem] = []
    private var scrolling = false
    private var settle: Timer?
    private(set) var showing = true

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        width
    }

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override var scrollerStyle: NSScroller.Style {
        didSet { updateShown() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(themeChanged), name: ThemeStore.didChange, object: nil)
        center.addObserver(self, selector: #selector(changesChanged(_:)), name: LiveFile.changesDidChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("Rail is built in code")
    }

    /// Follows `textView`'s headings, height and waiting changes.
    func attach(_ textView: EditorTextView) {
        self.textView = textView
        textView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(measureSoon), name: NSView.frameDidChangeNotification, object: textView)
        center.addObserver(self, selector: #selector(measureSoon), name: BlockMap.didParse, object: textView.styler.map)
        if let clip = (superview as? NSScrollView)?.contentView {
            center.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
        }
        updateShown()
    }

    @objc private func scrolled() {
        if arrival != nil { updateLabels() }
        scrolling = true
        updateShown()
        needsDisplay = true
        settle?.invalidate()
        settle = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scrolling = false
                self?.updateShown()
                self?.needsDisplay = true
            }
        }
    }

    /// Fades the overlay rail in or out in 200 ms; under Reduce Motion it comes and goes at once.
    private func updateShown() {
        let shown = scrollerStyle == .legacy || scrolling || hovering != nil || !waiting.isEmpty
        guard shown != showing else { return }
        showing = shown
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.current == .off ? 0 : 0.2
            animator().alphaValue = shown ? 1 : 0
        }
    }

    @objc private func themeChanged() {
        needsDisplay = true
        updateLabels()
    }

    @objc private func changesChanged(_ notification: Notification) {
        guard let textView, let live = notification.object as? LiveFile, live === textView.marks.live else { return }
        measure()
        let fresh = waiting.filter { !seen.contains($0.id) }
        seen = Set(marks.map(\.id))
        // A change that lands off screen pins its chip; one on screen has its stamp beside it.
        guard let landed = fresh.last(where: { !onScreen($0.y) }) else { return }
        arrival = landed.id
        labels.alphaValue = 0
        updateLabels()
        fadeIn()
    }

    @objc private func measureSoon() {
        remeasure?.cancel()
        remeasure = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.measure()
        }
    }

    /// Where the headings and changes sit in the text. TextKit 2 places what it has not laid out by estimate, as it
    /// sizes the view, so the rail and the bracket agree without laying out the whole note.
    private func measure() {
        guard let textView else { return }
        headings = outline(of: textView.textStorage!.mutableString, in: textView.styler.map)
        ticks = headings.map { (heading: $0, y: y(at: $0.location)) }
        let live = textView.marks.live
        marks = (live?.changes ?? [:]).filter(\.value.marked)
            .map { (id: $0.key, change: $0.value, y: y(at: $0.value.range.location)) }
            .sorted { $0.y < $1.y }
        if live !== self.live {
            self.live = live
            seen = Set(marks.map(\.id))
        }
        if let arrival, !marks.contains(where: { $0.id == arrival }) { self.arrival = nil }
        needsDisplay = true
        updateLabels()
        updateAccessibility()
    }

    /// The top of the line holding `index`, in the text view.
    private func y(at index: Int) -> CGFloat {
        guard let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager else { return 0 }
        let length = textView.textStorage!.length
        let index = min(max(index, 0), max(length - 1, 0))
        if let location = content.location(content.documentRange.location, offsetBy: index),
            let fragment = layout.textLayoutFragment(for: location)
        {
            return textView.textContainerOrigin.y + fragment.layoutFragmentFrame.minY
        }
        return CGFloat(index) / CGFloat(max(length, 1)) * textView.bounds.height
    }

    /// Whether a line whose top is at `y` in the text is on screen.
    private func onScreen(_ y: CGFloat) -> Bool {
        guard let visible = textView?.visibleRect else { return false }
        return (visible.minY...visible.maxY).contains(y)
    }

    /// The rail's y for a y in the text: the whole note maps onto the hairline.
    private func railY(_ y: CGFloat) -> CGFloat {
        let slot = rect(for: .knobSlot)
        let fraction = min(max(y / max(textView?.bounds.height ?? 1, 1), 0), 1)
        return isFlipped ? slot.minY + slot.height * fraction : slot.maxY - slot.height * fraction
    }

    // MARK: Parts

    /// The slot is the hairline's length, and the knob sits in it as the visible part sits in the note.
    override func rect(for part: NSScroller.Part) -> NSRect {
        switch part {
        case .knobSlot:
            return bounds.insetBy(dx: 0, dy: Self.inset)
        case .knob:
            guard usableParts == .allScrollerParts else { return .zero }
            let slot = rect(for: .knobSlot)
            let height = min(max((slot.height * knobProportion).rounded(), 16), slot.height)
            let travel = (slot.height - height) * CGFloat(doubleValue)
            return NSRect(x: 0, y: isFlipped ? slot.minY + travel : slot.maxY - height - travel, width: bounds.width, height: height)
        default:
            return super.rect(for: part)
        }
    }

    private func markRect(_ y: CGFloat) -> NSRect {
        NSRect(x: Self.line - 1, y: railY(y) - 5, width: 3, height: 10)
    }

    private func tickRect(_ tick: (heading: Heading, y: CGFloat)) -> NSRect {
        let width: CGFloat = tick.heading.level == 1 ? 13 : tick.heading.level == 2 ? 9 : 5
        return NSRect(x: Self.line + 0.5 - width / 2, y: railY(tick.y) - 0.5, width: width, height: 1)
    }

    private func mark(at point: NSPoint) -> (id: UInt64, change: LiveFile.Change, y: CGFloat)? {
        marks.last { markRect($0.y).insetBy(dx: -4, dy: -2).contains(point) }
    }

    private func tick(at point: NSPoint) -> Heading? {
        ticks.first { tickRect($0).insetBy(dx: 0, dy: -4).contains(point) }?.heading
    }

    // MARK: Drawing

    private func ink(_ alpha: CGFloat, dark: CGFloat) -> NSColor {
        let appearance = effectiveAppearance
        return ThemeStore.shared.color(.ink).resolved(for: appearance).withAlphaComponent(appearance.isDark ? dark : alpha)
    }

    /// A note with no waiting changes that fits on screen draws no track.
    private var blank: Bool {
        marks.isEmpty && (!isEnabled || knobProportion >= 1)
    }

    /// The marks of changes waiting for Keep or Revert; git's uncommitted changes are not among them.
    private var waiting: [(id: UInt64, change: LiveFile.Change, y: CGFloat)] {
        marks.filter { if case .git = $0.change.origin { false } else { true } }
    }

    /// An overlay rail the note isn't scrolling and the pointer isn't on.
    private var resting: Bool {
        scrollerStyle == .overlay && !scrolling && hovering == nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !blank, !resting else {
            ThemeStore.shared.color(.paper).setFill()
            bounds.fill()
            if !blank { drawMarks(waiting) }
            return
        }
        drawKnobSlot(in: rect(for: .knobSlot), highlight: false)
        drawKnob()
        drawMarks(marks)
    }

    /// Paper, the hairline and, while the pointer is on the rail or the note scrolls, the heading ticks; while the
    /// legend shows, the ticks are ink2 like their names.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        ThemeStore.shared.color(.paper).setFill()
        bounds.fill()
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        ink(contrast ? 0.30 : 0.20, dark: contrast ? 0.30 : 0.16).setFill()
        NSRect(x: Self.line, y: slotRect.minY, width: 1, height: slotRect.height).fill()
        let legend = labels.items.contains { $0.rule == nil }
        guard legend || hovering != nil || scrolling else { return }
        (legend ? ThemeStore.shared.color(.ink2) : ink(0.52, dark: 0.40)).setFill()
        for tick in ticks { tickRect(tick).fill() }
    }

    /// The bracket: ink at 16% (28% under Increase Contrast) over the visible span, stroked 3 pt in ink at 30% (45%), its
    /// caps reaching the hairline.
    override func drawKnob() {
        let knob = usableParts == .allScrollerParts ? rect(for: .knob) : rect(for: .knobSlot)
        guard knob.height > 0 else { return }
        let fill: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.28 : 0.16
        ink(fill, dark: fill).setFill()
        NSRect(x: 3, y: knob.minY + 1.5, width: Self.line - 3, height: max(knob.height - 3, 0)).fill()
        let path = NSBezierPath()
        path.lineWidth = 3
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: Self.line, y: knob.minY + 1.5))
        path.line(to: NSPoint(x: 3, y: knob.minY + 1.5))
        path.line(to: NSPoint(x: 3, y: knob.maxY - 1.5))
        path.line(to: NSPoint(x: Self.line, y: knob.maxY - 1.5))
        let stroke: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.45 : 0.30
        ink(stroke, dark: stroke).setStroke()
        path.stroke()
    }

    /// Each change's rule in its writer's ink, ringed in paper, hollow for another app as its underline is dashed; the
    /// labeled one has a halo.
    private func drawMarks(_ marks: [(id: UInt64, change: LiveFile.Change, y: CGFloat)]) {
        let lit = hovering.flatMap { mark(at: $0) }?.id ?? arrival
        for mark in marks {
            let rect = markRect(mark.y)
            let writer = MarkWriter(mark.change.origin)
            let color = writer.color
            if mark.id == lit {
                color.withAlphaComponent(0.28).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: -4, dy: -4), xRadius: 5.5, yRadius: 5.5).fill()
            }
            ThemeStore.shared.color(.paper).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), xRadius: 3, yRadius: 3).fill()
            if writer.dashed {
                color.setStroke()
                NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 1, yRadius: 1).stroke()
            } else {
                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hovering = convert(event.locationInWindow, from: nil)
        updateLabels()
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = nil
        updateLabels()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let mark = mark(at: point) {
            reveal(mark.change)
        } else if let heading = tick(at: point) {
            jump(to: heading)
        } else {
            super.mouseDown(with: event)
        }
    }

    /// Scrolls the change to the middle of the view with the caret at it.
    private func reveal(_ change: LiveFile.Change) {
        guard let textView, let scrollView = superview as? NSScrollView else { return }
        let anchor = min(change.range.location, max(textView.textStorage!.length - 1, 0))
        textView.setSelectedRange(NSRange(location: change.range.location, length: 0))
        window?.makeFirstResponder(textView)
        textView.hold(anchor, at: scrollView.contentView.bounds.height / 2)
    }

    /// Scrolls the heading near the top of the view with the caret on it, as the outline does.
    private func jump(to heading: Heading) {
        guard let textView, heading.location < textView.textStorage!.length else { return }
        textView.setSelectedRange(NSRange(location: heading.location, length: 0))
        window?.makeFirstResponder(textView)
        textView.hold(heading.location, at: 56)
    }

    // MARK: Labels

    /// "Claude" and "Error codes", or the line when no heading comes before the change.
    private func spoken(_ mark: (id: UInt64, change: LiveFile.Change, y: CGFloat)) -> (writer: String, place: String, time: String) {
        let writer = MarkWriter(mark.change.origin).name
        let place = headings.last { $0.location <= mark.change.range.location }?.title
            ?? textView?.marks.live.map { "line \($0.line(mark.id))" } ?? "the note"
        let time = (textView?.marks.landed[mark.id] ?? .now).formatted(date: .omitted, time: .shortened)
        return (writer, place, time)
    }

    /// The label for an off-screen change: a chevron toward it, `lead` with its heading ("Claude Code changed Steps" at a
    /// hovered mark, "1 more below · Steps" on the chip), the time if any, and Next or Previous Change's keys:
    /// "⌄ Claude Code changed Steps  16:09  ⌃⌘↓". It fits `width` by cutting the heading's middle; nil when even a short
    /// heading is wider.
    private static func label(_ lead: (String) -> String, place: String, time: String?, keys: String, width: CGFloat, below: Bool) -> NSAttributedString? {
        let store = ThemeStore.shared
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        func text(_ place: String) -> NSAttributedString {
            let text = NSMutableAttributedString()
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold).applying(NSImage.SymbolConfiguration(paletteColors: [store.color(.ink2)]))
            if let chevron = NSImage(systemSymbolName: below ? "chevron.down" : "chevron.up", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let attachment = NSTextAttachment()
                attachment.image = chevron
                attachment.bounds = NSRect(x: 0, y: ((font.capHeight - chevron.size.height) / 2).rounded(), width: chevron.size.width, height: chevron.size.height)
                text.append(NSAttributedString(attachment: attachment))
                text.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            text.append(NSAttributedString(string: lead(place), attributes: [.font: font, .foregroundColor: store.color(.ink)]))
            if let time {
                text.append(NSAttributedString(string: "  " + time, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: store.color(.ink2)]))
            }
            text.append(NSAttributedString(string: "  " + keys, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: store.color(.ink)]))
            return text
        }
        let characters = Array(place)
        for kept in stride(from: characters.count, through: min(characters.count, 6), by: -1) {
            let cut = kept == characters.count ? place : String(characters.prefix((kept + 1) / 2)) + "\u{2026}" + String(characters.suffix(kept / 2))
            let shown = text(cut)
            if shown.size().width <= width { return shown }
        }
        return nil
    }

    /// A label at the hovered mark when its change is off screen, else the chip for the change that landed off screen
    /// (while the Changes pane is closed), in the margin right of the text column; else every tick's name while the
    /// pointer is on a rail that draws.
    private func updateLabels() {
        defer {
            needsDisplay = true
            updateShown()
        }
        guard labels.superview != nil, let textView else { return labels.items = [] }
        let right = convert(NSPoint(x: bounds.minX - 8, y: 0), to: labels).x
        func center(_ y: CGFloat) -> CGFloat {
            convert(NSPoint(x: 0, y: railY(y)), to: labels).y
        }
        let hovered = hovering.flatMap { mark(at: $0) }
        // The hovered mark lights its change in the page: a halo on its margin rules, its wash from 15% to 28%.
        textView.marks.lit = hovered?.id
        if let landed = marks.first(where: { $0.id == arrival }), onScreen(landed.y) { arrival = nil }
        let reviewing = (textView.window?.windowController as? MainWindowController)?.showsChanges == true
        if let mark = hovered ?? (reviewing ? nil : marks.first(where: { $0.id == arrival })) {
            guard !onScreen(mark.y) else { return labels.items = [] }
            let (writer, place, time) = spoken(mark)
            let visible = textView.visibleRect
            let below = mark.y > visible.maxY
            let keys = below ? "\u{2303}\u{2318}\u{2193}" : "\u{2303}\u{2318}\u{2191}"
            // The pill's 8 pt sides, its 9 pt rule and 8 pt clear of the text column.
            let column = textView.textContainerOrigin.x + (textView.textContainer.map { $0.column - $0.lineFragmentPadding } ?? 0)
            let width = right - textView.convert(NSPoint(x: column, y: 0), to: labels).x - 8 - 25
            let text = if hovered != nil {
                Self.label({ "\(writer) changed \($0)" }, place: place, time: time, keys: keys, width: width, below: below)
            } else {
                Self.label({ "\(beyond(below: below)) more \(below ? "below" : "above") \u{00B7} \($0)" }, place: place, time: nil, keys: keys, width: width, below: below)
            }
            // The pill sits at the rail's end toward its change, 12 pt in.
            let (top, bottom) = (center(0), center(textView.bounds.height))
            let inward: CGFloat = top < bottom ? 12 : -12
            let pinned = hovered != nil ? center(mark.y) : below ? bottom - inward : top + inward
            labels.items = text.map { [RailLabels.Item(text: $0, center: pinned, right: right, rule: MarkWriter(mark.change.origin).color)] } ?? []
        } else if hovering != nil, !blank {
            // Where names would overlap, the higher heading keeps its name.
            var taken: [CGFloat] = []
            labels.items = ticks.sorted { $0.heading.level < $1.heading.level }.compactMap { tick in
                let y = center(tick.y)
                guard !taken.contains(where: { abs($0 - y) < 18 }) else { return nil }
                taken.append(y)
                let text = NSAttributedString(string: tick.heading.title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: ThemeStore.shared.color(.ink2)])
                return RailLabels.Item(text: text, center: y, right: right, rule: nil)
            }
        } else {
            labels.items = []
        }
    }

    /// How many waiting changes sit below the view, or above it.
    private func beyond(below: Bool) -> Int {
        guard let visible = textView?.visibleRect else { return 0 }
        return waiting.count { below ? $0.y > visible.maxY : $0.y < visible.minY }
    }

    /// The chip fades in in 150 ms; under Reduce Motion it comes at once.
    private func fadeIn() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.current == .off ? 0 : 0.15
            labels.animator().alphaValue = 1
        }
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + items
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateAccessibility()
    }

    /// A button per tick, "Heading: Endpoints", and per mark, "Claude changed Endpoints, 15:25".
    private func updateAccessibility() {
        let headings = ticks.map { tick in
            RailItem(self, "Heading: \(tick.heading.title)", tickRect(tick).insetBy(dx: 0, dy: -4)) { [weak self] in self?.jump(to: tick.heading) }
        }
        let changes = marks.map { mark in
            let (writer, place, time) = spoken(mark)
            return RailItem(self, "\(writer) changed \(place), \(time)", markRect(mark.y)) { [weak self] in self?.reveal(mark.change) }
        }
        items = headings + changes
    }
}

/// A tick or mark as VoiceOver reaches it: a button that does what a click does.
private final class RailItem: NSAccessibilityElement {
    private let press: () -> Void

    init(_ parent: NSView, _ label: String, _ frame: NSRect, press: @escaping () -> Void) {
        self.press = press
        super.init()
        setAccessibilityParent(parent)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityFrameInParentSpace(frame)
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}

/// The rail's labels, over the page left of the rail: a change's writer, place and time at its mark, or each tick's
/// heading. It never takes a click.
final class RailLabels: NSView {
    struct Item {
        let text: NSAttributedString
        /// The label's vertical center and right edge, in this view.
        let center: CGFloat
        let right: CGFloat
        /// A change's writer ink; nil for a heading's name.
        let rule: NSColor?
    }

    var items: [Item] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let store = ThemeStore.shared
        for item in items {
            let size = item.text.size()
            let boxed = item.rule != nil
            let padding: CGFloat = boxed ? 8 : 6
            let rule: CGFloat = boxed ? 3 + 6 : 0
            let height: CGFloat = boxed ? 22 : 18
            let width = (padding * 2 + rule + size.width).rounded(.up)
            let frame = NSRect(x: item.right - width, y: (item.center - height / 2).rounded(), width: width, height: height)
            let radius: CGFloat = boxed ? 6 : 4
            let box = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
            NSGraphicsContext.saveGraphicsState()
            if boxed {
                let shadow = NSShadow()
                shadow.shadowOffset = NSSize(width: 0, height: -2)
                shadow.shadowBlurRadius = 6
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.08)
                shadow.set()
            }
            store.color(.paper).setFill()
            box.fill()
            NSGraphicsContext.restoreGraphicsState()
            if let color = item.rule {
                store.color(.rule).setStroke()
                let edge = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
                edge.lineWidth = 1
                edge.stroke()
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: frame.minX + padding, y: item.center - 6, width: 3, height: 12), xRadius: 1.5, yRadius: 1.5).fill()
            }
            item.text.draw(at: NSPoint(x: frame.minX + padding + rule, y: item.center - size.height / 2))
        }
    }
}
