import AppKit

/// A list item from the block map's tokens, in document offsets.
struct ListItem {
    /// From the marker to the end of the item's last line, its children and continuation lines included.
    let span: NSRange
    /// The quote markers that start the marker's line, with the blank after the last one.
    let prefix: NSRange
    /// From the prefix to the marker.
    let indent: NSRange
    /// The bullet or number and the blanks after it.
    let marker: NSRange
    /// After the marker and any task box with its blank.
    let content: Int
    let isTask: Bool
    /// The indent of the item holding this one, after its line's prefix.
    let parentIndent: Int?
}

extension EditorTextView {
    /// The innermost list item holding `offset`, past its marker, in a list or a quote. Items in code are left alone.
    func listItem(at offset: Int) -> ListItem? {
        let text = textStorage!.mutableString
        let spans = styler.map.blocks(touching: NSRange(location: offset, length: 0)).flatMap(Self.spans)
        // An item holds the offsets from its marker to the end of its last line, before the line break.
        let holding = spans.filter { span in
            var end = NSMaxRange(span.range)
            while end > span.range.location, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
            return span.kind == .item && span.range.location <= offset && offset <= end
        }
        guard let span = holding.max(by: { $0.range.location < $1.range.location }), let item = listItem(span, among: spans), offset >= item.content
        else { return nil }
        return item
    }

    /// The item `span` starts, with the other spans of its block, which hold its task box and its parent.
    private func listItem(_ span: SyntaxSpan, among spans: [SyntaxSpan]) -> ListItem? {
        let text = textStorage!.mutableString
        guard let marker = span.markers.first else { return nil }
        let prefix = Self.prefix(of: span.range.location, in: text)
        var content = NSMaxRange(marker)
        let task = spans.first { box in
            if case .taskBox = box.kind { return box.range.location == content }
            return false
        }
        if let task {
            content = NSMaxRange(task.range)
            if content < text.length, text.character(at: content) == 0x20 { content += 1 }
        }
        let parent = spans.filter { $0.kind == .item && Self.holds($0, span.range.location) }.max { $0.range.location < $1.range.location }
        return ListItem(
            span: span.range,
            prefix: prefix,
            indent: NSRange(location: NSMaxRange(prefix), length: span.range.location - NSMaxRange(prefix)),
            marker: marker,
            content: content,
            isTask: task != nil,
            parentIndent: parent.map { $0.range.location - NSMaxRange(Self.prefix(of: $0.range.location, in: text)) }
        )
    }

