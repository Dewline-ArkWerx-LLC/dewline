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

    @Test func anInlineGhostHangsOnceTheWindowNarrowsPastIt() async throws {
        let before = "We will ship the new build to all customers on Friday morning.\n"
        let note = try Note(before)
        defer { note.close() }
        note.textView.window!.setContentSize(NSSize(width: 1400, height: 600))
        try Data(before.replacingOccurrences(of: " morning", with: "").utf8).write(to: note.url)
        await note.live.refresh()
        let id = try #require(note.live.changes.first { $0.value.marked && !$0.value.removed.isEmpty }?.key)
        #expect((note.textView.marks.hangers[id]?.view as? Ghost)?.inlineWidth != nil)
        note.textView.window!.setContentSize(NSSize(width: 480, height: 600))
        await waitForMain { (note.textView.marks.hangers[id]?.view as? Ghost).map { $0.inlineWidth == nil } ?? false }
        await waitForMain()
        #expect(try note.line(of: note.location(of: "Friday")) == note.line(of: note.location(of: "Friday") + 6))
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

extension LaneATests {
    // MARK: Code files

    @Test func aCodeChangeSetsItsOldLineAboveTheNewOneAsADiffWithKeepAndRevertInView() async throws {
        let before = "fn main() {\n    let total = waits.sum();\n    println!(\"{total}\");\n}\n"
        let after = before.replacingOccurrences(of: "waits.sum()", with: "waits.iter().sum::<u64>()")
        let note = try Note(before, name: "main.rs")
        defer { note.close() }
        #expect(note.textView.styler.code == "rs")
        try Data(after.utf8).write(to: note.url)
        await note.live.refresh()
        let marks = note.textView.marks
        let ghosts = marks.hangers.values.compactMap { $0.view as? Ghost }
        #expect(ghosts.count == 1)
        let ghost = try #require(ghosts.first)
        #expect(ghost.shown == "    let total = waits.sum();")
        #expect(ghost.inlineWidth == nil)
        // The old line takes the space above the new one, with no gap.
        let line = note.location(of: "    let total")
        let storage = try #require(note.textView.textStorage)
        await waitForMain { (storage.attribute(.paragraphStyle, at: line, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0 >= ghost.frame.height }
        marks.relayout()
        let top = try note.lineTop(of: line)
        #expect(ghost.frame.minY < top && abs(ghost.frame.maxY - top) < 1)
        // The ruler marks the old line with its old number and "−", the new one with "+".
        let diff = marks.diff
        #expect(diff.removed.count == 1 && diff.removed.first?.at == line && diff.removed.first?.lines == 1 && diff.removed.first?.added == 0)
        #expect(diff.written.contains { NSLocationInRange($0.location, NSRange(location: line, length: 30)) })
        // The stamp folds under the change, inside the view, with Keep and Revert.
        let stamp = try #require(note.stamps.first)
        #expect(stamp.folded && stamp.frame.maxX <= note.textView.visibleRect.maxX)
        let buttons = stamp.subviews.compactMap { $0 as? StampButton }.filter { !$0.isHidden && $0.frame.maxX <= stamp.bounds.maxX }
        #expect(buttons.contains { $0.accessibilityLabel()?.hasPrefix("Keep") == true } && buttons.contains { $0.accessibilityLabel()?.hasPrefix("Revert") == true })
        // A typesetting error on the change's line rises onto its stamp.
        let numbers = try #require(note.textView.enclosingScrollView?.verticalRulerView as? LineNumbers)
        numbers.errors = [2: "unknown variable: waits"]
        #expect(try #require(note.stamps.first).accessibilityLabel()?.hasSuffix("Breaks the build: unknown variable: waits") == true)
        numbers.errors = [4: "unclosed delimiter"]
        #expect(try #require(note.stamps.first).accessibilityLabel()?.contains("Breaks the build") == false)
    }

    // MARK: Stamps

    @Test func everyStampShowsKeepAndRevertInTheBodysSizeWithItsKeys() async throws {
        let before = "# Plan\n\nShip on Friday.\n\nTest on Thursday.\n"
        let note = try Note(before)
        defer { note.close() }
        note.textView.window!.setContentSize(NSSize(width: 1400, height: 800))
        let outside = before.replacingOccurrences(of: "Friday.", with: "Friday at noon.")
        try Data(outside.utf8).write(to: note.url)
        await note.live.refresh()
        try await note.claudeWrites(outside, outside.replacingOccurrences(of: "Thursday.", with: "Thursday and Friday."))
        let stamps = note.stamps
        #expect(stamps.count == 2)
        for stamp in stamps {
            #expect(!stamp.folded)
            let buttons = stamp.subviews.compactMap { $0 as? StampButton }.filter { !$0.isHidden && $0.accessibilityLabel()?.isEmpty == false }
            #expect(buttons.count >= 2)
            let keep = try #require(buttons.first { $0.accessibilityLabel()?.hasPrefix("Keep") == true })
            #expect(keep.font?.pointSize == ChangeStamp.textSize)
            #expect(keep.attributedTitle.string.contains("\u{2318}\u{21A9}"))
        }
        #expect(ChangeStamp.textSize == max(10, (ThemeStore.shared.bodyFont.pointSize * 0.69).rounded()))
    }

    @Test func aNamedWritersChangeTakesNoSolidUnderlineAndAnotherAppsKeepsItsDashes() async throws {
        let before = "# Plan\n\nShip on Friday.\n\nTest on Thursday.\n"
        let note = try Note(before)
        defer { note.close() }
        let outside = before.replacingOccurrences(of: "Friday.", with: "Friday at noon.")
        try Data(outside.utf8).write(to: note.url)
        await note.live.refresh()
        let marks = note.textView.marks
        marks.relayout()
        func underlines() -> [CAShapeLayer] {
            (marks.layer?.sublayers ?? []).flatMap { $0.sublayers ?? [] }.compactMap { $0 as? CAShapeLayer }
        }
        #expect(underlines().contains { $0.lineDashPattern != nil })
        let id = try #require(note.live.changes.first { $0.value.marked }?.key)
        note.live.keep(id)
        try await note.claudeWrites(outside, outside.replacingOccurrences(of: "Thursday.", with: "Thursday and Friday."))
        marks.relayout()
        let assisted = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast || NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
        #expect(underlines().isEmpty != assisted)
    }

    @Test func aSecondChangeInAParagraphTakesATickOnItsRule() async throws {
        let note = try Note("# Plan\n\nShip on Friday. Test it on Thursday.\n")
        defer { note.close() }
        try Data("# Plan\n\nShip on Monday. Test it on Tuesday.\n".utf8).write(to: note.url)
        await note.live.refresh()
        #expect(note.live.changes.values.filter(\.marked).count == 2)
        let marks = note.textView.marks
        marks.relayout()
        let ticks = (marks.layer?.sublayers ?? []).flatMap { $0.sublayers ?? [] }.filter { $0.frame.size == CGSize(width: 4, height: 1.5) }
        #expect(ticks.count == 1)
    }

    @Test func aRevertLeavesAReceiptWhereItsStampStood() async throws {
        let before = "# Plan\n\nShip on Friday.\n"
        let note = try Note(before)
        defer { note.close() }
        note.textView.window!.setContentSize(NSSize(width: 1400, height: 800))
        try await note.claudeWrites(before, "# Plan\n\nShip on Friday at noon.\n")
        let stamp = try #require(note.stamps.first)
        let (_, change) = try #require(note.live.changes.first { $0.value.marked })
        note.textView.setSelectedRange(NSRange(location: change.range.location + 1, length: 0))
        let place = stamp.frame
        note.textView.revertChange(nil)
        #expect(note.textView.string == before)
        let receipt = try #require(note.textView.marks.receipts.first)
        #expect(receipt.stringValue == "Reverted \u{00B7} \u{2318}Z" && receipt.superview === note.textView)
        #expect(abs(receipt.frame.maxX - place.maxX) < 1 && abs(receipt.frame.minY - place.minY) < 1)
    }

    @Test func codexWithAnUntrustedHookIsAskedForTrust() {
        #expect(ChangeStamp.codexNeedsTrust("Version: 0.7.0\n  Codex: installed in /Users/a/.codex/hooks.json; needs trust\n"))
        #expect(!ChangeStamp.codexNeedsTrust("Version: 0.7.0\n  Codex: installed in /Users/a/.codex/hooks.json\n"))
        #expect(!ChangeStamp.codexNeedsTrust("  Claude Code: installed in /Users/a/.claude/settings.json; needs trust\n"))
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

    /// A code file opens with its URL, which picks its language.
    init(_ text: String, name: String = "plan.md") throws {
        folder = URL(filePath: NSTemporaryDirectory()).resolvingSymlinksInPath().appending(path: "dewline-lane-a-\(UUID().uuidString)")
        let files = folder.appending(path: "files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        url = files.appending(path: name)
        try Data(text.utf8).write(to: url)
        document = MarkdownDocument()
        document.engine = try ChangeEngine(store: folder.appending(path: "snapshots"))
        try document.read(from: url, ofType: MarkdownDocument.type)
        if !name.hasSuffix(".md") { document.fileURL = url }
        document.makeWindowControllers()
        textView = try #require(document.textView)
        live = try #require(document.live)
    }

    /// Claude Code's write of `after` over `before` in session s1, as its hooks report it.
    func claudeWrites(_ before: String, _ after: String) async throws {
        let realpath = Darwin.realpath(url.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? url.path
        func hex(_ text: String) -> String {
            contentHash(Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let use = { (hash: String, declared: String?) in
            ControlSocket.Claim.ToolUse(id: "toolu_\(UUID().uuidString)", tool: .write, path: realpath, hash: hash, declared: declared)
        }
        let first = use(hex(before), hex(after))
        LiveFile.claim(ControlSocket.Claim(vendor: .claude, session: "s1", event: .preToolUse(first)), engine: document.engine!)
        try Data(after.utf8).write(to: url)
        LiveFile.claim(
            ControlSocket.Claim(vendor: .claude, session: "s1", event: .postToolUse(.init(id: first.id, tool: .write, path: realpath, hash: hex(after), declared: nil))),
            engine: document.engine!)
        await waitForMain { live.changes.values.contains { $0.marked && $0.origin == .agent(.claude, session: "s1") } }
    }

    /// The stamps showing, in text order.
    var stamps: [ChangeStamp] {
        textView.marks.relayout()
        return textView.subviews.compactMap { $0 as? ChangeStamp }.filter { !$0.isHidden }.sorted { $0.frame.minY < $1.frame.minY }
    }

    /// The top of the text of the line holding `index`, below any space before its paragraph, in the text view.
    func lineTop(of index: Int) throws -> CGFloat {
        let (fragment, line, _, _) = try line(at: index)
        return textView.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
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
