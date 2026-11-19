internal import DewlineFFIBindings
import Foundation

/// A match of a plain-text search. Ranges count UTF-16 code units, as NSString does: `range` in the file's text after
/// any byte-order mark, `previewRange` in `preview`.
public struct TextMatch: Sendable, Equatable {
    /// Counted from 1.
    public let line: Int
    public let range: NSRange
    /// The line around the match, with "…" where it was cut.
    public let preview: String
    public let previewRange: NSRange
}

public struct FileMatches: Sendable {
    public let url: URL
    public let matches: [TextMatch]
}

public struct SearchOptions: Sendable, Equatable {
    public var matchCase: Bool
    public var wholeWord: Bool
    /// The query is a regular expression, matched within a line.
    public var regex: Bool

    public init(matchCase: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.regex = regex
    }
}

/// Why a search or a replace did nothing.
public enum SearchFailure: Error, Sendable, Equatable {
    /// The pattern doesn't compile, and the message says why.
    case pattern(String)
    /// The file resolves outside the folder.
    case outside
    /// The file no longer holds the bytes it was read with.
    case conflict
    case io(String)

    init(_ error: Error) {
        switch error {
        case SearchError.Pattern(let message): self = .pattern(message)
        case SearchError.Outside: self = .outside
        case SearchError.Conflict: self = .conflict
        case SearchError.Io(let message): self = .io(message)
        default: self = .io("\(error)")
        }
    }
}

/// The matches of `query` in `files`, searched in order, for each file that has one. The search stops after `limit`
/// matches, and `stopped` says matches were left. Without `matchCase` letters match in any case; with `wholeWord` a
/// match starts and ends at word boundaries, and Han and kana characters are words on their own. Files over 64 MB,
/// files that aren't UTF-8 and files that can't be read are skipped.
public func textMatches(of query: String, in files: [URL], options: SearchOptions, limit: Int) throws(SearchFailure)
    -> (files: [FileMatches], stopped: Bool)
{
    let found: SearchResults
    do {
        found = try searchFiles(
            paths: files.map(\.path), query: query, matchCase: options.matchCase, wholeWord: options.wholeWord,
            regex: options.regex, limit: UInt32(clamping: limit)
        )
    } catch {
        throw SearchFailure(error)
    }
    let matches = found.files.map { file in
        FileMatches(url: files[Int(file.file)], matches: file.matches.map { match in
            TextMatch(
                line: Int(match.line),
                range: NSRange(location: Int(match.start), length: Int(match.end - match.start)),
                preview: match.preview,
                previewRange: NSRange(location: Int(match.previewStart), length: Int(match.previewEnd - match.previewStart))
            )
        })
    }
    return (matches, found.stopped)
}

/// `text` with each match of `query` replaced by `replacement`, and how many there were. In a pattern's replacement
/// `$1` or `${name}` stands for what a group matched, and `$$` for a dollar sign.
public func replacingMatches(of query: String, in text: String, with replacement: String, options: SearchOptions)
    throws(SearchFailure) -> (text: String, count: Int)
{
    do {
        let replaced = try replaceText(
            text: text, query: query, with: replacement, matchCase: options.matchCase, wholeWord: options.wholeWord,
            regex: options.regex
        )
        return (replaced.text, Int(replaced.count))
    } catch {
        throw SearchFailure(error)
    }
}

/// Replaces each match of `query` in the file at `url` as `replacingMatches` does, and returns how many there were. Only
/// a file that resolves inside `folder` is written, and only while it still holds what was read. `engine` notes the
/// write as yours.
public func replaceMatches(
    of query: String, inFile url: URL, under folder: URL, with replacement: String, options: SearchOptions, engine: ChangeEngine?
) throws(SearchFailure) -> Int {
    do {
        return Int(try replaceInFile(
            root: folder.path, path: url.path, query: query, with: replacement, matchCase: options.matchCase, wholeWord: options.wholeWord,
            regex: options.regex, engine: engine?.engine
        ))
    } catch {
        throw SearchFailure(error)
    }
}
