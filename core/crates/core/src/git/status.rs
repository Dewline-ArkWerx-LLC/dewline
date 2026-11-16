//! Each file's state under a folder, as `git status` reports it: the index
//! against HEAD's tree, the working tree against the index, and the files no
//! ignore file matches that the index doesn't list. Read from the
//! repository's files, as the rest of this module reads them.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::ffi::OsStr;
use std::fs::{self, File};
use std::io::{self, Read};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::{FileExt, MetadataExt};
use std::path::{Path, PathBuf};

use flate2::read::ZlibDecoder;
use flate2::{Decompress, FlushDecompress};

use super::{
    INTENT_TO_ADD, Index, IndexEntry, MAX_INDEX, MAX_LINE_FILE, Oid, Repo, SKIP_WORKTREE, blob_id,
    parse_index, read_file,
};

/// A file's state against HEAD and the index.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    /// Its content or mode differs from HEAD's or the index's.
    Modified,
    /// Not in HEAD: staged, added with intent, or untracked.
    New,
    /// Gone from the working tree, or from the index.
    Deleted,
    /// Staged with the blob of a file the index deletes from HEAD.
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

/// Longest delta chain read, as git caps `pack.depth`.
const MAX_DEPTH: usize = 4095;

const LINK: u32 = 0o120000;
const GITLINK: u32 = 0o160000;
const TREE: u32 = 0o040000;

/// The state of the files under `folder`, a realpath. An untracked folder
/// holding no tracked file is one path, as git status lists it. Renames are
/// exact: the same blob at the new path. Ignore files are the repository's
/// .gitignore files and info/exclude. None when the folder is in no
/// repository, or its index, HEAD or objects can't be read: split or sparse
/// indexes, SHA-256 repositories, alternates and missing objects.
pub fn status(folder: &Path) -> Option<Statuses> {
    // `find` looks for `.git` in each folder above the path, the folder first.
    let repo = Repo::find(&folder.join(".git"))?;
    let prefix = folder.strip_prefix(&repo.top).ok()?.as_os_str().as_bytes();
    let common = match read_line(&repo.gitdir.join("commondir")) {
        Some(common) => repo.gitdir.join(common),
        None => repo.gitdir.clone(),
    };

    // Files changed at or after the index was written may match its stat
    // data with other bytes, so their bytes are compared.
    let index_path = repo.gitdir.join("index");
    let (index, racy) = match fs::metadata(&index_path) {
        Ok(metadata) => {
            let bytes = read_file(&index_path, MAX_INDEX).ok()?;
            let index = parse_index(&bytes)?;
            (index, (metadata.mtime(), metadata.mtime_nsec()))
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            let index = Index {
                entries: Vec::new(),
                split: false,
                sparse: false,
                trees: HashMap::new(),
            };
            (index, (i64::MIN, 0))
        }
        Err(_) => return None,
    };
    if index.split || index.sparse {
        return None;
    }

    // HEAD's files, but those in folders whose tree the index holds as is.
    let mut head = HashMap::new();
    let mut same = HashSet::new();
    if let Some(commit) = head_commit(&repo.gitdir, &common)? {
        let objects = Objects::open(&common.join("objects"));
        let tree = objects.commit_tree(commit)?;
        if index.trees.get(&b""[..]) == Some(&tree) {
            same.insert(Vec::new());
        } else {
            objects.flatten(tree, b"", prefix, &index.trees, &mut head, &mut same)?;
        }
    }

    let mut files = BTreeMap::new();
    let mut indexed = HashSet::new();
    let mut tracked_folders = HashSet::new();
    let mut added = Vec::new();
    for entry in &index.entries {
        let name = &entry.name[..];
        indexed.insert(name);
        for (at, _) in name.iter().enumerate().filter(|(_, byte)| **byte == b'/') {
            tracked_folders.insert(&name[..at]);
        }
        if !within(name, prefix) {
            continue;
        }
        if entry.stage != 0 {
            files.insert(name.to_vec(), Status::Conflicted);
            continue;
        }
        let unchanged = same.contains(&b""[..])
            || name
                .iter()
                .enumerate()
                .any(|(at, &byte)| byte == b'/' && same.contains(&name[..at]));
        let staged = match head.get(name) {
            _ if entry.extended & INTENT_TO_ADD != 0 => Some(Status::New),
            _ if unchanged => None,
            None => {
                added.push(entry);
                Some(Status::New)
            }
            Some(&(mode, id)) => (id != entry.id || canonical(mode) != canonical(entry.mode))
                .then_some(Status::Modified),
        };
        let worktree = if entry.mode & 0o170000 == GITLINK || entry.extended & SKIP_WORKTREE != 0 {
            None
        } else {
            worktree(&repo.top.join(OsStr::from_bytes(name)), entry, racy)
        };
        let status = match (staged, worktree) {
            (_, Some(Status::Deleted)) => Status::Deleted,
            (Some(status), _) | (None, Some(status)) => status,
            (None, None) => continue,
        };
        files.entry(name.to_vec()).or_insert(status);
    }

    let mut deleted: Vec<_> = head
        .iter()
        .filter(|(name, _)| !indexed.contains(&name[..]))
        .collect();
    deleted.sort_by(|a, b| a.0.cmp(b.0));
    let empty = blob_id(b"");
    for entry in added {
        if files.get(&entry.name) != Some(&Status::New) || entry.id == empty {
            continue;
        }
        let from = deleted.iter().position(|(_, (mode, id))| {
            *id == entry.id && canonical(*mode) == canonical(entry.mode)
        });
        if let Some(from) = from {
            deleted.remove(from);
            files.insert(entry.name.clone(), Status::Renamed);
        }
    }
    for (name, _) in deleted {
        files.insert(name.clone(), Status::Deleted);
    }

    let mut walk = Walk {
        top: &repo.top,
        indexed: &indexed,
        tracked_folders: &tracked_folders,
        ignores: Vec::new(),
        files: &mut files,
    };
    if let Ok(exclude) = read_file(&common.join("info/exclude"), MAX_INDEX) {
        walk.ignores.push((Vec::new(), patterns(&exclude)));
    }
    // Nothing in an ignored folder is untracked.
    let mut folder = Vec::new();
    let mut ignored = false;
    if !prefix.is_empty() {
        for part in prefix.split(|&byte| byte == b'/') {
            walk.push(&folder);
            folder = join(&folder, part);
            ignored |= walk.ignored(&folder, true);
        }
    }
    if !ignored {
        walk.walk(&folder);
    }

    let files = files
        .into_iter()
        .map(|(name, status)| {
            let relative = if prefix.is_empty() {
                &name[..]
            } else {
                &name[prefix.len() + 1..]
            };
            (PathBuf::from(OsStr::from_bytes(relative)), status)
        })
        .collect();
    Some(Statuses {
        gitdir: repo.gitdir,
        files,
    })
}

