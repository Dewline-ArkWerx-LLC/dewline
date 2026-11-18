use std::path::{Path, PathBuf};

use dewline_core::notelinks::{self, Notes};

/// A line that links to a note. Offsets are UTF-16 code units in the file's text after any byte-order mark.
#[derive(uniffi::Record)]
pub struct Backlink {
    pub path: String,
    /// Counted from 1.
    pub line: u32,
    pub start: u32,
    pub end: u32,
    /// The line, trimmed.
    pub preview: String,
}

/// An open note's path and the text its editor holds.
#[derive(uniffi::Record)]
pub struct OpenNote {
    pub path: String,
    pub text: String,
}

/// Replaces UTF-16 code units `start..end` with `text`.
#[derive(uniffi::Record)]
pub struct LinkEdit {
    pub start: u32,
    pub end: u32,
    pub text: String,
}

fn utf16(text: &str, byte: usize) -> u32 {
    text[..byte].encode_utf16().count() as u32
}

fn relative(root: &Path, path: &str) -> Option<PathBuf> {
    Path::new(path)
        .strip_prefix(root)
        .ok()
        .map(Path::to_path_buf)
}

/// The notes under `root`, root-relative, in name order: `.md`, `.markdown` and `.txt` files outside dot folders.
#[uniffi::export]
pub fn note_paths(root: String) -> Vec<String> {
    notelinks::walk(Path::new(&root))
        .into_iter()
        .map(|path| path.to_string_lossy().into_owned())
        .collect()
}

/// The lines in the other notes under `root` that link to `note` by wikilink or markdown link, at most 200.
#[uniffi::export]
pub fn note_backlinks(root: String, note: String) -> Vec<Backlink> {
    let root = Path::new(&root);
    let Some(target) = relative(root, &note) else {
        return Vec::new();
    };
    let notes = Notes::new(notelinks::walk(root));
    let mut found = Vec::new();
    for source in notes.paths() {
        let Some(text) = notelinks::read(&root.join(source)) else {
            continue;
        };
        let text = text.strip_prefix('\u{feff}').unwrap_or(&text);
        for link in notelinks::backlinks(text, source, &notes, &target) {
            found.push(Backlink {
                path: root.join(source).to_string_lossy().into_owned(),
                line: link.line as u32,
                start: utf16(text, link.link.start),
                end: utf16(text, link.link.end),
                preview: link.text,
            });
            if found.len() == 200 {
                return found;
            }
        }
    }
    found
}

/// Points the links to the note renamed from `old` to `new` in the notes under `root` at its new name. Closed notes
/// change on disk; for each of `open`, the edits its text takes, in order.
#[uniffi::export]
pub fn relink_notes(
    root: String,
    old: String,
    new: String,
    open: Vec<OpenNote>,
) -> Vec<Vec<LinkEdit>> {
    let root = Path::new(&root);
    let (Some(old), Some(new)) = (relative(root, &old), relative(root, &new)) else {
        return open.iter().map(|_| Vec::new()).collect();
    };
    let mut paths = notelinks::walk(root);
    paths.retain(|path| *path != new);
    paths.push(old.clone());
    let notes = Notes::new(paths);
    let skipping: Vec<PathBuf> = open
        .iter()
        .filter_map(|note| relative(root, &note.path))
        .collect();
    notelinks::rewrite(root, &notes, &old, &new, &skipping);
    open.iter()
        .map(|note| {
            let Some(source) = relative(root, &note.path) else {
                return Vec::new();
            };
            let source = if source == new { old.clone() } else { source };
            notelinks::relink(&note.text, &source, &notes, &old, &new)
                .into_iter()
                .map(|(range, text)| LinkEdit {
                    start: utf16(&note.text, range.start),
                    end: utf16(&note.text, range.end),
                    text,
                })
                .collect()
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renames_relink_open_and_closed_notes() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().to_str().unwrap().to_owned();
        let path = |name: &str| dir.path().join(name).to_str().unwrap().to_owned();
        std::fs::write(path("new.md"), "# Plan").unwrap();
        std::fs::write(path("closed.md"), "See [[old]].").unwrap();
        let open = OpenNote {
            path: path("open.md"),
            text: "é [[old]] and [[old]]".into(),
        };
        let edits = relink_notes(root.clone(), path("old.md"), path("new.md"), vec![open]);
        let starts: Vec<_> = edits[0]
            .iter()
            .map(|edit| (edit.start, edit.end, edit.text.as_str()))
            .collect();
        assert_eq!(starts, [(4, 7, "new"), (16, 19, "new")]);
        assert_eq!(
            std::fs::read_to_string(path("closed.md")).unwrap(),
            "See [[new]]."
        );
        let links = note_backlinks(root, path("new.md"));
        assert_eq!(
            links
                .iter()
                .map(|link| (link.line, link.start, link.end))
                .collect::<Vec<_>>(),
            [(1, 4, 11)]
        );
    }
}
