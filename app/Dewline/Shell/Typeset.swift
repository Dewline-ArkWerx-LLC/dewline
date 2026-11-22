import AppKit
import CryptoKit

/// Typst and LaTeX code files typeset with the user's own typst, latexmk or tectonic after Dewline saves them and after
/// an outside write lands, never on opening. The PDF and LaTeX's aux files go to the app's cache, never beside the
/// source. The status bar says how it went, with Go to Line for errors; File > Export copies the PDF.
@MainActor
enum Typeset {
    struct Diagnostic: Equatable, Sendable {
        let file: URL
        let line: Int
        let column: Int
        let error: Bool
        let message: String

        var place: String { "\(file.lastPathComponent):\(line)" }
    }

    enum Outcome: Sendable {
        case done(pdf: URL, [Diagnostic])
        case failed([Diagnostic], log: String)
        case missing(String)
    }

    /// Where the compilers are looked for, MacTeX's folder first, and the child's PATH.
    nonisolated static let folders = ["/Library/TeX/texbin", "/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/bin"]
        .map { ($0 as NSString).expandingTildeInPath }
    /// A compile still running after this is stopped.
    nonisolated static let limit = 120
    private static let message = "typeset"
    /// Each source's PDF from its last clean compile this session.
    private static var clean: [URL: URL] = [:]
    private static var running: [URL: Task<Void, Never>] = [:]
    /// Written again while its compile ran: it compiles once more after.
    private static var again: Set<URL> = []

    static func typesets(_ url: URL) -> Bool {
        CodeFile.language(of: url).map(CodeFile.typeset.contains) ?? false
    }

    /// The document's file was saved or took an outside write: compile it, or once more after the running compile.
    static func written(_ document: MarkdownDocument) {
        guard let url = document.fileURL?.standardizedFileURL, typesets(url) else { return }
        guard running[url] == nil else {
            again.insert(url)
            return
        }
        // Typst reads files under the window's folder only, or the file's own folder outside it.
        let folder = (document.windowControllers.first as? MainWindowController)?.folder?.url
        let root = folder.flatMap { url.path.hasPrefix($0.path + "/") ? $0 : nil } ?? url.deletingLastPathComponent()
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "dev.arkwerx.dewline/typeset")
            .appending(path: SHA256.hash(data: Data(url.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined())
        running[url] = Task {
            defer {
                running[url] = nil
                if again.remove(url) != nil { written(document) }
            }
            let outcome = await Task.detached { compile(url, root: root, into: cache) }.value
            report(outcome, for: url, in: document)
        }
    }

    /// File > Export… for a Typst or LaTeX document: a PDF-only save panel that copies its last clean PDF, compiling
    /// first when there is none.
    static func export(_ document: MarkdownDocument, in window: NSWindow) {
        guard let url = document.fileURL?.standardizedFileURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent
        panel.directoryURL = url.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let target = panel.url else { return }
            Task { @MainActor in
                if clean[url] == nil {
                    written(document)
                    await running[url]?.value
                }
                // A failed compile said why in the status bar.
                guard let pdf = clean[url] else { return }
                do {
                    try Data(contentsOf: pdf).write(to: target, options: .atomic)
                    Export.exported(target)
                } catch {
                    document.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
                }
            }
        }
    }

    private static func report(_ outcome: Outcome, for url: URL, in document: MarkdownDocument) {
        let window = document.windowControllers.first?.window
        let numbers = document.textView?.enclosingScrollView?.verticalRulerView as? LineNumbers
        switch outcome {
        case .missing(let text):
            clean[url] = nil
            numbers?.errors = [:]
            StatusBar.post(.init(id: message, kind: .setup, text: text), in: window)
        case .failed(let diagnostics, let log):
            clean[url] = nil
            let errors = diagnostics.filter(\.error)
            numbers?.errors = Dictionary(errors.filter { $0.file == url }.map { ($0.line, $0.message) }) { first, _ in first }
            let last = log.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            var text = errors.first.map { "\(count(errors.count, "error")) \u{00B7} \($0.place) \($0.message)" } ?? "Typesetting failed: \(last)"
            var actions = actions(errors, from: window)
            // The first error on a line inside a marked change names its writer, and Revert Change takes the change out.
            if let first = errors.first, first.file == url, let live = document.live, let marked = change(at: first.line, in: live) {
                text += " in \(EarlierVersions.writer(marked.1.origin))\u{2019}s change"
                actions.insert(.init(title: "Revert Change") { [weak live] _ in live?.revert(marked.0) }, at: 0)
            }
            StatusBar.post(.init(id: message, kind: .problem, text: text, actions: actions), in: window)
        case .done(let pdf, let warnings):
            clean[url] = pdf
            numbers?.errors = [:]
            let open = StatusBar.Message.Action(title: "Open PDF") { _ in NSWorkspace.shared.open(pdf) }
            if let first = warnings.first {
                let text = "\(count(warnings.count, "warning")) \u{00B7} \(first.place) \(first.message)"
                StatusBar.post(.init(id: message, kind: .info, text: text, actions: [open] + actions(warnings, from: window)), in: window)
            } else {
                StatusBar.post(.init(id: message, kind: .result, text: "Typeset \u{201C}\(pdf.lastPathComponent)\u{201D}", actions: [open], untilTyping: true), in: window)
            }
        }
    }

