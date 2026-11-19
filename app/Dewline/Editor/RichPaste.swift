import AppKit
import UniformTypeIdentifiers

extension EditorTextView {
    /// Edit > Copy as Markdown: the selection, or the whole note when nothing is selected, as Markdown text.
    @objc func copyAsMarkdown(_ sender: Any?) {
        writeMarkdown(to: .general)
    }

    /// Edit > Copy as HTML: the selection, or the whole note, as HTML from the core's exporter, for rich text apps and
    /// as its source for text ones.
    @objc func copyAsHTML(_ sender: Any?) {
        writeHTML(to: .general)
    }

    func writeMarkdown(to pboard: NSPasteboard) {
        let text = copiedText
        pboard.clearContents()
        pboard.setString(text, forType: .string)
        pboard.setString(text, forType: NSPasteboard.PasteboardType("net.daringfireball.markdown"))
    }

    func writeHTML(to pboard: NSPasteboard) {
        let html = Export.fragment(copiedText)
        pboard.clearContents()
        pboard.setString(html, forType: .html)
        pboard.setString(html, forType: .string)
    }

    private var copiedText: String {
        let selection = selectedRange()
        return selection.length > 0 ? textStorage!.mutableString.substring(with: selection) : string
    }

    /// Pastes HTML from a web page, Mail or a word processor as Markdown, as one edit. False, for the text view's own
    /// paste, in a code block, when the pasteboard has images or files, its plain text is already Markdown, or its HTML
    /// has nothing Markdown would mark.
    func pasteHTMLAsMarkdown(from pboard: NSPasteboard) -> Bool {
        let types = pboard.types ?? []
        guard styler.map.blocks(in: NSRange(location: selectedRange().location, length: 0)).first?.kind != .code, !types.contains(.fileURL), !types.contains(where: { UTType($0.rawValue)?.conforms(to: .image) == true }),
            let html = pboard.string(forType: .html),
            !(pboard.string(forType: .string).map(HTMLMarkdown.looksLikeMarkdown) ?? false),
            let markdown = HTMLMarkdown.markdown(html)
        else { return false }
        replace(selectedRange(), with: withLineBreaks(markdown))
        return true
    }
}

