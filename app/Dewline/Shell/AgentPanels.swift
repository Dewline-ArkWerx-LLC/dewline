import Foundation
import MdCore

/// A row of What Loads Here: an agent's name over its files, or one file.
struct AgentRow {
    /// Nil for an agent's name.
    let url: URL?
    let title: String
    let detail: String
    let tip: String?
}

/// The home folder agents keep their settings, memory and plans under.
let agentHome = FileManager.default.homeDirectoryForCurrentUser.path

/// What each agent loads in `folder`: its name with the total, then each file with its estimate.
func whatLoadsRows(in folder: URL, root: URL?) -> [AgentRow] {
    let loaded = agentFilesLoaded(in: folder.path, home: agentHome)
    var rows: [AgentRow] = []
    for agent in ["Claude Code", "Codex", "Cursor"] {
        let files = loaded.filter { $0.agent == agent }
        guard !files.isEmpty else { continue }
        let total = files.reduce(0) { $0 + $1.tokens }
        rows.append(AgentRow(url: nil, title: agent, detail: "≈\(tokens(total)) tokens", tip: "Estimated at 4 bytes a token"))
        for file in files {
            let url = URL(filePath: file.path)
            rows.append(AgentRow(
                url: url, title: shortPath(url, from: folder, root: root), detail: tokens(file.tokens),
                tip: [file.path, file.how].joined(separator: "\n")
            ))
        }
    }
    return rows
}

private func tokens(_ count: UInt64) -> String {
    count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : String(count)
}

/// `url` by name in `folder`, relative under `root`, and from the home folder elsewhere.
private func shortPath(_ url: URL, from folder: URL, root: URL?) -> String {
    let path = url.path
    if url.deletingLastPathComponent().path == folder.path { return url.lastPathComponent }
    if let root, path.hasPrefix(root.path + "/") { return String(path.dropFirst(root.path.count + 1)) }
    return (path as NSString).abbreviatingWithTildeInPath
}
