import AppKit

/// Set Up and Remove for agent hooks. Set Up shows the settings files `dewline doctor --install-hooks` would change and
/// the entries it would add, and on Add Hooks runs it from the app's bundle, answering its questions yes. The command
/// asks only on a terminal, so it runs on a pseudo-terminal of its own.
@MainActor
enum HookSetup {
    /// Agent settings missing a hook, from `dewline doctor`: "Claude Code", the file it would change, and each entry it
    /// would add there as JSON.
    struct Missing: Equatable {
        let agent: String
        let file: String
        var entries: [String] = []
    }

    static func command(bundle: URL = Bundle.main.bundleURL) -> URL {
        bundle.appending(path: "Contents/Helpers/dewline")
    }

    /// Reads the doctor's "  Claude Code: PreToolUse, Stop missing from /Users/a/.claude/settings.json" lines and the
    /// "    {"Stop": …}" entries under each.
    static func missing(in report: String) -> [Missing] {
        var found: [Missing] = []
        var last: Int?
        for line in report.split(separator: "\n") {
            if line.hasPrefix("    "), let index = last {
                found[index].entries.append(line.trimmingCharacters(in: .whitespaces))
                continue
            }
            last = nil
            guard line.hasPrefix("  "), let colon = line.firstIndex(of: ":"), let from = line.range(of: " missing from ") else { continue }
            let agent = line[line.index(line.startIndex, offsetBy: 2)..<colon]
            found.append(Missing(agent: String(agent), file: String(line[from.upperBound...])))
            last = found.count - 1
        }
        return found
    }

    /// Names in a folder that say an agent works there.
    private static let agentNames = [".claude", ".cursor", ".codex", "CLAUDE.md", "AGENTS.md"]
    /// The folders already checked.
    private static let offeredKey = "DewlineOfferedHookSetup"
    /// True once the user has ticked Don't Offer Again; no offer shows after that.
    private static let declinedKey = "DewlineDeclinedHookSetup"
    /// The folders doctor is checking now.
    private static var checking: Set<String> = []

