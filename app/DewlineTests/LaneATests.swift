import AppKit
import MdCore
import Testing
@testable import Dewline

/// Change anatomy in the editor: bullets, ghosts, line breaks and stamps, each in a note opened in a window that is
/// never shown, with the engine's store in a temporary folder.
@MainActor
struct LaneATests {
    // MARK: Bullets

    @Test func aListsBulletsDrawWithTheirLinesWhenAFoldedStampMovesThem() async throws {
        let note = try Note("Intro line.\n\n- one\n- two\n")
        defer { note.close() }
        note.textView.window!.setContentSize(NSSize(width: 420, height: 600))
        let two = note.location(of: "- two")
        await waitForMain { note.isHidden(two) }
        let top = try #require(note.textView.baseline(at: two))
        try Data("Intro line, changed.\n\n- one\n- two\n".utf8).write(to: note.url)
        await note.live.refresh()
        // The folded stamp's bar opens under the intro and moves the list down.
        await waitForMain { (note.textView.baseline(at: note.location(of: "- two")) ?? top) > top }
        #expect(try note.fragmentInks(over: note.location(of: "- two")))
        #expect(try note.fragmentInks(over: note.location(of: "- one")))
    }

    // MARK: Line breaks

    @Test func aPeriodAfterInlineCodeStaysOnTheCodesLine() async throws {
        let note = try Note("The delivery logic lives in `src/delivery/`. Handlers in `src/handlers/` follow it.\n")
        defer { note.close() }
        let slash = note.location(of: "/`.")
        await waitForMain { note.isHidden(slash + 1) }
        var widths = Set<Int>()
        for width in stride(from: 280, through: 1000, by: 3) {
            note.textView.window!.setContentSize(NSSize(width: CGFloat(width), height: 400))
            widths.insert(try note.line(of: slash + 2))
            #expect(try note.line(of: slash) == note.line(of: slash + 2), "window \(width) pt")
        }
        // The widths tried wrap the sentence at more than one place.
        #expect(widths.count > 1)
    }

    // MARK: Ghosts

    @Test func aRemovalWiderThanTheRestOfItsLineHangsInsteadOfPushingItsWordDown() async throws {
        let before = "We will ship the new build to all customers on Friday morning.\n"
        let after = "We will ship the new build to all customers on Friday.\n"
        let note = try Note(before)
        defer { note.close() }
        let font = ThemeStore.shared.bodyFont
        let fits = NSAttributedString(string: after, attributes: [.font: font]).size().width
        let full = NSAttributedString(string: before, attributes: [.font: font]).size().width
        // A column that holds the new sentence on one line but not the old one.
        var found = false
        for width in stride(from: 240, through: 1400, by: 4) {
            note.textView.window!.setContentSize(NSSize(width: CGFloat(width), height: 600))
            let column = note.textView.textContainer!.column - 2 * note.textView.textContainer!.lineFragmentPadding
            if column > fits + 8, column < full - 8 {
                found = true
                break
            }
        }
        try #require(found)
        try Data(after.utf8).write(to: note.url)
        await note.live.refresh()
        let (id, change) = try #require(note.live.changes.first { $0.value.marked && !$0.value.removed.isEmpty })
        #expect(change.removed.contains("morning"))
        let ghost = try #require(note.textView.marks.hangers[id]?.view as? Ghost)
        #expect(ghost.inlineWidth == nil)
        await waitForMain { note.textView.marks.relayout(); return note.textView.marks.hangers[id] != nil }
        #expect(try note.line(of: note.location(of: "Friday")) == 0)
    }

    @Test func anInlineGhostSitsFlushAgainstThePunctuationAfterIt() async throws {
        let note = try Note("Ship the build on Friday morning.\n")
        defer { note.close() }
        note.textView.window!.setContentSize(NSSize(width: 1000, height: 600))
        try Data("Ship the build on Friday.\n".utf8).write(to: note.url)
        await note.live.refresh()
        let (id, change) = try #require(note.live.changes.first { $0.value.marked && !$0.value.removed.isEmpty })
        let ghost = try #require(note.textView.marks.hangers[id]?.view as? Ghost)
        let width = try #require(ghost.inlineWidth)
        let storage = try #require(note.textView.textStorage)
        await waitForMain { storage.attribute(.kern, at: change.range.location - 1, effectiveRange: nil) as? CGFloat == width }
        note.textView.marks.relayout()
        let period = try note.glyphMinX(at: note.location(of: "."))
        // Within the ghost's rounding up to whole points, short of a space.
        #expect(abs(ghost.frame.maxX - period) < 1)
    }

