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
        /// The hook events it lacks: "PreToolUse", "Stop".
        var events: [String] = []
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
            let events = line[line.index(after: colon)..<from.lowerBound].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            found.append(Missing(agent: String(agent), file: String(line[from.upperBound...]), events: events))
            last = found.count - 1
        }
        return found
    }

    /// What each kind of hook event is for, as docs/hooks.md says.
    private static let purposes: [(events: Set<String>, purpose: String)] = [
        (["PreToolUse", "PostToolUse", "PostToolUseFailure", "preToolUse", "postToolUse", "afterFileEdit"], "to name the agent behind each edit"),
        (["Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "stop"], "to mark where each turn ends"),
        (["InstructionsLoaded"], "to list the instruction files it loaded"),
    ]

    /// One line for each agent: the events it gains, grouped by what they are for.
    static func summary(_ missing: [Missing]) -> String {
        missing.map { item in
            var groups = purposes.compactMap { group in
                let events = item.events.filter(group.events.contains)
                return events.isEmpty ? nil : events.joined(separator: ", ") + " " + group.purpose
            }
            let other = item.events.filter { event in !purposes.contains { $0.events.contains(event) } }
            if !other.isEmpty { groups.append(other.joined(separator: ", ")) }
            return "\(item.agent): " + groups.joined(separator: "; ") + "."
        }.joined(separator: "\n")
    }

    /// True when the app runs from a disk image or a copy macOS translocated: a hook set up from here calls a path
    /// that is gone once the image ejects or the app quits.
    static func misplaced(_ bundle: URL = Bundle.main.bundleURL) -> Bool {
        let path = bundle.standardizedFileURL.path
        return path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    /// Asks to move the app into Applications and open it from there; Move copies it, quits, and opens the copy.
    static func offerMove(on window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Move Dewline to Applications"
        alert.informativeText = "Dewline is running from a disk image or a temporary copy. Agent hooks set up from here would stop working "
            + "once it\u{2019}s gone, so set them up after the move."
        alert.addButton(withTitle: "Move to Applications and Relaunch")
        alert.addButton(withTitle: "Not Now")
        present(alert, on: window) { response in
            if response == .alertFirstButtonReturn { moveToApplications(on: window) }
        }
    }

    /// Asks first when Applications already has a Dewline, and stops when that one is open.
    private static func moveToApplications(on window: NSWindow?) {
        let source = Bundle.main.bundleURL
        let target = URL(filePath: "/Applications", directoryHint: .isDirectory).appending(path: source.lastPathComponent)
        guard FileManager.default.fileExists(atPath: target.path) else { return copy(source, to: target) }
        let alert = NSAlert()
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.standardizedFileURL == target.standardizedFileURL }) {
            alert.messageText = "Dewline is open from Applications"
            alert.informativeText = "Quit it, then move this copy."
            return present(alert, on: window) { _ in }
        }
        let installed = Updates.versionOnDisk(at: target)?.version ?? "another version"
        let this = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "another version"
        alert.messageText = "Replace the Dewline in Applications?"
        alert.informativeText = "Applications has Dewline \(installed); this copy is \(this). The one in Applications moves to the Trash."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        present(alert, on: window) { response in
            if response == .alertFirstButtonReturn { copy(source, to: target, replacing: true) }
        }
    }

    /// Copies the app off the main thread, quits, and opens the copy.
    private static func copy(_ source: URL, to target: URL, replacing: Bool = false) {
        Task {
            do {
                try await Task.detached {
                    if replacing { try FileManager.default.trashItem(at: target, resultingItemURL: nil) }
                    try FileManager.default.copyItem(at: source, to: target)
                    // The copy keeps the download's quarantine, which would translocate it again.
                    let clear = Process()
                    clear.executableURL = URL(filePath: "/usr/bin/xattr")
                    clear.arguments = ["-dr", "com.apple.quarantine", target.path]
                    try clear.run()
                    clear.waitUntilExit()
                }.value
                // Opens the copy once this app has quit, so the two never hold the control socket at once. Gives up after
                // a minute, so a canceled quit doesn't open it later.
                let relaunch = Process()
                relaunch.executableURL = URL(filePath: "/bin/sh")
                relaunch.arguments = [
                    "-c", "i=0; while /bin/kill -0 \"$1\" 2>/dev/null; do [ $i -lt 300 ] || exit 0; /bin/sleep 0.2; i=$((i+1)); done; /usr/bin/open \"$2\"",
                    "sh", String(getpid()), target.path,
                ]
                try relaunch.run()
            } catch {
                NSApp.presentError(error)
                return
            }
            NSApp.terminate(nil)
        }
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
        guard !misplaced() else {
            offerMove(on: window)
            return done(false)
        }
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
                + "Adds one local command, dewline notify, in every project (your user settings):\n\n\(summary(missing))\n\n"
                + "It sends Dewline paths and hashes, never file content, and nothing leaves this Mac. Remove it any time in Settings > Agents."
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
