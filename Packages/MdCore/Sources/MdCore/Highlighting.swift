internal import DewlineFFIBindings
import Foundation

/// What a span of code is, as `core::highlight::Class` numbers it.
public enum CodeClass: UInt32, Sendable, CaseIterable {
    case comment = 1, string, escape, number, constant, keyword, `operator`, type, function, tag, attribute
    case inserted, deleted, heading
}

/// A span of a code block's text, in UTF-16 offsets from the block's start.
public struct CodeSpan: Equatable, Sendable {
    public let range: NSRange
    public let codeClass: CodeClass

    public init(range: NSRange, codeClass: CodeClass) {
        self.range = range
        self.codeClass = codeClass
    }
}

/// Highlights fenced code on one Rust worker thread, which keeps each block's line states (record 0008).
public final class CodeHighlighter: Sendable {
    private let highlighter: DewlineFFIBindings.Highlighter

    /// `syntaxes` is the app's `Syntaxes.packdump`.
    public init(syntaxes: URL) {
        highlighter = DewlineFFIBindings.Highlighter(syntaxes: syntaxes.path)
    }

    /// The spans of `text` in `language`, waiting for the worker, so call it off the main thread. Empty for a language
    /// without a syntax; nil when a newer request for `block` or `forget` overtook this one.
    public func highlight(block: UInt64, language: String, text: String) -> [CodeSpan]? {
        highlighter.highlight(block: block, language: language, text: text).map(Self.spans)
    }

    /// `highlight` for a whole file, `text`, in the syntax its `path` names: by its file name (Makefile), its extension,
    /// or its `#!` line. An edit reparses from its first changed line until the parser is back in step.
    public func highlightFile(block: UInt64, path: String, text: String) -> [CodeSpan]? {
        highlighter.highlightFile(block: block, path: path, text: text).map(Self.spans)
    }

    private static func spans(_ words: [UInt32]) -> [CodeSpan] {
        stride(from: 0, to: words.count, by: 3).compactMap { at in
            CodeClass(rawValue: words[at + 2]).map {
                CodeSpan(range: NSRange(location: Int(words[at]), length: Int(words[at + 1] - words[at])), codeClass: $0)
            }
        }
    }

    /// Cancels `block`'s requests and drops its line states.
    public func forget(_ block: UInt64) {
        highlighter.forget(block: block)
    }
}