/// Whether `path` is `folder` or under it; every path is under "".
fn within(path: &[u8], folder: &[u8]) -> bool {
    folder.is_empty()
        || path
            .strip_prefix(folder)
            .is_some_and(|rest| rest.is_empty() || rest[0] == b'/')
}

fn join(folder: &[u8], name: &[u8]) -> Vec<u8> {
    if folder.is_empty() {
        name.to_vec()
    } else {
        [folder, b"/", name].concat()
    }
}

/// A mode as git compares it: a file is 644 or 755.
fn canonical(mode: u32) -> u32 {
    match mode & 0o170000 {
        0o100000 if mode & 0o100 != 0 => 0o100755,
        0o100000 => 0o100644,
        kind => kind,
    }
}

/// How the working tree's file differs from its index entry, if it does.
/// Matching stat data means unchanged unless the file is racy.
fn worktree(path: &Path, entry: &IndexEntry, racy: (i64, i64)) -> Option<Status> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::NotFound | io::ErrorKind::NotADirectory
            ) =>
        {
            return Some(Status::Deleted);
        }
        Err(_) => return None,
    };
    let kind = metadata.file_type();
    if kind.is_dir() {
        return Some(Status::Deleted);
    }
    let link = entry.mode & 0o170000 == LINK;
    if !(kind.is_file() || kind.is_symlink())
        || link != kind.is_symlink()
        || (!link && (entry.mode & 0o100 != 0) != (metadata.mode() & 0o100 != 0))
    {
        return Some(Status::Modified);
    }
    // The index keeps 32 bits of each.
    let mtime = (metadata.mtime(), metadata.mtime_nsec());
    let stat = (
        (mtime.0 as u32, mtime.1 as u32),
        metadata.ino() as u32,
        metadata.len() as u32,
    );
    if stat == (entry.mtime, entry.ino, entry.size) && mtime < racy {
        return None;
    }
    if stat.2 != entry.size {
        return Some(Status::Modified);
    }
    let bytes = if link {
        fs::read_link(path).ok()?.into_os_string().into_vec()
    } else {
        read_file(path, 1 << 40).ok()?
    };
    (blob_id(&bytes) != entry.id).then_some(Status::Modified)
}

