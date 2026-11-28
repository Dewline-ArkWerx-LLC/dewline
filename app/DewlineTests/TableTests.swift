import AppKit
import Testing
@testable import Dewline

/// An editor in a window that is never ordered front.
@MainActor
private struct Editor {
    let window: NSWindow
    let view: EditorTextView

    init(_ text: String, caret: Int, width: CGFloat = 760) {
        let scrollView = EditorTextView.scrollView()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        view = scrollView.documentView as! EditorTextView
        view.string = text
        window.makeFirstResponder(view)
        place(caret)
    }

    func place(_ caret: Int) {
        view.setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// The first occurrence of `string` at or after `from`.
    func find(_ string: String, from: Int = 0) -> NSRange {
        let text = view.string as NSString
        return text.range(of: string, range: NSRange(location: from, length: text.length - from))
    }

    func rect(_ range: NSRange) -> NSRect {
        view.firstRect(forCharacterRange: range, actualRange: nil)
    }

    func rect(_ string: String, from: Int = 0) -> NSRect {
        rect(find(string, from: from))
    }

    func role(at location: Int) -> BlockLine.Role? {
        (view.textStorage!.attribute(.dewlineBlock, at: location, effectiveRange: nil) as? BlockLine)?.role
    }

    /// `rect(range)` in the view.
    func frame(_ range: NSRange) -> NSRect {
        view.convert(window.convertFromScreen(rect(range)), from: nil)
    }

    func frame(_ string: String, from: Int = 0) -> NSRect {
        frame(find(string, from: from))
    }

    /// Where the column's text starts, in the view.
    var edge: CGFloat {
        view.textContainerOrigin.x + (view.textContainer?.lineFragmentPadding ?? 0)
    }

    /// The laid-out fragment of the paragraph holding `location`.
    func fragment(at location: Int) throws -> NSTextLayoutFragment {
        let layout = try #require(view.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let at = try #require(content.location(content.documentRange.location, offsetBy: location))
        layout.ensureLayout(for: NSTextRange(location: at))
        return try #require(layout.textLayoutFragment(for: at))
    }

    /// The first line box of the paragraph holding `location`, in the view.
    func lineBox(at location: Int) throws -> NSRect {
        let fragment = try fragment(at: location)
        let line = try #require(fragment.textLineFragments.first)
        return line.typographicBounds.offsetBy(dx: view.textContainerOrigin.x + fragment.layoutFragmentFrame.minX, dy: view.textContainerOrigin.y + fragment.layoutFragmentFrame.minY)
    }

    /// Where CoreText sets the glyph of the character at `location`, in the view: a caret beside a kerned character
    /// stands in the middle of its kern.
    func glyphX(at location: Int) throws -> CGFloat {
        let fragment = try fragment(at: location)
        let content = try #require(view.textLayoutManager?.textContentManager)
        let offset = content.offset(from: fragment.rangeInElement.location, to: try #require(content.location(content.documentRange.location, offsetBy: location)))
        let line = try #require(fragment.textLineFragments.first { NSLocationInRange(offset, $0.characterRange) })
        let typeset = CTLineCreateWithAttributedString(line.attributedString.attributedSubstring(from: line.characterRange))
        for run in CTLineGetGlyphRuns(typeset) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetStringIndices(run, CFRange(), &indices)
            if let glyph = indices.firstIndex(of: offset - line.characterRange.location) {
                return view.textContainerOrigin.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + positions[glyph].x
            }
        }
        throw CocoaError(.featureUnsupported)
    }

    /// The center of the pipe at `location`, in the view.
    func pipeX(at location: Int) throws -> CGFloat {
        let font = try #require(view.textStorage!.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
        return try glyphX(at: location) + NSAttributedString(string: "|", attributes: [.font: font]).size().width / 2
    }

    /// The x of a point in the view in `fragment`'s coordinates.
    func x(_ x: CGFloat, in fragment: NSTextLayoutFragment) -> CGFloat {
        x - view.textContainerOrigin.x - fragment.layoutFragmentFrame.minX
    }

    /// Runs `edit` in its own undo group, as an event would.
    func edit(_ edit: () -> Void) {
        let undo = view.styler.undoManager
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        edit()
        undo.endUndoGrouping()
    }
}

/// A layout fragment drawn on its own, in Tidewater's light colors, at `scale` pixels a point.
@MainActor
private struct Drawn {
    let bounds: CGRect
    let scale: CGFloat
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(_ fragment: NSTextLayoutFragment, scale: CGFloat = 4) throws {
        bounds = fragment.renderingSurfaceBounds.union(CGRect(origin: .zero, size: fragment.layoutFragmentFrame.size)).integral
        self.scale = scale
        width = Int(bounds.width * scale)
        height = Int(bounds.height * scale)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let origin = CGPoint(x: -bounds.minX, y: -bounds.minY)
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { fragment.draw(at: origin, in: context) }
        let data = try #require(context.data)
        pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    /// The premultiplied red, green, blue and alpha of the pixel at a point in the fragment.
    func pixel(x: CGFloat, y: CGFloat) -> [CGFloat] {
        let at = (Int((y - bounds.minY) * scale) * width + Int((x - bounds.minX) * scale)) * 4
        return pixels[at..<at + 4].map { CGFloat($0) / 255 }
    }

    /// The tops of the pixel rows, in the fragment's points, inked between `left` and `right` and from `top` to `bottom`.
    func inked(left: CGFloat, right: CGFloat, top: CGFloat = -.infinity, bottom: CGFloat = .infinity) -> [CGFloat] {
        let columns = max(Int((left - bounds.minX) * scale), 0)..<min(Int((right - bounds.minX) * scale), width)
        return (0..<height).map { bounds.minY + CGFloat($0) / scale }.enumerated().filter { row, y in
            y >= top && y < bottom && columns.contains { pixels[(row * width + $0) * 4 + 3] > 0 }
        }.map(\.element)
    }

    /// The center of what is inked between `left` and `right`, in the fragment's points.
    func center(left: CGFloat, right: CGFloat) -> CGPoint? {
        let rows = inked(left: left, right: right)
        let columns = (max(Int((left - bounds.minX) * scale), 0)..<min(Int((right - bounds.minX) * scale), width)).filter { column in
            (0..<height).contains { pixels[($0 * width + column) * 4 + 3] > 0 }
        }
        guard let top = rows.first, let bottom = rows.last, let first = columns.first, let last = columns.last else { return nil }
        return CGPoint(x: bounds.minX + CGFloat(first + last + 1) / 2 / scale, y: (top + bottom + 1 / scale) / 2)
    }
}

/// The relative luminance of an sRGB color.
private func luminance(_ rgb: [CGFloat]) -> CGFloat {
    let linear = rgb.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
}

/// The attributes whose values differ between two versions of a text, by key.
private func changedKeys(_ before: NSAttributedString, _ after: NSAttributedString) -> Set<NSAttributedString.Key> {
    var keys: Set<NSAttributedString.Key> = []
    for at in 0..<before.length {
        let old = before.attributes(at: at, effectiveRange: nil), new = after.attributes(at: at, effectiveRange: nil)
        for key in Set(old.keys).union(new.keys) where !((old[key] as AnyObject?)?.isEqual(new[key]) ?? (new[key] == nil)) {
            keys.insert(key)
        }
    }
    return keys
}

@MainActor
struct TableTests {
    static let text = "Intro\n\n| Name | Qty | Note |\n|:-----|----:|:----:|\n| apple | 3 | ok |\n| kiwi fruit | 12 | fine one |\n\nAfter\n"

