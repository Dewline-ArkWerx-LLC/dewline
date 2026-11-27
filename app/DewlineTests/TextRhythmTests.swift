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
        // column's edge and the heading's text starts on it.
        let head = lines[0].at
        editor.place(head + 3)
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

    /// R4: a heading that starts the note takes no space above it: its line starts at the container's top inset.
    @Test func aHeadingThatStartsTheNoteSitsAtTheInset() throws {
        let editor = try Rhythm("# Title\n\nText.")
        defer { editor.close() }
        let title = try editor.line(at: 2)
        #expect(editor.view.textContainerInset.height == 24)
        #expect(abs(title.minY - editor.view.textContainerOrigin.y) <= 0.5, "the title's line starts at \(title.minY)")
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