fn read_line(path: &Path) -> Option<String> {
    let bytes = read_file(path, MAX_LINE_FILE).ok()?;
    let line = String::from_utf8(bytes).ok()?.lines().next()?.to_owned();
    Some(line)
}

fn parse_oid(hex: &str) -> Option<Oid> {
    if hex.len() != 40 {
        return None;
    }
    let mut id = [0u8; 20];
    for (at, byte) in id.iter_mut().enumerate() {
        *byte = u8::from_str_radix(hex.get(at * 2..at * 2 + 2)?, 16).ok()?;
    }
    Some(Oid(id))
}

/// The commit HEAD names, or None on a branch with no commit yet. The outer
/// None: HEAD can't be read.
fn head_commit(gitdir: &Path, common: &Path) -> Option<Option<Oid>> {
    let mut line = read_line(&gitdir.join("HEAD"))?;
    // A symbolic ref may name another; git follows five.
    for _ in 0..5 {
        let Some(name) = line.strip_prefix("ref: ") else {
            return Some(Some(parse_oid(&line)?));
        };
        let name = name.trim_end();
        if !name.starts_with("refs/")
            || name
                .split('/')
                .any(|part| part.is_empty() || part == "." || part == "..")
        {
            return None;
        }
        match read_line(&common.join(name)) {
            Some(next) => line = next,
            None => return Some(packed_ref(common, name)),
        }
    }
    None
}

fn packed_ref(common: &Path, name: &str) -> Option<Oid> {
    let packed = read_file(&common.join("packed-refs"), MAX_INDEX).ok()?;
    String::from_utf8_lossy(&packed).lines().find_map(|line| {
        let (id, named) = line.split_once(' ')?;
        (named == name).then(|| parse_oid(id))?
    })
}

/// A repository's object store: loose objects and version 2 pack indexes.
struct Objects {
    folder: PathBuf,
    packs: Vec<(Vec<u8>, File)>,
}

impl Objects {
    fn open(folder: &Path) -> Objects {
        let mut packs = Vec::new();
        for entry in fs::read_dir(folder.join("pack"))
            .into_iter()
            .flatten()
            .flatten()
        {
            let path = entry.path();
            if path.extension() != Some(OsStr::new("idx")) {
                continue;
            }
            // A pack being written or removed has one file of the two.
            let Ok(idx) = read_file(&path, MAX_INDEX) else {
                continue;
            };
            let Ok(pack) = File::open(path.with_extension("pack")) else {
                continue;
            };
            if idx.starts_with(b"\xfftOc\0\0\0\x02") {
                packs.push((idx, pack));
            }
        }
        Objects {
            folder: folder.to_path_buf(),
            packs,
        }
    }

    /// The object's type (1 commit, 2 tree, 3 blob, 4 tag) and bytes.
    /// `depth` counts the deltas read to reach it.
    fn read(&self, id: Oid, depth: usize) -> Option<(u8, Vec<u8>)> {
        let hex = id.to_string();
        if let Ok(loose) = read_file(&self.folder.join(&hex[..2]).join(&hex[2..]), MAX_INDEX) {
            let mut bytes = Vec::new();
            ZlibDecoder::new(&loose[..])
                .take(MAX_INDEX + 64)
                .read_to_end(&mut bytes)
                .ok()?;
            let nul = bytes.iter().position(|&byte| byte == 0)?;
            let header = std::str::from_utf8(&bytes[..nul]).ok()?;
            let (kind, size) = header.split_once(' ')?;
            let size = size.parse::<usize>().ok()?;
            let kind = match kind {
                "commit" => 1,
                "tree" => 2,
                "blob" => 3,
                "tag" => 4,
                _ => return None,
            };
            bytes.drain(..=nul);
            return (size == bytes.len()).then_some((kind, bytes));
        }
        self.packs.iter().find_map(|(idx, pack)| {
            let offset = find(idx, id)?;
            Some(self.packed(pack, offset, depth))
        })?
    }

