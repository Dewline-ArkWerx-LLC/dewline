import AppKit
import Testing
@testable import Dewline

/// An editor in a window that is never ordered front.
@MainActor
private struct Editor {
    let window: NSWindow
    let view: EditorTextView

    init(_ text: String, caret: Int, width: CGFloat = 760) {
        let scrollView = EditorTextView.scrollView()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        view = scrollView.documentView as! EditorTextView
        view.string = text
        window.makeFirstResponder(view)
        place(caret)
    }

    func place(_ caret: Int) {
        view.setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// The first occurrence of `string` at or after `from`.
    func find(_ string: String, from: Int = 0) -> NSRange {
        let text = view.string as NSString
        return text.range(of: string, range: NSRange(location: from, length: text.length - from))
    }

    func rect(_ range: NSRange) -> NSRect {
        view.firstRect(forCharacterRange: range, actualRange: nil)
    }

    func rect(_ string: String, from: Int = 0) -> NSRect {
        rect(find(string, from: from))
    }

    func role(at location: Int) -> BlockLine.Role? {
        (view.textStorage!.attribute(.dewlineBlock, at: location, effectiveRange: nil) as? BlockLine)?.role
    }

    /// Runs `edit` in its own undo group, as an event would.
    func edit(_ edit: () -> Void) {
        let undo = view.styler.undoManager
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        edit()
        undo.endUndoGrouping()
    }
}

@MainActor
struct TableTests {
    static let text = "Intro\n\n| Name | Qty | Note |\n|:-----|----:|:----:|\n| apple | 3 | ok |\n| kiwi fruit | 12 | fine one |\n\nAfter\n"

    @Test func columnsAlignFromTheWidestCell() throws {
        let editor = Editor(Self.text, caret: 0)
        #expect(editor.view.string == Self.text)
        let gap = (MarkdownStyler.bodyFont.pointSize * 1.5).rounded()
        // Pipes and padding take no space.
        let head = editor.find("| Name")
        #expect(editor.rect(NSRange(location: head.location, length: 2)).width <= 0.5)
        // A caret position splits the kern before it, so a cell's start is its end less its laid-out width.
        func cell(_ string: String, skip: Int = 0) -> (start: CGFloat, end: CGFloat) {
            var range = editor.find(string)
            range = NSRange(location: range.location + skip, length: range.length - 2 * skip)
            let end = editor.rect(range).maxX
            return (end - editor.view.textStorage!.attributedSubstring(from: range).size().width, end)
        }
        // Left: every cell starts at the column's start.
        let name = cell("Name"), apple = cell("apple"), kiwi = cell("kiwi fruit")
        #expect(abs(apple.start - name.start) <= 0.5 && abs(kiwi.start - name.start) <= 0.5)
        // Right: every cell ends at the column's end, which the widest cell sets.
        let qty = cell("Qty"), three = cell(" 3 ", skip: 1), twelve = cell("12")
        #expect(abs(three.end - qty.end) <= 0.5 && abs(twelve.end - qty.end) <= 0.5)
        let first = (kiwi.end - kiwi.start).rounded(.up)
        let second = max(qty.end - qty.start, twelve.end - twelve.start).rounded(.up)
        #expect(abs(qty.end - (name.start + first + gap + second)) <= 1)
        // Center: every cell's middle is the column's, the widest cell's.
        let note = cell("Note"), ok = cell("ok"), fine = cell("fine one")
        let middle = (fine.start + fine.end) / 2
        #expect(abs((note.start + note.end) / 2 - middle) <= 1 && abs((ok.start + ok.end) / 2 - middle) <= 1)
        #expect(abs(fine.start - (qty.end + gap)) <= 1)
        // One rule, across under the head, whose delimiter row collapses so the head sits a row's pitch above the first row.
        guard case .table(let rule)? = editor.role(at: editor.find("| apple").location) else { Issue.record("no rule on a row"); return }
        #expect(!rule.across)
        guard case .table(let under)? = editor.role(at: editor.find("|:---").location) else { Issue.record("no rule under the head"); return }
        #expect(under.across && under.width == rule.width)
        let (headY, appleY, kiwiY) = (editor.rect("Name").minY, editor.rect("apple").minY, editor.rect("kiwi").minY)
        #expect(abs(abs(headY - appleY) - abs(appleY - kiwiY)) <= 1)
        #expect(Tables.alignments("|:-----|----:|:----:|---|") == [.left, .right, .center, nil])
        #expect(editor.view.string == Self.text)
    }

