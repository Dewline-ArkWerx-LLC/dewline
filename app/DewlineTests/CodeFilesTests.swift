import AppKit
import MdCore
import Testing
@testable import Dewline

/// Source and config files, which open as highlighted code.
@MainActor @Suite(.serialized)
struct CodeFilesTests {
    private static let python = "import os\n\n# Not a heading\ndef main(**kwargs):\n    if kwargs:\n        print(\"*a* _b_\")\n"
        + "long = '\(String(repeating: "a", count: 400))'\n"

    @Test func codeFilesListAndOpenInCodeMode() async throws {
        let folder = try Folder(Self.files(["notes.md": "# Notes\n", "main.py": Self.python, "Dockerfile": "FROM swift\n", "photo.png": ""]))
        defer { try? FileManager.default.removeItem(at: folder.url) }
        // Quick Open and Find in Files list every file the sidebar opens: notes and code, not the picture.
        #expect(Self.quickOpenNames(folder) == ["Dockerfile", "main.py", "notes.md"])
        #expect(folder.children(of: folder.url).entries.filter(\.opens).map(\.url.lastPathComponent) == ["Dockerfile", "main.py", "notes.md"])

        let controller = MainWindowController(folder: folder)
        defer { (controller.document as? NSDocument)?.close() }
        controller.open(folder.url.appending(path: "main.py"), newTab: false)
        let textView = try #require(controller.textView)
        #expect(textView.string == Self.python)
        #expect(textView.styler.code == "py")
        // No Markdown: no blocks, so no heading, emphasis or hidden marker.
        let whole = NSRange(location: 0, length: (textView.string as NSString).length)
        #expect(textView.styler.map.blocks(in: whole).isEmpty)
        let storage = try #require(textView.textStorage)
        storage.enumerateAttribute(.font, in: whole) { value, _, _ in
            let font = value as? NSFont
            #expect(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
            #expect(font?.familyName == NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).familyName)
        }
        storage.enumerateAttribute(.foregroundColor, in: whole) { value, _, _ in
            #expect(value as? NSColor != NSColor.clear)
        }
        // Lines don't wrap, the view scrolls sideways, and each line has a number.
        #expect(textView.textContainer?.widthTracksTextView == false)
        #expect(textView.isHorizontallyResizable)
        #expect(textView.enclosingScrollView?.hasHorizontalScroller == true)
        let numbers = try #require(textView.enclosingScrollView?.verticalRulerView as? LineNumbers)
        #expect(textView.enclosingScrollView?.rulersVisible == true)
        #expect(numbers.lineStarts() == [0, 10, 11, 27, 47, 62, 87, 497])
        #expect(!textView.isAutomaticQuoteSubstitutionEnabled && !textView.isContinuousSpellCheckingEnabled)
        // The whole file is highlighted: "import" takes the keyword color.
        let layout = try #require(textView.textLayoutManager)
        // Compared by resolved value: a ThemeStore change, from a suite running beside this one, rebuilds the store's
        // dynamic colors as new objects, so a color held across the wait would never equal the one painted after it.
        func resolved(_ color: NSColor?) -> NSColor? {
            var result: NSColor?
            textView.effectiveAppearance.performAsCurrentDrawingAppearance { result = color?.usingColorSpace(.sRGB) }
            return result
        }
        let area = NSRect(x: 0, y: 0, width: 600, height: 300)
        let bitmap = try #require(textView.bitmapImageRepForCachingDisplay(in: area))
        try await Self.until {
            layout.ensureLayout(for: layout.documentRange)
            // Colors are set when a line is drawn, and a window that is not on screen never draws: draw into a bitmap.
            textView.cacheDisplay(in: area, to: bitmap)
            var color: NSColor?
            layout.enumerateRenderingAttributes(from: layout.documentRange.location, reverse: false) { _, attributes, _ in
                color = attributes[.foregroundColor] as? NSColor
                return false
            }
            return resolved(color) == resolved(ThemeStore.shared.color(.codeKeyword))
        }
        // The 400-character line widens the view past the clip view, and no further than the text.
        let clip = try #require(textView.enclosingScrollView?.contentView.bounds.width)
        #expect(textView.frame.width > clip)
        #expect(textView.frame.width < 10_000)
        // Tab inserts the file's four spaces.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertTab(nil)
        #expect(textView.string.hasPrefix("    import os"))

        // File > Open's way in takes a file Launch Services has no type for.
        let dockerfile = folder.url.appending(path: "Dockerfile")
        let (document, error) = await Self.openDocument(dockerfile)
        defer { document?.close() }
        #expect(error == nil)
        #expect(document?.fileType == MarkdownDocument.type)
        #expect(CodeFile.language(of: dockerfile) == "dockerfile")
    }

