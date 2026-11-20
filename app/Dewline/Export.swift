import AppKit
import MdCore
import PDFKit
import UniformTypeIdentifiers
import WebKit

/// A document as a standalone HTML page, a paged PDF, an EPUB book or one tall PNG in the current theme, or as a Word,
/// rich text, OpenDocument, LaTeX, portable Markdown or plain text file: the PDF, book and PNG in the light palette, as
/// paper is, and the HTML in both, switched by the reader's appearance. LaTeX and Markdown write their diagrams and
/// images into a folder beside them. The source file is never read
/// or written: the page comes from the text passed in, and images inline from the document's folder.
@MainActor
enum Export {
    enum Format: Int, CaseIterable {
        /// The raw values are stored in the defaults; the order is the Format menu's.
        case pdf = 1, docx = 2, html = 0, rtf = 4, odt = 5, epub = 7, latex = 8, markdown = 9, text = 3, png = 6

        var fileExtension: String {
            switch self {
            case .html: "html"
            case .pdf: "pdf"
            case .docx: "docx"
            case .rtf: "rtf"
            case .odt: "odt"
            case .epub: "epub"
            case .latex: "tex"
            case .markdown: "md"
            case .text: "txt"
            case .png: "png"
            }
        }

        var type: UTType {
            UTType(filenameExtension: fileExtension) ?? .data
        }

        var name: String {
            switch self {
            case .html: "HTML"
            case .pdf: "PDF"
            case .docx: "Word"
            case .rtf: "Rich Text"
            case .odt: "OpenDocument"
            case .epub: "EPUB"
            case .latex: "LaTeX"
            case .markdown: "Markdown (portable)"
            case .text: "Plain Text"
            case .png: "PNG Image"
            }
        }
    }

    /// The app's code syntaxes, which color fenced code in a page.
    private static let syntaxes = Bundle.main.url(forResource: "Syntaxes", withExtension: "packdump")

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// One appearance's colors: CSS custom properties, the diagram colors and the paper.
    @MainActor
    private struct Palette {
        let properties: String
        let colors: DiagramColors
        let paper: NSColor

        init(_ name: NSAppearance.Name) {
            var palette: (String, DiagramColors, NSColor)?
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let tokens: [Token] = [.paper, .ink, .ink2, .heading, .link, .codeBackground, .quoteRule, .syntax]
                palette = (
                    tokens.map { "--\($0.rawValue): \(String(format: "#%08x", Export.rgba($0)));" }.joined(separator: " "),
                    DiagramColors(
                        paper: Export.rgba(.paper), ink: Export.rgba(.ink), ink2: Export.rgba(.ink2), accent: Export.rgba(.accent),
                        fill: Export.rgba(.codeBackground)
                    ),
                    ThemeStore.shared.color(.paper).usingColorSpace(.sRGB)!
                )
            }
            (properties, colors, paper) = palette!
        }
    }

    static func write(_ text: String, title: String, as format: Format, to url: URL, folder: URL?) async throws {
        let data: Data
        switch format {
        case .docx:
            // Without a folder, relative images resolve in an empty one and keep their alt text.
            data = try exportWordDocument(text, folder: folder ?? URL(filePath: "/var/empty", directoryHint: .isDirectory))
        case .text:
            data = Data(try exportPlainText(text).utf8)
        case .rtf, .odt:
            data = try richText(text, title: title, as: format == .rtf ? .rtf : .openDocument)
        case .epub:
            let light = Palette(.aqua)
            data = try exportEPUB(
                text, title: title, css: stylesheet(light: light, dark: nil), folder: folder, colors: light.colors, mathSize: ThemeStore.shared.bodySize
            )
        case .latex:
            let article = try exportLaTeX(text, name: url.deletingPathExtension().lastPathComponent, folder: folder, colors: Palette(.aqua).colors)
            try write(article.files, beside: url)
            data = Data(article.tex.utf8)
        case .markdown:
            let copy = try exportPortableMarkdown(text, name: url.deletingPathExtension().lastPathComponent, folder: folder)
            try write(copy.files, beside: url)
            data = Data(copy.text.utf8)
        case .html, .pdf, .png:
            let light = Palette(.aqua)
            let dark = format == .html ? Palette(.darkAqua) : nil
            let page = try exportPage(
                text, title: title, css: stylesheet(light: light, dark: dark), folder: folder, colors: light.colors, dark: dark?.colors,
                mathSize: ThemeStore.shared.bodySize, syntaxes: syntaxes
            )
            switch format {
            case .html: data = Data(page.utf8)
            case .pdf: data = try await PageRenderer().pdf(of: page, paper: light.paper)
            default: data = try await PageRenderer().png(of: page, paper: light.paper)
            }
        }
        try data.write(to: url, options: .atomic)
    }

