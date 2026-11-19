//! The version of each Markdown file Dewline last saw, kept in the store's
//! `seen/` folder, so a write made while the file was closed, or while the
//! app was quit, lands as marked changes when it opens; and the changes
//! left undecided when it closed open with it again.

use std::collections::HashSet;
use std::ffi::OsStr;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

use blake3::Hash;

use super::{
    Change, ChangeId, ClosedChange, DocId, Engine, Kind, Mark, Origin, State, UNKNOWN, closed,
    lock, private, read, strip,
};
use crate::git::status::Ignores;
use crate::store::{self, Seen};
use crate::{merge, text};

/// The extensions of the files whose last seen version the engine keeps:
/// Markdown, MDX, Quarto, and Cursor's rules (.mdc), as the sidebar lists them,
/// and the Typst and LaTeX sources Dewline typesets.
const TRACKED: [&str; 9] = [
    "md", "markdown", "mdown", "mkd", "mdc", "mdx", "qmd", "typ", "tex",
];
/// The hidden folders that hold what agents read, which a scan notes.
const AGENT_FOLDERS: [&str; 9] = [
    ".agents",
    ".claude",
    ".codex",
    ".cursor",
    ".github",
    ".kiro",
    ".ruler",
    ".specify",
    ".windsurf",
];
/// A scan notes at most this many files: those git tracks before those it
/// ignores, the last modified first.
const MAX_SCAN: usize = 10_000;
/// A scan that finds a file unchanged dates its seen version again once it
/// is this old, so pruning keeps it.
const REFRESH: Duration = Duration::from_secs(24 * 60 * 60);

/// A hooked write to a file no document had open: the bytes it replaced and
/// the bytes it declared, which name it only if the file holds them.
pub(super) struct ClosedWrite {
    origin: Origin,
    before: Hash,
    /// None once a second write did not start from the first one's bytes.
    declared: Option<Hash>,
    time: SystemTime,
}

/// A closed file seen to differ from its last seen version `base`: since
/// when, and the places that changed while it held `disk`.
pub(super) struct Waiting {
    time: SystemTime,
    base: Hash,
    disk: Hash,
    count: u32,
}

/// What `Engine::earlier` finds a file opens on.
pub(super) struct Earlier {
    pub bytes: Option<Vec<u8>>,
    /// The base's hash and the hooked writer that made the file from it.
    pub writer: Option<(Hash, Origin)>,
    pub seen: Option<Seen>,
}

impl Engine {
    /// The version the file at `real`, as opened at `path` and holding
    /// `bytes`, opens on when it differs from them: its seen version, else
    /// the bytes a hooked write replaced, both put in the history with the
    /// file. With it, the hooked write's writer when the file holds what it
    /// declared, and the seen version, whose marks open with it. A Markdown
    /// file with no seen version is seen as it is.
    pub(super) fn earlier(
        &self,
        path: &Path,
        real: &Path,
        bytes: &[u8],
        wall: SystemTime,
    ) -> io::Result<Earlier> {
        let disk = blake3::hash(bytes);
        let kept = !private(path) && !private(real) && tracked(real);
        let seen = if kept { self.store.seen(real)? } else { None };
        let write = {
            let mut state = self.state();
            state.waiting.remove(real);
            state.closed.remove(real)
        };
        let earlier = match (&seen, &write) {
            (Some(seen), _) if seen.hash != disk => seen.bytes().ok(),
            (None, Some(write)) if write.before != disk => self.store.get(&write.before).ok(),
            _ => None,
        }
        .filter(|before| is_text(before) && is_text(bytes));
        let Some(before) = earlier else {
            if kept && seen.is_none() {
                self.see(real, false, bytes, wall);
            }
            return Ok(Earlier {
                bytes: None,
                writer: None,
                seen,
            });
        };
        self.store.put(real, &before, UNKNOWN, wall)?;
        self.store.put(real, bytes, UNKNOWN, wall)?;
        let base = blake3::hash(&before);
        let named = write
            .filter(|write| write.before == base && write.declared == Some(disk))
            .map(|write| (base, write.origin));
        Ok(Earlier {
            bytes: Some(before),
            writer: named,
            seen,
        })
    }

    /// Keeps `bytes` as the seen version of the Markdown file at `path`,
    /// unless it is private.
    pub(super) fn see(&self, path: &Path, private: bool, bytes: &[u8], wall: SystemTime) {
        if !private && tracked(path) {
            let _ = self.keep_seen(path, bytes, &[], wall);
        }
    }

    /// Keeps `bytes` and `marks` as the seen version of the file at `path`,
    /// which a document has. A failed write drops the seen version, so an
    /// older one can't make the document's own saves read as a closed change.
    fn keep_seen(
        &self,
        path: &Path,
        bytes: &[u8],
        marks: &[store::Mark],
        wall: SystemTime,
    ) -> io::Result<()> {
        self.state().waiting.remove(path);
        let kept = self.store.see(path, bytes, marks, wall);
        if kept.is_err() {
            let _ = self.store.forget(path);
        }
        kept
    }