    @Test func columnsAlignFromTheWidestCell() throws {
        let editor = Editor(Self.text, caret: 0)
        #expect(editor.view.string == Self.text)
        let gap = (MarkdownStyler.bodyFont.pointSize * 1.5).rounded()
        let head = editor.find("| Name")
        // A caret position splits the kern before it, so a cell's start is its end less its laid-out width.
        func cell(_ string: String, skip: Int = 0) -> (start: CGFloat, end: CGFloat) {
            var range = editor.find(string)
            range = NSRange(location: range.location + skip, length: range.length - 2 * skip)
            let end = editor.rect(range).maxX
            return (end - editor.view.textStorage!.attributedSubstring(from: range).size().width, end)
        }
        // Left: every cell starts at the column's start.
        let name = cell("Name"), apple = cell("apple"), kiwi = cell("kiwi fruit")
        #expect(abs(apple.start - name.start) <= 0.5 && abs(kiwi.start - name.start) <= 0.5)
        // The leading pipe and its blank sit left of the first cell; padding past one blank beside a pipe takes no room.
        #expect(editor.rect(NSRange(location: head.location, length: 2)).maxX <= name.start + 0.5)
        let padded = Editor("| a   | b |\n|-----|---|\n|   c | d |\n", caret: 0)
        for surplus in [NSRange(location: padded.find("a   |").location + 1, length: 2), NSRange(location: padded.find("|   c").location + 2, length: 2)] {
            #expect(padded.rect(surplus).width <= 0.5, "\(surplus) is \(padded.rect(surplus)), its line \((0..<12).map { padded.rect(NSRange(location: surplus.location - 3 + $0, length: 1)) })")
        }
        // Right: every cell ends at the column's end, which the widest cell sets.
        let qty = cell("Qty"), three = cell(" 3 ", skip: 1), twelve = cell("12")
        #expect(abs(three.end - qty.end) <= 0.5 && abs(twelve.end - qty.end) <= 0.5)
        let first = (kiwi.end - kiwi.start).rounded(.up)
        let second = max(qty.end - qty.start, twelve.end - twelve.start).rounded(.up)
        #expect(abs(qty.end - (name.start + first + gap + second)) <= 1)
        // Center: every cell's middle is the column's, the widest cell's.
        let note = cell("Note"), ok = cell("ok"), fine = cell("fine one")
        let middle = (fine.start + fine.end) / 2
        #expect(abs((note.start + note.end) / 2 - middle) <= 1 && abs((ok.start + ok.end) / 2 - middle) <= 1)
        #expect(abs(fine.start - (qty.end + gap)) <= 1)
        // One rule, across under the head, whose delimiter row collapses so the head sits a row's pitch above the first row.
        guard case .table(let rule)? = editor.role(at: editor.find("| apple").location) else { Issue.record("no rule on a row"); return }
        #expect(!rule.across)
        guard case .table(let under)? = editor.role(at: editor.find("|:---").location) else { Issue.record("no rule under the head"); return }
        #expect(under.across && under.width == rule.width)
        let (headY, appleY, kiwiY) = (editor.rect("Name").minY, editor.rect("apple").minY, editor.rect("kiwi").minY)
        #expect(abs(abs(headY - appleY) - abs(appleY - kiwiY)) <= 1)
        #expect(abs(abs(appleY - kiwiY) - 1.5 * ThemeStore.shared.bodyLineHeight) <= 0.5)
        #expect(Tables.alignments("|:-----|----:|:----:|---|") == [.left, .right, .center, nil])
        #expect(editor.view.string == Self.text)
    }

