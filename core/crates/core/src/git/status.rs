//! Each file's state under a folder, as `git status --porcelain=v2` reports
//! it: the index against HEAD's tree, the working tree against the index, and
//! the files no ignore rule matches that the index doesn't list. Git reads its
//! own config, so `core.excludesFile`, `core.autocrlf`, `core.fileMode`, filters
//! and rename detection hold as they do in a terminal.

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;

use super::Repo;

/// A file's state against HEAD and the index.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    /// Its content or mode differs from HEAD's or the index's.
    Modified,
    /// Not in HEAD: staged, added with intent, or untracked.
    New,
    /// Gone from the working tree, or from the index.
    Deleted,
    /// Staged as a rename: git found a file the index deletes from HEAD with
    /// the same or similar content.
    Renamed,
    /// Unmerged.
    Conflicted,
}

/// A folder's repository and the files under the folder that differ from
/// HEAD or the index, by their paths from the folder, in byte order.
#[derive(Debug, PartialEq, Eq)]
pub struct Statuses {
    pub gitdir: PathBuf,
    pub files: Vec<(PathBuf, Status)>,
}

/// The state of the files under `folder`, a realpath. An untracked folder
/// holding no tracked file is one path, as git status lists it. A rename's old
/// path is not listed. None when the folder is in no repository, git is not
/// installed, or git status fails.
pub fn status(folder: &Path) -> Option<Statuses> {
    // `find` looks for `.git` in each folder above the path, the folder first.
    let repo = Repo::find(&folder.join(".git"))?;
    let prefix = folder.strip_prefix(&repo.top).ok()?.as_os_str().as_bytes();
    // The whole repository, so a rename from outside the folder is found.
    let mut files = parse(&run(&repo.top, &["--untracked-files=normal".as_ref()])?)?;
    // A folder inside an untracked one: git lists only the untracked one, so
    // the files under the folder are listed and each kept as its first part.
    let inside = |name: &[u8]| {
        prefix
            .strip_prefix(name)
            .is_some_and(|rest| rest.is_empty() || rest[0] == b'/')
    };
    if !prefix.is_empty()
        && files
            .iter()
            .any(|(name, status)| *status == Status::New && inside(name))
    {
        let pathspec = OsStr::from_bytes(&[b":(literal)", prefix].concat()).to_owned();
        let args = ["--untracked-files=all".as_ref(), "--".as_ref(), &*pathspec];
        files = parse(&run(&repo.top, &args)?)?
            .into_keys()
            .filter_map(|name| {
                let rest = name.strip_prefix(prefix)?.strip_prefix(b"/")?;
                let first = rest.split(|&byte| byte == b'/').next()?;
                Some(([prefix, b"/", first].concat(), Status::New))
            })
            .collect();
    }
    let files = files
        .into_iter()
        .filter_map(|(name, status)| {
            // A file at the folder's own path is not under it.
            let relative = if prefix.is_empty() {
                &name[..]
            } else {
                name.strip_prefix(prefix)?.strip_prefix(b"/")?
            };
            Some((PathBuf::from(OsStr::from_bytes(relative)), status))
        })
        .collect();
    Some(Statuses {
        gitdir: repo.gitdir,
        files,
    })
}

/// `git status --porcelain=v2 -z` with `args`, in `top`. Git reads no
/// variable of the app's and takes no optional lock, so it never writes the
/// index and wakes the folder's watcher.
fn run(top: &Path, args: &[&OsStr]) -> Option<Vec<u8>> {
    let mut git = Command::new(git()?);
    for (key, _) in std::env::vars_os() {
        if key.as_bytes().starts_with(b"GIT_") {
            git.env_remove(key);
        }
    }
    let output = git
        .current_dir(top)
        .env("GIT_TERMINAL_PROMPT", "0")
        // An fsmonitor hook is a program the repository names; status runs fine without it.
        .args([
            "-c",
            "core.fsmonitor=false",
            "--no-optional-locks",
            "status",
        ])
        .args([
            "--porcelain=v2",
            "-z",
            "--find-renames",
            "--ignore-submodules=dirty",
        ])
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    output.status.success().then_some(output.stdout)
}

/// The developer tools' git, found once. Without the tools /usr/bin/git only
/// asks to install them, and with them it spends 8 ms finding this one.
fn git() -> Option<&'static Path> {
    static GIT: OnceLock<Option<PathBuf>> = OnceLock::new();
    GIT.get_or_init(|| {
        let tools = Command::new("/usr/bin/xcode-select")
            .arg("-p")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success());
        if !tools {
            return None;
        }
        let found = Command::new("/usr/bin/xcrun")
            .args(["--find", "git"])
            .stderr(Stdio::null())
            .output()
            .ok()
            .filter(|found| found.status.success())?;
        let path = PathBuf::from(OsStr::from_bytes(found.stdout.trim_ascii_end()));
        path.is_absolute().then_some(path)
    })
    .as_deref()
}

