import AppKit
import MdCore

/// `[[` outside code lists the folder's notes by name as you type; picking one with Return or Tab closes the link.
extension EditorTextView {
    /// Typing the second `[` of `[[` opens the list.
    func completeWikilink(after typed: Any) {
        guard (typed as? String) == "[", !hasMarkedText(), styler.code == nil, let range = wikilinkName, range.length == 0,
            !styler.isCode(NSRange(location: range.location - 2, length: 2)), let noteFolder
        else { return }
        wikilinkNames = Self.names(NoteLinks.notes(in: noteFolder))
        if !wikilinkNames.isEmpty { complete(nil) }
    }

    /// What follows an unclosed `[[` on the caret's line, up to the caret.
    private var wikilinkName: NSRange? {
        let caret = selectedRange()
        guard caret.length == 0, noteFolder != nil else { return nil }
        let text = textStorage!.mutableString
        let line = text.lineRange(for: NSRange(location: caret.location, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: caret.location - line.location)) as NSString
        let open = before.range(of: "[[", options: .backwards)
        guard open.location != NSNotFound else { return nil }
        let typed = before.substring(from: NSMaxRange(open))
        guard !typed.contains(where: { "[]|#".contains($0) }) else { return nil }
        return NSRange(location: line.location + NSMaxRange(open), length: (typed as NSString).length)
    }

    /// The notes' names as a wikilink gives them: a `.md` note's name without the extension, or its path when another
    /// note has that name.
    private static func names(_ paths: [String]) -> [String] {
        let notes = paths.filter { ($0 as NSString).pathExtension.lowercased() == "md" }.map { ($0 as NSString).deletingPathExtension }
        let stems = notes.map { ($0 as NSString).lastPathComponent }
        var counts: [String: Int] = [:]
        for stem in stems { counts[stem.lowercased(), default: 0] += 1 }
        return zip(notes, stems).map { counts[$1.lowercased()] == 1 ? $1 : $0 }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    override var rangeForUserCompletion: NSRange {
        wikilinkName ?? super.rangeForUserCompletion
    }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard wikilinkName == charRange else { return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index) }
        let typed = textStorage!.mutableString.substring(with: charRange).lowercased()
        let starting = wikilinkNames.filter { $0.lowercased().hasPrefix(typed) }
        let containing = wikilinkNames.filter { !$0.lowercased().hasPrefix(typed) && $0.lowercased().contains(typed) }
        index.pointee = 0
        return Array((starting + containing).prefix(50))
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        let closes = flag && wikilinkName?.location == charRange.location
            && [NSTextMovement.return.rawValue, NSTextMovement.tab.rawValue].contains(movement)
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        guard closes else { return }
        let caret = selectedRange()
        let text = textStorage!.mutableString
        let closed = NSMaxRange(caret) + 2 <= text.length && text.substring(with: NSRange(location: NSMaxRange(caret), length: 2)) == "]]"
        if closed {
            setSelectedRange(NSRange(location: NSMaxRange(caret) + 2, length: 0))
        } else {
            insertText("]]", replacementRange: caret)
        }
    }
}
