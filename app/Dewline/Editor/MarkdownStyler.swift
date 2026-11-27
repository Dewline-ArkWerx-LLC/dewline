import AppKit
import MdCore

/// Styles markdown through attributes only and owns the editor's undo history.
@MainActor
final class MarkdownStyler: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    weak var textView: EditorTextView? {
        didSet {
            cards.textView = textView
            hover?.removeFromSuperview()
            hover = textView.map { LinkHover(textView: $0) }
            if let hover { textView?.addSubview(hover) }
        }
    }
    let undoManager = UndoManager()
    let map: BlockMap
    let blocks: RenderedBlocks
    let highlights = CodeHighlights()
    let tables: Tables
    let tasks: TaskBoxes
    let fences: CodeFences
    let math: InlineMath
    let cards: LinkCards
    private(set) var hover: LinkHover?
    private(set) var restyles = 0
    /// The paragraphs the last restyle styled.
    private(set) var restyled = NSRange()
    private(set) var showsSource = false
    /// A code file's language: the whole text is code, in SF Mono and highlighted, and nothing styles as Markdown.
    var code: String? {
        didSet { map.isCode = code != nil }
    }
    /// Source line height: 22 pt, or prose's 24 pt pitch through `DewlineSourceLineHeight`, until the owner picks one.
    var sourceLineHeight: CGFloat = {
        let height = UserDefaults.standard.double(forKey: "DewlineSourceLineHeight")
        return height > 0 ? height : 22
    }()
    private var revealed: Set<SyntaxSpan> = []
    /// The empty line Return made, laid out as the line typing there will make, until it gains a character, Return
    /// moves on from it or the caret leaves it.
    var fresh: Int?
    /// Paragraph styles with space above them, by style and amount.
    private var spacedStyles: [NSParagraphStyle: [CGFloat: NSParagraphStyle]] = [:]
    /// Paragraph styles as a body line that continues them, by style.
    private var continuedStyles: [NSParagraphStyle: NSParagraphStyle] = [:]
    private var pending: NSRange?
    /// Where the caret lands after the edit `shouldChangeText` approved, until the storage processes that edit.
    var landing: Int?
    /// The characters the storage's current edit changed, before AppKit fixes attributes around them and widens the
    /// range `didProcessEditing` gets, as far as the whole paragraph.
    private var edit = NSRange()
    /// Text not styled yet, whole paragraphs, which `styleSome` works through from the top of the view.
    private var unstyled = IndexSet()
    private var scheduled = false
    /// The text the next later pass styles: what the last one would have styled in `passTime` at its rate. Each pass
    /// also lays the view out again, so on a fast Mac few long passes style a long text sooner than many short ones.
    private var passLength = MarkdownStyler.pass
    /// The line a restored place put at the top of the view, until the text is all styled. The place was measured on
    /// styled text, so `styleSome` holds this line while it shows.
    var restored: Int?
    /// The text folded blocks hide, in text order, each from the line after its block's first line. A heading's fold
    /// holds the folds of the blocks under it.
    private(set) var folds: [NSRange] = []

    var hasUnstyledText: Bool {
        !unstyled.isEmpty
    }

    static var bodyFont: NSFont {
        ThemeStore.shared.bodyFont
    }

    static let hiddenFont = NSFont.systemFont(ofSize: 0.01)
    /// A hidden marker's attributes, built once: a Swift dictionary bridges again on every write.
    private static let hiddenMarker = NSDictionary(
        objects: [hiddenFont, NSColor.clear], forKeys: [NSAttributedString.Key.font.rawValue as NSString, NSAttributedString.Key.foregroundColor.rawValue as NSString]
    )
    /// The attributes styling owns; restyling leaves every other attribute in the storage as it is.
    private static let keys = [
        NSAttributedString.Key.font, .foregroundColor, .backgroundColor, .paragraphStyle, .underlineStyle, .underlineColor, .strikethroughStyle, .kern, .toolTip,
        .dewlineMarkerFont, .dewlineBlock, .dewlineQuote, .baselineOffset, .dewlineCallout, .dewlineCode, .dewlineMath, .dewlineCodeChip,
        .dewlineHang, .dewlineRule, .dewlineListMarker, .dewlineSkip,
    ].map { $0.rawValue as NSString }
    /// The text a long restyle styles at once, which covers the view: several screens.
    private static let chunk = BlockMap.screen
    /// The text the first later pass styles while more waits, and the least a later one aims for.
    private static let pass = chunk / 2
    /// How long one later pass styles while more waits, so the pass and the display after it fit in a 120 Hz frame.
    private static let passTime = Duration.milliseconds(6)
    private static var base: [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: ThemeStore.shared.color(.ink),
            .paragraphStyle: ThemeStore.shared.paragraphStyle(lineHeight: ThemeStore.shared.bodyLineHeight),
            .underlineStyle: 0,
            .strikethroughStyle: 0,
        ]
    }

    /// The Code font slot at `font`'s x-height.
    static func code(matching font: NSFont) -> NSFont {
        let store = ThemeStore.shared
        return store.codeFont(size: font.pointSize * font.xHeight / store.codeFont(size: font.pointSize).xHeight)
    }

    override init() {
        let map = BlockMap()
        self.map = map
        blocks = RenderedBlocks(map: map)
        tables = Tables(map: map)
        tasks = TaskBoxes(map: map)
        fences = CodeFences(map: map)
        math = InlineMath(map: map)
        cards = LinkCards(map: map)
        super.init()
        map.merged = { [weak self] changed in self?.restyleLater(changed) }
        for name in [NSNotification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(undid), name: name, object: undoManager)
        }
    }

    /// Undo and redo set the selection after their edit, often to where it was, and then no selection change corrects
    /// the reveal their restyle guessed.
    @objc private func undid(_ notification: Notification) {
        guard textView?.defersStyling == false else { return }
        updateReveal()
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        if code != nil {
            // SF Mono at the body's x-height, a tab four of its spaces wide.
            let body = Self.bodyFont
            let size = body.pointSize * body.xHeight / NSFont.monospacedSystemFont(ofSize: body.pointSize, weight: .regular).xHeight
            let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            let style = ThemeStore.shared.paragraphStyle(lineHeight: sourceLineHeight).mutableCopy() as! NSMutableParagraphStyle
            style.tabStops = []
            style.defaultTabInterval = NSAttributedString(string: "    ", attributes: [.font: font]).size().width
            return Self.base.merging([.font: font, .paragraphStyle: style]) { $1 }
        }
        guard showsSource else { return Self.base }
        // TextKit 2 sets a fixed-height line's baseline its font's descender, to the point, above the line's bottom. A
        // Source line is as much shorter than prose's as prose's descender is deeper, so its baseline sits where prose's
        // does, and the rest of its pitch comes after it.
        let body = Self.bodyFont, font = Self.code(matching: body)
        let height = ThemeStore.shared.bodyLineHeight - (-body.descender).rounded() + (-font.descender).rounded()
        let style = ThemeStore.shared.paragraphStyle(lineHeight: height).mutableCopy() as! NSMutableParagraphStyle
        style.lineSpacing = sourceLineHeight - height
        return Self.base.merging([.font: font, .paragraphStyle: style]) { $1 }
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        undoManager
    }

    func textViewWritingToolsDidEnd(_ textView: NSTextView) {
        self.textView?.inputEnded?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !textView!.defersStyling else { return }
        unfoldSelection()
        updateReveal()
    }

    /// Smart quotes and dashes leave code alone.
    func textView(
        _ view: NSTextView, didCheckTextIn range: NSRange, types checkingTypes: NSTextCheckingTypes, options: [NSSpellChecker.OptionKey: Any],
        results: [NSTextCheckingResult], orthography: NSOrthography, wordCount: Int
    ) -> [NSTextCheckingResult] {
        results.filter { ![.quote, .dash].contains($0.resultType) || !isCode($0.range) }
    }

    /// Whether `range` meets a code block, front matter, math or a code span.
    func isCode(_ range: NSRange) -> Bool {
        map.literals(in: range).contains { NSIntersectionRange($0, range).length > 0 } || map.blocks(touching: range).contains { block in
            block.spans.contains { span in
                let code = span.shifted(by: block.range.location).range
                return span.kind == .inlineCode && code.location < NSMaxRange(range) && range.location < NSMaxRange(code)
            }
        }
    }

    /// Folds exactly `folds`, restyling the text whose fold changed.
    func setFolds(_ new: [NSRange]) {
        let changed = Set(folds).symmetricDifference(new)
        folds = Set(new).sorted { $0.location < $1.location }
        if let first = changed.first { restyleNow(changed.reduce(first, NSUnionRange)) }
    }

    /// The caret moving into folded text, or a selection's end landing in it, unfolds it.
    private func unfoldSelection() {
        let text = textView!.textStorage!.mutableString
        let selection = textView!.selectedRanges.map(\.rangeValue)
        let inside = { (fold: NSRange) in
            selection.contains { range in
                let end = NSMaxRange(range)
                return NSLocationInRange(range.location, fold) || (range.length > 0 && fold.location < end && end < NSMaxRange(fold))
                    // A caret at the end of a text whose last line is folded.
                    || (range.length == 0 && end == NSMaxRange(fold) && end == text.length && ![0x0A, 0x0D].contains(text.character(at: end - 1)))
            }
        }
        if folds.contains(where: inside) { setFolds(folds.filter { !inside($0) }) }
    }

    /// Spelling and grammar marks skip code, math (inline too), front matter, HTML, addresses, wikilink targets and
    /// hyphenated words.
    func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range affectedCharRange: NSRange) -> Int {
        guard value != 0 else { return value }
        let text = textView.textStorage!.mutableString
        let start = max(affectedCharRange.location - 1, 0)
        let around = NSRange(location: start, length: min(NSMaxRange(affectedCharRange) + 1, text.length) - start)
        if text.substring(with: around).contains("-") { return 0 }
        let math = map.blocks(touching: affectedCharRange).contains { block in
            block.spans.contains { $0.kind == .inlineMath && NSIntersectionRange($0.shifted(by: block.range.location).range, affectedCharRange).length > 0 }
        }
        if math { return 0 }
        return map.literals(in: affectedCharRange).contains { NSIntersectionRange($0, affectedCharRange).length > 0 } ? 0 : value
    }

    /// Writing Tools leave the same text alone.
    func textView(_ textView: NSTextView, writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange) -> [NSValue] {
        map.literals(in: enclosingRange).map { NSValue(range: NSIntersectionRange($0, enclosingRange)) }.filter { $0.rangeValue.length > 0 }
    }

    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        willProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { edit = editedRange }
    }

    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        LatencyProbe.begin(.attributes)
        defer { LatencyProbe.end(.attributes) }
        MainActor.assumeIsolated {
            textView!.storageDidEdit(editedRange, delta: delta)
            // A landing outside the edit is left from an approved edit that never came. Undo and redo come without
            // shouldChangeText and leave the caret at the end of the text they put back.
            let caret = landing.flatMap { editedRange.location <= $0 && $0 <= NSMaxRange(editedRange) ? $0 : nil }
                ?? (undoManager.isUndoing || undoManager.isRedoing ? NSMaxRange(editedRange) : nil)
            landing = nil
            let oldEnd = NSMaxRange(editedRange) - delta
            revealed = Set(revealed.compactMap { span in
                if NSMaxRange(span.range) < editedRange.location { return span }
                guard span.range.location > oldEnd else { return nil }
                return span.shifted(by: delta)
            })
            unstyled.remove(integersIn: editedRange.location..<oldEnd)
            unstyled.shift(startingAt: oldEnd, by: delta)
            let text = textView!.textStorage!.mutableString
            // The fresh line moves with the text; a line break typed at it moves it past the break, and any other edit
            // that reaches it ends it.
            if let at = fresh {
                let changedEnd = NSMaxRange(edit) - delta
                let moved = at < edit.location ? at : at > changedEnd ? at + delta
                    : edit.length > 0 && [0x0A, 0x0D].contains(text.character(at: NSMaxRange(edit) - 1)) ? NSMaxRange(edit) : nil
                fresh = moved.flatMap { at in
                    (at == 0 || [0x0A, 0x0D].contains(text.character(at: at - 1))) && (at == text.length || [0x0A, 0x0D].contains(text.character(at: at))) ? at : nil
                }
            }
            // Lines after an edit can move, and what the view draws under them (bullets, wells, chips) must move with
            // them: an agent's write lands in the storage, outside the view's own redraw. One typed character is the
            // view's.
            if delta != 1 || edit.length != 1 || [0x0A, 0x0D].contains(text.character(at: edit.location)) {
                textView!.setNeedsDisplay(textView!.visibleRect)
            }
            // An edit in folded text unfolds it; an edit before a fold moves it.
            let editEnd = NSMaxRange(edit) - delta
            var unfolded: NSRange?
            folds = folds.compactMap { fold in
                if editEnd < fold.location { return NSRange(location: fold.location + delta, length: fold.length) }
                if edit.location > NSMaxRange(fold) || (edit.location == NSMaxRange(fold) && [0x0A, 0x0D].contains(text.character(at: edit.location - 1))) {
                    return fold
                }
                let start = min(fold.location, edit.location)
                let end = NSMaxRange(fold) < editEnd ? NSMaxRange(edit) : NSMaxRange(fold) + delta
                let shown = NSRange(location: start, length: end - start)
                unfolded = unfolded.map { NSUnionRange($0, shown) } ?? shown
                return nil
            }
            // An edit whose text ends in a line break splits a paragraph, and the half after the break is a paragraph
            // the edit changed too.
            let length = textView!.textStorage!.length
            var range = NSUnionRange(editedRange, NSRange(location: edit.location, length: min(edit.length + 1, length - edit.location)))
            if let waiting = pending {
                func moved(_ offset: Int) -> Int {
                    offset < oldEnd ? min(offset, editedRange.location) : offset + delta
                }
                let start = moved(waiting.location)
                range = NSUnionRange(NSRange(location: start, length: moved(NSMaxRange(waiting)) - start), range)
            }
            LatencyProbe.begin(.parse)
            let changed = map.textDidChange(textView!.textStorage!.mutableString, edited: edit, delta: delta)
            LatencyProbe.end(.parse)
            blocks.textDidChange(edited: edit, delta: delta)
            highlights.textDidChange(edited: edit, delta: delta)
            tables.textDidChange(edited: edit, delta: delta)
            tasks.textDidChange(edited: edit, delta: delta)
            fences.textDidChange(edited: edit, delta: delta)
            math.textDidChange(edited: edit, delta: delta)
            cards.textDidChange(edited: edit, delta: delta)
            range = NSUnionRange(range, changed)
            if let unfolded { range = NSUnionRange(range, unfolded) }
            if textView!.defersStyling {
                pending = range
            } else {
                pending = nil
                // An edit made on the storage leaves the selection where it is unless the view moves it, and a move
                // updates the reveal.
                let selection = caret.map { [NSRange(location: $0, length: 0)] } ?? textView!.selectedRanges.map(\.rangeValue)
                restyleSoon(range, in: textView!.textStorage!, selection: selection)
            }
        }
    }

    func flush() {
        if let range = pending {
            pending = nil
            restyle(range)
        }
        updateReveal()
        if !unstyled.isEmpty { schedule() }
    }

    /// Switches mode and restyles the paragraphs around `range`; `restyleDocument()` brings the rest along.
    func toggleSource(restyling range: NSRange) {
        showsSource.toggle()
        restyle(range)
    }

    func restyleDocument() {
        restyle(NSRange(location: 0, length: textView!.textStorage!.length))
    }

    /// Restyles `range`, or after the composition while an input method composes.
    func restyleNow(_ range: NSRange) {
        guard !textView!.defersStyling else {
            pending = pending.map { NSUnionRange($0, range) } ?? range
            return
        }
        restyle(range)
    }

    private func restyle(_ range: NSRange) {
        let storage = textView!.textStorage!
        storage.beginEditing()
        restyle(range, in: storage, selection: textView!.selectedRanges.map(\.rangeValue))
        storage.endEditing()
    }
}

