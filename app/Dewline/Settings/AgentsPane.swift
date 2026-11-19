import AppKit
import SwiftUI

/// What `dewline doctor` reports: whether the command runs, from the PATH or else inside the app, and whether each
/// agent's settings carry every hook that names its writes, each running a command that exists.
struct HookStatus: Equatable, Sendable {
    var claude: Bool
    var codex: Bool
    /// Codex has the hooks but hasn't recorded trust for each one, so it doesn't run them.
    var codexNeedsTrust = false
    var cursor = false
    /// The `dewline` on the PATH, if any.
    var onPath: String?
    /// The doctor's version line, or nil when the command didn't run.
    var version: String?

    /// Where Homebrew and the usual installs put commands; an app doesn't get the login shell's PATH.
    private static let pathFolders = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/bin"]

    static func read(
        home: URL = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory),
        bundle: URL = Bundle.main.bundleURL
    ) -> HookStatus {
        let onPath = pathFolders
            .map { ($0 as NSString).expandingTildeInPath + "/dewline" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let process = Process()
        process.executableURL = URL(filePath: onPath ?? bundle.appending(path: "Contents/Helpers/dewline").path)
        process.arguments = ["doctor"]
        process.environment = ProcessInfo.processInfo.environment.merging(["HOME": home.path]) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return HookStatus(claude: false, codex: false, onPath: onPath) }
        // A doctor that hangs reads as no hooks after 2 s.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { process.terminate() } }
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        process.waitUntilExit()
        func installed(_ agent: String) -> Substring? {
            lines.first { $0.hasPrefix("  \(agent): installed in ") }
        }
        return HookStatus(
            claude: installed("Claude Code") != nil, codex: installed("Codex") != nil,
            codexNeedsTrust: installed("Codex")?.contains("; needs trust") == true, cursor: installed("Cursor") != nil, onPath: onPath,
            version: lines.first { $0.hasPrefix("Version: ") }.map { String($0.dropFirst("Version: ".count)) }
        )
    }
}

struct AgentsPane: View {
    let store: ThemeStore
    @State private var hooks = HookStatus(claude: false, codex: false)

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Hooks", note: "Hooks tell Dewline which agent wrote a change.") {
                SettingsRow(label: "Claude Code", detail: "Edits made by its shell commands show as Another app.") {
                    status(hooks.claude ? "Installed" : nil)
                }
                SettingsRow(label: "Codex", detail: "Codex runs them once you trust them: type /hooks in Codex.") {
                    status(hooks.codex ? (hooks.codexNeedsTrust ? "Needs trust" : "Installed") : nil)
                }
                SettingsRow(
                    label: "Cursor",
                    detail: "Names the agent\u{2019}s edits Cursor reports. Tab edits, terminal commands and edits that only delete lines show as Another app."
                ) {
                    status(hooks.cursor ? "Installed" : nil)
                }
                SettingsRow(label: "") {
                    Button("Set Up All Hooks\u{2026}") { NSApp.sendAction(Self.setUpHooks, to: nil, from: nil) }
                        .fixedSize()
                        .help(hooks.version ?? "")
                }
            }
        }
        .task { hooks = await Task.detached { HookStatus.read() }.value }
    }

    /// Answered by HookSetup, which lists the files the hooks change before it installs them.
    static let setUpHooks = #selector(AppDelegate.setUpHooks(_:))

    /// `text`, or "Not set up" in the muted ink when it is nil.
    private func status(_ text: String?) -> some View {
        Text(text ?? "Not set up")
            .font(Station.label)
            .foregroundStyle(Station.color(text == nil ? .ink2 : .ink))
    }
}
