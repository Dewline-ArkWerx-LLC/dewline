import AppKit
import MdCore

/// `dewline://open?path=…&line=…` and `dewline://demo`, Welcome.md's link. `open` shows only a Markdown file inside the
/// home folder, never inside ~/Library or a `.ssh` folder. `demo` makes its two edits to Welcome.md in Dewline's
/// own folder. Nothing else a link names is read or written; `dewline export` reaches the app through the control socket.
@MainActor
enum SchemeLinks {
    static func handle(_ url: URL) {
        do {
            try run(url)
        } catch {
            NSApp.presentError(error)
        }
    }

    static func run(_ url: URL) throws {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        switch url.host() {
        case "open":
            guard let path = value("path"), !path.isEmpty else { throw Refused("This link doesn\u{2019}t say which note to open.") }
            let file = URL(fileURLWithPath: try jailedPath((path as NSString).expandingTildeInPath))
            guard FolderEntry.markdownExtensions.contains(file.pathExtension.lowercased()) else {
                throw Refused("\(file.path): a link opens only Markdown notes")
            }
            let line = value("line").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
            guard let delegate = NSApp.delegate as? AppDelegate else { return }
            try delegate.show(file, line: line, column: nil)
        case "demo":
            (NSApp.delegate as? AppDelegate)?.playDemo(at: Welcome.url())
        default:
            throw Refused("Dewline can\u{2019}t open this kind of link.")
        }
    }
}
