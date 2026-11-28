import AppKit

/// A list item's layout: its later lines hang under its text, past its marker, and a hidden bullet draws as a dot.
@MainActor
enum ListLayout {
    /// Hangs each item of `block`, which starts at `offset` in `styled`, under its text. `widths` holds the markers
    /// measured so far; `quoteIndent` is the text indent of the quote the block sits in, 0 outside one.
    static func style(_ block: BlockMap.Block, offset: Int, in styled: NSMutableAttributedString, widths: inout [NSAttributedString: CGFloat], quoteIndent: CGFloat) {
        for item in block.spans where item.kind == .item {
            let item = item.shifted(by: offset)
            let paragraph = styled.mutableString.paragraphRange(for: NSRange(location: item.range.location, length: 0))
            guard item.content.location <= NSMaxRange(paragraph) else { continue }
            let style = (styled.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle ?? .default).mutableCopy() as! NSMutableParagraphStyle
            let marker = NSRange(location: paragraph.location, length: item.content.location - paragraph.location)
            func measure(_ range: NSRange) -> CGFloat {
                let text = styled.attributedSubstring(from: range)
                let width = widths[text] ?? text.size().width
                widths[text] = width
                return width
            }
            var width = measure(marker)
            // A bullet's text starts an en space past it; a task's box stands in for its bullet.
            let task = block.spans.contains { span in
                if case .taskBox = span.kind { return span.range.location + offset == item.content.location }
                return false
            }
            if isBullet(at: item.range.location, in: styled.mutableString), !task, NSMaxRange(marker) - 1 > item.range.location,
                let font = styled.attribute(.font, at: item.range.location, effectiveRange: nil) as? NSFont {
                let hang = measure(NSRange(location: paragraph.location, length: item.range.location + 1 - paragraph.location)) + font.pointSize / 2
                styled.addAttribute(.kern, value: hang - width, range: NSRange(location: NSMaxRange(marker) - 1, length: 1))
                width = hang
            }
            style.headIndent = style.firstLineHeadIndent + width
            styled.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
    }

    /// Whether the item marker at `index` is a `-`, `*` or `+`.
    static func isBullet(at index: Int, in text: NSString) -> Bool {
        [0x2D, 0x2A, 0x2B].contains(text.character(at: index))
    }
}

/// A list item's paragraph whose `-`, `*` or `+` marker is hidden: a dot in `ink2` centered over the marker.
final class BulletFragment: NSTextLayoutFragment {
    /// The marker's offset in the paragraph.
    private let bullet: Int

    init(bullet: Int, textElement: NSTextElement) {
        self.bullet = bullet
        super.init(textElement: textElement, range: textElement.elementRange)
    }

    required init?(coder: NSCoder) {
        fatalError("BulletFragment is built in code")
    }

    /// The hidden bullet in `paragraph`, past its indent and any quote markers, that keeps its room and is followed by
    /// a space: the styler hides an item's marker that way and no other text.
    static func bullet(in paragraph: NSAttributedString) -> Int? {
        let text = paragraph.string as NSString
        var at = 0
        while at < text.length, [0x20, 0x09, 0x3E].contains(text.character(at: at)) { at += 1 }
        guard at + 1 < text.length, [0x2D, 0x2A, 0x2B].contains(text.character(at: at)), [0x20, 0x09].contains(text.character(at: at + 1)),
            paragraph.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor == NSColor.clear,
            (paragraph.attribute(.font, at: at, effectiveRange: nil) as? NSFont)?.pointSize ?? 0 > 1
        else { return nil }
        return at
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let line = textLineFragments.first(where: { NSLocationInRange(bullet, $0.characterRange) }),
            let font = line.attributedString.attribute(.font, at: bullet, effectiveRange: nil) as? NSFont
        else { return }
        let color = MainActor.assumeIsolated { ThemeStore.shared.color(.ink2) }
        let dot = NSAttributedString(string: "\u{2022}", attributes: [.font: font, .foregroundColor: color])
        let bounds = line.typographicBounds
        let left = line.locationForCharacter(at: bullet).x
        let right = line.locationForCharacter(at: bullet + 1).x
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        dot.draw(at: CGPoint(
            x: point.x + bounds.minX + left + ((right - left - dot.size().width) / 2).rounded(),
            y: point.y + bounds.minY + line.glyphOrigin.y - font.ascender))
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension NSAttributedString.Key {
    /// A list item's marker, by the item's depth.
    static let dewlineListMarker = NSAttributedString.Key("DewlineListMarker")
}
