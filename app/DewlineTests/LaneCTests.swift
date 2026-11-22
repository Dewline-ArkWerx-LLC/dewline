import AppKit
import MdCore
import Testing
@testable import Dewline

/// Earlier Versions and rendered blocks: hunks, summaries, turns and pins, the sheet's width, inline math, H1 tracking
/// and fenced Rust.
@MainActor @Suite(.serialized)
struct LaneCTests {
    private static let type = "net.daringfireball.markdown"

    /// A one-word change deep in a long note shows as one line with two either side under its line numbers: the word
    /// restoring takes out struck, the one it brings back washed, and none of the rest of the note.
    @Test func earlierVersionsShowHunksWithWordMarks() throws {
        let lines = (1...40).map { "Line \($0) says hello." }
        var old = lines
        old[29] = "Line 30 says goodbye."
        let shown = EarlierVersions.difference(from: lines.joined(separator: "\n") + "\n", to: old.joined(separator: "\n") + "\n", ink: .systemRed)
        let text = shown.string as NSString
        #expect(text.hasPrefix("Lines 28\u{2013}32\n"), "\(text)")
        #expect(!text.contains("Line 1 says") && !text.contains("Line 27 says") && !text.contains("Line 33 says"))
        let line = text.range(of: "Line 30 says hellogoodbye.")
        try #require(line.location != NSNotFound, "\(text)")
        let gone = text.range(of: "hello", range: line).location
        let back = text.range(of: "goodbye", range: line).location
        let kept = text.range(of: "says", range: line).location
        #expect(shown.attribute(.strikethroughStyle, at: gone, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(shown.attribute(.strikethroughStyle, at: back, effectiveRange: nil) == nil)
        #expect(shown.attribute(.backgroundColor, at: back, effectiveRange: nil) != nil)
        #expect(shown.attribute(.backgroundColor, at: kept, effectiveRange: nil) == nil)
        // Two changes far apart are two hunks.
        old[4] = "Line 5 says hi."
        let two = EarlierVersions.difference(from: lines.joined(separator: "\n") + "\n", to: old.joined(separator: "\n") + "\n").string
        #expect(two.components(separatedBy: "\n").filter { $0.hasPrefix("Lines ") } == ["Lines 3\u{2013}7", "Lines 28\u{2013}32"])
    }

    /// Each row says what its version changed from the one below, in words, under the heading it starts in.
    @Test func earlierVersionsSummarizeEachVersion() {
        let older = "# Plan\n\n## Backoff\n\nWait a second.\n"
        #expect(EarlierVersions.summary(of: "# Plan\n\n## Backoff\n\nWait a second, then double it.\n", over: older) == "+3 words \u{00B7} Backoff")
        #expect(EarlierVersions.summary(of: "# Plan\n\n## Backoff\n\nWait.\n", over: older) == "\u{2212}2 words \u{00B7} Backoff")
        #expect(EarlierVersions.summary(of: "Wait a minute.\n", over: "Wait a second.\n") == "+1 \u{2212}1 words")
    }

