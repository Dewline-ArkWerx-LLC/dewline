import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Dewline

/// An editor in a window that is never ordered front.
@MainActor
private struct Editor {
    let window: NSWindow
    let view: EditorTextView

    init(_ text: String, caret: Int? = nil) {
        let scrollView = EditorTextView.scrollView()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        view = scrollView.documentView as! EditorTextView
        view.string = text
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: caret ?? text.utf16.count, length: 0))
    }

    var text: String { view.string }
    var caret: Int { view.selectedRange().location }

    func undo() {
        if view.styler.undoManager.groupingLevel > 0 { view.styler.undoManager.endUndoGrouping() }
        view.styler.undoManager.undo()
    }

    /// Runs `edit` in its own undo group, as an event would.
    func edit(_ edit: () -> Void) {
        let undo = view.styler.undoManager
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        edit()
        undo.endUndoGrouping()
    }

    /// The box of the line holding the character at `index` in the view, without the space above it.
    func line(at index: Int) throws -> NSRect {
        let layout = try #require(view.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: index))
        layout.ensureLayout(for: NSTextRange(location: location))
        let fragment = try #require(layout.textLayoutFragment(for: location))
        let offset = content.offset(from: fragment.rangeInElement.location, to: location)
        let line = try #require(fragment.textLineFragments.first { NSLocationInRange(offset, $0.characterRange) } ?? fragment.textLineFragments.first)
        let origin = view.textContainerOrigin
        return line.typographicBounds.offsetBy(dx: origin.x + fragment.layoutFragmentFrame.minX, dy: origin.y + fragment.layoutFragmentFrame.minY)
    }

    /// Where the character at `index` starts, from the column's text edge.
    func x(at index: Int) -> CGFloat {
        let rect = view.convert(window.convertFromScreen(view.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)), from: nil)
        return rect.minX - view.textContainerOrigin.x - (view.textContainer?.lineFragmentPadding ?? 0)
    }

    /// Whether the character at `index` is laid out hidden, as a fold leaves it.
    func isHidden(_ index: Int) -> Bool {
        let storage = view.textStorage!
        return (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont) == MarkdownStyler.hiddenFont
            && storage.attribute(.dewlineBlock, at: index, effectiveRange: nil) != nil
    }
}

@MainActor
struct SmartListTests {
    @Test func returnContinuesTheList() {
        for (text, next) in [("- one", "- "), ("* one", "* "), ("1. one", "2. "), ("9) one", "10) "), ("- [x] done", "- [ ] "), ("  - one", "  - ")] {
            let editor = Editor(text)
            editor.view.insertNewline(nil)
            #expect(editor.text == text + "\n" + next)
            #expect(editor.caret == editor.text.utf16.count)
        }
    }

    @Test func returnSplitsAnItemAndKeepsItsLineEnding() {
        let editor = Editor("- one two\r\n- three", caret: 5)
        editor.view.insertNewline(nil)
        #expect(editor.text == "- one\r\n-  two\r\n- three")
        #expect(editor.caret == 9)
    }

    @Test func returnOnAnEmptyItemEndsTheList() {
        let editor = Editor("- one\n- ")
        editor.view.insertNewline(nil)
        #expect(editor.text == "- one\n\n")
        #expect(editor.caret == editor.text.utf16.count)
        let task = Editor("1. [ ] one\n2. [ ] ")
        task.view.insertNewline(nil)
        #expect(task.text == "1. [ ] one\n\n")
    }

    @Test func returnOutsideAListIsPlain() {
        let editor = Editor("plain")
        editor.view.insertNewline(nil)
        #expect(editor.text == "plain\n")
        let marker = Editor("- one", caret: 0)
        marker.view.insertNewline(nil)
        #expect(marker.text == "\n- one")
    }

    @Test func continuationIsOneUndoableEdit() {
        let editor = Editor("- one")
        editor.view.insertNewline(nil)
        #expect(editor.text == "- one\n- ")
        editor.undo()
        #expect(editor.text == "- one")
    }

