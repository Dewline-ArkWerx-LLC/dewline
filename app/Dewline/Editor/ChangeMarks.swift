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
        case .agent(.claude, _): ("Claude Code", .claude)
        case .agent(.codex, _): ("Codex", .codex)
        case .agent(.cursor, _): ("Cursor", .cursor)
        case .agent(.demo, _): ("Demo agent", .demo)
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

    /// The name as the margin stamp sets it, small capitals in the writer's ink: CLAUDE CODE, GIT.
    @MainActor var stamp: NSAttributedString {
        NSAttributedString(string: name, attributes: [.font: Self.stampFont, .foregroundColor: color, .kern: 0.4])
    }

    /// SF Pro semibold at the stamp's text size, with both cases set as small capitals.
    @MainActor static var stampFont: NSFont {
        let size = ChangeStamp.textSize
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [
            [NSFontDescriptor.FeatureKey.typeIdentifier: kUpperCaseType, .selectorIdentifier: kUpperCaseSmallCapsSelector],
            [NSFontDescriptor.FeatureKey.typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector],
        ]])
        return NSFont(descriptor: descriptor, size: size) ?? font
    }

    /// "Claude changed 2 places".
    func spoken(places: Int) -> String {
        "\(name) changed \(places) \(places == 1 ? "place" : "places")"
    }
}