    @Test func aRewriteAcrossLinesHangsItsOldTextAsOneBlock() async throws {
        let before = "# Meeting\n\n- Ali will send the draft today\n- Bo owns the release train\n- Cy checks the numbers twice\n- Di books the big room\n\nEnd.\n"
        let after = "# Meeting\n\nAli sends the draft, Bo runs the release, and Cy and Di check numbers and the room.\n\nEnd.\n"
        let note = try Note(before)
        defer { note.close() }
        note.textView.window!.setContentSize(NSSize(width: 1000, height: 700))
        try Data(after.utf8).write(to: note.url)
        await note.live.refresh()
        let marked = note.live.changes.filter(\.value.marked)
        #expect(marked.values.filter { !$0.removed.allSatisfy(\.isWhitespace) }.count > 1)
        let ghosts = marked.keys.compactMap { note.textView.marks.hangers[$0]?.view as? Ghost }
        #expect(ghosts.count == 1)
        let ghost = try #require(ghosts.first)
        #expect(ghost.inlineWidth == nil)
        for words in ["Ali will send", "Bo owns the release", "Di books the big room"] {
            #expect(ghost.shown.contains(words))
        }
    }
}

/// A note the change engine opens in a window that is never shown.
@MainActor
private struct Note {
    let folder: URL
    let url: URL
    let document: MarkdownDocument
    let textView: EditorTextView
    let live: LiveFile

    init(_ text: String, name: String = "plan.md") throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "dewline-lane-a-\(UUID().uuidString)")
        let files = folder.appending(path: "files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        url = files.appending(path: name)
        try Data(text.utf8).write(to: url)
        document = MarkdownDocument()
        document.engine = try ChangeEngine(store: folder.appending(path: "snapshots"))
        try document.read(from: url, ofType: "net.daringfireball.markdown")
        document.makeWindowControllers()
        textView = try #require(document.textView)
        live = try #require(document.live)
    }

    func close() {
        document.close()
        try? FileManager.default.removeItem(at: folder)
    }

    func location(of text: String) -> Int {
        (textView.string as NSString).range(of: text).location
    }

    /// Whether the character at `index` is styled hidden.
    func isHidden(_ index: Int) -> Bool {
        guard let storage = textView.textStorage, index < storage.length else { return false }
        return storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor == NSColor.clear
    }

    /// The layout fragment and line holding the character at `index`, and its offset in the fragment.
    private func line(at index: Int) throws -> (fragment: NSTextLayoutFragment, line: NSTextLineFragment, number: Int, offset: Int) {
        let layout = try #require(textView.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: index))
        layout.ensureLayout(for: NSTextRange(location: location))
        let fragment = try #require(layout.textLayoutFragment(for: location))
        let offset = content.offset(from: fragment.rangeInElement.location, to: location)
        let number = try #require(fragment.textLineFragments.firstIndex { NSLocationInRange(offset, $0.characterRange) })
        return (fragment, fragment.textLineFragments[number], number, offset)
    }

    /// The line of its paragraph the character at `index` sits on, from 0.
    func line(of index: Int) throws -> Int {
        try line(at: index).number
    }

    /// Whether the layout fragment of the line holding `index` draws anything over that character, by itself.
    func fragmentInks(over index: Int) throws -> Bool {
        let (fragment, line, _, offset) = try line(at: index)
        let left = Int((line.typographicBounds.minX + line.locationForCharacter(at: offset).x).rounded(.down))
        let right = Int((line.typographicBounds.minX + line.locationForCharacter(at: offset + 1).x).rounded(.up))
        let width = Int(ceil(fragment.layoutFragmentFrame.width)) + 1
        let height = Int(ceil(fragment.layoutFragmentFrame.height)) + 1
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        fragment.draw(at: .zero, in: context)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in max(left, 0)..<min(right, width) where pixels[(y * width + x) * 4 + 3] > 0 {
                return true
            }
        }
        return false
    }

    /// Where CoreText sets the glyph of the character at `index`, in the text view.
    func glyphMinX(at index: Int) throws -> CGFloat {
        let (fragment, line, _, offset) = try line(at: index)
        let ctLine = CTLineCreateWithAttributedString(line.attributedString.attributedSubstring(from: line.characterRange))
        let left = textView.textContainerOrigin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
        for run in CTLineGetGlyphRuns(ctLine) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetStringIndices(run, CFRange(), &indices)
            if let k = indices.firstIndex(of: offset - line.characterRange.location) { return left + positions[k].x }
        }
        throw CocoaError(.featureUnsupported)
    }
}
