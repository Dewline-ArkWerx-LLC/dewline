import AppKit
import MdCore
import os

/// A document's file as the change engine keeps it: watched, with outside writes landed into the editor and saves
/// made through the engine. Engine calls other than `commit` run off the main thread, one at a time.
@MainActor
final class LiveFile {
    /// A landed change or conflict, by its live range in the buffer.
    struct Change: Equatable {
        var range: NSRange
        var origin: ChangeEngine.Origin
        var marked: Bool
        let conflict: Bool
        /// The text the change took out, which shows struck under its line.
        var removed = ""
        /// A conflict's other version.
        var theirs = ""
        /// Landed unnamed while Claude Code ran a shell command.
        var shell = false
        /// Revert was refused for text typed inside it, until you edit it again.
        var refused = false
    }

    let engine: ChangeEngine
    let doc: UInt64
    private(set) var url: URL
    /// Changes and conflicts until they are decided.
    private(set) var changes: [UInt64: Change] = [:] {
        didSet {
            guard oldValue != changes else { return }
            document?.textView?.marks.update(changes)
            NotificationCenter.default.post(name: Self.changesDidChange, object: self)
        }
    }
    static let changesDidChange = Notification.Name("LiveFileChangesDidChange")
    /// The file's snapshots, newest first, as last read off the main thread for the Snapshots menu.
    private(set) var snapshots: [ChangeEngine.Snapshot] = []
    /// Why the last autosave wrote nothing, until one writes.
    private(set) var refusal: ChangeEngine.Refusal? {
        didSet {
            guard oldValue != refusal else { return }
            NotificationCenter.default.post(name: Self.changesDidChange, object: self)
        }
    }
    /// Text a refused save kept before the file opened, other than the file's, until you restore or discard it.
    private(set) var draft: ChangeEngine.Snapshot? {
        didSet {
            guard oldValue != draft else { return }
            NotificationCenter.default.post(name: Self.changesDidChange, object: self)
        }
    }
    private var gitdir: URL?
    private weak var document: MarkdownDocument?
    private let queue = DispatchQueue(label: "dev.arkwerx.dewline.engine", qos: .utility)
    private var sources: [any DispatchSourceFileSystemObject] = []
    private var debounce: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var autosaving: Task<Void, Never>?
    /// The first edit since the last autosave ran.
    private(set) var unsavedSince: ContinuousClock.Instant?
    /// Refused autosaves in a row, which space their retries.
    private var retries = 0
    private var refreshing: Task<Void, Never>?
    private var refreshAgain = false
    /// A landing waits for a composition or Writing Tools session to end.
    private var landingWaits = false
    /// The engine refused the last autosave; it runs again when the refusing state ends.
    private var autosaveRefused = false
    private var applying = false
    /// `keepMarks` waits for the main thread's current work.
    private var keepsMarks = false
    private var closed = false
    /// Opened over a change made while the file was closed: the change lands once a text view shows it.
    private var landsWrite: Bool
    /// The changes left undecided when the file last closed, marked once a text view shows them.
    private var restored: [ChangeEngine.Mark]
    private weak var textView: EditorTextView?
    private nonisolated static let log = Logger(subsystem: "dev.arkwerx.dewline", category: "engine")

    init(
        engine: ChangeEngine, doc: UInt64, url: URL, gitdir: URL?, document: MarkdownDocument, closedWrite: Bool = false,
        marks: [ChangeEngine.Mark] = []
    ) {
        self.engine = engine
        self.doc = doc
        self.url = url
        self.document = document
        landsWrite = closedWrite
        restored = marks
        Self.open[Key(engine, doc)] = self
        watchGit(gitdir)
        arm()
        reloadSnapshots()
        // Opening took the file off the list of files changed while closed.
        ClosedChanges.refresh()
        // Before any save, which runs on the same queue.
        queue.async { [weak self] in
            let draft = try? engine.draft(doc)
            Task { @MainActor in self?.draft = draft }
        }
    }