    /// The object at `offset` in `pack`, its deltas applied.
    fn packed(&self, pack: &File, mut offset: u64, depth: usize) -> Option<(u8, Vec<u8>)> {
        let mut deltas = Vec::new();
        let (kind, mut bytes) = loop {
            if depth + deltas.len() > MAX_DEPTH {
                return None;
            }
            // Type and size, then a base's offset or id: at most 30 bytes.
            let mut head = [0u8; 32];
            let length = pack.read_at(&mut head, offset).ok()?;
            let mut head = head[..length].iter().copied();
            let mut byte = head.next()?;
            let kind = (byte >> 4) & 7;
            let mut size = u64::from(byte & 15);
            let mut shift = 4;
            while byte & 0x80 != 0 {
                byte = head.next()?;
                if shift > 57 {
                    return None;
                }
                size |= u64::from(byte & 0x7f) << shift;
                shift += 7;
            }
            match kind {
                1..=4 => {
                    let at = offset + (length - head.len()) as u64;
                    break (kind, inflate_at(pack, at, size)?);
                }
                6 => {
                    // Git's offset varint (varint.c).
                    let mut byte = head.next()?;
                    let mut back = u64::from(byte & 0x7f);
                    while byte & 0x80 != 0 {
                        byte = head.next()?;
                        back = back.checked_add(1)?;
                        if back >> 57 != 0 {
                            return None;
                        }
                        back = (back << 7) | u64::from(byte & 0x7f);
                    }
                    let at = offset + (length - head.len()) as u64;
                    deltas.push(inflate_at(pack, at, size)?);
                    offset = offset.checked_sub(back).filter(|_| back > 0)?;
                }
                7 => {
                    let base: Vec<u8> = head.by_ref().take(20).collect();
                    let base = Oid(base.try_into().ok()?);
                    let at = offset + (length - head.len()) as u64;
                    deltas.push(inflate_at(pack, at, size)?);
                    break self.read(base, depth + deltas.len())?;
                }
                _ => return None,
            }
        };
        for delta in deltas.iter().rev() {
            bytes = apply(&bytes, delta)?;
        }
        Some((kind, bytes))
    }

    fn commit_tree(&self, commit: Oid) -> Option<Oid> {
        let (kind, bytes) = self.read(commit, 0)?;
        let line = bytes.strip_prefix(b"tree ")?.get(..40)?;
        (kind == 1).then(|| parse_oid(std::str::from_utf8(line).ok()?))?
    }

    /// Adds the files of `tree`, at `base`, that are under `folder`, by path,
    /// and the folders whose tree `trees` holds to `same` in place of theirs.
    fn flatten(
        &self,
        tree: Oid,
        base: &[u8],
        folder: &[u8],
        trees: &HashMap<Vec<u8>, Oid>,
        files: &mut HashMap<Vec<u8>, (u32, Oid)>,
        same: &mut HashSet<Vec<u8>>,
    ) -> Option<()> {
        let (kind, bytes) = self.read(tree, 0)?;
        if kind != 2 {
            return None;
        }
        let mut rest = &bytes[..];
        while !rest.is_empty() {
            let space = rest.iter().position(|&byte| byte == b' ')?;
            let mode = u32::from_str_radix(std::str::from_utf8(&rest[..space]).ok()?, 8).ok()?;
            let nul = space + rest[space..].iter().position(|&byte| byte == 0)?;
            let path = join(base, &rest[space + 1..nul]);
            let id = Oid(rest.get(nul + 1..nul + 21)?.try_into().ok()?);
            rest = &rest[nul + 21..];
            if mode == TREE {
                if trees.get(&path) == Some(&id) {
                    same.insert(path);
                } else if within(&path, folder) || within(folder, &path) {
                    self.flatten(id, &path, folder, trees, files, same)?;
                }
            } else if within(&path, folder) {
                files.insert(path, (mode, id));
            }
        }
        Some(())
    }
}