    /// Notes that `origin` is about to write the file at `path`, which holds
    /// `before`, and that the write makes bytes whose hash is `declared`.
    /// Unless the file is not Markdown or a document has it open, `before`
    /// goes into the store and the write names its writer when the file opens
    /// holding `declared`. A second write keeps the first one's `before`, and
    /// names its writer only if it is the same writer starting from the bytes
    /// the first declared.
    pub fn closed_write(
        &self,
        path: &Path,
        origin: Origin,
        before: &[u8],
        declared: Hash,
    ) -> io::Result<()> {
        let real = fs::canonicalize(path)?;
        if private(path) || private(&real) || !tracked(&real) {
            return Ok(());
        }
        let hash = blake3::hash(before);
        {
            let mut state = self.state();
            if state.docs.values().any(|d| d.path == real) {
                return Ok(());
            }
            if let Some(write) = state.closed.get_mut(&real) {
                let follows = write.origin == origin && write.declared == Some(hash);
                write.declared = follows.then_some(declared);
                return Ok(());
            }
        }
        let (_, wall) = (self.clock)();
        self.store.put(&real, before, UNKNOWN, wall)?;
        let write = ClosedWrite {
            origin,
            before: hash,
            declared: Some(declared),
            time: wall,
        };
        let mut state = self.state();
        if !state.docs.values().any(|d| d.path == real) {
            state.closed.entry(real).or_insert(write);
        }
        Ok(())
    }

    /// `closed_write` for a write already made, as Cursor's afterFileEdit
    /// reports one: the file at `path` held the bytes whose hash is `before`.
    /// Kept only when the store holds those bytes, as the file's seen version
    /// or in its history.
    pub fn closed_wrote(
        &self,
        path: &Path,
        origin: Origin,
        before: Hash,
        declared: Hash,
    ) -> io::Result<()> {
        let real = fs::canonicalize(path)?;
        let bytes = match self.store.seen(&real)?.filter(|seen| seen.hash == before) {
            Some(seen) => seen.bytes()?,
            None => match self.store.get(&before) {
                Ok(bytes) => bytes,
                Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
                Err(error) => return Err(error),
            },
        };
        self.closed_write(path, origin, &bytes, declared)
    }

    /// Notes the Markdown files in `folder`, and in its subfolders when
    /// `deep`, hidden ones other than the agent folders and `node_modules`
    /// aside, what git ignores last. A file no document has open and no seen
    /// version yet is seen as it is; one that differs from its seen version
    /// is in `closed_changes`.
    pub fn scan(&self, folder: &Path, deep: bool) -> io::Result<()> {
        let root = fs::canonicalize(folder)?;
        let (mut ignores, prefix) = Ignores::of(&root);
        let mut folders = vec![(root.clone(), false)];
        let mut files = Vec::new();
        let mut first = true;
        while let Some((folder, inside_ignored)) = folders.pop() {
            let entries = match fs::read_dir(&folder) {
                Ok(entries) => entries,
                Err(error) if first => return Err(error),
                Err(_) => continue,
            };
            first = false;
            for entry in entries.flatten() {
                let name = entry.file_name();
                let Ok(kind) = entry.file_type() else {
                    continue;
                };
                let agents = kind.is_dir() && AGENT_FOLDERS.iter().any(|folder| name == *folder);
                if name.as_encoded_bytes().starts_with(b".") && !agents || name == "node_modules" {
                    continue;
                }
                let path = entry.path();
                let folder = kind.is_dir();
                if !(folder && deep || kind.is_file() && tracked(&path) && !private(&path)) {
                    continue;
                }
                let relative = path.strip_prefix(&root).unwrap_or(&path).as_os_str();
                let relative = relative.as_encoded_bytes();
                let from_top = if prefix.is_empty() {
                    relative.to_vec()
                } else {
                    [&prefix, b"/".as_slice(), relative].concat()
                };
                let ignored = inside_ignored || ignores.ignored(&from_top, folder);
                if folder {
                    folders.push((path, ignored));
                } else {
                    let modified = entry.metadata().and_then(|metadata| metadata.modified());
                    files.push((ignored, modified.unwrap_or(SystemTime::UNIX_EPOCH), path));
                }
            }
        }
        files.sort_by(|a, b| {
            a.0.cmp(&b.0)
                .then(b.1.cmp(&a.1))
                .then_with(|| a.2.cmp(&b.2))
        });
        files.truncate(MAX_SCAN);
        let open: HashSet<PathBuf> = self.state().docs.values().map(|d| d.path.clone()).collect();
        let (_, wall) = (self.clock)();
        for (_, _, path) in files {
            if open.contains(&path) {
                continue;
            }
            let Ok(bytes) = read(&path) else {
                continue;
            };
            let differs = match self.store.seen(&path)? {
                Some(seen) => seen.hash != blake3::hash(&bytes),
                None => self.state().closed.contains_key(&path),
            };
            if differs {
                self.closed_change(path, &bytes, wall);
            } else {
                self.state().waiting.remove(&path);
                self.store.note(&path, &bytes, wall, REFRESH)?;
            }
        }
        Ok(())
    }