    /// The marked change whose lines hold `line`, counting from 1.
    private static func change(at line: Int, in live: LiveFile) -> (UInt64, LiveFile.Change)? {
        guard let text = live.text else { return nil }
        return live.changes.first { id, change in
            guard change.marked, !change.conflict else { return false }
            let range = NSIntersectionRange(change.range, NSRange(location: 0, length: text.length))
            let start = live.line(id)
            let end = start + text.substring(with: range).trimmingCharacters(in: .newlines).count { $0.isNewline }
            return (start...end).contains(line)
        }.map { ($0.key, $0.value) }
    }

    private static func count(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// Go to Line for the first diagnostic and, for more than one, a menu of them all.
    private static func actions(_ diagnostics: [Diagnostic], from window: NSWindow?) -> [StatusBar.Message.Action] {
        guard let first = diagnostics.first else { return [] }
        var actions = [StatusBar.Message.Action(title: "Go to Line") { _ in show(first, from: window) }]
        if diagnostics.count > 1 {
            actions.append(.init(title: "All \(diagnostics.count)") { view in
                let picker = Picker(diagnostics, window: window)
                let menu = NSMenu()
                for (index, diagnostic) in diagnostics.enumerated() {
                    let item = menu.addItem(withTitle: "\(diagnostic.place) \(diagnostic.message)", action: #selector(Picker.picked(_:)), keyEquivalent: "")
                    item.tag = index
                    item.target = picker
                }
                withExtendedLifetime(picker) { _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view) }
            })
        }
        return actions
    }

    /// Opens the diagnostic's file, in another tab when it isn't this one, and moves the caret to its line.
    static func show(_ diagnostic: Diagnostic, from window: NSWindow?) {
        (window?.windowController as? MainWindowController)?.open(diagnostic.file, newTab: true)
        guard let tab = NSDocumentController.shared.document(for: diagnostic.file)?.windowControllers.first as? MainWindowController,
            let textView = tab.textView
        else { return }
        tab.window?.makeFirstResponder(textView)
        textView.jump(toLine: diagnostic.line, column: diagnostic.column)
    }

    /// A compiler run: `program` with `arguments` in `folder`, with `environment` over the app's own.
    struct Job: Sendable {
        let program: String
        let arguments: [String]
        let folder: URL
        let environment: [String: String]
    }

    /// Compiles `source` (a .tex file's `% !TEX root`) with the first compiler found into `cache`, keeping the last
    /// clean PDF there.
    nonisolated static func compile(_ source: URL, root: URL, into cache: URL) -> Outcome {
        let build = cache.appending(path: "build", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let typst = source.pathExtension.lowercased() == "typ"
        guard let file = typst ? source : main(of: source, in: root) else {
            return .failed([], log: "% !TEX root is outside the folder")
        }
        guard var job = job(file, root: root, build: build, find: find) else {
            return .missing(typst ? "Typesetting .typ needs typst: brew install typst" : "Typesetting .tex needs MacTeX or tectonic: brew install tectonic")
        }
        if job.program.hasSuffix("/latexmk"), !plain(source.lastPathComponent) || !plain(file.lastPathComponent) {
            return .failed([], log: "Rename the file to typeset it: only letters, digits, space, dot, dash and underscore")
        }
        try? FileManager.default.createDirectory(at: build.appending(path: "tmp"), withIntermediateDirectories: true)
        job = sandboxed(job, file: file, root: root, build: build)
        let folder = job.folder
        let environment = ProcessInfo.processInfo.environment.merging(["PATH": folders.joined(separator: ":")]) { $1 }.merging(job.environment) { $1 }
        let run: Run
        do {
            run = try spawn(job.program, job.arguments, in: folder, environment: environment)
        } catch {
            return .failed([], log: error.localizedDescription)
        }
        let diagnostics = parse(run.log, in: folder)
        if run.stopped {
            return .failed(diagnostics, log: "it ran over \(limit) seconds and was stopped")
        }
        let name = file.deletingPathExtension().lastPathComponent + ".pdf"
        let built = build.appending(path: name)
        guard run.status == 0, FileManager.default.fileExists(atPath: built.path) else {
            return .failed(diagnostics, log: run.log)
        }
        let pdf = cache.appending(path: name)
        do {
            try? FileManager.default.removeItem(at: pdf)
            try FileManager.default.moveItem(at: built, to: pdf)
        } catch {
            return .failed(diagnostics, log: error.localizedDescription)
        }
        return .done(pdf: pdf, diagnostics)
    }

    private struct Run: Sendable {
        let log: String
        let status: Int32
        let stopped: Bool
    }

    /// Runs `program` in a process group of its own with stdout and stderr in one pipe, keeping the first MB of output.
    /// Past `limit` seconds the group gets SIGTERM, then SIGKILL; whatever is left in it when the compiler ends is killed
    /// too, and the pipe is closed after two more seconds, so no child can keep the compile from finishing.
    private nonisolated static func spawn(_ program: String, _ arguments: [String], in folder: URL, environment: [String: String]) throws -> Run {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let (reading, writing) = (fds[0], fds[1])
        _ = fcntl(reading, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writing, F_SETFD, FD_CLOEXEC)
        _ = fcntl(reading, F_SETFL, O_NONBLOCK)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writing, 1)
        posix_spawn_file_actions_adddup2(&actions, writing, 2)
        posix_spawn_file_actions_addchdir(&actions, folder.path)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        var signals = sigset_t()
        sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attributes, &signals)
        sigaddset(&signals, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &signals)
        let argv = ([program] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, program, &actions, &attributes, argv, envp)
        close(writing)
        guard spawned == 0 else {
            close(reading)
            throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO)
        }

