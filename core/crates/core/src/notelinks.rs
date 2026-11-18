//! Links between the notes in a folder: wikilinks and relative markdown links, the note each names, the lines that
//! link to a note, and the edits that keep links on a note through a rename.

use std::collections::HashMap;
use std::fs;
use std::ops::Range;
use std::path::{Component, Path, PathBuf};

use pulldown_cmark::{Event, LinkType, Options, Parser, Tag, TagEnd};

use crate::file;

/// `walk` lists at most this many notes.
pub const MAX_NOTES: usize = 20_000;
/// The most a note read from disk holds.
pub const MAX_NOTE: u64 = 8 << 20;

/// The notes under `root`, root-relative, in name order. Links are skipped, not followed.
pub fn walk(root: &Path) -> Vec<PathBuf> {
    let mut notes = Vec::new();
    visit(root, Path::new(""), &mut notes);
    notes
}

fn visit(root: &Path, folder: &Path, notes: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(root.join(folder)) else {
        return;
    };
    let mut entries: Vec<_> = entries.flatten().collect();
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        if notes.len() == MAX_NOTES {
            return;
        }
        let relative = folder.join(entry.file_name());
        match entry.file_type() {
            Ok(kind) if kind.is_dir() && !hidden(&relative) => visit(root, &relative, notes),
            Ok(kind) if kind.is_file() && is_note(&relative) => notes.push(relative),
            _ => {}
        }
    }
}

fn hidden(relative: &Path) -> bool {
    relative
        .components()
        .any(|part| part.as_os_str().as_encoded_bytes().starts_with(b"."))
}

/// A `.md`, `.markdown` or `.txt` file outside dot folders, and not a dotfile itself.
pub fn is_note(relative: &Path) -> bool {
    !hidden(relative)
        && relative.extension().is_some_and(|extension| {
            ["md", "markdown", "txt"]
                .iter()
                .any(|note| extension.eq_ignore_ascii_case(note))
        })
}

/// A folder's notes, root-relative, indexed for wikilinks.
pub struct Notes {
    paths: Vec<PathBuf>,
    /// Each note by its last name in lowercase, `.md` dropped: its path the same way, and its index in `paths`.
    by_name: HashMap<String, Vec<(String, usize)>>,
}

impl Notes {
    pub fn new(paths: Vec<PathBuf>) -> Notes {
        let mut by_name: HashMap<String, Vec<(String, usize)>> = HashMap::new();
        for (index, path) in paths.iter().enumerate() {
            let key = key(&path.to_string_lossy());
            let name = key.rsplit('/').next().unwrap_or_default().to_owned();
            by_name.entry(name).or_default().push((key, index));
        }
        Notes { paths, by_name }
    }

    pub fn paths(&self) -> &[PathBuf] {
        &self.paths
    }

    /// The note a wikilink's name gives: `note`, `note.md` or `folder/note`, ignoring case. The note's path must be
    /// the name or end with `/` and the name; the shortest path wins, then the first.
    pub fn resolve(&self, name: &str) -> Option<&Path> {
        let name = key(name.trim());
        if name.is_empty() || name.starts_with('/') || name.split('/').any(|part| part == "..") {
            return None;
        }
        let last = name.rsplit('/').next().unwrap_or_default();
        let suffix = format!("/{name}");
        self.by_name
            .get(last)?
            .iter()
            .filter(|(key, _)| *key == name || key.ends_with(&suffix))
            .min_by_key(|(key, index)| (key.len(), *index))
            .map(|(_, index)| self.paths[*index].as_path())
    }
}