extension MarkdownStyler {
    /// Restyles `range`, unless it is long and the view is at the top of the text, as when a document opens: then its
    /// first chunk, which covers the view, is styled now and the rest by `styleSome`.
    private func restyleSoon(_ range: NSRange, in storage: NSTextStorage, selection: [NSRange]) {
        let paragraphs = storage.mutableString.paragraphRange(for: range)
        guard paragraphs.length > Self.chunk, textView!.visibleRect.minY <= 0 else {
            return restyle(paragraphs, in: storage, selection: selection)
        }
        unstyled.insert(integersIn: Range(paragraphs)!)
        restyle(NSRange(location: paragraphs.location, length: Self.chunk), in: storage, selection: selection)
        schedule()
    }

    /// Runs `styleSome` when the main run loop next goes to wait, which comes after any event in hand and before the
    /// view displays, and wakes it for the pass. Unlike a timer, the observer runs before the display that follows an
    /// event; unlike the main queue, it also runs in a run loop nested inside a main-queue job; unlike a block, which
    /// can queue another for the same turn, it runs once a frame.
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 0) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.styleSome() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Styles the next chunk of unstyled text in text order and schedules the next. Once the view is past the first
    /// unstyled character, the rest is styled in one pass: each chunk styled above the view would make TextKit 2 place
    /// the view again. That pass holds the restored line, the caret's line, or the first visible line in place, as
    /// switching to the source does.
    private func styleSome() {
        scheduled = false
        // Text past the map's blocks waits for the first whole parse, whose landing schedules this again.
        guard let textView, !textView.defersStyling, let first = unstyled.first, first < map.parsed else { return }
        let storage = textView.textStorage!
        let past = isPast(first)
        var held: (anchor: Int, offset: CGFloat)?
        if past {
            let visible = textView.visibleRect
            func index(_ x: CGFloat, _ y: CGFloat) -> Int {
                textView.characterIndexForInsertion(at: NSPoint(x: x, y: max(y, textView.textContainerOrigin.y)))
            }
            let top = index(visible.minX, visible.minY)
            let bottom = index(visible.maxX, visible.maxY)
            let line = [restored, textView.selectedRange().location].compactMap { $0 }.first { top <= $0 && $0 <= bottom }
            let anchor = min(line ?? top, storage.length - 1)
            held = textView.baseline(at: anchor).map { (anchor, $0 - visible.minY) }
        }
        let length = past ? map.parsed - first : min(unstyled.rangeView.first!.count, passLength, map.parsed - first)
        let start = ContinuousClock.now
        storage.beginEditing()
        restyle(NSRange(location: first, length: length), in: storage, selection: textView.selectedRanges.map(\.rangeValue))
        storage.endEditing()
        let took = max(ContinuousClock.now - start, .microseconds(100))
        if !past { passLength = max(Self.pass, Int(Double(length) * (Self.passTime / took))) }
        if let held { textView.hold(held.anchor, at: held.offset) }
        if unstyled.isEmpty { restored = nil } else { schedule() }
    }

    /// Whether the top of the view is past the line holding `index`, found without laying out any text.
    private func isPast(_ index: Int) -> Bool {
        let textView = textView!
        let visible = textView.visibleRect
        // TextKit 2 answers a point in the top inset with an index near the end of the text.
        return index < textView.characterIndexForInsertion(at: NSPoint(x: visible.minX, y: max(visible.minY, textView.textContainerOrigin.y)))
    }

    private func restyle(_ range: NSRange, in storage: NSTextStorage, selection: [NSRange]) {
        restyles += 1
        var paragraphs = storage.mutableString.paragraphRange(for: tables.covering(map.covering(storage.mutableString.paragraphRange(for: range))))
        // A fresh line takes its look from the text above it.
        if fresh == NSMaxRange(paragraphs) {
            paragraphs = NSUnionRange(paragraphs, storage.mutableString.paragraphRange(for: NSRange(location: NSMaxRange(paragraphs), length: 0)))
        }
        restyled = paragraphs
        unstyled.remove(integersIn: Range(paragraphs)!)
        let styled = NSMutableAttributedString(string: storage.mutableString.substring(with: paragraphs))
        let whole = NSRange(location: 0, length: styled.length)
        let source = showsSource
        let prose = !source && code == nil
        let store = ThemeStore.shared
        styled.addAttributes(baseAttributes, range: whole)
        revealed = revealed.filter { !NSLocationInRange($0.range.location, paragraphs) }
        let selection = selection.map { NSRange(location: $0.location - paragraphs.location, length: $0.length) }
        // A caret in an agent's marked change, where Next Change puts it, leaves the markers around it hidden.
        let changed = textView?.marks.painted.values.map { NSRange(location: $0.location - paragraphs.location, length: $0.length) } ?? []
        let revealing = selection.filter { caret in
            caret.length > 0 || !changed.contains { $0.location <= caret.location && caret.location <= NSMaxRange($0) }
        }
        // Markers repeat: each one's width is measured once.
        var widths: [NSAttributedString: CGFloat] = [:]
        let found = map.blocks(in: paragraphs)
        for block in found {
            let offset = block.range.location - paragraphs.location
            let lines = NSRange(location: offset, length: block.range.length)
            switch block.kind {
            case .heading where source:
                Self.add(.bold, in: lines, of: styled)
                styled.addAttribute(.foregroundColor, value: store.color(.heading), range: lines)
            case .heading(let level):
                let heading = store.heading(level)
                styled.addAttributes([
                    .font: heading.font, .paragraphStyle: store.paragraphStyle(lineHeight: heading.lineHeight),
                    .foregroundColor: store.color(level < 5 ? .heading : .ink2),
                ], range: lines)
                if heading.kern != 0 { styled.addAttribute(.kern, value: heading.kern, range: lines) }
            case .quote where !source, .callout where !source:
                styled.addAttributes([.paragraphStyle: store.quoteParagraphStyle, .foregroundColor: store.color(.heading), .dewlineQuote: true], range: lines)
                // A line holding only its markers is the quote's blank line.
                var at = lines.location
                while at < NSMaxRange(lines) {
                    let line = styled.mutableString.paragraphRange(for: NSRange(location: at, length: 0))
                    at = NSMaxRange(line)
                    if Self.isBlank(line, in: styled.mutableString, quoted: true) { styled.addAttribute(.paragraphStyle, value: store.quoteBlankParagraphStyle, range: line) }
                }
            default:
                break
            }
            Constructs.style(block, lines: lines, in: styled, source: source)
            let spans = Self.styled(block).map { $0.shifted(by: offset) }
            for span in spans {
                switch span.kind {
                case .quote where !source:
                    Self.add(.italic, in: span.content, of: styled)
                case .strong:
                    Self.add(.bold, in: span.content, of: styled)
                case .emphasis:
                    Self.add(.italic, in: span.content, of: styled)
                case .strikethrough:
                    styled.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.content)
                case .link:
                    styled.addAttributes(Links.style(of: span, in: styled.mutableString), range: span.content)
                case .inlineCode where !source:
                    // At 0.9 of the text around it, so a code span sits in the line rather than over it.
                    styled.enumerateAttribute(.font, in: span.content) { value, run, _ in
                        styled.addAttribute(.font, value: store.codeFont(size: (value as! NSFont).pointSize * 0.9), range: run)
                    }
                    styled.addAttribute(.dewlineCodeChip, value: true, range: span.range)
                default:
                    Constructs.style(span, in: styled, source: source)
                }
            }
            // Fenced code is monospaced; `highlights` colors it.
            for span in block.spans where span.kind == .fencedCode && !source {
                styled.addAttribute(.font, value: Self.code(matching: Self.bodyFont), range: NSRange(location: span.range.location + offset, length: span.range.length))
            }
            for span in spans {
                for marker in span.markers {
                    styled.addAttribute(.dewlineMarkerFont, value: styled.attribute(.font, at: marker.location, effectiveRange: nil)!, range: marker)
                }
                let reveal = Self.touches(span, revealing) || Self.hides(span, changed)
                if reveal { revealed.insert(span.shifted(by: paragraphs.location)) }
                mark(span, revealed: reveal || source, in: styled)
            }
            for hit in Links.imports(in: styled.mutableString, range: lines, at: paragraphs.location, of: block) where !source {
                styled.addAttributes(Links.style, range: hit.range)
            }
            // An item's later lines hang under its text, past its marker.
            for item in block.spans where item.kind == .item && !source {
                let item = item.shifted(by: offset)
                let paragraph = styled.mutableString.paragraphRange(for: NSRange(location: item.range.location, length: 0))
                guard item.content.location <= NSMaxRange(paragraph) else { continue }
                let style = (styled.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle ?? .default).mutableCopy() as! NSMutableParagraphStyle
                let marker = NSRange(location: paragraph.location, length: item.content.location - paragraph.location)
                func measure(_ range: NSRange) -> CGFloat {
                    let text = styled.attributedSubstring(from: range)
                    let width = widths[text] ?? text.size().width
                    widths[text] = width
                    return width
                }
                var width = measure(marker)
                // A bullet's text starts an en space past it; a task's box stands in for its bullet.
                let task = block.spans.contains { span in
                    if case .taskBox = span.kind { return span.range.location + offset == item.content.location }
                    return false
                }
                if Self.isBullet(at: item.range.location, in: styled.mutableString), !task, NSMaxRange(marker) - 1 > item.range.location,
                    let font = styled.attribute(.font, at: item.range.location, effectiveRange: nil) as? NSFont {
                    let hang = measure(NSRange(location: paragraph.location, length: item.range.location + 1 - paragraph.location)) + font.pointSize / 2
                    styled.addAttribute(.kern, value: hang - width, range: NSRange(location: NSMaxRange(marker) - 1, length: 1))
                    width = hang
                }
                style.headIndent = style.firstLineHeadIndent + width
                styled.addAttribute(.paragraphStyle, value: style, range: paragraph)
            }
        }
        // A blank line is half a line, outside code, front matter and HTML. It counts toward the space between the
        // blocks around it, so zero or one of them between two blocks read the same.
        if prose {
            let literals = found.filter { [.code, .html, .frontMatter].contains($0.kind) }.map(\.range)
            let half = store.paragraphStyle(lineHeight: store.bodyLineHeight / 2)
            var (at, next) = (0, 0)
            while at < whole.length {
                let paragraph = styled.mutableString.paragraphRange(for: NSRange(location: at, length: 0))
                at = NSMaxRange(paragraph)
                guard Self.isBlank(paragraph, in: styled.mutableString) else { continue }
                let location = paragraphs.location + paragraph.location
                while next < literals.count, NSMaxRange(literals[next]) <= location { next += 1 }
                if next < literals.count, NSLocationInRange(location, literals[next]) { continue }
                styled.addAttribute(.paragraphStyle, value: half, range: paragraph)
            }
        }
        blocks.style(styled, at: paragraphs.location, selection: source ? [whole] : selection)
        if !source {
            let container = textView?.textContainer
            tables.style(styled, at: paragraphs.location, selection: selection, width: (container?.size.width ?? 0) - 2 * (container?.lineFragmentPadding ?? 0))
            tasks.style(styled, at: paragraphs.location, selection: selection)
            fences.style(styled, at: paragraphs.location, selection: selection, folds: folds)
            math.style(styled, at: paragraphs.location, selection: selection)
            cards.style(styled, at: paragraphs.location, selection: selection)
        }
        if prose {
            // Each block's first line takes the space its kind asks above it, less what the blank lines above it draw.
            for block in found where block.range.location >= paragraphs.location {
                guard let gap = gap(at: block.range.location, kind: block.kind), gap > 0 else { continue }
                let first = styled.mutableString.paragraphRange(for: NSRange(location: block.range.location - paragraphs.location, length: 0))
                let style = styled.attribute(.paragraphStyle, at: first.location, effectiveRange: nil) as? NSParagraphStyle ?? .default
                styled.addAttribute(.paragraphStyle, value: spaced(style, gap), range: first)
            }
            if let fresh, NSLocationInRange(fresh, paragraphs) {
                let line = styled.mutableString.paragraphRange(for: NSRange(location: fresh - paragraphs.location, length: 0))
                let style = freshStyle(at: fresh) { location in
                    location < paragraphs.location
                        ? storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
                        : styled.attribute(.paragraphStyle, at: location - paragraphs.location, effectiveRange: nil) as? NSParagraphStyle
                }
                if let style, line.length > 0 { styled.addAttribute(.paragraphStyle, value: style, range: line) }
            }
        }
        if code == nil { MeasureContainer.keepProse(styled, to: store.measure) }
        for fold in folds {
            let hidden = NSIntersectionRange(fold, paragraphs)
            guard hidden.length > 0 else { continue }
            let local = NSRange(location: hidden.location - paragraphs.location, length: hidden.length)
            styled.addAttributes([
                .dewlineBlock: BlockLine(.collapsed), .foregroundColor: NSColor.clear, .font: Self.hiddenFont, .paragraphStyle: RenderedBlocks.collapsedLines,
            ], range: local)
        }
        if let code {
            highlights.update(file: code, text: storage.mutableString)
        } else {
            highlights.update(map.blocks(in: paragraphs), in: paragraphs, text: storage.mutableString)
        }
        // Removed text, a conflict's other version and the folded stamp hang under their paragraph, in space added
        // below it, or above the next paragraph when theirs is drawn as a block.
        for (anchor, height, before) in textView?.marks.space(in: paragraphs) ?? [] {
            let paragraph = styled.mutableString.paragraphRange(for: NSRange(location: anchor - paragraphs.location, length: 0))
            guard styled.attribute(.dewlineBlock, at: paragraph.location, effectiveRange: nil) == nil else { continue }
            let style = (styled.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle ?? .default)
                .mutableCopy() as! NSMutableParagraphStyle
            if before { style.paragraphSpacingBefore += height } else { style.paragraphSpacing += height }
            styled.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
        // A short removal's ghost reads inline, in a gap after the character before its deletion point.
        for (after, width) in textView?.marks.gaps(in: paragraphs) ?? [] {
            let local = NSRange(location: after - paragraphs.location, length: 1)
            let kern = styled.attribute(.kern, at: local.location, effectiveRange: nil) as? CGFloat ?? 0
            styled.addAttribute(.kern, value: kern + width, range: local)
        }
        // Only runs whose styling differs are written, once each, so layout invalidates only what changed. The CF
        // accessors return a run's dictionary without bridging it to Swift, which costs more than the comparison.
        // Attribute dictionaries are uniqued, so a restyle meets few pairs of them: each pair is compared and merged once.
        var merges: [Runs: NSDictionary?] = [:]
        var offset = 0
        while offset < whole.length {
            var run = CFRange()
            let wanted = CFAttributedStringGetAttributes(styled, offset, &run) as NSDictionary
            let end = paragraphs.location + run.location + run.length
            var location = paragraphs.location + offset
            while location < end {
                var part = CFRange()
                let current = CFAttributedStringGetAttributes(storage, location, &part) as NSDictionary
                let length = min(part.location + part.length, end) - location
                let runs = Runs(wanted: wanted, current: current)
                let merged: NSDictionary?
                if let known = merges[runs] {
                    merged = known
                } else {
                    merged = Self.merge(wanted, into: current)
                    merges[runs] = .some(merged)
                }
                if let merged { CFAttributedStringSetAttributes(storage, CFRange(location: location, length: length), merged, true) }
                location += length
            }
            offset = run.location + run.length
        }
        if prose { respace(after: paragraphs, in: storage) }
    }

    /// Sets the space above the first block after `paragraphs`, which depends on the text above it, where it changed:
    /// one paragraph style in the same write, so a restyle reaches no further than the text it styles.
    private func respace(after paragraphs: NSRange, in storage: NSTextStorage) {
        var after: BlockMap.Block?
        map.walk(from: NSMaxRange(paragraphs)) { block in
            after = block
            return false
        }
        guard let block = after, block.range.location >= NSMaxRange(paragraphs), let gap = gap(at: block.range.location, kind: block.kind),
            !folds.contains(where: { NSLocationInRange(block.range.location, $0) })
        else { return }
        let first = storage.mutableString.paragraphRange(for: NSRange(location: block.range.location, length: 0))
        guard let style = storage.attribute(.paragraphStyle, at: first.location, effectiveRange: nil) as? NSParagraphStyle else { return }
        // A change's folded stamp before the block adds its room, as the restyle's own pass for it does.
        let room: CGFloat = storage.attribute(.dewlineBlock, at: first.location, effectiveRange: nil) != nil ? 0
            : (textView?.marks.space(in: first) ?? []).reduce(0) { $0 + ($1.before ? $1.height : 0) }
        guard style.paragraphSpacingBefore != gap + room else { return }
        let attributes = [NSAttributedString.Key.paragraphStyle.rawValue: spaced(style, gap + room)] as CFDictionary
        CFAttributedStringSetAttributes(storage, CFRange(location: first.location, length: first.length), attributes, false)
    }

    /// The space the block of `kind` at `location` takes above its first line: what the block before it asks, 0 at the
    /// top of the note, less the blank lines between them at their drawn height. Nil for a table row under its table's
    /// head or a row, and a top-level item under an item, which their own layouts space. A fresh line above stands for
    /// the paragraph typing there will make.
    private func gap(at location: Int, kind: MarkdownBlock.Kind) -> CGFloat? {
        let store = ThemeStore.shared
        let line = store.bodyLineHeight
        let text = textView!.textStorage!.mutableString
        var blanks: CGFloat = 0
        var top = location
        var typed = false
        // Four blank lines draw more than any gap.
        for _ in 0..<4 where top > 0 {
            let above = text.paragraphRange(for: NSRange(location: top - 1, length: 0))
            if above.location == fresh {
                typed = true
                break
            }
            guard Self.isBlank(above, in: text) else { break }
            if !folds.contains(where: { NSLocationInRange(above.location, $0) }) { blanks += line / 2 }
            top = above.location
        }
        var before: MarkdownBlock.Kind? = typed ? .paragraph : nil
        if !typed {
            map.walk(from: location, backward: true) { block in
                before = block.kind
                return false
            }
        }
        let wanted: CGFloat
        switch (kind, before) {
        case (_, nil): wanted = 0
        case (.tableRow, .tableHead?), (.tableRow, .tableRow?), (.item, .item?): return nil
        // A paragraph right under a fresh line is the text that line's typing joins.
        case (.paragraph, _) where typed && blanks == 0: wanted = 0
        case (.heading, .heading?): wanted = 0.75 * line
        case (.heading(let level), _): wanted = store.heading(level).spaceAbove
        case (.tableHead, .heading?): wanted = line / 2
        case (.tableHead, _), (_, .tableHead?), (_, .tableRow?): wanted = line
        default: wanted = line / 2
        }
        return max(wanted - blanks, 0)
    }

    /// How an empty line at `location` lays out until typing there, so the first character moves nothing, in a note in
    /// Live: as a body line of the paragraph, item or quote text right above it, which typing there continues, else as a
    /// paragraph with the space a paragraph takes there. Nil off an empty line and in code, front matter and HTML.
    func freshStyle(at location: Int) -> NSParagraphStyle? {
        guard !showsSource, code == nil, let storage = textView?.textStorage else { return nil }
        return freshStyle(at: location) { storage.attribute(.paragraphStyle, at: $0, effectiveRange: nil) as? NSParagraphStyle }
    }

    /// `freshStyle(at:)` with the paragraph styles `style(at:)` reads.
    private func freshStyle(at location: Int, style: (Int) -> NSParagraphStyle?) -> NSParagraphStyle? {
        let text = textView!.textStorage!.mutableString
        let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
        guard Self.isBlank(paragraph, in: text),
            !map.blocks(in: NSRange(location: paragraph.location, length: 0)).contains(where: { [.code, .html, .frontMatter].contains($0.kind) })
        else { return nil }
        let line = ThemeStore.shared.bodyLineHeight
        if paragraph.location > 0 {
            let above = text.paragraphRange(for: NSRange(location: paragraph.location - 1, length: 0))
            if !Self.isBlank(above, in: text, quoted: true),
                map.blocks(in: NSRange(location: above.location, length: 0)).contains(where: { [.paragraph, .item, .quote, .callout].contains($0.kind) }),
                let style = style(above.location)
            {
                if let continued = continuedStyles[style], continued.minimumLineHeight == line { return continued }
                let continued = style.mutableCopy() as! NSMutableParagraphStyle
                (continued.minimumLineHeight, continued.maximumLineHeight, continued.paragraphSpacingBefore, continued.paragraphSpacing) = (line, line, 0, 0)
                continuedStyles[style] = continued
                return continued
            }
        }
        return ThemeStore.shared.paragraphStyle(lineHeight: line, before: gap(at: paragraph.location, kind: .paragraph) ?? 0)
    }

    /// `style` with `amount` above it.
    private func spaced(_ style: NSParagraphStyle, _ amount: CGFloat) -> NSParagraphStyle {
        if let spaced = spacedStyles[style]?[amount] { return spaced }
        let spaced = style.mutableCopy() as! NSMutableParagraphStyle
        spaced.paragraphSpacingBefore = amount
        spacedStyles[style, default: [:]][amount] = spaced
        return spaced
    }

    /// Whether `paragraph` holds only spaces, tabs, its line break and, when `quoted`, quote markers.
    private static func isBlank(_ paragraph: NSRange, in text: NSString, quoted: Bool = false) -> Bool {
        (paragraph.location..<NSMaxRange(paragraph)).allSatisfy { [0x20, 0x09, 0x0A, 0x0D].contains(text.character(at: $0)) || (quoted && text.character(at: $0) == 0x3E) }
    }

    /// `current` with `wanted`'s value for each key styling owns, or nil when the two agree on all of them.
    private static func merge(_ wanted: NSDictionary, into current: NSDictionary) -> NSDictionary? {
        guard keys.contains(where: { wanted.object(forKey: $0) as? NSObject != current.object(forKey: $0) as? NSObject }) else { return nil }
        let merged = current.mutableCopy() as! NSMutableDictionary
        for key in keys {
            if let value = wanted.object(forKey: key) {
                merged.setObject(value, forKey: key)
            } else {
                merged.removeObject(forKey: key)
            }
        }
        return merged
    }

    private func mark(_ span: SyntaxSpan, revealed: Bool, in storage: NSMutableAttributedString) {
        for marker in span.markers {
            if span.kind == .item {
                // A bullet keeps its room, so the text stays put when it shows, and the view draws a dot over it. A
                // number stays as typed.
                guard Self.isBullet(at: marker.location, in: storage.mutableString) else { continue }
                storage.addAttribute(.foregroundColor, value: revealed ? ThemeStore.shared.color(showsSource ? .ink2 : .syntax) : NSColor.clear, range: marker)
            } else if revealed {
                let font = storage.attribute(.dewlineMarkerFont, at: marker.location, effectiveRange: nil)!
                let quiet: Bool = switch span.kind {
                case .heading, .quote: true
                default: false
                }
                storage.addAttributes([.font: font, .foregroundColor: ThemeStore.shared.color(showsSource ? .ink2 : quiet ? .ink3 : .syntax)], range: marker)
            } else {
                CFAttributedStringSetAttributes(storage, CFRange(location: marker.location, length: marker.length), Self.hiddenMarker, false)
            }
        }
        if span.kind == .quote, !showsSource { hang(span.markers, in: storage) }
    }

    /// Sets each quote line's `> ` in the quote's indent, so its text stays put while they show. A callout's title line
    /// keeps its icon's room.
    private func hang(_ markers: [NSRange], in storage: NSMutableAttributedString) {
        let text = storage.mutableString
        var widths: [Int: CGFloat] = [:]
        for marker in markers {
            let shown = (storage.attribute(.font, at: marker.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 0 > 1
            widths[text.paragraphRange(for: marker).location, default: 0] += shown ? storage.attributedSubstring(from: marker).size().width : 0
        }
        for (start, width) in widths where storage.attribute(.dewlineCallout, at: start, effectiveRange: nil) == nil {
            guard let style = storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle,
                style.firstLineHeadIndent != max(style.headIndent - width, 0)
            else { continue }
            let hung = style.mutableCopy() as! NSMutableParagraphStyle
            hung.firstLineHeadIndent = max(style.headIndent - width, 0)
            storage.addAttribute(.paragraphStyle, value: hung, range: text.paragraphRange(for: NSRange(location: start, length: 0)))
        }
    }

    /// Shows or hides markers for the selection and the marked changes, on either one's move.
    func updateReveal() {
        LatencyProbe.begin(.reveal)
        defer { LatencyProbe.end(.reveal) }
        // A fresh line the caret leaves empty is a blank line.
        var left: [NSRange] = []
        if let at = fresh, textView!.selectedRanges.map(\.rangeValue) != [NSRange(location: at, length: 0)] {
            fresh = nil
            left = [NSRange(location: at, length: 0)]
        }
        guard !showsSource else { return }
        let textView = textView!
        let storage = textView.textStorage!
        let selection = textView.selectedRanges.map(\.rangeValue)
        var now: Set<SyntaxSpan> = []
        for range in selection {
            // Unstyled text takes the selection's reveal state when it is styled.
            for block in map.blocks(touching: range) where !unstyled.intersects(integersIn: Range(block.range)!) {
                now.formUnion(Self.styled(block).map { $0.shifted(by: block.range.location) }.filter { Self.touches($0, selection) })
            }
        }
        // A marked change wholly inside hidden markers, such as a link's new target, shows them, or its mark sits on nothing.
        for change in textView.marks.painted.values {
            for block in map.blocks(touching: change) where !unstyled.intersects(integersIn: Range(block.range)!) {
                now.formUnion(Self.styled(block).map { $0.shifted(by: block.range.location) }.filter { Self.hides($0, [change]) })
            }
        }
        let hide = revealed.subtracting(now)
        let show = now.subtracting(revealed)
        revealed = now
        let changedBlocks = blocks.revealChanges(selection) + tables.revealChanges(selection) + tasks.revealChanges(selection)
            + fences.revealChanges(selection, in: storage.mutableString) + math.revealChanges(selection) + cards.revealChanges(selection) + left
        guard !hide.isEmpty || !show.isEmpty || !changedBlocks.isEmpty else { return }
        storage.beginEditing()
        // In document order, the storage's attribute writes stay linear in the span count.
        for span in hide.sorted(by: { $0.range.location < $1.range.location }) { mark(span, revealed: false, in: storage) }
        for span in show.sorted(by: { $0.range.location < $1.range.location }) { mark(span, revealed: true, in: storage) }
        for range in changedBlocks { restyle(range, in: storage, selection: selection) }
        storage.endEditing()
        // Code wells and inline math draw behind the text, so a block that changes shape repaints them.
        if !changedBlocks.isEmpty { textView.needsDisplay = true }
    }

    /// Restyles, between events, what a whole parse changed.
    private func restyleLater(_ changed: [NSRange]) {
        guard let text = textView?.textStorage?.mutableString else { return }
        for range in changed {
            let paragraphs = text.paragraphRange(for: range)
            unstyled.insert(integersIn: Range(paragraphs)!)
            revealed = revealed.filter { !NSLocationInRange($0.range.location, paragraphs) }
        }
        blocks.textDidParse()
        schedule()
    }

    /// A heading's and a quote's spans and the inline ones that style, outside rendered blocks: the spans whose markers
    /// hide. A callout's `[!type]` hides whole.
    private static func styled(_ block: BlockMap.Block) -> [SyntaxSpan] {
        block.spans.filter { span in
            let styles = switch span.kind {
            case .heading: if case .heading = block.kind { true } else { false }
            case .quote, .callout: block.kind == .quote || block.kind == .callout
            case .emphasis, .strong, .strikethrough, .inlineCode, .link, .item: true
            case .highlight, .comment, .footnoteReference, .wikiLink, .embed: true
            default: false
            }
            return styles && !block.rendered.contains { NSIntersectionRange($0.range, span.range).length > 0 }
        }.map { span in
            switch span.kind {
            case .callout: SyntaxSpan(kind: .callout, range: span.range, content: NSRange(location: NSMaxRange(span.range), length: 0))
            // An item's marker shows with the caret beside it, not anywhere in the item.
            case .item:
                SyntaxSpan(
                    kind: .item, range: NSRange(location: span.range.location, length: span.content.location - span.range.location),
                    content: NSRange(location: span.content.location, length: 0)
                )
            default: span
            }
        }
    }

    /// Whether the item marker at `index` is a `-`, `*` or `+`.
    static func isBullet(at index: Int, in text: NSString) -> Bool {
        [0x2D, 0x2A, 0x2B].contains(text.character(at: index))
    }

    /// Whether one of `changes` lies wholly inside one of `span`'s markers.
    private static func hides(_ span: SyntaxSpan, _ changes: [NSRange]) -> Bool {
        changes.contains { change in change.length > 0 && span.markers.contains { $0.location <= change.location && NSMaxRange(change) <= NSMaxRange($0) } }
    }

    private static func touches(_ span: SyntaxSpan, _ selection: [NSRange]) -> Bool {
        selection.contains { $0.location <= NSMaxRange(span.range) && NSMaxRange($0) >= span.range.location }
    }

    private static func add(_ traits: NSFontDescriptor.SymbolicTraits, in range: NSRange, of storage: NSMutableAttributedString) {
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            storage.addAttribute(.font, value: ThemeStore.shared.font(value as! NSFont, adding: traits), range: run)
        }
    }
}

/// A run's wanted attributes and the storage's, by identity, held so neither address is reused while a restyle runs.
private struct Runs: Hashable {
    let wanted: NSDictionary
    let current: NSDictionary

    static func == (a: Runs, b: Runs) -> Bool {
        a.wanted === b.wanted && a.current === b.current
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(wanted))
        hasher.combine(ObjectIdentifier(current))
    }
}

extension NSAttributedString.Key {
    static let dewlineMarkerFont = NSAttributedString.Key("DewlineMarkerFont")
    /// A code span, whose chip the view draws under the change marks.
    static let dewlineCodeChip = NSAttributedString.Key("DewlineCodeChip")
    /// A heading's paragraph, whose markers hang this many points into the left margin.
    static let dewlineHang = NSAttributedString.Key("DewlineHang")
    /// A thematic break's line, which the view draws as a rule.
    static let dewlineRule = NSAttributedString.Key("DewlineRule")
    /// A list item's marker, by the item's depth.
    static let dewlineListMarker = NSAttributedString.Key("DewlineListMarker")
    /// Characters the caret never rests among.
    static let dewlineSkip = NSAttributedString.Key("DewlineSkip")
}