/// Each path in `git status --porcelain=v2 -z` output and its state, by path
/// from the top of the repository. A path listed twice, staged as deleted and
/// untracked, is untracked. None when a record is malformed.
fn parse(output: &[u8]) -> Option<BTreeMap<Vec<u8>, Status>> {
    let mut files = BTreeMap::new();
    let mut records = output.split(|&byte| byte == 0).filter(|r| !r.is_empty());
    while let Some(record) = records.next() {
        // The fields before the path, the record's kind first.
        let fields = match record.first()? {
            b'1' => 8,
            b'2' => 9,
            b'u' => 10,
            b'?' => 1,
            _ => continue,
        };
        let mut parts = record.splitn(fields + 1, |&byte| byte == b' ');
        let kind = parts.next()?[0];
        let xy = if kind == b'?' { b".." } else { parts.next()? };
        let path = parts.last()?;
        let &[staged, worktree] = xy else {
            return None;
        };
        let status = match (kind, staged, worktree) {
            (b'?', ..) => Status::New,
            (b'u', ..) => Status::Conflicted,
            (_, _, b'D') | (b'1', b'D', _) => Status::Deleted,
            (b'2', b'R', _) => Status::Renamed,
            (b'2', ..) | (b'1', b'A', _) | (b'1', _, b'A') => Status::New,
            (b'1', b'M' | b'T', _) | (b'1', _, b'M' | b'T') => Status::Modified,
            _ => continue,
        };
        if kind == b'2' {
            // The path it was renamed or copied from.
            records.next()?;
        }
        let path = path.strip_suffix(b"/").unwrap_or(path);
        files.insert(path.to_vec(), status);
    }
    Some(files)
}

#[cfg(test)]
mod tests {
    use super::super::tests::{git, repo, run, write};
    use super::*;
    use std::fs;
    use std::os::unix::fs::{PermissionsExt, symlink};

    fn statuses(folder: &Path) -> Vec<(String, Status)> {
        status(folder)
            .unwrap()
            .files
            .into_iter()
            .map(|(path, status)| (path.to_str().unwrap().to_owned(), status))
            .collect()
    }

