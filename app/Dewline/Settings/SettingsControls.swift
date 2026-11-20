import AppKit
import SwiftUI

/// A pane's settings as a grouped form, with Restore Defaults under it when the pane has one.
struct SettingsForm<Content: View>: View {
    var restore: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Form { content }
            if let restore {
                HStack {
                    Spacer()
                    Button("Restore Defaults", action: restore)
                }
                .padding([.horizontal, .bottom], 20)
            }
        }
    }
}

/// A folder's path with a Choose\u{2026} button that asks for another.
struct FolderField: View {
    let url: URL
    let chose: (URL) -> Void

    var body: some View {
        PathField(url: url) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.directoryURL = url
            if panel.runModal() == .OK, let chosen = panel.url { chose(chosen) }
        }
    }
}

/// A path shortened in the middle, its full path in the tooltip, and a Choose\u{2026} button.
struct PathField: View {
    let url: URL
    let choose: () -> Void

    var body: some View {
        HStack {
            Text(abbreviatedPath(url))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(url.path)
                .accessibilityLabel(url.path)
            Button("Choose\u{2026}", action: choose)
                .fixedSize()
        }
    }
}
