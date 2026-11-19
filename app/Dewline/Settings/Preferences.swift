import AppKit
import Observation

/// The General settings, kept in user defaults. Posts `didChange` after every change.
@MainActor @Observable
final class Preferences {
    enum Attachments: String {
        /// Pasted images go in the document's own folder.
        case beside
        /// In an "attachments" folder beside the document.
        case subfolder
    }

    static let shared = Preferences(defaults: .standard)
    /// The settings as a fresh install has them, for Restore Defaults.
    static var factory: Preferences { Preferences(defaults: .factory) }
    static let didChange = Notification.Name("DewlinePreferencesDidChange")
    /// The inbox file `dewline capture` appends to, an absolute path in the app's domain (dev.arkwerx.dewline).
    /// Unset means ~/Documents/Dewline/Inbox.md.
    static let inboxKey = "DewlineInboxPath"

    @ObservationIgnored private let defaults: UserDefaults

    /// The sidebar lists what .gitignore hides, dimmed, and Quick Open and Find in Files search it.
    var showsIgnored: Bool { didSet { save(showsIgnored, "DewlineShowIgnored") } }
    var attachments: Attachments { didSet { save(attachments.rawValue, "DewlineAttachments") } }
    var inbox: URL { didSet { save(inbox.path, Self.inboxKey) } }
    /// Where New Note puts a note when no window shows a folder, picked at the first one. Unset means ask.
    var notesFolder: URL? { didSet { save(notesFolder?.path, "DewlineNewFileFolder") } }
    #if COLLAB
    /// The name a shared document's host and guests see.
    var collaborationName: String { didSet { save(collaborationName, "DewlineCollaborationName") } }
    /// Where a guest's copies of shared documents go.
    var sharedFolder: URL { didSet { save(sharedFolder.path, "DewlineSharedFolder") } }
    #endif
    /// Cards and hover previews for web links, which ask each site for its title and picture.
    var linkPreviews: Bool { didSet { save(linkPreviews, "DewlineLinkPreviews") } }
    /// Source and config files list in the sidebar and Quick Open and open as highlighted code (`CodeFile`).
    var opensCodeFiles: Bool { didSet { save(opensCodeFiles, CodeFile.key) } }

    init(defaults: UserDefaults, home: URL = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)) {
        self.defaults = defaults
        let documents = home.appending(path: "Documents", directoryHint: .isDirectory)
        func path(_ key: String) -> URL? {
            defaults.string(forKey: key).flatMap { $0.hasPrefix("/") ? URL(filePath: $0) : nil }
        }
        showsIgnored = defaults.bool(forKey: "DewlineShowIgnored")
        attachments = defaults.string(forKey: "DewlineAttachments").flatMap(Attachments.init) ?? .beside
        inbox = path(Self.inboxKey) ?? documents.appending(path: "Dewline/Inbox.md")
        notesFolder = path("DewlineNewFileFolder")
        #if COLLAB
        collaborationName = defaults.string(forKey: "DewlineCollaborationName").flatMap { $0.isEmpty ? nil : $0 } ?? NSFullUserName()
        sharedFolder = path("DewlineSharedFolder") ?? documents.appending(path: "Dewline Shared", directoryHint: .isDirectory)
        #endif
        linkPreviews = defaults.bool(forKey: "DewlineLinkPreviews")
        opensCodeFiles = defaults.bool(forKey: CodeFile.key)
    }

    /// AppKit brings back the last windows only while NSQuitAlwaysKeepsWindows holds; the system's
    /// "Close windows when quitting an application" sets it false for every app that doesn't set its own.
    func keepWindows() {
        defaults.set(true, forKey: "NSQuitAlwaysKeepsWindows")
    }

    private func save(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

extension UserDefaults {
    /// A domain nothing writes, so it reads every setting at its default.
    static var factory: UserDefaults { UserDefaults(suiteName: "dev.arkwerx.dewline.factory")! }
}
