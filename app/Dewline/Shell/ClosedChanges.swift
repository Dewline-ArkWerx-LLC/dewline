import Foundation
import MdCore
import os

/// Files an agent wrote while no tab had them open (B5), kept from hooked agents' PreToolUse claims. Opening one lands
/// the write as marked changes against the bytes it replaced, so it reviews like a change to an open file.
@MainActor
enum ClosedChanges {
    /// The engine the app's documents open through; tests pass their own.
    static var engine: ChangeEngine? = MarkdownDocument.sharedEngine
    /// A scan finished: the list may have changed.
    static let changed = Notification.Name("ClosedChangesChanged")

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