    /// Writes each file at its path relative to `url`'s folder, making the folders on the way and refusing one that is a
    /// symbolic link or a file.
    private static func write(_ files: [(path: String, data: Data)], beside url: URL) throws {
        for file in files {
            var folder = url.deletingLastPathComponent()
            for part in file.path.split(separator: "/").dropLast() {
                folder.append(path: String(part), directoryHint: .isDirectory)
                var info = stat()
                if lstat(folder.path, &info) != 0 {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                } else if info.st_mode & S_IFMT != S_IFDIR {
                    throw Failure(errorDescription: "\u{201C}\(folder.lastPathComponent)\u{201D} beside the export isn\u{2019}t a folder.")
                }
            }
            try file.data.write(to: folder.appending(path: (file.path as NSString).lastPathComponent), options: .atomic)
        }
    }

    /// The page with diagrams and math as their source, task boxes as ballot boxes and images as their alt text, read
    /// by AppKit's HTML reader in the editor's faces, the system's named as faces every Mac has.
    private static func richText(_ text: String, title: String, as type: NSAttributedString.DocumentType) throws -> Data {
        let store = ThemeStore.shared
        let named = ["New York": "Georgia", "SF Pro": "Helvetica Neue", "SF Pro Rounded": "Helvetica Neue", "SF Mono": "Menlo"]
        func face(_ name: String, _ generic: String) -> String { family(named[name] ?? name, generic) }
        let css = """
        body { font-family: \(face(store.bodyFace, "serif")); font-size: \(store.bodySize)px; }
        h1, h2, h3, h4, h5, h6 { font-family: \(face(store.headingFace, "serif")); }
        code, pre { font-family: \(face(store.codeFace, "monospace")); }
        """
        let page = try previewPage(text, title: title, css: css, syntaxes: syntaxes)
            .replacing("<input type=\"checkbox\" disabled checked>", with: "\u{2611}")
            .replacing("<input type=\"checkbox\" disabled>", with: "\u{2610}")
            .replacing(/<img [^>]*?alt="([^"]*)"[^>]*>/) { $0.1.isEmpty ? "[image]" : "[image: \($0.1)]" }
        let string = try NSAttributedString(
            data: Data(page.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        )
        return try string.data(from: NSRange(location: 0, length: string.length), documentAttributes: [.documentType: type])
    }

    /// `text` as the body of an HTML page, for the pasteboard: diagrams and math in the light palette, images at their
    /// paths.
    static func fragment(_ text: String) -> String {
        let page = (try? exportPage(
            text, title: "", css: "", folder: nil, colors: Palette(.aqua).colors, dark: nil, mathSize: ThemeStore.shared.bodySize,
            syntaxes: nil
        )) ?? ""
        guard let start = page.range(of: "<body>\n"), let end = page.range(of: "</body>", options: .backwards) else { return page }
        return String(page[start.upperBound..<end.lowerBound])
    }

