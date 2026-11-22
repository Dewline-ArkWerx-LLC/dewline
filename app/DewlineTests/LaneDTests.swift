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

    /// The guide points at the stamp's own button before its keys, asks for the Keep without deciding for the reader,
    /// and names no one agent at its close.
    @Test func theGuidePointsAtTheButtonAndNamesNoOneAgent() {
        #expect(WelcomeGuide.sentences[1].hasSuffix("Revert it with the button beside the change, or"))
        #expect(WelcomeGuide.keys[1] == "\u{2325}\u{2318}\u{232B}")
        #expect(WelcomeGuide.sentences[2] == "It also added a paragraph. Keep this one.")
        #expect(WelcomeGuide.closing.hasPrefix("Open the folder your agent works in."))
    }

    /// A setup row's command reads in SF Mono and VoiceOver hears no backticks.
    @Test func theSetupListSetsTheCommandInMono() throws {
        let status = GuideIsland.status("Opens notes from a terminal. `dewline open --wait` works as $EDITOR.")
        #expect(status.string == "Opens notes from a terminal. dewline open --wait works as $EDITOR.")
        func mono(_ word: String) throws -> Bool {
            let font = try #require(status.attribute(.font, at: (status.string as NSString).range(of: word).location, effectiveRange: nil) as? NSFont)
            return font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }
        #expect(try mono("open --wait"))
        #expect(try !mono("terminal"))
        #expect(try !mono("$EDITOR"))
    }

    /// Skip is borderless text in ink2, legible rather than greyed out.
    @Test func skipIsBorderlessInInk2() {
        let skip = ChromeButton("Skip") {}
        #expect(!skip.isBordered)
        #expect(skip.contentTintColor == Chrome.color(.ink2))
    }

    /// The status bar takes no height until something shows, or while reserved, and keeps it once something has, so
    /// a later message doesn't move the page.
    @Test func theStatusBarKeepsItsHeightOnceShown() {
        let fresh = StatusBar()
        #expect(fresh.isHidden)
        fresh.reserved = true
        #expect(!fresh.isHidden)
        fresh.reserved = false
        #expect(fresh.isHidden)
        let bar = StatusBar()
        bar.post(.init(id: "undo", kind: .result, text: "Reverted \u{00B7} \u{2318}Z to undo", untilTyping: true))
        bar.typed()
        #expect(bar.shown == nil)
        #expect(!bar.isHidden)
        #expect(bar.constraints.contains { $0.firstAttribute == .height && $0.constant == StatusBar.height })
    }

    /// The hook sheet leads with what hooks send, then names the events it adds, the file with ~ and how far it reaches;
    /// a long path loses its middle rather than breaking across lines.
    @Test func theHookSheetLeadsWithPrivacyAndNamesTheEvents() {
        let events = ["PreToolUse", "PostToolUse", "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "PostToolUseFailure", "InstructionsLoaded"]
        let missing = [HookSetup.Missing(agent: "Claude Code", file: NSHomeDirectory() + "/.claude/settings.json", events: events, entries: events)]
        let text = HookSetup.informative(missing, in: nil)
        #expect(text.hasPrefix("Hooks send file paths and hashes, never content, and nothing leaves this Mac."))
        #expect(text.hasSuffix("\n\nAdds Dewline to 8 Claude Code hook events (PreToolUse, PostToolUse, Stop, \u{2026}) in ~/.claude/settings.json, "
            + "for every project.\nBackup saved beside it."))
        #expect(HookSetup.shortened("/private/tmp/claude-501/dw70UCa/.claude/settings.json") == "/private/\u{2026}/dw70UCa/.claude/settings.json")
        #expect(HookSetup.shortened(NSHomeDirectory() + "/.claude/settings.json") == "~/.claude/settings.json")
    }

    /// A folder's empty page leads with the test prompt: the prompt in a code chip over Copy a Test Prompt, the accent
    /// default, the hint naming the folder to paste it in, and the folder's CLAUDE.md as a link, all on the text
    /// column's leading edge under the folder's name in the heading face.
    @Test func theEmptyPageLeadsWithTheTestPrompt() throws {
        Offscreen.install()
        defer { Offscreen.uninstall() }
        let root = FileManager.default.temporaryDirectory.appending(path: "lane-d-\(UUID().uuidString)/relay", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Data("# Relay\n".utf8).write(to: root.appending(path: "CLAUDE.md"))
        let main = MainWindowController(folder: Folder(root))
        main.showWindow(nil)
        defer {
            main.window?.isReleasedWhenClosed = false
            main.window?.orderOut(nil)
        }
        let window = try #require(main.window)
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.layoutIfNeeded()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let views = all(try #require(window.contentView))
        let buttons = views.compactMap { $0 as? NSButton }
        let copy = try #require(buttons.first { $0.title == "Copy a Test Prompt" })
        #expect(copy.keyEquivalent == "\r" && copy.bezelColor == Chrome.color(.accent))
        let open = try #require(buttons.first { $0.title == "Open CLAUDE.md" })
        #expect(!open.isBordered && open.keyEquivalent.isEmpty)
        let labels = views.compactMap { $0 as? NSTextField }
        let prompt = try #require(labels.first { $0.stringValue == MainWindowController.testPrompt })
        #expect(prompt.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        let gap = prompt.convert(prompt.bounds, to: nil).minY - copy.convert(copy.bounds, to: nil).maxY
        #expect(gap > 0 && gap < 24, "just over the button")
        let hint = try #require(labels.first { $0.stringValue.hasPrefix("Paste it into Claude Code running in ") })
        #expect(hint.stringValue == MainWindowController.hookHint(on: false, in: root))
        #expect(hint.stringValue.contains("/relay. "))
        let title = try #require(labels.first { $0.stringValue == "Dewline is watching relay" })
        #expect(title.font == ThemeStore.shared.heading(3).font)
        let page = try #require(title.superview?.superview)
        let leading = title.convert(title.alignmentRect(forFrame: title.bounds), to: page).minX
        #expect(abs(leading - (page.bounds.width - ThemeStore.shared.measure) / 2) < 1, "on the text column's leading edge")
        #expect(abs(copy.convert(copy.bounds, to: page).minX - leading) < 8)
    }

    /// File > Open… takes a folder as well as notes, and a folder opens in a window of its own.
    @Test func openTakesAFolder() throws {
        let item = try #require(MainMenu.bar().main.items.compactMap(\.submenu).first { $0.title == "File" }?.items.first { $0.title == "Open\u{2026}" })
        #expect(item.keyEquivalent == "o" && item.keyEquivalentModifierMask == .command)
        #expect(item.action == #selector(OpenPanel.run(_:)) && item.target === OpenPanel.self)
        #expect(OpenPanel.types.contains("net.daringfireball.markdown"))
    }
}
