import Foundation
import MdCore
import os

/// Notes that changed while no tab had them open, or while the app was quit (B5). Opening one lands the change as
/// marked changes against the version Dewline last saw, so it reviews like a change to an open file.
@MainActor
enum ClosedChanges {
    /// The engine the app's documents open through; tests pass their own.
    static var engine: ChangeEngine? = MarkdownDocument.sharedEngine
    /// A scan finished: the list may have changed.
    static let changed = Notification.Name("ClosedChangesChanged")

    /// `writer` is about to write the file at `url`, which holds `before`, making bytes whose BLAKE3 hex is
    /// `declared`: the agent panel calls this before its write to a closed note; hooked agents' writes are kept from
    /// their PreToolUse claims.
    static func record(path url: URL, writer: ChangeEngine.Origin, before: Data, declared: String) {
        do throws(ChangeEngine.Failure) {
            try engine?.closedWrite(url, origin: writer, before: before, declared: declared)
        } catch {
            Logger(subsystem: "dev.arkwerx.dewline", category: "engine")
                .error("A closed file's write was not kept: \(String(describing: error), privacy: .public)")
        }
    }

    /// Notes the Markdown files in `folder`, and its subfolders when `deep`, off the main thread, then posts `changed`.
    static func scan(_ folder: URL, deep: Bool) {
        guard let engine else { return }
        DispatchQueue.global(qos: .utility).async {
            do throws(ChangeEngine.Failure) {
                try engine.scan(folder, deep: deep)
            } catch {
                Logger(subsystem: "dev.arkwerx.dewline", category: "engine")
                    .error("A folder was not scanned: \(String(describing: error), privacy: .public)")
            }
            Task { @MainActor in NotificationCenter.default.post(name: changed, object: nil) }
        }
    }

    /// Changed while closed, oldest first: each file, who wrote it, and when.
    static var all: [ChangeEngine.ClosedChange] {
        engine?.closedChanges() ?? []
    }
}
