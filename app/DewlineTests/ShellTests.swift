import Foundation
import Testing
@testable import Dewline

struct ShellTests {
    @Test func gitIgnoreMatchesNamesAnchorsAndFolders() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("# build output\nbuild/\n/drafts\n*.log\ndocs/private\n!keep.log\n".utf8).write(to: root.appending(path: ".gitignore"))
        let ignore = Folder(root).ignore
        #expect(ignore.ignores("build", isFolder: true))
        #expect(ignore.ignores("notes/build", isFolder: true))
        #expect(!ignore.ignores("build", isFolder: false))
        #expect(ignore.ignores("drafts", isFolder: true))
        #expect(!ignore.ignores("notes/drafts", isFolder: true))
        #expect(ignore.ignores("notes/debug.log", isFolder: false))
        #expect(ignore.ignores("docs/private", isFolder: true))
        #expect(!ignore.ignores("private", isFolder: true))
        #expect(!ignore.ignores("notes.md", isFolder: false))
        #expect(!ignore.ignores("keep.log", isFolder: false))
    }

    @Test func folderListsFoldersFirstInFinderOrderAndHidesNoise() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in [".git", ".claude", "node_modules", "build", "Journal"] {
            try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        for file in [".DS_Store", ".gitignore", "note 10.md", "note 2.md", "photo.png", "debug.log", "rule.mdc"] {
            try Data((file == ".gitignore" ? "build/\n*.log\n" : "").utf8).write(to: root.appending(path: file))
        }
        let folder = Folder(root)
        let listing = folder.children(of: folder.url)
        #expect(listing.entries.map(\.url.lastPathComponent) == [".claude", "Journal", "note 2.md", "note 10.md", "photo.png", "rule.mdc"])
        #expect(listing.entries.map(\.isMarkdown) == [false, false, true, true, false, true])
        #expect(listing.ignored == ["build/", "debug.log"])
        let all = folder.children(of: folder.url, showingIgnored: true).entries
        #expect(all.map(\.url.lastPathComponent) == [".claude", "build", "Journal", "debug.log", "note 2.md", "note 10.md", "photo.png", "rule.mdc"])
        #expect(all.filter(\.isIgnored).map(\.url.lastPathComponent) == ["build", "debug.log"])
        #expect(folder.relativePath(of: root.appending(path: "Journal/today.md")) == "Journal/today.md")
        #expect(folder.relativePath(of: root.deletingLastPathComponent()) == nil)
    }

    @Test @MainActor func aNoteAtHomeOrARootOpensWithoutAFolder() throws {
        let home = URL(filePath: NSHomeDirectory())
        #expect(MainWindowController.folder(for: home.appending(path: "AGENTS.md")) == nil)
        #expect(MainWindowController.folder(for: home.appending(path: "Library/notes.md")) == nil)
        #expect(MainWindowController.folder(for: home.appending(path: "Library/Application Support/dev.arkwerx.dewline/Welcome.md")) == nil)
        #expect(MainWindowController.folder(for: URL(filePath: "/notes.md")) == nil)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "docs"), withIntermediateDirectories: true)
        #expect(MainWindowController.folder(for: root.appending(path: "docs/plan.md"))?.url == root.standardizedFileURL)
    }

    @Test @MainActor func outlineKeepsH1ToH3WithLineNumbers() {
        let text = "# Plan\n\nIntro\n\n## **Before** the beta\n\n```\n# not a heading\n```\n\n#### Too deep\n### Monday\n" as NSString
        let map = BlockMap()
        _ = map.textDidChange(text, edited: NSRange(location: 0, length: text.length), delta: text.length)
        #expect(outline(of: text, in: map).map { [$0.level, $0.line] } == [[1, 1], [2, 5], [3, 12]])
        #expect(outline(of: text, in: map).map(\.title) == ["Plan", "Before the beta", "Monday"])
    }

    @Test func shortDateNamesTodayYesterdayTheWeekThenTheDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 15)))
        func ago(_ days: Int, hour: Int = 9) -> Date {
            calendar.date(byAdding: .day, value: -days, to: calendar.date(bySettingHour: hour, minute: 12, second: 0, of: now)!)!
        }
        #expect(shortDate(ago(0), now: now, calendar: calendar) == "09:12")
        #expect(shortDate(ago(1, hour: 23), now: now, calendar: calendar) == "Yesterday")
        #expect(shortDate(ago(3), now: now, calendar: calendar) == "Thursday")
        #expect(shortDate(ago(7), now: now, calendar: calendar) == "18 Oct")
        let lastYear = try #require(calendar.date(from: DateComponents(year: 2025, month: 3, day: 14, hour: 9)))
        #expect(shortDate(lastYear, now: now, calendar: calendar) == "14 Mar 2025")
    }

    @Test func pathsAbbreviateTheHomeFolder() {
        let home = "/Users/rick"
        #expect(abbreviatedPath(URL(filePath: "/Users/rick/Notes/essays/"), home: home) == "~/Notes/essays")
        #expect(abbreviatedPath(URL(filePath: "/Users/rick"), home: home) == "~")
        #expect(abbreviatedPath(URL(filePath: "/Users/rick/Notes/../Plans"), home: home) == "~/Plans")
        #expect(abbreviatedPath(URL(filePath: "/Users/ricky/Notes"), home: home) == "/Users/ricky/Notes")
        #expect(abbreviatedPath(URL(filePath: "/Volumes/Work/Users/rick"), home: home) == "/Volumes/Work/Users/rick")
    }

    @Test func visitsMoveToTheFrontWithoutDuplicates() {
        let a = Library.Visit(url: URL(filePath: "/a.md"), date: .distantPast)
        let b = Library.Visit(url: URL(filePath: "/b.md"), date: .distantPast)
        let again = Library.Visit(url: URL(filePath: "/a.md"), date: .now)
        #expect(Library.adding(again, to: [a, b], limit: 20) == [again, b])
        #expect(Library.adding(b, to: [a], limit: 1) == [b])
        let folder = Library.Visit(url: URL(filePath: "/notes/", directoryHint: .isDirectory), date: .now)
        #expect(Library.adding(folder, to: [Library.Visit(url: URL(filePath: "/notes"), date: .distantPast)], limit: 20) == [folder])
    }
}