/// The offset of `id` in a version 2 pack index: a 256-entry fanout of
/// counts, the sorted ids, their CRCs, 31-bit offsets, then 64-bit ones.
fn find(idx: &[u8], id: Oid) -> Option<u64> {
    let word = |at: usize| Some(u32::from_be_bytes(idx.get(at..at + 4)?.try_into().ok()?));
    let first = usize::from(id.0[0]);
    let count = word(8 + 4 * 255)? as usize;
    let mut low = if first == 0 {
        0
    } else {
        word(8 + 4 * (first - 1))? as usize
    };
    let mut high = (word(8 + 4 * first)? as usize).min(count);
    let ids = 8 + 4 * 256;
    while low < high {
        let middle = (low + high) / 2;
        let at = ids + 20 * middle;
        match idx.get(at..at + 20)?.cmp(&id.0[..]) {
            std::cmp::Ordering::Less => low = middle + 1,
            std::cmp::Ordering::Greater => high = middle,
            std::cmp::Ordering::Equal => {
                let offsets = ids + 24 * count;
                let offset = word(offsets + 4 * middle)?;
                if offset & 0x8000_0000 == 0 {
                    return Some(u64::from(offset));
                }
                let at = offsets + 4 * count + 8 * (offset & 0x7fff_ffff) as usize;
                return Some(u64::from_be_bytes(idx.get(at..at + 8)?.try_into().ok()?));
            }
        }
    }
    None
}

/// Inflates the zlib stream at `offset`, which must give `size` bytes.
fn inflate_at(file: &File, mut offset: u64, size: u64) -> Option<Vec<u8>> {
    if size > MAX_INDEX {
        return None;
    }
    let mut bytes = Vec::with_capacity(size as usize);
    let mut inflate = Decompress::new(true);
    let mut chunk = vec![0u8; (size as usize + 64).min(64 << 10)];
    loop {
        let length = file.read_at(&mut chunk, offset).ok()?;
        let (read, written) = (inflate.total_in(), bytes.len());
        let status = inflate
            .decompress_vec(&chunk[..length], &mut bytes, FlushDecompress::None)
            .ok()?;
        if status == flate2::Status::StreamEnd {
            return (bytes.len() as u64 == size).then_some(bytes);
        }
        if inflate.total_in() == read && bytes.len() == written {
            return None;
        }
        offset += inflate.total_in() - read;
    }
}

/// Applies a git delta: the base's size, the result's, then copies from the
/// base and inserts.
fn apply(base: &[u8], delta: &[u8]) -> Option<Vec<u8>> {
    let mut delta = delta.iter().copied();
    let mut size = || {
        let mut value = 0u64;
        for shift in (0..64).step_by(7) {
            let byte = delta.next()?;
            value |= u64::from(byte & 0x7f) << shift;
            if byte & 0x80 == 0 {
                return Some(value);
            }
        }
        None
    };
    if size()? != base.len() as u64 {
        return None;
    }
    let length = size()?;
    if length > MAX_INDEX {
        return None;
    }
    let mut bytes = Vec::with_capacity(length as usize);
    while let Some(op) = delta.next() {
        if op & 0x80 != 0 {
            let mut field = |bits: std::ops::Range<u8>| {
                let mut value = 0usize;
                for bit in bits.clone() {
                    if op & (1 << bit) != 0 {
                        value |= usize::from(delta.next()?) << (8 * (bit - bits.start));
                    }
                }
                Some(value)
            };
            let from = field(0..4)?;
            let count = match field(4..7)? {
                0 => 0x10000,
                count => count,
            };
            bytes.extend_from_slice(base.get(from..from.checked_add(count)?)?);
        } else if op != 0 {
            for _ in 0..op {
                bytes.push(delta.next()?);
            }
        } else {
            return None;
        }
    }
    (bytes.len() as u64 == length).then_some(bytes)
}

/// One line of an ignore file.
struct Pattern {
    glob: Vec<u8>,
    negated: bool,
    folders_only: bool,
    /// A slash before the end ties the glob to the file's folder; otherwise
    /// it matches names at any depth.
    anchored: bool,
}

