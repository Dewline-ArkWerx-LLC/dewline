import AppKit
import MdCore

/// A writer's four channels (D21): hue, underline style, small-caps stamp and spoken label.
struct MarkWriter: Equatable {
    let name: String
    let writer: Writer
    /// Unknown app's underline is dashed, so the mark holds without its color.
    var dashed: Bool { writer == .unknown }

    init(_ origin: ChangeEngine.Origin) {
        (name, writer) = switch origin {
        case .agent(.claude, _): ("Claude", .claude)
        case .agent(.codex, _): ("Codex", .codex)
        case .agent(.cursor, _): ("Cursor", .cursor)
        case .agent(.demo, _): ("Demo", .demo)
        case .agent(.acp, let session): (String(session.prefix { $0 != "#" }), .demo)
        case .collaborator(_, let name): (name, .collaborator)
        case .git: ("git", .git)
        case .external: ("Another app", .unknown)
        case .user: ("You", .you)
        }
    }

    /// The writer's hue in Settings > Agents (Collaboration for a collaborator), under the view's appearance.
    @MainActor var color: NSColor {
        ThemeStore.shared.writerColor(writer)
    }

    /// "Claude's"; "the other" for another app.
    var possessive: String {
        dashed ? "the other" : "\(name)'s"
    }

    /// The name as the margin stamp sets it, SF Mono capitals in the writer's ink: CLAUDE, GIT.
    @MainActor var stamp: NSAttributedString {
        NSAttributedString(string: name.uppercased(), attributes: [.font: Chrome.mono(10.5, weight: .semibold), .foregroundColor: color, .kern: 0.84])
    }

    /// "Claude changed 2 places".
    func spoken(places: Int) -> String {
        "\(name) changed \(places) \(places == 1 ? "place" : "places")"
    }
}

