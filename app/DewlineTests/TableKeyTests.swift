import AppKit
import Testing
@testable import Dewline

/// An editor in a window that is never ordered front.
@MainActor
private struct Editor {
    let window: NSWindow
    let view: EditorTextView

    init(_ text: String, at caret: String) {
        let scrollView = EditorTextView.scrollView()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        view = scrollView.documentView as! EditorTextView
        view.string = text
        window.makeFirstResponder(view)
        place(at: caret)
    }

    var text: String { view.string }
    var caret: Int { view.selectedRange().location }

    func find(_ string: String) -> Int {
        (view.string as NSString).range(of: string).location
    }

    /// The caret after the first occurrence of `string`.
    func place(at string: String) {
        view.setSelectedRange(NSRange(location: find(string) + (string as NSString).length, length: 0))
    }

    /// Runs `edit` in its own undo group, as an event would.
    func edit(_ edit: () -> Void) {
        let undo = view.styler.undoManager
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        edit()
        undo.endUndoGrouping()
    }

    /// The menu command `command`, as the Format menu and the Table submenu send it.
    func run(_ command: TableEditing) {
        let item = NSMenuItem(title: command.name, action: #selector(EditorTextView.editTableItem(_:)), keyEquivalent: "")
        item.tag = command.rawValue
        edit { view.editTableItem(item) }
    }

    /// The context menu for a right-click on the first character of `string`.
    func menu(at string: String) throws -> NSMenu? {
        let rect = window.convertFromScreen(view.firstRect(forCharacterRange: NSRange(location: find(string), length: 1), actualRange: nil))
        let click = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: rect.midX, y: rect.midY), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        return view.menu(for: click)
    }
}

@MainActor
struct TableKeyTests {
    static let text = "Intro\n\n| a | b | c |\n|---|---|---|\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n| 7 | 8 | 9 |\n"

    /// T5: Return goes to the same column one row down; on the last row it adds an empty row with the same cells and
    /// changes no other line; on that empty row it ends the table with a blank line and a fresh line after it.
    /// Option-Return in a table does what Return does.
    @Test func returnMovesDownAndAddsThenEndsTheTable() {
        let editor = Editor(Self.text, at: "6")
        editor.edit { editor.view.insertNewline(nil) }
        #expect(editor.text == Self.text)
        #expect(editor.caret == editor.find("9") + 1)
        editor.edit { editor.view.insertNewline(nil) }
        let added = Self.text + "|   |   |   |\n"
        #expect(editor.text == added)
        #expect(editor.caret == editor.find("|   |   |   |") + 10)
        editor.view.styler.undoManager.undo()
        #expect(editor.text == Self.text)
        editor.view.styler.undoManager.redo()
        #expect(editor.text == added)
        editor.place(at: "|   |   | ")
        editor.edit { editor.view.insertNewline(nil) }
        #expect(editor.text == Self.text + "\n\n")
        #expect(editor.caret == Self.text.utf16.count + 1)
        #expect(editor.view.styler.fresh == editor.caret)
        #expect(editor.view.styler.tables.range(at: editor.caret) == nil)

        let option = Editor(Self.text, at: "5")
        option.edit { option.view.insertNewlineIgnoringFieldEditor(nil) }
        #expect(option.text == Self.text)
        #expect(option.caret == option.find("8") + 1)
    }

    /// T9: Delete Row removes the caret's line and Delete Column one cell and one pipe from every line, and nothing
    /// else; neither removes the header or a table's only column. A right-click in a table opens its Table submenu.
    @Test func deleteRowAndColumnAndTheTableSubmenu() throws {
        let row = Editor(Self.text, at: "5")
        row.run(.deleteRow)
        #expect(row.text == Self.text.replacingOccurrences(of: "| 4 | 5 | 6 |\n", with: ""))
        #expect(row.caret == row.find("8") + 1)
        let header = Editor(Self.text, at: "b")
        header.run(.deleteRow)
        #expect(header.text == Self.text)

        let column = Editor(Self.text, at: "b")
        column.run(.deleteColumn)
        #expect(column.text == "Intro\n\n| a | c |\n|---|---|\n| 1 | 3 |\n| 4 | 6 |\n| 7 | 9 |\n")
        #expect(column.caret == column.find("c") + 1)
        column.view.styler.undoManager.undo()
        #expect(column.text == Self.text)
        let only = Editor("| a |\n|---|\n| 1 |\n", at: "1")
        only.run(.deleteColumn)
        #expect(only.text == "| a |\n|---|\n| 1 |\n")

        let menu = try #require(try Editor(Self.text, at: "Intro").menu(at: "5"))
        let table = try #require(menu.items.first?.submenu)
        #expect(menu.items.first?.title == "Table")
        #expect(table.items.map(\.title) == ["Insert Row Above", "Insert Row Below", "Insert Column Left", "Insert Column Right", "Delete Row", "Delete Column"])
        #expect(table.items.map(\.tag) == TableEditing.menu.map(\.rawValue))
        let prose = try Editor(Self.text, at: "Intro").menu(at: "Intro")
        #expect(prose?.items.first?.title != "Table")
    }
}