/// A path or name in lowercase, without a `.md` extension.
fn key(text: &str) -> String {
    let lower = text.to_lowercase();
    match lower.strip_suffix(".md") {
        Some(stem) => stem.to_owned(),
        None => lower,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Wiki,
    Markdown,
    /// A reference definition, `[label]: path`.
    Definition,
}

/// A link from one note to another.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Link {
    pub kind: Kind,
    /// The whole link or definition, in bytes.
    pub range: Range<usize>,
    /// The note, root-relative.
    pub target: PathBuf,
    /// The bytes naming the file as written: a wikilink's name, a destination's last part. A reference link has none;
    /// its definition does.
    pub name: Option<Range<usize>>,
}

const OPTIONS: Options = Options::ENABLE_TABLES
    .union(Options::ENABLE_FOOTNOTES)
    .union(Options::ENABLE_STRIKETHROUGH)
    .union(Options::ENABLE_TASKLISTS)
    .union(Options::ENABLE_MATH)
    .union(Options::ENABLE_WIKILINKS)
    .union(Options::ENABLE_YAML_STYLE_METADATA_BLOCKS);

/// A markdown link waiting for its end: the link, its note, whether its destination follows its text, and where its
/// text ends so far.
struct Open {
    range: Range<usize>,
    target: Option<PathBuf>,
    inline: bool,
    text_end: usize,
}

/// The links in `text`, the note at `source`, to notes: wikilinks that name one of `notes`, and relative markdown
/// links and reference definitions, outside code. Wikilinks come first.
pub fn links(text: &str, source: &Path, notes: &Notes) -> Vec<Link> {
    let folder = source.parent().unwrap_or(Path::new(""));
    let mut found = Vec::new();
    let mut open: Vec<Option<Open>> = Vec::new();
    let mut iter = Parser::new_ext(text, OPTIONS).into_offset_iter();
    for (event, range) in &mut iter {
        if let Some(Some(link)) = open.last_mut()
            && !matches!(event, Event::End(_))
        {
            link.text_end = link.text_end.max(range.end);
        }
        match event {
            Event::Start(Tag::Link {
                link_type,
                dest_url,
                ..
            })
            | Event::Start(Tag::Image {
                link_type,
                dest_url,
                ..
            }) => {
                if let LinkType::WikiLink { .. } = link_type {
                    found.extend(wikilink(text, range, notes));
                    open.push(None);
                    continue;
                }
                let text_end = range.start + text[range.clone()].find('[').map_or(0, |at| at + 1);
                open.push(Some(Open {
                    target: local(&dest_url, folder),
                    inline: link_type == LinkType::Inline,
                    range,
                    text_end,
                }));
            }
            Event::End(TagEnd::Link | TagEnd::Image) => {
                let Some(Some(link)) = open.pop() else {
                    continue;
                };
                let Some(target) = link.target else {
                    continue;
                };
                let name = if link.inline {
                    text[link.text_end..link.range.end]
                        .starts_with("](")
                        .then(|| destination(text, link.text_end + 2, link.range.end))
                        .flatten()
                } else {
                    None
                };
                found.push(Link {
                    kind: Kind::Markdown,
                    range: link.range,
                    target,
                    name,
                });
            }
            _ => {}
        }
    }
    let mut definitions: Vec<Link> = iter
        .reference_definitions()
        .iter()
        .filter_map(|(_, definition)| {
            let target = local(&definition.dest, folder)?;
            let span = definition.span.clone();
            let colon = span.start + text[span.clone()].find("]:")? + 2;
            Some(Link {
                kind: Kind::Definition,
                name: destination(text, colon, span.end),
                range: span,
                target,
            })
        })
        .collect();
    definitions.sort_by_key(|link| link.range.start);
    found.extend(definitions);
    found
}

/// The wikilink or embed at `range` when it names one of `notes`.
fn wikilink(text: &str, range: Range<usize>, notes: &Notes) -> Option<Link> {
    let whole = &text[range.clone()];
    let open = range.start + whole.find("[[")? + 2;
    let close = range.end.checked_sub(2).filter(|_| whole.ends_with("]]"))?;
    let inner = text.get(open..close)?;
    let end = open + inner.find(['|', '#']).unwrap_or(inner.len());
    let written = &text[open..end];
    let start = open + (written.len() - written.trim_start().len());
    let end = start + written.trim().len();
    let target = notes.resolve(&text[start..end])?.to_path_buf();
    Some(Link {
        kind: Kind::Wiki,
        range,
        target,
        name: Some(start..end),
    })
}

