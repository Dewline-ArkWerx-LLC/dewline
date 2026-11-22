import AppKit
import DiskArbitration

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

    /// Where a bundle sits, as the Move window asks: the original of a translocated copy, the volume holding a path,
    /// and whether DiskArbitration calls a volume a disk image. Tests stand in their own.
    struct Placement {
        var original: (URL) -> URL? = HookSetup.translocatedOriginal
        var volume: (URL) -> URL? = { try? $0.resourceValues(forKeys: [.volumeURLKey]).volume }
        var isDiskImage: (URL) -> Bool = HookSetup.isDiskImage
    }

    /// True when the app runs from a disk image or a copy macOS translocated: a hook set up from here calls a path
    /// that is gone once the image ejects or the app quits. An external drive or a share is where it belongs.
    static func misplaced(_ bundle: URL = Bundle.main.bundleURL, placement: Placement = Placement()) -> Bool {
        placement.original(bundle) != nil || diskImage(holding: bundle, placement: placement) != nil
    }

    /// The disk image volume to eject after a move: the one holding the bundle, or a translocated copy's original.
    static func diskImage(holding bundle: URL, placement: Placement = Placement()) -> URL? {
        guard let volume = placement.volume(placement.original(bundle) ?? bundle), placement.isDiskImage(volume) else { return nil }
        return volume
    }

    /// DiskArbitration's device model for a mounted image.
    nonisolated static func isDiskImage(_ volume: URL) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault), let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL),
            let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return false }
        return (description[kDADiskDescriptionDeviceModelKey as String] as? String)?.trimmingCharacters(in: .whitespaces) == "Disk Image"
    }

    private typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
    private typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    /// The original of a copy macOS translocated, from Security's SecTranslocate calls, looked up at run time as Sparkle
    /// does; nil for a bundle that runs where it is.
    nonisolated static func translocatedOriginal(_ bundle: URL) -> URL? {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
            let isSymbol = dlsym(security, "SecTranslocateIsTranslocatedURL"), let originalSymbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL")
        else { return nil }
        var translocated = false
        guard unsafeBitCast(isSymbol, to: IsTranslocated.self)(bundle as CFURL, &translocated, nil), translocated else { return nil }
        return unsafeBitCast(originalSymbol, to: OriginalPath.self)(bundle as CFURL, nil)?.takeRetainedValue() as URL?
    }

    /// Where Move puts the app: Applications, or the one in the home folder when this account can't write there.
    static func moveTarget(
        for bundle: URL = Bundle.main.bundleURL, home: URL = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory),
        canWrite: (String) -> Bool = FileManager.default.isWritableFile(atPath:)
    ) -> URL {
        let folder = canWrite("/Applications") ? URL(filePath: "/Applications", directoryHint: .isDirectory) : home.appending(path: "Applications", directoryHint: .isDirectory)
        return folder.appending(path: bundle.lastPathComponent)
    }

    /// The Move window, which moves the app into Applications and opens it from there.
    static func offerMove(on window: NSWindow?) {
        MoveWindowController.show()
    }

    /// Asks first when Applications already has a Dewline, and stops when that one is open. `moving` runs as the copy
    /// starts and says how long its picture needs, which the quit waits for; `failed` runs when nothing moved.
    static func moveToApplications(
        on window: NSWindow?, moving: @escaping @MainActor () -> Duration = { .zero }, failed: @escaping @MainActor () -> Void = {}
    ) {
        let source = Bundle.main.bundleURL
        let target = moveTarget(for: source)
        let eject = diskImage(holding: source)
        guard FileManager.default.fileExists(atPath: target.path) else { return copy(source, to: target, eject: eject, moving: moving, failed: failed) }
        let alert = NSAlert()
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.standardizedFileURL == target.standardizedFileURL }) {
            alert.messageText = "Dewline is open from Applications"
            alert.informativeText = "Quit it, then move this copy."
            return present(alert, on: window) { _ in failed() }
        }
        let installed = Updates.versionOnDisk(at: target)?.version ?? "another version"
        let this = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "another version"
        alert.messageText = "Replace the Dewline in Applications?"
        alert.informativeText = "Applications has Dewline \(installed); this copy is \(this). The one in Applications moves to the Trash."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        present(alert, on: window) { response in
            guard response == .alertFirstButtonReturn else { return failed() }
            copy(source, to: target, replacing: true, eject: eject, moving: moving, failed: failed)
        }
    }

    /// Copies the app off the main thread, quits, and opens the copy, then ejects `eject`, the disk image it ran from.
    private static func copy(
        _ source: URL, to target: URL, replacing: Bool = false, eject: URL?, moving: @MainActor () -> Duration, failed: @escaping @MainActor () -> Void
    ) {
        let shown = ContinuousClock.now + moving()
        Task {
            do {
                try await Task.detached {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
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
                // a minute, so a canceled quit doesn't open it later. Then ejects the disk image, retrying once when it is
                // busy (Spotlight holds a fresh mount), and gives up quietly.
                let relaunch = Process()
                relaunch.executableURL = URL(filePath: "/bin/sh")
                relaunch.arguments = [
                    "-c", "i=0; while /bin/kill -0 \"$1\" 2>/dev/null; do [ $i -lt 300 ] || exit 0; /bin/sleep 0.2; i=$((i+1)); done; /usr/bin/open \"$2\"; "
                        + "[ -n \"$3\" ] || exit 0; /usr/sbin/diskutil eject \"$3\" >/dev/null 2>&1 || { /bin/sleep 1; /usr/sbin/diskutil eject \"$3\" >/dev/null 2>&1; }",
                    "sh", String(getpid()), target.path, eject?.path ?? "",
                ]
                try relaunch.run()
            } catch {
                NSApp.presentError(error)
                return failed()
            }
            try? await Task.sleep(until: shown)
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
    /// Folders opened from the guide's setup list, whose hooks row already asked this launch.
    static var askedThisLaunch: Set<String> = []

    /// The changes no hook named, made outside a shell command: ones hooks would have named. The offer waits until one
    /// of them is kept or reverted, so it comes once the user has seen why hooks matter and doesn't cover the change.
    static func unnamedEdits(in changes: [UInt64: LiveFile.Change]) -> Set<UInt64> {
        Set(changes.filter { $0.value.marked && $0.value.origin == .external && !$0.value.shell }.keys)
    }

    /// Offers Set Up on `window` if an agent's hooks are missing, once for each folder that holds an agent's files;
    /// doctor reads `folder`'s project settings too. Its window asks once an unnamed edit in a note there is kept or
    /// reverted. A folder counts as checked once doctor has run and found nothing missing or the sheet has shown, so Not
    /// Now holds for that folder only.
    static func offer(on window: NSWindow, in folder: URL) {
        let key = folder.path
        // While the guide runs it is the one thing asking; a later edit offers.
        guard WelcomeGuide.running == nil, !checking.contains(key), !askedThisLaunch.contains(key), !UserDefaults.standard.bool(forKey: declinedKey),
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
            alert.informativeText = scope(missing, in: folder) + "\n\n"
                + "Hooks send file paths and hashes, never content, and nothing leaves this Mac. Remove them any time in Settings > Agents."
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

    /// The files Add Hooks changes and how far each reaches: "Adds 2 entries to ~/.claude/settings.json (every
    /// project). Backup saved beside it." A file inside `folder` holds that project's settings.
    static func scope(_ missing: [Missing], in folder: URL?) -> String {
        let lines = missing.map { item in
            let count = item.entries.count == 1 ? "1 entry" : "\(item.entries.count) entries"
            let project = folder.map { item.file.hasPrefix($0.standardizedFileURL.path + "/") } ?? false
            return "Adds \(count) to \((item.file as NSString).abbreviatingWithTildeInPath) (\(project ? "this project only" : "every project"))."
        }
        return (lines + [missing.count == 1 ? "Backup saved beside it." : "Backups saved beside each."]).joined(separator: "\n")
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

/// The Set Up sheet's accessory, on the informative text's leading edge: Show Details, which opens, in SF Mono 11, the
/// events each agent gains and what for, each settings file with its backup's name, the entries it gains and the
/// command they run.
private final class HookDetails: NSView {
    private static let width: CGFloat = 420
    private static let detailsHeight: CGFloat = 180
    /// NSAlert sets its accessory this far left of the informative text.
    private static let inset: CGFloat = 4

    private weak var alert: NSAlert?
    private let disclosure = NSButton()
    private let label = NSTextField(labelWithString: "Show Details")
    private let details = NSScrollView()

    init(_ missing: [HookSetup.Missing], command: URL, alert: NSAlert) {
        self.alert = alert
        super.init(frame: .zero)
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
        let epoch = Int(Date().timeIntervalSince1970)
        text.string = HookSetup.summary(missing) + "\n\n" + missing.map { item in
            let file = (item.file as NSString).abbreviatingWithTildeInPath
            let backup = (item.file as NSString).lastPathComponent + ".dewline-backup-\(epoch)"
            return ([file + ", backed up first as " + backup + ", gains:"] + item.entries.map { "  " + $0 }).joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n\nEach hook runs \u{201C}\((command.path as NSString).abbreviatingWithTildeInPath) notify\u{201D}, which sends Dewline a file\u{2019}s path and hash, never its content."
        details.documentView = text
        details.hasVerticalScroller = true
        details.borderType = .bezelBorder
        details.isHidden = true
        for view in [disclosure, label, details] { addSubview(view) }
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

    /// The disclosure row, then, when shown, the details under it.
    private func layOut() {
        let x = Self.inset
        let width = Self.width - x
        let row: CGFloat = 20
        let height = row + (details.isHidden ? 0 : Self.detailsHeight + 6)
        setFrameSize(NSSize(width: Self.width, height: height))
        let rowY = height - row
        disclosure.frame = NSRect(x: x, y: rowY, width: 20, height: row)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: x + 22, y: rowY + (row - label.frame.height) / 2)
        details.frame = NSRect(x: x, y: 0, width: width, height: Self.detailsHeight)
        details.documentView?.frame.size.width = details.contentSize.width
    }
}