    @Test func tabIndentsAndShiftTabOutdents() {
        let editor = Editor("- one\n- two")
        editor.view.insertTab(nil)
        #expect(editor.text == "- one\n  - two")
        #expect(editor.caret == editor.text.utf16.count)
        editor.view.insertBacktab(nil)
        #expect(editor.text == "- one\n- two")
        #expect(editor.caret == editor.text.utf16.count)
        editor.view.insertTab(nil)
        editor.undo()
        #expect(editor.text == "- one\n- two")

        let ordered = Editor("1. one\n2. two")
        ordered.view.insertTab(nil)
        #expect(ordered.text == "1. one\n   2. two")
        let prose = Editor("prose")
        prose.view.insertTab(nil)
        #expect(prose.text == "prose\t")
    }

    /// L8: Tab moves an item with its children onto its previous sibling's text, in the list's spaces or tabs, as one
    /// edit; a first child has no sibling to move under and stays.
    @Test func tabMovesAnItemAndItsChildrenUnderItsSibling() {
        for (text, indented) in [("- a\n- b\n  - c", "- a\n  - b\n    - c"), ("- a\n- b\n\t- c", "- a\n\t- b\n\t\t- c")] {
            let editor = Editor(text, caret: 7)
            editor.view.insertTab(nil)
            #expect(editor.text == indented)
            #expect(editor.caret == (indented as NSString).range(of: "b").location + 1)
            editor.undo()
            #expect(editor.text == text)
        }
        let child = Editor("- a\n  - b")
        child.view.insertTab(nil)
        #expect(child.text == "- a\n  - b")
        #expect(child.caret == child.text.utf16.count)
    }

    /// L9: Return on an empty nested item moves it to its parent's indent; on an empty top-level item it leaves a blank
    /// line and a fresh line after the list, where typing makes a paragraph at the column's edge a blank line below.
    @Test func returnOnAnEmptyItemOutdentsItThenEndsTheList() throws {
        let nested = Editor("- a\n  - b\n  - ")
        nested.view.insertNewline(nil)
        #expect(nested.text == "- a\n  - b\n- ")
        #expect(nested.caret == nested.text.utf16.count)
        let editor = Editor("- b\n- c\n- ")
        editor.view.insertNewline(nil)
        #expect(editor.text == "- b\n- c\n\n")
        #expect(editor.caret == editor.text.utf16.count && editor.view.styler.fresh == editor.caret)
        editor.view.insertText("Text", replacementRange: editor.view.selectedRange())
        #expect(editor.text == "- b\n- c\n\nText")
        let text = (editor.text as NSString).range(of: "Text").location
        #expect(abs(editor.x(at: text)) <= 0.5)
        let gap = try editor.line(at: text).minY - editor.line(at: 4).maxY
        #expect(abs(gap - ThemeStore.shared.bodyLineHeight / 2) <= 0.5, "\(gap) pt above Text")
    }

    /// L10: in a quote, Return and Tab keep the line's markers and measure the indent after them.
    @Test func listKeysKeepAQuotesMarkers() {
        let editor = Editor("> - a")
        editor.view.insertNewline(nil)
        #expect(editor.text == "> - a\n> - ")
        editor.view.insertText("b", replacementRange: editor.view.selectedRange())
        editor.view.insertTab(nil)
        #expect(editor.text == "> - a\n>   - b")
        #expect(editor.caret == editor.text.utf16.count)
    }

