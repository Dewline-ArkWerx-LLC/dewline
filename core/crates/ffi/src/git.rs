use std::path::Path;
use std::sync::{Mutex, PoisonError};

use dewline_core::git::status::{self, Ignores, Status};

use crate::{Panicked, contained};

#[derive(uniffi::Enum)]
pub enum GitState {
    Modified,
    New,
    Deleted,
    Renamed,
    Conflicted,
}

#[derive(uniffi::Record)]
pub struct GitFile {
    /// From the folder asked about.
    pub path: String,
    pub state: GitState,
}

#[derive(uniffi::Record)]
pub struct GitStatus {
    /// The folder that holds the repository's index and HEAD.
    pub gitdir: String,
    pub files: Vec<GitFile>,
}

/// The files under `folder` that differ from HEAD or the index. An untracked
/// folder with no tracked file is one path. None when the folder is in no
/// repository or the repository can't be read.
#[uniffi::export]
pub fn git_status(folder: String) -> Result<Option<GitStatus>, Panicked> {
    contained(|| {
        let folder = Path::new(&folder).canonicalize().ok()?;
        let found = status::status(&folder)?;
        Some(GitStatus {
            gitdir: found.gitdir.to_string_lossy().into_owned(),
            files: found
                .files
                .into_iter()
                .map(|(path, status)| GitFile {
                    path: path.to_string_lossy().into_owned(),
                    state: match status {
                        Status::Modified => GitState::Modified,
                        Status::New => GitState::New,
                        Status::Deleted => GitState::Deleted,
                        Status::Renamed => GitState::Renamed,
                        Status::Conflicted => GitState::Conflicted,
                    },
                })
                .collect(),
        })
    })
}

/// What git ignores under a folder: its repository's ignore files and
/// `core.excludesFile`, or the folder's own .gitignore files when no
/// repository holds it. One for the sidebar and `git_status`.
#[derive(uniffi::Object)]
pub struct GitIgnores {
    ignores: Mutex<Ignores>,
    /// The folder's path from the work tree's top.
    prefix: Vec<u8>,
}

#[uniffi::export]
impl GitIgnores {
    #[uniffi::constructor]
    pub fn new(folder: String) -> Self {
        let folder = Path::new(&folder);
        let (ignores, prefix) = Ignores::of(&folder.canonicalize().unwrap_or(folder.to_path_buf()));
        Self {
            ignores: Mutex::new(ignores),
            prefix,
        }
    }

    /// Whether git ignores `path`, "/"-separated from the folder: it or a
    /// folder above it matches.
    pub fn ignores(&self, path: String, is_folder: bool) -> Result<bool, Panicked> {
        contained(|| {
            let path = if self.prefix.is_empty() {
                path.into_bytes()
            } else {
                [&self.prefix, b"/".as_slice(), path.as_bytes()].concat()
            };
            self.ignores
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .ignored(&path, is_folder)
        })
    }
}