        nonisolated(unsafe) var output = Data()
        let drained = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeReadSource(fileDescriptor: reading, queue: DispatchQueue(label: "dev.arkwerx.dewline.typeset"))
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = read(reading, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer.prefix(min(count, max(0, 1_048_576 - output.count))))
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                source.cancel()
            }
        }
        source.setCancelHandler {
            close(reading)
            drained.signal()
        }
        source.resume()

        // Waits without reaping, so the group's id can't be reused before the sweep below.
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [pid] in
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
            exited.signal()
        }
        func ended(within seconds: Int) -> Bool {
            exited.wait(timeout: .now() + .seconds(seconds)) == .success
        }
        var gone = ended(within: limit)
        let stopped = !gone
        if stopped {
            killpg(pid, SIGTERM)
            gone = ended(within: 2)
            if !gone {
                killpg(pid, SIGKILL)
                gone = ended(within: 2)
            }
        }
        killpg(pid, SIGKILL)
        var status: Int32 = -1
        if gone { _ = waitpid(pid, &status, 0) }
        if drained.wait(timeout: .now() + .seconds(2)) == .timedOut {
            source.cancel()
            drained.wait()
        }
        return Run(log: String(decoding: output, as: UTF8.self), status: status, stopped: stopped)
    }

    /// How `file` typesets into `build` with the first compiler `find` locates, or nil when there is none: typst
    /// confined to `root`; latexmk without any rc file (a repo's .latexmkrc is Perl) or bibtex, biber and makeindex, each
    /// engine without shell escape, and TeX opening no absolute or parent-folder path outside `build`; tectonic untrusted.
    nonisolated static func job(_ file: URL, root: URL, build: URL, find: (String) -> String?) -> Job? {
        if file.pathExtension.lowercased() == "typ" {
            guard let typst = find("typst") else { return nil }
            let pdf = build.appending(path: file.deletingPathExtension().lastPathComponent + ".pdf")
            return Job(program: typst, arguments: ["compile", "--root", root.path, "--diagnostic-format", "short", file.path, pdf.path], folder: root, environment: [:])
        }
        let folder = file.deletingLastPathComponent()
        if let latexmk = find("latexmk") {
            let engine = ["xelatex": "-xelatex", "lualatex": "-lualatex"][magic("program", in: file)?.lowercased() ?? ""] ?? "-pdf"
            let engines = [
                "-pdflatex=pdflatex -no-shell-escape %O %S", "-xelatex=xelatex -no-shell-escape %O %S",
                "-lualatex=lualatex -no-shell-escape --safer --nosocket %O %S",
            ]
            let arguments = ["-norc", "-bibtex-", "-e", "$makeindex = 'NONE'", engine] + engines + ["-interaction=nonstopmode", "-file-line-error", "-outdir=\(build.path)", "./" + file.lastPathComponent]
            return Job(program: latexmk, arguments: arguments, folder: folder, environment: ["openin_any": "p", "openout_any": "p", "TEXMFOUTPUT": build.path])
        }
        if let tectonic = find("tectonic") {
            return Job(program: tectonic, arguments: ["-X", "compile", "--untrusted", "--keep-logs", "--outdir", build.path, file.lastPathComponent], folder: folder, environment: [:])
        }
        return nil
    }

    /// latexmk hands file names to a shell: a name it takes has only letters, digits, space, dot, dash and underscore, and
    /// no leading dash.
    nonisolated static func plain(_ name: String) -> Bool {
        !name.hasPrefix("-") && name.wholeMatch(of: /[A-Za-z0-9._ -]+/) != nil
    }

    /// `job` under sandbox-exec. It runs programs from the toolchain folders and sh, perl and env only, sends no Apple
    /// events and can't ask Launch Services to open anything. It reads system and TeX folders, `root` and `build`, and
    /// in home only the TeX, Tectonic, typst and font folders; a root at or above home narrows to `file`'s folder, or
    /// to `file` itself. The sandbox checks a symlink's target, so a link in the folder can't pull an outside file into
    /// the PDF. It writes only `build`, its own temporary folder there, and those caches. Only typst and tectonic reach
    /// the network, over HTTPS, for packages and bundles. Paths go in as parameters, never into the profile's text.
    nonisolated static func sandboxed(_ job: Job, file: URL, root: URL, build: URL) -> Job {
        let online = ["typst", "tectonic"].contains(URL(filePath: job.program).lastPathComponent)
        let home = real(URL(filePath: NSHomeDirectory())) ?? NSHomeDirectory()
        let reads = [root, file.deletingLastPathComponent(), file].map { real($0) ?? $0.path }
            .first { !(home + "/").hasPrefix($0 == "/" ? "/" : $0 + "/") } ?? file.path
        let paths = [("ROOT", reads), ("BUILD", real(build) ?? build.path), ("HOME", home), ("PROGRAM", real(URL(filePath: job.program)) ?? job.program)]
        let profile = online ? profile + "\n" + network : profile
        let environment = job.environment.merging(["TMPDIR": build.appending(path: "tmp").path]) { $1 }
        return Job(program: "/usr/bin/sandbox-exec", arguments: ["-p", profile] + paths.flatMap { ["-D", "\($0)=\($1)"] } + [job.program] + job.arguments, folder: job.folder, environment: environment)
    }

    private nonisolated static let profile = """
        (version 1)
        (allow default)
        (deny file-read* file-write* network* process-exec appleevent-send)
        (deny mach-lookup (global-name "com.apple.coreservices.launchservicesd") (global-name "com.apple.lsd.mapdb"))
        (allow process-exec (subpath "/Library/TeX") (subpath "/usr/local/texlive") (subpath "/opt/homebrew/bin")
            (subpath "/opt/homebrew/Cellar") (subpath "/usr/local/bin") (subpath "/usr/local/Cellar") (literal "/bin/sh")
            (literal "/bin/bash") (literal "/bin/zsh") (literal "/bin/dash") (literal "/usr/bin/perl") (literal "/usr/bin/env")
            (literal (param "PROGRAM")))
        (deny process-exec (literal "/bin/launchctl") (literal "/usr/bin/open") (literal "/usr/bin/osascript") (literal "/usr/bin/xpcproxy"))
        (allow file-read-metadata)
        (allow file-read* (literal "/") (subpath "/Library/TeX") (subpath "/Library/Fonts") (subpath "/usr") (subpath "/bin")
            (subpath "/opt/homebrew") (subpath "/System") (subpath "/private/etc") (subpath "/dev") (subpath "/private/var/db/dyld")
            (subpath "/private/var/db/timezone") (subpath (param "ROOT")) (literal (param "PROGRAM"))
            (subpath (string-append (param "HOME") "/Library/texmf"))
            (subpath (string-append (param "HOME") "/Library/Fonts"))
            (subpath (string-append (param "HOME") "/Library/Application Support/typst")))
        (allow file-read* file-write* (subpath (param "BUILD"))
            (prefix (string-append (param "HOME") "/.texlive"))
            (subpath (string-append (param "HOME") "/Library/texlive"))
            (subpath (string-append (param "HOME") "/Library/Caches/Tectonic"))
            (subpath (string-append (param "HOME") "/Library/Caches/typst")))
        (allow file-write* (literal "/dev/null"))
        """
    private nonisolated static let network = """
        (allow network-outbound (remote tcp "*:443") (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))
        """

    /// The file a .tex `source` typesets: itself, or its `% !TEX root` when that resolves, symlinks and all, inside
    /// `root`; nil when it doesn't.
    nonisolated static func main(of source: URL, in root: URL) -> URL? {
        guard let name = magic("root", in: source) else { return source }
        let file = source.deletingLastPathComponent().appending(path: name).standardizedFileURL
        guard let folder = real(root), let path = real(file), path.hasPrefix(folder + "/") else { return nil }
        return file
    }

    private nonisolated static func real(_ url: URL) -> String? {
        guard let path = realpath(url.path, nil) else { return nil }
        defer { free(path) }
        return String(cString: path)
    }

    private nonisolated static func find(_ program: String) -> String? {
        folders.map { "\($0)/\(program)" }.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    /// The value of a `% !TEX key = value` line in the first 20 lines of `file`.
    private nonisolated static func magic(_ key: String, in file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline).prefix(20) {
            guard let match = line.wholeMatch(of: /\s*%\s*!TEX\s+(\w+)\s*=\s*(.+?)\s*/.ignoresCase()),
                match.1.lowercased() == key
            else { continue }
            return String(match.2)
        }
        return nil
    }

    /// The errors and warnings in a compiler's output, once each: typst's `a.typ:3:15: error: message`, tectonic's
    /// `error: a.tex:12: message`, and LaTeX's `-file-line-error` `./a.tex:12: message`.
    nonisolated static func parse(_ log: String, in folder: URL) -> [Diagnostic] {
        func url(_ path: Substring) -> URL {
            (path.hasPrefix("/") ? URL(filePath: String(path)) : folder.appending(path: String(path))).standardizedFileURL
        }
        var found: [Diagnostic] = []
        for line in log.split(whereSeparator: \.isNewline) {
            let diagnostic: Diagnostic
            if let match = line.wholeMatch(of: /(.+?):(\d+):(\d+): (error|warning): (.+)/) {
                diagnostic = Diagnostic(file: url(match.1), line: Int(match.2) ?? 1, column: Int(match.3) ?? 1, error: match.4 == "error", message: String(match.5))
            } else if let match = line.wholeMatch(of: /(error|warning): (.+?):(\d+): (.+)/) {
                diagnostic = Diagnostic(file: url(match.2), line: Int(match.3) ?? 1, column: 1, error: match.1 == "error", message: String(match.4))
            } else if let match = line.wholeMatch(of: /(.+?\.(?:tex|sty|cls|ltx)):(\d+): (.+)/) {
                diagnostic = Diagnostic(file: url(match.1), line: Int(match.2) ?? 1, column: 1, error: true, message: String(match.3))
            } else {
                continue
            }
            if !found.contains(diagnostic) { found.append(diagnostic) }
        }
        return found
    }
}

/// The target of the status bar's diagnostics menu.
@MainActor
private final class Picker: NSObject {
    private let diagnostics: [Typeset.Diagnostic]
    private weak var window: NSWindow?

    init(_ diagnostics: [Typeset.Diagnostic], window: NSWindow?) {
        self.diagnostics = diagnostics
        self.window = window
    }

    @objc func picked(_ sender: NSMenuItem) {
        Typeset.show(diagnostics[sender.tag], from: window)
    }
}