/// Paints marked changes over the text at render time, never as text edits: a wash in the writer's hue under
/// inserted text with an underline in the writer's style, one 3 pt rule in the writer's ink beside the changed rows in
/// the left margin, and the writer's name and time on hover. Each writer session carries a `ChangeStamp` in the
/// margin, on its focused or first change, with Revert and Keep on the stamped change's alone until the pointer is on
/// another; a margin too narrow for the compact stamp folds the focused change's stamp under its block. Short removed text reads inline at its deletion point as a struck ghost, in a gap the styler opens just before the
/// change; longer removed text and a conflict's other version hang under the paragraph, in space the styler reserves
/// below it. The marks sit under the text; ghosts and cards sit over it.
@MainActor
final class ChangeMarks: NSView, NSViewToolTipOwner {
    weak var textView: EditorTextView? {
        didSet {
            NotificationCenter.default.removeObserver(self, name: NSTextStorage.didProcessEditingNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: LiveFile.changesDidChange, object: nil)
            // A decision in another tab moves the stamp's count.
            NotificationCenter.default.addObserver(self, selector: #selector(storageEdited), name: LiveFile.changesDidChange, object: nil)
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
    /// The stamps by writer session, each with the change it sits on.
    private var stamps: [String: (view: ChangeStamp, change: UInt64)] = [:]
    /// Where the folded stamp hangs.
    private var fold: Fold?
    /// The height the text view keeps to hold a folded stamp below the note's last line, else 0.
    private(set) var reach: CGFloat = 0
    private var dirty = false
    private var observing: NSView?
    /// The inline ghosts were taken out for a new width: they come back once their gaps close.
    private var remeasuring = false
    /// The "Reverted" receipts showing in the margin.
    private(set) var receipts: [NSTextField] = []

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

    /// The margin labels come and go with the width, and an inline ghost is measured again against its line.
    override func setFrameSize(_ newSize: NSSize) {
        let widened = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widened, !changes.isEmpty {
            dirty = true
            textView?.needsLayout = true
            remeasureInline()
        }
    }

    /// Takes out the inline ghosts and, once the styler has closed their gaps, places them again, inline only where
    /// each still fits the rest of its line.
    private func remeasureInline() {
        let inline = hangers.filter { Self.isInline($0.value.view) }
        guard !inline.isEmpty else { return }
        for (id, hanger) in inline {
            hanger.view.removeFromSuperview()
            hangers[id] = nil
        }
        remeasuring = true
        reserve(inline.map(\.value.anchor))
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

    /// Any edit, typing or styling, moves the lines the marks sit on, and a decision anywhere in the window moves the
    /// stamp's count: they lay out again on the text's next layout pass, from the fragments that pass makes.
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
        // Each hanger's anchor under its paragraph, its ghost's parts, and for removed text the character before the
        // deletion point when that is on the same line: an inline ghost's gap opens after it.
        var wanted: [UInt64: (hang: Int, inline: Int?, parts: [(text: String, struck: Bool)]?)] = [:]
        let rewrites = rewrites(in: text)
        for rewrite in rewrites { wanted[rewrite.key] = (rewrite.hang, nil, rewrite.parts) }
        let rewritten = Set(rewrites.flatMap(\.members))
        // Removed blanks strike nothing visible, and a gap for them would move the line: a ticked box's space.
        for (id, change) in changes where !rewritten.contains(id) && (change.conflict || !change.removed.allSatisfy(\.isWhitespace)) {
            let end = change.range.length > 0 ? NSMaxRange(change.range) - 1 : change.range.location - 1
            let at = change.range.location
            let inline = !change.conflict && at > 0 && at <= length && ![0x0A, 0x0D].contains(text.character(at: at - 1)) ? at - 1 : nil
            wanted[id] = (min(max(end, 0), max(length - 1, 0)), inline, change.conflict ? nil : [(change.removed, true)])
        }
        var touched: [Int] = []
        for (id, hanger) in hangers {
            let ghost = hanger.view as? Ghost
            if let want = wanted[id], !(Self.isInline(hanger.view) && want.inline == nil),
                ghost?.shown == want.parts.map({ Ghost.shown($0) }) { continue }
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
            let view: NSView = if let parts = want.parts {
                ghost(parts, for: change, inline: want.inline)
            } else {
                ConflictCard(MarkWriter(change.origin), theirs: change.theirs) { [weak self] decision in
                    self?.live?.decide(id, decision)
                }
            }
            let anchor = Self.isInline(view) ? want.inline ?? want.hang : want.hang
            textView.addSubview(view)
            hangers[id] = (anchor, view)
            touched.append(anchor)
        }
        guard !touched.isEmpty else { return }
        measureHangers()
        reserve(touched)
    }

    /// A ghost of `change`'s removed `parts`: inline after the character at `inline` when its gap fits the rest of that
    /// line, spaced from a word on either side, else hanging.
    private func ghost(_ parts: [(text: String, struck: Bool)], for change: LiveFile.Change, inline: Int?) -> Ghost {
        let writer = MarkWriter(change.origin)
        if let textView, code {
            let base = textView.styler.baseAttributes
            return Ghost(
                parts, writer: writer, inlineUpTo: 0, font: base[.font] as? NSFont ?? ThemeStore.shared.bodyFont,
                style: base[.paragraphStyle] as? NSParagraphStyle ?? .default)
        }
        guard let inline, let text = textView?.textStorage?.mutableString else { return Ghost(parts, writer: writer, inlineUpTo: 0) }
        func word(_ character: unichar) -> Bool {
            Unicode.Scalar(character).map { CharacterSet.alphanumerics.contains($0) } ?? false
        }
        let removed = change.removed as NSString
        let at = change.range.location
        let spaced = (
            before: removed.length > 0 && word(text.character(at: inline)) && word(removed.character(at: 0)),
            after: removed.length > 0 && at < text.length && word(removed.character(at: removed.length - 1)) && word(text.character(at: at))
        )
        return Ghost(parts, writer: writer, inlineUpTo: min(room(after: inline), columnWidth * 0.6), spaced: spaced)
    }

    /// The width left on the line after the character at `anchor`, less the text after it up to the next blank, which a
    /// gap there carries along: a wider gap would push the word before it onto the next line.
    private func room(after anchor: Int) -> CGFloat {
        guard let textView, let segment = segments(NSRange(location: anchor, length: 1)).first else { return 0 }
        let storage = textView.textStorage!
        var end = anchor + 1
        while end < storage.length, !Self.isBlank(storage.mutableString.character(at: end)) { end += 1 }
        let carried = storage.attributedSubstring(from: NSRange(location: anchor + 1, length: end - anchor - 1)).size().width
        let right = textView.textContainerOrigin.x + (textView.textContainer?.lineFragmentPadding ?? 0) + columnWidth
        return right - segment.frame.maxX - carried
    }

    /// Changes that rewrite more than one line, or more than three runs in one paragraph, read as one, since gaps for
    /// so many ghosts would move each other: their paragraphs' old text hangs under them, struck where it was removed,
    /// under the first change's key. In a code file every removal reads this way, its old lines set above the new
    /// ones from their first line's start, as a diff does.
    private func rewrites(in text: NSString) -> [(key: UInt64, members: [UInt64], hang: Int, parts: [(text: String, struck: Bool)])] {
        let code = code
        var regions: [(range: NSRange, members: [(id: UInt64, change: LiveFile.Change)])] = []
        let shown = changes.filter { !$0.value.conflict && NSMaxRange($0.value.range) <= text.length }
        for (id, change) in shown.sorted(by: { $0.value.range.location < $1.value.range.location }) {
            let at = change.range.location
            // Whole lines taken out between two lines are their own region, holding no line of the text.
            let between = code && change.range.length == 0 && (at == 0 || [0x0A, 0x0D].contains(text.character(at: at - 1)))
            let paragraphs = between ? NSRange(location: at, length: 0) : text.paragraphRange(for: change.range)
            if let last = regions.last, paragraphs.location < NSMaxRange(last.range) {
                regions[regions.count - 1].range = NSUnionRange(last.range, paragraphs)
                regions[regions.count - 1].members.append((id, change))
            } else {
                regions.append((paragraphs, [(id, change)]))
            }
        }
        return regions.compactMap { region in
            let removing = region.members.filter { !$0.change.removed.allSatisfy(\.isWhitespace) }.count
            let lines = region.members.contains { $0.change.removed.contains(where: \.isNewline) || text.substring(with: $0.change.range).contains(where: \.isNewline) }
            guard code ? removing > 0 : removing > 1 && (lines || removing > 3) else { return nil }
            var parts: [(text: String, struck: Bool)] = []
            var at = region.range.location
            for (_, change) in region.members {
                if change.range.location > at { parts.append((text.substring(with: NSRange(location: at, length: change.range.location - at)), false)) }
                if !change.removed.isEmpty { parts.append((change.removed, true)) }
                at = max(at, NSMaxRange(change.range))
            }
            if NSMaxRange(region.range) > at { parts.append((text.substring(with: NSRange(location: at, length: NSMaxRange(region.range) - at)), false)) }
            let hang = min(max(code ? region.range.location : NSMaxRange(region.range) - 1, 0), max(text.length - 1, 0))
            return (region.members[0].id, region.members.map(\.id), hang, parts)
        }
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
                if self.remeasuring {
                    self.remeasuring = false
                    self.updateHangers()
                }
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Whether the text is a code file's.
    private var code: Bool {
        textView?.styler.code != nil
    }

    private var columnWidth: CGFloat {
        guard let textView, let container = textView.textContainer else { return 0 }
        return container.column - 2 * container.lineFragmentPadding
    }

    private func measureHangers() {
        for hanger in hangers.values where !Self.isInline(hanger.view) {
            // A code file's column has no end: its old lines take their own width.
            let width = code ? (hanger.view as? Ghost)?.naturalWidth ?? columnWidth : columnWidth
            guard hanger.view.frame.width != width else { continue }
            hanger.view.setFrameSize(NSSize(width: width, height: (hanger.view as? Hanging)?.height(for: width) ?? 0))
        }
    }

    /// Space to reserve under the paragraphs holding these offsets, or above them (`before`), for the styler.
    func space(in range: NSRange) -> [(anchor: Int, height: CGFloat, before: Bool)] {
        let code = code
        var space = hangers.values.filter { NSLocationInRange($0.anchor, range) && !Self.isInline($0.view) }
            .map { code && $0.view is Ghost ? ($0.anchor, $0.view.frame.height, true) : ($0.anchor, $0.view.frame.height + 2 * Self.gap, false) }
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
        // A named writer's text takes a solid underline as well as its wash only for those who need more than hue.
        let underlined = contrast || NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
        let current = stamped
        let left = textView.textContainerOrigin.x + (textView.textContainer?.lineFragmentPadding ?? 0)
        let now = CACurrentMediaTime()
        let motion = Motion.current != .off
        let storage = textView.textStorage!
        var hung: [UInt64: CGFloat] = [:]
        var above: [UInt64: CGFloat] = [:]
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
                ghost.frame.origin = NSPoint(x: gap.frame.minX + glyph.size().width + kern - width + ghost.lead, y: gap.frame.minY + gap.baseline - ghost.ascent)
                continue
            }
            // A code file's old lines sit above the lines that replaced them, in the space before their first line.
            if code, hanger.view is Ghost {
                guard let fragment = fragment(at: hanger.anchor) else { continue }
                let y = textView.textContainerOrigin.y + fragment.layoutFragmentFrame.minY
                hanger.view.frame.origin = NSPoint(x: left, y: y)
                above[id] = y
                continue
            }
            guard let top = textBottom(at: hanger.anchor) else { continue }
            let stacked = hangers.filter { $0.key < id && !Self.isInline($0.value.view) && paragraph($0.value.anchor) == paragraph(hanger.anchor) }
                .map { $0.value.view.frame.height + Self.gap }
            let y = top + Self.gap + stacked.reduce(0, +)
            hanger.view.frame.origin = NSPoint(x: left, y: y)
            hung[id] = y + hanger.view.frame.height
        }
        // Rules already drawn: a change whose rule runs beside an earlier one's takes a tick at its first line.
        var drawn: [NSRect] = []
        for (id, change) in changes.sorted(by: { $0.value.range.location < $1.value.range.location }) where NSMaxRange(change.range) <= storage.length {
            let writer = MarkWriter(change.origin)
            let color = writer.color.resolved(for: effectiveAppearance)
            let group = CALayer()
            let lines = segments(change.range)
            var rows = Self.rows(lines, in: storage.mutableString)
            if rows.isEmpty, let line = lineRect(at: change.range.location) { rows = [line] }
            if let bottom = hung[id], let last = rows.last { rows[rows.count - 1].size.height = bottom - last.minY }
            if let top = above[id], let first = rows.first, top < first.minY {
                rows[0] = NSRect(x: first.minX, y: top, width: first.width, height: first.maxY - top)
            }
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
                let trim = trimmed(lines)
                for line in trim where line.frame.width >= 0.5 && !drawn.rows.contains(where: { NSLocationInRange(line.location, $0) }) {
                    let fill = CALayer()
                    // A change within one line takes 2 pt either side, so a one-letter wash reads as a mark.
                    fill.frame = trim.count == 1 ? line.frame.insetBy(dx: -2, dy: 0) : line.frame
                    fill.backgroundColor = color.withAlphaComponent(id == lit ? wash + 0.13 : wash).cgColor
                    group.addSublayer(fill)
                    // Dashed for another app, always; a solid 1 pt line at 35% ink for a named writer, which no
                    // spelling or grammar flag looks like, under Differentiate Without Color or Increase Contrast.
                    guard writer.dashed || underlined else {
                        tips.append((line.frame, id))
                        continue
                    }
                    let underline = CAShapeLayer()
                    let width = writer.dashed ? rule : 1
                    let y = line.frame.minY + line.baseline + (writer.dashed ? rule + 1 : 2.5)
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: line.frame.minX, y: y))
                    path.addLine(to: CGPoint(x: line.frame.maxX, y: y))
                    underline.path = path
                    underline.strokeColor = writer.dashed ? color.cgColor : color.withAlphaComponent(0.35).cgColor
                    underline.lineWidth = width
                    if writer.dashed { underline.lineDashPattern = [4, 3] }
                    group.addSublayer(underline)
                    tips.append((line.frame, id))
                }
            }
            // One rule from the change's first row to its last; in a quote, the quote's rule in the writer's ink.
            let x = quoted(change.range.location) ? left : max(left - Self.ruleInset, 4)
            let span = rows.dropFirst().reduce(rows[0]) { $0.union($1) }
            // The change Keep and Revert decide takes a rule a point heavier.
            let width = id == current ? ruleWidth + 1 : ruleWidth
            let rules = [NSRect(x: x, y: span.minY + 2, width: width, height: max(span.height - 4, 4))]
            if !change.conflict { ruled.append((Review.key(change.origin), rules, color)) }
            if drawn.contains(where: { $0.minY < rules[0].maxY && rules[0].minY < $0.maxY }) {
                let tick = CALayer()
                tick.frame = NSRect(x: x - 6, y: (rows[0].midY - 0.75).rounded(), width: 4, height: 1.5)
                tick.backgroundColor = color.cgColor
                group.addSublayer(tick)
            }
            drawn += rules
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
                mark.cornerRadius = width / 2
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
                guard bottom > top, bottom - top <= near, above.rules[0].minX == below.rules[0].minX else { continue }
                let join = CALayer()
                join.frame = NSRect(x: below.rules[0].minX + (ruleWidth - 1) / 2, y: top, width: 1, height: bottom - top)
                join.backgroundColor = above.color.withAlphaComponent(0.35).cgColor
                layer.addSublayer(join)
            }
        }
        CATransaction.commit()
        for tip in tips { addToolTip(tip.rect, owner: self, userData: nil) }
        placeStamp(left: left, hung: hung)
        // A code file's ruler marks the old and new lines.
        if code { textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true }
    }

    private struct Segment {
        let frame: NSRect
        let baseline: CGFloat
        /// The segment's first character.
        let location: Int
        let length: Int
    }

    /// Whether the text at `index` sits in a quote that draws its rule at the column's left edge.
    private func quoted(_ index: Int) -> Bool {
        guard let textView, !textView.styler.showsSource, index < textView.textStorage!.length else { return false }
        let storage = textView.textStorage!
        return storage.attribute(.dewlineQuote, at: index, effectiveRange: nil) != nil
            && storage.attribute(.dewlineCallout, at: index, effectiveRange: nil) == nil
    }

    /// `segments` without the blanks at either end of each, which a wash or underline would show as a nub.
    private func trimmed(_ segments: [Segment]) -> [Segment] {
        guard let text = textView?.textStorage?.mutableString else { return segments }
        return segments.flatMap { segment -> [Segment] in
            var (start, end) = (segment.location, min(segment.location + segment.length, text.length))
            while start < end, Self.isBlank(text.character(at: start)) { start += 1 }
            while end > start, Self.isBlank(text.character(at: end - 1)) { end -= 1 }
            if start == segment.location && end == segment.location + segment.length { return [segment] }
            return start < end ? self.segments(NSRange(location: start, length: end - start)) : []
        }
    }

    private static func isBlank(_ character: unichar) -> Bool {
        [0x20, 0x09, 0x0A, 0x0D, 0xA0].contains(character)
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
            let length = segment.map { content.offset(from: $0.location, to: $0.endLocation) } ?? range.length
            segments.append(Segment(frame: frame.offsetBy(dx: origin.x, dy: origin.y), baseline: baseline, location: location, length: length))
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

    /// The changes the stamp counts with `id`: every waiting change from the same writer's session in the note; a
    /// conflict alone.
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
            for stamp in stamps.values { stamp.view.removeFromSuperview() }
            stamps = [:]
            setFold(nil)
            setReach(0)
            return
        }
        // One stamp per writer session: on the stamped change for its session, else on the session's first change.
        let length = textView.textStorage!.length
        var shown = [Review.key(change.origin): id]
        for (other, change) in changes.sorted(by: { $0.value.range.location < $1.value.range.location })
        where !change.conflict && NSMaxRange(change.range) <= length && shown[Review.key(change.origin)] == nil {
            shown[Review.key(change.origin)] = other
        }
        for (key, stamp) in stamps where shown[key] == nil {
            stamp.view.removeFromSuperview()
            stamps[key] = nil
        }
        for (key, id) in shown { show(key, id) }
        let primary = stamps[Review.key(change.origin)]!.view
        if left >= stamps.values.map(\.view.marginWidth).max()! + ChangeStamp.inset + ChangeStamp.gutter {
            setFold(nil)
            setReach(0)
            // Stamps that would collide stack 8 pt apart.
            var bottom = -CGFloat.infinity
            for (key, id) in shown.sorted(by: { changes[$0.value]!.range.location < changes[$1.value]!.range.location }) {
                let stamp = stamps[key]!.view
                guard let (first, second) = baselines(of: changes[id]!.range) else {
                    stamp.isHidden = true
                    continue
                }
                stamp.isHidden = false
                stamp.placeInMargin(right: left - ChangeStamp.inset, first: first, second: second)
                let shift = bottom + 8 - stamp.frame.minY
                if shift > 0 { stamp.placeInMargin(right: left - ChangeStamp.inset, first: first + shift, second: second + shift) }
                bottom = stamp.frame.maxY
            }
        } else {
            // A narrow margin holds one stamp, folded under the stamped change's block.
            for stamp in stamps.values where stamp.view !== primary { stamp.view.isHidden = true }
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
            guard let y else { return primary.isHidden = true }
            primary.isHidden = false
            // A code file's column has no end: the bar ends at the view's.
            let width = code ? min(columnWidth, max(textView.visibleRect.maxX - left - 16, 0)) : columnWidth
            primary.placeAsBar(NSRect(x: left, y: y + Self.gap, width: width, height: ChangeStamp.barHeight))
            setReach(fold.end ? primary.frame.maxY + Self.gap + textView.textContainerInset.height : 0)
        }
    }

    /// Shows the stamp for writer session `key` on change `id`, making it the first time.
    private func show(_ key: String, _ id: UInt64) {
        guard let textView, let change = changes[id] else { return }
        let stamp = stamps[key]?.view ?? {
            let stamp = ChangeStamp(revert: { [weak self] in self?.decideStamp(key, keep: false) }, keep: { [weak self] in self?.decideStamp(key, keep: true) })
            stamp.resized = { [weak self] in
                guard let self else { return }
                self.dirty = true
                self.textView?.needsLayout = true
            }
            textView.addSubview(stamp)
            return stamp
        }()
        stamps[key] = (stamp, id)
        let group = group(of: id)
        let external = change.origin == .external
        let place = live.map { Review.place(of: id, in: $0, window: textView.window) } ?? (index: 1, total: changes.count)
        let numbers = textView.enclosingScrollView?.verticalRulerView as? LineNumbers
        stamp.show(
            MarkWriter(change.origin), at: landed[id] ?? .now, index: place.index, of: place.total, external: external,
            shell: external && change.shell, refused: group.contains { changes[$0]?.refused == true },
            error: group.lazy.compactMap { self.changes[$0].flatMap { numbers?.error(in: $0.range) } }.first)
    }

    /// A stamp's first and second text baselines in the margin, beside the change in `range`.
    private func baselines(of range: NSRange) -> (first: CGFloat, second: CGFloat)? {
        let storage = textView!.textStorage!
        let probe = range.length > 0 ? range : NSRange(location: min(range.location, max(storage.length - 1, 0)), length: storage.length > 0 ? 1 : 0)
        let lines = segments(probe).sorted { $0.frame.minY < $1.frame.minY }
        guard let first = lines.first else { return nil }
        if let row = drawnBaseline(at: first.location) { return (row.first, row.first + row.line) }
        let top = first.frame.minY + first.baseline
        let next = lines.first { $0.frame.minY >= first.frame.maxY - 0.5 }
        return (top, next.map { $0.frame.minY + $0.baseline } ?? top + ThemeStore.shared.bodyFont.pointSize * ThemeStore.shared.lineHeight)
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

    /// The marks lay out again, as after an edit: the typesetting errors the stamp shows changed.
    func refresh() {
        storageEdited()
    }

    /// "Reverted · ⌘Z" for 4 s where the margin stamp on `id` stood, before the revert takes it away.
    func reverted(_ id: UInt64) {
        guard let textView, let stamp = stamps.values.first(where: { $0.change == id && !$0.view.isHidden && !$0.view.folded })?.view else { return }
        let receipt = NSTextField(labelWithString: "Reverted \u{00B7} \u{2318}Z")
        receipt.font = .systemFont(ofSize: ChangeStamp.textSize)
        receipt.textColor = ThemeStore.shared.color(.ink2)
        let size = receipt.fittingSize
        receipt.frame = NSRect(x: stamp.frame.maxX - size.width, y: stamp.frame.minY, width: size.width, height: size.height)
        receipt.wantsLayer = true
        textView.addSubview(receipt)
        receipts.append(receipt)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak receipt] in
            MainActor.assumeIsolated {
                guard let receipt else { return }
                self?.receipts.removeAll { $0 === receipt }
                guard Motion.current != .off else { return receipt.removeFromSuperview() }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.fade
                    receipt.animator().alphaValue = 0
                } completionHandler: {
                    MainActor.assumeIsolated { receipt.removeFromSuperview() }
                }
            }
        }
    }

    /// In a code file, each ghost's old lines, set above the line that starts at `at`, with the lines the changes
    /// above it added, which their old numbers lack; and the ranges the changes wrote.
    var diff: (removed: [(at: Int, lines: Int, added: Int)], written: [NSRange]) {
        guard code, let text = textView?.textStorage?.mutableString else { return ([], []) }
        func breaks(_ string: String) -> Int {
            string.reduce(0) { $1.isNewline ? $0 + 1 : $0 }
        }
        let shown = changes.values.filter { !$0.conflict && NSMaxRange($0.range) <= text.length }
        let removed = hangers.compactMap { id, hanger -> (at: Int, lines: Int, added: Int)? in
            guard let ghost = hanger.view as? Ghost, changes[id] != nil else { return nil }
            let at = text.paragraphRange(for: NSRange(location: hanger.anchor, length: 0)).location
            let added = shown.filter { NSMaxRange($0.range) <= at }.reduce(0) { $0 + breaks(text.substring(with: $1.range)) - breaks($1.removed) }
            return (at, breaks(ghost.shown) + 1, added)
        }
        return (removed, shown.filter { $0.range.length > 0 }.map(\.range))
    }

    private func decideStamp(_ key: String, keep: Bool) {
        guard let id = stamps[key]?.change else { return }
        textView?.decide(id, keep: keep)
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