    #[test]
    fn states_match_git_status() {
        let (_dir, root) = repo(&[
            (
                ".gitignore",
                b"*.log\nbuild/\n!keep.log\n/docs/drafts/\n**/cache\n",
            ),
            ("README.md", b"# Readme\n"),
            ("a.md", b"# A\n"),
            ("b.md", b"# B\n"),
            ("c.md", b"# C\n"),
            ("d.md", b"# D\n"),
            ("e.md", b"# E\n"),
            ("moved.md", b"# Moved\n"),
            ("exec.sh", b"echo\n"),
            ("conflict.md", b"base\n"),
            ("docs/plan.md", b"# Plan\n"),
            ("docs/nested/.gitignore", b"*.tmp\n"),
            ("docs/nested/n.md", b"n\n"),
            ("old/name.md", b"# Name\n"),
            (
                "guide.md",
                b"# Guide\n\nOne.\n\nTwo.\n\nThree.\n\nFour.\n\nFive.\n",
            ),
        ]);
        symlink("a.md", root.join("link")).unwrap();
        git(&root, &["add", "link"]);
        git(&root, &["commit", "-q", "-m", "base"]);
        git(&root, &["checkout", "-q", "-b", "theirs"]);
        write(&root, "conflict.md", b"theirs\n");
        git(&root, &["commit", "-q", "-am", "theirs"]);
        git(&root, &["checkout", "-q", "main"]);
        write(&root, "conflict.md", b"ours\n");
        git(&root, &["commit", "-q", "-am", "ours"]);
        assert!(!run(&root, &["merge", "-q", "theirs"]).status.success());

        // Same length, so only the bytes tell.
        write(&root, "a.md", b"# Z\n");
        write(&root, "b.md", b"# B, staged\n");
        git(&root, &["add", "b.md"]);
        fs::remove_file(root.join("c.md")).unwrap();
        git(&root, &["rm", "-q", "d.md"]);
        git(&root, &["rm", "-q", "--cached", "e.md"]);
        fs::create_dir(root.join("new")).unwrap();
        git(&root, &["mv", "old/name.md", "new/name.md"]);
        write(&root, "new/name.md", b"# Name, edited\n");
        // Renamed with its content changed, and staged.
        git(&root, &["mv", "guide.md", "new/guide.md"]);
        write(
            &root,
            "new/guide.md",
            b"# Guide\n\nOne.\n\nTwo.\n\nThree, edited.\n\nFour.\n\nFive.\n",
        );
        git(&root, &["add", "new/guide.md"]);
        fs::rename(root.join("moved.md"), root.join("moved2.md")).unwrap();
        fs::set_permissions(root.join("exec.sh"), fs::Permissions::from_mode(0o755)).unwrap();
        fs::remove_file(root.join("link")).unwrap();
        symlink("b.md", root.join("link")).unwrap();
        write(&root, "staged.md", b"staged\n");
        git(&root, &["add", "staged.md"]);
        write(&root, "ita.md", b"intent\n");
        git(&root, &["add", "-N", "ita.md"]);
        for (name, bytes) in [
            ("notes.md", &b"untracked\n"[..]),
            ("two words.md", b"untracked\n"),
            ("docs/new.md", b"new\n"),
            ("fresh/x.md", b"x\n"),
            ("fresh/y/z.md", b"z\n"),
            ("keep.log", b"kept\n"),
            ("secret.md", b"excluded\n"),
            // Ignored, or folders holding only ignored files.
            ("x.log", b""),
            ("junk/a.log", b""),
            ("build/out.txt", b""),
            ("docs/nested/t.tmp", b""),
            ("docs/drafts/d.md", b""),
            ("deep/cache/c.txt", b""),
        ] {
            write(&root, name, bytes);
        }
        fs::create_dir(root.join("empty")).unwrap();
        fs::create_dir(root.join("inner")).unwrap();
        git(&root.join("inner"), &["init", "-q"]);
        write(&root, ".git/info/exclude", b"secret.md\n");
        // A global ignore file, named here in the repository's config.
        write(&root, ".git/ignore-everywhere", b".DS_Store\n*.local\n");
        let excludes = root.join(".git/ignore-everywhere");
        git(
            &root,
            &["config", "core.excludesFile", excludes.to_str().unwrap()],
        );
        write(&root, ".DS_Store", b"");
        write(&root, "docs/env.local", b"");

        use Status::*;
        let expected = [
            ("a.md", Modified),
            ("b.md", Modified),
            ("c.md", Deleted),
            ("conflict.md", Conflicted),
            ("d.md", Deleted),
            ("docs/new.md", New),
            ("e.md", New),
            ("exec.sh", Modified),
            ("fresh", New),
            ("inner", New),
            ("ita.md", New),
            ("keep.log", New),
            ("link", Modified),
            ("moved.md", Deleted),
            ("moved2.md", New),
            ("new/guide.md", Renamed),
            ("new/name.md", Renamed),
            ("notes.md", New),
            ("staged.md", New),
            ("two words.md", New),
        ];
        let expected: Vec<_> = expected
            .iter()
            .map(|&(path, status)| (path.to_owned(), status))
            .collect();
        assert_eq!(statuses(&root), expected);
        assert_eq!(status(&root).unwrap().gitdir, root.join(".git"));

        // A rename into a folder from outside it is still a rename.
        assert_eq!(
            statuses(&root.join("new")),
            [
                ("guide.md".to_owned(), Renamed),
                ("name.md".to_owned(), Renamed)
            ]
        );

        // A folder inside the repository: its files, by their paths from it.
        write(&root, "docs/plan.md", b"# Plan, edited\n");
        assert_eq!(
            statuses(&root.join("docs")),
            [("new.md".to_owned(), New), ("plan.md".to_owned(), Modified)]
        );
        assert_eq!(statuses(&root.join("docs/drafts")), []);

        // Folders inside an untracked one: each file or folder under them.
        assert_eq!(
            statuses(&root.join("fresh")),
            [("x.md".to_owned(), New), ("y".to_owned(), New)]
        );
        assert_eq!(statuses(&root.join("fresh/y")), [("z.md".to_owned(), New)]);

        // HEAD's c.md is not under a folder now at its path.
        fs::create_dir(root.join("c.md")).unwrap();
        assert_eq!(statuses(&root.join("c.md")), []);
    }

    #[test]
    fn linked_worktrees() {
        let (_dir, root) = repo(&[("CLAUDE.md", b"# Claude\n")]);
        git(&root, &["commit", "-q", "-m", "base"]);
        git(&root, &["worktree", "add", "-q", "-b", "side", "wt"]);
        let worktree = root.join("wt");
        assert_eq!(statuses(&worktree), []);
        write(&worktree, "CLAUDE.md", b"# Side\n");
        let found = status(&worktree).unwrap();
        assert_eq!(found.gitdir, root.join(".git/worktrees/wt"));
        assert_eq!(
            found.files,
            [(PathBuf::from("CLAUDE.md"), Status::Modified)]
        );
    }

    #[test]
    fn unborn_branches_and_no_repository() {
        let (_dir, root) = repo(&[("CLAUDE.md", b"# Claude\n"), ("docs/plan.md", b"plan\n")]);
        assert_eq!(
            statuses(&root),
            [
                ("CLAUDE.md".to_owned(), Status::New),
                ("docs/plan.md".to_owned(), Status::New)
            ]
        );
        let outside = tempfile::tempdir().unwrap();
        assert_eq!(status(&outside.path().canonicalize().unwrap()), None);
    }
}
