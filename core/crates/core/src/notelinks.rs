//! Links between the notes in a folder: wikilinks and relative markdown links, the note each names, the lines that
//! link to a note, and the edits that keep links on a note through a rename.

use std::collections::HashMap;
use std::fs;
use std::ops::Range;
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path, PathBuf};

use pulldown_cmark::{Event, LinkType, Options, Parser, Tag, TagEnd};

use crate::engine::{Engine, Origin};
use crate::file;
use crate::git::status::Ignores;

/// `walk` lists at most this many notes.
pub const MAX_NOTES: usize = 20_000;
/// The most a note read from disk holds.
pub const MAX_NOTE: u64 = 8 << 20;

/// The notes under `root`, root-relative, in name order: the one list of notes that link completion, backlinks,
/// relinking and MCP read. Links, `node_modules` and what git ignores are skipped.
pub fn walk(root: &Path) -> Vec<PathBuf> {
    let (mut ignores, prefix) =
        Ignores::of(&fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf()));
    let mut keep = |relative: &Path, folder: bool| {
        let path = relative.as_os_str().as_bytes();
        let path = if prefix.is_empty() {
            path.to_vec()
        } else {
            [&prefix, b"/".as_slice(), path].concat()
        };
        (folder || is_note(relative)) && !ignores.ignored(&path, folder)
    };
    let mut notes = Vec::new();
    visit(root, Path::new(""), &mut keep, &mut notes);
    notes
}

/// Every file under `root`, root-relative, in name order, outside dot folders and `node_modules`.
pub fn files(root: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    visit(root, Path::new(""), &mut |_, _| true, &mut files);
    files
}

