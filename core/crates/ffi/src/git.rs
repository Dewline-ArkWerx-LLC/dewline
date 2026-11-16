use std::path::Path;

use dewline_core::git::status::{self, Status};

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
pub fn git_status(folder: String) -> Option<GitStatus> {
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
}