    /// Files no document has open that differ from their seen version, or
    /// from the bytes a hooked write replaced, oldest first.
    pub fn closed_changes(&self) -> Vec<ClosedChange> {
        let paths: HashSet<PathBuf> = {
            let state = self.state();
            state
                .closed
                .keys()
                .chain(state.waiting.keys())
                .filter(|path| !state.docs.values().any(|d| d.path == **path))
                .cloned()
                .collect()
        };
        let (_, wall) = (self.clock)();
        let mut closed: Vec<ClosedChange> = paths
            .into_iter()
            .filter_map(|path| {
                let bytes = read(&path).ok()?;
                self.closed_change(path, &bytes, wall)
            })
            .collect();
        closed.sort_by_key(|change| change.time);
        closed
    }

    /// The closed file at `path`, which holds `bytes`, as a closed change, if
    /// it differs from its seen version, else from a hooked write's `before`.
    /// Its count is kept until the file changes again.
    fn closed_change(&self, path: PathBuf, bytes: &[u8], now: SystemTime) -> Option<ClosedChange> {
        let disk = blake3::hash(bytes);
        let cached = {
            let state = self.state();
            state
                .waiting
                .get(&path)
                .filter(|waiting| waiting.disk == disk)
                .map(|waiting| (waiting.base, waiting.count, waiting.time))
        };
        let (base, count, time) = match cached {
            Some(cached) => cached,
            None => {
                let seen = self.store.seen(&path).ok().flatten();
                let before = self.state().closed.get(&path).map(|write| write.before);
                let (base, earlier) = match (seen, before) {
                    (Some(seen), _) => (seen.hash, seen.bytes().ok()),
                    (None, Some(before)) => (before, self.store.get(&before).ok()),
                    (None, None) => return None,
                };
                if base == disk {
                    self.state().waiting.remove(&path);
                    return None;
                }
                let count = places(&earlier?, bytes)?;
                let mut state = self.state();
                let time = state.waiting.get(&path).map_or(now, |waiting| waiting.time);
                state.waiting.insert(
                    path.clone(),
                    Waiting {
                        time,
                        base,
                        disk,
                        count,
                    },
                );
                (base, count, time)
            }
        };
        let state = self.state();
        let write = state.closed.get(&path);
        let origin = match write {
            Some(write) if write.before == base && write.declared == Some(disk) => {
                write.origin.clone()
            }
            _ => Origin::External,
        };
        Some(ClosedChange {
            origin,
            count,
            time: write.map_or(time, |write| write.time),
            path,
        })
    }

    /// Keeps the document's base as its file's seen version, with its
    /// undecided changes and conflicts at `ranges`, UTF-16 in `buffer`, as
    /// marks where the base has them; opening the file again shows them.
    /// Call it before `close`.
    pub fn keep_marks(
        &self,
        doc: DocId,
        buffer: &str,
        ranges: &[(ChangeId, u32, u32)],
    ) -> io::Result<()> {
        let serial = self.serial(doc).ok_or_else(closed)?;
        let _serial = lock(&serial);
        let (path, base, marks) = {
            let state = self.state();
            let d = state.docs.get(&doc).ok_or_else(closed)?;
            if d.private || !tracked(&d.path) {
                return Ok(());
            }
            let marks = strip(&d.base, d.bom)
                .map_or_else(Vec::new, |base| marks(&d.changes, buffer, base, ranges));
            (d.path.clone(), d.base.clone(), marks)
        };
        self.keep_seen(&path, &base, &marks, (self.clock)().1)
    }
}

/// Whether the engine keeps the file's last seen version, by its extension.
pub(super) fn tracked(path: &Path) -> bool {
    path.extension()
        .and_then(OsStr::to_str)
        .is_some_and(|extension| TRACKED.contains(&extension.to_ascii_lowercase().as_str()))
}

