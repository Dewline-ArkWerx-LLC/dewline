import AppKit
import SwiftUI
import Testing
@testable import Dewline

/// Every test keeps its settings in a throwaway defaults suite and its files in a temporary folder.
@MainActor
struct SettingsPaneTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "dev.arkwerx.dewline.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func preferencesStartFromTheirDefaults() {
        withDefaults { defaults in
            let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
            let preferences = Preferences(defaults: defaults, home: home)
            #expect(!preferences.showsIgnored)
            #expect(preferences.attachments == .beside)
            #expect(preferences.inbox.path == "/Users/someone/Documents/Dewline/Inbox.md")
            #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("Dewline") }.isEmpty, "reading writes nothing")
        }
    }

    @Test func preferencesKeepWhatIsSetUnderTheirKeys() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            preferences.showsIgnored = true
            preferences.attachments = .subfolder
            preferences.inbox = URL(filePath: "/tmp/notes/Inbox.md")
            #expect(defaults.bool(forKey: "DewlineShowIgnored"))
            #expect(defaults.string(forKey: "DewlineAttachments") == "subfolder")
            #expect(defaults.string(forKey: Preferences.inboxKey) == "/tmp/notes/Inbox.md")

            let reread = Preferences(defaults: defaults)
            #expect(reread.showsIgnored)
            #expect(reread.attachments == .subfolder)
            #expect(reread.inbox.path == "/tmp/notes/Inbox.md")
        }
    }

    @Test func preferencesRefuseValuesTheyCannotUse() {
        withDefaults { defaults in
            defaults.set("relative/Inbox.md", forKey: Preferences.inboxKey)
            defaults.set("cloud", forKey: "DewlineAttachments")
            let preferences = Preferences(defaults: defaults, home: URL(filePath: "/Users/someone", directoryHint: .isDirectory))
            #expect(preferences.inbox.path == "/Users/someone/Documents/Dewline/Inbox.md")
            #expect(preferences.attachments == .beside)
        }
    }

    /// Each pane's Restore Defaults puts back its own settings as a fresh install has them, and leaves the others.
    @Test func restoreDefaultsPutsBackEachPanesSettings() {
        withDefaults { defaults in
            let store = ThemeStore(defaults: defaults)
            let preferences = Preferences(defaults: defaults)
            let factory = ThemeStore.factory
            store.appearance = factory.appearance == .dark ? .light : .dark
            store.lightTheme = Theme.light.first { $0 != factory.lightTheme }!
            store.darkTheme = Theme.dark.first { $0 != factory.darkTheme }!
            store.bodyFace = "Menlo"
            store.headingFace = "Menlo"
            store.codeFace = "Menlo"
            store.bodySize = factory.bodySize + 3
            store.lineHeight = factory.lineHeight + 0.1
            store.columnWidth = factory.columnWidth + 10
            store.vimMode = !factory.vimMode
            store.tabWidth = factory.tabWidth == 4 ? 2 : 4
            store.spellCheck = !factory.spellCheck
            preferences.linkPreviews = !Preferences.factory.linkPreviews
            preferences.opensCodeFiles = !Preferences.factory.opensCodeFiles

            AppearancePane.restore(store)
            #expect(store.appearance == factory.appearance)
            #expect(store.lightTheme == factory.lightTheme)
            #expect(store.darkTheme == factory.darkTheme)
            #expect([store.bodyFace, store.headingFace, store.codeFace] == [factory.bodyFace, factory.headingFace, factory.codeFace])
            #expect([store.bodySize, store.lineHeight, store.columnWidth] == [factory.bodySize, factory.lineHeight, factory.columnWidth])
            #expect(store.vimMode != factory.vimMode, "Appearance leaves the Editor's settings")

            EditorPane.restore(store, preferences)
            #expect(store.vimMode == factory.vimMode)
            #expect(store.tabWidth == factory.tabWidth)
            #expect(store.spellCheck == factory.spellCheck)
            #expect(preferences.linkPreviews == Preferences.factory.linkPreviews)
            #expect(preferences.opensCodeFiles == Preferences.factory.opensCodeFiles)
        }
    }

    /// A store other than the shared one, as Restore Defaults' factory and these tests make, leaves open editors alone.
    @Test func aSecondThemeStoreLeavesOpenEditorsAlone() throws {
        let view = try #require(EditorTextView.scrollView().documentView as? EditorTextView)
        let probe = NSColor(red: 1, green: 0, blue: 1, alpha: 1)
        view.backgroundColor = probe
        withDefaults { ThemeStore(defaults: $0).bodySize += 1 }
        #expect(view.backgroundColor == probe)
    }

    /// Every pane is a grouped form the window's width, as tall as its settings and no taller than the window allows.
    @Test func panesSizeToTheirContent() {
        for pane in SettingsPane.allCases {
            let size = NSHostingController(rootView: SettingsPaneView(pane: pane)).view.fittingSize
            #expect(size.width == SettingsWindowController.width, "\(pane)")
            #expect(size.height > 100 && size.height <= SettingsWindowController.maxHeight, "\(pane): \(size.height)")
        }
    }

    @Test func hookStatusReadsEachAgentsSettings() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(HookStatus.read(home: home).pair == [false, false])

        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        // Every event `dewline doctor --install-hooks` writes, each calling `dewline notify --hook <agent>`.
        func hooks(_ agent: String, _ events: [String]) throws -> Data {
            let group = ["hooks": [["type": "command", "command": "dewline notify --hook \(agent)"]]]
            return try JSONSerialization.data(withJSONObject: ["hooks": Dictionary(uniqueKeysWithValues: events.map { ($0, [group]) })])
        }
        try hooks("claude", ["PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "InstructionsLoaded"])
            .write(to: home.appending(path: ".claude/settings.json"))
        #expect(HookStatus.read(home: home).pair == [true, false])
        #expect(HookStatus.read(home: home).agents[0].file == home.appending(path: ".claude/settings.json").path)

        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try Data("model = \"gpt\"\n".utf8).write(to: home.appending(path: ".codex/config.toml"))
        #expect(HookStatus.read(home: home).codex == false)
        try hooks("codex", ["PreToolUse", "PostToolUse", "Stop", "SessionEnd"]).write(to: home.appending(path: ".codex/hooks.json"))
        #expect(HookStatus.read(home: home).pair == [true, true])
        #expect(HookStatus.read(home: home).codexNeedsTrust)
    }

    /// Hooks that run a Dewline the user moved or deleted name nothing, so they don't read as installed.
    @Test func hooksRunningAMovedAppAreNotSetUp() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: "Here"), withIntermediateDirectories: true)
        let here = home.appending(path: "Here/dewline").path
        #expect(FileManager.default.createFile(atPath: here, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755]))
        func install(_ program: String) throws {
            let events = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "InstructionsLoaded"]
            let group = ["hooks": [["type": "command", "command": "\(program) notify --hook claude"]]]
            try JSONSerialization.data(withJSONObject: ["hooks": Dictionary(uniqueKeysWithValues: events.map { ($0, [group]) })])
                .write(to: home.appending(path: ".claude/settings.json"))
        }
        try install(here)
        #expect(HookStatus.read(home: home).claude)
        try install(home.appending(path: "Gone/dewline").path)
        #expect(HookStatus.read(home: home).claude == false)
    }
}

private extension HookStatus {
    /// Claude Code's and Codex's hooks, as the doctor reports them.
    var pair: [Bool] { [claude, codex] }
}
