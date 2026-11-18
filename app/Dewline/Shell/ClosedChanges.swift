import Foundation
import MdCore
import os

/// Files an agent wrote while no tab had them open (B5). Opening one lands the write as marked changes against the
/// bytes it replaced, so it reviews like a change to an open file. Recording one posts `LiveFile.changesDidChange`
/// with no file, so Activity and the sidebar count it.
@MainActor
enum ClosedChanges {
    /// The engine the app's documents open through; tests pass their own.
    static var engine: ChangeEngine? = MarkdownDocument.sharedEngine

    /// `writer` is about to write the file at `url`, which holds `before`, making bytes whose BLAKE3 hex is
    /// `declared`: the agent panel calls this before its write to a closed note; hooked agents' writes are kept from
    /// their PreToolUse claims.
    static func record(path url: URL, writer: ChangeEngine.Origin, before: Data, declared: String) {
        do throws(ChangeEngine.Failure) {
            try engine?.closedWrite(url, origin: writer, before: before, declared: declared)
            NotificationCenter.default.post(name: LiveFile.changesDidChange, object: nil)
        } catch {
            Logger(subsystem: "dev.arkwerx.dewline", category: "engine")
                .error("A closed file's write was not kept: \(String(describing: error), privacy: .public)")
        }
    }

    /// Changed while closed, oldest first: each file, who wrote it, and when.
    static var all: [ChangeEngine.ClosedChange] {
        engine?.closedChanges() ?? []
    }
}