/// The undecided changes and conflicts at `ranges`, UTF-16 in `buffer`, as
/// marks where `base` has them. Typing the base does not hold is left out;
/// a conflict's mark puts back yours, where the base holds theirs.
fn marks(
    changes: &[Change],
    buffer: &str,
    base: &str,
    ranges: &[(ChangeId, u32, u32)],
) -> Vec<store::Mark> {
    let typed = if buffer == base {
        Vec::new()
    } else {
        let merge = merge::merge3(buffer, buffer, base);
        let mut edits = merge.edits;
        edits.extend(merge.conflicts.into_iter().map(|conflict| merge::Edit {
            start: conflict.start,
            end: conflict.end,
            text: conflict.theirs,
        }));
        edits.sort_by_key(|edit| edit.start);
        edits
    };
    // A range edge inside typing takes in all of it.
    let widen = |at: u32, edge: fn(&merge::Edit) -> u32| {
        typed
            .iter()
            .find(|edit| edit.start < at && at < edit.end)
            .map_or(at, edge)
    };
    let mut ranges: Vec<(ChangeId, u32, u32)> = ranges
        .iter()
        .map(|&(id, start, end)| (id, widen(start, |e| e.start), widen(end, |e| e.end)))
        .collect();
    ranges.sort_by_key(|&(_, start, _)| start);
    let mut done = 0;
    ranges
        .into_iter()
        .filter_map(|(id, start, end)| {
            let change = changes
                .iter()
                .find(|change| change.id == id && change.marked)?;
            let original = match &change.kind {
                Kind::Edit { original, .. } => original.clone(),
                Kind::Conflict { .. } => utf16_slice(buffer, start, end)?.to_owned(),
            };
            let start = merge::map_offset(&typed, start, merge::Bias::Before);
            if start < done {
                return None;
            }
            done = merge::map_offset(&typed, end, merge::Bias::After);
            Some(store::Mark {
                origin: change.origin.label(),
                start,
                end: done,
                original,
            })
        })
        .collect()
}

fn is_text(bytes: &[u8]) -> bool {
    matches!(text::Opened::new(bytes.to_vec()), text::Opened::Utf8 { .. })
}

/// How many places differ between two versions of a text file; None when
/// either is not text.
fn places(before: &[u8], after: &[u8]) -> Option<u32> {
    let (text::Opened::Utf8 { text: before, .. }, text::Opened::Utf8 { text: after, .. }) = (
        text::Opened::new(before.to_vec()),
        text::Opened::new(after.to_vec()),
    ) else {
        return None;
    };
    Some(merge::merge3(&before, &before, &after).edits.len() as u32)
}

/// The text between UTF-16 offsets `start` and `end`, if both fall between
/// characters inside it.
fn utf16_slice(text: &str, start: u32, end: u32) -> Option<&str> {
    let byte = |at: u32| {
        let mut unit = 0;
        for (index, c) in text.char_indices() {
            if unit >= at {
                return (unit == at).then_some(index);
            }
            unit += c.len_utf16() as u32;
        }
        (unit == at).then_some(text.len())
    };
    text.get(byte(start)?..byte(end)?)
}

