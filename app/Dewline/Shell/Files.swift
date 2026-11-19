import AppKit
import MdCore

/// One file or folder in a folder tree.
struct FolderEntry: Equatable {
    let url: URL
    let isFolder: Bool
    /// Ignored by git, and listed only while the sidebar shows what it hides.
    var isIgnored = false

    /// The extensions of net.daringfireball.markdown, as project.yml declares it.
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    /// Cursor rules, MDX and Quarto, which project.yml declares as Markdown dialects.
    static let dialectExtensions: Set<String> = ["mdc", "mdx", "qmd"]

    var isMarkdown: Bool {
        let type = url.pathExtension.lowercased()
        return !isFolder && (Self.markdownExtensions.contains(type) || Self.dialectExtensions.contains(type))
    }

    var isCode: Bool {
        !isFolder && CodeFile.language(of: url) != nil
    }

    /// A note, or a code file while Open code files is on: the files the sidebar and Quick Open open.
    var opens: Bool {
        isMarkdown || isCode && CodeFile.isOn
    }
}

/// A folder opened in a window: lists its children the way the sidebar shows them.
struct Folder {
    /// The hidden folders that hold what agents read: rules, skills, commands and instructions.
    static let agentFolders: Set<String> = [".claude", ".cursor", ".github"]
    /// Other apps' data and caches, which no folder walk enters.
    static let library = URL(filePath: NSHomeDirectory()).appending(path: "Library").standardizedFileURL

    let url: URL
    let ignore: GitIgnores

    init(_ url: URL) {
        self.url = url.standardizedFileURL
        ignore = GitIgnores(folder: self.url)
    }

