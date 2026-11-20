import Foundation

/// Everyone whose changes Dewline marks (D21). Each change marks in its writer's ink (`ThemeStore.writerColor`) and
/// shows its writer by name.
enum Writer: String, CaseIterable, Identifiable, Sendable {
    case you, claude, codex, cursor, copilot, gemini, git, unknown, otherMac, collaborator
    /// Welcome.md's first-run demo; it has no row in Settings.
    case demo

    var id: Self { self }

    var name: String {
        switch self {
        case .you: "You"
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .copilot: "Copilot"
        case .gemini: "Gemini"
        case .git: "git"
        case .unknown: "Another app"
        case .otherMac: "Your other Mac"
        case .collaborator: "Collaborator"
        case .demo: "Demo agent"
        }
    }
}
