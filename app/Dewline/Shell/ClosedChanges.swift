import Foundation
import MdCore

/// Files an agent wrote while no tab had them open (B5), kept from hooked agents' PreToolUse claims. Opening one lands
/// the write as marked changes against the bytes it replaced, so it reviews like a change to an open file.
@MainActor
enum ClosedChanges {
    /// The engine the app's documents open through; tests pass their own.
    static var engine: ChangeEngine? = MarkdownDocument.sharedEngine

    /// Changed while closed, oldest first: each file, who wrote it, and when.
    static var all: [ChangeEngine.ClosedChange] {
        engine?.closedChanges() ?? []
    }
}
