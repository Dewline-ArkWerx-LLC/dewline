//! Markdown any CommonMark or GFM renderer shows as Dewline does: wikilinks as relative links, embeds as images or
//! links, highlights as `<mark>`, comments left out, and images inside the note's folder copied beside the export.
//! Everything else stays as written.

use std::collections::HashMap;
use std::fs;
use std::ops::Range;
use std::path::Path;

use super::{encode, files_folder, read_image, slug};
use crate::md::{self, TokenKind};

/// How many folder entries a wikilink's search reads at most.
const MAX_ENTRIES: usize = 50_000;

/// `markdown`, a note in `folder`, as Markdown named `name`, and the images to write beside it, each at a path relative
/// to the export's folder.
pub fn portable(
    markdown: &str,
    name: &str,
    folder: Option<&Path>,
) -> (String, Vec<(String, Vec<u8>)>) {
    let tokens: Vec<_> = md::parse(markdown)
        .tokens
        .into_iter()
        .filter(|token| {
            matches!(
                token.kind,
                TokenKind::WikiLink
                    | TokenKind::Embed
                    | TokenKind::Highlight
                    | TokenKind::Comment
                    | TokenKind::Image
            )
        })
        .collect();
    let bytes = byte_offsets(
        markdown,
        tokens.iter().flat_map(|token| {
            [
                token.start,
                token.content_start,
                token.content_end,
                token.end,
            ]
        }),
    );
    let mut images = Images {
        folder,
        files_folder: files_folder(name),
        copied: HashMap::new(),
        files: Vec::new(),
    };
    let mut edits: Vec<(Range<usize>, String)> = Vec::new();
    for token in &tokens {
        let [start, open, close, end] = [
            token.start,
            token.content_start,
            token.content_end,
            token.end,
        ]
        .map(|at| bytes[&at]);
        let content = &markdown[open..close];
        // A wikilink's or embed's target is its content, or the opening marker's text before `|` when an alias follows.
        let target = |marker: usize| match markdown[start + marker..open].strip_suffix('|') {
            Some(target) => target,
            None => content,
        };
        match token.kind {
            TokenKind::Comment => edits.push((start..end, String::new())),
            TokenKind::Highlight => {
                edits.push((start..open, "<mark>".into()));
                edits.push((close..end, "</mark>".into()));
            }
            TokenKind::WikiLink => {
                let link = note_link(target(2), folder);
                edits.push((start..end, format!("[{content}]({link})")));
            }
            TokenKind::Embed => {
                let target = target(3);
                let image = Path::new(target).extension().is_some_and(|extension| {
                    ["png", "jpg", "jpeg", "gif", "webp", "svg"]
                        .contains(&extension.to_ascii_lowercase().to_str().unwrap_or(""))
                });
                let replacement = if image {
                    let path = images.copy(target).unwrap_or_else(|| encode(target));
                    format!("![]({path})")
                } else {
                    format!("[{target}]({})", note_link(target, folder))
                };
                edits.push((start..end, replacement));
            }
            _ => {
                if let Some(at) = destination(&markdown[close..end])
                    && let Some(path) = images.copy(&markdown[close..end][at.clone()])
                {
                    edits.push((close + at.start..close + at.end, path));
                }
            }
        }
    }
    edits.sort_by_key(|(range, _)| range.start);
    let mut out = String::with_capacity(markdown.len());
    let mut done = 0;
    for (range, text) in edits {
        // An edit inside a comment goes with it.
        if range.start < done {
            continue;
        }
        out.push_str(&markdown[done..range.start]);
        out.push_str(&text);
        done = range.end;
    }
    out.push_str(&markdown[done..]);
    (out, images.files)
}

struct Images<'a> {
    folder: Option<&'a Path>,
    files_folder: String,
    /// The link to each image copied, by its address in the note.
    copied: HashMap<String, String>,
    files: Vec<(String, Vec<u8>)>,
}

impl Images<'_> {
    /// The link to the copy of the image at `address` inside the note's folder, at the same path inside the export's.
    fn copy(&mut self, address: &str) -> Option<String> {
        if let Some(link) = self.copied.get(address) {
            return Some(link.clone());
        }
        let (_, bytes) = read_image(self.folder?, address)?;
        let path = format!("{}/{}", self.files_folder, address.trim_start_matches("./"));
        let link = encode(&path);
        self.files.push((path, bytes));
        self.copied.insert(address.to_owned(), link.clone());
        Some(link)
    }
}

/// Where the destination lies in an image's closing marker, `](address)` or `](address "title")`, with or without
/// angle brackets; `None` for a reference.
fn destination(closing: &str) -> Option<Range<usize>> {
    let inner = closing.strip_prefix("](")?.strip_suffix(')')?;
    let start = 2 + inner.len() - inner.trim_start().len();
    let rest = &closing[start..closing.len() - 1];
    if let Some(bracketed) = rest.strip_prefix('<') {
        return Some(start + 1..start + 1 + bracketed.find('>')?);
    }
    let length = rest.find(char::is_whitespace).unwrap_or(rest.len());
    (length > 0).then(|| start..start + length)
}