    /// Keeps the HTML page's stylesheet, in both palettes, in the app group's defaults for the Quick Look preview,
    /// whose sandbox can't read the app's settings.
    static func publishPreviewStylesheet() {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "DewlineAppGroup") as? String else { return }
        UserDefaults(suiteName: group)?.set(stylesheet(light: Palette(.aqua), dark: Palette(.darkAqua)), forKey: "PreviewStylesheet")
    }

    private static func rgba(_ token: Token) -> UInt32 {
        let color = ThemeStore.shared.color(token).usingColorSpace(.sRGB)!
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            .reduce(0) { $0 << 8 | UInt32(($1 * 255).rounded()) }
    }

    private static func family(_ face: String, _ generic: String) -> String {
        let system = ["New York": "ui-serif", "SF Pro": "system-ui", "SF Pro Rounded": "ui-rounded", "SF Mono": "ui-monospace"]
        let name = system[face] ?? "\"\(face.filter { !"\"\\;{}<>".contains($0) })\""
        return "\(name), \(generic)"
    }

    /// The editor's faces, and the theme's colors in the light palette, switched to `dark` on a dark page.
    private static func stylesheet(light: Palette, dark: Palette?) -> String {
        let store = ThemeStore.shared
        let scheme = dark.map { "@media (prefers-color-scheme: dark) { :root { \($0.properties) } }\n" } ?? ""
        return """
        :root { color-scheme: \(dark == nil ? "light" : "light dark"); \(light.properties) }
        \(scheme)html { background: var(--paper); }
        body { color: var(--ink); font-family: \(family(store.bodyFace, "serif")); font-size: \(store.bodySize)px; line-height: \(store.lineHeight); max-width: 40em; margin: 0 auto; padding: 2em 3em; }
        h1, h2, h3, h4, h5, h6 { font-family: \(family(store.headingFace, "serif")); color: var(--heading); line-height: 1.25; }
        a { color: var(--link); }
        code, pre { font-family: \(family(store.codeFace, "monospace")); font-size: 0.88em; background: var(--codeBackground); border-radius: 4px; }
        code { padding: 0.1em 0.3em; }
        pre { padding: 0.8em 1em; white-space: pre-wrap; }
        pre code { padding: 0; background: none; font-size: 1em; }
        blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid var(--quoteRule); color: var(--ink2); }
        table { border-collapse: collapse; }
        th, td { border: 1px solid var(--syntax); padding: 0.3em 0.6em; }
        hr { border: 0; border-top: 1px solid var(--syntax); }
        img { max-width: 100%; }
        figure.diagram { margin: 1em 0; }
        figure.diagram svg { max-width: 100%; height: auto; }
        img.math { vertical-align: middle; }
        .math-display { display: block; text-align: center; margin: 1em 0; }
        .footnote-definition { font-size: 0.9em; color: var(--ink2); }
        """
    }

    /// The format File > Export… last wrote, which the panel starts on.
    static let formatKey = "DewlineExportFormat"
    /// The last file written, which the status bar names with Show in Finder.
    private(set) static var lastExport: URL?
    static let didExport = Notification.Name("DewlineDidExport")

    /// File > Export…: the save panel for the window's document with a Format menu, starting on the format last used,
    /// else `format`.
    static func run(for document: MarkdownDocument, text: String, format: Format, in window: NSWindow) {
        let panel = NSSavePanel()
        let title = document.fileURL?.deletingPathExtension().lastPathComponent ?? document.displayName ?? "Untitled"
        let start = (UserDefaults.standard.object(forKey: formatKey) as? Int).flatMap(Format.init) ?? format
        let formats = NSPopUpButton(frame: .zero, pullsDown: false)
        for choice in Format.allCases {
            formats.addItem(withTitle: choice.name)
            formats.lastItem?.tag = choice.rawValue
        }
        formats.selectItem(withTag: start.rawValue)
        formats.sizeToFit()
        let label = NSTextField(labelWithString: "Format:")
        label.textColor = .secondaryLabelColor
        label.sizeToFit()
        // The panel centers its accessory. Its own labels end 93 pt left of the middle and its fields start 85 pt
        // left of it, so Format sits on their columns, with 8 pt above and below.
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: formats.frame.height + 16))
        label.frame.origin = NSPoint(x: 180 - 93 + 2 - label.frame.width, y: 8 + (formats.frame.height - label.frame.height) / 2)
        formats.frame.origin = NSPoint(x: 180 - 85 - 3, y: 8)
        for view in [label, formats] {
            view.autoresizingMask = [.minXMargin, .maxXMargin]
            accessory.addSubview(view)
        }
        panel.accessoryView = accessory
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = title
        panel.allowedContentTypes = [start.type]
        let chooser = PopUpTarget { panel.allowedContentTypes = [(Format(rawValue: $0) ?? .pdf).type] }
        formats.target = chooser
        formats.action = #selector(PopUpTarget.changed(_:))
        let folder = document.fileURL?.deletingLastPathComponent()
        if let folder { panel.directoryURL = folder }
        panel.beginSheetModal(for: window) { response in
            withExtendedLifetime(chooser) {}
            guard response == .OK, let url = panel.url, let format = Format(rawValue: formats.selectedTag()) else { return }
            UserDefaults.standard.set(format.rawValue, forKey: formatKey)
            Task { @MainActor in
                do {
                    if let source = document.fileURL, url.resolvingSymlinksInPath() == source.resolvingSymlinksInPath() {
                        throw replacesSource
                    }
                    try await write(text, title: title, as: format, to: url, folder: folder)
                    exported(url)
                } catch {
                    document.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
                }
            }
        }
    }

    static let replacesSource = Failure(errorDescription: "The export would replace the note itself. Choose another name.")

    /// An export finished: a notice says "Exported “Launch plan.pdf”" with Show in Finder.
    static func exported(_ url: URL) {
        lastExport = url
        NotificationCenter.default.post(name: didExport, object: url)
    }

    /// File > Print…: the note laid out as its PDF export, in the print panel.
    static func print(_ text: String, title: String, folder: URL?, on window: NSWindow) async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try await write(text, title: title, as: .pdf, to: url, folder: folder)
        guard let pdf = PDFDocument(data: try Data(contentsOf: url)), let operation = pdf.printOperation(for: .shared, scalingMode: .pageScaleNone, autoRotate: true) else {
            throw Failure(errorDescription: "The note couldn\u{2019}t be laid out for printing.")
        }
        operation.jobTitle = title
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}