    /// Follows the editor's edits and input sessions.
    func attach(_ textView: EditorTextView) {
        textView.marks.live = self
        textView.edited = { [weak self] range, delta in self?.edited(range, delta: delta) }
        textView.inputEnded = { [weak self] in self?.inputEnded() }
        self.textView = textView
        if !restored.isEmpty {
            changes = Dictionary(uniqueKeysWithValues: restored.map {
                ($0.change, Change(range: $0.range, origin: $0.origin, marked: true, conflict: false, removed: $0.removed))
            })
            restored = []
        }
        if landsWrite {
            landsWrite = false
            Task { await refresh() }
        }
    }

    func close() {
        let keep = keepingMarks()
        closed = true
        Self.open[Key(engine, doc)] = nil
        watchGit(nil)
        for source in sources { source.cancel() }
        sources = []
        for task in [debounce, retry, autosaving] { task?.cancel() }
        let (engine, doc) = (engine, doc)
        queue.async {
            keep()
            engine.close(doc)
        }
    }

    /// Before the app quits: keeps every open file's undecided changes for the next launch.
    static func keepAllMarks() {
        for live in open.values {
            live.queue.sync(execute: live.keepingMarks())
        }
    }

    /// Keeps the undecided changes with the engine once the current main-thread work ends, so a crash or force quit
    /// leaves them marked the next time the file opens. Only a buffer that is the file keeps them; a save that follows
    /// an edit keeps them again.
    private func keepMarks() {
        guard !keepsMarks else { return }
        keepsMarks = true
        Task { [weak self] in
            guard let self, !self.closed else { return }
            keepsMarks = false
            queue.async(execute: keepingMarks())
        }
    }

