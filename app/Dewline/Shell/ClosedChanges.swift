import Foundation
import MdCore
import os

/// Files an agent wrote while no tab had them open (B5), kept from hooked agents' PreToolUse claims. Opening one lands
/// the write as marked changes against the bytes it replaced, so it reviews like a change to an open file.
@MainActor
enum ClosedChanges {
    /// The engine the app's documents open through; tests pass their own.
    static var engine: ChangeEngine? = MarkdownDocument.sharedEngine {
        didSet { refresh() }
    }
    /// The list changed.
    static let changed = Notification.Name("ClosedChangesChanged")
    /// Changed while closed, oldest first: each file, who wrote it, and when, as last listed off the main thread.
    private(set) static var all: [ChangeEngine.ClosedChange] = []

    /// Scans and listings, one at a time.
    private nonisolated static let queue = DispatchQueue(label: "dev.arkwerx.dewline.closed", qos: .utility)
    /// Whether a listing waits to start, and the folders whose deep scan waits.
    private nonisolated static let waiting = OSAllocatedUnfairLock(initialState: (listing: false, deep: Set<URL>()))

    /// Notes the Markdown files in `folder`, and its subfolders when `deep`, off the main thread, then lists the
    /// changed files again. Each tab's sidebar asks for a deep scan; one already waiting for the folder serves them all.
    static func scan(_ folder: URL, deep: Bool) {
        guard let engine else { return }
        let folder = folder.standardizedFileURL
        if deep, !waiting.withLock({ $0.deep.insert(folder).inserted }) { return }
        queue.async {
            if deep { waiting.withLock { _ = $0.deep.remove(folder) } }
            do throws(ChangeEngine.Failure) {
                try engine.scan(folder, deep: deep)
            } catch {
                Logger(subsystem: "dev.arkwerx.dewline", category: "engine")
                    .error("A folder was not scanned: \(String(describing: error), privacy: .public)")
            }
            Task { @MainActor in refresh() }
        }
    }

    /// Lists the changed files again off the main thread, then posts `changed`. Calls while a listing waits to start
    /// share it.
    static func refresh() {
        guard let engine else { return }
        let queued = waiting.withLock { state in
            defer { state.listing = true }
            return state.listing
        }
        guard !queued else { return }
        queue.async {
            waiting.withLock { $0.listing = false }
            let listed = engine.closedChanges()
            Task { @MainActor in
                guard engine === Self.engine else { return }
                all = listed
                NotificationCenter.default.post(name: changed, object: nil)
            }
        }
    }
}