@MainActor
private final class PopUpTarget: NSObject {
    let action: (Int) -> Void

    init(_ action: @escaping (Int) -> Void) {
        self.action = action
    }

    @objc func changed(_ sender: NSPopUpButton) {
        action(sender.selectedTag())
    }
}

/// Lays out one page in a web view that runs no page script, keeps no data and follows no link, as one tall PDF page.
/// `pdf` cuts it into pages of the default paper size, breaking between top-level blocks where one fits; `png` draws it
/// at two pixels per CSS pixel.
@MainActor
private final class PageRenderer: NSObject, WKNavigationDelegate {
    /// CSS pixels to points, as browsers print.
    private static let scale = 0.75
    /// The tallest PNG, in pixels: about nine Letter pages.
    static let maxHeight = 16_384
    private var loaded: CheckedContinuation<Void, any Error>?
    private var navigations = 0

    /// The page as one PDF page as wide as the paper, and the top of each of the body's blocks, in CSS pixels.
    private func layout(_ html: String) async throws -> (page: CGPDFPage, document: CGPDFDocument, tops: [Double]) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let width = NSPrintInfo.shared.paperSize.width / Self.scale
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 1000), configuration: configuration)
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            view.loadHTMLString(html, baseURL: nil)
        }
        let tops = (try? await view.callAsyncJavaScript(
            "return Array.from(document.body.children, e => e.getBoundingClientRect().top + window.scrollY)",
            contentWorld: .defaultClient
        ) as? [Double]) ?? []
        let tall = try await view.pdf()
        guard let document = CGDataProvider(data: tall as CFData).flatMap(CGPDFDocument.init), let page = document.page(at: 1) else {
            throw Export.Failure(errorDescription: "The page couldn’t be laid out as a PDF.")
        }
        return (page, document, tops)
    }

    func pdf(of html: String, paper: NSColor) async throws -> Data {
        let (page, document, tops) = try await layout(html)
        let paperSize = NSPrintInfo.shared.paperSize
        let margin = 54.0
        let box = page.getBoxRect(.mediaBox)
        let capacity = (paperSize.height - 2 * margin) / Self.scale
        var starts = [0.0]
        while box.height - starts.last! > capacity {
            let start = starts.last!
            starts.append(tops.last { $0 > start + 1 && $0 <= start + capacity } ?? start + capacity)
        }
        let out = NSMutableData()
        var media = CGRect(origin: .zero, size: paperSize)
        guard let consumer = CGDataConsumer(data: out), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            throw Export.Failure(errorDescription: "The PDF couldn’t be written.")
        }
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : box.height
            context.beginPDFPage(nil)
            context.setFillColor(paper.usingColorSpace(.sRGB)?.cgColor ?? .white)
            context.fill(media)
            let height = (end - start) * Self.scale
            context.clip(to: CGRect(x: 0, y: paperSize.height - margin - height, width: paperSize.width, height: height))
            context.translateBy(x: 0, y: paperSize.height - margin)
            context.scaleBy(x: Self.scale, y: Self.scale)
            context.translateBy(x: -box.minX, y: start - box.maxY)
            context.drawPDFPage(page)
            context.endPDFPage()
        }
        context.closePDF()
        withExtendedLifetime(document) {}
        return out as Data
    }

    func png(of html: String, paper: NSColor) async throws -> Data {
        let (page, document, _) = try await layout(html)
        let box = page.getBoxRect(.mediaBox)
        let (width, height) = (Int((box.width * 2).rounded(.up)), Int((box.height * 2).rounded(.up)))
        guard height <= Self.maxHeight else {
            throw Export.Failure(errorDescription: "The note is too long for one image: it would be \(height) pixels tall, and a PNG export stops at \(Self.maxHeight). Export it as PDF instead.")
        }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw Export.Failure(errorDescription: "The image couldn’t be drawn.") }
        context.setFillColor(paper.usingColorSpace(.sRGB)?.cgColor ?? .white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: 2, y: 2)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        withExtendedLifetime(document) {}
        let out = NSMutableData()
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw Export.Failure(errorDescription: "The image couldn’t be drawn.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Export.Failure(errorDescription: "The PNG couldn’t be written.") }
        return out as Data
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigations += 1
        return navigations == 1 ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }
}
