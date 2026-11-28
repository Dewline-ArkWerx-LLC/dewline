import AppKit
import ObjectiveC
import Testing
@testable import Dewline

/// The editor in a window that reports itself key and is never ordered front, as `CaretTests` builds it, so the system
/// caret exists; every measure comes from its laid-out text.
@MainActor
private struct Rhythm {
    let window: KeyWindow
    let view: EditorTextView

    init(_ text: String, caret: Int = 0) throws {
        let scrollView = EditorTextView.scrollView()
        window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        view = try #require(scrollView.documentView as? EditorTextView)
        view.string = text
        window.makeFirstResponder(view)
        place(caret)
    }

    /// Empties the view first: a closed window's text system stays alive for a while, still holding the text.
    func close() {
        view.string = ""
        window.contentView = nil
        window.close()
    }

    func place(_ caret: Int) {
        view.setSelectedRange(NSRange(location: caret, length: 0))
        settle()
    }

    func type(_ text: String) {
        view.insertText(text, replacementRange: view.selectedRange())
        settle()
    }

    /// Lays the viewport and the window out and draws, which places the system caret.
    func settle() {
        view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }

    func at(_ text: String) -> Int {
        (view.string as NSString).range(of: text).location
    }

    /// The layout fragment and the line holding the character at `index`.
    private func laidOut(_ index: Int) throws -> (fragment: NSTextLayoutFragment, line: NSTextLineFragment) {
        let layout = try #require(view.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: index))
        layout.ensureLayout(for: NSTextRange(location: location))
        let fragment = try #require(layout.textLayoutFragment(for: location))
        let offset = content.offset(from: fragment.rangeInElement.location, to: location)
        let line = try #require(fragment.textLineFragments.first { NSLocationInRange(offset, $0.characterRange) } ?? fragment.textLineFragments.first)
        return (fragment, line)
    }

    /// The frame of the layout fragment holding the character at `index` in the view, the space above it included.
    func fragment(at index: Int) throws -> NSRect {
        try laidOut(index).fragment.layoutFragmentFrame.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
    }

    /// The box of the line holding the character at `index` in the view: the line alone, without the space above it.
    func line(at index: Int) throws -> NSRect {
        let (fragment, line) = try laidOut(index)
        let origin = view.textContainerOrigin
        return line.typographicBounds.offsetBy(dx: origin.x + fragment.layoutFragmentFrame.minX, dy: origin.y + fragment.layoutFragmentFrame.minY)
    }

    /// The system caret in the view.
    var caret: NSRect? {
        view.indicator?.frame
    }

    /// `firstRect(forCharacterRange:)` in the view.
    func firstRect(_ range: NSRange) -> NSRect {
        view.convert(window.convertFromScreen(view.firstRect(forCharacterRange: range, actualRange: nil)), from: nil)
    }

    /// The union of the selection segments over `range` in the view.
    func selection(_ range: NSRange) throws -> NSRect {
        let layout = try #require(view.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let start = try #require(content.location(content.documentRange.location, offsetBy: range.location))
        let end = try #require(content.location(start, offsetBy: range.length))
        var union: NSRect?
        layout.enumerateTextSegments(in: try #require(NSTextRange(location: start, end: end)), type: .selection, options: []) { _, frame, _, _ in
            union = union.map { $0.union(frame) } ?? frame
            return true
        }
        return try #require(union).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
    }

    /// The frame of every paragraph's layout fragment, by the paragraph's start.
    func frames() throws -> [(at: Int, frame: NSRect)] {
        let string = view.string as NSString
        var frames: [(at: Int, frame: NSRect)] = []
        var at = 0
        while at < string.length {
            frames.append((at, try fragment(at: at)))
            at = NSMaxRange(string.paragraphRange(for: NSRange(location: at, length: 0)))
        }
        return frames
    }

    /// The characters of each line the paragraph holding `index` lays out, in the text.
    func lines(of index: Int) throws -> [NSRange] {
        let (fragment, _) = try laidOut(index)
        let content = try #require(view.textLayoutManager?.textContentManager)
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        return fragment.textLineFragments.map { NSRange(location: start + $0.characterRange.location, length: $0.characterRange.length) }
    }

    /// Where CoreText sets each glyph of the line holding `index`, by character, from its origin to its advance, in the
    /// view: a kern is in its character's advance.
    func glyphs(around index: Int) throws -> [Int: (minX: CGFloat, maxX: CGFloat)] {
        let (fragment, line) = try laidOut(index)
        let content = try #require(view.textLayoutManager?.textContentManager)
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location) + line.characterRange.location
        let left = view.textContainerOrigin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
        var glyphs: [Int: (minX: CGFloat, maxX: CGFloat)] = [:]
        for run in CTLineGetGlyphRuns(CTLineCreateWithAttributedString(line.attributedString.attributedSubstring(from: line.characterRange))) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetAdvances(run, CFRange(), &advances)
            CTRunGetStringIndices(run, CFRange(), &indices)
            for k in 0..<count { glyphs[start + indices[k]] = (left + positions[k].x, left + positions[k].x + advances[k].width) }
        }
        return glyphs
    }

    /// Restyles the whole text at the selection and describes the first attribute that changed, if any did.
    func restyleChanges() -> String? {
        let storage = view.textStorage!
        let before = NSAttributedString(attributedString: storage)
        view.styler.restyleDocument()
        let keys: [NSAttributedString.Key] = [
            .font, .foregroundColor, .backgroundColor, .paragraphStyle, .underlineStyle, .strikethroughStyle, .kern,
            .dewlineMarkerFont, .dewlineBlock, .dewlineQuote, .dewlineHang, .dewlineRule, .dewlineListMarker, .dewlineSkip,
        ]
        for offset in 0..<storage.length {
            let old = before.attributes(at: offset, effectiveRange: nil)
            let new = storage.attributes(at: offset, effectiveRange: nil)
            for key in keys where old[key] as? NSObject != new[key] as? NSObject {
                return "\(key.rawValue) at \(offset): \(old[key].map { "\($0)" } ?? "nil") became \(new[key].map { "\($0)" } ?? "nil")"
            }
        }
        return nil
    }
}

