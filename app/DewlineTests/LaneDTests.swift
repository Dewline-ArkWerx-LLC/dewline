import AppKit
import Testing
@testable import Dewline

/// First run, the empty folder page, hook setup and Settings (wave 17, lane D).
@MainActor
struct LaneDTests {
    /// The demo's paragraph names the stamps as the app writes them: CLAUDE CODE, not CLAUDE.
    @Test func theDemoNamesTheStampsAsTheyRead() {
        for writer in [Writer.claude, .codex, .cursor] {
            #expect(Welcome.inserted.contains(writer.name.uppercased()), "\(writer.name)")
        }
    }

    /// Settings > Appearance says how code is sized as the editor sizes it: blocks at the body's x-height, inline code at
    /// 0.9 of the text around it.
    @Test func theCodeCaptionMatchesTheEditor() throws {
        let scrollView = EditorTextView.scrollView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        let view = scrollView.documentView as! EditorTextView
        defer {
            view.string = ""
            window.close()
        }
        view.string = "Run `cargo test` now\n\n```\nlet x = 1\n```\n"
        view.styler.restyleDocument()
        let storage = try #require(view.textStorage)
        let body = MarkdownStyler.bodyFont
        let inline = try #require(storage.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)
        let block = try #require(storage.attribute(.font, at: (view.string as NSString).range(of: "let x").location, effectiveRange: nil) as? NSFont)
        #expect(abs(inline.pointSize - body.pointSize * 0.9) < 0.01)
        #expect(abs(block.pointSize - MarkdownStyler.code(matching: body).pointSize) < 0.01)
        #expect(FontSlots.codeNote.contains("blocks match the body font\u{2019}s x-height"))
        #expect(FontSlots.codeNote.contains("inline code is 0.9 of the text"))
    }
}
