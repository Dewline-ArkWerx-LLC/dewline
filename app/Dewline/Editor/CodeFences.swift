import AppKit

/// Fenced code in Live: the block sits in a `codeBackground` well, as wide as the column or its widest line, up to the
/// container's width, and its fence lines are the well's top and bottom padding, their text hidden while the selection
/// is off them. A folded block keeps its fences. A Mermaid block is `RenderedBlocks`'.
@MainActor
final class CodeFences {
    private let map: BlockMap
    /// The blocks whose fence lines show, by their fenced span's range.
    private var revealed: Set<NSRange> = []
    private var indented: [CGFloat: [NSParagraphStyle: NSParagraphStyle]] = [:]
    /// The room on each side of the code, the inset quote and callout text share.
    static var padding: CGFloat {
        ThemeStore.shared.inset
    }
    static let radius: CGFloat = 8
    /// Half the room a code line leaves around its glyphs, on the half-point grid.
    static var lead: CGFloat {
        let font = MarkdownStyler.code(matching: MarkdownStyler.bodyFont)
        return (ThemeStore.shared.bodyLineHeight - font.ascender + font.descender).rounded() / 2
    }
    /// The room between a well's edge and the glyph box of its first and last lines: half a line and the lead.
    static var margin: CGFloat {
        ThemeStore.shared.bodyLineHeight / 2 + lead
    }

    init(map: BlockMap) {
        self.map = map
    }

    /// Moves the revealed blocks past an edit the map has taken.
    func textDidChange(edited: NSRange, delta: Int) {
        let oldEnd = NSMaxRange(edited) - delta
        revealed = Set(revealed.compactMap { range in
            if NSMaxRange(range) < edited.location { return range }
            return range.location > oldEnd ? NSRange(location: range.location + delta, length: range.length) : nil
        })
    }

    /// The blocks whose fence lines the selection reached or left since they were last styled.
    func revealChanges(_ selection: [NSRange], in text: NSString) -> [NSRange] {
        var now: Set<NSRange> = []
        for range in selection {
            for block in map.blocks(touching: range) {
                for fence in Self.fences(block) where Self.lines(fence, in: text).contains(where: { Self.touches($0, selection) }) {
                    now.insert(fence.range)
                }
            }
        }
        return Array(now.symmetricDifference(revealed))
    }

    /// Styles the fenced code in `styled`, a copy of the storage from `offset` on, for a selection in its coordinates.
    /// `folds` are in the storage's.
    func style(_ styled: NSMutableAttributedString, at offset: Int, selection: [NSRange], folds: [NSRange]) {
        let whole = NSRange(location: offset, length: styled.length)
        revealed = revealed.filter { !NSLocationInRange($0.location, whole) }
        let text = styled.mutableString
        for block in map.blocks(in: whole) {
            for fence in Self.fences(block) {
                let local = fence.shifted(by: -offset)
                guard local.range.location >= 0, NSMaxRange(local.range) <= styled.length else { continue }
                let well = text.paragraphRange(for: local.range)
                styled.enumerateAttribute(.paragraphStyle, in: well) { value, run, _ in
                    styled.addAttribute(.paragraphStyle, value: indent(value as? NSParagraphStyle ?? .default), range: run)
                }
                let code = styled.attributedSubstring(from: local.content)
                let lead = code.length > 0 ? (code.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0 : 0
                let widest = code.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin).width
                styled.addAttribute(.dewlineCode, value: CodeWell(start: fence.range.location, width: (lead + widest + Self.padding).rounded(.up)), range: well)
                Self.hang(local.content, in: styled)
                let lines = Self.lines(local, in: text)
                // A fence line is the well's padding, shown or hidden: the opening one half a line less the lead, the
                // closing one half a line and the lead, so the code's glyphs sit as far from the well's top as from its
                // bottom. Shown, its text takes a smaller code font and the line keeps its height.
                let shown = lines.contains(where: { Self.touches($0, selection) }) || folds.contains(where: { NSIntersectionRange($0, fence.range).length > 0 })
                if shown { revealed.insert(fence.range) }
                let store = ThemeStore.shared
                let half = store.bodyLineHeight / 2
                let font = shown ? store.codeFont(size: 0.75 * MarkdownStyler.code(matching: MarkdownStyler.bodyFont).pointSize) : MarkdownStyler.hiddenFont
                for (index, line) in lines.enumerated() {
                    let style = indent(store.paragraphStyle(lineHeight: index == 0 ? half - Self.lead : half + Self.lead))
                    styled.addAttributes([
                        .font: font, .foregroundColor: shown ? store.color(.syntax) : NSColor.clear, .paragraphStyle: style,
                    ], range: text.paragraphRange(for: line))
                }
            }
        }
    }