    /// Keeps the buffer's undecided changes with the engine, to run off the main thread, so they show again the next
    /// time the file opens.
    private func keepingMarks() -> @Sendable () -> Void {
        let (engine, doc) = (engine, doc)
        let buffer = (document?.textView ?? textView)?.string
        let ranges = changes.filter { $0.value.marked && !$0.value.conflict }.mapValues(\.range)
        return {
            guard let buffer else { return }
            do throws(ChangeEngine.Failure) {
                try engine.keepMarks(doc, buffer: buffer, ranges: ranges)
            } catch {
                Self.log.error("A file's undecided changes were not kept: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The file is now at `url`.
    func moved(to url: URL) {
        guard url.standardizedFileURL != self.url.standardizedFileURL else { return }
        self.url = url
        arm()
        let (engine, doc) = (engine, doc)
        queue.async { [weak self] in
            let result = Result { () throws(ChangeEngine.Failure) in try engine.moved(doc, to: url) }
            Task { @MainActor in
                guard let self, !self.closed else { return }
                switch result {
                case .success(let gitdir): self.watchGit(gitdir)
                case .failure(let error):
                    Self.log.error("The engine lost a moved file: \(String(describing: error), privacy: .public)")
                }
                self.reloadSnapshots()
            }
        }
    }

    // MARK: Claims and git

    private struct Key: Hashable {
        let engine: ObjectIdentifier
        let doc: UInt64

        init(_ engine: ChangeEngine, _ doc: UInt64) {
            self.engine = ObjectIdentifier(engine)
            self.doc = doc
        }
    }

    /// Open files by engine and document, since claims and git name documents.
    private static var open: [Key: LiveFile] = [:]
    static let claims = DispatchQueue(label: "dev.arkwerx.dewline.claims", qos: .utility)

    /// Sends a hook's claim to `engine` and acts on what it changed.
    static func claim(_ claim: ControlSocket.Claim, engine: ChangeEngine) {
        // The engine parses the line's fields again; Stop stands for every turn's end.
        let (event, use, path): (String, ControlSocket.Claim.ToolUse?, String?)
        switch claim.event {
        case .preToolUse(let call): (event, use, path) = ("PreToolUse", call, call.path)
        case .postToolUse(let call): (event, use, path) = ("PostToolUse", call, call.path)
        case .instructionsLoaded(let file): (event, use, path) = ("InstructionsLoaded", nil, file)
        case .shell(let id, let cwd, let ended): return shell(id, session: claim.session, cwd: cwd, ended: ended)
        case .turnEnd: (event, use, path) = ("Stop", nil, nil)
        case .sessionEnd: (event, use, path) = ("SessionEnd", nil, nil)
        }
        if claim.event == .turnEnd || claim.event == .sessionEnd {
            let now = ContinuousClock.now
            for (id, shell) in shells where shell.session == claim.session && shell.end == nil { shells[id]?.end = now }
        }
        claims.async {
            // A Read declares nothing and writes nothing.
            if case .preToolUse(let use) = claim.event, use.tool != .read, let hash = use.hash, let declared = use.declared {
                closedWrite(use.path, hash: hash, declared: declared, by: claim, engine: engine)
            }
            let updates = engine.claim(
                event: event, vendor: claim.vendor.rawValue, session: claim.session, toolUseId: use?.id,
                tool: use?.tool.rawValue, path: path, hash: use?.hash, declared: use?.declared)
            // The tool has written: a file it wrote while closed is listed.
            if case .postToolUse = claim.event { Task { @MainActor in ClosedChanges.refresh() } }
            let finished = claim.event == .turnEnd
            guard !updates.isEmpty || finished else { return }
            Task { @MainActor in
                for update in updates {
                    switch update {
                    case .relabeled(let doc, let change, let origin):
                        open[Key(engine, doc)]?.relabel(change, origin: origin)
                    case .retry(let doc):
                        if let live = open[Key(engine, doc)] {
                            Task {
                                await live.refresh()
                                live.released()
                            }
                        }
                    }
                }
                if finished { Review.finished(vendor: claim.vendor, session: claim.session) }
            }
        }
    }

    /// A Claude Code Bash call, from its hooks: the realpath of the folder it runs in, when it started and, once its
    /// PostToolUse or the turn's end came, when it ended.
    private struct Shell {
        let session: String
        let cwd: String
        let start: ContinuousClock.Instant
        var end: ContinuousClock.Instant?
    }

    /// Shell commands by call id. A change under one's folder that lands while it runs, or within a second after, stays
    /// unnamed and says so (X2); one that never ends counts for ten minutes, Claude Code's longest Bash timeout.
    private static var shells: [String: Shell] = [:]

    private static func shell(_ id: String, session: String, cwd: String?, ended: Bool) {
        let now = ContinuousClock.now
        shells = shells.filter { now - ($0.value.end ?? $0.value.start) < .seconds(600) }
        if ended {
            shells[id]?.end = now
        } else if shells[id] == nil, let cwd {
            shells[id] = Shell(session: session, cwd: cwd, start: now)
        }
    }

    /// Whether a change to the file at `url` landing now lands during a shell command run in a folder that holds it.
    private static func duringShell(_ url: URL) -> Bool {
        let now = ContinuousClock.now
        let running = shells.values.filter { shell in
            shell.end.map { now - $0 <= .seconds(1) } ?? (now - shell.start < .seconds(600))
        }
        guard !running.isEmpty, let real = Darwin.realpath(url.path, nil) else { return false }
        defer { free(real) }
        let path = String(cString: real)
        return running.contains { path.hasPrefix($0.cwd == "/" ? "/" : $0.cwd + "/") }
    }

    /// Before an agent's tool writes a file: keeps the bytes it read, if the file still holds them, and the hash of the
    /// bytes it declares, so a write to a file no tab has open lands marked, and named if it made those bytes, when it
    /// opens (B5). A write already made is kept from the bytes the engine has. The engine ignores open files.
    private nonisolated static func closedWrite(
        _ path: String, hash: String, declared: String, by claim: ControlSocket.Claim, engine: ChangeEngine
    ) {
        let vendor: ChangeEngine.Vendor =
            switch claim.vendor {
            case .claude: .claude
            case .codex: .codex
            case .cursor: .cursor
            case .demo: .demo
            case .acp: .acp
            }
        let url = URL(fileURLWithPath: path)
        guard let disk = try? Data(contentsOf: url) else { return }
        let diskHash = contentHash(disk).map { String(format: "%02x", $0) }.joined()
        do throws(ChangeEngine.Failure) {
            if diskHash == hash {
                try engine.closedWrite(url, origin: .agent(vendor, session: claim.session), before: disk, declared: declared)
            } else if diskHash == declared {
                // Cursor's afterFileEdit comes once the file holds the edit.
                try engine.closedWrote(url, origin: .agent(vendor, session: claim.session), before: hash, declared: declared)
                Task { @MainActor in ClosedChanges.refresh() }
            }
        } catch {
            log.error("A closed file's write was not kept: \(String(describing: error), privacy: .public)")
        }
    }

    private func relabel(_ change: UInt64, origin: ChangeEngine.Origin) {
        guard changes[change] != nil else { return }
        changes[change]?.origin = origin
        changes[change]?.marked = true
        Review.landed(self, change)
    }

    /// A hooked call on the file ended.
    private func released() {
        if autosaveRefused { Task { await autosave() } }
    }

    /// One vnode source per gitdir, shared by the open files in its repository.
    private final class GitWatch {
        let source: any DispatchSourceFileSystemObject
        var files = 0
        var debounce: Task<Void, Never>?

        init(_ source: any DispatchSourceFileSystemObject) {
            self.source = source
        }
    }

    private static var gitWatches: [String: GitWatch] = [:]

    private func watchGit(_ gitdir: URL?) {
        if let old = self.gitdir, let watch = Self.gitWatches[old.path] {
            watch.files -= 1
            if watch.files == 0 {
                watch.source.cancel()
                watch.debounce?.cancel()
                Self.gitWatches[old.path] = nil
            }
        }
        self.gitdir = gitdir
        guard let gitdir else { return }
        if let watch = Self.gitWatches[gitdir.path] {
            watch.files += 1
            return
        }
        let fd = Darwin.open(gitdir.path, O_EVTONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .link], queue: .main)
        let watch = GitWatch(source)
        watch.files = 1
        let engine = engine
        // git's locks come and go in the gitdir: index.lock, HEAD.lock, ORIG_HEAD.
        source.setEventHandler { [weak watch] in
            MainActor.assumeIsolated {
                guard let watch else { return }
                watch.debounce?.cancel()
                watch.debounce = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    let docs = await withCheckedContinuation { continuation in
                        Self.claims.async { continuation.resume(returning: engine.gitChanged(gitdir)) }
                    }
                    for doc in docs {
                        if let live = Self.open[Key(engine, doc)] { Task { await live.refresh() } }
                    }
                }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        Self.gitWatches[gitdir.path] = watch
    }

    // MARK: Detection

    /// Vnode sources on the file and its folder. A source on the file follows its inode, so each signal arms them
    /// again on whatever file is at the path then.
    private func arm() {
        for source in sources { source.cancel() }
        sources = []
        fileFD = -1
        guard !closed else { return }
        let file: DispatchSource.FileSystemEvent = [.write, .extend, .delete, .rename, .attrib, .link, .revoke]
        for (path, events) in [(url.path, file), (url.deletingLastPathComponent().path, .write)] {
            let fd = Darwin.open(path, O_EVTONLY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.signal() } }
            source.setCancelHandler { Darwin.close(fd) }
            source.resume()
            sources.append(source)
            if path == url.path { fileFD = fd }
        }
    }

    /// The descriptor the file's source watches, while it is armed.
    private var fileFD: Int32 = -1

    /// With no file at the path, where the watched file went, if it was renamed rather than deleted.
    private func renamedPath() -> URL? {
        guard fileFD >= 0, access(url.path, F_OK) != 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fileFD, F_GETPATH, &buffer) == 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard path != url.path, access(path, F_OK) == 0 else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Something changed at the file or in its folder: arm again and land 150 ms after the last signal.
    func signal() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            // NSDocument hears of a rename only through file coordination; one seen here moves the document too.
            if let renamed = renamedPath() {
                document?.fileURL = renamed
                moved(to: renamed)
            } else {
                arm()
            }
            await refresh()
        }
    }

    // MARK: Landing

    /// Observes the file and lands its new version into the buffer, until the buffer holds it, nothing is left to
    /// land, or the landing waits. A call while one runs makes it go round once more and waits for it.
    func refresh() async {
        refreshAgain = true
        if let refreshing { return await refreshing.value }
        let task = Task {
            while refreshAgain, !closed {
                refreshAgain = false
                await landOnce()
            }
            refreshing = nil
        }
        refreshing = task
        await task.value
    }

    private func landOnce() async {
        guard let textView = document?.textView, !waitsForInput(textView) else { return }
        let (buffer, version) = (textView.string, textView.version)
        let (engine, doc) = (engine, doc)
        let result = await offMain { () -> Result<ChangeEngine.Landing?, ChangeEngine.Failure> in
            Result { () throws(ChangeEngine.Failure) in
                try engine.observe(doc) ? try engine.land(doc, buffer: buffer, version: version) : nil
            }
        }
        let landing: ChangeEngine.Landing
        switch result {
        case .success(let landed?): landing = landed
        case .success(nil), .failure(.closed): return
        case .failure(.waiting):
            retry?.cancel()
            retry = Task { [weak self] in
                // git's lock and a hook call's end land again sooner; this covers a lock left behind.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
            return
        case .failure(let failure):
            Self.log.error("A change to the file did not land: \(String(describing: failure), privacy: .public)")
            return
        }
        guard !closed, document?.textView === textView, !waitsForInput(textView) else { return }
        // A newer edit or observation supersedes the landing: land again.
        guard textView.version == landing.version, engine.commit(doc, landing: landing.id) else {
            refreshAgain = true
            return
        }
        apply(landing, to: textView)
    }

    private func waitsForInput(_ textView: EditorTextView) -> Bool {
        landingWaits = textView.hasMarkedText() || textView.isWritingToolsActive
        return landingWaits
    }

    /// Applies a committed landing as one storage edit outside undo, keeping the selection by its neighbors and the
    /// caret's line, else the first visible line, where it is on screen.
    private func apply(_ landing: ChangeEngine.Landing, to textView: EditorTextView) {
        let storage = textView.textStorage!
        let edits = landing.edits
        func map(_ offset: Int, _ bias: ChangeEngine.Bias) -> Int {
            ChangeEngine.map(offset, through: edits, bias: bias)
        }
        let selection = textView.selectedRanges.map(\.rangeValue)
        let visible = textView.visibleRect
        // TextKit 2 answers a point in the top inset with an index near the end of the text, so probes stay below it.
        func index(_ x: CGFloat, _ y: CGFloat) -> Int {
            textView.characterIndexForInsertion(at: NSPoint(x: x, y: max(y, textView.textContainerOrigin.y)))
        }
        let first = index(visible.minX, visible.minY)
        let caret = selection.first?.location ?? first
        let anchor = first <= caret && caret <= index(visible.maxX, visible.maxY) ? caret : first
        let offset = textView.baseline(at: min(anchor, storage.length - 1)).map { $0 - visible.minY }

        // Removed text shows struck under its line once the change is marked, so it is read before the edit.
        let removed = edits.map { storage.mutableString.substring(with: $0.range) }
        applying = true
        // Undo entries move past the hunks, so undo never touches the landed text.
        textView.history.land(edits) {
            storage.beginEditing()
            for edit in (landing.covering.map { [$0] } ?? edits).reversed() {
                storage.replaceCharacters(in: edit.range, with: edit.text)
            }
            storage.endEditing()
        }
        applying = false

        let mapped = selection.map { range in
            guard range.length > 0 else { return NSRange(location: map(range.location, .before), length: 0) }
            let start = map(range.location, .after)
            return NSRange(location: start, length: max(map(NSMaxRange(range), .before) - start, 0))
        }
        textView.setSelectedRanges(mapped.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        if let offset { textView.hold(map(anchor, .before), at: offset) }

        changes = changes.filter { $0.value.marked || $0.value.conflict }.mapValues { change in
            var change = change
            let start = map(change.range.location, .after)
            change.range = NSRange(location: start, length: max(map(NSMaxRange(change.range), .before) - start, 0))
            return change
        }
        var shift = 0
        let shell = landing.origin == .external && Self.duringShell(url)
        for (index, edit) in edits.enumerated() {
            let length = edit.text.utf16.count
            changes[edit.change] = Change(
                range: NSRange(location: edit.range.location + shift, length: length), origin: landing.origin,
                marked: landing.marked, conflict: false, removed: removed[index], shell: shell)
            shift += length - edit.range.length
        }
        for conflict in landing.conflicts {
            let start = map(conflict.range.location, .after)
            let range = NSRange(location: start, length: max(map(NSMaxRange(conflict.range), .before) - start, 0))
            changes[conflict.change] = Change(
                range: range, origin: landing.origin, marked: true, conflict: true, theirs: conflict.theirs)
        }
        // git rewrites many open notes at once: only the key window's note announces and follows its landing.
        let behind: Bool = if case .git = landing.origin { textView.window?.isKeyWindow != true } else { false }
        if landing.marked, !behind {
            textView.marks.announce(landing.origin, places: edits.count + landing.conflicts.count)
            if let first = (edits.map(\.change) + landing.conflicts.map(\.change)).min(by: { changes[$0]!.range.location < changes[$1]!.range.location }) {
                Review.landed(self, first)
            }
        }
        reloadSnapshots()

        if landing.clean { keepMarks() } else { scheduleAutosave() }
    }

    // MARK: Edits and saves

    private func edited(_ range: NSRange, delta: Int) {
        guard !applying else { return }
        let oldEnd = NSMaxRange(range) - delta
        func moved(_ offset: Int) -> Int {
            offset < range.location ? offset : offset >= oldEnd ? offset + delta : NSMaxRange(range)
        }
        changes = changes.mapValues { change in
            var change = change
            if range.location <= NSMaxRange(change.range), oldEnd >= change.range.location { change.refused = false }
            let start = min(moved(change.range.location), change.range.location)
            change.range = NSRange(location: start, length: moved(NSMaxRange(change.range)) - start)
            return change
        }
        scheduleAutosave()
    }

    /// Settles a change: replaces its live range with what the decision makes of it, as one undoable edit. Deciding
    /// the last conflict runs a refused autosave again.
    func decide(_ change: UInt64, _ decision: ChangeEngine.Decision) {
        guard let textView = document?.textView, let pending = changes[change] else { return }
        let current = (textView.string as NSString).substring(with: pending.range)
        let replacement = engine.decide(doc, change: change, decision: decision, current: current)
        // A revert that would drop text typed inside the change leaves it pending, and its stamp says why.
        if replacement == nil, decision == .other, !pending.conflict {
            NSSound.beep()
            changes[change]?.refused = true
            return
        }
        changes[change] = nil
        // A decision that edits the text is kept by the save that follows.
        if let replacement {
            textView.replaceAsOneEdit(pending.range, with: replacement, named: Self.name(decision, pending))
        } else {
            keepMarks()
        }
        if pending.conflict, !changes.values.contains(where: \.conflict), autosaveRefused {
            Task { await autosave() }
        }
    }

    /// Keeps the outside writer's text: a change as it landed, a conflict's other version. Cmd-Return.
    func keep(_ change: UInt64) {
        decide(change, changes[change]?.conflict == true ? .other : .keep)
    }

    /// Keeps your text: a change's text before it landed, your version of a conflict. Option-Cmd-Delete.
    func revert(_ change: UInt64) {
        decide(change, changes[change]?.conflict == true ? .keep : .other)
    }

    /// Keep All and Revert All: decides every marked change in the file, last first, as one undoable edit.
    func decideAll(keep: Bool) {
        decide(changes.filter(\.value.marked).map(\.key), keep: keep, named: keep ? "Keep All Changes" : "Revert All Changes")
    }

    /// Keeps or reverts `ids`, last first, as one undoable edit: the stamp's changes, one writer's in this file.
    func decide(_ ids: [UInt64], keep: Bool, named name: String? = nil) {
        guard let textView = document?.textView else { return }
        let ids = ids.filter { changes[$0] != nil }.sorted { changes[$0]!.range.location > changes[$1]!.range.location }
        guard !ids.isEmpty else { return }
        if ids.count == 1, name == nil { return keep ? self.keep(ids[0]) : revert(ids[0]) }
        textView.history.perform(name ?? (keep ? "Keep Changes" : "Revert Changes")) {
            for id in ids { keep ? self.keep(id) : self.revert(id) }
        }
    }

    /// The change's first line of text, for a list: what it put there, else what it took out.
    func excerpt(_ change: UInt64) -> String {
        guard let pending = changes[change], let text = document?.textView?.string as NSString? else { return "" }
        let range = NSIntersectionRange(pending.range, NSRange(location: 0, length: text.length))
        let landed = text.substring(with: range)
        let shown = landed.contains(where: { !$0.isWhitespace }) ? landed : pending.conflict ? pending.theirs : pending.removed
        return shown.split(whereSeparator: \.isNewline).first { $0.contains(where: { !$0.isWhitespace }) }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// The change's line, counting from 1.
    func line(_ change: UInt64) -> Int {
        guard let pending = changes[change], let text = document?.textView?.string as NSString? else { return 1 }
        return text.substring(to: min(pending.range.location, text.length)).utf16.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
    }

    /// Brings the change's tab forward and scrolls its line a third of the way down the page; `caret` puts the caret
    /// in it, which makes it the one the stamp shows.
    func reveal(_ change: UInt64, caret: Bool) {
        guard let pending = changes[change], let textView = document?.textView, let window = textView.window,
            let scrollView = textView.enclosingScrollView
        else { return }
        if !window.isVisible { window.windowController?.showWindow(nil) }
        if caret {
            window.makeKeyAndOrderFront(nil)
            textView.setSelectedRange(NSRange(location: pending.range.location, length: 0))
            window.makeFirstResponder(textView)
        }
        let anchor = min(pending.range.location, max(textView.string.utf16.count - 1, 0))
        textView.hold(anchor, at: scrollView.contentInsets.top + scrollView.contentView.bounds.height / 3)
    }

    /// The Edit menu's name for a decision: "Undo Revert Claude's Change".
    private static func name(_ decision: ChangeEngine.Decision, _ change: Change) -> String {
        let writer = MarkWriter(change.origin)
        return switch (decision, change.conflict) {
        case (.other, false): "Revert \(writer.dashed ? "Outside" : writer.possessive) Change"
        case (.other, true): "Use \(writer.dashed ? "Other" : writer.possessive) Version"
        case (.both, _): "Keep Both Versions"
        case (.keep, _): "Keep Your Version"
        }
    }

    // MARK: Snapshots

    /// Reads the snapshot list off the main thread, then calls `then`.
    func reloadSnapshots(then: (@MainActor @Sendable () -> Void)? = nil) {
        let (engine, doc) = (engine, doc)
        queue.async { [weak self] in
            let snapshots = (try? engine.snapshots(doc)) ?? []
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.snapshots = snapshots
                then?()
            }
        }
    }

    /// Puts the draft's text in the buffer as one undoable edit, then empties the draft.
    func restoreDraft() async {
        guard let draft else { return }
        self.draft = nil
        if await restore(draft) { discardDraft() }
    }

    func discardDraft() {
        draft = nil
        let (engine, doc) = (engine, doc)
        queue.async {
            do throws(ChangeEngine.Failure) {
                try engine.discardDraft(doc)
            } catch {
                Self.log.error("A draft was not discarded: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The draft a refused save kept, while it holds other bytes than the file.
    func keptDraft() async -> ChangeEngine.Snapshot? {
        let (engine, doc) = (engine, doc)
        return await offMain { try? engine.draft(doc) }
    }

    /// Replaces the buffer with the snapshot's text as one undoable edit; the buffer is snapshotted first.
    @discardableResult
    func restore(_ snapshot: ChangeEngine.Snapshot) async -> Bool {
        guard let textView = document?.textView else { return false }
        let (engine, doc, buffer) = (engine, doc, textView.string)
        let result = await offMain { () -> Result<String, ChangeEngine.Failure> in
            Result { () throws(ChangeEngine.Failure) in try engine.restore(doc, snapshot: snapshot, buffer: buffer) }
        }
        defer { reloadSnapshots() }
        switch result {
        case .success(let text):
            guard !closed, document?.textView === textView else { return false }
            textView.replaceAsOneEdit(NSRange(location: 0, length: (textView.string as NSString).length), with: text, named: "Restore Snapshot")
            return true
        case .failure(let error):
            Self.log.error("A snapshot did not restore: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func pin(_ snapshot: ChangeEngine.Snapshot, _ pinned: Bool) {
        let (engine, doc) = (engine, doc)
        queue.async { [weak self] in
            do throws(ChangeEngine.Failure) {
                try engine.pin(doc, snapshot: snapshot, pinned: pinned)
            } catch {
                Self.log.error("A snapshot did not pin: \(String(describing: error), privacy: .public)")
            }
            Task { @MainActor in self?.reloadSnapshots() }
        }
    }

    private func inputEnded() {
        if landingWaits { Task { await refresh() } }
        if autosaveRefused { Task { await autosave() } }
    }

    /// Autosaves 2 s after the last edit, and 10 s after the first unsaved one while typing goes on.
    private func scheduleAutosave() {
        let now = ContinuousClock.now
        let since = unsavedSince ?? now
        unsavedSince = since
        autosaving?.cancel()
        autosaving = Task { [weak self] in
            try? await Task.sleep(until: Self.autosaveDue(now: now, since: since))
            guard !Task.isCancelled else { return }
            await self?.autosave()
        }
    }

    /// When an edit at `now` autosaves: 2 s after it, or 10 s after the first unsaved edit, `since`, if sooner.
    static func autosaveDue(now: ContinuousClock.Instant, since: ContinuousClock.Instant) -> ContinuousClock.Instant {
        min(now + .seconds(2), since + .seconds(10))
    }

    /// Waits before each retry of a refused autosave; the last repeats.
    private static let retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60)]

    /// Saves the buffer unless the engine refuses, which puts it in the file's draft instead. A refusal whose end
    /// sends no event is tried again with backoff.
    @discardableResult
    func autosave() async -> ChangeEngine.Refusal? {
        autosaving?.cancel()
        guard let textView = document?.textView else { return nil }
        unsavedSince = nil
        let refusal = await save(.auto(composing: textView.hasMarkedText(), writingTools: textView.isWritingToolsActive))
        autosaveRefused = refusal != nil
        self.refusal = refusal
        // A refused autosave writes the draft snapshot instead.
        if refusal != nil { reloadSnapshots() }
        switch refusal {
        case nil:
            retries = 0
        case .closed?, .readOnly?, .conflict?, .composing?, .writingTools?:
            break
        case .stale?, .changed?, .held?, .deleted?, .unreadable?, .io?:
            // An edit during the save scheduled the next one already.
            guard unsavedSince == nil else { break }
            let delay = Self.retryDelays[min(retries, Self.retryDelays.count - 1)]
            retries += 1
            autosaving = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.autosave()
            }
        }
        return refusal
    }

    /// Cmd-S: lands what the file holds, then saves.
    func saveExplicitly() async -> ChangeEngine.Refusal? {
        await refresh()
        unsavedSince = nil
        let refusal = await save(.explicit)
        if refusal == nil {
            autosaveRefused = false
            self.refusal = nil
            retries = 0
        }
        return refusal
    }

    private func save(_ kind: ChangeEngine.SaveKind) async -> ChangeEngine.Refusal? {
        guard !closed, let document, let textView = document.textView else { return .closed }
        let (buffer, version) = (textView.string, textView.version)
        let token = document.changeCountToken(for: .saveOperation)
        let (engine, doc, url) = (engine, doc, url)
        // Coordinated, so a sync client finishes with the file first and takes the save as one change.
        let result = await offMain { () -> Result<Data, ChangeEngine.Refusal> in
            do {
                return try document.coordinatedWrite(at: url) { _ in
                    Result { () throws(ChangeEngine.Refusal) in try engine.save(doc, buffer: buffer, version: version, kind: kind) }
                }
            } catch {
                return .failure(.io(error.localizedDescription))
            }
        }
        switch result {
        case .success:
            document.saved(token: token)
            reloadSnapshots()
            if changes.values.contains(where: \.marked) { keepMarks() }
            return nil
        case .failure(let refusal):
            return refusal
        }
    }

    private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