    @Test func theCaretsRowShowsItsSource() throws {
        let editor = Editor(Self.text, caret: 0)
        let storage = try #require(editor.view.textStorage)
        let syntax = ThemeStore.shared.color(.syntax)
        let row = editor.find("| apple")
        let other = editor.find("| kiwi")
        func pipe(_ at: Int) -> (width: CGFloat, color: NSColor?) {
            (editor.rect(NSRange(location: at, length: 1)).width, storage.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor)
        }
        // Every row keeps its pipes' room, clear.
        let clear = pipe(row.location)
        #expect(clear.width > 2 && clear.color == .clear)
        let cells = ["apple", "3", "ok"].map { editor.find($0, from: row.location).location }
        func xs() throws -> [CGFloat] { try cells.map { try editor.glyphX(at: $0) } }
        let elsewhere = try xs()
        editor.place(editor.find("apple").location + 2)
        let shown = pipe(row.location)
        #expect(abs(shown.width - clear.width) <= 0.5 && shown.color == syntax)
        guard case .table? = editor.role(at: row.location) else { Issue.record("the caret's row lost its layout"); return }
        let caretRow = try xs()
        #expect(zip(caretRow, elsewhere).allSatisfy { abs($0 - $1) <= 0.5 }, "cells at \(caretRow), \(elsewhere) with the caret elsewhere")
        let otherPipe = pipe(other.location)
        #expect(abs(otherPipe.width - clear.width) <= 0.5 && otherPipe.color == .clear)
        // The caret on the head leaves the delimiter line a rule; on the delimiter line its dashes show, in its height.
        let delimiter = editor.find("|:---")
        let height = try editor.fragment(at: delimiter.location).layoutFragmentFrame.height
        #expect(editor.rect(NSRange(location: delimiter.location, length: 2)).width <= 0.5)
        editor.place(editor.find("Name").location)
        #expect(editor.rect(NSRange(location: delimiter.location, length: 2)).width <= 0.5)
        guard case .table(let rule)? = editor.role(at: delimiter.location) else { Issue.record("no rule under the head"); return }
        #expect(rule.across)
        let hidden = pipe(row.location)
        #expect(abs(hidden.width - clear.width) <= 0.5 && hidden.color == .clear)
        editor.place(delimiter.location + 2)
        #expect(storage.attribute(.foregroundColor, at: delimiter.location + 2, effectiveRange: nil) as? NSColor == syntax)
        #expect(editor.rect(NSRange(location: delimiter.location + 2, length: 1)).width > 2)
        #expect(abs(try editor.fragment(at: delimiter.location).layoutFragmentFrame.height - height) <= 0.5)
        guard case .table(let shownRule)? = editor.role(at: delimiter.location) else { Issue.record("no layout on the delimiter line"); return }
        #expect(!shownRule.across)
        editor.place(0)
        #expect(editor.rect(NSRange(location: delimiter.location, length: 2)).width <= 0.5)
        #expect(editor.view.string == Self.text)
    }

    @Test func columnsOnlyWidenWhileTyping() {
        let editor = Editor(Self.text, caret: 0)
        let view = editor.view
        func qtyEnd() -> CGFloat { editor.rect("Qty").maxX }
        let start = qtyEnd()
        // Shortening the widest cell keeps the column while the caret stays in the table.
        editor.place(NSMaxRange(editor.find("kiwi fruit")))
        for _ in 0..<6 { editor.edit { view.deleteBackward(nil) } }
        #expect(view.string.contains("| kiwi | 12 |"))
        #expect(abs(qtyEnd() - start) <= 0.5)
        // Leaving the table fits the columns again.
        editor.place(0)
        #expect(qtyEnd() < start - 10)
        // Typing a longer cell widens them at once.
        let narrow = qtyEnd()
        editor.place(NSMaxRange(editor.find("kiwi")))
        editor.edit { view.insertText(" and a much longer name", replacementRange: view.selectedRange()) }
        #expect(qtyEnd() > start + 10)
        #expect(qtyEnd() > narrow)
    }

    @Test func tablesAndCodeRunPastTheMeasure() throws {
        let columns = 1...7
        let table = "| " + columns.map { "column \($0)" }.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: columns.count)
            + "\n| " + columns.map { "cell \($0)" }.joined(separator: " | ") + " |\n"
        let code = String(repeating: "let x = 1; ", count: 7) + "done"
        let prose = String(repeating: "word ", count: 40) + "last"
        let editor = Editor("Intro\n\n\(table)\n```\n\(code)\n```\n\n\(prose)\n", caret: 0, width: 1200)
        let view = editor.view
        let container = try #require(view.textContainer)
        func frame(_ string: String) -> NSRect {
            view.convert(editor.window.convertFromScreen(editor.rect(string)), from: nil)
        }
        let start = view.textContainerOrigin.x + container.lineFragmentPadding
        let measure = start + container.column - 2 * container.lineFragmentPadding
        let edge = view.bounds.width - 32
        #expect(container.column < container.size.width)
        // The table keeps its natural columns, one line per row, past the measure and inside the right margin.
        let row = editor.find("| cell 1").location
        guard case .table(let rule)? = editor.role(at: row) else { Issue.record("no rule on the row"); return }
        #expect(rule.cells.isEmpty)
        #expect(start + rule.width > measure && start + rule.width <= edge)
        let layout = try #require(view.textLayoutManager)
        let location = try #require(layout.location(layout.documentRange.location, offsetBy: row))
        layout.ensureLayout(for: NSTextRange(location: location))
        let fragment = try #require(layout.textLayoutFragment(for: location))
        #expect(view.textContainerOrigin.x + fragment.layoutFragmentFrame.maxX > measure)
        #expect(frame("column 7").maxX > measure && frame("cell 7").maxX > measure && frame("cell 7").maxX <= edge)
        #expect(abs(frame("column 1").minY - frame("column 7").minY) < 1)
        // A code line runs on in its widened well; prose wraps at the measure.
        #expect(frame("done").maxX > measure && abs(frame("done").minY - frame("let").minY) < 1)
        let well = try #require(view.textStorage!.attribute(.dewlineCode, at: editor.find("let").location, effectiveRange: nil) as? CodeWell)
        let drawn = view.codeWell(well, top: frame("let"), bottom: frame("done"))
        #expect(drawn.maxX > frame("done").maxX && drawn.maxX <= edge)
        #expect(frame("last").maxX <= measure + 1 && frame("last").minY > frame("word").minY)
        #expect(view.string.hasPrefix("Intro\n\n| column 1 |"))
    }