    /// A Typst source opens as code, and its first line is drawn: the line numbers paint paper in their own strip only,
    /// not over the text beside it.
    @Test func aTypstSourceDrawsItsFirstLine() async throws {
        let folder = try Folder(Self.files(["brief.typ": "#set page(width: 10cm)\n= Brief\n\nThe queue retries #n times.\n"]))
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let controller = MainWindowController(folder: folder)
        defer { (controller.document as? NSDocument)?.close() }
        controller.open(folder.url.appending(path: "brief.typ"), newTab: false)
        let textView = try #require(controller.textView)
        #expect(textView.styler.code == "typ")
        let scrollView = try #require(textView.enclosingScrollView)
        let layout = try #require(textView.textLayoutManager)
        var first: NSTextLayoutFragment?
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            first = fragment
            return false
        }
        let fragment = try #require(first)
        let line = try #require(fragment.textLineFragments.first)
        #expect(line.attributedString.string.hasPrefix("#set page(width: 10cm)"))

        // The scroll view as the window draws it, line numbers and all: the first line's glyphs show.
        scrollView.layoutSubtreeIfNeeded()
        let bitmap = try #require(scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds))
        scrollView.cacheDisplay(in: scrollView.bounds, to: bitmap)
        let origin = textView.textContainerOrigin
        let glyphs = NSRect(origin: NSPoint(x: fragment.layoutFragmentFrame.minX + origin.x, y: fragment.layoutFragmentFrame.minY + origin.y), size: line.typographicBounds.size)
        var rect = scrollView.convert(glyphs, from: textView)
        if !scrollView.isFlipped { rect.origin.y = scrollView.bounds.height - rect.maxY }
        let scale = CGFloat(bitmap.pixelsWide) / scrollView.bounds.width
        var colors = Set<String>()
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
            for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
                if let color = bitmap.colorAt(x: x, y: y) { colors.insert(color.description) }
            }
        }
        #expect(colors.count > 1)
    }

    @Test func indentationFollowsTheFile() {
        #expect(CodeFile.indentation(of: "func main() {\n\tif x {\n\t\ty()\n\t}\n}\n") == "\t")
        #expect(CodeFile.indentation(of: "a:\n  b:\n    c: 1\n  d: 2\n") == "  ")
        #expect(CodeFile.indentation(of: Self.python) == "    ")
        #expect(CodeFile.indentation(of: "x = 1\n") == nil)
    }

    @Test func aCodeFileRoundTripsByteIdentical() async throws {
        // A byte-order mark, CRLF and CR breaks, a tab, non-ASCII and no final line break.
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("fn main() {\r\n\tlet s = \"é 😀\";\r}\r\n// end".utf8)
        let file = try EngineFile("main.rs", bytes)
        defer { file.close() }
        #expect(file.textView.styler.code == "rs")
        let numbers = try #require(file.textView.enclosingScrollView?.verticalRulerView as? LineNumbers)
        #expect(numbers.lineStarts() == [0, 13, 30, 33])
        try await file.save()
        #expect(try Data(contentsOf: file.url) == bytes)
        file.textView.insertText("x", replacementRange: NSRange(location: 3, length: 0))
        file.textView.insertText("", replacementRange: NSRange(location: 3, length: 1))
        try await file.save()
        #expect(try Data(contentsOf: file.url) == bytes)
    }

    @Test func anOutsideWriteToAnOpenPythonFileIsMarked() async throws {
        let file = try EngineFile("main.py", Data(Self.python.utf8))
        defer { file.close() }
        #expect(file.textView.styler.code == "py")
        let after = Self.python + "\nmain()\n"
        try Data(after.utf8).write(to: file.url)
        await file.live.refresh()
        #expect(file.textView.string == after)
        let (id, change) = try #require(file.live.changes.first { $0.value.marked })
        #expect(change.origin == .external)
        #expect((file.textView.string as NSString).substring(with: change.range).contains("main()"))
        file.textView.marks.relayout()
        #expect(file.textView.marks.painted[id] == change.range)
        // Reviewed at the change: Keep clears the mark and leaves the text.
        file.textView.setSelectedRange(NSRange(location: change.range.location + 1, length: 0))
        file.textView.keepChange(nil)
        #expect(file.live.changes[id] == nil)
        #expect(file.textView.string == after)
    }

    @Test func typesetJobsRunWithoutShellEscapeOrOutsidePaths() throws {
        let (tex, root, build) = (URL(filePath: "/p/doc/a.tex"), URL(filePath: "/p"), URL(filePath: "/c/build"))
        let latexmk = try #require(Typeset.job(tex, root: root, build: build) { "/bin/\($0)" })
        #expect(latexmk.program == "/bin/latexmk")
        #expect(latexmk.arguments == [
            "-norc", "-bibtex-", "-e", "$makeindex = 'NONE'", "-pdf", "-pdflatex=pdflatex -no-shell-escape %O %S", "-xelatex=xelatex -no-shell-escape %O %S",
            "-lualatex=lualatex -no-shell-escape --safer --nosocket %O %S", "-interaction=nonstopmode", "-file-line-error", "-outdir=/c/build",
            "./a.tex",
        ])
        #expect(latexmk.folder.path == "/p/doc")
        #expect(latexmk.environment == ["openin_any": "p", "openout_any": "p", "TEXMFOUTPUT": "/c/build"])
        let tectonic = try #require(Typeset.job(tex, root: root, build: build) { $0 == "tectonic" ? "/bin/tectonic" : nil })
        #expect(tectonic.arguments == ["-X", "compile", "--untrusted", "--keep-logs", "--outdir", "/c/build", "a.tex"])
        let typst = try #require(Typeset.job(URL(filePath: "/p/doc/a.typ"), root: root, build: build) { "/bin/\($0)" })
        #expect(typst.arguments == ["compile", "--root", "/p", "--diagnostic-format", "short", "/p/doc/a.typ", "/c/build/a.pdf"])
        #expect(Typeset.job(tex, root: root, build: build) { _ in nil } == nil)
    }

    @Test func latexmkTakesOnlyPlainFileNames() {
        #expect(Typeset.plain("ok name.tex"))
        #expect(Typeset.plain("a-b_c.1.tex"))
        for name in ["$(id).tex", "a`b`.tex", "-shell-escape.tex", "a;b.tex", "a\"b.tex", ""] {
            #expect(!Typeset.plain(name), "\(name)")
        }
    }

    @Test func typesetJobsRunSandboxedWithPathsAsParameters() throws {
        let (root, build) = (URL(filePath: "/p"), URL(filePath: "/c/build"))
        let latexmk = Typeset.Job(program: "/bin/latexmk", arguments: ["-norc", "./a.tex"], folder: root, environment: ["openin_any": "p"])
        let file = URL(filePath: "/p/doc/a.tex")
        let sandboxed = Typeset.sandboxed(latexmk, file: file, root: root, build: build)
        #expect(sandboxed.program == "/usr/bin/sandbox-exec")
        #expect(sandboxed.folder == root && sandboxed.environment == ["openin_any": "p", "TMPDIR": "/c/build/tmp"])
        #expect(Array(sandboxed.arguments.suffix(3)) == ["/bin/latexmk", "-norc", "./a.tex"])
        #expect(sandboxed.arguments.contains("ROOT=/p") && sandboxed.arguments.contains("BUILD=/c/build"))
        let profile = try #require(sandboxed.arguments.first == "-p" ? sandboxed.arguments[1] : nil)
        #expect(!profile.contains("/p\"") && !profile.contains(NSHomeDirectory()))
        #expect(profile.contains("(deny file-read* file-write* network* process-exec appleevent-send)") && !profile.contains("network-outbound"))
        let typst = Typeset.sandboxed(.init(program: "/bin/typst", arguments: [], folder: root, environment: [:]), file: file, root: root, build: build)
        #expect(typst.arguments[1].contains("(allow network-outbound"))
        // A root at or above home narrows to the file's folder, or the file itself when that folder is home.
        let home = URL(filePath: NSHomeDirectory())
        #expect(Typeset.sandboxed(latexmk, file: file, root: URL(filePath: "/"), build: build).arguments.contains("ROOT=/p/doc"))
        let away = home.appending(path: "dewline-\(UUID().uuidString)/a.tex")
        #expect(Typeset.sandboxed(latexmk, file: away, root: home, build: build).arguments.contains("ROOT=" + away.deletingLastPathComponent().path))
        let loose = home.appending(path: "dewline-\(UUID().uuidString).tex")
        #expect(Typeset.sandboxed(latexmk, file: loose, root: home, build: build).arguments.contains("ROOT=" + loose.path))
    }

    @Test func aSandboxedJobCantReadThroughALinkOutOfTheFolder() throws {
        let folder = try Self.files(["inside.txt": "inside"])
        let outside = URL(filePath: "/private/tmp/dewline-outside-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "link.txt"), withDestinationURL: outside)
        func cat(_ name: String) throws -> (Int32, String) {
            let job = Typeset.sandboxed(.init(program: "/bin/cat", arguments: [name], folder: folder, environment: [:]), file: folder.appending(path: name), root: folder, build: folder)
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(filePath: job.program)
            process.arguments = job.arguments
            process.currentDirectoryURL = job.folder
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, output)
        }
        let (read, inside) = try cat("inside.txt")
        #expect(read == 0 && inside == "inside")
        let (status, output) = try cat("link.txt")
        #expect(status != 0 && output.isEmpty)
    }

    @Test func aTexRootOutsideTheFolderIsRefused() throws {
        let top = try Self.files(["outside.tex": "\\documentclass{article}\n"])
        defer { try? FileManager.default.removeItem(at: top) }
        let folder = top.appending(path: "doc")
        try FileManager.default.createDirectory(at: folder.appending(path: "ch"), withIntermediateDirectories: true)
        let files = ["main.tex": "\\documentclass{article}\n", "ch/one.tex": "% !TEX root = ../main.tex\n", "up.tex": "% !TEX root = ../outside.tex\n", "link.tex": "% !TEX root = linked.tex\n"]
        for (name, text) in files { try Data(text.utf8).write(to: folder.appending(path: name)) }
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "linked.tex"), withDestinationURL: top.appending(path: "outside.tex"))
        let main = folder.appending(path: "main.tex").path
        #expect(Typeset.main(of: folder.appending(path: "main.tex"), in: folder)?.path == main)
        #expect(Typeset.main(of: folder.appending(path: "ch/one.tex"), in: folder)?.path == main)
        #expect(Typeset.main(of: folder.appending(path: "up.tex"), in: folder) == nil)
        #expect(Typeset.main(of: folder.appending(path: "link.tex"), in: folder) == nil)
    }

    // MARK: Helpers

    private static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func files(_ files: [String: String]) throws -> URL {
        let root = URL(filePath: NSTemporaryDirectory()).resolvingSymlinksInPath().appending(path: "dewline-code-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: root.appending(path: name)) }
        return root
    }

    private static func quickOpenNames(_ folder: Folder) -> [String] {
        var tree = FileTree(folder)
        tree.relist(nil)
        return tree.files.map(\.url.lastPathComponent).sorted()
    }

    /// File > Open's way in, through the app's document controller, without showing a window.
    private static func openDocument(_ url: URL) async -> (MarkdownDocument?, (any Error)?) {
        await withCheckedContinuation { continuation in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { document, _, error in
                continuation.resume(returning: (document as? MarkdownDocument, error))
            }
        }
    }

    /// A code file the change engine opens, in a window never shown.
    @MainActor private struct EngineFile {
        let folder: URL
        let url: URL
        let document: MarkdownDocument
        let textView: EditorTextView
        let live: LiveFile

        init(_ name: String, _ bytes: Data) throws {
            folder = URL(filePath: NSTemporaryDirectory()).resolvingSymlinksInPath().appending(path: "dewline-code-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder.appending(path: "files"), withIntermediateDirectories: true)
            url = folder.appending(path: "files/\(name)")
            try bytes.write(to: url)
            document = MarkdownDocument()
            document.engine = try ChangeEngine(store: folder.appending(path: "snapshots"))
            try document.read(from: url, ofType: MarkdownDocument.type)
            document.fileURL = url
            document.makeWindowControllers()
            textView = try #require(document.textView)
            live = try #require(document.live)
        }

        /// Cmd-S.
        func save() async throws {
            let error: (any Error)? = await withCheckedContinuation { continuation in
                document.save(to: url, ofType: MarkdownDocument.type, for: .saveOperation) { continuation.resume(returning: $0) }
            }
            if let error { throw error }
        }

        func close() {
            document.close()
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