    /// Return in a list item starts the next item, numbered one on and unchecked, under the same quote markers. Return
    /// on an empty nested item outdents it; on an empty top-level item it leaves the line blank and puts the caret on a
    /// fresh line under it, after the list. Returns false when the caret is not in an item.
    func continueList() -> Bool {
        let text = textStorage!.mutableString
        let selection = selectedRange()
        guard let item = listItem(at: selection.location) else { return false }
        var contentsEnd = 0
        var lineEnd = 0
        text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: item.marker.location, length: 0))
        var newline = text.substring(with: NSRange(location: contentsEnd, length: lineEnd - contentsEnd))
        if newline.isEmpty {
            // The last line: its neighbor above gives the line ending.
            newline = "\n"
            if item.prefix.location > 0 {
                var above = 0
                var aboveEnd = 0
                text.getLineStart(nil, end: &aboveEnd, contentsEnd: &above, for: NSRange(location: item.prefix.location - 1, length: 0))
                if aboveEnd > above { newline = text.substring(with: NSRange(location: above, length: aboveEnd - above)) }
            }
        }
        let prefix = text.substring(with: item.prefix)
        let rest = text.substring(with: NSRange(location: item.content, length: max(contentsEnd - item.content, 0)))
        // A task box with nothing after it may not parse as one.
        let bare = rest.trimmingCharacters(in: .whitespaces)
        if selection.length == 0, selection.location <= contentsEnd, bare.isEmpty || ["[ ]", "[x]", "[X]"].contains(bare) {
            if item.parentIndent != nil { return indentItems(outdent: true) }
            // The break the edit ends with moves the fresh line onto the new line.
            if prefix.isEmpty { styler.fresh = item.indent.location }
            replace(NSRange(location: item.indent.location, length: contentsEnd - item.indent.location), with: newline + prefix)
            return true
        }
        let marker = text.substring(with: item.marker)
        let bullet = marker.trimmingCharacters(in: .whitespaces)
        let blanks = String(marker.dropFirst(bullet.count))
        var next = bullet
        if let number = Int(bullet.prefix { $0.isNumber }) {
            next = "\(number + 1)" + bullet.drop { $0.isNumber }
        }
        let indent = text.substring(with: item.indent)
        replace(selection, with: newline + prefix + (indent.allSatisfy(\.isWhitespace) ? indent : String(repeating: " ", count: indent.count)) + next + blanks + (item.isTask ? "[ ] " : ""))
        return true
    }

    /// Tab moves every item whose marker line meets the selection, with its children and continuation lines, so its
    /// marker lands on its previous sibling's text, written in the sibling's indent and the list's spaces or tabs.
    /// Shift-Tab moves it to its parent's indent. One edit; with no previous sibling, a beep and no edit. Returns false
    /// when no item's marker line meets the selection and the caret is in no item.
    func indentItems(outdent: Bool) -> Bool {
        let text = textStorage!.mutableString
        let selection = selectedRange()
        let lines = text.lineRange(for: selection)
        var items: [ListItem] = []
        var line = lines.location
        repeat {
            let range = text.lineRange(for: NSRange(location: line, length: 0))
            var contentsEnd = 0
            text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: range)
            // A child moves with its item.
            if let item = listItem(at: contentsEnd), item.prefix.location == range.location,
                !items.contains(where: { NSLocationInRange(item.marker.location, $0.span) })
            {
                items.append(item)
            }
            line = NSMaxRange(range)
        } while line < NSMaxRange(lines)
        var edits: [(range: NSRange, string: String)] = []
        for item in items {
            let indent = text.substring(with: item.indent)
            var target = String(indent.prefix(item.parentIndent ?? 0))
            if !outdent {
                guard let sibling = previousSibling(of: item) else {
                    NSSound.beep()
                    return true
                }
                let list = text.substring(with: NSRange(location: sibling.prefix.location, length: NSMaxRange(item.span) - sibling.prefix.location))
                let tabs = list.components(separatedBy: .newlines).contains { line in line.prefix { " \t>".contains($0) }.contains("\t") }
                target = text.substring(with: sibling.indent) + (tabs ? "\t" : String(repeating: " ", count: sibling.marker.length))
            }
            // Each line of the item whose blanks reach its indent swaps that indent for the target's.
            let depth = text.substring(with: item.prefix).filter { $0 == ">" }.count
            var at = item.prefix.location
            while at < NSMaxRange(item.span) {
                let range = text.lineRange(for: NSRange(location: at, length: 0))
                let start = NSMaxRange(Self.prefix(of: range.location, depth: depth, in: text))
                var end = start
                while end < NSMaxRange(range), [0x20, 0x09].contains(text.character(at: end)) { end += 1 }
                if end - start >= item.indent.length, end < NSMaxRange(range), ![0x0A, 0x0D].contains(text.character(at: end)) {
                    let kept = text.substring(with: NSRange(location: start, length: item.indent.length)).commonPrefix(with: target).utf16.count
                    if kept < item.indent.length || kept < target.utf16.count {
                        edits.append((NSRange(location: start + kept, length: item.indent.length - kept), (target as NSString).substring(from: kept)))
                    }
                }
                at = NSMaxRange(range)
            }
        }
        guard !edits.isEmpty else { return listItem(at: selection.location) != nil }
        let changed = NSRange(location: edits[0].range.location, length: NSMaxRange(edits.last!.range) - edits[0].range.location)
        let result = NSMutableString(string: text.substring(with: changed))
        for edit in edits.reversed() {
            result.replaceCharacters(in: NSRange(location: edit.range.location - changed.location, length: edit.range.length), with: edit.string)
        }
        func moved(_ offset: Int) -> Int {
            edits.reduce(offset) { position, edit in
                guard edit.range.location < offset || (edit.range.length == 0 && edit.range.location == offset) else { return position }
                return position + edit.string.utf16.count - min(edit.range.length, offset - edit.range.location)
            }
        }
        let start = moved(selection.location)
        replace(changed, with: result as String, selecting: NSRange(location: start, length: max(moved(NSMaxRange(selection)) - start, 0)))
        return true
    }

    /// The item before `item` at its depth, under the same parent: in its block, or for a top-level item, the item
    /// block right before it. Nil for a list's first item and an item's first child.
    private func previousSibling(of item: ListItem) -> ListItem? {
        guard let block = styler.map.blocks(in: NSRange(location: item.span.location, length: 0)).first else { return nil }
        let spans = Self.spans(of: block)
        let items = spans.filter { $0.kind == .item }
        func parent(_ location: Int) -> Int? {
            items.filter { Self.holds($0, location) }.map(\.range.location).max()
        }
        let level = parent(item.span.location)
        if let sibling = items.filter({ $0.range.location < item.span.location && parent($0.range.location) == level }).max(by: { $0.range.location < $1.range.location }) {
            return listItem(sibling, among: spans)
        }
        guard level == nil, block.kind == .item else { return nil }
        var above: BlockMap.Block?
        styler.map.walk(from: block.range.location, backward: true) { block in
            above = block
            return false
        }
        guard let above, above.kind == .item else { return nil }
        let before = Self.spans(of: above)
        return before.first { $0.kind == .item }.flatMap { listItem($0, among: before) }
    }

    /// `block`'s spans in document offsets.
    private static func spans(of block: BlockMap.Block) -> [SyntaxSpan] {
        block.spans.map { $0.shifted(by: block.range.location) }
    }

    /// Whether the item `span` holds `location` past its own start.
    private static func holds(_ span: SyntaxSpan, _ location: Int) -> Bool {
        span.range.location < location && location <= NSMaxRange(span.range)
    }

    /// The quote markers that start the line holding `location`, `depth` of them at most, and the blank after the last.
    private static func prefix(of location: Int, depth: Int = .max, in text: NSString) -> NSRange {
        let start = text.lineRange(for: NSRange(location: location, length: 0)).location
        var at = start, end = start, found = 0
        while found < depth, at < text.length, [0x20, 0x09, 0x3E].contains(text.character(at: at)) {
            if text.character(at: at) == 0x3E { (found, end) = (found + 1, at + 1) }
            at += 1
        }
        if end > start, end < text.length, [0x20, 0x09].contains(text.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Replaces `range` with `string` as one undoable edit, then selects `selection`, or puts the caret after the
    /// new text.
    func replace(_ range: NSRange, with string: String, selecting selection: NSRange? = nil) {
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: string) else { return }
        textStorage!.replaceCharacters(in: range, with: string)
        didChangeText()
        breakUndoCoalescing()
        setSelectedRange(selection ?? NSRange(location: range.location + string.utf16.count, length: 0))
    }
}
