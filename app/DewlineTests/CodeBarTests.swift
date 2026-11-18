import AppKit
import Testing
@testable import Dewline

@MainActor
struct CodeBarTests {
    private func editor(_ text: String) -> (NSWindow, EditorTextView) {
        let scrollView = EditorTextView.scrollView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        let view = scrollView.documentView as! EditorTextView
        view.string = text
        view.layoutSubtreeIfNeeded()
        return (window, view)
    }

    private func point(_ view: EditorTextView, at index: Int) -> NSPoint {
        let rect = view.convert(view.window!.convertFromScreen(view.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)), from: nil)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    @Test func hoveringACodeBlockShowsItsLanguageAndCopiesItsCodeWithoutFences() throws {
        let text = "Intro\n\n```rust,ignore\nfn main() {}\nlet x = 1;\n```\n\nAfter\n"
        let (window, view) = editor(text)
        defer { window.close() }
        let code = (text as NSString).range(of: "fn main")
        view.hoverCode(at: point(view, at: code.location))
        #expect(view.codeBar.block != nil)
        #expect(view.codeBar.language == "rust")
        #expect(!view.codeBar.isHidden)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.arkwerx.dewline.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        view.codeBar.pasteboard = pasteboard
        view.codeBar.copyCode()
        #expect(pasteboard.string(forType: .string) == "fn main() {}\nlet x = 1;\n")
        view.hoverCode(at: point(view, at: (text as NSString).range(of: "After").location))
        #expect(view.codeBar.block == nil)
    }

    @Test func aFenceWithoutALanguageShowsOnlyCopy() {
        let text = "```\nplain\n```\n"
        let (window, view) = editor(text)
        defer { window.close() }
        view.hoverCode(at: point(view, at: 4))
        #expect(view.codeBar.block != nil)
        #expect(view.codeBar.language.isEmpty)
    }
}
