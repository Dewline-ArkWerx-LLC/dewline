import AppKit
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import Dewline

@MainActor
struct ExportTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dewline-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func exportWritesAPagedPDFWithoutShowingAWindow() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = "# Report\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n\n<script>document.title = 'ran'</script>\n\n"
            + (1...120).map { "Paragraph \($0) of the long export." }.joined(separator: "\n\n")
        let url = folder.appending(path: "report.pdf")
        try await Export.write(text, title: "Report", as: .pdf, to: url, folder: folder)
        let data = try Data(contentsOf: url)
        #expect(data.starts(with: Data("%PDF".utf8)))
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount > 1)
        #expect(pdf.string?.contains("Paragraph 120") == true)
        #expect(NSApp.windows.allSatisfy { !$0.isVisible })

        let html = folder.appending(path: "report.html")
        try await Export.write(text, title: "Report", as: .html, to: html, folder: folder)
        let page = try String(contentsOf: html, encoding: .utf8)
        #expect(page.contains("<table>") && page.contains("&lt;script&gt;") && !page.contains("<script>"))
    }

    @Test func pdfPrintsTheLightPaletteAndHTMLCarriesBoth() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        func paper(_ name: NSAppearance.Name) -> NSColor {
            var color = NSColor.clear
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                color = ThemeStore.shared.color(.paper).usingColorSpace(.sRGB)!
            }
            return color
        }
        func hex(_ color: NSColor) -> String {
            String(format: "#%02x%02x%02x", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
        }
        let (light, dark) = (paper(.aqua), paper(.darkAqua))
        #expect(hex(light) != hex(dark))
        let saved = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        defer { NSApp.appearance = saved }

        let url = folder.appending(path: "a.pdf")
        try await Export.write("# Title\n\nText.", title: "a", as: .pdf, to: url, folder: nil)
        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        let image = page.thumbnail(of: NSSize(width: 100, height: 130), for: .mediaBox)
        let tiff = try #require(image.tiffRepresentation)
        let corner = try #require(NSBitmapImageRep(data: tiff)?.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
        #expect(abs(corner.redComponent - light.redComponent) + abs(corner.greenComponent - light.greenComponent) + abs(corner.blueComponent - light.blueComponent) < 0.06)

        let html = folder.appending(path: "a.html")
        try await Export.write("# Title", title: "a", as: .html, to: html, folder: nil)
        let css = try String(contentsOf: html, encoding: .utf8)
        let media = try #require(css.range(of: "@media (prefers-color-scheme: dark)"))
        #expect(css[..<media.lowerBound].contains("--paper: \(hex(light))"))
        #expect(css[media.upperBound...].contains("--paper: \(hex(dark))"))
    }

    private let sample = """
        # Report

        Some **bold** text with $x^2$ and a [link](https://x.dev).

        - one
        - two

        - [x] done

        | Name | Qty |
        |:--|--:|
        | apple | 3 |
        | kiwi | 120 |

        ![a dot](dot.png)

        ```mermaid
        flowchart LR
          A --> B
        ```

        """

    @Test func plainTextKeepsBulletsAndAlignsTables() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "report.txt")
        try await Export.write(sample, title: "report", as: .text, to: url, folder: folder)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("Report\n\nSome bold text with x^2 and a link (https://x.dev).\n\n• one\n• two\n"))
        #expect(text.contains("Name   Qty\n-----  ---\napple    3\nkiwi   120\n"))
        #expect(text.contains("[image: a dot]") && text.contains("    flowchart LR\n"))
    }

    /// Rich text and OpenDocument carry headings as sized paragraphs, lists, tables and links; diagrams and math keep
    /// their source and an image its alt text, in faces other Macs have.
    @Test func richTextAndOpenDocumentHoldListsTablesAndText() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let rtf = folder.appending(path: "report.rtf")
        try await Export.write(sample, title: "report", as: .rtf, to: rtf, folder: folder)
        let raw = try String(contentsOf: rtf, encoding: .ascii)
        #expect(raw.hasPrefix("{\\rtf1") && !raw.contains("\\f0\\fnil\\fcharset0 ."))
        for (url, type) in [(rtf, NSAttributedString.DocumentType.rtf), (folder.appending(path: "report.odt"), .openDocument)] {
            if type == .openDocument {
                try await Export.write(sample, title: "report", as: .odt, to: url, folder: folder)
                let zip = try Data(contentsOf: url)
                #expect(zip.starts(with: Data([0x50, 0x4B, 0x03, 0x04])) && zip[30..<38] == Data("mimetype".utf8))
                #expect(zip.range(of: Data("application/vnd.oasis.opendocument.text".utf8)) != nil)
            }
            let string = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
            let text = string.string
            #expect(text.contains("Report") && text.contains("x^2") && text.contains("flowchart LR") && text.contains("[image: a dot]"), "\(type)")
            #expect(text.contains("\u{2611}") && text.contains("kiwi"), "\(type)")
            let style = string.attribute(.paragraphStyle, at: (text as NSString).range(of: "kiwi").location, effectiveRange: nil) as? NSParagraphStyle
            #expect(style?.textBlocks.contains { $0 is NSTextTableBlock } == true, "\(type)")
            let item = string.attribute(.paragraphStyle, at: (text as NSString).range(of: "two").location, effectiveRange: nil) as? NSParagraphStyle
            #expect(item?.textLists.isEmpty == false, "\(type)")
            let heading = string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            let body = string.attribute(.font, at: (text as NSString).range(of: "Some").location, effectiveRange: nil) as? NSFont
            #expect((heading?.pointSize ?? 0) > (body?.pointSize ?? 0), "\(type)")
        }
    }

    /// The PNG is the PDF's page at two pixels per CSS pixel; a note taller than the limit is refused, not cut.
    @Test func pngIsOneTallPageAtTwiceTheSize() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "report.png")
        try await Export.write(sample, title: "report", as: .png, to: url, folder: folder)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == Int((NSPrintInfo.shared.paperSize.width / 0.75 * 2).rounded(.up)))
        #expect(image.height > 400 && image.height <= 16_384)

        let long = (1...400).map { "Paragraph \($0) of the long export." }.joined(separator: "\n\n")
        let refused = folder.appending(path: "long.png")
        await #expect(throws: Export.Failure.self) {
            try await Export.write(long, title: "long", as: .png, to: refused, folder: folder)
        }
        #expect(!FileManager.default.fileExists(atPath: refused.path))
    }

    /// The EPUB is a zip whose first entry is its uncompressed mimetype, with the diagram as an SVG file in the book.
    @Test func epubPackagesTheChapterAndItsDiagram() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "report.epub")
        try await Export.write(sample, title: "report", as: .epub, to: url, folder: folder)
        let book = try Data(contentsOf: url)
        #expect(book.starts(with: Data([0x50, 0x4B, 0x03, 0x04])) && book[30..<58] == Data("mimetypeapplication/epub+zip".utf8))
        for name in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/chapter.xhtml", "OEBPS/images/diagram-2.svg"] {
            #expect(book.range(of: Data(name.utf8)) != nil, "\(name)")
        }
        #expect(book.range(of: Data("<dc:title>Report</dc:title>".utf8)) != nil)
    }

    /// LaTeX writes the article and a folder beside it with the diagram and the image, and refuses a folder that is a
    /// symbolic link.
    @Test func latexWritesItsFiguresBesideTheArticle() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2]).write(to: folder.appending(path: "dot.png"))
        let url = folder.appending(path: "report.tex")
        try await Export.write(sample, title: "report", as: .latex, to: url, folder: folder)
        let tex = try String(contentsOf: url, encoding: .utf8)
        #expect(tex.contains("\\title{Report}") && tex.contains("$x^2$") && tex.contains("\\begin{tabular}{lr}"))
        #expect(tex.contains("\\includegraphics[width=\\maxwidth]{report-files/image-1.png}"))
        #expect(tex.contains("\\includegraphics[width=\\maxwidth]{report-files/diagram-2.png}"))
        let diagram = try Data(contentsOf: folder.appending(path: "report-files/diagram-2.png"))
        #expect(diagram.starts(with: Data([0x89, 0x50, 0x4E, 0x47])))

        let elsewhere = try self.folder()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "linked-files"), withDestinationURL: elsewhere)
        await #expect(throws: Export.Failure.self) {
            try await Export.write(sample, title: "linked", as: .latex, to: folder.appending(path: "linked.tex"), folder: folder)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }
}