    @Test func theCaretsRowShowsItsSource() {
        let editor = Editor(Self.text, caret: 0)
        let row = editor.find("| apple")
        let other = editor.find("| kiwi")
        #expect(editor.rect(NSRange(location: row.location, length: 1)).width <= 0.5)
        editor.place(editor.find("apple").location + 2)
        #expect(editor.rect(NSRange(location: row.location, length: 1)).width > 2)
        #expect(editor.role(at: row.location) == nil)
        #expect(editor.rect(NSRange(location: other.location, length: 1)).width <= 0.5)
        // The head shows its delimiter row with it.
        let delimiter = editor.find("|:---")
        #expect(editor.rect(NSRange(location: delimiter.location, length: 2)).width <= 0.5)
        editor.place(editor.find("Name").location)
        #expect(editor.rect(NSRange(location: delimiter.location, length: 2)).width > 2)
        #expect(editor.rect(NSRange(location: row.location, length: 1)).width <= 0.5)
        editor.place(0)
        #expect(editor.rect(NSRange(location: delimiter.location, length: 2)).width <= 0.5)
        #expect(editor.view.string == Self.text)
    }

    @Test func columnsOnlyWidenWhileTyping() {
        let editor = Editor(Self.text, caret: 0)
        let view = editor.view
        func qtyEnd() -> CGFloat { editor.rect("Qty").maxX }
        let start = qtyEnd()
        // Shortening the widest cell keeps the column while the caret stays in the table.
        editor.place(NSMaxRange(editor.find("kiwi fruit")))
        for _ in 0..<6 { editor.edit { view.deleteBackward(nil) } }
        #expect(view.string.contains("| kiwi | 12 |"))
        #expect(abs(qtyEnd() - start) <= 0.5)
        // Leaving the table fits the columns again.
        editor.place(0)
        #expect(qtyEnd() < start - 10)
        // Typing a longer cell widens them at once.
        let narrow = qtyEnd()
        editor.place(NSMaxRange(editor.find("kiwi")))
        editor.edit { view.insertText(" and a much longer name", replacementRange: view.selectedRange()) }
        #expect(qtyEnd() > start + 10)
        #expect(qtyEnd() > narrow)
    }

    @Test func tablesAndCodeRunPastTheMeasure() throws {
        let columns = 1...7
        let table = "| " + columns.map { "column \($0)" }.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: columns.count)
            + "\n| " + columns.map { "cell \($0)" }.joined(separator: " | ") + " |\n"
        let code = String(repeating: "let x = 1; ", count: 7) + "done"
        let prose = String(repeating: "word ", count: 40) + "last"
        let editor = Editor("Intro\n\n\(table)\n```\n\(code)\n```\n\n\(prose)\n", caret: 0, width: 1200)
        let view = editor.view
        let container = try #require(view.textContainer)
        func frame(_ string: String) -> NSRect {
            view.convert(editor.window.convertFromScreen(editor.rect(string)), from: nil)
        }
        let start = view.textContainerOrigin.x + container.lineFragmentPadding
        let measure = start + container.column - 2 * container.lineFragmentPadding
        let edge = view.bounds.width - 32
        #expect(container.column < container.size.width)
        // The table keeps its natural columns, one line per row, past the measure and inside the right margin.
        let row = editor.find("| cell 1").location
        guard case .table(let rule)? = editor.role(at: row) else { Issue.record("no rule on the row"); return }
        #expect(rule.cells.isEmpty)
        #expect(start + rule.width > measure && start + rule.width <= edge)
        let layout = try #require(view.textLayoutManager)
        let location = try #require(layout.location(layout.documentRange.location, offsetBy: row))
        layout.ensureLayout(for: NSTextRange(location: location))
        let fragment = try #require(layout.textLayoutFragment(for: location))
        #expect(view.textContainerOrigin.x + fragment.layoutFragmentFrame.maxX > measure)
        #expect(frame("column 7").maxX > measure && frame("cell 7").maxX > measure && frame("cell 7").maxX <= edge)
        #expect(abs(frame("column 1").minY - frame("column 7").minY) < 1)
        // A code line runs on in its widened well; prose wraps at the measure.
        #expect(frame("done").maxX > measure && abs(frame("done").minY - frame("let").minY) < 1)
        let well = try #require(view.textStorage!.attribute(.dewlineCode, at: editor.find("let").location, effectiveRange: nil) as? CodeWell)
        let drawn = view.codeWell(well, top: frame("let"), bottom: frame("done"))
        #expect(drawn.maxX > frame("done").maxX && drawn.maxX <= edge)
        #expect(frame("last").maxX <= measure + 1 && frame("last").minY > frame("word").minY)
        #expect(view.string.hasPrefix("Intro\n\n| column 1 |"))
    }

