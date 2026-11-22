import AppKit
import MdCore
import Testing
@testable import Dewline

/// Documents the change engine opens, each in a window that is never shown, with the engine's store in a temporary
/// folder.
@MainActor
struct LiveFileTests {
    private static let type = "net.daringfireball.markdown"

    @Test func anOutsideWriteLandsWithTheCaretKept() async throws {
        let file = try OpenFile("# Plan\n\nShip on Friday.\n")
        defer { file.close() }
        let caret = file.location(of: "Friday") + 2
        file.textView.setSelectedRange(NSRange(location: caret, length: 0))
        // Only the watch tells the document.
        try Data("Agent note.\n\n# Plan\n\nShip on Friday.\n".utf8).write(to: file.url)
        await waitForMain { file.textView.string == "Agent note.\n\n# Plan\n\nShip on Friday.\n" }
        #expect(file.textView.selectedRange() == NSRange(location: caret + 13, length: 0))
        #expect(!file.document.isDocumentEdited)
        #expect(file.document.isUnchanged(file.textView.string))
    }

    @Test func typingWhileAWriteLandsKeepsBoth() async throws {
        let file = try OpenFile("# Plan\n\nShip on Friday.\n")
        defer { file.close() }
        try Data("# Plan\n\nShip on Friday.\n\nAgent note.\n".utf8).write(to: file.url, options: .atomic)
        let landing = Task { await file.live.refresh() }
        // The landing reads the buffer before the keystroke, which moves the version under it.
        for _ in 0..<3 { await Task.yield() }
        file.textView.insertText("!", replacementRange: NSRange(location: 6, length: 0))
        await landing.value
        #expect(file.textView.string == "# Plan!\n\nShip on Friday.\n\nAgent note.\n")
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "# Plan\n\nShip on Friday.\n\nAgent note.\n")
    }

    @Test func anOverlappingWriteKeepsYourTextAndOpensAConflict() async throws {
        let file = try OpenFile("# Plan\n\nShip on Friday.\n")
        defer { file.close() }
        file.textView.insertText("Monday", replacementRange: NSRange(location: file.location(of: "Friday"), length: 6))
        try Data("# Plan\n\nShip on Sunday.\n".utf8).write(to: file.url)
        await file.live.refresh()
        #expect(file.textView.string == "# Plan\n\nShip on Monday.\n")
        let conflict = try #require(file.live.changes.values.first { $0.conflict })
        #expect((file.textView.string as NSString).substring(with: conflict.range).contains("Monday"))
        // Cmd-S waits for the choice, and the other version stays on disk.
        await #expect(throws: SaveConflict.self) { try await file.save() }
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "# Plan\n\nShip on Sunday.\n")
        // Autosave waits for the choice too, and deciding the last conflict runs it again.
        #expect(await file.live.autosave() == .conflict)
        let id = try #require(file.live.changes.first { $0.value.conflict }?.key)
        file.live.decide(id, .keep)
        await waitForMain { (try? String(contentsOf: file.url, encoding: .utf8)) == "# Plan\n\nShip on Monday.\n" }
    }

    @Test func aLateClaimNamesAnUnknownLanding() async throws {
        let file = try OpenFile("# Plan\n")
        defer { file.close() }
        let after = "# Plan\n\nAgent note.\n"
        try Data(after.utf8).write(to: file.url)
        await file.live.refresh()
        #expect(file.textView.string == after)
        #expect(!file.live.changes.isEmpty && file.live.changes.values.allSatisfy { $0.marked && $0.origin == .external })
        let use = { (hash: String, declared: String?) in
            ControlSocket.Claim.ToolUse(id: "toolu_1", tool: .write, path: file.realpath, hash: hash, declared: declared)
        }
        file.textView.marks.relayout()
        #expect(!file.textView.marks.painted.isEmpty)
        file.claim(.preToolUse(use(Self.hex("# Plan\n"), Self.hex(after))))
        file.claim(.postToolUse(use(Self.hex(after), nil)))
        await waitForMain { file.live.changes.values.contains { $0.marked && $0.origin == .agent(.claude, session: "s1") } }
        file.textView.marks.relayout()
        let id = try #require(file.live.changes.first { $0.value.marked }?.key)
        #expect(file.textView.marks.painted[id] == file.live.changes[id]?.range)
    }

    @Test func aMarkedLandingPaintsWithoutEditingTheText() async throws {
        let file = try OpenFile("# Plan\n\nShip on Friday.\n")
        defer { file.close() }
        // A landing into unsaved text is marked.
        file.textView.insertText("!", replacementRange: NSRange(location: 6, length: 0))
        let version = file.textView.version
        try Data("# Plan\n\nShip on Friday.\n\nAgent note.\n".utf8).write(to: file.url, options: .atomic)
        await file.live.refresh()
        #expect(file.textView.string == "# Plan!\n\nShip on Friday.\n\nAgent note.\n")
        let (id, change) = try #require(file.live.changes.first { $0.value.marked })
        let marks = file.textView.marks
        marks.relayout()
        #expect(marks.painted[id] == change.range)
        #expect((file.textView.string as NSString).substring(with: change.range).contains("Agent note"))
        // The landing is the one storage edit: the marks are paint, not attributes.
        #expect(file.textView.version == version + 1)
        let storage = try #require(file.textView.textStorage)
        storage.enumerateAttributes(in: change.range) { attributes, _, _ in
            #expect(attributes[.backgroundColor] == nil)
            #expect((attributes[.underlineStyle] as? Int ?? 0) == 0)
        }
        // Keep clears the mark and leaves the text.
        file.textView.setSelectedRange(NSRange(location: change.range.location + 1, length: 0))
        #expect(marks.changeAtCaret == id)
        file.textView.keepChange(nil)
        marks.relayout()
        #expect(file.live.changes[id] == nil)
        #expect(marks.painted.isEmpty)
        #expect(file.textView.string == "# Plan!\n\nShip on Friday.\n\nAgent note.\n")
    }

    @Test func typingAboveAChangeKeepsItsMarksOnItsWords() async throws {
        let file = try OpenFile("# Plan\n\nWe could maybe ship Friday.\n", events: true)
        defer { file.close() }
        file.type("!", at: 6)
        try Data("# Plan\n\nWe ship Friday, if QA signs off.\n".utf8).write(to: file.url, options: .atomic)
        await file.live.refresh()
        let before = file.live.changes.filter(\.value.marked).mapValues { (file.textView.string as NSString).substring(with: $0.range) }
        #expect(!before.isEmpty)
        file.type("ab", at: 0)
        for (id, words) in before {
            let range = try #require(file.live.changes[id]?.range)
            #expect((file.textView.string as NSString).substring(with: range) == words)
        }
        // The marks hear of the move once the edit is done.
        await waitForMain {
            file.textView.marks.relayout()
            return before.keys.allSatisfy { file.textView.marks.painted[$0] == file.live.changes[$0]?.range }
        }
    }

    @Test func removedTextHangsStruckUnderItsLine() async throws {
        let file = try OpenFile("# Plan\n\nShip on Friday.\n\nOld note.\n")
        defer { file.close() }
        file.textView.insertText("!", replacementRange: NSRange(location: 6, length: 0))
        try Data("# Plan\n\nShip on Friday.\n".utf8).write(to: file.url, options: .atomic)
        await file.live.refresh()
        #expect(file.textView.string == "# Plan!\n\nShip on Friday.\n")
        let (id, change) = try #require(file.live.changes.first { $0.value.marked })
        #expect(change.removed.contains("Old note."))
        #expect(file.textView.marks.hangers[id]?.view is Ghost)
    }

    @Test func inlineGhostsSitInTheirOwnGapsBeforeWhatReplacedThem() async throws {
        let before = "# Field Notes\n\nDewline keeps the **file** as the source of truth. Edits from agents land as *changes* you can keep or revert.\n"
        let after = before.replacingOccurrences(of: "*changes* you can keep or revert.", with: "*changes*, marked in place, that you keep or revert one at a time.")
        let file = try OpenFile(before)
        defer { file.close() }
        file.textView.window!.setContentSize(NSSize(width: 1000, height: 700))
        let use = { (hash: String, declared: String?) in
            ControlSocket.Claim.ToolUse(id: "toolu_1", tool: .edit, path: file.realpath, hash: hash, declared: declared)
        }
        file.claim(.preToolUse(use(Self.hex(before), Self.hex(after))))
        try Data(after.utf8).write(to: file.url)
        file.claim(.postToolUse(use(Self.hex(after), nil)))
        await waitForMain { file.live.changes.values.contains { $0.marked } }
        let marks = file.textView.marks
        let storage = try #require(file.textView.textStorage)
        let ghosts = file.live.changes.compactMap { id, change in
            (marks.hangers[id]?.view as? Ghost).flatMap { ghost in ghost.inlineWidth.map { (ghost, $0, change) } }
        }
        #expect(ghosts.map { $0.2.removed } == [" you can"])
        // The styler opens each gap, then the marks lay out again.
        await waitForMain {
            ghosts.allSatisfy { storage.attribute(.kern, at: $0.2.range.location - 1, effectiveRange: nil) as? CGFloat == $0.1 }
        }
        marks.relayout()
        // The closing * of *changes* is the same character before and after, so nothing struck shows it.
        let star = file.location(of: "*,")
        #expect(file.live.changes.values.allSatisfy { !$0.removed.contains("*") && !NSLocationInRange(star, $0.range) })
        #expect(storage.attribute(.foregroundColor, at: star, effectiveRange: nil) as? NSColor == .clear)
        // Where CoreText sets each glyph of the changed line, against which every ghost must stay clear of text.
        let layout = try #require(file.textView.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: star))
        let fragment = try #require(layout.textLayoutFragment(for: location))
        let offset = content.offset(from: fragment.rangeInElement.location, to: location)
        let line = try #require(fragment.textLineFragments.first { NSLocationInRange(offset, $0.characterRange) })
        let ctLine = CTLineCreateWithAttributedString(line.attributedString.attributedSubstring(from: line.characterRange))
        let paragraph = star - offset
        let left = file.textView.textContainerOrigin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
        var glyphs: [Int: (minX: CGFloat, maxX: CGFloat)] = [:]
        for run in CTLineGetGlyphRuns(ctLine) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetAdvances(run, CFRange(), &advances)
            CTRunGetStringIndices(run, CFRange(), &indices)
            for k in 0..<count {
                let x = left + positions[k].x
                let width = advances[k].width - (storage.attribute(.kern, at: paragraph + line.characterRange.location + indices[k], effectiveRange: nil) as? CGFloat ?? 0)
                glyphs[paragraph + line.characterRange.location + indices[k]] = (x, x + width)
            }
        }
        let inserted = file.live.changes.values.flatMap { change in (change.range.location..<NSMaxRange(change.range)).compactMap { glyphs[$0] } }
        #expect(inserted.count > 20)
        for (ghost, width, change) in ghosts {
            let start = try #require(glyphs[change.range.location])
            #expect(abs(ghost.frame.minX + width - start.minX) < 0.5)
            for glyph in inserted where glyph.maxX - glyph.minX > 0.5 {
                #expect(ghost.frame.maxX <= glyph.minX + 0.5 || ghost.frame.minX >= glyph.maxX - 0.5)
            }
        }
    }

    @Test func aPageAtTheTopKeepsItsPlaceAtTheFirstLine() throws {
        let file = try OpenFile("# Field Notes\n\n" + String(repeating: "A line of the notes.\n\n", count: 80))
        defer { file.close() }
        let tab = try #require(file.textView.window?.windowController as? MainWindowController)
        let clip = try #require(file.textView.enclosingScrollView?.contentView)
        #expect(clip.bounds.minY == 0)
        let place = try #require(tab.place)
        #expect(place.top == 0)
        clip.scroll(to: NSPoint(x: 0, y: 400))
        tab.restore(place)
        #expect(clip.bounds.minY == 0)
    }

    @Test func revertTakesTheChangeOutAsOneUndo() async throws {
        let file = try OpenFile("# Plan\n\nShip on Friday.\n", events: true)
        defer { file.close() }
        file.type("!", at: 6)
        try Data("# Plan\n\nShip on Friday.\n\nAgent note.\n".utf8).write(to: file.url, options: .atomic)
        await file.live.refresh()
        let (id, change) = try #require(file.live.changes.first { $0.value.marked })
        file.textView.setSelectedRange(NSRange(location: change.range.location + 1, length: 0))
        file.event { file.textView.revertChange(nil) }
        #expect(file.textView.string == "# Plan!\n\nShip on Friday.\n")
        #expect(file.live.changes[id] == nil)
        let window = try #require(file.document.windowControllers.first as? MainWindowController)
        #expect(window.statusBar.shown?.text == "Reverted \u{00B7} \u{2318}Z to undo")
        file.undo()
        #expect(file.textView.string == "# Plan!\n\nShip on Friday.\n\nAgent note.\n")
    }

    @Test(arguments: [ChangeEngine.Decision.keep, .other, .both])
    func theConflictCardDecides(_ decision: ChangeEngine.Decision) async throws {
        let file = try OpenFile("# Plan\n\nShip on Friday.\n")
        defer { file.close() }
        file.textView.insertText("Monday", replacementRange: NSRange(location: file.location(of: "Friday"), length: 6))
        try Data("# Plan\n\nShip on Sunday.\n".utf8).write(to: file.url)
        await file.live.refresh()
        let (id, conflict) = try #require(file.live.changes.first { $0.value.conflict })
        let card = try #require(file.textView.marks.hangers[id]?.view as? ConflictCard)
        #expect(conflict.theirs.contains("Sunday"))
        #expect(card.otherVersion == conflict.theirs.trimmingCharacters(in: .newlines))
        for button in [card.keepYours, card.useTheirs, card.keepBoth] {
            #expect(!(button.accessibilityLabel() ?? "").isEmpty)
        }
        #expect(card.frame.height > 0)
        // The styler reserves the card's height under your paragraph.
        await waitForMain {
            let style = file.textView.textStorage!.attribute(.paragraphStyle, at: conflict.range.location, effectiveRange: nil) as? NSParagraphStyle
            return (style?.paragraphSpacing ?? 0) >= card.frame.height
        }
        let yours = (file.textView.string as NSString).substring(with: conflict.range)
        let expected = switch decision {
        case .keep: "# Plan\n\nShip on Monday.\n"
        case .other: "# Plan\n\nShip on Sunday.\n"
        case .both:
            (file.textView.string as NSString).replacingCharacters(
                in: NSRange(location: conflict.range.location, length: (yours as NSString).length),
                with: yours + (yours.hasSuffix("\n") ? "" : "\n") + conflict.theirs)
        }
        switch decision {
        case .keep: card.keepYours.performClick(nil)
        case .other: card.useTheirs.performClick(nil)
        case .both: card.keepBoth.performClick(nil)
        }
        #expect(file.textView.string == expected)
        #expect(file.live.changes[id] == nil)
        #expect(file.textView.marks.hangers[id] == nil)
        #expect(card.superview == nil)
        // The marks sit under the text and its selection.
        #expect(file.textView.subviews.first === file.textView.marks)
        // The space under the paragraph goes with the card.
        await waitForMain {
            let style = file.textView.textStorage!.attribute(.paragraphStyle, at: conflict.range.location, effectiveRange: nil) as? NSParagraphStyle
            return (style?.paragraphSpacing ?? 0) < card.frame.height
        }
    }

    @Test func anEditHoldsAutosaveUntilItsPostAndAReadHoldsNothing() async throws {
        let file = try OpenFile("# Plan\n")
        defer { file.close() }
        file.record("PreToolUse", tool: "Read", id: "toolu_0")
        file.record("InstructionsLoaded")
        file.textView.insertText("!", replacementRange: NSRange(location: 6, length: 0))
        #expect(await file.live.autosave() == nil)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "# Plan!\n")

        file.record("PreToolUse", tool: "Edit", id: "toolu_1")
        file.textView.insertText("?", replacementRange: NSRange(location: 7, length: 0))
        #expect(await file.live.autosave() == .held)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "# Plan!\n")
        // The turn's end leaves the call open; its PostToolUse ends it and the refused autosave runs.
        file.claim(.turnEnd)
        file.claim(.postToolUse(.init(id: "toolu_1", tool: .edit, path: file.realpath, hash: Self.hex("# Plan!\n"), declared: nil)))
        await waitForMain { (try? String(contentsOf: file.url, encoding: .utf8)) == "# Plan!?\n" }
    }

    // MARK: Autosave without asking

    @Test func typingWithoutAPauseSavesWithin10Seconds() async throws {
        let file = try OpenFile("# Plan\n")
        defer { file.close() }
        file.textView.insertText("a", replacementRange: NSRange(location: 6, length: 0))
        let since = try #require(file.live.unsavedSince)
        file.textView.insertText("a", replacementRange: NSRange(location: 7, length: 0))
        #expect(file.live.unsavedSince == since, "a keystroke keeps the first unsaved edit's time")
        #expect(LiveFile.autosaveDue(now: since, since: since) == since + .seconds(2))
        #expect(LiveFile.autosaveDue(now: since + .seconds(5), since: since) == since + .seconds(7))
        #expect(LiveFile.autosaveDue(now: since + .seconds(9.7), since: since) == since + .seconds(10))
        #expect(await file.live.autosave() == nil)
        #expect(file.live.unsavedSince == nil)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "# Planaa\n")
    }

    @Test func closingSavesWithoutASheet() async throws {
        let file = try OpenFile("# Plan\n", events: true)
        defer { file.close() }
        file.type("!", at: 6)
        #expect(file.document.isDocumentEdited)
        #expect(await CloseProbe.canClose(file.document))
        #expect(file.textView.window?.attachedSheet == nil)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "# Plan!\n")
        #expect(!file.document.isDocumentEdited)
    }

    @Test func quittingSavesEveryNoteWithoutAReview() async throws {
        #expect(NSDocumentController.shared is DocumentController)
        // A controller of its own, so the review sees only this test's note.
        let controller = DocumentController()
        let file = try OpenFile("# Plan\n", events: true)
        defer { file.close() }
        controller.addDocument(file.document)
        defer { controller.removeDocument(file.document) }
        file.type("!", at: 6)
        let probe = CloseProbe()
        let reviewed = await withCheckedContinuation { continuation in
            probe.answered = { continuation.resume(returning: $0) }
            controller.reviewUnsavedDocuments(
                withAlertTitle: nil, cancellable: true, delegate: probe,
                didReviewAllSelector: #selector(CloseProbe.documentController(_:didReviewAll:contextInfo:)), contextInfo: nil)
        }
        #expect(reviewed)
        #expect(NSApp.windows.allSatisfy { $0.attachedSheet == nil })
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "# Plan!\n")
    }

    @Test func closingDuringAHoldKeepsTheDraftAndOpeningOffersIt() async throws {
        // Closing during the agent's Write keeps your text in the draft; its write then lands on the closed file.
        let file = try OpenFile("# Plan\n", events: true)
        defer { try? FileManager.default.removeItem(at: file.folder) }
        file.record("PreToolUse", tool: "Write", id: "toolu_1")
        file.type(" for Friday", at: 6)
        #expect(await CloseProbe.canClose(file.document))
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "# Plan\n")
        file.document.close()
        try Data("# Agent\n".utf8).write(to: file.url)

        let again = MarkdownDocument()
        again.engine = file.document.engine
        try again.read(from: file.url, ofType: Self.type)
        again.makeWindowControllers()
        defer { again.close() }
        let window = try #require(again.windowControllers.first as? MainWindowController)
        let live = try #require(again.live)
        await waitForMain { live.draft != nil }
        let message = try #require(window.statusBar.shown)
        #expect(message.text.hasPrefix("Unsaved text from ") && message.text.hasSuffix(" was kept"))
        #expect(message.actions.map(\.title) == ["Restore", "Discard"])
        message.actions[0].run(window.statusBar)
        await waitForMain { again.textView?.string == "# Plan for Friday\n" }
        #expect(window.statusBar.shown == nil)
        #expect(await live.keptDraft() == nil)
    }

    @Test func theStatusSaysOnlyWhyANoteIsNotSaved() async throws {
        let file = try OpenFile("# Plan\n", events: true)
        defer { file.close() }
        // Save Now saves to the note's file, as a tab's note has one.
        file.document.fileURL = file.url
        let window = try #require(file.document.windowControllers.first as? MainWindowController)
        #expect(window.statusBar.shown == nil)
        #expect(window.savedState?.hasPrefix("Saved") == true)

        // Edited and unsaved: the tab's dot and tooltip, nothing in the status bar.
        file.type("!", at: 6)
        #expect(file.document.isDocumentEdited)
        #expect(window.savedState == "Not saved yet")
        #expect(window.statusBar.shown == nil)

        // Held: one reason and Save Now, which writes through the hold.
        file.record("PreToolUse", tool: "Edit", id: "toolu_1")
        #expect(await file.live.autosave() == .held)
        let held = try #require(window.statusBar.shown)
        #expect(held.text == "Not saved: an agent is writing this note")
        #expect(held.actions.map(\.title) == ["Save Now"])
        held.actions[0].run(window.statusBar)
        await waitForMain { window.statusBar.shown == nil && !file.document.isDocumentEdited }
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "# Plan!\n")
        #expect(window.savedState?.hasPrefix("Saved") == true)

        // Deleted: says so.
        file.record("PostToolUse", tool: "Edit", id: "toolu_1")
        try FileManager.default.removeItem(at: file.url)
        await file.live.refresh()
        file.type("?", at: 7)
        #expect(await file.live.autosave() == .deleted)
        #expect(window.statusBar.shown?.text == "Not saved: the file was deleted")
        // Closing asks: no file opens to offer the draft back.
        #expect(await file.document.flush() == false)
    }

    @Test func restoringASnapshotIsOneUndo() async throws {
        let file = try OpenFile("# Plan\n", events: true)
        defer { file.close() }
        try Data("# Plan\n\nAgent note.\n".utf8).write(to: file.url)
        await file.live.refresh()
        await waitForMain { !file.live.snapshots.isEmpty }
        let snapshots = file.live.snapshots
        let oldest = try #require(snapshots.last)
        #expect(snapshots.map(\.time) == snapshots.map(\.time).sorted(by: >))
        await file.event { await file.live.restore(oldest) }
        #expect(file.textView.string == "# Plan\n")
        // Restoring writes nothing to the file.
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "# Plan\n\nAgent note.\n")
        file.undo()
        #expect(file.textView.string == "# Plan\n\nAgent note.\n")
    }

    @Test func pinningASnapshotShowsInTheList() async throws {
        let file = try OpenFile("# Plan\n")
        defer { file.close() }
        try Data("# Plan\n\nAgent note.\n".utf8).write(to: file.url)
        await file.live.refresh()
        await waitForMain { !file.live.snapshots.isEmpty }
        let snapshot = file.live.snapshots[0]
        file.live.pin(snapshot, true)
        await waitForMain { file.live.snapshots.first { $0.time == snapshot.time && $0.origin == snapshot.origin }?.pinned == true }
    }

    @Test func aRenameSeenOnlyByTheWatchFollowsTheFile() async throws {
        let file = try OpenFile("# Plan\n")
        defer { file.close() }
        let renamed = file.url.deletingLastPathComponent().appending(path: "renamed.md")
        try FileManager.default.moveItem(at: file.url, to: renamed)
        // The watch names the file by its realpath, under /private.
        await waitForMain { file.live.url.resolvingSymlinksInPath() == renamed.resolvingSymlinksInPath() }
        #expect(file.document.fileURL == file.live.url)
        // Writes to the new name land.
        try Data("# Plan\n\nAgent note.\n".utf8).write(to: renamed)
        await waitForMain { file.textView.string == "# Plan\n\nAgent note.\n" }
    }

    @Test func saveAsOntoTheSameFileGoesThroughTheEngine() async throws {
        let file = try OpenFile("# Plan\n")
        defer { file.close() }
        file.textView.insertText("!", replacementRange: NSRange(location: 6, length: 0))
        try await file.save(.saveAsOperation)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "# Plan!\n")
    }

    @Test func gitsLockReleaseLandsTheWaitingChange() async throws {
        let file = try OpenFile("# Plan\n", git: true)
        defer { file.close() }
        let lock = file.url.deletingLastPathComponent().appending(path: ".git/index.lock")
        try Data().write(to: lock)
        try Data("# Plan\n\nSwitched.\n".utf8).write(to: file.url)
        await file.live.refresh()
        #expect(file.textView.string == "# Plan\n")
        // The gitdir's watch lands it.
        try FileManager.default.removeItem(at: lock)
        await waitForMain { file.textView.string == "# Plan\n\nSwitched.\n" }
    }

    private static func hex(_ text: String) -> String {
        contentHash(Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func saveAfterAnOutsideWriteKeepsIt() async throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let file = try OpenFile(bom + Data("# Plan\n\nShip on Friday.\n".utf8))
        defer { file.close() }
        let end = file.location(of: "Friday.") + 7
        file.textView.insertText(" Then rest.", replacementRange: NSRange(location: end, length: 0))
        try (bom + Data("Agent note.\n\n# Plan\n\nShip on Friday.\n".utf8)).write(to: file.url)
        try await file.save()
        let both = "Agent note.\n\n# Plan\n\nShip on Friday. Then rest.\n"
        #expect(file.textView.string == both)
        #expect(try Data(contentsOf: file.url) == bom + Data(both.utf8))
        #expect(!file.document.isDocumentEdited)
    }

    @Test func autosaveWaitsForTheComposition() async throws {
        let file = try OpenFile("# Plan\n")
        defer { file.close() }
        file.textView.setSelectedRange(NSRange(location: 6, length: 0))
        file.textView.insertText("!", replacementRange: file.textView.selectedRange())
        file.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(await file.live.autosave() == .composing)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "# Plan\n")
        // The composition's end runs the refused autosave again.
        file.textView.unmarkText()
        await waitForMain { (try? String(contentsOf: file.url, encoding: .utf8)) == "# Plan!に\n" }
        #expect(file.textView.string == "# Plan!に\n")
    }

    // MARK: Undo

    @Test func undoAfterALandingElsewhereTakesOutOnlyYourTyping() async throws {
        let file = try OpenFile("# Plan\n\nShip on Friday.\n", events: true)
        defer { file.close() }
        file.type(" Then rest.", at: file.location(of: "Friday.") + 7)
        try Data("Agent note.\n\n# Plan\n\nShip on Friday.\n".utf8).write(to: file.url, options: .atomic)
        await file.live.refresh()
        #expect(file.textView.string == "Agent note.\n\n# Plan\n\nShip on Friday. Then rest.\n")
        file.undo()
        #expect(file.textView.string == "Agent note.\n\n# Plan\n\nShip on Friday.\n")
        #expect(!file.undoManager.canUndo)
        file.redo()
        #expect(file.textView.string == "Agent note.\n\n# Plan\n\nShip on Friday. Then rest.\n")
    }

    @Test func undoStopsAtAnEntryALandingTouched() async throws {
        let file = try OpenFile("# Plan\n\nShip on Friday.\n", events: true)
        defer { file.close() }
        file.type("!", at: 6)
        try await file.save()
        file.type(" Then rest.", at: file.location(of: "Friday.") + 7)
        // The agent changes the "!" you typed, which is on disk now.
        try Data("# Plan?\n\nShip on Friday.\n".utf8).write(to: file.url, options: .atomic)
        await file.live.refresh()
        #expect(file.textView.string == "# Plan?\n\nShip on Friday. Then rest.\n")
        file.undo()
        #expect(file.textView.string == "# Plan?\n\nShip on Friday.\n")
        // Undoing the "!" would take out the agent's text, so the history ends there.
        #expect(!file.undoManager.canUndo)
    }

    @Test func aLandingClearsRedo() async throws {
        let file = try OpenFile("# Plan\n\nShip on Friday.\n", events: true)
        defer { file.close() }
        file.type("!", at: 6)
        file.undo()
        #expect(file.undoManager.canRedo)
        try Data("# Plan\n\nShip on Friday.\n\nAgent note.\n".utf8).write(to: file.url, options: .atomic)
        await file.live.refresh()
        #expect(file.textView.string == "# Plan\n\nShip on Friday.\n\nAgent note.\n")
        #expect(!file.undoManager.canRedo)
    }

    @Test func typingUndoesByWordAndACompositionAsOne() async throws {
        let file = try OpenFile("# Plan\n", events: true)
        defer { file.close() }
        file.textView.setSelectedRange(NSRange(location: 6, length: 0))
        for character in " ship it" {
            file.event { file.textView.insertText(String(character), replacementRange: file.textView.selectedRange()) }
        }
        for marked in ["k", "か"] {
            file.event {
                file.textView.setMarkedText(marked, selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        file.event { file.textView.insertText("漢", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        #expect(file.textView.string == "# Plan ship it漢\n")
        // The composition, each word with the space after it, and the space before the first word.
        for expected in ["# Plan ship it\n", "# Plan ship \n", "# Plan \n", "# Plan\n"] {
            file.undo()
            #expect(file.textView.string == expected)
            #expect(file.undoManager.redoMenuItemTitle == "Redo Typing")
        }
    }

    @Test func revertAndRestoreUndoUnderTheirNames() async throws {
        let file = try OpenFile("# Plan\n\nShip on Friday.\n", events: true)
        defer { file.close() }
        file.type("!", at: 6)
        let after = "# Plan\n\nShip on Friday.\n\nAgent note.\n"
        file.claim(.preToolUse(.init(id: "toolu_1", tool: .write, path: file.realpath, hash: Self.hex("# Plan\n\nShip on Friday.\n"), declared: Self.hex(after))))
        try Data(after.utf8).write(to: file.url, options: .atomic)
        file.claim(.postToolUse(.init(id: "toolu_1", tool: .write, path: file.realpath, hash: Self.hex(after), declared: nil)))
        await file.live.refresh()
        let (_, change) = try #require(file.live.changes.first { $0.value.marked })
        await waitForMain { file.live.changes.values.contains { $0.origin == .agent(.claude, session: "s1") } }
        file.textView.setSelectedRange(NSRange(location: change.range.location + 1, length: 0))
        file.event { file.textView.revertChange(nil) }
        #expect(file.undoManager.undoMenuItemTitle == "Undo Revert Claude Code's Change")
        file.undo()
        #expect(file.textView.string == "# Plan!\n\nShip on Friday.\n\nAgent note.\n")
        // Your "!" from before the landing still undoes.
        file.undo()
        #expect(file.textView.string == "# Plan\n\nShip on Friday.\n\nAgent note.\n")

        await waitForMain { !file.live.snapshots.isEmpty }
        let oldest = try #require(file.live.snapshots.last)
        await file.event { await file.live.restore(oldest) }
        #expect(file.undoManager.undoMenuItemTitle == "Undo Restore Snapshot")
    }

    @Test func onlyLandingsSinceASaveLeaveTheDocumentClean() async throws {
        let file = try OpenFile("# Plan\n\nShip on Friday.\n", events: true)
        defer { file.close() }
        file.type("!", at: 6)
        #expect(file.document.isDocumentEdited)
        try await file.save()
        #expect(!file.document.isDocumentEdited)
        try Data("# Plan!\n\nShip on Friday.\n\nAgent note.\n".utf8).write(to: file.url, options: .atomic)
        await file.live.refresh()
        #expect(file.textView.string == "# Plan!\n\nShip on Friday.\n\nAgent note.\n")
        #expect(!file.document.isDocumentEdited)
        // Typing right after the save is a new edit.
        file.type("?", at: 7)
        #expect(file.document.isDocumentEdited)
        file.undo()
        #expect(!file.document.isDocumentEdited)
        // Undoing the saved "!" leaves the buffer unlike the file.
        file.undo()
        #expect(file.textView.string == "# Plan\n\nShip on Friday.\n\nAgent note.\n")
        #expect(file.document.isDocumentEdited)
    }

    @MainActor
    private struct OpenFile {
        let folder: URL
        let url: URL
        let document: MarkdownDocument
        let textView: EditorTextView
        let live: LiveFile

        init(_ text: String, git: Bool = false, events: Bool = false) throws {
            try self.init(Data(text.utf8), git: git, events: events)
        }

        /// With `git`, the file's folder is a new repository; with `events`, edits are grouped by `event`.
        init(_ bytes: Data, git: Bool = false, events: Bool = false) throws {
            folder = FileManager.default.temporaryDirectory.appending(path: "dewline-live-\(UUID().uuidString)")
            let files = folder.appending(path: "files")
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            if git {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["init", "-q", files.path]
                process.environment = ["HOME": folder.path, "GIT_CONFIG_NOSYSTEM": "1"]
                try process.run()
                process.waitUntilExit()
            }
            url = files.appending(path: "plan.md")
            try bytes.write(to: url)
            document = MarkdownDocument()
            document.engine = try ChangeEngine(store: folder.appending(path: "snapshots"))
            try document.read(from: url, ofType: LiveFileTests.type)
            // Without a fileURL the window leaves the recent files in user defaults alone.
            document.makeWindowControllers()
            textView = try #require(document.textView)
            live = try #require(document.live)
            if events { textView.history.undoManager.groupsByEvent = false }
        }

        /// The file's realpath, as hooks name it.
        var realpath: String {
            Darwin.realpath(url.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? url.path
        }

        /// A Claude Code hook's claim on the file in session s1, recorded before it returns; the app doesn't hear what
        /// it changed.
        func record(_ event: String, tool: String? = nil, id: String? = nil) {
            _ = document.engine!.claim(
                event: event, vendor: "claude", session: "s1", toolUseId: id, tool: tool, path: realpath, hash: nil, declared: nil)
        }

        /// A Claude Code hook's claim in session s1, as `dewline notify` sends it.
        func claim(_ event: ControlSocket.Claim.Event) {
            LiveFile.claim(ControlSocket.Claim(vendor: .claude, session: "s1", event: event), engine: document.engine!)
        }

        var undoManager: UndoManager {
            textView.history.undoManager
        }

        /// Types `text` at `location` as one keystroke, after a click there.
        func type(_ text: String, at location: Int) {
            textView.breakUndoCoalescing()
            textView.setSelectedRange(NSRange(location: location, length: 0))
            event { textView.insertText(text, replacementRange: textView.selectedRange()) }
        }

        /// One event's undo group, which the app's run loop opens at an edit and closes; a file opened with
        /// `events` groups by hand, which leaves an empty group where an edit joined the last entry.
        func event(_ body: () -> Void) {
            undoManager.beginUndoGrouping()
            body()
            undoManager.endUndoGrouping()
        }

        func event(_ body: () async -> Void) async {
            undoManager.beginUndoGrouping()
            await body()
            undoManager.endUndoGrouping()
        }

        /// Cmd-Z, past the empty groups.
        func undo() {
            let text = textView.string
            repeat {
                textView.window!.tryToPerform(Selector(("undo:")), with: nil)
            } while textView.string == text && undoManager.canUndo
        }

        func redo() {
            textView.window!.tryToPerform(Selector(("redo:")), with: nil)
        }

        func location(of text: String) -> Int {
            (textView.string as NSString).range(of: text).location
        }

        /// Cmd-S.
        func save(_ operation: NSDocument.SaveOperationType = .saveOperation) async throws {
            let error: (any Error)? = await withCheckedContinuation { continuation in
                document.save(to: url, ofType: LiveFileTests.type, for: operation) { continuation.resume(returning: $0) }
            }
            if let error { throw error }
        }

        func close() {
            document.close()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// The delegate AppKit answers after a close or a quit review.
    private final class CloseProbe: NSObject {
        var answered: ((Bool) -> Void)?

        @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
            answered?(shouldClose)
        }

        @objc func documentController(_ controller: NSDocumentController, didReviewAll: Bool, contextInfo: UnsafeMutableRawPointer?) {
            answered?(didReviewAll)
        }

        /// Asks `document` whether it can close, as a tab's close button does.
        @MainActor static func canClose(_ document: NSDocument) async -> Bool {
            let probe = CloseProbe()
            return await withCheckedContinuation { continuation in
                probe.answered = { continuation.resume(returning: $0) }
                document.canClose(
                    withDelegate: probe, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
            }
        }
    }
}