    /// Two hooked Claude Code writes a moment apart are one row, credited to Claude Code, over the version they replaced,
    /// with what they changed under it; only the selected row shows its pin; the sheet fits a 620 pt window.
    @Test func earlierVersionsFoldATurnAndShowOnePin() async throws {
        let root = URL(filePath: NSTemporaryDirectory()).resolvingSymlinksInPath().appending(path: "dewline-lane-c-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "plan.md")
        try Data("# Plan\n".utf8).write(to: url)
        let engine = try ChangeEngine(store: root.appending(path: "store"))
        let document = MarkdownDocument()
        document.engine = engine
        try document.read(from: url, ofType: Self.type)
        document.makeWindowControllers()
        defer { document.close() }
        let textView = try #require((document.windowControllers.first as? MainWindowController)?.textView)
        let live = try #require(document.live)
        let texts = ["# Plan\n", "# Plan\n\nOne.\n", "# Plan\n\nOne.\n\nTwo.\n"]
        for (index, text) in texts.enumerated().dropFirst() {
            try Self.claudeWrites(text, over: texts[index - 1], to: url, id: "toolu_\(index)", engine: engine)
            await waitForMain { textView.string == text }
        }
        await waitForMain { live.snapshots.count >= 3 }
        #expect(live.snapshots.prefix(2).allSatisfy { if case .agent(.claude, _) = $0.origin { true } else { false } }, "\(live.snapshots.map(\.origin))")

        let sheet = EarlierVersions(document, live)
        #expect(sheet.rows.map(\.count) == [2, 1])
        #expect(EarlierVersions.title(of: EarlierVersions.credited(sheet.rows[0])).hasSuffix("Claude Code"))
        await waitForMain { !sheet.summaries.isEmpty }
        #expect(sheet.summaries[EarlierVersions.credited(sheet.rows[0]).id] == "+2 words \u{00B7} Plan")
        // The current text is the newest row, so the sheet opens on the one before it.
        #expect(sheet.table.selectedRow == 1)
        let pins = (0..<2).map { row in
            (sheet.tableView(sheet.table, viewFor: sheet.table.tableColumns[1], row: row)?.subviews.first as? NSButton)?.isHidden
        }
        #expect(pins == [true, false])

        #expect(EarlierVersions.width(in: 1400) == 760)
        #expect(EarlierVersions.width(in: 620) == 580)
        #expect(EarlierVersions.width(in: 300) == 420)
        #expect(sheet.sheet.minSize.width == 420)
        for (width, list) in [(420, 200), (760, 304)] as [(CGFloat, CGFloat)] {
            sheet.sheet.setContentSize(NSSize(width: width, height: 460))
            sheet.sheet.contentView?.layoutSubtreeIfNeeded()
            #expect(sheet.table.enclosingScrollView?.frame.width == list, "at \(width)")
        }
    }

    /// Inline math is set so its x-height is the body's.
    @Test func inlineMathMatchesTheBodyXHeight() throws {
        let font = ThemeStore.shared.bodyFont
        let drawing = try mathDrawing("x", size: Double(InlineMath.size(matching: font)), color: 0x0000_00ff)
        #expect(abs(drawing.size.height - drawing.depth - font.xHeight) < 0.25, "\(drawing.size.height - drawing.depth) for \(font.xHeight)")
    }

    /// H1 is tracked in by a hundredth of an em.
    @Test func headingOneTracksInSlightly() {
        let heading = ThemeStore.shared.heading(1)
        #expect(abs(heading.kern + 0.01 * heading.font.pointSize) < 0.001)
    }

    /// A `rust` fence in a note is colored by its syntax: `fn` takes the keyword color once the line draws.
    @Test func aRustFenceIsHighlighted() async throws {
        let root = URL(filePath: NSTemporaryDirectory()).resolvingSymlinksInPath().appending(path: "dewline-lane-c-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "# Worker\n\n```rust\nfn main() {}\n```\n"
        try Data(text.utf8).write(to: root.appending(path: "notes.md"))
        let controller = MainWindowController(folder: Folder(root))
        defer { (controller.document as? NSDocument)?.close() }
        controller.open(root.appending(path: "notes.md"), newTab: false)
        let textView = try #require(controller.textView)
        let layout = try #require(textView.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let at = try #require(content.location(content.documentRange.location, offsetBy: (textView.string as NSString).range(of: "fn").location))
        func resolved(_ color: NSColor?) -> NSColor? {
            var result: NSColor?
            textView.effectiveAppearance.performAsCurrentDrawingAppearance { result = color?.usingColorSpace(.sRGB) }
            return result
        }
        let area = NSRect(x: 0, y: 0, width: 600, height: 300)
        let bitmap = try #require(textView.bitmapImageRepForCachingDisplay(in: area))
        await waitForMain {
            layout.ensureLayout(for: layout.documentRange)
            // Colors are set when a line is drawn, and a window that is not on screen never draws: draw into a bitmap.
            textView.cacheDisplay(in: area, to: bitmap)
            var color: NSColor?
            layout.enumerateRenderingAttributes(from: at, reverse: false) { _, attributes, _ in
                color = attributes[.foregroundColor] as? NSColor
                return false
            }
            return resolved(color) == resolved(ThemeStore.shared.color(.codeKeyword))
        }
    }

    /// Claude Code's write of `after` over `before`, between its PreToolUse and PostToolUse claims.
    private static func claudeWrites(_ after: String, over before: String, to url: URL, id: String, engine: ChangeEngine) throws {
        let path = Darwin.realpath(url.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? url.path
        func hex(_ text: String) -> String { contentHash(Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        func use(_ hash: String, _ declared: String?) -> ControlSocket.Claim.ToolUse {
            ControlSocket.Claim.ToolUse(id: id, tool: .edit, path: path, hash: hash, declared: declared)
        }
        LiveFile.claim(ControlSocket.Claim(vendor: .claude, session: "s1", event: .preToolUse(use(hex(before), hex(after)))), engine: engine)
        try Data(after.utf8).write(to: url, options: .atomic)
        LiveFile.claim(ControlSocket.Claim(vendor: .claude, session: "s1", event: .postToolUse(use(hex(after), nil))), engine: engine)
    }
}
