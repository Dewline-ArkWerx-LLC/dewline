import AppKit

/// Editing a GFM table in its source. Tab and Shift-Tab move between cells and select the next one's text; Tab in the
/// last cell adds a row. Return moves to the same column one row down; on the last row it adds an empty row, and on an
/// empty last row it ends the table. An insertion rewrites the table with its pipes aligned and puts the caret in the
/// new cell; moving between cells leaves the text alone, and Return and the deletions change only the lines they touch.
enum TableEditing: Int, CaseIterable {
    case nextCell = 1, previousCell, rowAbove, rowBelow, columnLeft, columnRight, nextRow, deleteRow, deleteColumn

    /// The commands of the Format menu and of the context menu's Table submenu, in order.
    static let menu: [TableEditing] = [.rowAbove, .rowBelow, .columnLeft, .columnRight, .deleteRow, .deleteColumn]

    /// The menu item's title and the undo action's name. Next Cell edits only when it adds a row, Next Row when it adds a
    /// row or ends the table.
    var name: String {
        switch self {
        case .nextCell, .nextRow: "Add Row"
        case .previousCell: "Previous Cell"
        case .rowAbove: "Insert Row Above"
        case .rowBelow: "Insert Row Below"
        case .columnLeft: "Insert Column Left"
        case .columnRight: "Insert Column Right"
        case .deleteRow: "Delete Row"
        case .deleteColumn: "Delete Column"
        }
    }

    /// One line of the table: where its text runs, without the line break, and its cells between the pipes.
    private struct Line {
        let range: NSRange
        let cells: [NSRange]
    }

    /// The edit this command makes in the table whose lines `table` covers, for a caret or selection on one of them.
    /// Moving to a cell is an empty edit at the cell that selects it. Nil when the selection leaves the line it starts
    /// on or is outside the table's lines, for a row above the header, for deleting the header, the delimiter row or the
    /// only column, and for deleting a column that would leave the header or the delimiter row without a pipe.
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
        case .nextRow:
            let below = max(row + 1, 2)
            if below < lines.count {
                let cells = lines[below].cells
                let end = NSMaxRange(Self.trimmed(cells[min(column, cells.count - 1)], in: text))
                return MarkdownFormat.Edit(range: NSRange(location: end, length: 0), replacement: "", selection: NSRange(location: end, length: 0))
            }
            let last = lines[lines.count - 1]
            let lineEnd = Self.lineEnd(after: lines[0], in: text)
            // An empty last row becomes a blank line under the table, with the caret on a line after it: a line right
            // under the table would be a row.
            if row > 1, last.cells.allSatisfy({ Self.trimmed($0, in: text).length == 0 }) {
                return MarkdownFormat.Edit(range: last.range, replacement: lineEnd, selection: NSRange(location: last.range.location + lineEnd.utf16.count, length: 0))
            }
            // The new row is the last one with its cells blanked: the same cells, pipes and indent.
            let blank = NSMutableString(string: text.substring(with: last.range))
            for cell in last.cells.reversed() {
                blank.replaceCharacters(in: NSRange(location: cell.location - last.range.location, length: cell.length), with: String(repeating: " ", count: cell.length))
            }
            let cell = last.cells[min(column, last.cells.count - 1)]
            let caret = NSMaxRange(last.range) + lineEnd.utf16.count + cell.location - last.range.location + min(cell.length, 1)
            return MarkdownFormat.Edit(range: NSRange(location: NSMaxRange(last.range), length: 0), replacement: lineEnd + (blank as String), selection: NSRange(location: caret, length: 0))
        case .deleteRow:
            guard row > 1 else { return nil }
            let line = lines[row].range
            let whole = text.lineRange(for: line)
            // The text's last line takes the line break before it.
            let removed = NSMaxRange(whole) > NSMaxRange(line) ? whole
                : NSRange(location: NSMaxRange(lines[row - 1].range), length: NSMaxRange(line) - NSMaxRange(lines[row - 1].range))
            let next = row + 1 < lines.count ? row + 1 : row == 2 ? 0 : row - 1
            let cells = lines[next].cells
            var caret = NSMaxRange(Self.trimmed(cells[min(column, cells.count - 1)], in: text))
            if caret > removed.location { caret -= removed.length }
            return MarkdownFormat.Edit(range: removed, replacement: "", selection: NSRange(location: caret, length: 0))
        case .deleteColumn:
            // A header or delimiter row without a pipe is no longer a table's.
            guard lines[0].cells.count > 1, lines.prefix(2).allSatisfy({ line in text.substring(with: line.range).filter { $0 == "|" }.count > 1 }) else { return nil }
            var removed: [NSRange] = []
            for line in lines where column < line.cells.count {
                // The cell and the pipe after it, or before it when none follows.
                let cell = line.cells[column]
                let pipe = (NSMaxRange(cell) < NSMaxRange(line.range) && text.character(at: NSMaxRange(cell)) == 0x7C) ? NSMaxRange(cell) : cell.location - 1
                guard pipe >= line.range.location, text.character(at: pipe) == 0x7C else { return nil }
                removed.append(NSUnionRange(cell, NSRange(location: pipe, length: 1)))
            }
            let range = NSRange(location: removed[0].location, length: NSMaxRange(removed[removed.count - 1]) - removed[0].location)
            let kept = NSMutableString(string: text.substring(with: range))
            for cut in removed.reversed() {
                kept.deleteCharacters(in: NSRange(location: cut.location - range.location, length: cut.length))
            }
            // The caret goes to the end of the cell that takes the column's place, or of the one before it.
            let cells = lines[row].cells
            let end = NSMaxRange(Self.trimmed(cells[column + 1 < cells.count ? column + 1 : max(column - 1, 0)], in: text))
            let caret = end - removed.reduce(0) { $0 + max(0, min(NSMaxRange($1), end) - $1.location) }
            return MarkdownFormat.Edit(range: range, replacement: kept as String, selection: NSRange(location: caret, length: 0))
        }
    }

    /// The line break after `line`: CRLF when the text has one there, else LF.
    private static func lineEnd(after line: Line, in text: NSString) -> String {
        NSMaxRange(line.range) + 1 < text.length && text.character(at: NSMaxRange(line.range)) == 0x0D ? "\r\n" : "\n"
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
        let lineEnd = Self.lineEnd(after: lines[0], in: text)
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