    /// L11: Backspace at an item's text outdents a nested item and turns a top-level marker into blanks, which make the
    /// line the item above's continuation; at that line's text, past its hidden blanks, Backspace joins it to the item.
    @Test func backspaceAtAnItemsTextOutdentsThenJoins() {
        let nested = Editor("- a\n  - b", caret: 8)
        nested.view.deleteBackward(nil)
        #expect(nested.text == "- a\n- b")
        #expect(nested.caret == 6)
        let editor = Editor("- a\n- b", caret: 6)
        editor.edit { editor.view.deleteBackward(nil) }
        #expect(editor.text == "- a\n  b")
        #expect(editor.caret == 6)
        // The list layout hides a continuation line's leading blanks this way.
        editor.view.textStorage!.addAttribute(.dewlineSkip, value: true, range: NSRange(location: 4, length: 2))
        editor.edit { editor.view.deleteBackward(nil) }
        #expect(editor.text == "- ab")
        #expect(editor.caret == 3)
        editor.undo()
        #expect(editor.text == "- a\n  b")
        // At a nested item's marker, past its hidden indent, the item stays an item.
        let marker = Editor("- a\n  - b", caret: 6)
        marker.view.textStorage!.addAttribute(.dewlineSkip, value: true, range: NSRange(location: 4, length: 2))
        marker.edit { marker.view.deleteBackward(nil) }
        #expect(marker.text.hasPrefix("- a\n") && marker.text.hasSuffix("- b"))
    }
}

@MainActor
struct FoldTests {
    static let text = "# A\n\npara one\n\n## B\n\npara two\n\n# C\n\nthree\n\n```\ncode\n```\n"

    @Test func foldHidesAndUnfoldRestoresWithNoByteChange() throws {
        let editor = Editor(Self.text, caret: 0)
        let one = (Self.text as NSString).range(of: "para one").location
        let two = (Self.text as NSString).range(of: "para two").location
        let three = (Self.text as NSString).range(of: "three").location
        editor.view.foldBlock(nil)
        #expect(editor.text == Self.text)
        #expect(editor.view.styler.folds == [NSRange(location: 4, length: (Self.text as NSString).range(of: "# C").location - 5)])
        #expect(editor.isHidden(one) && editor.isHidden(two))
        #expect(!editor.isHidden(0) && !editor.isHidden(three))
        editor.view.unfoldBlock(nil)
        #expect(editor.text == Self.text)
        #expect(editor.view.styler.folds.isEmpty)
        #expect(!editor.isHidden(one) && !editor.isHidden(two))
    }

    @Test func foldAllAndUnfoldAll() {
        let editor = Editor(Self.text, caret: (Self.text as NSString).range(of: "para two").location)
        editor.view.foldAll(nil)
        #expect(editor.text == Self.text)
        // Three headings with text under them and the fence.
        #expect(editor.view.styler.folds.count == 4)
        #expect(editor.caret == 3)
        let code = (Self.text as NSString).range(of: "code").location
        #expect(editor.isHidden(code))
        editor.view.unfoldAll(nil)
        #expect(editor.view.styler.folds.isEmpty)
        #expect(!editor.isHidden(code))
        #expect(editor.text == Self.text)
    }

    @Test func caretMovingInUnfolds() {
        let editor = Editor(Self.text, caret: 0)
        editor.view.foldBlock(nil)
        let one = (Self.text as NSString).range(of: "para one").location
        editor.view.setSelectedRange(NSRange(location: one + 2, length: 0))
        #expect(editor.view.styler.folds.isEmpty)
        #expect(!editor.isHidden(one))
    }

    @Test func editsAboveMoveAFoldAndEditsInsideUnfoldIt() {
        let editor = Editor(Self.text, caret: 0)
        editor.view.foldBlock(nil)
        let fold = editor.view.styler.folds[0]
        editor.view.insertText("X", replacementRange: NSRange(location: 2, length: 0))
        #expect(editor.view.styler.folds == [NSRange(location: fold.location + 1, length: fold.length)])
        editor.view.textStorage!.replaceCharacters(in: NSRange(location: fold.location + 3, length: 1), with: "Q")
        #expect(editor.view.styler.folds.isEmpty)
    }
}

@MainActor
struct WordCountTests {
    static let sample = """
        ---
        title: Not counted here
        ---

        # Hello world

        Some **bold** text with a [link](https://example.com/path) and `code here`.

        - one item
        - [ ] task two

        ```swift
        let x = 1
        ```

        """

