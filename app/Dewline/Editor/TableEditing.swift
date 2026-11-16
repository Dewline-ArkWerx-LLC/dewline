import AppKit

/// Editing a GFM table in its source. Tab and Shift-Tab move between cells and select the next one's text; Tab in the
/// last cell adds a row. An insertion rewrites the table with its pipes aligned and puts the caret in the new cell;
/// moving between cells leaves the text alone.
enum TableEditing: Int, CaseIterable {
    case nextCell = 1, previousCell, rowAbove, rowBelow, columnLeft, columnRight

    /// The menu item's title and the undo action's name; Next Cell edits only when it adds a row.
    var name: String {
        switch self {
        case .nextCell: "Add Row"
        case .previousCell: "Previous Cell"
        case .rowAbove: "Insert Row Above"
        case .rowBelow: "Insert Row Below"
        case .columnLeft: "Insert Column Left"
        case .columnRight: "Insert Column Right"
        }
    }

    /// One line of the table: where its text runs, without the line break, and its cells between the pipes.
    private struct Line {
        let range: NSRange
        let cells: [NSRange]
    }

    /// The edit this command makes in the table whose lines `table` covers, for a caret or selection on one of them.
    /// Moving to a cell is an empty edit at the cell that selects it. Nil when the selection leaves the line it starts
    /// on or is outside the table's lines, or for a row above the header.
    func edit(in text: NSString, table: NSRange, selection: NSRange) -> MarkdownFormat.Edit? {
        let lines = Self.lines(in: text, table)
        guard lines.count >= 2, let row = lines.firstIndex(where: { $0.range.location <= selection.location && selection.location <= NSMaxRange($0.range) }),
            NSMaxRange(selection) <= NSMaxRange(lines[row].range)
        else { return nil }
        // The caret's column is the last cell of its line that starts at or before it; the delimiter row counts as the header.
        let column = lines[row].cells.lastIndex { $0.location <= selection.location } ?? 0
        let gridRow = max(row - 1, 0)
        // The cells in reading order, past the delimiter row.
        let order = lines.indices.filter { $0 != 1 }.flatMap { line in lines[line].cells.indices.map { (line: line, cell: $0) } }
        let current = order.firstIndex { $0.line == (row == 1 ? 0 : row) && $0.cell == column } ?? 0
        switch self {
        case .nextCell where current + 1 < order.count, .previousCell:
            // Shift-Tab in the first cell selects it.
            let next = order[self == .nextCell ? current + 1 : max(current - 1, 0)]
            let cell = Self.trimmed(lines[next.line].cells[next.cell], in: text)
            return MarkdownFormat.Edit(range: NSRange(location: cell.location, length: 0), replacement: "", selection: cell)
        case .nextCell:
            return Self.rewrite(text, lines) { grid in
                grid.rows.append(Array(repeating: "", count: grid.columns))
                return (grid.rows.count - 1, 0)
            }
        case .rowAbove, .rowBelow:
            guard self == .rowBelow || gridRow > 0 else { return nil }
            return Self.rewrite(text, lines) { grid in
                let at = self == .rowAbove ? gridRow : gridRow + 1
                grid.rows.insert(Array(repeating: "", count: grid.columns), at: at)
                return (at, column)
            }
        case .columnLeft, .columnRight:
            return Self.rewrite(text, lines) { grid in
                let at = min(self == .columnLeft ? column : column + 1, grid.columns)
                for index in grid.rows.indices { grid.rows[index].insert("", at: at) }
                grid.alignments.insert(nil, at: at)
                return (gridRow, at)
            }
        }
    }

    /// The table's rows as cell text, header first, and each column's alignment: nil for `---`, else the side or
    /// sides its colons are on.
    private struct Grid {
        var rows: [[String]]
        var alignments: [Tables.Alignment?]

        var columns: Int { alignments.count }
    }

