import AppKit
import MdCore

/// Welcome.md: the bundled guide, written once into Dewline's own folder in Application Support, where it is a note
/// like any other.
@MainActor
enum Welcome {
    /// True once the first launch wrote the guide and opened it.
    static let shownKey = "DewlineWelcomeShown"
    /// The demo's two edits: the words before the link it replaces, and the paragraph it inserts after the one that
    /// says what Keep and Revert do.
    static let replaced = "Try it:"
    static let replacement = "Here it is, written from outside the editor:"
    static let anchor = "Revert puts the old text back.\n"
    static let inserted = "\nThis paragraph arrived the way an agent\u{2019}s edit does: written to the file while the note was open.\n"

    static var bundled: URL {
        Bundle.main.url(forResource: "Welcome", withExtension: "md")!
    }

    /// Dewline's own folder, which holds its snapshots too.
    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "dev.arkwerx.dewline", directoryHint: .isDirectory)
    }

    static func url(in folder: URL = folder) -> URL {
        folder.appending(path: "Welcome.md")
    }

    /// Writes the bundled guide into `folder` unless a Welcome.md is already there; true when it wrote one.
    @discardableResult
    static func write(in folder: URL = folder) throws -> Bool {
        let url = url(in: folder)
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(contentsOf: bundled).write(to: url, options: .withoutOverwriting)
        return true
    }
}

/// "Show me a change" in Welcome.md: the demo writer rewrites the words before the link and inserts a paragraph below
/// it through the change engine, claimed as an agent's hooks claim a write, so two changes land marked with Keep and
/// Revert where the reader is looking.
@MainActor
final class WelcomeDemo {
    private static var running: WelcomeDemo?

    private weak var document: MarkdownDocument?
    private let url: URL
    private var start: Task<Void, Never>?

    private init(_ document: MarkdownDocument, url: URL) {
        self.document = document
        self.url = url
    }

    static func play(_ document: MarkdownDocument, at url: URL) {
        running?.stop()
        let demo = WelcomeDemo(document, url: url)
        running = demo
        demo.start = Task { [weak demo] in
            // Long enough to see the paragraph change after the click.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            demo?.write()
            if running === demo { running = nil }
        }
    }

    private func stop() {
        start?.cancel()
        if Self.running === self { Self.running = nil }
    }

    /// The demo's claimed write: PreToolUse with the bytes it declares, the write, PostToolUse, then the turn's end.
    private func write() {
        guard let engine = document?.live?.engine, let before = try? Data(contentsOf: url),
            let real = realpath(url.path, nil)
        else { return }
        let path = String(cString: real)
        free(real)
        let text = String(decoding: before, as: UTF8.self)
        guard let replaced = text.range(of: Welcome.replaced), let anchor = text.range(of: Welcome.anchor), replaced.upperBound <= anchor.lowerBound,
            !text.contains(Welcome.inserted)
        else { return }
        let edited = text[..<replaced.lowerBound] + Welcome.replacement + text[replaced.upperBound..<anchor.upperBound] + Welcome.inserted
            + text[anchor.upperBound...]
        let after = Data(edited.utf8)
        let id = UUID().uuidString
        func claim(_ event: ControlSocket.Claim.Event) {
            LiveFile.claim(ControlSocket.Claim(vendor: .demo, session: "welcome", event: event), engine: engine)
        }
        claim(.preToolUse(.init(id: id, tool: .write, path: path, hash: Self.hex(before), declared: Self.hex(after))))
        guard (try? after.write(to: url)) != nil else { return }
        claim(.postToolUse(.init(id: id, tool: .write, path: path, hash: Self.hex(after), declared: nil)))
        claim(.turnEnd)
    }

    private static func hex(_ data: Data) -> String {
        contentHash(data).map { String(format: "%02x", $0) }.joined()
    }
}
