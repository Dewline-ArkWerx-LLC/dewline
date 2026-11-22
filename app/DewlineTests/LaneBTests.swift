import AppKit
import MdCore
import Testing
@testable import Dewline

/// Review navigation and badges: the rail at rest, the off-screen chip, writer badges, Quick Open and Find in Files.
@MainActor
struct LaneBTests {
    /// A note open in a window that is never shown, with the change engine's store in a temporary folder.
    @MainActor
    private struct Note {
        let folder: URL
        let url: URL
        let document: MarkdownDocument
        let textView: EditorTextView
        let live: LiveFile
        let rail: Rail

        init(_ text: String) throws {
            folder = FileManager.default.temporaryDirectory.appending(path: "dewline-laneb-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            url = folder.appending(path: "plan.md")
            try Data(text.utf8).write(to: url)
            document = MarkdownDocument()
            document.engine = try ChangeEngine(store: folder.appending(path: "snapshots"))
            try document.read(from: url, ofType: "net.daringfireball.markdown")
            document.makeWindowControllers()
            textView = try #require(document.textView)
            live = try #require(document.live)
            let scrollView = try #require(textView.enclosingScrollView)
            rail = try #require(scrollView.verticalScroller as? Rail)
            textView.window?.setContentSize(NSSize(width: 1400, height: 600))
            textView.window?.layoutIfNeeded()
            scrollView.scrollerStyle = .overlay
            // The rail measures the note, as it does 150 ms after the note opens.
            NotificationCenter.default.post(name: LiveFile.changesDidChange, object: live)
        }

        /// Another app writes `text` and the note takes it in.
        func write(_ text: String) async throws {
            try Data(text.utf8).write(to: url)
            await live.refresh()
        }

        /// Whether an overlay rail the note isn't scrolling shows; AppKit puts back the system's scroller style as the
        /// note lays out, so this sets overlay first.
        func showsAtRest() -> Bool {
            rail.scrollerStyle = .overlay
            return rail.showing
        }

        func close() {
            document.close()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// A note longer than its window, whose last section is below the view.
    private static let plan = "# Plan\n\n" + (1...120).map { "Line \($0) of the plan.\n\n" }.joined() + "## Backoff\n\nCap at 60 s.\n"

    @Test func aWaitingChangeKeepsItsMarkOnAnOverlayRailAtRest() async throws {
        let note = try Note(Self.plan)
        defer { note.close() }
        #expect(!note.showsAtRest())
        try await note.write(Self.plan.replacingOccurrences(of: "Line 1 of", with: "Line one of"))
        let id = try #require(note.live.changes.first { $0.value.marked }?.key)
        #expect(note.showsAtRest())
        note.live.decide(id, .keep)
        #expect(!note.showsAtRest())
    }

    @Test func aChangeBelowTheViewPinsAChipUntilItIsOnScreen() async throws {
        let note = try Note(Self.plan)
        defer { note.close() }
        try await note.write(Self.plan.replacingOccurrences(of: "Cap at 60 s.", with: "Cap at 90 s."))
        let chip = try #require(note.rail.labels.items.first)
        #expect(chip.text.string.contains("1 more below \u{00B7} Backoff"))
        #expect(chip.text.string.hasSuffix("\u{2303}\u{2318}\u{2193}"))
        note.textView.scrollRangeToVisible(NSRange(location: (note.textView.string as NSString).length - 1, length: 0))
        #expect(note.rail.labels.items.isEmpty)
        note.textView.scroll(.zero)
        #expect(note.rail.labels.items.isEmpty)
    }
}
