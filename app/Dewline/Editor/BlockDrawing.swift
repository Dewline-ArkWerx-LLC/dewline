import AppKit

/// How one line of a rendered block lays out and draws: the value of `.dewlineBlock`. The picture's line reserves
/// its height, the block's other lines collapse, a failed block's last line carries the error below it, and folded
/// front matter's first line draws its summary. A laid-out table row draws its column rules, and a task item its box.
final class BlockLine: NSObject {
    enum Role {
        case picture(BlockPicture, label: String), collapsed, error(String), table(TableRule), task(TaskMark), summary(NSAttributedString)
    }

    let role: Role
    static let errorHeight: CGFloat = 20

    init(_ role: Role) {
        self.role = role
    }

    override func isEqual(_ object: Any?) -> Bool {
        switch (role, (object as? BlockLine)?.role) {
        case let (.picture(picture, label), .picture(other, otherLabel)?):
            picture.identity == other.identity && picture.size == other.size && label == otherLabel
        case (.collapsed, .collapsed?): true
        case let (.error(message), .error(other)?): message == other
        case let (.table(rule), .table(other)?): rule == other
        case let (.task(task), .task(other)?): task == other
        case let (.summary(line), .summary(other)?): line.isEqual(to: other)
        default: false
        }
    }

    override var hash: Int {
        switch role {
        case .picture(let picture, _): picture.identity.hashValue
        case .collapsed: 0
        case .error(let message): message.hashValue
        case .table(let rule): [rule.width, rule.hang].hashValue ^ rule.kind.hashValue
        case .task(let task): task.at
        case .summary(let line): line.string.hashValue
        }
    }
}

/// A table line's rules, in points from its first column's start: the delimiter line's runs across the columns under the
/// head (`across`) unless the caret shows its source, and a body row's hairline sits in the space above it. A line whose
/// source starts with a pipe hangs that pipe `hang` left of the column. A row too wide for the text draws its cells,
/// wrapped in their columns.
struct TableRule: Equatable {
    enum Kind {
        case head, delimiter, body
    }

    let width: CGFloat
    let across: Bool
    /// The delimiter line's rule, or a body row's hairline, which draws at 60%.
    let color: NSColor
    var kind = Kind.body
    var hang: CGFloat = 0
    var cells: [TableCell] = []
}

/// A cell drawn at `x`, `top` below its row's first line top, wrapped to `width`, all in points from its row's first
/// column. `source` is the cell's text in the row's paragraph, from the paragraph's start.
struct TableCell: Equatable {
    let x: CGFloat
    let top: CGFloat
    let width: CGFloat
    let text: NSAttributedString
    let source: NSRange
}

/// A task item's box, where a sibling's bullet sits, for the `[ ]` that starts `at` characters into the line.
struct TaskMark: Equatable {
    let at: Int
    let checked: Bool
    let label: String
    /// The open box's edge.
    let stroke: NSColor
    /// The done box's edge and its check, drawn and never filled.
    let check: NSColor
}

extension NSAttributedString.Key {
    static let dewlineBlock = NSAttributedString.Key("DewlineBlock")
}

/// Paragraphs that carry `.dewlineBlock` lay out as `BlockFragment`s.
final class BlockFragments: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
            let line = paragraph.attributedString.attribute(.dewlineBlock, at: 0, effectiveRange: nil) as? BlockLine
        else { return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange) }
        return BlockFragment(line, textElement: textElement)
    }
}

/// Draws a block's picture in place of its hidden first line, nothing for its collapsed lines, and the error
/// under a failed block's source. The heights come from the line's paragraph style.
final class BlockFragment: NSTextLayoutFragment {
    let line: BlockLine

    init(_ line: BlockLine, textElement: NSTextElement) {
        self.line = line
        super.init(textElement: textElement, range: textElement.elementRange)
    }

    required init?(coder: NSCoder) {
        fatalError("BlockFragment is built in code")
    }

    private var column: CGFloat {
        textLayoutManager?.textContainer?.column ?? 0
    }

    private var textBottom: CGFloat {
        textLineFragments.last?.typographicBounds.maxY ?? 0
    }

    /// The first line's top, below the space before the paragraph.
    var lineTop: CGFloat {
        textLineFragments.first?.typographicBounds.minY ?? 0
    }

