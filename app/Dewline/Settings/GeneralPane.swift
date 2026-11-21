import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

struct GeneralPane: View {
    @Bindable var preferences: Preferences
    let updates: Updates
    @State private var isDefaultApp = DefaultApp.isDewline

    var body: some View {
        SettingsForm(restore: { Self.restore(preferences, updates) }) {
            Section {
                LabeledContent {
                    Button("Use Dewline") { Task { isDefaultApp = await DefaultApp.make() } }
                        .disabled(isDefaultApp)
                } label: {
                    Text("Default Markdown app")
                    Text(isDefaultApp ? "Finder opens Markdown files in Dewline." : "Finder opens Markdown files in another app.")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in isDefaultApp = DefaultApp.isDewline }
            Section("Files") {
                if let folder = preferences.notesFolder {
                    LabeledContent {
                        FolderField(url: folder) { preferences.notesFolder = $0 }
                    } label: {
                        Text("New notes go in")
                        Text("When no window shows a folder.")
                    }
                }
                Toggle(isOn: $preferences.showsIgnored) {
                    Text("Show files .gitignore hides")
                    Text("Dimmed in the sidebar, and found by Quick Open and Find in Files.")
                }
                Picker("Pasted images go", selection: $preferences.attachments) {
                    Text("Beside the note").tag(Preferences.Attachments.beside)
                    Text("In an \u{201C}attachments\u{201D} folder beside it").tag(Preferences.Attachments.subfolder)
                }
                LabeledContent {
                    PathField(url: preferences.inbox) {
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [UTType("net.daringfireball.markdown") ?? .plainText]
                        panel.directoryURL = preferences.inbox.deletingLastPathComponent()
                        panel.nameFieldStringValue = preferences.inbox.lastPathComponent
                        panel.prompt = "Use"
                        if panel.runModal() == .OK, let url = panel.url { preferences.inbox = url }
                    }
                } label: {
                    Text("Inbox")
                    Text("File > Capture\u{2026}, the Services menu, Shortcuts, dewline capture and MCP add to the end of this note.")
                }
            }
            Section {
                if updates.updater == nil {
                    Text("This build does not update itself.")
                } else {
                    Toggle("Check automatically", isOn: Binding { updates.automaticChecks } set: { updates.setAutomaticChecks($0) })
                    Toggle(isOn: Binding { updates.beta } set: { updates.setBeta($0) }) {
                        Text("Beta builds")
                        Text("Betas also get every stable release.")
                    }
                    LabeledContent("Last checked") {
                        HStack {
                            Text(updates.lastCheck?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                            // Sparkle starts no check while it holds a staged update.
                            Button("Check Now") { updates.checkNow() }
                                .disabled(updates.staged != nil)
                        }
                    }
                }
                if let text = updates.stagedText {
                    Text(text)
                }
            } header: {
                Text("Updates")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if updates.updater != nil {
                        Text(Updates.lineText)
                    }
                    if let error = updates.lastError {
                        Text(error)
                    }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Puts this pane's settings, and no others, back as a fresh install has them.
    static func restore(_ preferences: Preferences, _ updates: Updates) {
        let factory = Preferences.factory
        preferences.showsIgnored = factory.showsIgnored
        preferences.attachments = factory.attachments
        preferences.inbox = factory.inbox
        preferences.notesFolder = factory.notesFolder
        updates.setAutomaticChecks(Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool ?? false)
        updates.setBeta(false)
    }
}

/// The app Finder opens Markdown files in.
@MainActor
enum DefaultApp {
    /// Markdown, its dialects, and every type another app gives one of their extensions (Typora's io.typora.markdown
    /// for .mdown and .qmd, com.mdxjs.mdx): a binding on net.daringfireball.markdown does not reach them.
    static var types: [UTType] {
        let markdown = UTType(MarkdownDocument.type) ?? .plainText
        var types = [markdown] + [UTType("dev.arkwerx.dewline.markdown-dialect")].compactMap { $0 }
        for tag in FolderEntry.markdownExtensions.union(FolderEntry.dialectExtensions).sorted() {
            for type in UTType.types(tag: tag, tagClass: .filenameExtension, conformingTo: markdown) where !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    /// Whether Launch Services opens every Markdown type in this app's bundle ID, wherever this copy runs from.
    static var isDewline: Bool {
        types.allSatisfy { type in
            NSWorkspace.shared.urlForApplication(toOpen: type).flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
        }
    }

    /// Makes Dewline the app for every Markdown type; true when it is.
    static func make() async -> Bool {
        for type in types {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
            } catch {
                Logger(subsystem: "dev.arkwerx.dewline", category: "app")
                    .error("Dewline did not become the app for \(type.identifier, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return isDewline
    }
}