/// HTML as Markdown: headings, paragraphs, emphasis, code, links, images, lists, task boxes, quotes, rules and tables.
/// Anything else passes its text through.
enum HTMLMarkdown {
    /// `html` as Markdown, or nil when it marks nothing beyond plain paragraphs, as a code editor's colored lines do.
    static func markdown(_ html: String) -> String? {
        guard let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML]), let root = document.rootElement() else { return nil }
        var converter = Converter()
        let text = converter.convert(root)
        guard converter.marked else { return nil }
        let markdown = Converter.clean(text).replacingOccurrences(of: Converter.indent, with: " ")
        return markdown.isEmpty ? nil : markdown
    }

    /// Whether plain text already reads as Markdown source: a heading, list item, quote, fence or table row starts a
    /// line, or it has a link or strong emphasis.
    static func looksLikeMarkdown(_ text: String) -> Bool {
        text.range(of: #"(?m)^ {0,3}(#{1,6} |[-*+] |\d{1,9}[.)] |> |```|~~~|\|.*\|\s*$)|\[[^\]\n]+\]\([^)\s]+\)|\*\*[^*\n]+\*\*"#, options: .regularExpression) != nil
    }

    private struct Converter {
        /// Whether anything Markdown marks came through.
        var marked = false

        mutating func convert(_ node: XMLNode) -> String {
            switch node.kind {
            case .text:
                return (node.stringValue ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .replacingOccurrences(of: #"([*`\\])"#, with: #"\\$1"#, options: .regularExpression)
            case .element:
                return element(node as! XMLElement)
            default:
                return children(node)
            }
        }

        private mutating func children(_ node: XMLNode) -> String {
            var out = ""
            for child in node.children ?? [] { out += convert(child) }
            return out
        }

        private mutating func element(_ element: XMLElement) -> String {
            let name = element.name?.lowercased() ?? ""
            let style = (element.attribute(forName: "style")?.stringValue ?? "").replacingOccurrences(of: " ", with: "")
            func attribute(_ key: String) -> String {
                element.attribute(forName: key)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            switch name {
            case "head", "script", "style", "title", "meta", "noscript", "template":
                return ""
            case "h1", "h2", "h3", "h4", "h5", "h6":
                marked = true
                let level = Int(name.dropFirst())!
                return "\n\n" + String(repeating: "#", count: level) + " " + Self.oneLine(children(element)) + "\n\n"
            case "p", "div", "section", "article", "header", "footer", "main", "aside", "figure", "figcaption", "dl", "dt", "dd":
                return "\n\n" + children(element) + "\n\n"
            case "br":
                return "\n"
            // Google Docs wraps a whole copy in a <b> styled back to normal weight.
            case "b" where style.contains("font-weight:normal"):
                return children(element)
            case "strong", "b":
                return wrap(children(element), "**")
            case "em", "i", "cite":
                return wrap(children(element), "*")
            case "del", "s", "strike":
                return wrap(children(element), "~~")
            case "span" where style.contains("font-weight:700") || style.contains("font-weight:bold"):
                return wrap(children(element), "**")
            case "span" where style.contains("font-style:italic"):
                return wrap(children(element), "*")
            case "code", "kbd", "samp":
                let code = Self.oneLine(element.stringValue ?? "")
                guard !code.isEmpty else { return "" }
                marked = true
                let fence = code.contains("`") ? "``" : "`"
                return fence + (code.hasPrefix("`") ? " " : "") + code + (code.hasSuffix("`") ? " " : "") + fence
            case "pre":
                marked = true
                var code = element.stringValue ?? ""
                while code.hasSuffix("\n") { code.removeLast() }
                let fence = code.contains("```") ? "~~~" : "```"
                return "\n\n" + fence + "\n" + code + "\n" + fence + "\n\n"
            case "a":
                let text = children(element)
                let href = attribute("href")
                guard !href.isEmpty, !href.hasPrefix("#"), !href.lowercased().hasPrefix("javascript:"), !text.trimmingCharacters(in: .whitespaces).isEmpty
                else { return text }
                marked = true
                return "[" + Self.oneLine(text) + "](" + Self.destination(href) + ")"
            case "img":
                let source = attribute("src")
                guard !source.isEmpty else { return "" }
                marked = true
                return "![" + Self.oneLine(attribute("alt")).replacingOccurrences(of: "]", with: "\\]") + "](" + Self.destination(source) + ")"
            case "input" where attribute("type").lowercased() == "checkbox":
                marked = true
                return element.attribute(forName: "checked") == nil ? "[ ] " : "[x] "
            case "ul", "ol":
                marked = true
                var number = Int(attribute("start")) ?? 1
                var items: [String] = []
                for child in element.children ?? [] {
                    guard let item = child as? XMLElement, item.name?.lowercased() == "li" else { continue }
                    let marker = name == "ol" ? "\(number). " : "- "
                    number += 1
                    let body = Self.clean(children(item)).replacingOccurrences(of: #"\n\n+"#, with: "\n", options: .regularExpression)
                    let indent = String(repeating: Self.indent, count: marker.count)
                    items.append(marker + body.replacingOccurrences(of: "\n", with: "\n" + indent))
                }
                return "\n\n" + items.joined(separator: "\n") + "\n\n"
            case "li":
                return "\n\n- " + children(element) + "\n\n"
            case "blockquote":
                marked = true
                let body = Self.clean(children(element)).split(separator: "\n", omittingEmptySubsequences: false)
                return "\n\n" + body.map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n") + "\n\n"
            case "hr":
                marked = true
                return "\n\n---\n\n"
            case "table":
                marked = true
                var rows: [[String]] = []
                func collect(_ node: XMLNode) {
                    for child in node.children ?? [] {
                        guard let child = child as? XMLElement else { continue }
                        switch child.name?.lowercased() {
                        case "tr":
                            rows.append((child.children ?? []).compactMap { cell -> String? in
                                guard let cell = cell as? XMLElement, ["td", "th"].contains(cell.name?.lowercased()) else { return nil }
                                return Self.oneLine(children(cell)).replacingOccurrences(of: "|", with: "\\|")
                            })
                        case "table": continue
                        default: collect(child)
                        }
                    }
                }
                collect(element)
                let columns = rows.map(\.count).max() ?? 0
                guard columns > 0 else { return "" }
                let lines = rows.map { "| " + ($0 + Array(repeating: "", count: columns - $0.count)).joined(separator: " | ") + " |" }
                let delimiter = "|" + String(repeating: " --- |", count: columns)
                return "\n\n" + ([lines[0], delimiter] + lines.dropFirst()).joined(separator: "\n") + "\n\n"
            default:
                return children(element)
            }
        }

        /// `text` between `mark`s, with its outer spaces outside them.
        private mutating func wrap(_ text: String, _ mark: String) -> String {
            let inner = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !inner.isEmpty else { return text }
            marked = true
            let lead = text.prefix { $0.isWhitespace }.isEmpty ? "" : " "
            let trail = text.reversed().prefix { $0.isWhitespace }.isEmpty ? "" : " "
            return lead + mark + inner + mark + trail
        }

        /// A space of indent, until `markdown` writes it as one.
        static let indent = "\u{E000}"

        private static func oneLine(_ text: String) -> String {
            text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }

        /// A link destination, in angle brackets when it has spaces or parentheses.
        private static func destination(_ url: String) -> String {
            url.contains(where: { " ()".contains($0) }) ? "<" + url.replacingOccurrences(of: ">", with: "%3E") + ">" : url
        }

        /// Lines trimmed outside code fences, runs of blank lines down to one, and no blank lines at the ends. A list
        /// item's indent is `indent`, which trimming keeps.
        static func clean(_ text: String) -> String {
            var lines: [String] = []
            var fence: String?
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let open = fence {
                    lines.append(line)
                    if trimmed == open { fence = nil }
                    continue
                }
                if trimmed == "```" || trimmed == "~~~" { fence = trimmed }
                if trimmed.isEmpty, lines.last?.isEmpty ?? true { continue }
                lines.append(trimmed)
            }
            while lines.last?.isEmpty == true { lines.removeLast() }
            return lines.joined(separator: "\n")
        }
    }
}