/// An ignore file's patterns, as gitignore(5) reads them.
fn patterns(bytes: &[u8]) -> Vec<Pattern> {
    bytes
        .split(|&byte| byte == b'\n')
        .filter_map(|line| {
            let mut line = line.strip_suffix(b"\r").unwrap_or(line);
            // Trailing spaces go unless a backslash quotes them.
            while let [rest @ .., b' '] = line {
                if rest.ends_with(b"\\") {
                    break;
                }
                line = rest;
            }
            if line.first().is_none_or(|&byte| byte == b'#') {
                return None;
            }
            let negated = line[0] == b'!';
            if negated {
                line = &line[1..];
            }
            let folders_only = line.ends_with(b"/");
            if folders_only {
                line = &line[..line.len() - 1];
            }
            let anchored = line.contains(&b'/');
            let line = line.strip_prefix(b"/").unwrap_or(line);
            (!line.is_empty()).then(|| Pattern {
                glob: line.to_vec(),
                negated,
                folders_only,
                anchored,
            })
        })
        .collect()
}

#[derive(PartialEq)]
enum Wild {
    Match,
    NoMatch,
    AbortAll,
    AbortToDoubleStar,
}

/// Git's wildmatch (wildmatch.c) with WM_PATHNAME: `*`, `?` and classes
/// stop at `/`, and `**` between slashes spans folders. POSIX character
/// classes are not read.
fn wildmatch(pattern: &[u8], text: &[u8]) -> bool {
    dowild(pattern, 0, text, 0) == Wild::Match
}

fn dowild(pattern: &[u8], mut p: usize, text: &[u8], mut t: usize) -> Wild {
    let at = |bytes: &[u8], i: usize| bytes.get(i).copied().unwrap_or(0);
    while p < pattern.len() {
        let mut p_ch = pattern[p];
        let t_ch = at(text, t);
        if t_ch == 0 && p_ch != b'*' {
            return Wild::AbortAll;
        }
        match p_ch {
            b'?' => {
                if t_ch == b'/' {
                    return Wild::NoMatch;
                }
            }
            b'*' => {
                p += 1;
                let mut spans = false;
                if at(pattern, p) == b'*' {
                    let before = p.checked_sub(2);
                    while at(pattern, p) == b'*' {
                        p += 1;
                    }
                    let next = at(pattern, p);
                    if before.is_none_or(|before| pattern[before] == b'/')
                        && (next == 0 || next == b'/')
                    {
                        if next == b'/' && dowild(pattern, p + 1, text, t) == Wild::Match {
                            return Wild::Match;
                        }
                        spans = true;
                    }
                }
                if p == pattern.len() {
                    return if spans || !text[t..].contains(&b'/') {
                        Wild::Match
                    } else {
                        Wild::NoMatch
                    };
                }
                if !spans && pattern[p] == b'/' {
                    // One star then a slash matches the rest of this folder.
                    let Some(slash) = text[t..].iter().position(|&byte| byte == b'/') else {
                        return Wild::NoMatch;
                    };
                    t += slash;
                    // The slashes match below.
                    continue;
                }
                while t < text.len() {
                    match dowild(pattern, p, text, t) {
                        Wild::NoMatch if !spans && text[t] == b'/' => {
                            return Wild::AbortToDoubleStar;
                        }
                        Wild::NoMatch => {}
                        Wild::AbortToDoubleStar if spans => {}
                        matched => return matched,
                    }
                    t += 1;
                }
                return Wild::AbortAll;
            }
            b'[' => {
                p += 1;
                p_ch = at(pattern, p);
                if p_ch == b'^' {
                    p_ch = b'!';
                }
                let negated = p_ch == b'!';
                if negated {
                    p += 1;
                    p_ch = at(pattern, p);
                }
                let mut previous = 0u8;
                let mut matched = false;
                loop {
                    if p_ch == 0 {
                        return Wild::AbortAll;
                    }
                    if p_ch == b'\\' {
                        p += 1;
                        p_ch = at(pattern, p);
                        if p_ch == 0 {
                            return Wild::AbortAll;
                        }
                        matched |= t_ch == p_ch;
                    } else if p_ch == b'-'
                        && previous != 0
                        && at(pattern, p + 1) != 0
                        && at(pattern, p + 1) != b']'
                    {
                        p += 1;
                        p_ch = at(pattern, p);
                        if p_ch == b'\\' {
                            p += 1;
                            p_ch = at(pattern, p);
                            if p_ch == 0 {
                                return Wild::AbortAll;
                            }
                        }
                        matched |= previous <= t_ch && t_ch <= p_ch;
                        p_ch = 0;
                    } else {
                        matched |= t_ch == p_ch;
                    }
                    previous = p_ch;
                    p += 1;
                    p_ch = at(pattern, p);
                    if p_ch == b']' {
                        break;
                    }
                }
                if matched == negated || t_ch == b'/' {
                    return Wild::NoMatch;
                }
            }
            _ => {
                if p_ch == b'\\' {
                    p += 1;
                    p_ch = at(pattern, p);
                }
                if t_ch != p_ch {
                    return Wild::NoMatch;
                }
            }
        }
        p += 1;
        t += 1;
    }
    if t < text.len() {
        Wild::NoMatch
    } else {
        Wild::Match
    }
}

