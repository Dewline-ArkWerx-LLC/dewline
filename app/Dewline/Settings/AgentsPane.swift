import AppKit
import SwiftUI

/// What `dewline doctor` reports: whether the command runs, from the PATH or else inside the app, and for each agent
/// whether its settings carry every hook that names its writes, each running a command that exists.
struct HookStatus: Equatable, Sendable {
    struct Agent: Equatable, Sendable, Identifiable {
        /// The doctor's name for it: "claude", "codex" or "cursor".
        let name: String
        /// "Claude Code".
        let title: String
        var installed = false
        /// Codex has the hooks but hasn't recorded trust for each one, so it doesn't run them.
        var needsTrust = false
        /// The settings file the doctor names for it, nil when the agent isn't on this Mac.
        var file: String?

        var id: String { name }
    }

    var agents = [Agent(name: "claude", title: "Claude Code"), Agent(name: "codex", title: "Codex"), Agent(name: "cursor", title: "Cursor")]
    /// The `dewline` on the PATH, if any.
    var onPath: String?
    /// The doctor's version line, or nil when the command didn't run.
    var version: String?

    var claude: Bool { agents[0].installed }
    var codex: Bool { agents[1].installed }
    var cursor: Bool { agents[2].installed }
    var codexNeedsTrust: Bool { agents[1].needsTrust }
    /// True when any agent's hooks are set up.
    var any: Bool { agents.contains(where: \.installed) }

    /// Where Homebrew and the usual installs put commands; an app doesn't get the login shell's PATH.
    private static let pathFolders = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/bin"]

    /// The doctor's report, run in `folder` so it reads that project's settings too.
    static func read(
        home: URL = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory),
        bundle: URL = Bundle.main.bundleURL, in folder: URL? = nil
    ) -> HookStatus {
        var status = HookStatus()
        status.onPath = pathFolders
            .map { ($0 as NSString).expandingTildeInPath + "/dewline" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let process = Process()
        process.executableURL = URL(filePath: status.onPath ?? bundle.appending(path: "Contents/Helpers/dewline").path)
        process.arguments = ["doctor"]
        process.currentDirectoryURL = folder
        process.environment = ProcessInfo.processInfo.environment.merging(["HOME": home.path]) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return status }
        // A doctor that hangs reads as no hooks after 2 s.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { process.terminate() } }
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        process.waitUntilExit()
        for index in status.agents.indices {
            guard let line = lines.first(where: { $0.hasPrefix("  \(status.agents[index].title): ") }) else { continue }
            let report = line.dropFirst(status.agents[index].title.count + 4)
            if report.hasPrefix("installed in ") {
                let file = report.dropFirst("installed in ".count)
                status.agents[index].installed = true
                status.agents[index].needsTrust = file.contains("; needs trust")
                status.agents[index].file = String(file.prefix { $0 != ";" })
            } else if let from = report.range(of: " missing from ") {
                status.agents[index].file = String(report[from.upperBound...])
            } else if let set = report.range(of: "disableAllHooks is set in ") {
                status.agents[index].file = String(report[set.upperBound...])
            }
        }
        status.version = lines.first { $0.hasPrefix("Version: ") }.map { String($0.dropFirst("Version: ".count)) }
        return status
    }
}

struct AgentsPane: View {
    let store: ThemeStore
    @State private var hooks = HookStatus()

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Hooks") {
                SettingsNote(
                    "With its hooks, each agent\u{2019}s change carries its name. Without them, its edits still show, labeled Another app."
                )
                .padding(.bottom, 10)
                ForEach(hooks.agents) { agent in
                    SettingsRow(label: agent.title, detail: Self.detail(agent.name)) {
                        row(agent)
                    }
                }
                SettingsRow(label: "") {
                    Button("Set Up All Hooks\u{2026}") { HookSetup.install(from: NSApp.keyWindow) { _ in Task { await refresh() } } }
                        .fixedSize()
                        .help(hooks.version ?? "")
                }
            }
        }
        .task { await refresh() }
    }

    /// What each agent's hooks give, then where they stop.
    private static func detail(_ agent: String) -> String {
        switch agent {
        case "claude": "Names Claude Code\u{2019}s edits. Edits from its shell commands show as \u{201C}\(ChangeStamp.duringShell)\u{201D}."
        case "codex": "Names Codex\u{2019}s edits once you trust the hooks: type /hooks in Codex."
        default: "Names the edits Cursor\u{2019}s agent reports. Tab edits, terminal commands and edits that only delete lines show as Another app."
        }
    }

    private func refresh() async {
        hooks = await Task.detached { HookStatus.read() }.value
    }

    /// The agent's state with its symbol, then Set Up or Remove, and Show File when it has a settings file.
    private func row(_ agent: HookStatus.Agent) -> some View {
        let (text, symbol, color): (String, String, Color) =
            switch (agent.installed, agent.needsTrust) {
            case (true, false): ("Installed", "checkmark.circle.fill", .green)
            case (true, true): ("Needs trust", "exclamationmark.triangle.fill", .orange)
            default: ("Not set up", "circle.dashed", Station.color(.ink2))
            }
        return HStack(spacing: 8) {
            Label {
                Text(text).foregroundStyle(Station.color(agent.installed ? .ink : .ink2))
            } icon: {
                Image(systemName: symbol).foregroundStyle(color)
            }
            .font(Station.label)
            .frame(width: 110, alignment: .leading)
            if agent.installed {
                Button("Remove") { HookSetup.remove(agent.name) { _ in Task { await refresh() } } }
                    .fixedSize()
                    .help("Takes Dewline\u{2019}s hooks out of \(agent.title)\u{2019}s settings, keeping a backup beside the file.")
            } else if agent.file != nil {
                Button("Set Up\u{2026}") { HookSetup.install(from: NSApp.keyWindow, agent: agent.name) { _ in Task { await refresh() } } }
                    .fixedSize()
            }
            if let file = agent.file, FileManager.default.fileExists(atPath: file) {
                Button("Show File") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: file)]) }
                    .fixedSize()
                    .help((file as NSString).abbreviatingWithTildeInPath)
            }
        }
    }
}