/// The bytes of the destination starting at or after `from` (spaces skipped), up to its `#` or `?`, from its last
/// `/` on; none when it is empty.
fn destination(text: &str, from: usize, until: usize) -> Option<Range<usize>> {
    let bytes = &text.as_bytes()[..until];
    let mut at = from;
    while at < bytes.len() && bytes[at].is_ascii_whitespace() {
        at += 1;
    }
    let (start, end) = if bytes.get(at) == Some(&b'<') {
        let start = at + 1;
        let end = start + text[start..until].find('>')?;
        (start, end)
    } else {
        let start = at;
        let mut depth = 0;
        while at < bytes.len() {
            match bytes[at] {
                b'\\' => at += 1,
                b'(' => depth += 1,
                b')' if depth == 0 => break,
                b')' => depth -= 1,
                byte if byte.is_ascii_whitespace() => break,
                _ => {}
            }
            at += 1;
        }
        (start, at.min(bytes.len()))
    };
    let path = &text[start..end];
    let end = start + path.find(['#', '?']).unwrap_or(path.len());
    let last = text[start..end]
        .rfind('/')
        .map_or(start, |slash| start + slash + 1);
    (last < end).then_some(last..end)
}

/// A destination's note, root-relative, or none for an address, an anchor here, a path from the top, or one that
/// climbs out of the root.
fn local(destination: &str, folder: &Path) -> Option<PathBuf> {
    let path = destination.split(['#', '?']).next().unwrap_or_default();
    let scheme = path.find(':').is_some_and(|colon| {
        path[..colon]
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"+.-".contains(&byte))
    });
    if path.is_empty() || path.starts_with('/') || scheme {
        return None;
    }
    let mut out = PathBuf::new();
    for part in folder.join(decode(path)).components() {
        match part {
            Component::Normal(name) => out.push(name),
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    return None;
                }
            }
            Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    Some(out)
}