    /// The children of `folder`, folders first in Finder order, and the names git ignores,
    /// which are among the children only when `showingIgnored`. Hidden files, .git, node_modules and ~/Library never
    /// show; the agent folders do.
    func children(of folder: URL, showingIgnored: Bool = false) -> (entries: [FolderEntry], ignored: [String]) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey], options: []
        )) ?? []
        var entries: [FolderEntry] = []
        var ignored: [String] = []
        for child in urls where child.lastPathComponent != "node_modules" && child.standardizedFileURL.path != Self.library.path {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
            let isFolder = values?.isDirectory == true
            let hidden = child.lastPathComponent.hasPrefix(".") || values?.isHidden == true
            if hidden, !(isFolder && Self.agentFolders.contains(child.lastPathComponent)) { continue }
            var entry = FolderEntry(url: child.standardizedFileURL, isFolder: isFolder)
            if let path = relativePath(of: entry.url), ignore.ignores(path, isFolder: isFolder) {
                ignored.append(child.lastPathComponent + (isFolder ? "/" : ""))
                entry.isIgnored = true
                if !showingIgnored { continue }
            }
            entries.append(entry)
        }
        entries.sort { a, b in
            a.isFolder != b.isFolder
                ? a.isFolder
                : a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        return (entries, ignored.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    /// The path of `file` under this folder, "/"-separated, or nil when it lies outside.
    func relativePath(of file: URL) -> String? {
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(url.path + "/") else { return nil }
        return String(path.dropFirst(url.path.count + 1))
    }
}

/// Reports, on the main queue, the folders under the roots whose contents changed, batched by FSEvents over 0.3 s.
@MainActor
final class FolderWatch {
    private let changed: ([URL]) -> Void
    private var stream: FSEventStreamRef?

    init(_ roots: [URL], changed: @escaping ([URL]) -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(
            nil,
            { _, info, _, paths, _, _ in
                let watch = Int(bitPattern: info)
                let folders = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]).map { URL(filePath: $0) }
                MainActor.assumeIsolated {
                    Unmanaged<FolderWatch>.fromOpaque(UnsafeRawPointer(bitPattern: watch)!).takeUnretainedValue().changed(folders)
                }
            },
            &context,
            roots.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        )
        guard let stream else { return }
        if roots.contains(where: { Folder.library.path.hasPrefix($0.path + "/") }) {
            _ = FSEventStreamSetExclusionPaths(stream, [Folder.library.path] as CFArray)
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    isolated deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

/// Recent files, recent folders and pins, kept in user defaults.
@MainActor
enum Library {
    static let changed = Notification.Name("DewlineLibraryChanged")

    struct Visit: Equatable {
        let url: URL
        let date: Date
    }

    static var recents: [Visit] { visits("RecentFiles") }
    static var recentFolders: [Visit] { visits("RecentFolders") }
    static var pins: [URL] {
        (UserDefaults.standard.stringArray(forKey: "Pins") ?? []).map { URL(filePath: $0, directoryHint: .checkFileSystem) }
    }

    static func noteOpened(_ url: URL, folder: Bool = false) {
        let key = folder ? "RecentFolders" : "RecentFiles"
        store(adding(Visit(url: url, date: .now), to: visits(key), limit: 20), key)
    }

    static func forget(_ url: URL) {
        store(recents.filter { $0.url != url }, "RecentFiles")
    }

    static func forgetRecents() {
        store([], "RecentFiles")
        store([], "RecentFolders")
    }

    static func setPinned(_ url: URL, _ pinned: Bool) {
        let paths = pins.map(\.path).filter { $0 != url.path } + (pinned ? [url.path] : [])
        UserDefaults.standard.set(paths, forKey: "Pins")
        NotificationCenter.default.post(name: changed, object: nil)
    }

    nonisolated static func adding(_ visit: Visit, to visits: [Visit], limit: Int) -> [Visit] {
        Array(([visit] + visits.filter { $0.url.path != visit.url.path }).prefix(limit))
    }

    private static func visits(_ key: String) -> [Visit] {
        (UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []).compactMap { entry in
            guard let path = entry["path"] as? String, let date = entry["date"] as? Date else { return nil }
            return Visit(url: URL(filePath: path), date: date)
        }
    }

    private static func store(_ visits: [Visit], _ key: String) {
        UserDefaults.standard.set(visits.map { ["path": $0.url.path, "date": $0.date] }, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// File > Open Recent: the recent folders, then the recent notes, newest first, then Clear Menu.
@MainActor
final class RecentMenu: NSObject, NSMenuDelegate {
    private static let shared = RecentMenu()

    static func menu() -> NSMenu {
        let menu = NSMenu(title: "Open Recent")
        menu.delegate = shared
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let groups = [(Library.recentFolders, true), (Library.recents, false)].filter { !$0.0.isEmpty }
        for (visits, folders) in groups {
            for visit in visits {
                let item = menu.addItem(
                    withTitle: FileManager.default.displayName(atPath: visit.url.path), action: #selector(open(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = visit.url
                item.tag = folders ? 1 : 0
                item.image = NSImage(systemSymbolName: folders ? "folder" : "doc.text", accessibilityDescription: nil)
                item.toolTip = abbreviatedPath(visit.url)
            }
            menu.addItem(.separator())
        }
        let clear = menu.addItem(withTitle: "Clear Menu", action: groups.isEmpty ? nil : #selector(clear(_:)), keyEquivalent: "")
        clear.target = self
    }

    @objc private func open(_ sender: NSMenuItem) {
        let url = sender.representedObject as! URL
        if sender.tag == 1 {
            (NSApp.delegate as? AppDelegate)?.openFolder(at: url)
        } else {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }

    @objc private func clear(_ sender: NSMenuItem) {
        Library.forgetRecents()
        NSDocumentController.shared.clearRecentDocuments(sender)
    }
}

/// A heading in the open file's outline.
struct Heading: Equatable {
    let level: Int
    let title: String
    /// UTF-16 offset of the heading's first character.
    let location: Int
    let line: Int
}

/// The H1 to H3 headings in `map`'s blocks of `text`, with their 1-based line numbers.
@MainActor func outline(of text: NSString, in map: BlockMap) -> [Heading] {
    var line = 1
    var counted = 0
    return map.blocks(in: NSRange(location: 0, length: text.length)).flatMap { block in
        block.spans.compactMap { span in
            guard case .heading(let level) = span.kind, level <= 3 else { return nil }
            let location = block.range.location + span.range.location
            for index in counted..<location where text.character(at: index) == 0x0A {
                line += 1
            }
            counted = location
            let title = plainInline(text.substring(with: NSRange(location: block.range.location + span.content.location, length: span.content.length)))
            return title.isEmpty ? nil : Heading(level: level, title: title, location: location, line: line)
        }
    }
}

/// `markdown` without link targets, wikilink brackets and emphasis or code markers.
func plainInline(_ markdown: String) -> String {
    markdown
        .replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        .replacingOccurrences(of: #"\[\[([^\]|]*)(?:\|([^\]]*))?\]\]"#, with: "$1", options: .regularExpression)
        .replacingOccurrences(of: #"\*\*|__|~~|[*`]"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

/// "9:12 AM" today, "Yesterday", a weekday within the week, then the date.
func shortDate(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
    let locale = calendar.locale ?? .current
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    switch days {
    case ...0: style = style.hour().minute()
    case 1: return "Yesterday"
    case 2..<7: style = style.weekday(.wide)
    default:
        style = style.day().month(.abbreviated)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
    }
    return date.formatted(style)
}

/// The branch checked out in the repository holding `folder`, read from its HEAD; nil when detached or in none. A
/// worktree's .git file names its git directory.
func gitBranch(at folder: URL) -> String? {
    var directory = folder.standardizedFileURL
    while true {
        let dotGit = directory.appending(path: ".git")
        var gitdir = dotGit
        if let file = try? String(contentsOf: dotGit, encoding: .utf8), file.hasPrefix("gitdir: ") {
            let path = file.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitdir = path.hasPrefix("/") ? URL(filePath: path) : directory.appending(path: path)
        }
        if let head = try? String(contentsOf: gitdir.appending(path: "HEAD"), encoding: .utf8) {
            guard head.hasPrefix("ref: refs/heads/") else { return nil }
            return head.dropFirst("ref: refs/heads/".count).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard directory.pathComponents.count > 1 else { return nil }
        directory = directory.deletingLastPathComponent()
    }
}

/// `url`'s path with the home folder as "~".
func abbreviatedPath(_ url: URL, home: String = NSHomeDirectory()) -> String {
    let path = url.standardizedFileURL.path
    guard path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
}