    /// The fixture's Backoff and Setting tables under their heading, and its table wider than a 900 pt window's column.
    static let backoff = """
        ## Backoff

        | Attempt | Wait | Elapsed | Notes |
        |--:|--:|--:|---|
        | 1 | 2 s | 2 s | First retry is fast so a blip costs nothing |
        | 4 | 16 s | 30 s | |
        | 8 | 256 s | 8.5 min | Most transient failures clear by here |
        | 12 | 1 h | 2.1 h | Parked after this attempt |

        | Setting | Default | Range | Where |
        |---|:-:|---|---|
        | `max_attempts` | 12 | 1\u{2013}20 | `config/retry.toml` |
        | `max_backoff` | 3600 s | 1\u{2013}3600 s | per subscriber, [API](https://example.com/api) |
        | `jitter` | 0.1 | 0\u{2013}0.5 | `config/retry.toml` |

        The table below is wider than the text column on purpose.

        | Endpoint | Owner | Behavior on 5xx | Behavior on timeout | Escalation when the subscriber stays down for more than an hour |
        |---|---|---|---|---|
        | `POST /v1/events` | platform | retry with backoff, record the status code and the first 200 bytes of the body | retry with backoff after a 10 s connect timeout | page platform on-call, then email the subscriber's listed contact |
        | `POST /v1/batch` | ingest | split the batch in half and retry each half | retry the whole batch once, then split | open a ticket in the ingest queue |

        """

    /// Whether the settings are a fresh install's, which the spec's numbers are measured at.
    static var defaults: Bool {
        let store = ThemeStore.shared
        return store.bodySize == 16 && store.lineHeight == 1.5 && store.bodyFace == "Seravek"
    }

    /// T1: the caret's row changes the color of its pipes and nothing else.
    @Test func theCaretsRowOnlyColorsItsPipes() throws {
        let editor = Editor(Self.backoff, caret: (Self.backoff as NSString).range(of: "The table below").location)
        let storage = try #require(editor.view.textStorage)
        let text = storage.string as NSString
        let row = text.lineRange(for: editor.find("| 8 | 256 s |"))
        let cells = ["8", "256 s", "8.5 min", "Most"].map { editor.find($0, from: row.location).location }
        let pipes = (row.location..<NSMaxRange(row)).filter { text.character(at: $0) == 0x7C }
        func xs() throws -> [CGFloat] { try cells.map { try editor.glyphX(at: $0) } }
        func widths() -> [CGFloat] { pipes.map { editor.rect(NSRange(location: $0, length: 1)).width } }
        func colors() -> [NSColor?] { pipes.map { storage.attribute(.foregroundColor, at: $0, effectiveRange: nil) as? NSColor } }
        let (x, width) = (try xs(), widths())
        #expect(width.allSatisfy { $0 > 2 } && colors().allSatisfy { $0 == .clear })
        let before = NSAttributedString(attributedString: storage)
        editor.place(editor.find("256").location + 1)
        let caretRow = try xs()
        #expect(zip(caretRow, x).allSatisfy { abs($0 - $1) <= 0.5 }, "cells at \(caretRow), \(x) with the caret elsewhere")
        #expect(zip(widths(), width).allSatisfy { abs($0 - $1) <= 0.5 })
        #expect(colors().allSatisfy { $0 == ThemeStore.shared.color(.syntax) })
        guard case .table? = editor.role(at: row.location) else { Issue.record("the caret's row lost its layout"); return }
        let changed = changedKeys(before, storage)
        #expect(changed == [.foregroundColor], "\(changed)")
    }

