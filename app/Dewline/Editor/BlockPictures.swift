import AppKit
import ImageIO
import MdCore

/// A rendered block's picture and its size in points.
struct BlockPicture: Sendable {
    /// An image's or link card's pixels, or a diagram's or formula's outlines.
    enum Art: Sendable {
        case image(CGImage), drawing(Drawing)
    }

    let art: Art
    let size: CGSize
    /// The block it draws, or nil for a link card.
    var kind: RenderedBlock.Kind?

    var identity: ObjectIdentifier {
        switch art {
        case .image(let image): ObjectIdentifier(image)
        case .drawing(let drawing): ObjectIdentifier(drawing)
        }
    }

    /// Where the picture starts in a column `width` points wide: display math centers, the rest starts at the edge.
    func x(in width: CGFloat) -> CGFloat {
        kind == .math ? max((width - size.width) / 2, 0).rounded() : 0
    }

    /// Draws into `rect` of a context whose y axis points down: outlines at the context's scale, pixels on whole device
    /// pixels so an image drawn at the screen's scale lands pixel for pixel and a narrowed one resamples smoothly.
    func draw(in rect: CGRect, of context: CGContext) {
        switch art {
        case .drawing(let drawing):
            drawing.draw(in: rect, of: context)
        case .image(let image):
            context.saveGState()
            let device = context.convertToDeviceSpace(rect.origin)
            let origin = context.convertToUserSpace(CGPoint(x: device.x.rounded(), y: device.y.rounded()))
            context.interpolationQuality = .high
            context.translateBy(x: origin.x, y: origin.y + rect.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
    }
}

/// What a picture depends on besides the column width, which only narrows it, so equal requests share a render.
struct PictureRequest: Hashable, Sendable {
    let kind: RenderedBlock.Kind
    /// The diagram, the TeX, or the image file's path.
    let source: String
    let scale: CGFloat
    /// The theme's colors in the view's appearance: a diagram takes them all and math the ink; an image takes none.
    let colors: DiagramColors?
    /// A diagram's label face and size: the body's, at 0.85 of its size.
    var labelFamily = ""
    var labelSize: CGFloat = 14

    /// Renders off the main thread; an image is decoded no wider than `width` points.
    func render(width: CGFloat) -> Result<BlockPicture, RenderFailure> {
        Result { () throws(RenderFailure) in
            switch kind {
            case .mermaid:
                let drawing = try mermaidDrawing(source, colors: colors!, font: labelFamily, size: labelSize)
                return BlockPicture(art: .drawing(drawing), size: drawing.size)
            case .math:
                let drawing = try mathDrawing(source, size: 20, color: colors!.ink)
                return BlockPicture(art: .drawing(drawing), size: drawing.size)
            case .frontMatter:
                throw RenderFailure("front matter folds without a picture")
            case .image:
                guard !source.isEmpty else { throw RenderFailure("the note is not saved in a folder yet") }
                // Only a regular file: a pipe would hold the render queue forever.
                let url = URL(fileURLWithPath: source).resolvingSymlinksInPath()
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                    let file = CGImageSourceCreateWithURL(url as CFURL, nil),
                    let properties = CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any],
                    let pixels = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                    pixels > 0
                else { throw RenderFailure("there is no image this Mac can read at \(source)") }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(pixels, height) * min(Int(width * scale), pixels) / pixels,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(file, 0, options as CFDictionary) else {
                    throw RenderFailure("the image at \(source) cannot be decoded")
                }
                return BlockPicture(art: .image(image), size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
            }
        }
    }
}
