internal import DewlineFFIBindings
import Foundation

/// A file's state against HEAD and the index, as git status reports it. A new file is staged, or added with intent, or
/// untracked.
public enum GitFileState: Sendable, Equatable {
    case modified, deleted, renamed, conflicted
    case new(staged: Bool)
}

public struct FolderGitStatus: Sendable, Equatable {
    /// The folder that holds the repository's index and HEAD.
    public let gitdir: URL
    /// The files that differ from HEAD or the index, by their "/"-separated paths from the folder. An untracked folder
    /// holding no tracked file is one entry.
    public let files: [String: GitFileState]
    /// The commits HEAD's branch has that its upstream lacks, and those the upstream has that it lacks; nil without an
    /// upstream.
    public let ahead: Int?
    public let behind: Int?
}

/// The git state of the files under `folder`, or nil when the folder is in no repository or the repository can't be
/// read. It reads the index, HEAD's tree and the working tree, so call it off the main thread.
public func gitStatus(of folder: URL) -> FolderGitStatus? {
    (try? gitStatus(folder: folder.path)).map { status in
        FolderGitStatus(
            gitdir: URL(filePath: status.gitdir, directoryHint: .isDirectory),
            files: Dictionary(uniqueKeysWithValues: status.files.map { file in
                let state: GitFileState = switch file.state {
                case .modified: .modified
                case .added: .new(staged: true)
                case .untracked: .new(staged: false)
                case .deleted: .deleted
                case .renamed: .renamed
                case .conflicted: .conflicted
                }
                return (file.path, state)
            }),
            ahead: status.ahead.map(Int.init),
            behind: status.behind.map(Int.init)
        )
    }
}

/// What git ignores under a folder: its repository's .gitignore files, info/exclude and `core.excludesFile`, or the
/// folder's own .gitignore files when no repository holds it. The rules `gitStatus` reads.
public final class GitIgnores: Sendable {
    private let rules: DewlineFFIBindings.GitIgnores

    public init(folder: URL) {
        rules = DewlineFFIBindings.GitIgnores(folder: folder.path)
    }

    /// Whether git ignores `path`, "/"-separated from the folder: it or a folder above it matches. A folder's .gitignore
    /// is read the first time a path under it is asked about. A path the rules fail on counts as ignored.
    public func ignores(_ path: String, isFolder: Bool) -> Bool {
        (try? rules.ignores(path: path, isFolder: isFolder)) ?? true
    }
}