    /// T1b: a click past a cell's text puts the caret after it, typing there keeps the padding, and Right crosses the pipe
    /// to the next cell's text.
    @Test func aClickPastACellsTextTypesAfterItAndRightCrossesToTheNextCell() throws {
        let editor = Editor("| Name   | Qty |\n|--------|----:|\n| apple  |   3 |\n", caret: 0)
        let view = editor.view
        let apple = editor.frame("apple")
        let point = view.convert(NSPoint(x: apple.maxX + 10, y: apple.midY), to: nil)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: editor.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ))
        }
        // Through the application's queue, so the click is the current event, as a real one is.
        NSApp.postEvent(try mouse(.leftMouseDown), atStart: true)
        let down = try #require(NSApp.nextEvent(matching: .leftMouseDown, until: .distantPast, inMode: .default, dequeue: true))
        NSApp.postEvent(try mouse(.leftMouseUp), atStart: true)
        view.mouseDown(with: down)
        #expect(view.selectedRange() == NSRange(location: NSMaxRange(editor.find("apple")), length: 0))
        editor.edit { view.insertText("x", replacementRange: view.selectedRange()) }
        #expect(view.string == "| Name   | Qty |\n|--------|----:|\n| applex  |   3 |\n")
        // Right comes as a key, so the caret stops see a key and not the click.
        func right() throws {
            let key = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: editor.window.windowNumber, context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124
            ))
            NSApp.postEvent(key, atStart: true)
            view.keyDown(with: try #require(NSApp.nextEvent(matching: .keyDown, until: .distantPast, inMode: .default, dequeue: true)))
        }
        let line = editor.find("| applex  |   3 |")
        try right()
        #expect(view.selectedRange() == NSRange(location: editor.find("3", from: line.location).location, length: 0))
        editor.place(editor.find("applex").location)
        var carets: [CGFloat] = []
        for _ in 0..<30 where NSLocationInRange(view.selectedRange().location, line) {
            carets.append(editor.rect(view.selectedRange()).minX)
            try right()
        }
        #expect(carets.count > 2 && zip(carets, carets.dropFirst()).allSatisfy { $1 >= $0 - 0.5 }, "carets at \(carets)")
        // A blank typed after a cell's text holds the caret for the word after it.
        editor.place(NSMaxRange(editor.find("applex")))
        for typed in [" ", "y"] { editor.edit { view.insertText(typed, replacementRange: view.selectedRange()) } }
        #expect(view.string == "| Name   | Qty |\n|--------|----:|\n| applex y  |   3 |\n")
    }

    /// T2: rows 1.5 lines apart, a 1 pt rule in the half-line delimiter line, a fainter one-pixel hairline between body
    /// rows, the table's gaps to its neighbors, and wrapped cells set at the height text sets in its row.
    @Test func rowsStandHalfALineApartBetweenTheirRules() throws {
        let editor = Editor(Self.backoff, caret: 0, width: 900)
        let view = editor.view
        let line = ThemeStore.shared.bodyLineHeight
        let rows = ["| Attempt", "| 1 |", "| 4 |", "| 8 |", "| 12 |"].map { editor.find($0).location }
        let baselines = try rows.map { try #require(view.baseline(at: $0 + 2)) }
        for (above, below) in zip(baselines, baselines.dropFirst()) {
            #expect(abs(below - above - 1.5 * line) <= 0.5, "baselines \(above) and \(below)")
        }
        var paper: [CGFloat] = []
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            let color = ThemeStore.shared.color(.paper).usingColorSpace(.sRGB)!
            paper = [color.redComponent, color.greenComponent, color.blueComponent]
        }
        func contrast(_ pixel: [CGFloat]) -> CGFloat {
            (luminance(paper) - luminance((0..<3).map { pixel[$0] + paper[$0] * (1 - pixel[3]) })) / luminance(paper)
        }
        let delimiter = try #require(editor.fragment(at: editor.find("|--:|").location) as? BlockFragment)
        #expect(abs(delimiter.layoutFragmentFrame.height - line / 2) <= 0.5)
        let ruled = try Drawn(delimiter)
        let middle = delimiter.lineTop + (line / 4).rounded()
        let rule = ruled.inked(left: delimiter.tableStart + 1, right: delimiter.tableStart + 40)
        #expect(rule == (0..<Int(ruled.scale)).map { middle - 0.5 + CGFloat($0) / ruled.scale }, "the rule's rows \(rule) about \(middle)")
        let ruleContrast = contrast(ruled.pixel(x: delimiter.tableStart + 20, y: middle))
        for row in rows.dropFirst(2) {
            let fragment = try #require(editor.fragment(at: row) as? BlockFragment)
            #expect(abs(fragment.lineTop - line / 2) <= 0.5)
            let drawn = try Drawn(fragment)
            let hairline = drawn.inked(left: fragment.tableStart + 1, right: fragment.tableStart + 40, top: 0, bottom: fragment.lineTop)
            #expect(hairline.count == 1 && abs((hairline.first ?? 0) - fragment.lineTop / 2) <= 0.5, "the hairline's rows \(hairline)")
            let faint = contrast(drawn.pixel(x: fragment.tableStart + 20, y: hairline.first ?? 0))
            #expect(faint > 0 && faint <= ruleContrast * 2 / 3, "hairline \(faint) against the rule's \(ruleContrast)")
        }
        let heading = try editor.lineBox(at: 0), head = try editor.lineBox(at: rows[0])
        #expect(abs(head.minY - heading.maxY - line / 2) <= 0.5)
        let last = try editor.lineBox(at: rows[4]), setting = try editor.lineBox(at: editor.find("| Setting").location)
        #expect(abs(setting.minY - last.maxY - line) <= 0.5)
        // The wide table draws its cells, their text as far below its row's top as an unwrapped row's.
        let wide = try #require(editor.fragment(at: editor.find("| `POST /v1/events`").location) as? BlockFragment)
        guard case .table(let wrapped) = wide.line.role, wrapped.cells.count == 5 else { Issue.record("the wide table does not wrap at 900"); return }
        let platform = wrapped.cells[1]
        let drawnTop = try Drawn(wide).inked(left: wide.tableStart + platform.x, right: wide.tableStart + platform.x + platform.width, top: wide.lineTop).first
        let plain = try #require(editor.fragment(at: rows[1]) as? BlockFragment)
        let notes = editor.frame("First retry is fast so a blip costs nothing")
        let plainTop = try Drawn(plain).inked(left: editor.x(notes.minX, in: plain), right: editor.x(notes.maxX, in: plain), top: plain.lineTop).first
        let (drawnInk, plainInk) = (try #require(drawnTop) - wide.lineTop, try #require(plainTop) - plain.lineTop)
        #expect(abs(drawnInk - plainInk) <= 0.5, "drawn text \(drawnInk) below its row's top, unwrapped \(plainInk)")
    }

    /// T3: with the caret on the head the delimiter line stays a rule; on the delimiter line its pipes take the rows'
    /// places and each dash run starts at its column, in syntax color, small enough for its half line.
    @Test func theDelimiterLineShowsItsDashesInTheirColumns() throws {
        let editor = Editor(Self.text, caret: 0)
        let storage = try #require(editor.view.textStorage)
        let text = Self.text as NSString
        let gap = (MarkdownStyler.bodyFont.pointSize * 1.5).rounded()
        let delimiter = editor.find("|:-----|----:|:----:|")
        let head = editor.find("| Name | Qty | Note |")
        func pipes(_ line: NSRange) throws -> [CGFloat] {
            try (line.location..<NSMaxRange(line)).filter { text.character(at: $0) == 0x7C }.map { try editor.pipeX(at: $0) }
        }
        let columns = try pipes(head)
        #expect(abs(columns[0] - (editor.edge - gap / 2)) <= 0.5, "the leading pipe at \(columns[0]) for the edge at \(editor.edge)")
        let height = try editor.fragment(at: delimiter.location).layoutFragmentFrame.height
        editor.place(editor.find("Name").location)
        #expect(editor.rect(delimiter).width <= 0.5)
        guard case .table(let rule)? = editor.role(at: delimiter.location), rule.across else { Issue.record("no rule under the head"); return }
        editor.place(delimiter.location + 2)
        let font = try #require(storage.attribute(.font, at: delimiter.location + 2, effectiveRange: nil) as? NSFont)
        let body = MarkdownStyler.bodyFont
        let fitted = (ThemeStore.shared.bodyLineHeight * body.pointSize / (body.ascender - body.descender)).rounded(.down) / 2
        #expect(font.pointSize == fitted && font.familyName == body.familyName)
        if Self.defaults { #expect(fitted == 9.5) }
        #expect(storage.attribute(.foregroundColor, at: delimiter.location + 2, effectiveRange: nil) as? NSColor == ThemeStore.shared.color(.syntax))
        let shown = try pipes(delimiter)
        #expect(shown.count == columns.count && zip(shown, columns).allSatisfy { abs($0 - $1) <= 0.5 }, "pipes at \(shown), the rows' at \(columns)")
        let starts = [editor.edge] + columns.dropFirst().dropLast().map { $0 + gap / 2 }
        for (run, start) in zip([":-----", "----:", ":----:"], starts) {
            let x = try editor.glyphX(at: editor.find(run, from: delimiter.location).location)
            #expect(abs(x - start) <= 0.5, "\(run) at \(x), its column at \(start)")
        }
        #expect(abs(try editor.fragment(at: delimiter.location).layoutFragmentFrame.height - height) <= 0.5)
    }

    /// T4: every cell sets its figures tabular in a face that has them, and keeps the face's own in one that does not.
    @Test func cellsTakeTabularFiguresWhenTheFaceHasThem() throws {
        let store = ThemeStore.shared
        let face = store.bodyFace
        defer { store.bodyFace = face }
        for name in ["Seravek", "Charter", "Avenir Next"] {
            store.bodyFace = name
            let editor = Editor(Self.backoff, caret: 0)
            let storage = try #require(editor.view.textStorage)
            let body = MarkdownStyler.bodyFont
            #expect(body.familyName == name)
            let monospaced = (CTFontCopyFeatures(body) as? [[String: Any]] ?? []).contains { feature in
                feature[kCTFontFeatureTypeIdentifierKey as String] as? Int == kNumberSpacingType
                    && (feature[kCTFontFeatureTypeSelectorsKey as String] as? [[String: Any]] ?? []).contains {
                        $0[kCTFontFeatureSelectorIdentifierKey as String] as? Int == kMonospacedNumbersSelector
                    }
            }
            for cell in ["Attempt", "1", "256 s", "8.5 min", "First retry", "Default", "3600 s", "0.1"] {
                let font = try #require(storage.attribute(.font, at: editor.find(cell).location, effectiveRange: nil) as? NSFont)
                let settings = font.fontDescriptor.object(forKey: .featureSettings) as? [[NSFontDescriptor.FeatureKey: Any]] ?? []
                let tabular = settings.contains {
                    $0[.typeIdentifier] as? Int == kNumberSpacingType && $0[.selectorIdentifier] as? Int == kMonospacedNumbersSelector
                }
                #expect(tabular == monospaced && font.familyName == name, "\(cell) in \(font) with \(name) as the body face")
            }
        }
    }

    /// T6: a column of numbers with at most a 3-letter unit or a percent sign aligns right; a longer word keeps it left.
    @Test func numbersWithShortUnitsAlignRight() {
        let editor = Editor("| Count | Wait | Change |\n|---|---|---|\n| 3 apples | 8.5 min | -5 |\n| 3 | 1 h | $5 |\n| 2 | 30 s | 12% |\n", caret: 0)
        let apples = editor.rect("3 apples"), three = editor.rect(NSRange(location: editor.find("| 3 |").location + 2, length: 1))
        #expect(abs(apples.minX - three.minX) <= 0.5 && abs(apples.maxX - three.maxX) > 10)
        let minutes = editor.rect("8.5 min"), hour = editor.rect("1 h"), seconds = editor.rect("30 s")
        #expect(abs(minutes.maxX - hour.maxX) <= 0.5 && abs(minutes.maxX - seconds.maxX) <= 0.5)
        let minus = editor.rect("-5"), dollars = editor.rect("$5"), percent = editor.rect("12%")
        #expect(abs(minus.maxX - dollars.maxX) <= 0.5 && abs(minus.maxX - percent.maxX) <= 0.5)
        #expect(["256 s", "8.5 min", "-5", "$5", "12%", "1,024"].allSatisfy(Tables.isNumber))
        #expect(!["3 apples", "v2", "1.", "", "12 %s"].contains(where: Tables.isNumber))
    }

    /// T8: a task's box is 0.75 em square on the center of a bullet beside it, at each depth.
    @Test func aTaskBoxSitsOnASiblingBulletsCenter() throws {
        let text = "- one\n- [ ] two\n  - three\n  - [x] four\n\nEnd\n"
        let editor = Editor(text, caret: text.utf16.count)
        let side = (0.75 * ThemeStore.shared.bodySize).rounded()
        for (bullet, word, task) in [("- one", "one", "- [ ] two"), ("  - three", "three", "  - [x] four")] {
            let item = try editor.fragment(at: editor.find(bullet).location)
            let drawn = try Drawn(item)
            let dot = try #require(drawn.center(left: drawn.bounds.minX, right: editor.x(editor.frame(word).minX, in: item) - 1))
            let fragment = try #require(editor.fragment(at: editor.find(task).location) as? BlockFragment)
            let box = try #require(fragment.taskBoxRect)
            #expect(box.width == side && box.height == side)
            #expect(abs(fragment.layoutFragmentFrame.minX + box.midX - (item.layoutFragmentFrame.minX + dot.x)) <= 0.5, "\(task)'s box at \(box), the bullet at \(dot)")
            let (itemTop, taskTop) = try (#require(item.textLineFragments.first).typographicBounds.minY, #require(fragment.textLineFragments.first).typographicBounds.minY)
            #expect(abs(box.midY - taskTop - (dot.y - itemTop)) <= 0.5)
        }
    }

    /// T10: a wrapped head's cells all end on its last line, whose text stands as far above the rule as an unwrapped
    /// head's.
    @Test func aWrappedHeadsCellsSitOnTheRule() throws {
        let editor = Editor(Self.backoff, caret: 0, width: 900)
        let view = editor.view
        let head = try #require(editor.fragment(at: editor.find("| Endpoint").location) as? BlockFragment)
        guard case .table(let rule) = head.line.role, rule.cells.count == 5 else { Issue.record("the wide head does not wrap at 900"); return }
        let height = try #require(head.textLineFragments.first).typographicBounds.height
        for cell in rule.cells {
            let drawn = cell.text.boundingRect(with: NSSize(width: cell.width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin).height
            #expect(abs(cell.top + drawn - height) <= 0.5, "\(cell.text.string) ends \(cell.top + drawn) into a \(height) pt row")
        }
        #expect(rule.cells.contains { $0.top == 0 } && rule.cells.contains { $0.top > 0 })
        func ruleY(_ fragment: BlockFragment) throws -> CGFloat {
            view.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + fragment.lineTop
                + (try #require(fragment.textLineFragments.first).typographicBounds.height / 2).rounded()
        }
        let delimiter = try #require(editor.fragment(at: editor.find("|---|---|---|---|---|").location) as? BlockFragment)
        let plainHead = try #require(editor.fragment(at: editor.find("| Attempt").location) as? BlockFragment)
        let plainDelimiter = try #require(editor.fragment(at: editor.find("|--:|").location) as? BlockFragment)
        // Ink bottoms of words with no descender, on their baselines.
        let owner = rule.cells[1]
        let ownerBottom = try #require(Drawn(head).inked(left: head.tableStart + owner.x, right: head.tableStart + owner.x + owner.width).last)
        let wait = editor.frame("Wait")
        let waitBottom = try #require(Drawn(plainHead).inked(left: editor.x(wait.minX, in: plainHead), right: editor.x(wait.maxX, in: plainHead)).last)
        let drawn = try ruleY(delimiter) - (view.textContainerOrigin.y + head.layoutFragmentFrame.minY + ownerBottom)
        let plain = try ruleY(plainDelimiter) - (view.textContainerOrigin.y + plainHead.layoutFragmentFrame.minY + waitBottom)
        #expect(abs(drawn - plain) <= 0.5, "the wrapped head's text \(drawn) above its rule, an unwrapped head's \(plain)")
        let baseline = try #require(view.baseline(at: editor.find("Attempt").location))
        if Self.defaults { #expect(abs(try ruleY(plainDelimiter) - baseline - 10.8) <= 0.5) }
    }

    /// T11: a table that fit when the caret came in keeps one-line rows while typing widens it past the container, and
    /// wraps once the caret leaves.
    @Test func aTableKeepsItsFitUntilTheCaretLeaves() {
        let editor = Editor("Intro\n\n| a | b |\n|---|---|\n| c | d |\n\nAfter\n", caret: 0, width: 500)
        let view = editor.view
        func drawn() -> [Bool] {
            ["| a", "| c"].map { row in
                if case .table(let rule)? = editor.role(at: editor.find(row).location) { !rule.cells.isEmpty } else { true }
            }
        }
        #expect(drawn() == [false, false])
        editor.place(NSMaxRange(editor.find("| c")))
        for _ in 0..<12 {
            editor.edit { view.insertText(" wide words", replacementRange: view.selectedRange()) }
            #expect(drawn() == [false, false])
        }
        guard case .table(let rule)? = editor.role(at: editor.find("| a").location) else { Issue.record("no rule on the head"); return }
        #expect(rule.width > view.textContainer!.size.width)
        editor.place(0)
        #expect(drawn() == [true, true])
    }

    @Test func tabAndShiftTabMoveBetweenCellsPastTheDelimiterRow() {
        let editor = Editor(Self.text, caret: 0)
        editor.place(editor.find("Name").location + 1)
        let body = editor.find("| apple").location
        for (cell, from) in [("Qty", 0), ("Note", 0), ("apple", 0), ("3", body), ("ok", body), ("kiwi fruit", 0)] {
            editor.view.insertTab(nil)
            #expect(editor.view.selectedRange() == editor.find(cell, from: from), "Tab to \(cell)")
        }
        editor.view.insertBacktab(nil)
        #expect(editor.view.selectedRange() == editor.find("ok"))
        editor.place(editor.find("Name").location)
        editor.view.insertBacktab(nil)
        #expect(editor.view.selectedRange() == editor.find("Name"))
        #expect(editor.view.string == Self.text)
    }

    /// The table after Tab in its last cell, aligned, with the alignments kept.
    static let added = """
        Intro

        | Name       | Qty | Note     |
        | :--------- | --: | :------: |
        | apple      | 3   | ok       |
        | kiwi fruit | 12  | fine one |
        |            |     |          |

        After

        """

    @Test func tabInTheLastCellAddsAnAlignedRow() {
        let editor = Editor(Self.text, caret: 0)
        editor.place(editor.find("fine").location)
        editor.edit { editor.view.insertTab(nil) }
        #expect(editor.view.string == Self.added)
        #expect(editor.view.selectedRange() == NSRange(location: editor.find("|            |").location + 2, length: 0))
        editor.edit { editor.view.insertText("pear", replacementRange: editor.view.selectedRange()) }
        editor.view.insertTab(nil)
        #expect(editor.view.selectedRange() == NSRange(location: editor.find("pear").location + 17, length: 0))
        editor.view.styler.undoManager.undo()
        editor.view.styler.undoManager.undo()
        #expect(editor.view.string == Self.text)
    }

    @Test func insertRowsAndColumnsAndSelectTheNewCell() throws {
        func run(_ command: TableEditing, at cell: String, from: Int = 0) -> Editor {
            let editor = Editor("| a | b |\n|---|--:|\n| c | d |\n", caret: 0)
            editor.place(editor.find(cell, from: from).location)
            let item = NSMenuItem(title: command.name, action: #selector(EditorTextView.editTableItem(_:)), keyEquivalent: "")
            item.tag = command.rawValue
            #expect(editor.view.validateMenuItem(item))
            editor.edit { editor.view.editTableItem(item) }
            return editor
        }
        let below = run(.rowBelow, at: "a")
        #expect(below.view.string == "| a   | b   |\n| --- | --: |\n|     |     |\n| c   | d   |\n")
        #expect(below.view.selectedRange() == NSRange(location: 30, length: 0))
        let above = run(.rowAbove, at: "c")
        #expect(above.view.string == "| a   | b   |\n| --- | --: |\n|     |     |\n| c   | d   |\n")
        #expect(above.view.selectedRange() == NSRange(location: 30, length: 0))
        #expect(run(.rowAbove, at: "a").view.string == "| a | b |\n|---|--:|\n| c | d |\n")
        let left = run(.columnLeft, at: "d")
        #expect(left.view.string == "| a   |     | b   |\n| --- | --- | --: |\n| c   |     | d   |\n")
        #expect(left.view.selectedRange() == NSRange(location: 48, length: 0))
        let right = run(.columnRight, at: "d")
        #expect(right.view.string == "| a   | b   |     |\n| --- | --: | --- |\n| c   | d   |     |\n")
        #expect(right.view.selectedRange() == NSRange(location: 54, length: 0))
        right.view.styler.undoManager.undo()
        #expect(right.view.string == "| a | b |\n|---|--:|\n| c | d |\n")
        let crlf = Editor("| a | b |\r\n|---|---|\r\n| c | d |\r\n", caret: 0)
        crlf.view.insertBacktab(nil)
        #expect(crlf.view.selectedRange() == crlf.find("a"))
        crlf.place(crlf.find("| c").location)
        crlf.view.insertBacktab(nil)
        #expect(crlf.view.selectedRange() == crlf.find("b"))
        crlf.place(crlf.find("d").location)
        crlf.view.insertTab(nil)
        #expect(crlf.view.string == "| a   | b   |\r\n| --- | --- |\r\n| c   | d   |\r\n|     |     |\r\n")
        // Lines selected across rows take Tab as before, with no cell to move to.
        let rest = (crlf.view.string as NSString).substring(from: 20)
        crlf.view.setSelectedRange(NSRange(location: 0, length: 20))
        crlf.view.insertTab(nil)
        #expect(crlf.view.string == "\t" + rest)
        let outside = Editor("Prose\n\n| a |\n|---|\n", caret: 2)
        let item = NSMenuItem(title: "", action: #selector(EditorTextView.editTableItem(_:)), keyEquivalent: "")
        item.tag = TableEditing.rowBelow.rawValue
        #expect(!outside.view.validateMenuItem(item))
    }
}

@MainActor
struct TaskBoxTests {
    static let text = "- [ ] Buy milk\n- [x] Done\n\nEnd\n"

    @Test func aClickTogglesOneByteAndUndoRestoresIt() throws {
        let editor = Editor(Self.text, caret: Self.text.utf16.count)
        let view = editor.view
        guard case .task(let task)? = editor.role(at: 0) else { Issue.record("no box"); return }
        #expect(!task.checked && task.label == "Buy milk" && task.at == 2)
        // The box sits over its `[ ]`.
        let chars = view.convert(editor.window.convertFromScreen(editor.rect(NSRange(location: 2, length: 3))), from: nil)
        #expect(view.taskBox(at: NSPoint(x: chars.midX, y: chars.midY)) == 3)
        #expect(view.taskBox(at: NSPoint(x: chars.maxX + 40, y: chars.midY)) == nil)
        let caret = view.selectedRange()
        let point = view.convert(NSPoint(x: chars.midX, y: chars.midY), to: nil)
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        editor.edit { view.mouseDown(with: click) }
        let before = Array(Self.text.utf8), after = Array(view.string.utf8)
        #expect(after.count == before.count)
        #expect(zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset) == [3])
        #expect(view.string.hasPrefix("- [x] Buy milk"))
        #expect(view.selectedRange() == caret)
        guard case .task(let checked)? = editor.role(at: 0) else { Issue.record("no box after the click"); return }
        #expect(checked.checked)
        view.styler.undoManager.undo()
        #expect(view.string == Self.text)
    }

    @Test func boxesAreCheckboxesToAccessibility() {
        let editor = Editor(Self.text, caret: Self.text.utf16.count)
        let boxes = (editor.view.accessibilityChildren() ?? []).compactMap { $0 as? TaskBoxElement }
        #expect(boxes.map { $0.accessibilityRole() } == [.checkBox, .checkBox])
        #expect(boxes.map { $0.accessibilityLabel() } == ["Buy milk", "Done"])
        #expect(boxes.map { $0.accessibilityValue() as? Int } == [0, 1])
        editor.edit { _ = boxes.first?.accessibilityPerformPress() }
        #expect(editor.view.string == Self.text.replacingOccurrences(of: "- [ ] Buy", with: "- [x] Buy"))
    }

    @Test func theCaretShowsTheBoxsSource() {
        let editor = Editor(Self.text, caret: Self.text.utf16.count)
        #expect(editor.role(at: 0) != nil)
        editor.place(3)
        #expect(editor.role(at: 0) == nil)
        #expect(editor.view.textStorage!.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor != NSColor.clear)
        editor.place(Self.text.utf16.count)
        #expect(editor.role(at: 0) != nil)
        #expect(editor.view.string == Self.text)
    }
}
