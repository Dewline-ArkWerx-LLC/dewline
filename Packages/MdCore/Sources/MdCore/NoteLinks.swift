internal import DewlineFFIBindings
import Foundation

/// A line in another note that links to a note. `range` is the link's, in UTF-16 code units of the file's text after
/// any byte-order mark.
public struct Backlink: Sendable, Equatable {
    public let url: URL
    /// Counted from 1.
    public let line: Int
    public let range: NSRange
    /// The line, trimmed.
    public let preview: String
}

/// Links between the notes in a folder: wikilinks by name, the shortest path winning, and relative markdown links.
public enum NoteLinks {
    /// The notes under `folder`, relative to it, in name order: `.md`, `.markdown` and `.txt` files outside dot
    /// folders, `node_modules` and what git ignores. Walks the folder, so call it off the main thread.
    public static func notes(in folder: URL) -> [String] {
        (try? notePaths(root: folder.path)) ?? []
    }

    /// The lines in the other notes under `folder` that link to `note`, at most 200. Reads every note, so call it off
    /// the main thread.
    public static func backlinks(to note: URL, in folder: URL) -> [Backlink] {
        ((try? noteBacklinks(root: folder.path, note: note.path)) ?? []).map { link in
            Backlink(
                url: URL(filePath: link.path), line: Int(link.line),
                range: NSRange(location: Int(link.start), length: Int(link.end - link.start)), preview: link.preview
            )
        }
    }

    /// Points the links to the file or folder moved from `old` to `new` in the notes under `folder` at where it is now.
    /// Closed notes change on disk, which `engine` notes as yours; for each of `open`, the edits its text takes.
    public static func relink(
        from old: URL, to new: URL, in folder: URL, open: [(url: URL, text: String)], engine: ChangeEngine?
    ) -> [[ChangeEngine.Edit]] {
        let edits = try? relinkNotes(
            root: folder.path, old: old.path, new: new.path,
            open: open.map { OpenNote(path: $0.url.path, text: $0.text) }, engine: engine?.engine
        )
        return (edits ?? []).map { edits in
            edits.map { ChangeEngine.Edit(range: NSRange(location: Int($0.start), length: Int($0.end - $0.start)), text: $0.text) }
        }
    }
}
