import Foundation
import MdCore

/// The git state of each file under a folder, read again whenever the folder or its repository changes. The folder's
/// `FolderIndex` holds the one its tabs share and reads it again when the folder changes.
@MainActor
final class GitStates {
    /// Posted on the main queue after the states change.
    static let changed = Notification.Name("DewlineGitStatesChanged")
    private let folder: URL
    private var files: [String: GitFileState] = [:]
    /// Watches a gitdir outside the folder.
    private var watch: FolderWatch?
    private var gitdir: URL?
    private var reading = false
    private var stale = false

    init(folder: URL) {
        self.folder = folder.standardizedFileURL
        read()
    }

    /// The state of `url`, a file under the folder, or the untracked folder's that holds it. Nil when clean.
    func state(of url: URL) -> GitFileState? {
        let root = folder.path + "/"
        var path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return nil }
        path.removeFirst(root.count)
        if let state = files[path] { return state }
        while let slash = path.lastIndex(of: "/") {
            path = String(path[..<slash])
            if files[path] == .new { return .new }
        }
        return nil
    }

    func read() {
        guard !reading else {
            stale = true
            return
        }
        reading = true
        let folder = folder
        Task { [weak self] in
            let status = await Task.detached(priority: .utility) { gitStatus(of: folder) }.value
            self?.finished(status)
        }
    }

    private func finished(_ status: FolderGitStatus?) {
        reading = false
        // A gitdir outside the folder changes on commits and staging without the folder changing.
        if let gitdir = status?.gitdir.standardizedFileURL, gitdir != self.gitdir {
            self.gitdir = gitdir
            let inside = gitdir.path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
            watch = inside ? nil : FolderWatch([gitdir]) { [weak self] _ in self?.read() }
        }
        // A repository caught mid-write reads as none; the states stand until the next read.
        let kept = status == nil && gitdir.map { FileManager.default.fileExists(atPath: $0.path) } == true
        let files = status?.files ?? [:]
        if !kept && files != self.files {
            self.files = files
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
        if stale {
            stale = false
            read()
        }
    }
}