    override var renderingSurfaceBounds: CGRect {
        switch line.role {
        case .picture(let picture, _): CGRect(origin: CGPoint(x: picture.x(in: column), y: lineTop), size: picture.size)
        case .collapsed: .zero
        case .table(let rule):
            super.renderingSurfaceBounds.union(CGRect(
                x: min(textStart, 0), y: -1, width: tableStart + rule.width + 1 - min(textStart, 0), height: layoutFragmentFrame.height + 2
            ))
        case .task: super.renderingSurfaceBounds
        case .summary(let line): CGRect(origin: .zero, size: CGSize(width: line.size().width + 16, height: layoutFragmentFrame.height))
        case .error:
            // The error is wider than the line it hangs under.
            super.renderingSurfaceBounds.union(CGRect(
                x: 0, y: textBottom, width: column, height: BlockLine.errorHeight
            ))
        }
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        switch line.role {
        case .picture(let picture, _):
            let frame = CGRect(origin: CGPoint(x: point.x + picture.x(in: column), y: point.y + lineTop), size: picture.size)
            let dark = NSAppearance.currentDrawing().isDark
            guard case .image = picture.art, dark || picture.kind == .image else { return picture.draw(in: frame, of: context) }
            // An embedded image draws in 6 pt corners with a 1 px rim, black at 8% on a light page and white at 10% on a
            // dark one, where it also draws at 88% brightness; on a dark page a link card takes a faint 1 pt rim, so a
            // light one reads as placed.
            guard picture.kind == .image else {
                picture.draw(in: frame, of: context)
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
                context.setLineWidth(1)
                return context.stroke(frame.insetBy(dx: 0.5, dy: 0.5))
            }
            context.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.1) : CGColor(gray: 0, alpha: 0.08))
            let pixel = 1 / max(abs(context.convertToDeviceSpace(CGSize(width: 1, height: 1)).width), 1)
            let radius = min(6, frame.width / 2, frame.height / 2)
            context.saveGState()
            context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
            context.beginTransparencyLayer(in: frame, auxiliaryInfo: nil)
            picture.draw(in: frame, of: context)
            if dark {
                context.setBlendMode(.sourceAtop)
                context.setFillColor(CGColor(gray: 0, alpha: 0.12))
                context.fill(frame)
            }
            context.endTransparencyLayer()
            context.restoreGState()
            let rim = frame.insetBy(dx: pixel / 2, dy: pixel / 2)
            let inner = max(min(radius - pixel / 2, rim.width / 2, rim.height / 2), 0)
            context.addPath(CGPath(roundedRect: rim, cornerWidth: inner, cornerHeight: inner, transform: nil))
            context.setLineWidth(pixel)
            context.strokePath()
        case .collapsed:
            break
        case .summary(let line):
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let height = textLineFragments.first?.typographicBounds.height ?? layoutFragmentFrame.height
            line.draw(at: CGPoint(x: point.x + (textLayoutManager?.textContainer?.lineFragmentPadding ?? 0), y: point.y + lineTop + (height - line.size().height) / 2))
            NSGraphicsContext.restoreGraphicsState()
        case .error(let message):
            super.draw(at: point, in: context)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            NSAttributedString(string: message, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            ]).draw(at: CGPoint(x: point.x, y: point.y + textBottom + 3))
            NSGraphicsContext.restoreGraphicsState()
        case .table(let rule):
            super.draw(at: point, in: context)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let left = point.x + tableStart
            if rule.across {
                rule.color.setFill()
                let middle = ((textLineFragments.first?.typographicBounds.height ?? layoutFragmentFrame.height) / 2).rounded()
                NSRect(x: left, y: point.y + lineTop + middle - 0.5, width: rule.width, height: 1).fill()
            }
            // One device pixel at the middle of the space above a body row.
            if rule.kind == .body, lineTop > 0 {
                let pixel = 1 / max(abs(context.convertToDeviceSpace(CGSize(width: 1, height: 1)).width), 1)
                rule.color.withAlphaComponent(0.6).setFill()
                NSRect(x: left, y: ((point.y + lineTop / 2) / pixel).rounded(.down) * pixel, width: rule.width, height: pixel).fill()
            }
            for cell in rule.cells {
                let top = lineTop + cell.top
                cell.text.draw(with: NSRect(x: left + cell.x, y: point.y + top, width: cell.width, height: layoutFragmentFrame.height - top), options: .usesLineFragmentOrigin)
            }
            NSGraphicsContext.restoreGraphicsState()
        case .task(let task):
            super.draw(at: point, in: context)
            guard let box = taskBoxRect?.offsetBy(dx: point.x, dy: point.y) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: box.width * 0.22, yRadius: box.width * 0.22)
            outline.lineWidth = 1.5
            if task.checked {
                task.check.setStroke()
                outline.stroke()
                let mark = NSBezierPath()
                mark.move(to: NSPoint(x: box.minX + box.width * 0.25, y: box.minY + box.height * 0.52))
                mark.line(to: NSPoint(x: box.minX + box.width * 0.43, y: box.minY + box.height * 0.7))
                mark.line(to: NSPoint(x: box.minX + box.width * 0.76, y: box.minY + box.height * 0.3))
                mark.lineWidth = 1.5
                mark.lineCapStyle = .round
                mark.lineJoinStyle = .round
                task.check.setStroke()
                mark.stroke()
            } else {
                task.stroke.setStroke()
                outline.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// A table line's leading pipe hangs left of its first column.
    override var leadingPadding: CGFloat {
        guard case .table(let rule) = line.role else { return super.leadingPadding }
        return -rule.hang
    }

    /// Where the first line's text starts, in this fragment's coordinates.
    var textStart: CGFloat {
        guard let line = textLineFragments.first else { return 0 }
        return line.typographicBounds.minX + line.locationForCharacter(at: line.characterRange.location).x
    }

    /// Where a table line's first column starts, in this fragment's coordinates: past its hanging pipe.
    var tableStart: CGFloat {
        guard case .table(let rule) = line.role else { return textStart }
        return textStart + rule.hang
    }

    /// A task's box, in this fragment's coordinates: a 0.75 em square centered 0.75 em left of the item's text, on the
    /// first line's x-height middle, where a sibling bullet sits.
    var taskBoxRect: CGRect? {
        guard case .task = line.role, let text = textLineFragments.first,
            let style = text.attributedString.attribute(.paragraphStyle, at: text.characterRange.location, effectiveRange: nil) as? NSParagraphStyle
        else { return nil }
        let (size, xHeight) = MainActor.assumeIsolated { (ThemeStore.shared.bodyFont.pointSize, ThemeStore.shared.bodyFont.xHeight) }
        let side = (0.75 * size).rounded()
        let bounds = text.typographicBounds
        // The paragraph's first character starts at its first line's head indent.
        let x = textStart - style.firstLineHeadIndent + style.headIndent - side
        let y = bounds.minY + text.glyphOrigin.y - xHeight / 2
        return CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)
    }
}
