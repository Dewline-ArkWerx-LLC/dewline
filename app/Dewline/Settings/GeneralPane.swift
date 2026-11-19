import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

struct GeneralPane: View {
    @Bindable var preferences: Preferences
    let updates: Updates
    @State private var isDefaultApp = DefaultApp.isDewline

    var body: some View {
        SettingsPage {
            SettingsSection {
                SettingsRow(label: "Default Markdown app", detail: isDefaultApp ? "Finder opens Markdown files in Dewline." : "Finder opens Markdown files in another app.") {
                    Button("Use Dewline") { Task { isDefaultApp = await DefaultApp.make() } }
                        .buttonStyle(.station)
                        .disabled(isDefaultApp)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in isDefaultApp = DefaultApp.isDewline }
            SettingsSection(title: "Files") {
                if let folder = preferences.notesFolder {
                    SettingsRow(label: "New notes go in", detail: "When no window shows a folder.") {
                        FolderField(url: folder) { preferences.notesFolder = $0 }
                    }
                }
                SettingsRow(label: "Show files .gitignore hides", detail: "Dimmed in the sidebar, and found by Quick Open and Find in Files.") {
                    OnOff(label: "Show files .gitignore hides", isOn: $preferences.showsIgnored)
                }
                SettingsRow(label: "Pasted images go") {
                    TextChoice(label: "Pasted images go", selection: $preferences.attachments, options: [
                        ("Beside the note", .beside), ("In an \u{201C}attachments\u{201D} folder beside it", .subfolder),
                    ])
                }
                SettingsRow(label: "Inbox", detail: "File > Capture\u{2026}, the Services menu, Shortcuts, dewline capture and MCP add to the end of this note.") {
                    PathField(url: preferences.inbox) {
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [UTType("net.daringfireball.markdown") ?? .plainText]
                        panel.directoryURL = preferences.inbox.deletingLastPathComponent()
                        panel.nameFieldStringValue = preferences.inbox.lastPathComponent
                        panel.prompt = "Use"
                        if panel.runModal() == .OK, let url = panel.url { preferences.inbox = url }
                    }
                }
            }
            SettingsSection(title: "Updates", note: updates.updater == nil ? "This build does not update itself." : Updates.lineText) {
                Group {
                    SettingsRow(label: "Check automatically") {
                        OnOff(label: "Check for updates automatically", isOn: Binding { updates.automaticChecks } set: { updates.setAutomaticChecks($0) })
                    }
                    SettingsRow(label: "Beta builds", detail: "Betas also get every stable release.") {
                        OnOff(label: "Get beta builds", isOn: Binding { updates.beta } set: { updates.setBeta($0) })
                    }
                    SettingsRow(label: "Last checked") {
                        HStack(spacing: 14) {
                            Text(updates.lastCheck?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                                .font(Station.mono(12))
                                .foregroundStyle(Station.color(.ink2))
                            // Sparkle starts no check while it holds a staged update.
                            Button("Check Now") { updates.checkNow() }
                                .buttonStyle(.station)
                                .disabled(updates.staged != nil)
                        }
                    }
                }
                .disabled(updates.updater == nil)
                if let error = updates.lastError {
                    SettingsNote(error)
                        .padding(.top, 8)
                }
                if let text = updates.stagedText {
                    Text(text)
                        .font(Station.label)
                        .foregroundStyle(Station.color(.ink))
                        .padding(.top, 8)
                }
            }
            RestoreDefaults {
                let factory = Preferences.factory
                preferences.showsIgnored = factory.showsIgnored
                preferences.attachments = factory.attachments
                preferences.inbox = factory.inbox
                preferences.notesFolder = factory.notesFolder
                updates.setAutomaticChecks(Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool ?? false)
                updates.setBeta(false)
            }
        }
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