    /// Offers Set Up on `window` if an agent's hooks are missing, once for each folder that holds an agent's files;
    /// doctor reads `folder`'s project settings too. A folder counts as checked once doctor has run and found nothing
    /// missing or the sheet has shown, so Not Now holds for that folder only.
    static func offer(on window: NSWindow, in folder: URL) {
        let key = folder.path
        guard !checking.contains(key), !UserDefaults.standard.bool(forKey: declinedKey),
            !(UserDefaults.standard.stringArray(forKey: offeredKey) ?? []).contains(key),
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
            agentNames.contains(where: { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) })
        else { return }
        checking.insert(key)
        Task {
            let report = await run(command(), ["doctor"], answers: 0, in: folder)
            checking.remove(key)
            let hooksMissing = !missing(in: report.output).isEmpty
            guard report.ran, !hooksMissing || window.isVisible else { return }
            UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: offeredKey) ?? []) + [key], forKey: offeredKey)
            if hooksMissing { install(from: window, in: folder, offered: true) }
        }
    }

    /// Settings > Agents > Set Up…, and the offers: a sheet on `window` naming each file and what it gains, then the
    /// run; `agent` ("claude", "codex" or "cursor") sets up that agent alone. An offer's sheet can stop every offer.
    static func install(
        from window: NSWindow?, in folder: URL? = nil, agent: String? = nil, offered: Bool = false, command: URL = command(),
        done: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        let only = agent.map { ["--agent", $0] } ?? []
        Task {
            let report = await run(command, ["doctor"] + only, answers: 0, in: folder)
            let missing = Self.missing(in: report.output)
            let alert = NSAlert()
            guard report.ran else {
                alert.messageText = "Dewline couldn\u{2019}t run its dewline command."
                alert.informativeText = "Reinstall Dewline, then try again."
                return present(alert, on: window) { _ in done(false) }
            }
            guard !missing.isEmpty else {
                let none = !report.output.contains(": installed in ")
                alert.messageText = none ? "No agent to set up." : "Agent edits are already marked."
                alert.informativeText = none
                    ? "Dewline found no ~/.claude, ~/.codex or ~/.cursor folder. Set up again after you install Claude Code, Codex or Cursor."
                    : "Every agent Dewline knows has its hooks."
                return present(alert, on: window) { _ in done(true) }
            }
            alert.messageText = "Let Dewline see which agent made each edit"
            alert.informativeText = "Hooks let each change name the agent that wrote it; without them, agent edits still show, labeled Another app. "
                + "Adds one local command (dewline notify) to PreToolUse and PostToolUse. Nothing leaves this Mac. "
                + "Remove it any time in Settings > Agents."
            alert.accessoryView = HookDetails(missing, command: command, alert: alert)
            alert.addButton(withTitle: "Add Hooks")
            alert.addButton(withTitle: "Not Now")
            if offered {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = "Don\u{2019}t offer again"
            }
            present(alert, on: window) { response in
                if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: declinedKey) }
                guard response == .alertFirstButtonReturn else { return done(false) }
                Task {
                    let result = await run(command, ["doctor", "--install-hooks"] + only, answers: missing.count, in: folder)
                    let after = await run(command, ["doctor"] + only, answers: 0, in: folder)
                    done(result.ran && Self.missing(in: after.output).isEmpty)
                }
            }
        }
    }

    /// Settings > Agents > Remove: takes `agent`'s Dewline hooks out of its settings file, keeping a backup beside it.
    static func remove(_ agent: String, command: URL = command(), done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        Task {
            done(await run(command, ["doctor", "--remove-hooks", "--agent", agent], answers: 1).ran)
        }
    }

    private static func present(_ alert: NSAlert, on window: NSWindow?, _ handler: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let window {
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { handler(response) } }
        } else {
            handler(alert.runModal())
        }
    }

    /// Runs `command` with `arguments` in `folder` on a pseudo-terminal, typing "y" and Return `answers` times.
    static func run(_ command: URL, _ arguments: [String], answers: Int, in folder: URL? = nil) async -> (ran: Bool, output: String) {
        await Task.detached {
            var main: Int32 = -1
            var side: Int32 = -1
            guard openpty(&main, &side, nil, nil, nil) == 0 else { return (false, "") }
            let process = Process()
            process.executableURL = command
            process.arguments = arguments
            process.currentDirectoryURL = folder
            let terminal = FileHandle(fileDescriptor: side, closeOnDealloc: true)
            process.standardInput = terminal
            process.standardOutput = terminal
            process.standardError = terminal
            let reader = FileHandle(fileDescriptor: main, closeOnDealloc: true)
            do {
                try process.run()
            } catch {
                return (false, "")
            }
            try? terminal.close()
            if answers > 0 { reader.write(Data(String(repeating: "y\n", count: answers).utf8)) }
            var output = Data()
            // The terminal reports EIO once the command and its children have closed their side.
            while let chunk = try? reader.read(upToCount: 4096), !chunk.isEmpty { output.append(chunk) }
            process.waitUntilExit()
            return (process.terminationStatus == 0, String(decoding: output, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n"))
        }.value
    }
}

/// The Set Up sheet's accessory, on the informative text's leading edge: each agent's settings file, its middle cut when
/// long with the whole path as its tooltip, and its backup's name, then, under Show Details, the entries each file
/// gains and the command they run, in SF Mono 11.
private final class HookDetails: NSView {
    private static let width: CGFloat = 420
    private static let detailsHeight: CGFloat = 160
    /// NSAlert sets its accessory this far left of the informative text.
    private static let inset: CGFloat = 4

    private weak var alert: NSAlert?
    private let files: [NSTextField]
    private let summary: NSTextField
    private let disclosure = NSButton()
    private let label = NSTextField(labelWithString: "Show Details")
    private let details = NSScrollView()

    init(_ missing: [HookSetup.Missing], command: URL, alert: NSAlert) {
        self.alert = alert
        files = missing.map { item in
            let field = NSTextField(labelWithString: "\(item.agent): \((item.file as NSString).abbreviatingWithTildeInPath)")
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.lineBreakMode = .byTruncatingMiddle
            field.toolTip = item.file
            return field
        }
        let backup = ((missing[0].file as NSString).lastPathComponent) + ".dewline-backup-\(Int(Date().timeIntervalSince1970))"
        summary = NSTextField(wrappingLabelWithString: "Each file is copied first to a backup beside it, such as \(backup).")
        super.init(frame: .zero)
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.preferredMaxLayoutWidth = Self.width - Self.inset
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.title = ""
        disclosure.target = self
        disclosure.action = #selector(toggle)
        disclosure.setAccessibilityLabel("Show Details")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 4, height: 4)
        text.isVerticallyResizable = true
        text.autoresizingMask = .width
        text.string = missing.map { item in
            ([(item.file as NSString).abbreviatingWithTildeInPath + " gains:"] + item.entries.map { "  " + $0 }).joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n\nEach hook runs \u{201C}\(command.path) notify\u{201D}, which sends Dewline a file\u{2019}s path and hash, never its content."
        details.documentView = text
        details.hasVerticalScroller = true
        details.borderType = .bezelBorder
        details.isHidden = true
        for view in files + [summary, disclosure, label, details] { addSubview(view) }
        layOut()
    }

    required init?(coder: NSCoder) {
        fatalError("HookDetails is built in code")
    }

    @objc private func toggle() {
        details.isHidden = disclosure.state != .on
        label.stringValue = details.isHidden ? "Show Details" : "Hide Details"
        layOut()
        alert?.layout()
    }

    /// Stacks the files, the summary, the disclosure row and, when shown, the details, top down.
    private func layOut() {
        let x = Self.inset
        let width = Self.width - x
        let fileHeight = files.first?.intrinsicContentSize.height ?? 0
        let filesHeight = CGFloat(files.count) * fileHeight
        let summaryHeight = summary.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
        let row: CGFloat = 20
        let shown = details.isHidden ? 0 : Self.detailsHeight + 6
        let height = filesHeight + 8 + summaryHeight + 8 + row + shown
        setFrameSize(NSSize(width: Self.width, height: height))
        for (index, file) in files.enumerated() {
            file.frame = NSRect(x: x, y: height - CGFloat(index + 1) * fileHeight, width: width, height: fileHeight)
        }
        summary.frame = NSRect(x: x, y: height - filesHeight - 8 - summaryHeight, width: width, height: summaryHeight)
        let rowY = summary.frame.minY - 8 - row
        disclosure.frame = NSRect(x: x, y: rowY, width: 20, height: row)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: x + 22, y: rowY + (row - label.frame.height) / 2)
        details.frame = NSRect(x: x, y: 0, width: width, height: Self.detailsHeight)
        details.documentView?.frame.size.width = details.contentSize.width
    }
}