    /// Rewrites the table after `change` edits its grid and names the cell to select, by grid row and column.
    private static func rewrite(_ text: NSString, _ lines: [Line], _ change: (inout Grid) -> (row: Int, column: Int)) -> MarkdownFormat.Edit {
        let cells = { (line: Line) in line.cells.map { text.substring(with: trimmed($0, in: text)) } }
        let delimiter = cells(lines[1]).map { cell -> Tables.Alignment? in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .right
            case (true, false): .left
            case (false, false): nil
            }
        }
        var rows = ([lines[0]] + lines.dropFirst(2)).map(cells)
        // Short rows are padded and long ones kept, so no cell's text is lost.
        let columns = max(rows.map(\.count).max() ?? 0, delimiter.count)
        rows = rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
        var grid = Grid(rows: rows, alignments: delimiter + Array(repeating: nil, count: columns - delimiter.count))
        let target = change(&grid)

        let first = lines[0].range
        let indent = String(text.substring(with: first).prefix { $0 == " " || $0 == "\t" })
        let lineEnd = NSMaxRange(first) + 1 < text.length && text.character(at: NSMaxRange(first)) == 0x0D ? "\r\n" : "\n"
        let widths = (0..<grid.columns).map { column in max(3, grid.rows.map { $0[column].count }.max() ?? 0) }
        var out = ""
        var selection = NSRange(location: 0, length: 0)
        func line(_ row: [String], at index: Int?) {
            out += indent + "|"
            for (column, cell) in row.enumerated() {
                if index == target.row, column == target.column { selection = NSRange(location: out.utf16.count + 1, length: cell.utf16.count) }
                out += " " + cell + String(repeating: " ", count: widths[column] - cell.count) + " |"
            }
        }
        for (index, row) in grid.rows.enumerated() {
            if index > 0 { out += lineEnd }
            line(row, at: index)
            if index == 0 {
                out += lineEnd
                line(zip(grid.alignments, widths).map { alignment, width in
                    switch alignment {
                    case .left: ":" + String(repeating: "-", count: width - 1)
                    case .right: String(repeating: "-", count: width - 1) + ":"
                    case .center: ":" + String(repeating: "-", count: width - 2) + ":"
                    case nil: String(repeating: "-", count: width)
                    }
                }, at: nil)
            }
        }
        let range = NSRange(location: first.location, length: NSMaxRange(lines.last!.range) - first.location)
        return MarkdownFormat.Edit(range: range, replacement: out, selection: NSRange(location: range.location + selection.location, length: selection.length))
    }

    /// The table's lines in `range`, up to its first blank line, each split at its unescaped pipes. The pipes at a
    /// line's ends, when it has them, close its first and last cells.
    private static func lines(in text: NSString, _ range: NSRange) -> [Line] {
        var lines: [Line] = []
        var at = range.location
        while at < NSMaxRange(range) {
            var end = 0, contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: at, length: 0))
            let line = NSRange(location: at, length: contentsEnd - at)
            at = end
            var pipes: [Int] = []
            var escaped = false
            for index in Range(line)! {
                let character = text.character(at: index)
                if character == 0x7C, !escaped { pipes.append(index) }
                escaped = character == 0x5C && !escaped
            }
            let body = trimmed(line, in: text)
            guard body.length > 0 else { break }
            var bounds = [body.location - 1] + pipes + [NSMaxRange(body)]
            if pipes.first == body.location { bounds.removeFirst() }
            if pipes.count > (pipes.first == body.location ? 1 : 0), pipes.last == NSMaxRange(body) - 1 { bounds.removeLast() }
            let cells = zip(bounds, bounds.dropFirst()).map { NSRange(location: $0 + 1, length: $1 - $0 - 1) }
            lines.append(Line(range: line, cells: cells))
        }
        return lines
    }

    /// `range` without the spaces and tabs at its ends; all spaces leave an empty range one space in.
    private static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        let blank = { (index: Int) in [0x20, 0x09].contains(text.character(at: index)) }
        while start < end, blank(start) { start += 1 }
        while end > start, blank(end - 1) { end -= 1 }
        if start == end { return NSRange(location: min(range.location + 1, NSMaxRange(range)), length: 0) }
        return NSRange(location: start, length: end - start)
    }
}