/// The walk for untracked files.
struct Walk<'a> {
    top: &'a Path,
    indexed: &'a HashSet<&'a [u8]>,
    tracked_folders: &'a HashSet<&'a [u8]>,
    /// The ignore files that apply, each with its folder, shallowest first.
    ignores: Vec<(Vec<u8>, Vec<Pattern>)>,
    files: &'a mut BTreeMap<Vec<u8>, Status>,
}

impl Walk<'_> {
    /// Takes in `folder`'s .gitignore, if it has one.
    fn push(&mut self, folder: &[u8]) -> bool {
        let path = self.top.join(OsStr::from_bytes(folder)).join(".gitignore");
        let Ok(bytes) = read_file(&path, MAX_INDEX) else {
            return false;
        };
        self.ignores.push((folder.to_vec(), patterns(&bytes)));
        true
    }

    /// The last pattern to match decides, deeper ignore files first.
    fn ignored(&self, path: &[u8], folder: bool) -> bool {
        let name = path.rsplit(|&byte| byte == b'/').next().unwrap_or(path);
        for (base, patterns) in self.ignores.iter().rev() {
            let relative = if base.is_empty() {
                path
            } else {
                match path
                    .strip_prefix(&base[..])
                    .and_then(|rest| rest.strip_prefix(b"/"))
                {
                    Some(relative) => relative,
                    None => continue,
                }
            };
            for pattern in patterns.iter().rev() {
                if pattern.folders_only && !folder {
                    continue;
                }
                let text = if pattern.anchored { relative } else { name };
                if wildmatch(&pattern.glob, text) {
                    return !pattern.negated;
                }
            }
        }
        false
    }

    /// `folder`'s children but `.git`, and whether each is a folder.
    fn list(&self, folder: &[u8]) -> Vec<(Vec<u8>, bool)> {
        let entries = fs::read_dir(self.top.join(OsStr::from_bytes(folder)));
        entries
            .into_iter()
            .flatten()
            .flatten()
            .filter(|entry| entry.file_name() != ".git")
            .map(|entry| {
                let path = join(folder, entry.file_name().as_bytes());
                (path, entry.file_type().is_ok_and(|kind| kind.is_dir()))
            })
            .collect()
    }

    fn walk(&mut self, folder: &[u8]) {
        let pushed = self.push(folder);
        for (path, is_folder) in self.list(folder) {
            if self.indexed.contains(&path[..]) {
                continue;
            }
            if is_folder && self.tracked_folders.contains(&path[..]) {
                if !self.ignored(&path, true) {
                    self.walk(&path);
                }
            } else if !self.ignored(&path, is_folder) && (!is_folder || self.holds_untracked(&path))
            {
                self.files.insert(path, Status::New);
            }
        }
        if pushed {
            self.ignores.pop();
        }
    }

    /// Whether an untracked folder holds a file no ignore file matches. A
    /// repository inside counts as one.
    fn holds_untracked(&mut self, folder: &[u8]) -> bool {
        let top = self.top.join(OsStr::from_bytes(folder));
        if fs::symlink_metadata(top.join(".git")).is_ok() {
            return true;
        }
        let pushed = self.push(folder);
        let found = self.list(folder).into_iter().any(|(path, is_folder)| {
            !self.ignored(&path, is_folder) && (!is_folder || self.holds_untracked(&path))
        });
        if pushed {
            self.ignores.pop();
        }
        found
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::{git, repo, run, write};
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};

    fn statuses(folder: &Path) -> Vec<(String, Status)> {
        status(folder)
            .unwrap()
            .files
            .into_iter()
            .map(|(path, status)| (path.to_str().unwrap().to_owned(), status))
            .collect()
    }

    /// The paths `git status` lists under `folder`, once each: a rename's new
    /// path, an untracked folder without its slash.
    fn git_paths(root: &Path, folder: &str) -> Vec<String> {
        let output = git(
            root,
            &["status", "--porcelain=v1", "-z", "--untracked-files=normal"],
        );
        let mut paths = Vec::new();
        let mut fields = output.split('\0').filter(|field| !field.is_empty());
        while let Some(field) = fields.next() {
            if field.starts_with('R') {
                fields.next();
            }
            let path = field[3..].trim_end_matches('/');
            if let Some(path) = path.strip_prefix(folder) {
                paths.push(path.to_owned());
            }
        }
        paths.sort();
        paths.dedup();
        paths
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
            ("new/name.md", Renamed),
            ("notes.md", New),
            ("staged.md", New),
        ];
        let expected: Vec<_> = expected
            .iter()
            .map(|&(path, status)| (path.to_owned(), status))
            .collect();
        let found = statuses(&root);
        assert_eq!(found, expected);
        let paths: Vec<_> = found.into_iter().map(|(path, _)| path).collect();
        assert_eq!(paths, git_paths(&root, ""));
        assert_eq!(status(&root).unwrap().gitdir, root.join(".git"));

        // A folder inside the repository: its files, by their paths from it.
        write(&root, "docs/plan.md", b"# Plan, edited\n");
        assert_eq!(
            statuses(&root.join("docs")),
            [("new.md".to_owned(), New), ("plan.md".to_owned(), Modified)]
        );
        assert_eq!(
            statuses(&root.join("docs")).len(),
            git_paths(&root, "docs/").len()
        );
        assert_eq!(statuses(&root.join("docs/drafts")), []);
    }

    #[test]
    fn packed_objects_refs_and_linked_worktrees() {
        let (_dir, root) = repo(&[("CLAUDE.md", b"# Claude\n"), ("docs/plan.md", b"0\n")]);
        // Enough similar trees that the pack stores some as deltas.
        for round in 1..=40 {
            write(&root, "docs/plan.md", format!("{round}\n").as_bytes());
            write(&root, &format!("docs/more/{round}.md"), b"more\n");
            git(&root, &["add", "-A"]);
            git(&root, &["commit", "-q", "-m", &round.to_string()]);
        }
        git(&root, &["gc", "-q", "--aggressive"]);
        assert!(!root.join(".git/refs/heads/main").exists(), "refs packed");
        let verify: String = fs::read_dir(root.join(".git/objects/pack"))
            .unwrap()
            .flatten()
            .filter(|entry| entry.path().extension() == Some(OsStr::new("idx")))
            .map(|idx| git(&root, &["verify-pack", "-v", idx.path().to_str().unwrap()]))
            .collect();
        let tree_deltas = verify
            .lines()
            .filter(|line| line.split_whitespace().nth(1) == Some("tree"))
            .filter(|line| line.split_whitespace().count() == 7)
            .count();
        assert!(tree_deltas > 0, "{verify}");

        assert_eq!(statuses(&root), []);
        write(&root, "docs/more/7.md", b"edited\n");
        assert_eq!(
            statuses(&root),
            [("docs/more/7.md".to_owned(), Status::Modified)]
        );

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

    #[test]
    fn wildmatch_as_git() {
        let table = [
            ("foo", "foo", true),
            ("*", "foo", true),
            ("*", "a/b", false),
            ("**", "a/b", true),
            ("**/foo", "foo", true),
            ("**/foo", "a/b/foo", true),
            ("a/**/b", "a/b", true),
            ("a/**/b", "a/x/y/b", true),
            ("a/**", "a/x/y", true),
            ("a/*", "a/x/y", false),
            ("a/*/c", "a/b/c", true),
            ("**foo", "a/foo", false),
            ("*.md", "x.md", true),
            ("foo*bar", "foo/bar", false),
            ("a?c", "abc", true),
            ("a?c", "a/c", false),
            ("[a-c]x", "bx", true),
            ("[!a-c]x", "bx", false),
            ("[^a-c]x", "dx", true),
            ("[]]", "]", true),
            ("[a-]", "-", true),
            ("\\*", "*", true),
            ("\\*", "x", false),
            ("[ab", "a", false),
        ];
        for (pattern, text, matches) in table {
            assert_eq!(
                wildmatch(pattern.as_bytes(), text.as_bytes()),
                matches,
                "{pattern} {text}"
            );
        }
    }
}