    /// Each line of `code` wraps one indent past its own leading blanks, so wrapped code keeps its shape.
    private static func hang(_ code: NSRange, in styled: NSMutableAttributedString) {
        let text = styled.mutableString
        guard code.length > 0, let font = styled.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont else { return }
        let space = NSAttributedString(string: " ", attributes: [.font: font]).size().width
        var at = code.location
        while at < NSMaxRange(code) {
            let line = text.paragraphRange(for: NSRange(location: at, length: 0))
            at = NSMaxRange(line)
            var columns = 0
            for index in line.location..<NSMaxRange(line) {
                let character = text.character(at: index)
                guard character == 0x20 || character == 0x09 else { break }
                columns += character == 0x09 ? 4 : 1
            }
            guard let style = styled.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle else { continue }
            let hanging = style.mutableCopy() as! NSMutableParagraphStyle
            hanging.headIndent = style.firstLineHeadIndent + CGFloat(columns + 4) * space
            styled.addAttribute(.paragraphStyle, value: hanging, range: line)
        }
    }

    /// `style` with the well's padding on both sides.
    private func indent(_ style: NSParagraphStyle) -> NSParagraphStyle {
        let padding = Self.padding
        if let indented = indented[padding]?[style] { return indented }
        let wider = style.mutableCopy() as! NSMutableParagraphStyle
        wider.firstLineHeadIndent += padding
        wider.headIndent += padding
        wider.tailIndent = -padding
        indented[padding, default: [:]][style] = wider
        return wider
    }

    /// A code block's fenced spans, in the document, outside rendered blocks.
    private static func fences(_ block: BlockMap.Block) -> [SyntaxSpan] {
        guard block.kind == .code else { return [] }
        return block.spans.filter { span in
            span.kind == .fencedCode && !block.rendered.contains { NSIntersectionRange($0.range, span.range).length > 0 }
        }.map { $0.shifted(by: block.range.location) }
    }

    /// The fence lines of `fence`, without their line breaks: the opening one, and the closing one when it is closed.
    private static func lines(_ fence: SyntaxSpan, in text: NSString) -> [NSRange] {
        func line(_ at: Int) -> NSRange {
            var (start, end, contentsEnd) = (0, 0, 0)
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: min(at, text.length), length: 0))
            return NSRange(location: start, length: contentsEnd - start)
        }
        let opening = line(fence.range.location)
        guard NSMaxRange(fence.content) < NSMaxRange(fence.range) else { return [opening] }
        let closing = line(NSMaxRange(fence.content))
        return closing == opening ? [opening] : [opening, closing]
    }

    private static func touches(_ range: NSRange, _ selection: [NSRange]) -> Bool {
        selection.contains { $0.location <= NSMaxRange(range) && NSMaxRange($0) >= range.location }
    }
}

extension EditorTextView {
    /// Fills each fenced code block in `visible` with its well.
    func drawCodeWells(in visible: NSRange, line: (Int) -> NSRect) {
        let storage = textStorage!
        var drawn = Set<Int>()
        ThemeStore.shared.color(.codeBackground).setFill()
        storage.enumerateAttribute(.dewlineCode, in: visible) { value, range, _ in
            guard let code = value as? CodeWell else { return }
            var whole = NSRange()
            storage.attribute(.dewlineCode, at: range.location, longestEffectiveRange: &whole, in: NSRange(location: 0, length: storage.length))
            guard drawn.insert(whole.location).inserted else { return }
            let well = codeWell(code, top: line(whole.location), bottom: line(max(NSMaxRange(whole) - 1, whole.location)))
            NSBezierPath(roundedRect: well, xRadius: CodeFences.radius, yRadius: CodeFences.radius).fill()
        }
    }

    /// The well of `code` from the line at `top` to the one at `bottom`: from the column's start, as wide as the column or
    /// the block's widest line, up to the container's width.
    func codeWell(_ code: CodeWell, top: NSRect, bottom: NSRect) -> NSRect {
        let padding = textContainer?.lineFragmentPadding ?? 0
        let room = (textContainer?.size.width ?? 0) - 2 * padding
        let width = min(max((textContainer?.column ?? 0) - 2 * padding, code.width), room)
        return NSRect(x: textContainerOrigin.x + padding, y: top.minY, width: width, height: bottom.maxY - top.minY)
    }
}

/// The value of `.dewlineCode`: the block's start, so neighboring blocks stay apart, and how wide its widest line draws,
/// with the well's padding.
struct CodeWell: Hashable {
    let start: Int
    let width: CGFloat
}

extension NSAttributedString.Key {
    /// A fenced code block's lines, as a `CodeWell`.
    static let dewlineCode = NSAttributedString.Key("DewlineCode")
}