    @Test func tabAndShiftTabMoveBetweenCellsPastTheDelimiterRow() {
        let editor = Editor(Self.text, caret: 0)
        editor.place(editor.find("Name").location + 1)
        let body = editor.find("| apple").location
        for (cell, from) in [("Qty", 0), ("Note", 0), ("apple", 0), ("3", body), ("ok", body), ("kiwi fruit", 0)] {
            editor.view.insertTab(nil)
            #expect(editor.view.selectedRange() == editor.find(cell, from: from), "Tab to \(cell)")
        }
        editor.view.insertBacktab(nil)
        #expect(editor.view.selectedRange() == editor.find("ok"))
        editor.place(editor.find("Name").location)
        editor.view.insertBacktab(nil)
        #expect(editor.view.selectedRange() == editor.find("Name"))
        #expect(editor.view.string == Self.text)
    }

    /// The table after Tab in its last cell, aligned, with the alignments kept.
    static let added = """
        Intro

        | Name       | Qty | Note     |
        | :--------- | --: | :------: |
        | apple      | 3   | ok       |
        | kiwi fruit | 12  | fine one |
        |            |     |          |

        After

        """

    @Test func tabInTheLastCellAddsAnAlignedRow() {
        let editor = Editor(Self.text, caret: 0)
        editor.place(editor.find("fine").location)
        editor.edit { editor.view.insertTab(nil) }
        #expect(editor.view.string == Self.added)
        #expect(editor.view.selectedRange() == NSRange(location: editor.find("|            |").location + 2, length: 0))
        editor.edit { editor.view.insertText("pear", replacementRange: editor.view.selectedRange()) }
        editor.view.insertTab(nil)
        #expect(editor.view.selectedRange() == NSRange(location: editor.find("pear").location + 17, length: 0))
        editor.view.styler.undoManager.undo()
        editor.view.styler.undoManager.undo()
        #expect(editor.view.string == Self.text)
    }