/// `text` with its `%XX` escapes decoded.
fn decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        let hex = bytes
            .get(at + 1..at + 3)
            .and_then(|hex| std::str::from_utf8(hex).ok())
            .and_then(|hex| u8::from_str_radix(hex, 16).ok());
        match (bytes[at], hex) {
            (b'%', Some(byte)) => {
                out.push(byte);
                at += 3;
            }
            (byte, _) => {
                out.push(byte);
                at += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn same(a: &Path, b: &Path) -> bool {
    a.to_string_lossy().to_lowercase() == b.to_string_lossy().to_lowercase()
}

/// A line that links to a note.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Backlink {
    /// Counted from 1.
    pub line: usize,
    /// The line's first link to the note, in bytes.
    pub link: Range<usize>,
    /// The line, trimmed, at most 240 characters.
    pub text: String,
}

/// The lines of `text`, the note at `source`, that link to `target`, by wikilink or markdown link. A note's links to
/// itself are not backlinks.
pub fn backlinks(text: &str, source: &Path, notes: &Notes, target: &Path) -> Vec<Backlink> {
    if same(source, target) {
        return Vec::new();
    }
    let mut ranges: Vec<Range<usize>> = links(text, source, notes)
        .into_iter()
        .filter(|link| link.kind != Kind::Definition && same(&link.target, target))
        .map(|link| link.range)
        .collect();
    ranges.sort_by_key(|range| range.start);
    let mut found: Vec<Backlink> = Vec::new();
    for link in ranges {
        let start = text[..link.start].rfind('\n').map_or(0, |at| at + 1);
        if found.last().is_some_and(|last| last.link.start >= start) {
            continue;
        }
        let end = text[link.start..]
            .find('\n')
            .map_or(text.len(), |at| link.start + at);
        found.push(Backlink {
            line: text[..start].matches('\n').count() + 1,
            link,
            text: text[start..end].trim().chars().take(240).collect(),
        });
    }
    found
}

/// The edits that point the links in `text`, the note at `source`, to `old` at `new` instead: each a byte range and
/// what replaces it. A wikilink keeps its form, with or without `.md`, and names the note's whole path when its name
/// alone would give another note; a destination is percent-encoded unless it was written with spaces. `notes` has the
/// note at `old`.
pub fn relink(
    text: &str,
    source: &Path,
    notes: &Notes,
    old: &Path,
    new: &Path,
) -> Vec<(Range<usize>, String)> {
    let Some(file_name) = new
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
    else {
        return Vec::new();
    };
    let stem = match new.extension() {
        Some(extension) if extension.eq_ignore_ascii_case("md") => new
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned(),
        _ => file_name.clone(),
    };
    let found: Vec<Link> = links(text, source, notes)
        .into_iter()
        .filter(|link| same(&link.target, old))
        .collect();
    let after = found.iter().any(|link| link.kind == Kind::Wiki).then(|| {
        Notes::new(
            notes
                .paths()
                .iter()
                .map(|path| if same(path, old) { new } else { path }.to_path_buf())
                .collect(),
        )
    });
    let mut edits: Vec<(Range<usize>, String)> = found
        .into_iter()
        .filter_map(|link| {
            let name = link.name?;
            let written = &text[name.clone()];
            let wanted = match (link.kind, &after) {
                (Kind::Wiki, Some(after)) => {
                    let last = if written.to_lowercase().ends_with(".md") {
                        &file_name
                    } else {
                        &stem
                    };
                    let folder = written.rfind('/').map_or("", |slash| &written[..=slash]);
                    let path = new.with_file_name(last).to_string_lossy().into_owned();
                    [format!("{folder}{last}"), path]
                        .into_iter()
                        .find(|name| after.resolve(name).is_some_and(|note| same(note, new)))?
                }
                _ if written.contains(' ') => file_name.clone(),
                _ => encode(&file_name),
            };
            (written != wanted).then_some((name, wanted))
        })
        .collect();
    edits.sort_by_key(|(range, _)| range.start);
    edits.dedup_by_key(|(range, _)| range.start);
    edits
}

/// A file name as a link destination: blanks, `%`, brackets, `#`, `?`, quotes and backslashes percent-encoded.
fn encode(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    for character in name.chars() {
        if character.is_ascii_control() || " %()<>[]#?\"\\".contains(character) {
            out.push_str(&format!("%{:02X}", character as u8));
        } else {
            out.push(character);
        }
    }
    out
}

/// A note's text, byte-order mark and all, when it is UTF-8 of at most 8 MB.
pub fn read(path: &Path) -> Option<String> {
    let info = fs::metadata(path).ok()?;
    if !info.is_file() || info.len() > MAX_NOTE {
        return None;
    }
    String::from_utf8(fs::read(path).ok()?).ok()
}

/// Points the links to `old` in the notes under `root` at `new`, the note's new path, and returns the notes it rewrote.
/// Paths are root-relative, and `notes` has the note at `old`. Notes in `skipping`, and notes that change while they
/// are rewritten, are left alone.
pub fn rewrite(
    root: &Path,
    notes: &Notes,
    old: &Path,
    new: &Path,
    skipping: &[PathBuf],
) -> Vec<PathBuf> {
    let mut rewritten = Vec::new();
    for source in notes.paths() {
        let on_disk = if same(source, old) { new } else { source };
        if skipping.iter().any(|skip| same(skip, on_disk)) {
            continue;
        }
        let path = root.join(on_disk);
        let Some(text) = read(&path) else {
            continue;
        };
        let bom = if text.starts_with('\u{feff}') { 3 } else { 0 };
        let edits = relink(&text[bom..], source, notes, old, new);
        if edits.is_empty() {
            continue;
        }
        let mut out = text.clone();
        for (range, with) in edits.iter().rev() {
            out.replace_range(range.start + bom..range.end + bom, with);
        }
        if file::save(&path, &file::hash(text.as_bytes()), out.as_bytes()).is_ok() {
            rewritten.push(on_disk.to_path_buf());
        }
    }
    rewritten
}

#[cfg(test)]
mod tests {
    use super::*;

    fn notes(paths: &[&str]) -> Notes {
        Notes::new(paths.iter().map(PathBuf::from).collect())
    }

    #[test]
    fn only_notes_outside_dot_folders_are_notes() {
        assert!(is_note(Path::new("a/b.md")));
        assert!(is_note(Path::new("a/B.MARKDOWN")));
        assert!(is_note(Path::new("todo.txt")));
        assert!(!is_note(Path::new(".git/HEAD.md")));
        assert!(!is_note(Path::new("a/.secret.md")));
        assert!(!is_note(Path::new("a/b.html")));
        assert!(!is_note(Path::new("a/md")));
    }

    #[test]
    fn walk_lists_notes_in_name_order() {
        let dir = tempfile::tempdir().unwrap();
        for path in ["b.md", "a/c.md", "a/d.png", ".hidden/e.md", "f.txt"] {
            let path = dir.path().join(path);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, "").unwrap();
        }
        assert_eq!(
            walk(dir.path()),
            ["a/c.md", "b.md", "f.txt"].map(PathBuf::from)
        );
    }

    #[test]
    fn wikilinks_take_the_shortest_path() {
        let notes = notes(&[
            "projects/plan.md",
            "plan.md",
            "old/projects/plan.md",
            "todo.txt",
        ]);
        let resolve = |name| notes.resolve(name).map(Path::to_path_buf);
        assert_eq!(resolve("Plan"), Some("plan.md".into()));
        assert_eq!(resolve("plan.md"), Some("plan.md".into()));
        assert_eq!(resolve("projects/plan"), Some("projects/plan.md".into()));
        assert_eq!(resolve("todo.txt"), Some("todo.txt".into()));
        assert_eq!(resolve("lan"), None);
        assert_eq!(resolve("../plan"), None);
        assert_eq!(resolve("/plan"), None);
    }

    #[test]
    fn links_name_the_note_by_path_or_name() {
        let notes = notes(&[
            "a.md",
            "notes/c.md",
            "projects/b.md",
            "projects/launch plan.md",
        ]);
        let target = Path::new("projects/launch plan.md");
        let links = |source: &str, text: &str| {
            links(text, Path::new(source), &notes)
                .iter()
                .any(|link| link.target == target)
        };
        assert!(links("a.md", "see [[launch plan]] today"));
        assert!(links("a.md", "see [[Launch Plan|the plan]]"));
        assert!(links("a.md", "see [[projects/launch plan#Goals]]"));
        assert!(links("a.md", "see ![[launch plan.md]]"));
        assert!(links("a.md", "[plan](projects/launch%20plan.md)"));
        assert!(links(
            "a.md",
            "[plan](<projects/launch plan.md#goals> \"title\")"
        ));
        assert!(links("a.md", "[plan][p]\n\n[p]: projects/launch%20plan.md"));
        assert!(links("projects/b.md", "[plan](./launch%20plan.md)"));
        assert!(links("notes/c.md", "[plan](../projects/launch%20plan.md)"));
        assert!(!links("a.md", "[[launch]] and [[plan]]"));
        assert!(!links("a.md", "[plan](launch%20plan.md)"));
        assert!(!links(
            "a.md",
            "[plan](https://example.com/projects/launch%20plan.md)"
        ));
        assert!(!links("a.md", "[plan](../../projects/launch%20plan.md)"));
        assert!(!links(
            "a.md",
            "`[[launch plan]]`\n\n```\n[[launch plan]]\n```"
        ));
    }

    #[test]
    fn backlinks_are_lines_in_other_notes() {
        let notes = notes(&["a.md", "plan.md"]);
        let text = "# A\n\nSee [[plan]] and [the plan](plan.md).\n[[other]]\n  [p](plan.md)  ";
        let found = backlinks(text, Path::new("a.md"), &notes, Path::new("Plan.md"));
        assert_eq!(
            found
                .iter()
                .map(|link| (link.line, &text[link.link.clone()], link.text.as_str()))
                .collect::<Vec<_>>(),
            [
                (3, "[[plan]]", "See [[plan]] and [the plan](plan.md)."),
                (5, "[p](plan.md)", "[p](plan.md)"),
            ]
        );
        assert!(backlinks(text, Path::new("plan.md"), &notes, Path::new("plan.md")).is_empty());
    }

    #[test]
    fn relink_rewrites_names_as_written() {
        let notes = notes(&["a.md", "projects/launch plan.md", "projects/other.md"]);
        let text = "[[launch plan]] [[Projects/Launch Plan.md#Goals|g]] [[other]] `[[launch plan]]`\n\
                    [x](projects/launch%20plan.md) [y](<projects/launch plan.md>) [z][r]\n\n\
                    [r]: projects/launch%20plan.md#top \"t\"\n";
        let edits = relink(
            text,
            Path::new("a.md"),
            &notes,
            Path::new("projects/launch plan.md"),
            Path::new("projects/Q4 (draft).md"),
        );
        let mut out = text.to_owned();
        for (range, with) in edits.iter().rev() {
            out.replace_range(range.clone(), with);
        }
        assert_eq!(
            out,
            "[[Q4 (draft)]] [[Projects/Q4 (draft).md#Goals|g]] [[other]] `[[launch plan]]`\n\
             [x](projects/Q4%20%28draft%29.md) [y](<projects/Q4 (draft).md>) [z][r]\n\n\
             [r]: projects/Q4%20%28draft%29.md#top \"t\"\n"
        );
    }

    #[test]
    fn relink_names_the_path_when_the_name_gives_another_note() {
        let notes = notes(&["a.md", "roadmap.md", "projects/plan.md"]);
        let text = "[[plan]] [[projects/plan]] [[plan.md]]";
        let edits = relink(
            text,
            Path::new("a.md"),
            &notes,
            Path::new("projects/plan.md"),
            Path::new("projects/roadmap.md"),
        );
        let mut out = text.to_owned();
        for (range, with) in edits.iter().rev() {
            out.replace_range(range.clone(), with);
        }
        assert_eq!(
            out,
            "[[projects/roadmap]] [[projects/roadmap]] [[projects/roadmap.md]]"
        );
    }

    #[test]
    fn rewrite_changes_closed_notes_on_disk() {
        let dir = tempfile::tempdir().unwrap();
        let write = |path: &str, text: &str| fs::write(dir.path().join(path), text).unwrap();
        write("new.md", "# Plan\n");
        write("a.md", "\u{feff}See [[old]].\r\n");
        write("b.md", "See [[old]].\n");
        write("c.md", "Nothing here.\n");
        let mut paths = walk(dir.path());
        for path in &mut paths {
            if path == Path::new("new.md") {
                *path = "old.md".into();
            }
        }
        let notes = Notes::new(paths);
        let rewritten = rewrite(
            dir.path(),
            &notes,
            Path::new("old.md"),
            Path::new("new.md"),
            &["b.md".into()],
        );
        assert_eq!(rewritten, [PathBuf::from("a.md")]);
        let read = |path: &str| fs::read_to_string(dir.path().join(path)).unwrap();
        assert_eq!(read("a.md"), "\u{feff}See [[new]].\r\n");
        assert_eq!(read("b.md"), "See [[old]].\n");
    }
}
