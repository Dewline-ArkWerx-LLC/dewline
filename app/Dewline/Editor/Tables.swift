import AppKit

/// GFM tables laid out in place, every row on one geometry: each pipe and the blank on either side of it keep their
/// room, clear, and further padding and extra cells take none, so each cell starts at its column, its leading pipe hangs
/// left of the first column, and the caret's row only shows its pipes. The delimiter line is a half line holding the rule
/// under the head, and shows its dashes in their columns to a caret on it. Body rows stand half a line apart, a hairline
/// between them. A column left unaligned whose body cells are all numbers aligns right.
/// Columns are as wide as their widest cell. A table's rows run past the measure to the container's width; a table wider
/// than that shrinks its columns toward their least widths (a cell of 12 characters or fewer and a code span never
/// wrap), shares the room left in proportion to what each column wants beyond its least, and its rows draw their cells
/// wrapped in their columns. While the selection is in the table, its columns only widen and its rows never switch
/// between one line and wrapped.
@MainActor
final class Tables {
    enum Alignment {
        case left, center, right
    }

    private struct Table {
        let head: BlockMap.Block
        let rows: [BlockMap.Block]

        var range: NSRange {
            NSUnionRange(head.range, rows.last?.range ?? head.range)
        }
    }

    private let map: BlockMap
    /// The token ranges of the heads and rows showing their source.
    private var revealed: Set<NSRange> = []
    /// The table holding the selection, by its head's location, its column widths and whether its rows wrap.
    private var active: (head: Int, widths: [CGFloat], wraps: Bool)?
    /// The delimiter line's font for a body font and line height.
    private var dashes: (body: NSFont, line: CGFloat, font: NSFont)?

    init(map: BlockMap) {
        self.map = map
    }

    /// Moves the revealed rows past an edit the map has taken.
    func textDidChange(edited: NSRange, delta: Int) {
        let oldEnd = NSMaxRange(edited) - delta
        revealed = Set(revealed.compactMap { range in
            if NSMaxRange(range) < edited.location { return range }
            return range.location > oldEnd ? NSRange(location: range.location + delta, length: range.length) : nil
        })
    }

    /// `range` and the whole tables at its ends: a row's columns depend on every row.
    func covering(_ range: NSRange) -> NSRange {
        [range.location, max(NSMaxRange(range) - 1, range.location)].reduce(range) { range, location in
            table(at: location).map { NSUnionRange(range, $0.range) } ?? range
        }
    }

    /// The tables whose rows the selection entered or left since they were last styled.
    func revealChanges(_ selection: [NSRange]) -> [NSRange] {
        var now: Set<NSRange> = []
        for range in selection {
            for block in map.blocks(touching: range) {
                for line in Self.lines(block) where Self.touches(line, selection) { now.insert(line) }
            }
        }
        return Array(Set(now.symmetricDifference(revealed).compactMap { table(at: $0.location)?.range }))
    }

    /// Lays out the tables in `styled`, a copy of the storage from `offset` on, for a selection in its coordinates.
    func style(_ styled: NSMutableAttributedString, at offset: Int, selection: [NSRange], width: CGFloat) {
        let whole = NSRange(location: offset, length: styled.length)
        revealed = revealed.filter { !NSLocationInRange($0.location, whole) }
        for head in map.blocks(in: whole) where head.kind == .tableHead {
            let table = Table(head: head, rows: rows(after: head))
            guard NSMaxRange(table.range) <= NSMaxRange(whole) else { continue }
            lay(table, in: styled, at: offset, selection: selection, width: width)
        }
    }