    @Test func countsProseOnly() {
        let map = BlockMap()
        let text = Self.sample as NSString
        _ = map.textDidChange(text, edited: NSRange(location: 0, length: text.length), delta: text.length)
        let blocks = map.blocks(in: NSRange(location: 0, length: text.length))
        let hello = text.range(of: "Hello world")
        let count = WordCount.count(text, in: NSRange(location: 0, length: text.length), blocks: blocks, selection: hello)
        #expect(count.total == 13)
        #expect(count.selected == 2)
    }

    @Test func labels() {
        #expect(WordCount.label(total: 1234, selected: nil) == "1,234 words")
        #expect(WordCount.label(total: 1234, selected: 12) == "12 of 1,234 words")
        #expect(WordCount.label(total: 1, selected: nil) == "1 word")
    }
}

@MainActor
struct SmartPunctuationTests {
    @Test func offByDefault() throws {
        let suite = "dev.arkwerx.dewline.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ThemeStore(defaults: defaults)
        #expect(!store.smartPunctuation)
        store.smartPunctuation = true
        #expect(ThemeStore(defaults: defaults).smartPunctuation)
    }

    @Test func skipsCode() {
        let text = "Say \"hi\" -- `x \"y\"`\n\n```\na -- \"b\"\n```\n"
        let editor = Editor(text, caret: 0)
        let string = text as NSString
        let prose = string.range(of: "\"hi\"")
        let dash = string.range(of: "--")
        let span = string.range(of: "\"y\"")
        let fenced = string.range(of: "\"b\"")
        let results = [
            NSTextCheckingResult.quoteCheckingResult(range: NSRange(location: prose.location, length: 1), replacementString: "“"),
            NSTextCheckingResult.dashCheckingResult(range: dash, replacementString: "—"),
            NSTextCheckingResult.quoteCheckingResult(range: NSRange(location: span.location, length: 1), replacementString: "“"),
            NSTextCheckingResult.quoteCheckingResult(range: NSRange(location: fenced.location, length: 1), replacementString: "“"),
            NSTextCheckingResult.dashCheckingResult(range: string.range(of: "--", options: .backwards), replacementString: "—"),
        ]
        let kept = editor.view.styler.textView(
            editor.view, didCheckTextIn: NSRange(location: 0, length: string.length), types: NSTextCheckingAllTypes, options: [:],
            results: results, orthography: NSOrthography.defaultOrthography(forLanguage: "en"), wordCount: 0
        )
        #expect(kept.map(\.range) == [results[0].range, results[1].range])
    }
}

@MainActor
struct ImagePasteTests {
    @Test func pasteWritesAFileBesideTheDocumentAndLinksIt() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dewline-paste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        let taken = folder.appending(path: "image-\(date)-1.png")
        try Data("keep".utf8).write(to: taken)

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.arkwerx.dewline.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)

        let editor = Editor("Hi ")
        editor.view.documentFolder = folder
        #expect(editor.view.readSelection(from: pasteboard, type: .png))
        let name = "image-\(date)-2.png"
        #expect(editor.text == "Hi ![](\(name))")
        #expect(editor.caret == editor.text.utf16.count)
        #expect(try Data(contentsOf: folder.appending(path: name)) == png)
        #expect(try Data(contentsOf: taken) == Data("keep".utf8))
        editor.undo()
        #expect(editor.text == "Hi ")
    }

    @Test func pastedJPEGAndGIFKeepTheirBytesAndTIFFBecomesPNG() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dewline-paste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        let tiff = try #require(bitmap.tiffRepresentation)
        let gif = folder.appending(path: "dropped.gif")
        try #require(bitmap.representation(using: .gif, properties: [:])).write(to: gif)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.arkwerx.dewline.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let editor = Editor("")
        editor.view.documentFolder = folder

        pasteboard.clearContents()
        pasteboard.setData(jpeg, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
        #expect(editor.view.readablePasteboardTypes.contains(NSPasteboard.PasteboardType(UTType.jpeg.identifier)))
        #expect(editor.view.insertImages(from: pasteboard))
        #expect(try Data(contentsOf: folder.appending(path: "image-\(date)-1.jpeg")) == jpeg)

        pasteboard.clearContents()
        pasteboard.writeObjects([gif as NSURL])
        #expect(editor.view.insertImages(from: pasteboard))
        #expect(try Data(contentsOf: folder.appending(path: "image-\(date)-1.gif")) == Data(contentsOf: gif))

        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        #expect(editor.view.insertImages(from: pasteboard))
        let png = try Data(contentsOf: folder.appending(path: "image-\(date)-1.png"))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(editor.text == "![](image-\(date)-1.jpeg)![](image-\(date)-1.gif)![](image-\(date)-1.png)")
    }

    @Test func textOnThePasteboardPastesAsText() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.arkwerx.dewline.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("words", forType: .string)
        let editor = Editor("")
        editor.view.documentFolder = FileManager.default.temporaryDirectory
        #expect(!editor.view.insertImages(from: pasteboard))
    }
}