/// Paints marked changes over the text at render time, never as text edits: a wash in the writer's hue under
/// inserted text with an underline in the writer's style, a 3 pt rule in the writer's ink beside each changed row in
/// the left margin, joined by a 1 pt line across the rows between, and the writer's name and time on hover. The
/// focused change carries a `ChangeStamp` with Revert and Keep, in the margin or folded under its block. Short
/// removed text reads inline at its deletion point as a struck ghost, in a gap the styler opens just before the
/// change; longer removed text and a conflict's other version hang under the paragraph, in space the styler reserves
/// below it. The marks sit under the text; ghosts and cards sit over it.
@MainActor
final class ChangeMarks: NSView, NSViewToolTipOwner {
    weak var textView: EditorTextView? {
        didSet {
            NotificationCenter.default.removeObserver(self, name: NSTextStorage.didProcessEditingNotification, object: nil)
            guard let storage = textView?.textStorage else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(storageEdited), name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
    }
    /// Keep, Revert and the card's choices go through the engine here.
    weak var live: LiveFile?
    private var changes: [UInt64: LiveFile.Change] = [:]
    /// The ranges each marked change painted at the last layout, by change.
    private(set) var painted: [UInt64: NSRange] = [:]
    /// When each marked change's fade began.
    private var shown: [UInt64: CFTimeInterval] = [:]
    /// When each marked change landed here, for its tooltip.
    private(set) var landed: [UInt64: Date] = [:]
    /// Ghosts and cards by change, with the offset of the character whose paragraph they hang under.
    private(set) var hangers: [UInt64: (anchor: Int, view: NSView)] = [:]
    private var tips: [(rect: NSRect, change: UInt64)] = []
    /// The change whose mark the pointer is on in the rail: its rules get a halo and its wash deepens.
    var lit: UInt64? {
        didSet {
            guard lit != oldValue, !changes.isEmpty else { return }
            dirty = true
            textView?.needsLayout = true
        }
    }
    /// The last change the caret was in.
    private var focus: UInt64?
    private var stamp: ChangeStamp?
    /// Where the folded stamp hangs.
    private var fold: Fold?
    /// The height the text view keeps to hold a folded stamp below the note's last line, else 0.
    private(set) var reach: CGFloat = 0
    private var dirty = false
    private var observing: NSView?

    static let fade: CFTimeInterval = 0.2
    private static let gap: CGFloat = 6
    /// From the margin rule's left edge to the text column.
    private static let ruleInset: CGFloat = 17

    /// The folded stamp's place: in space reserved after `target`'s paragraph, or before it (`before`) when the block
    /// holding `change`, which ends at `last`, is drawn and takes no space after it, or below the text (`end`) when
    /// the note ends there: the layout drops space after the last paragraph.
    private struct Fold: Equatable {
        let change: UInt64
        let last: Int
        let target: Int
        let before: Bool
        var end = false
    }

    override var isFlipped: Bool { true }

    /// The margin labels come and go with the width.
    override func setFrameSize(_ newSize: NSSize) {
        let widened = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widened, !changes.isEmpty {
            dirty = true
            textView?.needsLayout = true
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.actions = ["sublayers": NSNull()]
        return layer
    }

    /// The change engine's pending changes, as the buffer has them now.
    func update(_ changes: [UInt64: LiveFile.Change]) {
        let marked = changes.filter(\.value.marked)
        guard !(marked.isEmpty && self.changes.isEmpty) else { return }
        let now = CACurrentMediaTime()
        shown = shown.filter { marked[$0.key] != nil }
        for id in marked.keys where shown[id] == nil { shown[id] = now }
        landed = landed.filter { marked[$0.key] != nil }
        for id in marked.keys where landed[id] == nil { landed[id] = .now }
        self.changes = marked
        updateHangers()
        dirty = true
        textView?.needsLayout = true
    }

    /// Any edit, typing or styling, moves the lines the marks sit on: they lay out again on the text's next layout
    /// pass, from the fragments that pass makes.
    @objc private func storageEdited() {
        guard !changes.isEmpty else { return }
        dirty = true
        textView?.needsLayout = true
    }

    // MARK: Hangers

    /// Whether `view` is a ghost that reads inline.
    private static func isInline(_ view: NSView) -> Bool {
        (view as? Ghost)?.inlineWidth != nil
    }

    private func updateHangers() {
        guard let textView else { return }
        let text = textView.textStorage!.mutableString
        let length = text.length
        // Each hanger's anchor under its paragraph, and for removed text the character before the deletion point when
        // that is on the same line: an inline ghost's gap opens after it.
        var wanted: [UInt64: (hang: Int, inline: Int?)] = [:]
        for (id, change) in changes where change.conflict || !change.removed.isEmpty {
            let end = change.range.length > 0 ? NSMaxRange(change.range) - 1 : change.range.location - 1
            let at = change.range.location
            let inline = !change.conflict && at > 0 && at <= length && ![0x0A, 0x0D].contains(text.character(at: at - 1)) ? at - 1 : nil
            wanted[id] = (min(max(end, 0), max(length - 1, 0)), inline)
        }
        var touched: [Int] = []
        for (id, hanger) in hangers where wanted[id].map({ Self.isInline(hanger.view) && $0.inline == nil }) ?? true {
            hanger.view.removeFromSuperview()
            hangers[id] = nil
            touched.append(hanger.anchor)
        }
        for (id, want) in wanted {
            if let hanger = hangers[id] {
                let anchor = Self.isInline(hanger.view) ? want.inline ?? want.hang : want.hang
                if hanger.anchor != anchor { hangers[id] = (anchor, hanger.view) }
                continue
            }
            let change = changes[id]!
            let view: NSView = change.conflict
                ? ConflictCard(MarkWriter(change.origin), theirs: change.theirs) { [weak self] decision in
                    self?.live?.decide(id, decision)
                }
                : Ghost(change.removed, writer: MarkWriter(change.origin), inlineUpTo: want.inline == nil ? 0 : columnWidth * 0.6)
            let anchor = Self.isInline(view) ? want.inline ?? want.hang : want.hang
            textView.addSubview(view)
            hangers[id] = (anchor, view)
            touched.append(anchor)
        }
        guard !touched.isEmpty else { return }
        measureHangers()
        reserve(touched)
    }

    /// Has the styler reserve space under the paragraphs holding `anchors` on the run loop's next pass, outside the
    /// storage edit or layout that asked, then lays the marks out again.
    private func reserve(_ anchors: [Int]) {
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let textView = self.textView else { return }
                let text = textView.textStorage!.mutableString
                for anchor in anchors where anchor < text.length {
                    textView.styler.restyleNow(text.paragraphRange(for: NSRange(location: anchor, length: 0)))
                }
                self.dirty = true
                textView.needsLayout = true
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private var columnWidth: CGFloat {
        guard let textView, let container = textView.textContainer else { return 0 }
        return container.size.width - 2 * container.lineFragmentPadding
    }

    private func measureHangers() {
        let width = columnWidth
        for hanger in hangers.values where hanger.view.frame.width != width && !Self.isInline(hanger.view) {
            hanger.view.setFrameSize(NSSize(width: width, height: (hanger.view as? Hanging)?.height(for: width) ?? 0))
        }
    }

    /// Space to reserve under the paragraphs holding these offsets, or above them (`before`), for the styler.
    func space(in range: NSRange) -> [(anchor: Int, height: CGFloat, before: Bool)] {
        var space = hangers.values.filter { NSLocationInRange($0.anchor, range) && !Self.isInline($0.view) }
            .map { ($0.anchor, $0.view.frame.height + 2 * Self.gap, false) }
        if let fold, !fold.end, NSLocationInRange(fold.target, range) { space.append((fold.target, ChangeStamp.barHeight + 2 * Self.gap, fold.before)) }
        return space
    }

    /// Gaps to open after these offsets for inline ghosts, for the styler.
    func gaps(in range: NSRange) -> [(after: Int, width: CGFloat)] {
        hangers.values.filter { NSLocationInRange($0.anchor, range) }.compactMap { hanger in
            (hanger.view as? Ghost)?.inlineWidth.map { (hanger.anchor, $0) }
        }
    }

    // MARK: Layout

    /// Lays the marks out again after the text's layout when something changed.
    func layoutIfDirty() {
        guard dirty else { return }
        relayout()
    }

    func relayout() {
        dirty = false
        guard let textView, let layer else { return }
        if frame != textView.bounds { frame = textView.bounds }
        let heights = hangers.mapValues(\.view.frame.height)
        measureHangers()
        let resized = hangers.filter { heights[$0.key] != $0.value.view.frame.height }.map(\.value.anchor)
        if !resized.isEmpty { reserve(resized) }
        removeAllToolTips()
        tips = []
        painted = [:]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayers = nil
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let dark = effectiveAppearance.isDark
        let wash = contrast ? (dark ? 0.30 : 0.22) : (dark ? 0.24 : 0.15)
        let rule: CGFloat = contrast ? 3 : 2
        let ruleWidth: CGFloat = contrast ? 4 : 3
        let left = textView.textContainerOrigin.x + (textView.textContainer?.lineFragmentPadding ?? 0)
        let now = CACurrentMediaTime()
        let motion = Motion.current != .off
        let storage = textView.textStorage!
        var hung: [UInt64: CGFloat] = [:]
        var ruled: [(key: String, rules: [NSRect], color: NSColor)] = []
        // Hangers under one paragraph stack in change order; each change in it anchors at its own offset.
        func paragraph(_ anchor: Int) -> NSRange {
            storage.mutableString.paragraphRange(for: NSRange(location: min(anchor, storage.length), length: 0))
        }
        for (id, hanger) in hangers.sorted(by: { $0.key < $1.key }) {
            if let ghost = hanger.view as? Ghost, let width = ghost.inlineWidth {
                // The gap is the end of the anchor character's kern, right before what replaced the removed text.
                // TextKit 2 splits a kern between the segments on either side of it, so the gap is measured from
                // the anchor's own glyph rather than from a segment edge.
                guard hanger.anchor < storage.length, let gap = segments(NSRange(location: hanger.anchor, length: 1)).first else { continue }
                let glyph = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: NSRange(location: hanger.anchor, length: 1)))
                let kern = glyph.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat ?? 0
                glyph.removeAttribute(.kern, range: NSRange(location: 0, length: 1))
                ghost.frame.origin = NSPoint(x: gap.frame.minX + glyph.size().width + kern - width, y: gap.frame.minY + gap.baseline - ghost.ascent)
                continue
            }
            guard let top = textBottom(at: hanger.anchor) else { continue }
            let stacked = hangers.filter { $0.key < id && !Self.isInline($0.value.view) && paragraph($0.value.anchor) == paragraph(hanger.anchor) }
                .map { $0.value.view.frame.height + Self.gap }
            let y = top + Self.gap + stacked.reduce(0, +)
            hanger.view.frame.origin = NSPoint(x: left, y: y)
            hung[id] = y + hanger.view.frame.height
        }
        for (id, change) in changes where NSMaxRange(change.range) <= storage.length {
            let writer = MarkWriter(change.origin)
            let color = writer.color.resolved(for: effectiveAppearance)
            let group = CALayer()
            let lines = segments(change.range)
            var rows = Self.rows(lines, in: storage.mutableString)
            if rows.isEmpty, let line = lineRect(at: change.range.location) { rows = [line] }
            if let bottom = hung[id], let last = rows.last { rows[rows.count - 1].size.height = bottom - last.minY }
            guard !rows.isEmpty else { continue }
            if !change.conflict {
                painted[id] = change.range
                // A table row that draws its cells hides its source, so the wash goes on the drawn cells instead.
                let drawn = drawnCells(change.range)
                for cell in drawn.cells {
                    let fill = CALayer()
                    fill.frame = cell
                    fill.backgroundColor = color.withAlphaComponent(id == lit ? wash + 0.13 : wash).cgColor
                    group.addSublayer(fill)
                    tips.append((cell, id))
                }
                for line in lines where line.frame.width >= 0.5 && !drawn.rows.contains(where: { NSLocationInRange(line.location, $0) }) {
                    let fill = CALayer()
                    fill.frame = line.frame
                    fill.backgroundColor = color.withAlphaComponent(id == lit ? wash + 0.13 : wash).cgColor
                    group.addSublayer(fill)
                    let underline = CAShapeLayer()
                    let y = line.frame.minY + line.baseline + rule + 1
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: line.frame.minX, y: y))
                    path.addLine(to: CGPoint(x: line.frame.maxX, y: y))
                    underline.path = path
                    underline.strokeColor = color.cgColor
                    underline.lineWidth = rule
                    if writer.dashed { underline.lineDashPattern = [4, 3] }
                    group.addSublayer(underline)
                    tips.append((line.frame, id))
                }
            }
            // A rule per row; a 1 pt line at 35% joins the rows across what lies between them.
            let x = max(left - Self.ruleInset, 4)
            let rules = rows.map { NSRect(x: x, y: $0.minY + 2, width: ruleWidth, height: max($0.height - 4, 4)) }
            if !change.conflict { ruled.append((Review.key(change.origin), rules, color)) }
            for (above, below) in zip(rules, rules.dropFirst()) where below.minY > above.maxY {
                let join = CALayer()
                join.frame = NSRect(x: x + (ruleWidth - 1) / 2, y: above.maxY, width: 1, height: below.minY - above.maxY)
                join.backgroundColor = color.withAlphaComponent(0.35).cgColor
                group.addSublayer(join)
            }
            for frame in rules {
                if id == lit {
                    let halo = CALayer()
                    halo.frame = frame.insetBy(dx: -2.5, dy: -2.5)
                    halo.cornerRadius = halo.frame.width / 2
                    halo.backgroundColor = color.withAlphaComponent(0.28).cgColor
                    group.addSublayer(halo)
                }
                let mark = CALayer()
                mark.frame = frame
                mark.cornerRadius = ruleWidth / 2
                mark.backgroundColor = color.cgColor
                group.addSublayer(mark)
                tips.append((frame.insetBy(dx: -6, dy: 0), id))
            }
            if motion, let start = shown[id], now - start < Self.fade {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = Self.fade
                fade.beginTime = start
                fade.fillMode = .backwards
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                group.add(fade, forKey: "fade")
            }
            layer.addSublayer(group)
        }
        // One writer's changes read as one: the same 1 pt line joins a change's last rule to the next change's first
        // when only a few lines lie between them.
        let near = ThemeStore.shared.bodyFont.pointSize * ThemeStore.shared.lineHeight * 3
        for writer in Dictionary(grouping: ruled, by: \.key).values {
            let spans = writer.filter { !$0.rules.isEmpty }.sorted { $0.rules[0].minY < $1.rules[0].minY }
            for (above, below) in zip(spans, spans.dropFirst()) {
                let (top, bottom) = (above.rules.last!.maxY, below.rules[0].minY)
                guard bottom > top, bottom - top <= near else { continue }
                let join = CALayer()
                join.frame = NSRect(x: below.rules[0].minX + (ruleWidth - 1) / 2, y: top, width: 1, height: bottom - top)
                join.backgroundColor = above.color.withAlphaComponent(0.35).cgColor
                layer.addSublayer(join)
            }
        }
        CATransaction.commit()
        for tip in tips { addToolTip(tip.rect, owner: self, userData: nil) }
        placeStamp(left: left, hung: hung)
    }

    private struct Segment {
        let frame: NSRect
        let baseline: CGFloat
        /// The segment's first character.
        let location: Int
    }

    /// The rows a change's segments fill, one per paragraph, from its first line to its last.
    private static func rows(_ segments: [Segment], in text: NSString) -> [NSRect] {
        var rows: [(paragraph: Int, rect: NSRect)] = []
        for segment in segments.sorted(by: { $0.frame.minY < $1.frame.minY }) where segment.frame.width >= 0.5 {
            let paragraph = text.paragraphRange(for: NSRange(location: min(segment.location, text.length), length: 0)).location
            if let last = rows.last, last.paragraph == paragraph {
                rows[rows.count - 1].rect = last.rect.union(segment.frame)
            } else {
                rows.append((paragraph, segment.frame))
            }
        }
        return rows.map(\.rect)
    }

    /// The drawn cells `range` changes in table rows that draw their cells, in this view's coordinates, and those rows'
    /// paragraphs.
    private func drawnCells(_ range: NSRange) -> (cells: [NSRect], rows: [NSRange]) {
        guard let textView, range.length > 0 else { return ([], []) }
        let storage = textView.textStorage!
        let text = storage.mutableString
        var cells: [NSRect] = []
        var rows: [NSRange] = []
        var at = range.location
        while at < min(NSMaxRange(range), storage.length) {
            let paragraph = text.paragraphRange(for: NSRange(location: at, length: 0))
            defer { at = NSMaxRange(paragraph) }
            guard let line = storage.attribute(.dewlineBlock, at: paragraph.location, effectiveRange: nil) as? BlockLine,
                case .table(let rule) = line.role, !rule.cells.isEmpty,
                let fragment = fragment(at: paragraph.location) as? BlockFragment
            else { continue }
            rows.append(paragraph)
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            for cell in rule.cells where NSIntersectionRange(NSRange(location: paragraph.location + cell.source.location, length: cell.source.length), range).length > 0 {
                cells.append(NSRect(x: frame.minX + fragment.textStart + cell.x, y: frame.minY, width: cell.width, height: frame.height))
            }
        }
        return (cells, rows)
    }

    /// The first baseline of a table row that draws its cells, and its line height: its hidden source sits on the
    /// row's last line.
    private func drawnBaseline(at index: Int) -> (first: CGFloat, line: CGFloat)? {
        guard let textView, index < textView.textStorage!.length,
            let block = textView.textStorage!.attribute(.dewlineBlock, at: index, effectiveRange: nil) as? BlockLine,
            case .table(let rule) = block.role, let cell = rule.cells.first, cell.text.length > 0,
            let fragment = fragment(at: index) as? BlockFragment
        else { return nil }
        let font = cell.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? ThemeStore.shared.bodyFont
        let style = cell.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let line = max(style?.minimumLineHeight ?? 0, ceil(font.ascender - font.descender + font.leading))
        // A line taller than its font puts the extra space above the glyphs.
        return (textView.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line + font.descender, line)
    }

    /// The range's line segments in this view's coordinates.
    private func segments(_ range: NSRange) -> [Segment] {
        guard range.length > 0, let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager,
            let start = content.location(content.documentRange.location, offsetBy: range.location),
            let end = content.location(start, offsetBy: range.length), let textRange = NSTextRange(location: start, end: end)
        else { return [] }
        layout.ensureLayout(for: textRange)
        let origin = textView.textContainerOrigin
        var segments: [Segment] = []
        layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { segment, frame, baseline, _ in
            let location = segment.map { content.offset(from: content.documentRange.location, to: $0.location) } ?? range.location
            segments.append(Segment(frame: frame.offsetBy(dx: origin.x, dy: origin.y), baseline: baseline, location: location))
            return true
        }
        return segments
    }

    private func fragment(at index: Int) -> NSTextLayoutFragment? {
        guard let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager,
            let location = content.location(content.documentRange.location, offsetBy: index)
        else { return nil }
        layout.ensureLayout(for: NSTextRange(location: location))
        return layout.textLayoutFragment(for: location)
    }

    /// The bottom of the text of the paragraph holding `index`, above any space reserved under it.
    private func textBottom(at index: Int) -> CGFloat? {
        guard let textView, let fragment = fragment(at: index) else { return nil }
        let bottom = fragment.textLineFragments.last?.typographicBounds.maxY ?? fragment.layoutFragmentFrame.height
        return textView.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + bottom
    }

    private func lineRect(at index: Int) -> NSRect? {
        guard let textView, let storage = textView.textStorage, storage.length > 0 else { return nil }
        let index = min(max(index, 0), storage.length - 1)
        guard let fragment = fragment(at: index), let content = textView.textLayoutManager?.textContentManager,
            let location = content.location(content.documentRange.location, offsetBy: index)
        else { return nil }
        let offset = content.offset(from: fragment.rangeInElement.location, to: location)
        let line = fragment.textLineFragments.first { NSLocationInRange(offset, $0.characterRange) } ?? fragment.textLineFragments.last
        guard let line else { return nil }
        let frame = fragment.layoutFragmentFrame
        return line.typographicBounds.offsetBy(dx: frame.minX + textView.textContainerOrigin.x, dy: frame.minY + textView.textContainerOrigin.y)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let tip = tips.first(where: { $0.rect.contains(point) }), let change = changes[tip.change] else { return "" }
        let time = (landed[tip.change] ?? .now).formatted(date: .omitted, time: .shortened)
        if change.conflict { return "\(MarkWriter(change.origin).name) \u{00B7} two versions" }
        return "\(MarkWriter(change.origin).name) \u{00B7} \(time)" + (change.origin == .external && change.shell ? " \u{00B7} \(ChangeStamp.duringShell)" : "")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if !changes.isEmpty { relayout() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let clip = enclosingScrollView?.contentView
        guard clip !== observing else { return }
        if let observing { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observing) }
        observing = clip
        if let clip {
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    /// TextKit 2 replaces its estimates as it lays out the text it scrolls to, so marks off screen move with them.
    @objc private func scrolled() {
        if !changes.isEmpty { relayout() }
    }

    // MARK: The change under the caret

    /// The marked change holding the caret, a conflict first.
    var changeAtCaret: UInt64? {
        guard let caret = textView?.selectedRanges.first?.rangeValue.location else { return nil }
        let holding = changes.filter { NSLocationInRange(caret, $0.value.range) || caret == NSMaxRange($0.value.range) }
        return holding.first { $0.value.conflict }?.key ?? holding.keys.min()
    }

    /// The change the stamp shows, which Keep and Revert decide when the caret is in no change: the one holding the
    /// caret, else the last one the caret was in while it waits, else the first in the note.
    var stamped: UInt64? {
        if let id = changeHoldingCaret { return id }
        if let focus, changes[focus]?.conflict == false { return focus }
        return changes.filter { !$0.value.conflict }.min { $0.value.range.location < $1.value.range.location }?.key
    }

    /// The changes Keep and Revert decide with `id`: every waiting change from the same writer's session in the note,
    /// which the stamp counts; a conflict alone.
    func group(of id: UInt64) -> [UInt64] {
        guard let change = changes[id], !change.conflict else { return [id] }
        let key = Review.key(change.origin)
        return changes.filter { !$0.value.conflict && Review.key($0.value.origin) == key }.map(\.key)
    }

    private var changeHoldingCaret: UInt64? {
        guard let caret = textView?.selectedRanges.first?.rangeValue.location else { return nil }
        return changes.filter { !$0.value.conflict && (NSLocationInRange(caret, $0.value.range) || caret == NSMaxRange($0.value.range)) }.keys.min()
    }

    /// The caret moved: a change it lands in takes the stamp.
    func caretMoved() {
        guard let id = changeHoldingCaret, id != focus else { return }
        focus = id
        dirty = true
        textView?.needsLayout = true
    }

    // MARK: The stamp

    private func placeStamp(left: CGFloat, hung: [UInt64: CGFloat]) {
        guard let textView, let id = stamped, let change = changes[id], NSMaxRange(change.range) <= textView.textStorage!.length else {
            stamp?.removeFromSuperview()
            stamp = nil
            setFold(nil)
            setReach(0)
            return
        }
        let stamp = self.stamp ?? {
            let stamp = ChangeStamp(revert: { [weak self] in self.map { $0.decideStamped(keep: false) } }, keep: { [weak self] in self.map { $0.decideStamped(keep: true) } })
            stamp.resized = { [weak self] in
                guard let self else { return }
                self.dirty = true
                self.textView?.needsLayout = true
            }
            textView.addSubview(stamp)
            self.stamp = stamp
            return stamp
        }()
        let group = group(of: id)
        let external = change.origin == .external
        stamp.show(
            MarkWriter(change.origin), at: landed[id] ?? .now, count: group.count, external: external, shell: external && change.shell,
            refused: group.contains { changes[$0]?.refused == true })
        if left >= stamp.marginWidth + ChangeStamp.inset + ChangeStamp.gutter {
            setFold(nil)
            setReach(0)
            let storage = textView.textStorage!
            let probe = change.range.length > 0 ? change.range
                : NSRange(location: min(change.range.location, max(storage.length - 1, 0)), length: storage.length > 0 ? 1 : 0)
            let lines = segments(probe).sorted { $0.frame.minY < $1.frame.minY }
            guard let first = lines.first else { return stamp.isHidden = true }
            stamp.isHidden = false
            let line = ThemeStore.shared.bodyFont.pointSize * ThemeStore.shared.lineHeight
            if let row = drawnBaseline(at: first.location) {
                return stamp.placeInMargin(right: left - ChangeStamp.inset, first: row.first, second: row.first + row.line)
            }
            let top = first.frame.minY + first.baseline
            let next = lines.first { $0.frame.minY >= first.frame.maxY - 0.5 }
            stamp.placeInMargin(right: left - ChangeStamp.inset, first: top, second: next.map { $0.frame.minY + $0.baseline } ?? top + line)
        } else {
            let fold = fold(for: id, change)
            setFold(fold)
            let y: CGFloat? = if fold.before {
                self.fragment(at: fold.target).map { textView.textContainerOrigin.y + $0.layoutFragmentFrame.minY }
            } else {
                textBottom(at: fold.last).map { bottom in
                    let paragraph = textView.textStorage!.mutableString.paragraphRange(for: NSRange(location: fold.last, length: 0))
                    let under = hangers.filter { !Self.isInline($0.value.view) && NSLocationInRange($0.value.anchor, paragraph) }.compactMap { hung[$0.key] }
                    return under.max() ?? bottom
                }
            }
            guard let y else { return stamp.isHidden = true }
            stamp.isHidden = false
            stamp.placeAsBar(NSRect(x: left, y: y + Self.gap, width: columnWidth, height: ChangeStamp.barHeight))
            setReach(fold.end ? stamp.frame.maxY + Self.gap + textView.textContainerInset.height : 0)
        }
    }

    /// The text view sizes itself to its text on the run loop's next pass, outside the layout that asked, and keeps
    /// at least `reach`.
    private func setReach(_ reach: CGFloat) {
        guard reach != self.reach else { return }
        self.reach = reach
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let textView = self.textView else { return }
                // sizeToFit leaves a view that already fits its text alone, so a taller reach sets the size itself.
                if self.reach > textView.frame.height { textView.setFrameSize(textView.frame.size) } else { textView.sizeToFit() }
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Under the block holding the change: after its last paragraph, or before the next paragraph not drawn as a block
    /// when the last one is drawn (a table row, a rendered fence) and takes no space after it.
    private func fold(for id: UInt64, _ change: LiveFile.Change) -> Fold {
        let storage = textView!.textStorage!
        let text = storage.mutableString
        let end = textView!.styler.map.blocks(in: change.range).last.map { NSMaxRange($0.range) } ?? NSMaxRange(text.paragraphRange(for: change.range))
        let last = min(max(end - 1, 0), max(text.length - 1, 0))
        let paragraph = text.paragraphRange(for: NSRange(location: last, length: 0))
        func drawn(_ paragraph: NSRange) -> Bool {
            paragraph.length > 0 && storage.attribute(.dewlineBlock, at: paragraph.location, effectiveRange: nil) != nil
        }
        guard drawn(paragraph) else { return Fold(change: id, last: last, target: last, before: false, end: NSMaxRange(paragraph) >= text.length) }
        var next = NSMaxRange(paragraph)
        while next < text.length, drawn(text.paragraphRange(for: NSRange(location: next, length: 0))) {
            next = NSMaxRange(text.paragraphRange(for: NSRange(location: next, length: 0)))
        }
        return Fold(change: id, last: last, target: min(next, max(text.length - 1, 0)), before: next < text.length, end: next >= text.length)
    }

    private func setFold(_ fold: Fold?) {
        guard fold != self.fold else { return }
        let old = self.fold
        self.fold = fold
        reserve([old?.target, fold?.target].compactMap { $0 })
    }

    private func decideStamped(keep: Bool) {
        guard let id = stamped else { return }
        live?.decide(group(of: id), keep: keep)
    }

    /// One announcement per marked landing.
    func announce(_ origin: ChangeEngine.Origin, places: Int) {
        guard let textView, places > 0 else { return }
        NSAccessibility.post(element: textView, notification: .announcementRequested, userInfo: [
            .announcement: MarkWriter(origin).spoken(places: places),
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

extension NSColor {
    /// The color as `appearance` draws it.
    func resolved(for appearance: NSAppearance) -> NSColor {
        var resolved = self
        appearance.performAsCurrentDrawingAppearance { resolved = NSColor(cgColor: self.cgColor) ?? self }
        return resolved
    }
}