    private func lay(_ table: Table, in styled: NSMutableAttributedString, at offset: Int, selection: [NSRange], width available: CGFloat) {
        guard let headToken = table.head.spans.first(where: { $0.kind == .tableHead })?.shifted(by: table.head.range.location - offset) else { return }
        let store = ThemeStore.shared
        let text = styled.mutableString
        let header = headToken.content
        var delimiter = NSRange(location: NSMaxRange(header), length: NSMaxRange(headToken.range) - NSMaxRange(header))
        while delimiter.length > 0, [0x0A, 0x0D].contains(text.character(at: delimiter.location)) {
            delimiter = NSRange(location: delimiter.location + 1, length: delimiter.length - 1)
        }
        let alignments = Self.alignments(text.substring(with: delimiter))
        func spans(_ kind: SyntaxSpan.Kind, of block: BlockMap.Block) -> [SyntaxSpan] {
            block.spans.filter { $0.kind == kind }.map { $0.shifted(by: block.range.location - offset) }
        }
        // A caret in a cell's padding, where only typing puts it, keeps the blanks before it as the cell's text, so a
        // typed blank stays a caret stop.
        func cells(of block: BlockMap.Block) -> [(range: NSRange, content: NSRange)] {
            spans(.tableCell, of: block).map { cell in
                guard let caret = selection.first(where: { $0.length == 0 && NSMaxRange(cell.content) < $0.location && $0.location <= NSMaxRange(cell.range) })
                else { return (cell.range, cell.content) }
                return (cell.range, NSRange(location: cell.content.location, length: caret.location - cell.content.location))
            }
        }
        var lines = [(range: header, token: header, cells: cells(of: table.head), code: spans(.inlineCode, of: table.head))]
        for row in table.rows {
            guard let token = row.spans.first(where: { $0.kind == .tableRow })?.shifted(by: row.range.location - offset) else { continue }
            lines.append((token.range, token.range, cells(of: row), spans(.inlineCode, of: row)))
        }
        let count = lines[0].cells.count
        guard count > 0 else { return }

        // Every cell sets its figures tabular when its face has them; the head is semibold, H4's weight, in the
        // heading color.
        let body = MarkdownStyler.bodyFont
        let ink = store.color(.ink)
        for (index, line) in lines.enumerated() {
            for cell in line.cells.prefix(count) {
                styled.enumerateAttribute(.font, in: cell.content) { value, run, _ in
                    guard let font = value as? NSFont, font.pointSize >= 1 else { return }
                    let weighted = index > 0 ? font : font == body ? store.heading(4).font : store.font(font, adding: .bold)
                    styled.addAttribute(.font, value: store.tabular(weighted), range: run)
                }
                guard index == 0 else { continue }
                styled.enumerateAttribute(.foregroundColor, in: cell.content) { value, run, _ in
                    if value as? NSColor === ink { styled.addAttribute(.foregroundColor, value: store.color(.heading), range: run) }
                }
            }
        }
        // A column whose body cells are all numbers aligns right unless its delimiter row sets an alignment.
        var aligned = (0..<count).map { alignments.count > $0 ? alignments[$0] ?? .left : .left }
        for column in 0..<count where alignments.count <= column || alignments[column] == nil {
            let cells = lines.dropFirst().compactMap { $0.cells.count > column ? $0.cells[column].content : nil }
            if !cells.isEmpty, cells.allSatisfy({ Self.isNumber(text.substring(with: $0)) }) { aligned[column] = .right }
        }
        let measured = lines.map { line in line.cells.prefix(count).map { styled.attributedSubstring(from: $0.content).size().width } }
        let natural = (0..<count).map { column in (measured.map { $0.count > column ? $0[column] : 0 }.max() ?? 0).rounded(.up) }
        let gap = (body.pointSize * 1.5).rounded()
        let room = available - gap * CGFloat(count - 1)
        // While the selection is in the table its fit holds: one-line columns only widen, wrapped ones keep their widths.
        let range = NSRange(location: table.head.range.location - offset, length: max(NSMaxRange(headToken.range), NSMaxRange(lines.last!.token)) - (table.head.range.location - offset))
        let inside = Self.touches(range, selection)
        var widths = natural
        let wraps: Bool
        if inside, let held = active, held.head == table.head.range.location, held.widths.count == count {
            wraps = held.wraps
            widths = wraps ? held.widths : zip(natural, held.widths).map { max($0, $1) }
        } else {
            wraps = available > 0 && natural.reduce(0, +) > room
            if wraps {
                let narrowest = lines.map { line in
                    line.cells.prefix(count).map { cell in
                        let code = line.code.filter { NSIntersectionRange($0.range, cell.content) == $0.range }
                        return Self.least(styled.attributedSubstring(from: cell.content), code: code.map { NSRange(location: $0.range.location - cell.content.location, length: $0.range.length) })
                    }
                }
                var least = (0..<count).map { column in narrowest.map { $0.count > column ? $0[column] : 0 }.max() ?? 0 }
                if least.reduce(0, +) > room { least = least.map { min($0, room / CGFloat(count)) } }
                widths = Self.fit(natural, least: least, into: room)
            }
        }
        if inside {
            active = (table.head.range.location, widths, wraps)
        } else if active?.head == table.head.range.location {
            active = nil
        }

        var starts: [CGFloat] = [0]
        for width in widths.dropLast() { starts.append(starts.last! + width + gap) }
        let total = starts.last! + widths.last!
        let lineHeight = store.bodyLineHeight
        let place = { (part: NSRange, cells: [(range: NSRange, content: NSRange)], measured: [CGFloat], aligned: [Alignment], font: NSFont, shown: Bool) in
            Self.place(part, cells: cells, measured: measured, aligned: aligned, starts: starts, widths: widths, gap: gap,
                pipe: NSAttributedString(string: "|", attributes: [.font: font]).size().width, blank: NSAttributedString(string: " ", attributes: [.font: font]).size().width,
                color: shown ? store.color(.syntax) : .clear, in: styled)
        }

        if delimiter.length > 0 {
            let paragraph = text.paragraphRange(for: delimiter)
            styled.addAttribute(.paragraphStyle, value: store.paragraphStyle(lineHeight: lineHeight / 2), range: paragraph)
            let source = Self.delimiterLine(header: header, token: headToken.range)
            let rule: TableRule
            if Self.touches(source, selection) {
                revealed.insert(NSRange(location: source.location + offset, length: source.length))
                // Its dash runs stand in for cells, at the largest half-point size whose ascender to descender fits
                // its half line.
                let font = dashFont(for: body, line: lineHeight / 2)
                styled.addAttributes([.font: font, .foregroundColor: store.color(.syntax)], range: delimiter)
                let runs = Self.cells(ofDelimiter: delimiter, in: text)
                let hang = place(delimiter, Array(runs.prefix(count)), runs.prefix(count).map { styled.attributedSubstring(from: $0.content).size().width },
                    Array(repeating: .left, count: count), font, true)
                rule = TableRule(width: total, across: false, color: store.color(.quoteRule), kind: .delimiter, hang: hang)
            } else {
                styled.addAttributes([.font: MarkdownStyler.hiddenFont, .foregroundColor: NSColor.clear], range: delimiter)
                var outside = IndexSet(integersIn: Range(delimiter)!)
                for run in Self.cells(ofDelimiter: delimiter, in: text) { outside.remove(integersIn: Range(run.content)!) }
                for part in outside.rangeView { styled.addAttribute(.dewlineSkip, value: true, range: NSRange(part)) }
                rule = TableRule(width: total, across: true, color: store.color(.quoteRule), kind: .delimiter)
            }
            styled.addAttribute(.dewlineBlock, value: BlockLine(.table(rule)), range: paragraph)
        }

        for (index, row) in lines.enumerated() {
            let shown = Self.touches(row.token, selection)
            if shown { revealed.insert(NSRange(location: row.token.location + offset, length: row.token.length)) }
            let paragraph = text.paragraphRange(for: NSRange(location: row.range.location, length: 0))
            // Body rows after the first stand half a line apart; the delimiter line spaces the first.
            let before = index > 1 ? lineHeight / 2 : 0
            let kind: TableRule.Kind = index == 0 ? .head : .body
            let color = store.color(index == 0 ? .quoteRule : .rule)
            if wraps, !shown {
                var cells = row.cells.prefix(count).enumerated().map { column, cell in
                    let drawn = Self.cell(styled.attributedSubstring(from: cell.content), aligned[column])
                    return TableCell(x: starts[column], top: 0, width: widths[column], text: drawn,
                        source: NSRange(location: cell.content.location - paragraph.location, length: cell.content.length))
                }
                let heights = cells.map { $0.text.boundingRect(with: NSSize(width: $0.width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin).height }
                let height = max(heights.max() ?? 0, lineHeight).rounded(.up)
                // The head's cells sit on the rule under it.
                if index == 0 {
                    cells = zip(cells, heights).map { TableCell(x: $0.x, top: height - $1, width: $0.width, text: $0.text, source: $0.source) }
                }
                styled.addAttributes([.font: MarkdownStyler.hiddenFont, .foregroundColor: NSColor.clear], range: row.range)
                styled.addAttribute(.paragraphStyle, value: store.paragraphStyle(lineHeight: height, before: before), range: paragraph)
                styled.addAttribute(.dewlineBlock, value: BlockLine(.table(TableRule(width: total, across: false, color: color, kind: kind, cells: cells))), range: paragraph)
                continue
            }
            styled.addAttribute(.paragraphStyle, value: store.paragraphStyle(lineHeight: lineHeight, before: before), range: paragraph)
            let cells = Array(row.cells.prefix(count))
            guard !wraps else {
                // The caret's row of a wrapped table shows its source.
                var outside = IndexSet(integersIn: Range(row.range)!)
                for cell in cells { outside.remove(integersIn: Range(cell.content)!) }
                for part in outside.rangeView { styled.addAttribute(.foregroundColor, value: store.color(.syntax), range: NSRange(part)) }
                continue
            }
            let hang = place(row.range, cells, measured[index], aligned, body, shown)
            styled.addAttribute(.dewlineBlock, value: BlockLine(.table(TableRule(width: total, across: false, color: color, kind: kind, hang: hang))), range: paragraph)
        }
    }

    /// Lays out the line `part` on the columns at `starts`, `widths` wide and `gap` apart, for its cells' text
    /// `measured` wide, and returns how far its leading pipe hangs left of the first column. Each pipe and the blank on
    /// either side of it keep their room, `pipe` and `blank` wide, in `color`, centering the pipe on its gap; further
    /// blanks and cells past the columns take no room; none of them is a caret stop. No kern is negative, and none sits
    /// on the character before a cell's text or on its last glyph unless the source has no blank there: a caret beside
    /// a kerned character stands in the middle of the kern.
    private static func place(
        _ part: NSRange, cells: [(range: NSRange, content: NSRange)], measured: [CGFloat], aligned: [Alignment], starts: [CGFloat], widths: [CGFloat],
        gap: CGFloat, pipe pipeWidth: CGFloat, blank blankWidth: CGFloat, color: NSColor, in styled: NSMutableAttributedString
    ) -> CGFloat {
        let text = styled.mutableString
        var outside = IndexSet(integersIn: Range(part)!)
        for cell in cells { outside.remove(integersIn: Range(cell.content)!) }
        func pipe(_ at: Int) -> Int? {
            NSLocationInRange(at, part) && text.character(at: at) == 0x7C ? at : nil
        }
        func blank(_ at: Int) -> Int? {
            outside.contains(at) && text.character(at: at) == 0x20 ? at : nil
        }
        let leading = cells.first.flatMap { pipe($0.range.location - 1) }
        let trailing = cells.last.flatMap { pipe(NSMaxRange($0.range)) }
        // The blank after the pipe before each cell, and the one before the pipe after it.
        let left = cells.indices.map { $0 > 0 || leading != nil ? blank(cells[$0].range.location) : nil }
        let right = cells.indices.map { $0 < cells.count - 1 || trailing != nil ? blank(NSMaxRange(cells[$0].range) - 1) : nil }
        var kept = IndexSet((leading.map { [$0] } ?? []) + cells.dropFirst().map { $0.range.location - 1 } + (trailing.map { [$0] } ?? []))
        for at in (left + right).compactMap({ $0 }) { kept.insert(at) }
        // An empty cell's first blank is a caret stop, where its text will start.
        var skipped = outside
        for (column, cell) in cells.enumerated() where cell.content.length == 0 {
            if let blank = left[column] { skipped.remove(blank) }
        }
        for at in outside.rangeView {
            styled.addAttribute(.foregroundColor, value: color, range: NSRange(at))
        }
        for at in skipped.rangeView {
            styled.addAttribute(.dewlineSkip, value: true, range: NSRange(at))
        }
        for at in outside.subtracting(kept).rangeView {
            styled.addAttribute(.font, value: MarkdownStyler.hiddenFont, range: NSRange(at))
        }
        let hang = leading == nil ? 0 : gap / 2 + pipeWidth / 2
        // The pen runs from the line's start, `hang` left of the first column; each kern moves it from where the text
        // before it ends to where the next pipe or text wants it.
        var kerns: [Int: CGFloat] = [:]
        var pen: CGFloat = 0
        var last: Int?
        func advance(_ at: Int, _ width: CGFloat) {
            // An empty cell's one blank stands after the pipe before it and before the pipe after it.
            guard at != last else { return }
            pen += width
            last = at
        }
        func move(to x: CGFloat) {
            guard let last, x > pen else { return }
            kerns[last, default: 0] += x - pen
            pen = x
        }
        func cross(_ at: Int, after column: Int, center: CGFloat) {
            if column >= 0, let blank = right[column] { advance(blank, blankWidth) }
            move(to: hang + center - pipeWidth / 2)
            advance(at, pipeWidth)
        }
        for (column, cell) in cells.enumerated() {
            let inset: CGFloat = switch aligned[column] {
            case .left: 0
            case .center: ((widths[column] - measured[column]) / 2).rounded()
            case .right: widths[column] - measured[column]
            }
            let start = hang + starts[column] + inset
            if column > 0 || leading != nil {
                cross(cell.range.location - 1, after: column - 1, center: starts[column] - gap / 2)
                if let blank = left[column] {
                    move(to: start - blankWidth)
                    advance(blank, blankWidth)
                }
            }
            move(to: start)
            if cell.content.length > 0 { advance(NSMaxRange(cell.content) - 1, measured[column]) }
        }
        if let trailing { cross(trailing, after: cells.count - 1, center: starts[cells.count - 1] + widths[cells.count - 1] + gap / 2) }
        for (at, kern) in kerns {
            let character = text.rangeOfComposedCharacterSequence(at: at)
            let current = styled.attribute(.kern, at: character.location, effectiveRange: nil) as? CGFloat ?? 0
            styled.addAttribute(.kern, value: current + kern, range: character)
        }
        return hang
    }

    /// The delimiter line's dash runs as cells: the text between two pipes, or a line's end, and its dashes and colons.
    private static func cells(ofDelimiter line: NSRange, in text: NSString) -> [(range: NSRange, content: NSRange)] {
        var cells: [(range: NSRange, content: NSRange)] = []
        var start = line.location
        for at in line.location...NSMaxRange(line) where at == NSMaxRange(line) || text.character(at: at) == 0x7C {
            let range = NSRange(location: start, length: at - start)
            start = at + 1
            var content = range
            while content.length > 0, [0x20, 0x09].contains(text.character(at: content.location)) { content = NSRange(location: content.location + 1, length: content.length - 1) }
            while content.length > 0, [0x20, 0x09].contains(text.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
            // No cell before a leading pipe or after a trailing one.
            if content.length > 0 || (at < NSMaxRange(line) && range.location > line.location) { cells.append((range, content)) }
        }
        return cells
    }

    /// The body face at the largest half-point size whose ascender to descender fits `line`.
    private func dashFont(for body: NSFont, line: CGFloat) -> NSFont {
        if let dashes, dashes.body == body, dashes.line == line { return dashes.font }
        let size = (2 * line * body.pointSize / (body.ascender - body.descender)).rounded(.down) / 2
        let font = NSFont(descriptor: body.fontDescriptor, size: size) ?? body
        dashes = (body, line, font)
        return font
    }

    /// The delimiter line of a head whose token is `token` and header line `header`: past the header's line break,
    /// so a caret at the header's end is not on it.
    private static func delimiterLine(header: NSRange, token: NSRange) -> NSRange {
        NSRange(location: NSMaxRange(header) + 1, length: max(NSMaxRange(token) - NSMaxRange(header) - 1, 0))
    }

    /// Whether a cell holds a number, optionally signed or with a currency sign, then at most a 3-letter unit or %.
    static func isNumber(_ cell: String) -> Bool {
        var rest = Substring(cell)
        if let sign = rest.first, "+-\u{2212}".contains(sign) { rest = rest.dropFirst() }
        if let currency = rest.first, "$\u{20AC}\u{00A3}\u{00A5}".contains(currency) { rest = rest.dropFirst() }
        let number = rest.prefix { $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }
        guard number.first?.isNumber == true, number.last?.isNumber == true else { return false }
        rest = rest.dropFirst(number.count)
        if rest.first == " " { rest = rest.dropFirst() }
        return rest == "%" || (rest.count <= 3 && rest.allSatisfy(\.isLetter))
    }

    /// Column widths that fill `room`: each column keeps its `least`, and what is left goes to each column in proportion
    /// to how much wider than that its widest cell is.
    private static func fit(_ widths: [CGFloat], least: [CGFloat], into room: CGFloat) -> [CGFloat] {
        let slack = max(room - least.reduce(0, +), 0)
        let wanted = zip(widths, least).map { max($0 - $1, 0) }
        let total = wanted.reduce(0, +)
        return zip(least, wanted).map { least, wanted in (least + (total > 0 ? min(wanted, slack * wanted / total) : 0)).rounded(.down) }
    }

    /// The narrowest a cell draws: all of it when it has 12 characters or fewer, else its longest word, each code span
    /// in it counting as one: a path in code breaks at no slash.
    private static func least(_ cell: NSAttributedString, code: [NSRange]) -> CGFloat {
        if cell.string.trimmingCharacters(in: .whitespaces).count <= 12 { return cell.size().width.rounded(.up) }
        var widest = code.map { cell.attributedSubstring(from: $0).size().width }.max() ?? 0
        (cell.string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: cell.length), options: .byWords) { _, word, _, _ in
            widest = max(widest, cell.attributedSubstring(from: word).size().width)
        }
        return widest.rounded(.up)
    }

    /// A cell's text, aligned for drawing in its column, its code spans on their background with no break at their blanks.
    private static func cell(_ text: NSAttributedString, _ alignment: Alignment) -> NSAttributedString {
        let aligned = NSMutableAttributedString(attributedString: text)
        aligned.enumerateAttribute(.dewlineCodeChip, in: NSRange(location: 0, length: aligned.length)) { value, run, _ in
            guard value != nil else { return }
            aligned.addAttribute(.backgroundColor, value: ThemeStore.shared.color(.codeBackground), range: run)
            aligned.mutableString.replaceOccurrences(of: " ", with: "\u{00A0}", range: run)
        }
        guard alignment != .left else { return aligned }
        let style = ThemeStore.shared.paragraphStyle(lineHeight: ThemeStore.shared.bodyLineHeight).mutableCopy() as! NSMutableParagraphStyle
        style.alignment = alignment == .center ? .center : .right
        aligned.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: aligned.length))
        return aligned
    }

    /// The alignment of each column in a delimiter row: `:--` left, `:-:` center, `--:` right, `---` nil.
    static func alignments(_ delimiter: String) -> [Alignment?] {
        var row = Substring(delimiter.trimmingCharacters(in: .whitespacesAndNewlines))
        if row.hasPrefix("|") { row = row.dropFirst() }
        if row.hasSuffix("|") { row = row.dropLast() }
        return row.split(separator: "|", omittingEmptySubsequences: false).map { cell in
            let cell = cell.trimmingCharacters(in: .whitespaces)
            if cell.hasSuffix(":") { return cell.hasPrefix(":") ? .center : .right }
            return cell.hasPrefix(":") ? .left : nil
        }
    }

    /// The lines of a head, its header and delimiter lines, or a row's, in the document.
    private static func lines(_ block: BlockMap.Block) -> [NSRange] {
        guard block.kind == .tableHead || block.kind == .tableRow,
            let token = block.spans.first(where: { $0.kind == .tableHead || $0.kind == .tableRow })?.shifted(by: block.range.location)
        else { return [] }
        return token.kind == .tableHead ? [token.content, delimiterLine(header: token.content, token: token.range)] : [token.range]
    }

    private func block(at location: Int) -> BlockMap.Block? {
        location >= 0 ? map.blocks(in: NSRange(location: location, length: 0)).first : nil
    }

    private func rows(after head: BlockMap.Block) -> [BlockMap.Block] {
        var rows: [BlockMap.Block] = []
        var end = NSMaxRange(head.range)
        while let next = block(at: end), next.range.location == end, next.kind == .tableRow {
            rows.append(next)
            end = NSMaxRange(next.range)
        }
        return rows
    }

    /// The lines of the table holding `location`, from its head to its last row.
    func range(at location: Int) -> NSRange? {
        table(at: location)?.range
    }

    /// The table holding the line at `location`.
    private func table(at location: Int) -> Table? {
        guard var head = block(at: location), head.kind == .tableHead || head.kind == .tableRow else { return nil }
        while head.kind == .tableRow {
            guard let above = block(at: head.range.location - 1), NSMaxRange(above.range) == head.range.location,
                above.kind == .tableHead || above.kind == .tableRow
            else { return nil }
            head = above
        }
        return Table(head: head, rows: rows(after: head))
    }

    private static func touches(_ range: NSRange, _ selection: [NSRange]) -> Bool {
        selection.contains { $0.location <= NSMaxRange(range) && NSMaxRange($0) >= range.location }
    }
}
