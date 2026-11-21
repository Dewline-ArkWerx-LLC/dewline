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
        case .table(let rule): rule.width.hashValue
        case .task(let task): task.at
        case .summary(let line): line.string.hashValue
        }
    }
}

/// A table line's rule, in points from where its text starts: the delimiter row's runs across the columns under the
/// head. A row too wide for the text draws its cells, wrapped in their columns.
struct TableRule: Equatable {
    let width: CGFloat
    let across: Bool
    let color: NSColor
    var cells: [TableCell] = []
}

/// A cell drawn at `x`, wrapped to `width`, both in points from where its row's text starts. `source` is the cell's
/// text in the row's paragraph, from the paragraph's start.
struct TableCell: Equatable {
    let x: CGFloat
    let width: CGFloat
    let text: NSAttributedString
    let source: NSRange
}

/// A task item's box over its hidden `[ ]`, which starts `at` characters into the line.
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

    override var renderingSurfaceBounds: CGRect {
        switch line.role {
        case .picture(let picture, _): CGRect(origin: CGPoint(x: picture.x(in: column), y: 0), size: picture.size)
        case .collapsed: .zero
        case .table(let rule):
            super.renderingSurfaceBounds.union(CGRect(x: 0, y: -1, width: textStart + rule.width + 1, height: layoutFragmentFrame.height + 2))
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
            let frame = CGRect(origin: CGPoint(x: point.x + picture.x(in: column), y: point.y), size: picture.size)
            guard case .image = picture.art, NSAppearance.currentDrawing().isDark else { return picture.draw(in: frame, of: context) }
            // On a dark page an embedded image draws at 88% brightness in 6 pt corners with a 1 px rim, and a link card
            // takes a faint 1 pt rim, so a light one reads as placed.
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
            guard picture.kind == .image else {
                picture.draw(in: frame, of: context)
                context.setLineWidth(1)
                return context.stroke(frame.insetBy(dx: 0.5, dy: 0.5))
            }
            let pixel = 1 / max(abs(context.convertToDeviceSpace(CGSize(width: 1, height: 1)).width), 1)
            let radius = min(6, frame.width / 2, frame.height / 2)
            context.saveGState()
            context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
            context.beginTransparencyLayer(in: frame, auxiliaryInfo: nil)
            picture.draw(in: frame, of: context)
            context.setBlendMode(.sourceAtop)
            context.setFillColor(CGColor(gray: 0, alpha: 0.12))
            context.fill(frame)
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
            line.draw(at: CGPoint(x: point.x + (textLayoutManager?.textContainer?.lineFragmentPadding ?? 0), y: point.y + (layoutFragmentFrame.height - line.size().height) / 2))
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
            rule.color.setFill()
            let left = point.x + textStart
            if rule.across {
                NSRect(x: left, y: point.y + (layoutFragmentFrame.height / 2).rounded() - 0.5, width: rule.width, height: 1).fill()
            }
            for cell in rule.cells {
                cell.text.draw(with: NSRect(x: left + cell.x, y: point.y, width: cell.width, height: layoutFragmentFrame.height), options: .usesLineFragmentOrigin)
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

    /// Where the first line's text starts, in this fragment's coordinates.
    var textStart: CGFloat {
        guard let line = textLineFragments.first else { return 0 }
        return line.typographicBounds.minX + line.locationForCharacter(at: line.characterRange.location).x
    }

    /// A task's box, in this fragment's coordinates: a square over the `[ ]` that sits on the baseline.
    var taskBoxRect: CGRect? {
        guard case .task(let task) = line.role,
            let text = textLineFragments.first(where: { NSLocationInRange(task.at, $0.characterRange) })
        else { return nil }
        let start = text.locationForCharacter(at: task.at).x
        let end = text.locationForCharacter(at: task.at + 3).x
        let bounds = text.typographicBounds
        let side = min(end - start, bounds.height * 0.6).rounded()
        let baseline = bounds.minY + text.glyphOrigin.y
        return CGRect(x: bounds.minX + start + ((end - start - side) / 2).rounded(), y: (baseline + 1 - side).rounded(), width: side, height: side)
    }
}
