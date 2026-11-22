internal import DewlineFFIBindings
import CoreGraphics
import Foundation
import ImageIO

/// Why a diagram or formula did not render, in words for the editor.
public struct RenderFailure: Error, Sendable, Equatable {
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }
}

/// The editor theme's colors for a diagram, each sRGB 0xRRGGBBAA: labels in the ink, lines and borders in ink2, boxes
/// filled with `fill`, notes edged in the accent.
public struct DiagramColors: Hashable, Sendable {
    public let paper, ink, ink2, accent, fill: UInt32

    public init(paper: UInt32, ink: UInt32, ink2: UInt32, accent: UInt32, fill: UInt32) {
        (self.paper, self.ink, self.ink2, self.accent, self.fill) = (paper, ink, ink2, accent, fill)
    }

    fileprivate var ffi: DewlineFFIBindings.DiagramColors {
        .init(paper: paper, ink: ink, ink2: ink2, accent: accent, fill: fill)
    }
}

/// A diagram or formula as outlines in points from its top left, filled at whatever scale the screen has, so it stays
/// as sharp as the text around it. Unchecked because CGPath is not marked Sendable; the paths never change after init.
public final class Drawing: @unchecked Sendable {
    public let size: CGSize
    /// How far a formula reaches below its baseline, in points.
    public let depth: CGFloat
    private let shapes: [(path: CGPath, color: CGColor, evenOdd: Bool)]
    private let insets: [(rect: CGRect, image: CGImage)]

    init(_ drawing: DewlineFFIBindings.Drawing) {
        size = CGSize(width: CGFloat(drawing.width), height: CGFloat(drawing.height))
        depth = CGFloat(drawing.depth)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        shapes = drawing.shapes.map { shape in
            let path = CGMutablePath()
            var at = 0
            func next() -> CGPoint {
                defer { at += 2 }
                return CGPoint(x: CGFloat(shape.points[at]), y: CGFloat(shape.points[at + 1]))
            }
            for verb in shape.verbs {
                switch verb {
                case 0: path.move(to: next())
                case 1: path.addLine(to: next())
                case 2:
                    let control = next()
                    path.addQuadCurve(to: next(), control: control)
                case 3:
                    let (first, second) = (next(), next())
                    path.addCurve(to: next(), control1: first, control2: second)
                default: path.closeSubpath()
                }
            }
            let rgba = withUnsafeBytes(of: shape.color.bigEndian) { $0.map { CGFloat($0) / 255 } }
            return (path, CGColor(colorSpace: srgb, components: rgba)!, shape.evenOdd)
        }
        insets = drawing.insets.compactMap { inset in
            guard let source = CGImageSourceCreateWithData(inset.data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            return (CGRect(x: CGFloat(inset.x), y: CGFloat(inset.y), width: CGFloat(inset.width), height: CGFloat(inset.height)), image)
        }
    }

    /// Fills the outlines into `rect` of a context whose y axis points down.
    public func draw(in rect: CGRect, of context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / size.width, y: rect.height / size.height)
        for shape in shapes {
            context.addPath(shape.path)
            context.setFillColor(shape.color)
            context.fillPath(using: shape.evenOdd ? .evenOdd : .winding)
        }
        context.interpolationQuality = .high
        for inset in insets {
            context.saveGState()
            context.translateBy(x: inset.rect.minX, y: inset.rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(inset.image, in: CGRect(origin: .zero, size: inset.rect.size))
            context.restoreGState()
        }
        context.restoreGState()
    }
}

/// A Mermaid diagram drawn by the engine in `colors`, its labels in the `font` family at `size` points.
public func mermaidDrawing(_ source: String, colors: DiagramColors, font: String, size: Double) throws(RenderFailure) -> Drawing {
    Drawing(try engine { try drawMermaid(source: source, colors: colors.ffi, font: font, fontSize: Float(size)) })
}

/// Math typeset by RaTeX at `size` points in `color` (0xRRGGBBAA), to sit on a line of text.
public func mathDrawing(_ tex: String, size: Double, color: UInt32) throws(RenderFailure) -> Drawing {
    Drawing(try engine { try drawMath(tex: tex, size: Float(size), color: color) })
}

/// `text` as a standalone HTML page with `css` inlined, images inside `folder` inlined, and diagrams and math in
/// `colors`, with a second picture in `dark` colors for a dark page, and fenced code colored in the `syntaxes` dump when it
/// loads; raw HTML in the source shows as text.
public func exportPage(
    _ text: String, title: String, css: String, folder: URL?, colors: DiagramColors, dark: DiagramColors?, mathSize: Double,
    syntaxes: URL?
) throws(RenderFailure) -> String {
    try engine {
        try exportHtml(
            text: text, title: title, css: css, folder: folder?.path, colors: colors.ffi, dark: dark?.ffi, mathSize: Float(mathSize),
            syntaxes: syntaxes?.path
        )
    }
}

/// `text` as an EPUB 3 book of the page `exportPage` writes in `colors`, its images, diagrams and math as files in it.
public func exportEPUB(_ text: String, title: String, css: String, folder: URL?, colors: DiagramColors, mathSize: Double) throws(RenderFailure) -> Data {
    do {
        return try exportEpub(text: text, title: title, css: css, folder: folder?.path, colors: colors.ffi, mathSize: Float(mathSize))
    } catch ExportError.Io(let message) {
        throw RenderFailure(message)
    } catch {
        throw RenderFailure("\(error)")
    }
}

/// `text` as a LaTeX article named `name`, and the files to write beside it, each at a path relative to the article's
/// folder: diagrams drawn in `colors`, and PNG and JPEG images read from inside `folder`.
public func exportLaTeX(_ text: String, name: String, folder: URL?, colors: DiagramColors) throws(RenderFailure) -> (tex: String, files: [(path: String, data: Data)]) {
    let article = try engine { try exportLatex(text: text, name: name, folder: folder?.path, colors: colors.ffi) }
    return (article.text, article.files.map { ($0.path, $0.bytes) })
}

/// `text` as Markdown any renderer shows, and the images to write beside it, each at a path relative to the export's
/// folder: wikilinks as relative links to the notes found in `folder`, highlights as `<mark>`, comments left out.
public func exportPortableMarkdown(_ text: String, name: String, folder: URL?) throws(RenderFailure) -> (text: String, files: [(path: String, data: Data)]) {
    let export = try engine { try DewlineFFIBindings.exportPortableMarkdown(text: text, name: name, folder: folder?.path) }
    return (export.text, export.files.map { ($0.path, $0.bytes) })
}

/// `text` as a Word document, with relative images read from inside `folder`.
public func exportWordDocument(_ text: String, folder: URL) throws(RenderFailure) -> Data {
    do {
        return try exportDocx(markdown: text, folder: folder.path)
    } catch ExportError.Io(let message) {
        throw RenderFailure(message)
    } catch {
        throw RenderFailure("\(error)")
    }
}

/// `text` as plain text: markers dropped, bullets, numbers and table columns kept.
public func exportPlainText(_ text: String) throws(RenderFailure) -> String {
    try engine { try exportText(markdown: text) }
}

private func engine<T>(_ call: () throws -> T) throws(RenderFailure) -> T {
    do {
        return try call()
    } catch RenderError.TooLarge {
        throw RenderFailure("the source is over 50 KB")
    } catch RenderError.TooSlow {
        throw RenderFailure("rendering took over 250 ms")
    } catch RenderError.Invalid(let message) {
        throw RenderFailure(message)
    } catch {
        throw RenderFailure("\(error)")
    }
}
