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

/// The `dewline` command on the PATH: a symlink to the app's helper in /usr/local/bin when this account can write there
/// and Homebrew doesn't own it, else in ~/.local/bin, made if missing. Never Homebrew's prefix, never an admin prompt.
@MainActor
enum CommandLink {
    /// ~/.local/bin when this launch made it, which the shell's PATH may not have yet.
    private(set) static var madeFolder: URL?

    static func folder(
        home: URL = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory), canUse: (String) -> Bool = CommandLink.canUse
    ) -> URL {
        canUse("/usr/local/bin") ? URL(filePath: "/usr/local/bin", directoryHint: .isDirectory) : home.appending(path: ".local/bin", directoryHint: .isDirectory)
    }

    /// A folder this account can write that Homebrew doesn't keep.
    nonisolated static func canUse(_ path: String) -> Bool {
        FileManager.default.isWritableFile(atPath: path) && !FileManager.default.fileExists(atPath: path + "/brew")
    }

    /// The file at the link's place unless it is a link that resolves to `command`, which Add leaves alone.
    static func taken(at folder: URL = folder(), command: URL = HookSetup.command()) -> URL? {
        let link = folder.appending(path: "dewline")
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return FileManager.default.fileExists(atPath: link.path) ? link : nil
        }
        return resolved(URL(filePath: destination, relativeTo: folder)) == resolved(command) ? nil : link
    }

    private static func resolved(_ url: URL) -> String {
        url.absoluteURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// True when `command` sits where a link to it breaks or can be swapped: on a volume, or in a copy macOS translocated.
    static func unstable(_ command: URL) -> Bool {
        let path = resolved(command)
        return path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    /// Settings > Agents and the setup list's Add: the Move window while the app runs from a disk image, a translocated
    /// copy or another volume, as Set Up does, else the link.
    static func add(on window: NSWindow?) {
        guard !HookSetup.misplaced(), !unstable(HookSetup.command()) else { return HookSetup.offerMove(on: window) }
        do {
            try install()
        } catch {
            NSApp.presentError(error)
        }
    }

    /// Links `command` as dewline in `folder`; nil when the app is `misplaced`, `command` is unstable or another
    /// dewline is there.
    @discardableResult
    static func install(command: URL = HookSetup.command(), in folder: URL = folder(), misplaced: Bool = HookSetup.misplaced()) throws -> URL? {
        guard !misplaced, !unstable(command), taken(at: folder, command: command) == nil else { return nil }
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            madeFolder = folder
        }
        let link = folder.appending(path: "dewline")
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil { try FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: command)
        return link
    }

    /// "dewline is at ~/.local/bin/dewline.", saying to add the folder to the PATH when this launch made it.
    static func status(_ path: String) -> String {
        let shown = (path as NSString).abbreviatingWithTildeInPath
        guard let made = madeFolder, path.hasPrefix(made.path + "/") else { return "dewline is at \(shown)." }
        return "dewline is at \(shown). Add \((made.path as NSString).abbreviatingWithTildeInPath) to your PATH to run it by name."
    }
}

struct AgentsPane: View {
    let store: ThemeStore
    @State private var hooks = HookStatus()
    @State private var taken: URL?

    var body: some View {
        SettingsForm {
            Section {
                LabeledContent {
                    if hooks.onPath == nil, taken == nil {
                        Button("Add") {
                            CommandLink.add(on: NSApp.keyWindow)
                            Task { await refresh() }
                        }
                        .fixedSize()
                    }
                } label: {
                    Text("dewline command")
                    Text(hooks.onPath.map(CommandLink.status) ?? taken.map { "Another dewline is at \(($0.path as NSString).abbreviatingWithTildeInPath)." } ?? "Not on your PATH.")
                }
            }
            Section {
                ForEach(hooks.agents) { agent in
                    row(agent)
                }
            } header: {
                Text("Hooks")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("With its hooks, each agent\u{2019}s change carries its name. Without them, its edits still show, labeled Another app.")
                        .foregroundStyle(.secondary)
                    Spacer()
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
        taken = CommandLink.taken()
    }

    /// "Last named edit 16:10", or the date too before today: when the agent's hooks last named a write.
    private static func lastEdit(_ agent: String) -> String {
        guard let date = ControlSocket.Claim.lastNamedEdit(agent) else { return "No named edit yet" }
        return "Last named edit " + date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }

    /// The agent's name, what its hooks give and when they last named an edit, then its state with a symbol, then Set Up or
    /// Remove, and Show File when it has a settings file.
    private func row(_ agent: HookStatus.Agent) -> some View {
        let (text, symbol, color): (String, String, Color) =
            switch (agent.installed, agent.needsTrust) {
            case (true, false): ("Active", "checkmark.circle.fill", .green)
            case (true, true): ("Installed, needs trust", "exclamationmark.triangle.fill", .orange)
            default: ("Not set up", "circle.dashed", .secondary)
            }
        return LabeledContent {
            HStack {
                Label {
                    Text(text).foregroundStyle(agent.installed ? .primary : .secondary)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(color)
                }
                .help(agent.needsTrust ? "Type /hooks in Codex to trust them." : "")
                if agent.installed {
                    Button("Remove") { HookSetup.remove(agent.name) { _ in Task { await refresh() } } }
                        .fixedSize()
                        .help("Takes Dewline\u{2019}s hooks out of \(agent.title)\u{2019}s settings, keeping a backup beside the file.")
                } else {
                    Button("Set Up\u{2026}") { HookSetup.install(from: NSApp.keyWindow, agent: agent.name) { _ in Task { await refresh() } } }
                        .fixedSize()
                }
                if let file = agent.file, FileManager.default.fileExists(atPath: file) {
                    Button("Show File") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: file)]) }
                        .fixedSize()
                        .help((file as NSString).abbreviatingWithTildeInPath)
                }
            }
        } label: {
            Text(agent.title)
            Text(Self.detail(agent.name))
            Text(Self.lastEdit(agent.name))
        }
    }
}