/// The seen version's marks as pending changes in `text`, the document's
/// base, which is the seen version. A mark whose range is not in the text is
/// dropped.
pub(super) fn restore(
    state: &mut State,
    seen: &Seen,
    text: &str,
    now: Instant,
) -> (Vec<Change>, Vec<Mark>) {
    let mut changes = Vec::new();
    let mut marks = Vec::new();
    for mark in &seen.marks {
        let Some(landed) = utf16_slice(text, mark.start, mark.end) else {
            continue;
        };
        let change = ChangeId(state.next());
        let origin = Origin::from_label(&mark.origin);
        changes.push(Change {
            id: change,
            origin: origin.clone(),
            marked: true,
            from: seen.hash,
            to: seen.hash,
            seen: now,
            kind: Kind::Edit {
                original: mark.original.clone(),
                landed: landed.to_owned(),
            },
        });
        marks.push(Mark {
            change,
            origin,
            start: mark.start,
            end: mark.end,
            removed: mark.original.clone(),
        });
    }
    (changes, marks)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::claims::{Claim, Fields, Vendor};
    use crate::engine::Landing;
    use std::process::Command;
    use std::sync::{Arc, Mutex};
    use std::time::UNIX_EPOCH;

    const DAY: Duration = Duration::from_secs(24 * 60 * 60);

    struct Fixture {
        _dir: tempfile::TempDir,
        root: PathBuf,
        notes: PathBuf,
        time: Arc<Mutex<(Instant, SystemTime)>>,
    }

    fn fixture() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let notes = root.join("notes");
        fs::create_dir(&notes).unwrap();
        let start = (
            Instant::now(),
            UNIX_EPOCH + Duration::from_secs(1_790_000_000),
        );
        Fixture {
            _dir: dir,
            root,
            notes,
            time: Arc::new(Mutex::new(start)),
        }
    }

    impl Fixture {
        /// An engine on the fixture's store, as a launch of the app makes.
        fn engine(&self) -> Engine {
            let clock = self.time.clone();
            Engine::new(
                &self.root.join("snapshots"),
                Box::new(move || *clock.lock().unwrap()),
            )
            .unwrap()
        }

        fn pass(&self, duration: Duration) {
            let mut time = self.time.lock().unwrap();
            time.0 += duration;
            time.1 += duration;
        }

        fn file(&self, name: &str, text: &str) -> PathBuf {
            let path = self.notes.join(name);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, text).unwrap();
            path
        }
    }

    fn text(opened: &crate::engine::Opened) -> &str {
        let text::Opened::Utf8 { text, .. } = &opened.contents else {
            panic!("not text");
        };
        text
    }

    /// Observes, lands and commits, and returns the landing and the landed
    /// buffer.
    fn land(engine: &Engine, doc: DocId, buffer: &str) -> (Landing, String) {
        assert!(engine.observe(doc).unwrap());
        let landing = engine.land(doc, buffer, 0).unwrap().unwrap();
        engine.commit(doc, landing.id).unwrap();
        let edits: Vec<merge::Edit> = landing.edits.iter().map(|(_, edit)| edit.clone()).collect();
        let landed = merge::apply(buffer, &edits);
        (landing, landed)
    }

    fn claude() -> Origin {
        Origin::Agent {
            vendor: Vendor::Claude,
            session: "s1".into(),
        }
    }

    const OLD: &str = "# Plan\n\nShip Friday.\n\nThen rest.\n";
    const NEW: &str = "# Plan\n\nShip Monday.\n\nThen rest a week.\n";

    #[test]
    fn a_write_made_while_the_app_was_quit_lands_when_the_note_opens() {
        let f = fixture();
        let path = f.file("plan.md", OLD);
        f.engine().scan(&f.notes, true).unwrap();
        fs::write(&path, NEW).unwrap();
        f.pass(DAY);

        let engine = f.engine();
        assert!(engine.closed_changes().is_empty(), "nothing scanned yet");
        engine.scan(&f.notes, true).unwrap();
        let closed = engine.closed_changes();
        assert_eq!(closed.len(), 1);
        assert_eq!(
            (&closed[0].path, &closed[0].origin, closed[0].count),
            (&path, &Origin::External, 2)
        );

        let opened = engine.open(&path).unwrap();
        assert!(opened.closed);
        assert_eq!(text(&opened), OLD);
        assert!(
            engine.closed_changes().is_empty(),
            "open notes leave the list"
        );
        let (landing, landed) = land(&engine, opened.doc, OLD);
        assert_eq!(landing.origin, Origin::External);
        assert!(landing.marked && landing.clean);
        assert_eq!(landing.edits.len(), 2);
        assert_eq!(landed, NEW);
    }

    #[test]
    fn a_write_to_a_closed_note_is_listed_then_lands_and_a_new_note_is_not() {
        let f = fixture();
        let path = f.file("plan.md", OLD);
        let engine = f.engine();
        engine.scan(&f.notes, true).unwrap();
        let opened = engine.open(&path).unwrap();
        assert!(!opened.closed);
        engine.close(opened.doc);

        fs::write(&path, NEW).unwrap();
        f.file("sub/new.md", "# New\n");
        // The folder watch names the folders that changed.
        engine.scan(&f.notes, false).unwrap();
        engine.scan(&f.notes.join("sub"), false).unwrap();
        let closed = engine.closed_changes();
        assert_eq!(closed.iter().map(|c| &c.path).collect::<Vec<_>>(), [&path]);

        fs::write(&path, OLD).unwrap();
        assert!(engine.closed_changes().is_empty(), "written back");
        fs::write(&path, NEW).unwrap();
        let opened = engine.open(&path).unwrap();
        assert!(opened.closed);
        let (_, landed) = land(&engine, opened.doc, OLD);
        assert_eq!(landed, NEW);
    }

    #[test]
    fn a_hooked_write_names_its_writer_only_when_the_note_holds_what_it_declared() {
        let f = fixture();
        let named = f.file("named.md", OLD);
        let unnamed = f.file("unnamed.md", OLD);
        let engine = f.engine();
        engine.scan(&f.notes, true).unwrap();
        let declared = blake3::hash(NEW.as_bytes());
        for path in [&named, &unnamed] {
            engine
                .closed_write(path, claude(), OLD.as_bytes(), declared)
                .unwrap();
        }
        fs::write(&named, NEW).unwrap();
        // Quote normalization, or another writer: not the declared bytes.
        fs::write(&unnamed, NEW.replace("Monday", "Tuesday")).unwrap();
        engine.scan(&f.notes, false).unwrap();
        let origins: Vec<(PathBuf, Origin)> = engine
            .closed_changes()
            .into_iter()
            .map(|change| (change.path, change.origin))
            .collect();
        assert_eq!(origins.len(), 2);
        assert!(origins.contains(&(named.clone(), claude())));
        assert!(origins.contains(&(unnamed.clone(), Origin::External)));

        for (path, origin) in [(&named, claude()), (&unnamed, Origin::External)] {
            let opened = engine.open(path).unwrap();
            assert!(opened.closed);
            let (landing, buffer) = land(&engine, opened.doc, OLD);
            assert_eq!(landing.origin, origin, "{}", path.display());
            // Left undecided, the changes keep their writer across a close.
            let ranges: Vec<(ChangeId, u32, u32)> = landing
                .edits
                .iter()
                .map(|(id, edit)| {
                    (
                        *id,
                        edit.start,
                        edit.start + edit.text.encode_utf16().count() as u32,
                    )
                })
                .collect();
            engine.keep_marks(opened.doc, &buffer, &ranges).unwrap();
            engine.close(opened.doc);
            let reopened = engine.open(path).unwrap();
            assert_eq!(reopened.marks.len(), 2);
            assert!(reopened.marks.iter().all(|mark| mark.origin == origin));
            engine.close(reopened.doc);
        }
    }

    #[test]
    fn a_write_reported_after_it_is_made_names_its_writer_from_the_seen_version() {
        let f = fixture();
        let seen = f.file("seen.md", OLD);
        let engine = f.engine();
        engine.scan(&f.notes, true).unwrap();
        let unseen = f.file("unseen.md", "# Unseen\n");
        let cursor = Origin::Agent {
            vendor: Vendor::Cursor,
            session: "s1".into(),
        };
        let after = blake3::hash(NEW.as_bytes());
        for (path, old) in [(&seen, OLD), (&unseen, "# Unseen\n")] {
            fs::write(path, NEW).unwrap();
            engine
                .closed_wrote(path, cursor.clone(), blake3::hash(old.as_bytes()), after)
                .unwrap();
        }
        engine.scan(&f.notes, false).unwrap();
        let origins: Vec<(PathBuf, Origin)> = engine
            .closed_changes()
            .into_iter()
            .map(|change| (change.path, change.origin))
            .collect();
        assert_eq!(
            origins,
            [(seen, cursor)],
            "the unseen note's old bytes are nowhere"
        );
    }

    #[test]
    fn a_second_write_by_the_same_writer_keeps_the_name_and_another_writer_drops_it() {
        let f = fixture();
        let path = f.file("plan.md", "one\n");
        let engine = f.engine();
        engine.scan(&f.notes, true).unwrap();
        let hash = |text: &str| blake3::hash(text.as_bytes());
        engine
            .closed_write(&path, claude(), b"one\n", hash("two\n"))
            .unwrap();
        fs::write(&path, "two\n").unwrap();
        engine
            .closed_write(&path, claude(), b"two\n", hash("three\n"))
            .unwrap();
        fs::write(&path, "three\n").unwrap();
        assert_eq!(engine.closed_changes()[0].origin, claude());

        let codex = Origin::Agent {
            vendor: Vendor::Codex,
            session: "s2".into(),
        };
        engine
            .closed_write(&path, codex, b"three\n", hash("four\n"))
            .unwrap();
        fs::write(&path, "four\n").unwrap();
        assert_eq!(engine.closed_changes()[0].origin, Origin::External);
    }

    fn git(dir: &Path, args: &[&str]) {
        let status = Command::new("git")
            .current_dir(dir)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_INDEX_FILE")
            .args([
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "user.name=test",
            ])
            .args(["-c", "init.defaultBranch=main"])
            .args(args)
            .status()
            .unwrap();
        assert!(status.success(), "git {args:?}");
    }

    /// AG-1: a Read records nothing, so a later pull is not Claude's.
    #[test]
    fn a_read_then_a_pull_is_not_credited_to_the_reader() {
        let f = fixture();
        let path = f.file("plan.md", OLD);
        git(&f.notes, &["init", "-q"]);
        git(&f.notes, &["add", "-A"]);
        git(&f.notes, &["commit", "-q", "-m", "old"]);
        git(&f.notes, &["checkout", "-q", "-b", "upstream"]);
        fs::write(&path, NEW).unwrap();
        git(&f.notes, &["commit", "-q", "-am", "new"]);
        git(&f.notes, &["checkout", "-q", "main"]);
        let engine = f.engine();
        engine.scan(&f.notes, true).unwrap();

        let hash = blake3::hash(OLD.as_bytes()).to_hex().to_string();
        let path_text = path.to_str().unwrap();
        for event in ["PreToolUse", "PostToolUse"] {
            let read = Claim::parse(Fields {
                event,
                vendor: "claude",
                session: "s1",
                tool_use_id: Some("t1"),
                tool: Some("Read"),
                path: Some(path_text),
                hash: Some(&hash),
                declared: None,
            })
            .unwrap();
            engine.claim(read).unwrap();
        }
        f.pass(DAY);
        git(&f.notes, &["merge", "-q", "--ff-only", "upstream"]);
        engine.scan(&f.notes, false).unwrap();
        assert_eq!(engine.closed_changes()[0].origin, Origin::External);
        let opened = engine.open(&path).unwrap();
        let (landing, _) = land(&engine, opened.doc, OLD);
        assert!(
            !matches!(landing.origin, Origin::Agent { .. }),
            "{:?}",
            landing.origin
        );
    }

    #[test]
    fn undecided_marks_survive_closing_and_quitting_and_reopen_where_they_were() {
        let f = fixture();
        let path = f.file("plan.md", OLD);
        let engine = f.engine();
        let opened = engine.open(&path).unwrap();
        fs::write(&path, NEW).unwrap();
        let (landing, buffer) = land(&engine, opened.doc, OLD);
        // The second change is kept; the first stays undecided.
        let ranges: Vec<(ChangeId, u32, u32)> = landing
            .edits
            .iter()
            .map(|(id, edit)| {
                (
                    *id,
                    edit.start,
                    edit.start + edit.text.encode_utf16().count() as u32,
                )
            })
            .collect();
        let (kept, start, end) = ranges[1];
        assert_eq!(
            engine.decide(
                opened.doc,
                kept,
                crate::engine::Decision::Keep,
                &buffer[start as usize..end as usize]
            ),
            None
        );
        engine.keep_marks(opened.doc, &buffer, &ranges).unwrap();
        engine.close(opened.doc);
        drop(engine);

        let engine = f.engine();
        let opened = engine.open(&path).unwrap();
        assert!(!opened.closed);
        assert_eq!(text(&opened), NEW);
        assert_eq!(opened.marks.len(), 1);
        let mark = &opened.marks[0];
        let (_, start, end) = ranges[0];
        assert_eq!(
            (&mark.origin, mark.start, mark.end, mark.removed.as_str()),
            (&Origin::External, start, end, "Friday")
        );
        assert_eq!(&NEW[start as usize..end as usize], "Monday");
        // Reverting it after the reopen puts back what it replaced.
        let reverted = engine.decide(
            opened.doc,
            mark.change,
            crate::engine::Decision::Other,
            "Monday",
        );
        assert_eq!(reverted.as_deref(), Some("Friday"));

        engine.keep_marks(opened.doc, NEW, &[]).unwrap();
        engine.close(opened.doc);
        let opened = engine.open(&path).unwrap();
        assert!(opened.marks.is_empty(), "decided marks stay decided");
        engine.close(opened.doc);
    }

    #[test]
    fn marks_open_under_a_write_made_after_the_close() {
        let f = fixture();
        let path = f.file("plan.md", OLD);
        let engine = f.engine();
        let opened = engine.open(&path).unwrap();
        fs::write(&path, NEW).unwrap();
        let (landing, buffer) = land(&engine, opened.doc, OLD);
        let ranges: Vec<(ChangeId, u32, u32)> = landing
            .edits
            .iter()
            .map(|(id, edit)| {
                (
                    *id,
                    edit.start,
                    edit.start + edit.text.encode_utf16().count() as u32,
                )
            })
            .collect();
        engine.keep_marks(opened.doc, &buffer, &ranges).unwrap();
        engine.close(opened.doc);

        fs::write(&path, format!("{NEW}\nP.S.\n")).unwrap();
        let opened = engine.open(&path).unwrap();
        assert!(opened.closed);
        assert_eq!(text(&opened), NEW);
        assert_eq!(opened.marks.len(), 2);
        let (landing, landed) = land(&engine, opened.doc, NEW);
        assert_eq!(landed, format!("{NEW}\nP.S.\n"));
        assert_eq!(landing.edits.len(), 1);
    }

    #[test]
    fn closing_mid_conflict_keeps_the_conflict_and_the_changes_marked() {
        let f = fixture();
        // The middle line keeps the two places apart.
        let old = OLD.replace("\n\nThen", "\n\nNotes.\n\nThen");
        let new = NEW.replace("\n\nThen", "\n\nNotes.\n\nThen");
        let path = f.file("plan.md", &old);
        let engine = f.engine();
        let opened = engine.open(&path).unwrap();
        let typed = old.replace("Friday", "Sunday");
        fs::write(&path, &new).unwrap();
        let (landing, buffer) = land(&engine, opened.doc, &typed);
        let [(conflict, card)] = &landing.conflicts[..] else {
            panic!("{landing:?}");
        };
        let [(edit, landed)] = &landing.edits[..] else {
            panic!("{landing:?}");
        };
        // The conflict comes before the edit, so its range holds in the buffer.
        let end = landed.start + landed.text.encode_utf16().count() as u32;
        let ranges = [
            (*conflict, card.start, card.end),
            (*edit, landed.start, end),
        ];
        engine.keep_marks(opened.doc, &buffer, &ranges).unwrap();
        engine.close(opened.doc);

        let opened = engine.open(&path).unwrap();
        assert_eq!(text(&opened), new);
        let [kept, edit] = &opened.marks[..] else {
            panic!("{:?}", opened.marks);
        };
        let at = |start: u32, end: u32| &new[start as usize..end as usize];
        assert_eq!(at(kept.start, kept.end), "Ship Monday.\n");
        assert_eq!(kept.removed, "Ship Sunday.\n");
        assert_eq!(at(edit.start, edit.end), " a week");
        // Reverting the conflict's mark puts yours back.
        let reverted = engine.decide(
            opened.doc,
            kept.change,
            crate::engine::Decision::Other,
            "Ship Monday.\n",
        );
        assert_eq!(reverted.as_deref(), Some("Ship Sunday.\n"));
    }

    #[test]
    fn pruning_drops_seen_versions_a_month_unseen_or_whose_file_is_gone() {
        let f = fixture();
        let kept = f.file("kept.md", "kept\n");
        let stale = f.file("away/stale.md", "stale\n");
        let gone = f.file("gone.md", "gone\n");
        let engine = f.engine();
        engine.scan(&f.notes, true).unwrap();
        fs::remove_file(&gone).unwrap();
        let seen = |path: &Path| engine.store.seen(path).unwrap().is_some();
        assert!(seen(&kept) && seen(&stale) && seen(&gone));
        engine.prune().unwrap();
        assert!(seen(&kept) && seen(&stale) && !seen(&gone));

        // Scans of the top folder alone date kept.md again; away/ goes unseen.
        for _ in 0..31 {
            f.pass(DAY);
            engine.scan(&f.notes, false).unwrap();
        }
        engine.prune().unwrap();
        assert!(seen(&kept), "dated again by each day's scan");
        assert!(!seen(&stale), "a month unseen");
        let entries = fs::read_dir(f.root.join("snapshots/seen")).unwrap().count();
        assert_eq!(entries, 1);

        // A version pruned while its file changed is seen again as it is.
        fs::write(&stale, "changed\n").unwrap();
        engine.scan(&f.notes, true).unwrap();
        assert!(engine.closed_changes().is_empty());
    }

    #[test]
    fn a_scan_notes_agent_folders_and_ignored_notes_and_skips_other_hidden_ones_other_files_and_open_notes()
     {
        let f = fixture();
        let open = f.file("open.md", "open\n");
        let noted = [
            f.file(".claude/commands/x.md", "x\n"),
            f.file(".cursor/rules/x.mdc", "x\n"),
            f.file(".github/copilot-instructions.md", "x\n"),
            f.file(".windsurf/rules/x.md", "x\n"),
            f.file("page.mdx", "x\n"),
            f.file("build/x.md", "x\n"),
            f.file("CLAUDE.local.md", "x\n"),
        ];
        let skipped = [
            f.file(".obsidian/x.md", "x\n"),
            f.file("node_modules/pkg/README.md", "x\n"),
            f.file("notes.txt", "x\n"),
        ];
        f.file(".gitignore", "build/\nCLAUDE.local.md\n");
        let engine = f.engine();
        // A hooked write to a file that is not Markdown keeps nothing.
        engine
            .closed_write(&skipped[2], claude(), b"x\n", blake3::hash(b"y\n"))
            .unwrap();
        fs::write(&skipped[2], "y\n").unwrap();
        let opened = engine.open(&open).unwrap();
        engine
            .store
            .see(&open, b"other\n", &[], UNIX_EPOCH)
            .unwrap();
        engine.scan(&f.notes, true).unwrap();
        for path in &noted {
            assert!(
                engine.store.seen(path).unwrap().is_some(),
                "{}",
                path.display()
            );
        }
        for path in &skipped {
            assert!(
                engine.store.seen(path).unwrap().is_none(),
                "{}",
                path.display()
            );
        }
        assert!(
            engine.closed_changes().is_empty(),
            "the open note is its document's"
        );
        // A closed write to a note git ignores is listed.
        fs::write(&noted[5], "y\n").unwrap();
        fs::write(&noted[6], "y\n").unwrap();
        engine.scan(&f.notes, true).unwrap();
        let mut listed: Vec<PathBuf> = engine
            .closed_changes()
            .into_iter()
            .map(|c| c.path)
            .collect();
        listed.sort();
        let mut ignored = vec![noted[5].clone(), noted[6].clone()];
        ignored.sort();
        assert_eq!(listed, ignored);
        engine.close(opened.doc);
        engine.scan(&f.notes, false).unwrap();
        assert!(
            engine.closed_changes().iter().any(|c| c.path == open),
            "closed, it differs"
        );
    }
}