/// The code `LatencyProbe` stamps for each `NSFont(descriptor:size:)` call while `FontCount` wraps it.
private let fontStamp: UInt16 = 999 << 1

/// Stamps every `NSFont(descriptor:size:)` call, until `restore`, so a keystroke's fonts can be counted.
@MainActor
private struct FontCount {
    let method: Method
    let original: IMP

    init() throws {
        typealias Font = @convention(c) (AnyObject, Selector, AnyObject, CGFloat) -> AnyObject?
        let selector = NSSelectorFromString("fontWithDescriptor:size:")
        method = try #require(class_getClassMethod(NSFont.self, selector))
        original = method_getImplementation(method)
        let call = unsafeBitCast(original, to: Font.self)
        let block: @convention(block) (AnyObject, AnyObject, CGFloat) -> AnyObject? = { this, descriptor, size in
            LatencyProbe.stamp(fontStamp)
            return call(this, selector, descriptor, size)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    func restore() {
        method_setImplementation(method, original)
    }

    /// The fonts built inside the editor's parts since the stamps were last cleared.
    var made: Int {
        var (depth, fonts) = (0, 0)
        for (code, _) in LatencyProbe.stamps {
            if code == fontStamp {
                if depth > 0 { fonts += 1 }
            } else if LatencyProbe.Part(rawValue: code >> 1) != nil {
                depth += code & 1 == 0 ? 1 : -1
            }
        }
        return fonts
    }
}

@MainActor
private final class Count {
    var value = 0
}

@MainActor
@Suite(.serialized)
struct TextRhythmTests {
    /// R0, first: in a laid-out editor in a key window, the space above a paragraph stays out of its line. The caret, a
    /// selection inside the line and `firstRect` all equal the line box and start at its top, for a 30 pt heading line
    /// with 30 above it, a 24 pt item with 4 and a drawn table row with 12. A fragment's negative leading padding moves
    /// the fragment and every caret in it by the padding, so a heading's shown `## ` hangs left of the column's edge and
    /// its text starts on the edge. The lab numbers this pins, macOS 27.3: in a window (lab5) a -36.62 pt padding moved
    /// the fragment to x -31.62 and every caret by exactly -36.62, and the caret rect, the selection and `firstRect` left
    /// out both `paragraphSpacingBefore` and an overridden `topMargin`; a 12 pt blank line held a 12 pt caret (lab4).
    @Test func spaceAboveStaysOutOfTheLineAndAHangMovesItsCarets() throws {
        let text = "Intro line.\n\n## Head\n\n- one\n- two\n\n| 1 | 2 |\n\nEnd.\n"
        let editor = try Rhythm(text)
        defer { editor.close() }
        let storage = try #require(editor.view.textStorage)
        let string = text as NSString
        let lines: [(at: Int, height: CGFloat, before: CGFloat)] = [(editor.at("## Head"), 30, 30), (editor.at("- two"), 24, 4), (editor.at("| 1 | 2 |"), 24, 12)]
        // The styles the heading, list and table layouts give these lines, set by hand; moving the caret among them
        // restyles none of them.
        for line in lines {
            let style = NSMutableParagraphStyle()
            (style.minimumLineHeight, style.maximumLineHeight, style.paragraphSpacingBefore) = (line.height, line.height, line.before)
            storage.addAttribute(.paragraphStyle, value: style, range: string.paragraphRange(for: NSRange(location: line.at, length: 0)))
        }
        let row = BlockLine(.table(TableRule(width: 60, across: false, color: .clear)))
        storage.addAttribute(.dewlineBlock, value: row, range: string.paragraphRange(for: NSRange(location: lines[2].at, length: 0)))
        for line in lines {
            let inside = NSRange(location: line.at + 3, length: 2)
            editor.place(inside.location)
            let box = try editor.line(at: inside.location)
            let fragment = try editor.fragment(at: inside.location)
            #expect(abs(box.height - line.height) <= 0.5, "the line at \(line.at) is \(box.height) pt")
            #expect(abs(box.minY - fragment.minY - line.before) <= 0.5, "the line at \(line.at) starts \(box.minY - fragment.minY) pt into its fragment")
            let caret = try #require(editor.caret)
            let selection = try editor.selection(inside)
            for (name, rect) in [("caret", caret), ("selection", selection), ("firstRect", editor.firstRect(inside))] {
                #expect(abs(rect.minY - box.minY) <= 0.5 && abs(rect.height - box.height) <= 0.5, "\(name) \(rect) against the line \(box) at \(line.at)")
            }
        }
        // With the caret on the heading its markers show in their own room; hung by their width, they move left of the
        // column's edge and the heading's text starts on it. The styler's own hang comes off first, so the hand-set one
        // is the only one.
        let head = lines[0].at
        editor.place(head + 3)
        storage.removeAttribute(.dewlineHang, range: string.paragraphRange(for: NSRange(location: head, length: 0)))
        editor.settle()
        let edge = editor.view.textContainerOrigin.x + (editor.view.textContainer?.lineFragmentPadding ?? 0)
        let shown = (0...3).map { editor.firstRect(NSRange(location: head + $0, length: 0)).minX }
        let width = shown[3] - shown[0]
        #expect(width > 10 && abs(shown[0] - edge) <= 0.5, "the markers show from \(shown[0]), \(width) pt wide, for the edge at \(edge)")
        storage.addAttribute(.dewlineHang, value: width, range: string.paragraphRange(for: NSRange(location: head, length: 0)))
        editor.settle()
        let hung = (0...3).map { editor.firstRect(NSRange(location: head + $0, length: 0)).minX }
        for (offset, (before, after)) in zip(shown, hung).enumerated() {
            #expect(abs(after - (before - width)) <= 0.5, "caret \(offset) moved from \(before) to \(after) under a \(width) pt hang")
        }
        #expect(abs(hung[3] - edge) <= 0.5, "the heading's text starts at \(hung[3]), the edge at \(edge)")
        #expect(hung[..<3].allSatisfy { $0 < edge }, "the markers' carets \(hung[..<3]) sit left of the edge at \(edge)")
        // As in lab5, where -36.62 put the fragment at x -31.62: the line fragment padding less the hang.
        let padding = editor.view.textContainer?.lineFragmentPadding ?? 0
        let fragment = try editor.fragment(at: head).minX - editor.view.textContainerOrigin.x
        #expect(abs(fragment - (padding - width)) <= 0.5, "the fragment sits at x \(fragment) under a \(width) pt hang")
    }

    /// R1: a blank line is half a line, the caret on it as tall, and each further blank line adds half a line; at other
    /// sizes and leadings a blank line stays half the body line.
    @Test func blankLinesAreHalfALine() throws {
        let line = ThemeStore.shared.bodyLineHeight
        for blanks in [1, 2] {
            let editor = try Rhythm("Para one.\n" + String(repeating: "\n", count: blanks) + "Para two.", caret: 10)
            defer { editor.close() }
            let one = try editor.line(at: 0)
            let two = try editor.line(at: editor.at("Para two."))
            #expect(abs(two.minY - one.maxY - CGFloat(blanks) * line / 2) <= 0.5, "\(blanks) blank lines: \(two.minY - one.maxY) pt between the paragraphs")
            let blank = try editor.line(at: 10)
            let caret = try #require(editor.caret)
            #expect(abs(caret.height - line / 2) <= 0.5 && abs(caret.minY - blank.minY) <= 0.5, "the caret \(caret) on the blank line \(blank)")
        }
        let store = ThemeStore.shared
        let (size, leading) = (store.bodySize, store.lineHeight)
        defer { (store.bodySize, store.lineHeight) = (size, leading) }
        for (points, height, half) in [(16.0, 1.3, 10.5), (20.0, 1.6, 16.0)] {
            (store.bodySize, store.lineHeight) = (points, height)
            let editor = try Rhythm("Para one.\n\nPara two.")
            defer { editor.close() }
            let blank = try editor.line(at: 10)
            #expect(abs(blank.height - half) <= 0.01, "at \(points) pt and \(height), the blank line is \(blank.height) pt")
        }
    }

    /// R2: an H2 takes a 30 pt line with 42 above it and 12 below, with blank lines around it or none.
    @Test func aHeadingTakesMoreSpaceAboveThanBelow() throws {
        try #require(ThemeStore.shared.bodySize == 16 && ThemeStore.shared.lineHeight == 1.5, "the defaults")
        for text in ["Text.\n\n## Head\n\nText.", "Text.\n## Head\nText."] {
            let editor = try Rhythm(text)
            defer { editor.close() }
            let above = try editor.line(at: 0)
            let head = try editor.line(at: editor.at("## Head") + 3)
            let below = try editor.line(at: (text as NSString).range(of: "Text.", options: .backwards).location)
            #expect(abs(head.height - 30) <= 0.5, "\(text.debugDescription): the heading's line is \(head.height) pt")
            #expect(abs(head.minY - above.maxY - 42) <= 0.5, "\(text.debugDescription): \(head.minY - above.maxY) pt above the heading")
            #expect(abs(below.minY - head.maxY - 12) <= 0.5, "\(text.debugDescription): \(below.minY - head.maxY) pt below it")
        }
    }

    /// R3: after a paragraph, each level takes its line box and its space above, and half a line below. H5 sets 13 pt
    /// small caps and H6 italic in ink2, the other levels the heading color; tracking sits on the text, not the markers.
    @Test func eachHeadingLevelTakesItsLineAndItsSpace() throws {
        let store = ThemeStore.shared
        try #require(store.bodySize == 16 && store.lineHeight == 1.5, "the defaults")
        let boxes: [CGFloat] = [36, 30, 24, 24, 24, 24]
        let above: [CGFloat] = [48, 42, 36, 24, 24, 24]
        for level in 1...6 {
            let markers = String(repeating: "#", count: level) + " "
            let text = "Text.\n\n\(markers)Head\n\nText."
            let editor = try Rhythm(text)
            defer { editor.close() }
            let storage = try #require(editor.view.textStorage)
            let head = editor.at(markers + "Head")
            let content = head + level + 1
            let previous = try editor.line(at: 0)
            let line = try editor.line(at: content)
            let next = try editor.line(at: (text as NSString).range(of: "Text.", options: .backwards).location)
            #expect(abs(line.height - boxes[level - 1]) <= 0.5, "H\(level): its line is \(line.height) pt")
            #expect(abs(line.minY - previous.maxY - above[level - 1]) <= 0.5, "H\(level): \(line.minY - previous.maxY) pt above it")
            #expect(abs(next.minY - line.maxY - 12) <= 0.5, "H\(level): \(next.minY - line.maxY) pt below it")
            let color = storage.attribute(.foregroundColor, at: content, effectiveRange: nil) as? NSColor
            #expect(color == store.color(level == 6 ? .ink2 : .heading), "H\(level) in \(String(describing: color))")
            let kern = store.heading(level).kern
            #expect((storage.attribute(.kern, at: content, effectiveRange: nil) as? CGFloat ?? 0) == kern, "H\(level): its text's tracking")
            #expect(storage.attribute(.kern, at: head, effectiveRange: nil) == nil, "H\(level): its markers' tracking")
            let font = try #require(storage.attribute(.font, at: content, effectiveRange: nil) as? NSFont)
            switch level {
            case 5:
                // Small caps shape every letter of "Head" to other glyphs than the plain semibold face.
                func glyphs(_ font: NSFont) -> [CGGlyph] {
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Head", attributes: [.font: font]))
                    return (CTLineGetGlyphRuns(line) as! [CTRun]).flatMap { run in
                        var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                        CTRunGetGlyphs(run, CFRange(), &glyphs)
                        return glyphs
                    }
                }
                let plain = Faces.font(store.bodyFace, size: 13, weight: .semibold)
                #expect(font.pointSize == 13 && font.familyName == plain.familyName, "H5 is \(font)")
                let (small, letters) = (glyphs(font), glyphs(plain))
                #expect(small.count == 4 && zip(small, letters).allSatisfy { $0 != $1 }, "H5 shapes \(small), the plain face \(letters)")
                #expect(abs(kern - 0.06 * 13) < 0.001, "H5 tracks \(kern)")
            case 6:
                #expect(font.pointSize == 16 && font.fontDescriptor.symbolicTraits.contains(.italic), "H6 is \(font)")
            default:
                break
            }
        }
    }

    /// R3b: a heading right under a heading sits 18 pt below it, with a blank line between them or none, and the text
    /// under the second 12 pt below that.
    @Test func aHeadingUnderAHeadingSitsCloseToIt() throws {
        try #require(ThemeStore.shared.bodySize == 16 && ThemeStore.shared.lineHeight == 1.5, "the defaults")
        for (text, second) in [("## A\n### B\nText", "### B"), ("##### A\n\n###### B\nText", "###### B")] {
            let editor = try Rhythm(text)
            defer { editor.close() }
            let first = try editor.line(at: editor.at("A"))
            let under = try editor.line(at: editor.at(second) + second.utf16.count - 1)
            let body = try editor.line(at: editor.at("Text"))
            #expect(abs(under.minY - first.maxY - 18) <= 0.5, "\(text.debugDescription): \(under.minY - first.maxY) pt between the headings")
            #expect(abs(body.minY - under.maxY - 12) <= 0.5, "\(text.debugDescription): \(body.minY - under.maxY) pt under the second")
        }
    }

    /// R4: a heading that starts the note takes no space above it: its line starts at the container's top inset.
    @Test func aHeadingThatStartsTheNoteSitsAtTheInset() throws {
        let editor = try Rhythm("# Title\n\nText.")
        defer { editor.close() }
        let title = try editor.line(at: 2)
        #expect(editor.view.textContainerInset.height == 24)
        #expect(abs(title.minY - editor.view.textContainerOrigin.y) <= 0.5, "the title's line starts at \(title.minY)")
    }

    /// R5: the caret arriving on a heading and leaving it changes its markers' color and nothing else: no fragment
    /// moves, the text keeps its x on the column's edge, and the markers' carets sit in the margin left of it in both
    /// states. A heading that wraps starts its next line on the edge and ends within the measure.
    @Test func aHeadingsMarkersShowInTheMargin() throws {
        do {
            let text = "Text.\n\n## Head\n\nText.\n"
            let editor = try Rhythm(text)
            defer { editor.close() }
            let storage = try #require(editor.view.textStorage)
            let string = text as NSString
            let head = editor.at("## Head")
            let edge = editor.view.textContainerOrigin.x + (editor.view.textContainer?.lineFragmentPadding ?? 0)
            let hang = try #require(storage.attribute(.dewlineHang, at: head, effectiveRange: nil) as? CGFloat)
            var starts: [Int] = []
            var at = 0
            while at < string.length {
                starts.append(at)
                at = NSMaxRange(string.paragraphRange(for: NSRange(location: at, length: 0)))
            }
            let frames = try starts.map { try editor.fragment(at: $0) }
            let keys: [NSAttributedString.Key] = [
                .font, .foregroundColor, .backgroundColor, .paragraphStyle, .underlineStyle, .strikethroughStyle, .kern,
                .dewlineMarkerFont, .dewlineBlock, .dewlineQuote, .dewlineHang, .dewlineRule, .dewlineListMarker, .dewlineSkip,
            ]
            for (state, caret, color) in [("shown", head + 5, ThemeStore.shared.color(.ink3)), ("hidden", 0, NSColor.clear)] {
                let before = NSAttributedString(attributedString: storage)
                editor.place(caret)
                for (start, (old, new)) in zip(starts, zip(frames, try starts.map { try editor.fragment(at: $0) })) {
                    #expect(abs(new.minX - old.minX) <= 0.5 && abs(new.minY - old.minY) <= 0.5 && abs(new.height - old.height) <= 0.5, "\(state): the fragment at \(start) moved from \(old) to \(new)")
                }
                let carets = (0...3).map { editor.firstRect(NSRange(location: head + $0, length: 0)).minX }
                #expect(abs(carets[3] - edge) <= 0.5, "\(state): the text starts at \(carets[3]), the edge at \(edge)")
                #expect(abs(carets[0] - (edge - hang)) <= 0.5 && carets[..<3].allSatisfy { $0 < edge }, "\(state): the markers' carets \(carets[..<3]), the edge at \(edge)")
                var changed: [(key: NSAttributedString.Key, at: Int)] = []
                for offset in 0..<storage.length {
                    let (old, new) = (before.attributes(at: offset, effectiveRange: nil), storage.attributes(at: offset, effectiveRange: nil))
                    changed += keys.filter { old[$0] as? NSObject != new[$0] as? NSObject }.map { (key: $0, at: offset) }
                }
                #expect(changed.map(\.at) == [head, head + 1, head + 2] && changed.allSatisfy { $0.key == .foregroundColor }, "\(state): \(changed)")
                #expect(storage.attribute(.foregroundColor, at: head, effectiveRange: nil) as? NSColor == color, "\(state): the markers' color")
            }
        }
        let words = "## A heading long enough to wrap twice in this column, since every word of it is set in the heading face"
        let wrapped = try Rhythm("Text.\n\n\(words)\n\nText.\n")
        defer { wrapped.close() }
        let edge = wrapped.view.textContainerOrigin.x + (wrapped.view.textContainer?.lineFragmentPadding ?? 0)
        let layout = try #require(wrapped.view.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let start = wrapped.at(words)
        let location = try #require(content.location(content.documentRange.location, offsetBy: start))
        layout.ensureLayout(for: NSTextRange(location: location))
        let fragment = try #require(layout.textLayoutFragment(for: location))
        try #require(fragment.textLineFragments.count >= 2, "the heading wraps")
        let measure = ThemeStore.shared.measure
        for (number, line) in fragment.textLineFragments.enumerated() {
            let range = NSRange(location: start + line.characterRange.location, length: line.characterRange.length)
            let ink = (wrapped.view.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            let rect = wrapped.firstRect(NSRange(location: range.location, length: (ink as NSString).length))
            if number > 0 { #expect(abs(rect.minX - edge) <= 0.5, "line \(number) starts at \(rect.minX), the edge at \(edge)") }
            #expect(rect.maxX <= edge + measure + 0.5, "line \(number) ends at \(rect.maxX), past the measure's \(edge + measure)")
        }
    }

    /// R6: Return at the end of a paragraph makes a fresh line, a line tall with the caret as tall at its top, and moves
    /// the paragraph below down by that line; typing into it moves nothing, and leaving it empty makes it a blank line.
    @Test func returnMakesAFreshLine() throws {
        let line = ThemeStore.shared.bodyLineHeight
        for types in [true, false] {
            let editor = try Rhythm("Para one.\nPara two.", caret: 9)
            defer { editor.close() }
            let before = try editor.line(at: editor.at("Para two."))
            editor.view.insertNewline(nil)
            editor.settle()
            #expect(editor.view.string == "Para one.\n\nPara two.")
            let returned = try editor.line(at: editor.at("Para two."))
            #expect(abs(returned.minY - before.minY - line) <= 0.5, "Return moved the paragraph below \(returned.minY - before.minY) pt")
            let one = try editor.line(at: 0)
            let fresh = try editor.line(at: 10)
            let caret = try #require(editor.caret)
            #expect(abs(fresh.height - line) <= 0.5 && abs(fresh.minY - one.maxY) <= 0.5, "the fresh line \(fresh) under \(one)")
            #expect(abs(caret.height - line) <= 0.5 && abs(caret.minY - fresh.minY) <= 0.5, "the caret \(caret) on the fresh line \(fresh)")
            if types {
                editor.type("x")
                let typed = try editor.line(at: 10)
                let after = try editor.line(at: editor.at("Para two."))
                #expect(abs(typed.minY - fresh.minY) <= 0.5 && abs(after.minY - returned.minY) <= 0.5, "typing moved \(typed) or \(after)")
            } else {
                editor.place(0)
                let blank = try editor.line(at: 10)
                let after = try editor.line(at: editor.at("Para two."))
                #expect(abs(blank.height - line / 2) <= 0.5, "the fresh line left empty is \(blank.height) pt")
                #expect(abs(after.minY - (returned.minY - line / 2)) <= 0.5, "the paragraph below moved up \(returned.minY - after.minY) pt")
            }
        }
    }

    /// R6b: Return, Return and a character at the end of a paragraph over a blank line move the paragraph below by 24,
    /// then 12, then nothing, and leave what a whole restyle of the text gives.
    @Test func twoReturnsAndACharacter() throws {
        let line = ThemeStore.shared.bodyLineHeight
        let editor = try Rhythm("Para one.\n\nPara two.", caret: 9)
        defer { editor.close() }
        var top = try editor.line(at: editor.at("Para two.")).minY
        for (step, moves) in [line, line / 2, 0].enumerated() {
            if step < 2 {
                editor.view.insertNewline(nil)
                editor.settle()
            } else {
                editor.type("x")
            }
            let now = try editor.line(at: editor.at("Para two.")).minY
            #expect(abs(now - top - moves) <= 0.5, "step \(step) moved the paragraph below \(now - top) pt")
            top = now
        }
        #expect(editor.view.string == "Para one.\n\nx\n\nPara two.")
        #expect(editor.restyleChanges() == nil)
    }

    /// R6c: Return at the end of a heading over a list makes a fresh line half a line below the heading; the list moves
    /// once, at the Return, and typing on the fresh line moves nothing.
    @Test func aFreshLineUnderAHeading() throws {
        let line = ThemeStore.shared.bodyLineHeight
        let editor = try Rhythm("## Goals\n- a", caret: 8)
        defer { editor.close() }
        let before = try editor.line(at: editor.at("- a"))
        editor.view.insertNewline(nil)
        editor.settle()
        let heading = try editor.line(at: 3)
        let fresh = try editor.line(at: 9)
        #expect(abs(fresh.height - line) <= 0.5 && abs(fresh.minY - heading.maxY - line / 2) <= 0.5, "the fresh line \(fresh) under the heading \(heading)")
        let returned = try editor.line(at: editor.at("- a"))
        #expect(abs(returned.minY - before.minY - 1.5 * line) <= 0.5, "Return moved the list \(returned.minY - before.minY) pt")
        editor.type("x")
        let typed = try editor.line(at: 9)
        let after = try editor.line(at: editor.at("- a"))
        #expect(abs(typed.minY - fresh.minY) <= 0.5 && abs(after.minY - returned.minY) <= 0.5, "typing moved \(typed) or \(after)")
    }

    /// R6d: composing on a blank line the caret was moved to lays out a body line in the body font, the line committing
    /// it makes: the heading above stays, and the commit moves nothing.
    @Test func composingOnABlankLine() throws {
        let line = ThemeStore.shared.bodyLineHeight
        let editor = try Rhythm("## Goals\n\n\nPara.", caret: 10)
        defer { editor.close() }
        let heading = try editor.line(at: 3)
        editor.view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.settle()
        let composing = try [3, 10, 12].map { try editor.line(at: $0) }
        #expect(abs(composing[1].height - line) <= 0.5, "the composing line is \(composing[1].height) pt")
        #expect(editor.view.textStorage?.attribute(.font, at: 10, effectiveRange: nil) as? NSFont == MarkdownStyler.bodyFont)
        #expect(abs(composing[0].minY - heading.minY) <= 0.5, "the heading moved from \(heading) to \(composing[0])")
        editor.view.unmarkText()
        editor.settle()
        #expect(editor.view.string == "## Goals\n\nに\nPara.")
        let committed = try [3, 10, 12].map { try editor.line(at: $0) }
        for (old, new) in zip(composing, committed) {
            #expect(abs(new.minY - old.minY) <= 0.5 && abs(new.height - old.height) <= 0.5, "the commit moved \(old) to \(new)")
        }
    }

    /// R7: a list sits half a line below the paragraph above it, with a blank line between them or none.
    @Test func aListSitsHalfALineBelowAParagraph() throws {
        let line = ThemeStore.shared.bodyLineHeight
        for text in ["Para.\n- a\n- b", "Para.\n\n- a\n- b"] {
            let editor = try Rhythm(text)
            defer { editor.close() }
            let paragraph = try editor.line(at: 0)
            let item = try editor.line(at: editor.at("- a"))
            #expect(abs(item.minY - paragraph.maxY - line / 2) <= 0.5, "\(text.debugDescription): \(item.minY - paragraph.maxY) pt above the list")
        }
    }

    /// R8: a code block's well leaves V between its edge and the glyphs of its first and last lines, its code starts at
    /// the inset quote and callout text start at, and the caret on its opening fence moves no line.
    @Test func codeSitsInTheMiddleOfItsWell() throws {
        let store = ThemeStore.shared
        try #require(store.bodySize == 16 && store.lineHeight == 1.5, "the defaults")
        let text = "> A crash sends the event again.\n\n> [!warning] Deploy order\n> Run the migration first.\n\n```rust\npub fn next(attempt: u32) -> u32 {\n    attempt + 1\n}\n```\n\nAfter.\n"
        let editor = try Rhythm(text, caret: text.utf16.count)
        defer { editor.close() }
        let storage = try #require(editor.view.textStorage)
        let code = editor.at("pub fn")
        let last = editor.at("}\n```")
        let well = try #require(storage.attribute(.dewlineCode, at: code, effectiveRange: nil) as? CodeWell)
        var whole = NSRange()
        storage.attribute(.dewlineCode, at: code, longestEffectiveRange: &whole, in: NSRange(location: 0, length: storage.length))
        let drawn = editor.view.codeWell(
            well, top: editor.firstRect(NSRange(location: whole.location, length: 0)), bottom: editor.firstRect(NSRange(location: NSMaxRange(whole) - 1, length: 0))
        )
        let font = try #require(storage.attribute(.font, at: code, effectiveRange: nil) as? NSFont)
        let top = try #require(editor.view.baseline(at: code)) - font.ascender
        let bottom = try #require(editor.view.baseline(at: last)) - font.descender
        let (above, below) = (top - drawn.minY, drawn.maxY - bottom)
        #expect(abs(above - below) <= 1, "\(above) pt over the code, \(below) pt under it")
        #expect(abs(above - 15.5) <= 1 && abs(below - 15.5) <= 1, "\(above) pt over the code, \(below) pt under it")
        let edge = editor.view.textContainerOrigin.x + (editor.view.textContainer?.lineFragmentPadding ?? 0)
        for start in [code, editor.at("A crash"), editor.at("Run the")] {
            let x = editor.firstRect(NSRange(location: start, length: 1)).minX - edge
            #expect(abs(x - store.inset) <= 0.5, "the text at \(start) starts at \(x)")
        }
        let frames = try editor.frames()
        editor.place(editor.at("```rust") + 3)
        #expect((storage.attribute(.font, at: editor.at("rust"), effectiveRange: nil) as? NSFont)?.pointSize ?? 0 > 1, "the fence shows")
        for ((start, old), (_, new)) in zip(frames, try editor.frames()) {
            #expect(abs(new.minY - old.minY) <= 0.5 && abs(new.height - old.height) <= 0.5, "the fragment at \(start) moved from \(old) to \(new)")
        }
    }

    /// R9: a callout's well leaves V between its edge and the glyphs of its first and last lines, half a line between it
    /// and the text around it, and the inset between its lines' ends and its right edge.
    @Test func aCalloutsWellPadsItsText() throws {
        let store = ThemeStore.shared
        try #require(store.bodySize == 16 && store.lineHeight == 1.5, "the defaults")
        let body = String(repeating: "Run the migration before the new worker starts, or it fails its first claim. ", count: 3)
        let text = "Above.\n\n> [!warning] Deploy order\n> \(body)\n\nBelow.\n"
        let editor = try Rhythm(text, caret: text.utf16.count)
        defer { editor.close() }
        let storage = try #require(editor.view.textStorage)
        let title = editor.at("Deploy")
        var whole = NSRange()
        storage.attribute(.dewlineCallout, at: title, longestEffectiveRange: &whole, in: NSRange(location: 0, length: storage.length))
        let well = editor.view.calloutWell(
            top: editor.firstRect(NSRange(location: whole.location, length: 0)), bottom: editor.firstRect(NSRange(location: NSMaxRange(whole) - 1, length: 0))
        )
        let end = NSMaxRange(whole) - 2
        let (head, tail) = try (#require(storage.attribute(.font, at: title, effectiveRange: nil) as? NSFont), #require(storage.attribute(.font, at: end, effectiveRange: nil) as? NSFont))
        let top = try #require(editor.view.baseline(at: title)) - head.ascender
        let bottom = try #require(editor.view.baseline(at: end)) - tail.descender
        #expect(abs(top - well.minY - 15.5) <= 1 && abs(well.maxY - bottom - 15.5) <= 1, "\(top - well.minY) pt over the text, \(well.maxY - bottom) pt under it")
        let above = try editor.line(at: 0)
        let after = try editor.line(at: editor.at("Below."))
        #expect(abs(well.minY - above.maxY - 12) <= 0.5 && abs(after.minY - well.maxY - 12) <= 0.5, "\(well.minY - above.maxY) pt above the well, \(after.minY - well.maxY) pt below it")
        let lines = try editor.lines(of: title) + editor.lines(of: editor.at("Run the"))
        #expect(lines.count >= 3, "the callout's body wraps")
        for line in lines {
            let ink = (editor.view.string as NSString).substring(with: line).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let rect = editor.firstRect(NSRange(location: line.location, length: (ink as NSString).length))
            #expect(rect.maxX <= well.maxX - store.inset + 0.5, "the line at \(line.location) ends at \(rect.maxX), the well at \(well.maxX)")
        }
    }

    /// R10: a thematic break is a 1 pt rule 4 em wide, centered on the column at its line's middle, half a line from the
    /// text around it; the caret on its line shows its characters instead and moves no line.
    @Test func aThematicBreakIsACenteredRule() throws {
        let store = ThemeStore.shared
        let text = "Above.\n\n---\n\nBelow.\n"
        let editor = try Rhythm(text)
        defer { editor.close() }
        let storage = try #require(editor.view.textStorage)
        let at = editor.at("---")
        #expect(storage.attribute(.dewlineRule, at: at, effectiveRange: nil) != nil)
        #expect(storage.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor == NSColor.clear)
        let line = try editor.line(at: at)
        let rule = editor.view.rule(on: editor.firstRect(NSRange(location: at, length: 0)))
        let padding = editor.view.textContainer?.lineFragmentPadding ?? 0
        let center = editor.view.textContainerOrigin.x + padding + ((editor.view.textContainer?.column ?? 0) - 2 * padding) / 2
        #expect(rule.height == 1 && abs(rule.width - 4 * store.bodySize) <= 0.5, "the rule is \(rule)")
        #expect(abs(rule.midX - center) <= 0.5 && abs(rule.midY - line.midY) <= 0.5, "the rule \(rule) on the line \(line), the column's center at \(center)")
        let above = try editor.line(at: 0)
        let below = try editor.line(at: editor.at("Below."))
        let half = store.bodyLineHeight / 2
        #expect(abs(line.minY - above.maxY - half) <= 0.5 && abs(below.minY - line.maxY - half) <= 0.5, "\(line.minY - above.maxY) pt above, \(below.minY - line.maxY) below")
        let frames = try editor.frames()
        editor.place(at + 1)
        #expect(storage.attribute(.dewlineRule, at: at, effectiveRange: nil) == nil, "the caret's rule is not drawn")
        #expect(storage.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor == store.color(.syntax))
        for ((start, old), (_, new)) in zip(frames, try editor.frames()) {
            #expect(abs(new.minY - old.minY) <= 0.5 && abs(new.height - old.height) <= 0.5, "the fragment at \(start) moved from \(old) to \(new)")
        }
        editor.place(0)
        #expect(storage.attribute(.dewlineRule, at: at, effectiveRange: nil) != nil, "the rule is back")
        #expect(editor.restyleChanges() == nil)
    }

    /// R11: a code span's chip stands 3 pt past its first and last glyphs and over their ascenders and descenders, in
    /// the room its hidden backticks keep, so the word spaces on each side keep their full width outside it.
    @Test func aCodeSpansChipStandsClearOfItsGlyphs() throws {
        let store = ThemeStore.shared
        try #require(store.bodySize == 16, "the default size")
        let text = "a `code` b\n"
        let editor = try Rhythm(text, caret: text.utf16.count)
        defer { editor.close() }
        let storage = try #require(editor.view.textStorage)
        let (open, close) = (editor.at("`code"), editor.at("` b"))
        for backtick in [open, close] {
            #expect(storage.attribute(.kern, at: backtick, effectiveRange: nil) as? CGFloat == 3, "the hidden backtick at \(backtick)")
        }
        let chips = editor.view.codeChips(in: NSRange(location: 0, length: storage.length)).filter { !$0.button }
        try #require(chips.count == 1, "\(chips)")
        let chip = chips[0].rect
        let glyphs = try editor.glyphs(around: open + 1)
        let (first, last) = try (#require(glyphs[open + 1]), #require(glyphs[close - 1]))
        let (before, after) = try (#require(glyphs[open - 1]), #require(glyphs[close + 1]))
        #expect(chip.minX <= first.minX - 3 + 0.5 && chip.maxX >= last.maxX + 3 - 0.5, "the chip \(chip) around \(first.minX) to \(last.maxX)")
        #expect(chip.minX >= before.maxX - 0.5 && chip.maxX <= after.minX + 0.5, "the chip \(chip) between the spaces at \(before.maxX) and \(after.minX)")
        let space = NSAttributedString(string: " ", attributes: [.font: store.bodyFont]).size().width
        #expect(abs(before.maxX - before.minX - space) <= 0.5 && abs(after.maxX - after.minX - space) <= 0.5, "the spaces are \(before) and \(after)")
        let font = try #require(storage.attribute(.font, at: open + 1, effectiveRange: nil) as? NSFont)
        let baseline = try #require(editor.view.baseline(at: open + 1))
        #expect(chip.minY <= baseline - font.ascender && chip.maxY >= baseline - font.descender, "the chip \(chip) over the baseline at \(baseline)")
        editor.place(open + 2)
        for backtick in [open, close] {
            #expect(storage.attribute(.kern, at: backtick, effectiveRange: nil) == nil, "the shown backtick at \(backtick)")
        }
        #expect(editor.restyleChanges() == nil)
    }

    /// 5.11: a caret proposed inside a run marked `.dewlineSkip` moves past it the way it moved; a run that starts its
    /// line takes the line's start with it and one that ends its line the line's end. Selections and Source pass.
    @Test func theCaretSkipsMarkedRuns() throws {
        let text = "abXXcd\n  ef\ngh  \nij\n"
        let editor = try Rhythm(text)
        defer { editor.close() }
        let storage = try #require(editor.view.textStorage)
        let runs = [NSRange(location: 2, length: 2), NSRange(location: 7, length: 2), NSRange(location: 14, length: 2)]
        for run in runs { storage.addAttribute(.dewlineSkip, value: true, range: run) }
        for (from, right, to) in [(2, true, 4), (4, false, 2), (6, true, 9), (9, false, 6), (14, true, 17), (17, false, 14)] {
            editor.place(from)
            if right { editor.view.moveRight(nil) } else { editor.view.moveLeft(nil) }
            #expect(editor.view.selectedRange() == NSRange(location: to, length: 0), "\(right ? "Right" : "Left") from \(from)")
        }
        let styler = editor.view.styler
        func proposed(_ from: Int, _ to: NSRange) -> [NSRange] {
            styler.textView(editor.view, willChangeSelectionFromCharacterRanges: [NSValue(range: NSRange(location: from, length: 0))], toCharacterRanges: [NSValue(range: to)])
                .map(\.rangeValue)
        }
        #expect(proposed(0, NSRange(location: 3, length: 0)) == [NSRange(location: 4, length: 0)])
        #expect(proposed(5, NSRange(location: 3, length: 0)) == [NSRange(location: 2, length: 0)])
        #expect(proposed(0, NSRange(location: 3, length: 2)) == [NSRange(location: 3, length: 2)], "a selection passes")
        editor.place(2)
        editor.view.moveRightAndModifySelection(nil)
        #expect(editor.view.selectedRange() == NSRange(location: 2, length: 1), "an extended selection passes")
        editor.view.toggleSource(nil)
        for run in runs { storage.addAttribute(.dewlineSkip, value: true, range: run) }
        #expect(proposed(0, NSRange(location: 3, length: 0)) == [NSRange(location: 3, length: 0)], "Source passes")
    }

    /// R12: at the end of a note that ends in a blank line, the caret is a line tall, and typing there moves nothing
    /// above it.
    @Test func theNotesEndTypesOnABodyLine() throws {
        let line = ThemeStore.shared.bodyLineHeight
        let editor = try Rhythm("Para.\n\n", caret: 7)
        defer { editor.close() }
        let caret = try #require(editor.caret)
        #expect(abs(caret.height - line) <= 0.5, "the caret is \(caret.height) pt")
        let above = try [0, 6].map { try editor.line(at: $0) }
        editor.type("x")
        let after = try [0, 6].map { try editor.line(at: $0) }
        for (old, new) in zip(above, after) {
            #expect(abs(new.minY - old.minY) <= 0.5 && abs(new.height - old.height) <= 0.5, "typing moved \(old) to \(new)")
        }
        let typed = try editor.line(at: 7)
        #expect(abs(typed.minY - caret.minY) <= 0.5 && abs(typed.height - line) <= 0.5, "the typed line \(typed) under the caret \(caret)")
    }

    /// R13: typing in a paragraph over a 200-row table restyles at most two paragraphs a keystroke, in one storage edit,
    /// building no font.
    @Test func typingOverALongTableStaysInItsParagraph() throws {
        let rows = (1...200).map { "| \($0) | x |\n" }.joined()
        let editor = try Rhythm("Para.\n\n| a | b |\n|---|---|\n" + rows, caret: 5)
        defer { editor.close() }
        let storage = try #require(editor.view.textStorage)
        let edits = Count()
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { _ in
            MainActor.assumeIsolated { edits.value += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let fonts = try FontCount()
        defer { fonts.restore() }
        for keystroke in 0..<8 {
            let restyles = editor.view.styler.restyles
            edits.value = 0
            LatencyProbe.stamps.removeAll()
            LatencyProbe.enabled = true
            editor.view.insertText("a", replacementRange: editor.view.selectedRange())
            LatencyProbe.enabled = false
            let restyled = (editor.view.string as NSString).substring(with: editor.view.styler.restyled)
            let paragraphs = restyled.components(separatedBy: "\n").count - (restyled.hasSuffix("\n") ? 1 : 0)
            #expect(editor.view.styler.restyles - restyles == 1, "keystroke \(keystroke)")
            #expect(paragraphs <= 2, "keystroke \(keystroke) restyled \(restyled.debugDescription)")
            #expect(edits.value == 1, "keystroke \(keystroke) made \(edits.value) storage edits")
            #expect(fonts.made == 0, "keystroke \(keystroke) built \(fonts.made) fonts")
        }
        #expect(editor.view.string.hasPrefix("Para.aaaaaaaa\n\n| a | b |"))
    }

    /// The find bar, Check Document Now and accessibility keep the editor on TextKit 2, which Live's drawing needs: the
    /// switch to TextKit 1 that would put the note in Source never comes.
    @Test func findSpellingAndAccessibilityKeepTextKit2() throws {
        let editor = try Rhythm("A note with a tpyo.\n\n- an item\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")
        defer { editor.close() }
        let switched = Count()
        let observer = NotificationCenter.default.addObserver(forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: editor.view, queue: nil) { _ in
            MainActor.assumeIsolated { switched.value += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let find = NSMenuItem()
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        editor.view.performTextFinderAction(find)
        editor.view.checkTextInDocument(nil)
        #expect(!(editor.view.accessibilityChildren() ?? []).isEmpty)
        editor.settle()
        #expect(editor.view.textLayoutManager != nil)
        #expect(switched.value == 0)
        #expect(!editor.view.styler.showsSource)
    }
}
