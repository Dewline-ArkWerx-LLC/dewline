use std::path::Path;
use std::sync::Arc;

use dewline_core::{links, loads};

use crate::markdown::Text;

use crate::{Panicked, contained};

/// One file an agent loads in a folder.
#[derive(uniffi::Record)]
pub struct LoadedFile {
    pub agent: String,
    pub path: String,
    /// "walk", "@import from CLAUDE.md", or a Cursor rule's trigger.
    pub how: String,
    /// The file's bytes / 4.
    pub tokens: u64,
}

/// What Claude Code, Codex and Cursor load for a session started in `folder`.
#[uniffi::export]
pub fn what_loads(folder: String, home: Option<String>) -> Result<Vec<LoadedFile>, Panicked> {
    contained(|| {
        loads::what_loads(Path::new(&folder), home.as_deref().map(Path::new))
            .into_iter()
            .map(|loaded| LoadedFile {
                agent: loaded.vendor.title().into(),
                path: loaded.path.to_string_lossy().into_owned(),
                how: loaded.how,
                tokens: loaded.tokens,
            })
            .collect()
    })
}

/// A broken link or import in a file's text, in UTF-16 offsets.
#[derive(uniffi::Record)]
pub struct BrokenLink {
    pub location: u64,
    pub length: u64,
    pub target: String,
    pub problem: String,
}

/// The broken links and imports of `text`, the file at `path`.
#[uniffi::export]
pub fn broken_links(
    path: String,
    text: Arc<Text>,
    home: Option<String>,
) -> Result<Vec<BrokenLink>, Panicked> {
    contained(|| {
        let file = Path::new(&path);
        let text = text.lock();
        let utf16 = |byte: usize| text[..byte].encode_utf16().count() as u64;
        links::broken(file, &text, home.as_deref().map(Path::new))
            .into_iter()
            .filter(|broken| broken.file == file)
            .map(|broken| {
                let start = utf16(broken.target.range.start);
                BrokenLink {
                    location: start,
                    length: utf16(broken.target.range.end) - start,
                    target: broken.target.text,
                    problem: broken.problem.describe().into(),
                }
            })
            .collect()
    })
}
