internal import DewlineFFIBindings
import Foundation

/// Whether an agent loads the file at `url` as instructions, rules, skills, plans or memory, by the engine's dated list.
public func isAgentFile(_ url: URL) -> Bool {
    DewlineFFIBindings.isAgentFile(path: url.path)
}

/// One instruction file an agent loads in a folder, with a bytes/4 token estimate.
public struct LoadedAgentFile: Sendable {
    public let agent: String
    public let path: String
    /// "walk", "@import from CLAUDE.md", or a Cursor rule's trigger.
    public let how: String
    public let tokens: UInt64
}

/// What Claude Code, Codex and Cursor load for a session started in `folder`.
public func agentFilesLoaded(in folder: String, home: String?) -> [LoadedAgentFile] {
    ((try? whatLoads(folder: folder, home: home)) ?? []).map {
        LoadedAgentFile(agent: $0.agent, path: $0.path, how: $0.how, tokens: $0.tokens)
    }
}

/// A broken link or import, in UTF-16 offsets.
public struct BrokenTarget: Sendable {
    public let range: NSRange
    public let target: String
    public let problem: String
}

/// The broken relative links and CLAUDE.md `@imports` of `text`, the file at `path`.
public func brokenTargets(in text: TextCopy, path: String, home: String?) -> [BrokenTarget] {
    ((try? brokenLinks(path: path, text: text.text, home: home)) ?? []).map {
        BrokenTarget(range: NSRange(location: Int($0.location), length: Int($0.length)), target: $0.target, problem: $0.problem)
    }
}