/// Lists the files under `folder` that `keep` keeps, entering the folders it keeps.
fn visit(
    root: &Path,
    folder: &Path,
    keep: &mut impl FnMut(&Path, bool) -> bool,
    found: &mut Vec<PathBuf>,
) {
    let Ok(entries) = fs::read_dir(root.join(folder)) else {
        return;
    };
    let mut entries: Vec<_> = entries.flatten().collect();
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        if found.len() == MAX_NOTES {
            return;
        }
        let relative = folder.join(entry.file_name());
        if hidden(&relative) || entry.file_name() == "node_modules" {
            continue;
        }
        match entry.file_type() {
            Ok(kind) if kind.is_dir() && keep(&relative, true) => {
                visit(root, &relative, keep, found)
            }
            Ok(kind) if kind.is_file() && keep(&relative, false) => found.push(relative),
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
    /// The bytes naming the file as written: a wikilink's name, a destination up to its `#` or `?`. A reference link
    /// has none; its definition does.
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

/// The bytes of the destination starting at or after `from` (spaces skipped), up to its `#` or `?`; none when it is
/// empty.
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
    (start < end).then_some(start..end)
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

/// The edits that keep the links in `text`, the note at `source`, on their files after `moves`, each a file's old and
/// new path: each a byte range and what replaces it. A wikilink keeps its form, with or without `.md`, and names the
/// note's whole path when its name alone would give another note. A destination keeps its folder while that still
/// leads to the file from where the note is now, else takes the path from there, percent-encoded unless it was written
/// with spaces. Paths are root-relative, and `notes` has the files at their old paths.
pub fn relink(
    text: &str,
    source: &Path,
    notes: &Notes,
    moves: &[(PathBuf, PathBuf)],
) -> Vec<(Range<usize>, String)> {
    let moved = |path: &Path| {
        moves
            .iter()
            .find(|(old, _)| same(old, path))
            .map(|(_, new)| new.as_path())
    };
    let folder = moved(source)
        .unwrap_or(source)
        .parent()
        .unwrap_or(Path::new(""))
        .to_path_buf();
    let found = links(text, source, notes);
    let after = found
        .iter()
        .any(|link| link.kind == Kind::Wiki && moved(&link.target).is_some())
        .then(|| {
            Notes::new(
                notes
                    .paths()
                    .iter()
                    .map(|path| moved(path).unwrap_or(path).to_path_buf())
                    .collect(),
            )
        });
    let mut edits: Vec<(Range<usize>, String)> = found
        .into_iter()
        .filter_map(|link| {
            let name = link.name?;
            let written = &text[name.clone()];
            let prefix = written.rfind('/').map_or("", |slash| &written[..=slash]);
            let wanted = if link.kind == Kind::Wiki {
                let (new, after) = (moved(&link.target)?, after.as_ref()?);
                let file_name = new.file_name()?.to_string_lossy();
                let last = match new.file_stem() {
                    Some(stem)
                        if !written.to_lowercase().ends_with(".md")
                            && new
                                .extension()
                                .is_some_and(|extension| extension.eq_ignore_ascii_case("md")) =>
                    {
                        stem.to_string_lossy()
                    }
                    _ => file_name,
                };
                let path = new.with_file_name(&*last).to_string_lossy().into_owned();
                [format!("{prefix}{last}"), path]
                    .into_iter()
                    .find(|name| after.resolve(name).is_some_and(|note| same(note, new)))?
            } else {
                let target = match moved(&link.target) {
                    Some(new) => new,
                    None if moved(source).is_some() => &link.target,
                    None => return None,
                };
                let spaced = written.contains(' ');
                let name = |part: &std::ffi::OsStr| {
                    let part = part.to_string_lossy();
                    if spaced {
                        part.into_owned()
                    } else {
                        encode(&part)
                    }
                };
                let kept = format!("{prefix}{}", name(target.file_name()?));
                if local(&kept, &folder).is_some_and(|path| same(&path, target)) {
                    kept
                } else {
                    path_between(&folder, target)
                        .iter()
                        .map(name)
                        .collect::<Vec<_>>()
                        .join("/")
                }
            };
            (written != wanted).then_some((name, wanted))
        })
        .collect();
    edits.sort_by_key(|(range, _)| range.start);
    edits.dedup_by_key(|(range, _)| range.start);
    edits
}

/// The relative path from `folder` to `file`, both root-relative.
fn path_between(folder: &Path, file: &Path) -> PathBuf {
    let shared = folder
        .components()
        .zip(file.components())
        .take_while(|(a, b)| a == b)
        .count();
    let up = folder
        .components()
        .skip(shared)
        .map(|_| Component::ParentDir);
    up.chain(file.components().skip(shared)).collect()
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

/// Keeps the links in the notes under `root` on their files after `moves`, as `relink` does, and returns the notes it
/// rewrote, where they are now. A note is read where `moves` puts it, or where it was until it moves. Notes in
/// `skipping`, and notes that change while they are rewritten, are left alone. `engine` notes each write as yours, so it
/// isn't another app's change to a closed note.
pub fn rewrite(
    root: &Path,
    notes: &Notes,
    moves: &[(PathBuf, PathBuf)],
    skipping: &[PathBuf],
    engine: Option<&Engine>,
) -> Vec<PathBuf> {
    let mut rewritten = Vec::new();
    for source in notes.paths() {
        let on_disk = moves
            .iter()
            .find(|(old, new)| same(old, source) && root.join(new).exists())
            .map_or(source, |(_, new)| new);
        if skipping.iter().any(|skip| same(skip, on_disk)) {
            continue;
        }
        let path = root.join(on_disk);
        let Some(text) = read(&path) else {
            continue;
        };
        let bom = if text.starts_with('\u{feff}') { 3 } else { 0 };
        let edits = relink(&text[bom..], source, notes, moves);
        if edits.is_empty() {
            continue;
        }
        let mut out = text.clone();
        for (range, with) in edits.iter().rev() {
            out.replace_range(range.start + bom..range.end + bom, with);
        }
        if let Some(engine) = engine {
            let _ = engine.closed_write(
                &path,
                Origin::User,
                text.as_bytes(),
                file::hash(out.as_bytes()),
            );
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
        for path in [
            "b.md",
            "a/c.md",
            "a/d.png",
            ".hidden/e.md",
            "f.txt",
            "node_modules/g.md",
            "build/h.md",
            "a/i.md",
        ] {
            let path = dir.path().join(path);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, "").unwrap();
        }
        fs::write(dir.path().join(".gitignore"), "build/\ni.md\n").unwrap();
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
            &[(
                "projects/launch plan.md".into(),
                "projects/Q4 (draft).md".into(),
            )],
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
            &[("projects/plan.md".into(), "projects/roadmap.md".into())],
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
    fn relink_follows_a_move_to_another_folder() {
        let notes = notes(&["a.md", "plan.md", "b.md"]);
        let moves = [("plan.md".into(), "projects/plan.md".into())];
        let apply = |source: &str, text: &str| {
            let mut out = text.to_owned();
            for (range, with) in relink(text, Path::new(source), &notes, &moves).iter().rev() {
                out.replace_range(range.clone(), with);
            }
            out
        };
        assert_eq!(
            apply("a.md", "[[plan]] [p](plan.md#goals) [q](./plan.md)"),
            "[[plan]] [p](projects/plan.md#goals) [q](projects/plan.md)"
        );
        assert_eq!(
            apply("plan.md", "[b](b.md) [s](plan.md) ![i](img/x.png)"),
            "[b](../b.md) [s](plan.md) ![i](../img/x.png)"
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
            &[("old.md".into(), "new.md".into())],
            &["b.md".into()],
            None,
        );
        assert_eq!(rewritten, [PathBuf::from("a.md")]);
        let read = |path: &str| fs::read_to_string(dir.path().join(path)).unwrap();
        assert_eq!(read("a.md"), "\u{feff}See [[new]].\r\n");
        assert_eq!(read("b.md"), "See [[old]].\n");
    }
}