/// A wikilink target, `note`, `note.md`, `folder/note`, `note#heading` or `#heading`, as a relative link: the note found
/// by name in `folder` or below it, ignoring case, the shortest path winning, else `note.md` beside the export.
fn note_link(target: &str, folder: Option<&Path>) -> String {
    let (name, heading) = match target.split_once('#') {
        Some((name, heading)) => (name.trim(), Some(heading.trim())),
        None => (target.trim(), None),
    };
    let fragment = heading.map_or(String::new(), |heading| format!("#{}", slug(heading)));
    if name.is_empty() {
        return fragment;
    }
    let stem = name.strip_suffix(".md").unwrap_or(name);
    let found = folder.and_then(|folder| {
        let mut entries = 0;
        find(folder, "", &stem.to_lowercase(), &mut entries)
    });
    encode(&found.unwrap_or_else(|| format!("{stem}.md"))) + &fragment
}

/// The shortest path below `folder`, from `prefix`, of a `.md` file whose path without the extension is `stem` or ends
/// with `/stem`, compared in lowercase. Hidden entries and symbolic links are passed over.
fn find(folder: &Path, prefix: &str, stem: &str, entries: &mut usize) -> Option<String> {
    let mut best: Option<String> = None;
    let mut folders = Vec::new();
    for entry in fs::read_dir(folder).ok()?.flatten() {
        *entries += 1;
        if *entries > MAX_ENTRIES {
            break;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        if name.starts_with('.') {
            continue;
        }
        let path = format!("{prefix}{name}");
        if kind.is_dir() {
            folders.push((entry.path(), path));
        } else if kind.is_file()
            && let Some(relative) = path.to_lowercase().strip_suffix(".md")
            && (relative == stem || relative.ends_with(&format!("/{stem}")))
            && best.as_ref().is_none_or(|best| path.len() < best.len())
        {
            best = Some(path);
        }
    }
    for (folder, path) in folders {
        if let Some(found) = find(&folder, &format!("{path}/"), stem, entries)
            && best.as_ref().is_none_or(|best| found.len() < best.len())
        {
            best = Some(found);
        }
    }
    best
}

/// The byte offset in `text` of each UTF-16 offset in `points`.
fn byte_offsets(text: &str, points: impl Iterator<Item = u32>) -> HashMap<u32, usize> {
    let mut points: Vec<u32> = points.collect();
    points.sort_unstable();
    points.dedup();
    let mut offsets = HashMap::with_capacity(points.len());
    let mut wanted = points.into_iter().peekable();
    let mut utf16 = 0;
    for (byte, c) in text.char_indices().chain([(text.len(), '\0')]) {
        while wanted.next_if(|&point| point <= utf16).is_some() {
            offsets.insert(utf16, byte);
        }
        utf16 += c.len_utf16() as u32;
    }
    offsets
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wikilinks_become_relative_links_to_the_notes_they_name() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join("projects/old")).unwrap();
        fs::write(dir.path().join("projects/Launch plan.md"), "").unwrap();
        fs::write(dir.path().join("projects/old/launch plan.md"), "").unwrap();
        let (out, files) = portable(
            "See [[Launch plan]], [[launch plan.md#Risks & dates|the *risks*]], [[#Top]] and [[nope]]. `[[code]]`\n",
            "notes",
            Some(dir.path()),
        );
        assert_eq!(
            out,
            "See [Launch plan](projects/Launch%20plan.md), [the *risks*](projects/Launch%20plan.md#risks--dates), \
             [#Top](#top) and [nope](nope.md). `[[code]]`\n"
        );
        assert!(files.is_empty());
    }

    #[test]
    fn images_inside_the_folder_are_copied_and_their_links_follow() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir(dir.path().join("attachments")).unwrap();
        let png = b"\x89PNG\r\n\x1a\nrest".to_vec();
        fs::write(dir.path().join("attachments/ferry at dawn.png"), &png).unwrap();
        fs::write(dir.path().join("dot.png"), &png).unwrap();
        let (out, files) = portable(
            "![Ferry](attachments/ferry%20at%20dawn.png) ![Ferry](<attachments/ferry at dawn.png> \"Dawn\")\n\n\
             ![[dot.png|300]] ![[Launch plan]] ![web](https://x.dev/a.png) ![up](../up.png) ![[gone.png]]\n",
            "Field notes",
            Some(dir.path()),
        );
        assert_eq!(
            out,
            "![Ferry](attachments/ferry%20at%20dawn.png) ![Ferry](<Field-notes-files/attachments/ferry%20at%20dawn.png> \
             \"Dawn\")\n\n![](Field-notes-files/dot.png) [Launch plan](Launch%20plan.md) ![web](https://x.dev/a.png) \
             ![up](../up.png) ![](gone.png)\n"
        );
        let names: Vec<&str> = files.iter().map(|(name, _)| name.as_str()).collect();
        assert_eq!(
            names,
            [
                "Field-notes-files/attachments/ferry at dawn.png",
                "Field-notes-files/dot.png"
            ]
        );
        assert_eq!(files[0].1, png);
    }

    #[test]
    fn highlights_become_mark_and_comments_go() {
        let (out, _) = portable(
            "Ünïcode ==keep [[a]]== and %%hidden [[b]]%% done.\n\n%%\nblock\n%%\n\nEnd.\n",
            "n",
            None,
        );
        assert_eq!(
            out,
            "Ünïcode <mark>keep [a](a.md)</mark> and  done.\n\n\n\nEnd.\n"
        );
    }
}