@MainActor
struct RichPasteTests {
    private func pasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.arkwerx.dewline.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    @Test func copyAsMarkdownWritesTheSelectionOrTheWholeNote() {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let editor = Editor("# Title\n\nSome **bold** text.\n", caret: 0)
        editor.view.writeMarkdown(to: board)
        #expect(board.string(forType: .string) == editor.text)
        #expect(board.string(forType: NSPasteboard.PasteboardType("net.daringfireball.markdown")) == editor.text)
        editor.view.setSelectedRange(NSRange(location: 9, length: 13))
        editor.view.writeMarkdown(to: board)
        #expect(board.string(forType: .string) == "Some **bold**")
    }

    @Test func copyAsHTMLWritesTheExportersBody() {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let editor = Editor("# Title\n\nSome **bold** text.\n", caret: 0)
        editor.view.writeHTML(to: board)
        let html = board.string(forType: .html) ?? ""
        #expect(html.contains("<h1 id=\"title\">Title</h1>"))
        #expect(html.contains("<p>Some <strong>bold</strong> text.</p>"))
        #expect(!html.contains("<body>") && !html.contains("<style>"))
        #expect(board.string(forType: .string) == html)
    }

    @Test func richHTMLPastesAsMarkdown() {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        board.setString("""
            <meta charset="utf-8"><h2>Plan</h2><p>Ship <b>this</b> <a href="https://example.com/a">now</a>, <code>x*y</code>.</p>
            <ul><li>one</li><li>two<ul><li>deep</li></ul></li></ul><blockquote><p>Quoted <i>words</i></p></blockquote>
            <table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>
            """, forType: .html)
        board.setString("Plan\nShip this now, x*y.\none\ntwo\ndeep\nQuoted words\nA B\n1 2", forType: .string)
        let editor = Editor("Before ", caret: nil)
        editor.view.history.perform("Paste") { #expect(editor.view.pasteHTMLAsMarkdown(from: board)) }
        #expect(editor.text == """
            Before ## Plan

            Ship **this** [now](https://example.com/a), `x*y`.

            - one
            - two
              - deep

            > Quoted *words*

            | A | B |
            | --- | --- |
            | 1 | 2 |
            """)
        editor.undo()
        #expect(editor.text == "Before ")
    }

    @Test func markdownTextAndPlainSpansPasteAsText() {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let editor = Editor("")
        // A Markdown editor's copy: its plain text is the source.
        board.setString("<h1>Title</h1><p><b>bold</b></p>", forType: .html)
        board.setString("# Title\n\n**bold**", forType: .string)
        #expect(!editor.view.pasteHTMLAsMarkdown(from: board))
        // A code editor's copy: colored spans, nothing Markdown marks.
        board.clearContents()
        board.setString("<div><span style=\"color:#f00\">let</span> x = 1</div>", forType: .html)
        board.setString("let x = 1", forType: .string)
        #expect(!editor.view.pasteHTMLAsMarkdown(from: board))
        // Into a code block, HTML pastes as its plain text.
        board.clearContents()
        board.setString("<p>Ship <b>this</b></p>", forType: .html)
        board.setString("Ship this", forType: .string)
        let fence = Editor("```\n\n```\n", caret: 4)
        #expect(!fence.view.pasteHTMLAsMarkdown(from: board))
        board.clearContents()
        board.setString("words", forType: .string)
        #expect(!editor.view.pasteHTMLAsMarkdown(from: board))
        #expect(editor.text == "")
    }
}

@MainActor
struct WritingModeTests {
    /// The ranges drawn in a rendering color, which leaves the storage alone.
    private func dimmed(_ view: EditorTextView) -> [NSRange] {
        let layout = view.textLayoutManager!
        let content = layout.textContentManager!
        var ranges: [NSRange] = []
        layout.enumerateRenderingAttributes(from: content.documentRange.location, reverse: false) { _, attributes, range in
            if attributes[.foregroundColor] != nil {
                let start = content.offset(from: content.documentRange.location, to: range.location)
                let found = NSRange(location: start, length: content.offset(from: range.location, to: range.endLocation))
                if let last = ranges.last, NSMaxRange(last) == start { ranges[ranges.count - 1] = NSUnionRange(last, found) } else { ranges.append(found) }
            }
            return true
        }
        return ranges
    }

    @Test func focusDimsAllButTheCaretsBlock() {
        let text = "One para.\n\nTwo para.\n\nThree.\n"
        let editor = Editor(text, caret: 13)
        let colors = editor.view.textStorage!.attributedSubstring(from: NSRange(location: 0, length: (text as NSString).length))
        editor.view.focusMode = true
        #expect(dimmed(editor.view) == [NSRange(location: 0, length: 11), NSRange(location: 21, length: 8)])
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(dimmed(editor.view) == [NSRange(location: 10, length: 19)])
        #expect(editor.view.textStorage!.isEqual(to: colors))
        editor.view.focusMode = false
        #expect(dimmed(editor.view).isEmpty)
    }

    @Test func aNoteLaysOutItsViewportOnLoadAndAsItsWindowShows() throws {
        let scrollView = EditorTextView.scrollView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        let view = try #require(scrollView.documentView as? EditorTextView)
        let layout = try #require(view.textLayoutManager)
        // A window behind the front one draws nothing yet: the load itself lays the viewport out.
        view.string = "# Standup\n\n- Shipped the retry queue\n- Reviewed the backoff\n"
        #expect(layout.textViewportLayoutController.viewportRange?.endLocation.compare(layout.documentRange.endLocation) == .orderedSame)
        view.textStorage!.append(NSAttributedString(string: "- Third item\n"))
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(layout.textViewportLayoutController.viewportRange?.endLocation.compare(layout.documentRange.endLocation) == .orderedSame)
    }

    @Test func theColumnKeepsTheRailsRoomInEveryScrollerStyle() throws {
        let editor = Editor("# Plan\n\nShip it.\n")
        let scrollView = try #require(editor.view.enclosingScrollView)
        var margins: [CGFloat] = []
        for style in [NSScroller.Style.legacy, .overlay] {
            scrollView.scrollerStyle = style
            scrollView.tile()
            editor.view.setFrameSize(scrollView.contentSize)
            margins.append(editor.view.textContainerInset.width)
        }
        #expect(margins[0] == margins[1])
    }

    @Test func typewriterLetsTheEndsReachTheMiddle() {
        let editor = Editor("text")
        let height = editor.view.enclosingScrollView!.contentView.bounds.height
        editor.view.typewriterMode = true
        #expect(editor.view.textContainerInset.height == (height / 2).rounded())
        editor.view.typewriterMode = false
        #expect(editor.view.textContainerInset.height == 24)
    }
}
