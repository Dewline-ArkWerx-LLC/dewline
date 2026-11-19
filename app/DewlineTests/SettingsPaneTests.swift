import Foundation
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

    @Test func hookStatusReadsEachAgentsSettings() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(HookStatus.read(home: home).agents == [false, false])

        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        // Every event `dewline doctor --install-hooks` writes, each calling `dewline notify --hook <agent>`.
        func hooks(_ agent: String, _ events: [String]) throws -> Data {
            let group = ["hooks": [["type": "command", "command": "dewline notify --hook \(agent)"]]]
            return try JSONSerialization.data(withJSONObject: ["hooks": Dictionary(uniqueKeysWithValues: events.map { ($0, [group]) })])
        }
        try hooks("claude", ["PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "InstructionsLoaded"])
            .write(to: home.appending(path: ".claude/settings.json"))
        #expect(HookStatus.read(home: home).agents == [true, false])

        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try Data("model = \"gpt\"\n".utf8).write(to: home.appending(path: ".codex/config.toml"))
        #expect(HookStatus.read(home: home).codex == false)
        try hooks("codex", ["PreToolUse", "PostToolUse", "Stop", "SessionEnd"]).write(to: home.appending(path: ".codex/hooks.json"))
        #expect(HookStatus.read(home: home).agents == [true, true])
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

    @Test func installCommandRunsTheBundledToolQuoted() {
        #expect(HookStatus.installCommand(bundle: URL(filePath: "/Applications/Dewline.app"))
            == "'/Applications/Dewline.app/Contents/Helpers/dewline' doctor --install-hooks")
        #expect(HookStatus.installCommand(bundle: URL(filePath: "/Users/someone/Rick's Apps/Dewline.app"))
            == #"'/Users/someone/Rick'\''s Apps/Dewline.app/Contents/Helpers/dewline' doctor --install-hooks"#)
    }
}

private extension HookStatus {
    /// Claude Code's and Codex's hooks, as the doctor reports them.
    var agents: [Bool] { [claude, codex] }
}
