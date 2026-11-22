import AppKit
import MdCore
import Testing
@testable import Dewline

/// The main window as ux-v4 lays it out, built offscreen: the title, the tab row, the sidebar's header, the status
/// bar, the right pane's preview, Show Sidebar (B1) and restoring a place (B2).
@MainActor @Suite(.serialized)
struct ShellV4Tests {
    private static let type = "net.daringfireball.markdown"

    /// A folder "Field Notes" holding `files`, deleted when the test ends.
    private func folder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "shell-v4-\(UUID().uuidString)/Field Notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: root.appending(path: name)) }
        return root
    }

    /// `url` read into a document on its own change engine, as the app's are, without the shared store.
    private func document(_ url: URL) throws -> MarkdownDocument {
        let document = MarkdownDocument()
        document.engine = try ChangeEngine(store: url.deletingLastPathComponent().deletingLastPathComponent().appending(path: "store-\(UUID().uuidString)"))
        try document.read(from: url, ofType: Self.type)
        document.fileURL = url
        document.fileType = Self.type
        NSDocumentController.shared.addDocument(document)
        return document
    }

    private func close(_ controllers: [MainWindowController]) {
        for controller in controllers {
            if let document = controller.document as? NSDocument {
                document.removeWindowController(controller)
                NSDocumentController.shared.removeDocument(document)
            }
            controller.window?.isReleasedWhenClosed = false
            controller.window?.orderOut(nil)
        }
    }

    private func settle(_ seconds: Double = 0.3) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    @Test func theTitleIsTheNoteAndTheSubtitleItsFolder() async throws {
        Offscreen.install()
        defer { Offscreen.uninstall() }
        let root = try folder(["Launch plan.md": "# Launch plan\n\nShip it.\n", "Ideas.md": "# Ideas\n"])
        let main = MainWindowController(folder: Folder(root))
        main.display(try document(root.appending(path: "Launch plan.md")))
        main.showWindow(nil)
        Offscreen.main = main.window
        defer { close([main]) }
        await settle(0.5)
        let window = try #require(main.window)
        #expect(window.title == "Launch plan")
        #expect(window.subtitle == "Field Notes")
        #expect(window.toolbar?.items.map(\.itemIdentifier).contains(WindowToolbar.tabs) == true)
        #expect(main.tabName == "Launch plan")
        #expect(main.savedState?.hasPrefix("Saved") == true)
        #expect(main.wordCount.hasSuffix("words"))
        #expect(main.textView?.selectedRange() == NSRange(location: 14, length: 0), "a note opens past its H1")
        await main.placeUpdate?.value
        #expect(main.statusBar.idle == "Launch plan.md:2:1", "the idle status bar names the caret's place")
    }

    @Test func eachTabsTitleRowHoldsTheWindowsTabs() async throws {
        Offscreen.install()
        defer { Offscreen.uninstall() }
        let root = try folder(["a.md": "# A\n", "b.md": "# B\n"])
        let main = MainWindowController(folder: Folder(root))
        main.display(try document(root.appending(path: "a.md")))
        main.showWindow(nil)
        func strip(_ controller: MainWindowController) -> TabStrip? {
            controller.window?.toolbar?.items.first { $0.itemIdentifier == WindowToolbar.tabs }?.view as? TabStrip
        }
        let second = MainWindowController(folder: main.folder, joining: main)
        second.display(try document(root.appending(path: "b.md")))
        defer { close([main, second]) }
        await settle()
        #expect(main.tabs.tabs.map(\.tabFileName) == ["a.md", "b.md"])
        #expect(strip(main)?.tabs === main.tabs && strip(second)?.tabs === main.tabs)
    }

    @Test func theSidebarListsTheTreeUnderTheFoldersOwnName() async throws {
        Offscreen.install()
        defer { Offscreen.uninstall() }
        let root = try folder(["plan.md": "# Plan\n", "CLAUDE.md": "# Notes\n"])
        let main = MainWindowController(folder: Folder(root))
        main.showWindow(nil)
        defer { close([main]) }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let outline = try #require(all(main.window!.contentView!).compactMap { $0 as? NSOutlineView }.first)
        for _ in 0..<200 where outline.numberOfRows < 3 { await settle(0.01) }
        let kinds = (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? SidebarNode)?.kind }
        #expect(!kinds.contains { if case .root = $0 { true } else { false } })
        #expect(all(main.window!.contentView!).contains { ($0 as? FolderPicker)?.accessibilityLabel()?.hasPrefix("Folder Field Notes") == true })
        let names = kinds.compactMap { kind -> String? in
            if case .entry(let entry) = kind { return entry.url.lastPathComponent }
            if case .section(let title) = kind { return title }
            return nil
        }
        #expect(names == ["CLAUDE.md", "plan.md"])
    }

    @Test func writerBadgesShowADotAndTheCountNeverALetter() {
        let origins: [ChangeEngine.Origin] = [.git(action: nil), .external, .agent(.claude, session: "s"), .agent(.demo, session: "d")]
        let widths = origins.map { WaitingBadge.width([WaitingCount(writer: MarkWriter($0), count: 2)]) }
        #expect(Set(widths).count == 1, "a dot, not a letter, so every writer's badge is the same width")
        #expect(WaitingBadge.tip([WaitingCount(writer: MarkWriter(.external), count: 2)]) == "Another app: 2 changes waiting")
        #expect(WaitingCount(writer: MarkWriter(.git(action: nil)), count: 1).spoken == "1 git change waiting")
    }

    @Test func aLongTabNameLosesItsMiddleAndKeepsItsExtension() {
        let title = "0003-retries-in-postgres.md"
        let fitted = TabStrip.fit(title, stem: 24, in: 120)
        let width = ceil((fitted as NSString).size(withAttributes: [.font: Chrome.label]).width)
        #expect(fitted.hasPrefix("0003") && fitted.contains("\u{2026}") && fitted.hasSuffix("gres.md"))
        #expect(width <= 120 && width > 104, "the name runs to the tab's end")
        #expect(TabStrip.fit("spec-for-the-retry-queue.md \u{00B7} api", stem: 24, in: 120).hasSuffix(".md \u{00B7} api"))
        #expect(TabStrip.fit(title, stem: 24, in: 400) == title)
    }

    @Test func chromeButtonsArePushButtonsAndSkipIsInline() {
        var pressed = 0
        let done = ChromeButton("Done") { pressed += 1 }
        let setUp = ChromeButton("Set Up", style: .bordered) {}
        let open = ChromeButton("Open a Folder\u{2026}", style: .filled) {}
        #expect(done.bezelStyle == .inline && setUp.bezelStyle == .push && open.bezelStyle == .push)
        #expect(open.bezelColor != nil && setUp.bezelColor == nil)
        done.performClick(nil)
        #expect(pressed == 1)
    }

    @Test func theOutlineHidesWhileTheNoteHasOneHeading() async throws {
        Offscreen.install()
        defer { Offscreen.uninstall() }
        let root = try folder(["plan.md": "# Plan\n\nShip it.\n\n## Steps\n"])
        let main = MainWindowController(folder: nil)
        main.display(try document(root.appending(path: "plan.md")))
        main.showWindow(nil)
        defer { close([main]) }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let outline = try #require(all(main.window!.contentView!).compactMap { $0 as? NSOutlineView }.first)
        func rows() -> [String] {
            (0..<outline.numberOfRows).compactMap { row in
                switch (outline.item(atRow: row) as? SidebarNode)?.kind {
                case .section(let title): title
                case .heading(let heading): heading.title
                default: nil
                }
            }
        }
        await waitForMain { rows() == ["Outline", "Plan", "Steps"] }
        #expect(rows() == ["Outline", "Plan", "Steps"])
        let text = try #require(main.textView)
        let steps = (text.string as NSString).range(of: "\n## Steps")
        text.insertText("", replacementRange: steps)
        await waitForMain { rows().isEmpty }
        #expect(rows().isEmpty, "one heading tells nothing the note's first line doesn't")
    }

    @Test func showSidebarReachesTheSplitFromTheText() async throws {
        Offscreen.install()
        defer { Offscreen.uninstall() }
        let root = try folder(["a.md": "# A\n\ntext\n"])
        let main = MainWindowController(folder: Folder(root))
        main.display(try document(root.appending(path: "a.md")))
        main.showWindow(nil)
        defer { close([main]) }
        let split = try #require(main.window?.contentViewController?.children.first as? StationSplitController)
        let textView = try #require(main.textView)
        let item = NSMenuItem(title: "Show Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "")
        #expect(NSApp.target(forAction: item.action!, to: nil, from: item) == nil || split.responds(to: item.action))
        #expect(split.validateUserInterfaceItem(item) && item.title == "Hide Sidebar")
        #expect(textView.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil))
        await settle(0.5)
        #expect(split.splitViewItems[0].isCollapsed)
    }

    @Test func aRestoredPlaceStaysPutAfterTheNextFrame() async throws {
        Offscreen.install()
        defer { Offscreen.uninstall() }
        let text = "# Long\n\n" + (1...240).map { "Paragraph \($0). " + String(repeating: "Words that wrap the line. ", count: 3) }.joined(separator: "\n\n") + "\n"
        let root = try folder(["long.md": text])
        let main = MainWindowController(folder: Folder(root))
        main.display(try document(root.appending(path: "long.md")))
        main.showWindow(nil)
        defer { close([main]) }
        await settle(0.5)
        let textView = try #require(main.textView)
        let target = (textView.string as NSString).range(of: "Paragraph 150.").location
        textView.scrollRangeToVisible(NSRange(location: target, length: 0))
        textView.hold(target, at: 40)
        await settle(0.3)
        let saved = try #require(main.place)
        main.restore(saved)
        await settle(0.3)
        let after = try #require(main.place)
        #expect(after.top == saved.top)
        #expect(abs(after.offset - saved.offset) < 1)
    }

    @Test func theStatusBarShowsOneMessageAtATime() {
        let bar = StatusBar()
        bar.post(.init(id: "loads", kind: .info, text: "Agents read 2 files here"))
        bar.post(.init(id: "update", kind: .question, text: "Check for updates once a day?"))
        #expect(bar.shown?.id == "update")
        bar.post(.init(id: "export", kind: .result, text: "Exported", untilTyping: true))
        #expect(bar.shown?.id == "export")
        bar.typed()
        #expect(bar.shown?.id == "update")
        bar.clear("update")
        #expect(bar.shown?.id == "loads")
        bar.post(.init(id: "held", kind: .problem, text: "Not saved"))
        bar.post(.init(id: "awaited", kind: .request, text: "A terminal is waiting for this note"))
        #expect(bar.shown?.id == "held")
        #expect(bar.isHidden == false)
        bar.clear("held")
        bar.clear("awaited")
        bar.clear("loads")
        #expect(bar.isHidden)
        bar.reserved = true
        #expect(!bar.isHidden)
        bar.reserved = false
        bar.idle = "docs/spec.md:3:5"
        #expect(!bar.isHidden && bar.shown == nil)
        #expect(MainWindowController.place("docs/spec.md", at: 9, in: "# A\n\nabcdef\n") == "docs/spec.md:3:5")
        #expect(MainWindowController.place("a.md", at: 12, in: "# A\n\nabcdef\n") == "a.md:4:1")
    }

    @Test func quickOpenNamesANewNoteForWhatWasTyped() {
        #expect(QuickOpenPanel.noteName("plan") == "plan.md")
        #expect(QuickOpenPanel.noteName("a/b: c") == "a-b- c.md")
        #expect(QuickOpenPanel.noteName("Notes.md") == "Notes.md")
    }
}