    @Test func insertRowsAndColumnsAndSelectTheNewCell() throws {
        func run(_ command: TableEditing, at cell: String, from: Int = 0) -> Editor {
            let editor = Editor("| a | b |\n|---|--:|\n| c | d |\n", caret: 0)
            editor.place(editor.find(cell, from: from).location)
            let item = NSMenuItem(title: command.name, action: #selector(EditorTextView.editTableItem(_:)), keyEquivalent: "")
            item.tag = command.rawValue
            #expect(editor.view.validateMenuItem(item))
            editor.edit { editor.view.editTableItem(item) }
            return editor
        }
        let below = run(.rowBelow, at: "a")
        #expect(below.view.string == "| a   | b   |\n| --- | --: |\n|     |     |\n| c   | d   |\n")
        #expect(below.view.selectedRange() == NSRange(location: 30, length: 0))
        let above = run(.rowAbove, at: "c")
        #expect(above.view.string == "| a   | b   |\n| --- | --: |\n|     |     |\n| c   | d   |\n")
        #expect(above.view.selectedRange() == NSRange(location: 30, length: 0))
        #expect(run(.rowAbove, at: "a").view.string == "| a | b |\n|---|--:|\n| c | d |\n")
        let left = run(.columnLeft, at: "d")
        #expect(left.view.string == "| a   |     | b   |\n| --- | --- | --: |\n| c   |     | d   |\n")
        #expect(left.view.selectedRange() == NSRange(location: 48, length: 0))
        let right = run(.columnRight, at: "d")
        #expect(right.view.string == "| a   | b   |     |\n| --- | --: | --- |\n| c   | d   |     |\n")
        #expect(right.view.selectedRange() == NSRange(location: 54, length: 0))
        right.view.styler.undoManager.undo()
        #expect(right.view.string == "| a | b |\n|---|--:|\n| c | d |\n")
        let crlf = Editor("| a | b |\r\n|---|---|\r\n| c | d |\r\n", caret: 0)
        crlf.view.insertBacktab(nil)
        #expect(crlf.view.selectedRange() == crlf.find("a"))
        crlf.place(crlf.find("| c").location)
        crlf.view.insertBacktab(nil)
        #expect(crlf.view.selectedRange() == crlf.find("b"))
        crlf.place(crlf.find("d").location)
        crlf.view.insertTab(nil)
        #expect(crlf.view.string == "| a   | b   |\r\n| --- | --- |\r\n| c   | d   |\r\n|     |     |\r\n")
        // Lines selected across rows take Tab as before, with no cell to move to.
        let rest = (crlf.view.string as NSString).substring(from: 20)
        crlf.view.setSelectedRange(NSRange(location: 0, length: 20))
        crlf.view.insertTab(nil)
        #expect(crlf.view.string == "\t" + rest)
        let outside = Editor("Prose\n\n| a |\n|---|\n", caret: 2)
        let item = NSMenuItem(title: "", action: #selector(EditorTextView.editTableItem(_:)), keyEquivalent: "")
        item.tag = TableEditing.rowBelow.rawValue
        #expect(!outside.view.validateMenuItem(item))
    }
}

@MainActor
struct TaskBoxTests {
    static let text = "- [ ] Buy milk\n- [x] Done\n\nEnd\n"

    @Test func aClickTogglesOneByteAndUndoRestoresIt() throws {
        let editor = Editor(Self.text, caret: Self.text.utf16.count)
        let view = editor.view
        guard case .task(let task)? = editor.role(at: 0) else { Issue.record("no box"); return }
        #expect(!task.checked && task.label == "Buy milk" && task.at == 2)
        // The box sits over its `[ ]`.
        let chars = view.convert(editor.window.convertFromScreen(editor.rect(NSRange(location: 2, length: 3))), from: nil)
        #expect(view.taskBox(at: NSPoint(x: chars.midX, y: chars.midY)) == 3)
        #expect(view.taskBox(at: NSPoint(x: chars.maxX + 40, y: chars.midY)) == nil)
        let caret = view.selectedRange()
        let point = view.convert(NSPoint(x: chars.midX, y: chars.midY), to: nil)
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        editor.edit { view.mouseDown(with: click) }
        let before = Array(Self.text.utf8), after = Array(view.string.utf8)
        #expect(after.count == before.count)
        #expect(zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset) == [3])
        #expect(view.string.hasPrefix("- [x] Buy milk"))
        #expect(view.selectedRange() == caret)
        guard case .task(let checked)? = editor.role(at: 0) else { Issue.record("no box after the click"); return }
        #expect(checked.checked)
        view.styler.undoManager.undo()
        #expect(view.string == Self.text)
    }

    @Test func boxesAreCheckboxesToAccessibility() {
        let editor = Editor(Self.text, caret: Self.text.utf16.count)
        let boxes = (editor.view.accessibilityChildren() ?? []).compactMap { $0 as? TaskBoxElement }
        #expect(boxes.map { $0.accessibilityRole() } == [.checkBox, .checkBox])
        #expect(boxes.map { $0.accessibilityLabel() } == ["Buy milk", "Done"])
        #expect(boxes.map { $0.accessibilityValue() as? Int } == [0, 1])
        editor.edit { _ = boxes.first?.accessibilityPerformPress() }
        #expect(editor.view.string == Self.text.replacingOccurrences(of: "- [ ] Buy", with: "- [x] Buy"))
    }

    @Test func theCaretShowsTheBoxsSource() {
        let editor = Editor(Self.text, caret: Self.text.utf16.count)
        #expect(editor.role(at: 0) != nil)
        editor.place(3)
        #expect(editor.role(at: 0) == nil)
        #expect(editor.view.textStorage!.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor != NSColor.clear)
        editor.place(Self.text.utf16.count)
        #expect(editor.role(at: 0) != nil)
        #expect(editor.view.string == Self.text)
    }
}
