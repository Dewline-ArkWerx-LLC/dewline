//! Each file's state under a folder, as `git status` reports it: the index
//! against HEAD's tree, the working tree against the index, and the files no
//! ignore file matches that the index doesn't list. Read from the
//! repository's files, as the rest of this module reads them; no git runs.

use std::cmp::Reverse;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::ffi::{OsStr, c_void};
use std::fmt::Write as _;
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

/// Bounds the work of reading one object: deltas in its chain, and bytes
/// inflated.
const MAX_DEPTH: usize = 4095;
const MAX_INFLATED: u64 = MAX_INDEX;
/// Bounds HEAD's tree entries read, which a tree naming one subtree many
/// times could otherwise multiply.
const MAX_TREE_ENTRIES: usize = 1 << 22;

const LINK: u32 = 0o120000;
const GITLINK: u32 = 0o160000;
const TREE: u32 = 0o040000;
/// Git's default rename limit, 1000, squared, and its scale for a score.
const MAX_RENAME_PAIRS: usize = 1000 * 1000;
const MAX_SCORE: u64 = 60_000;
/// The most bytes read of each blob a rename's content is compared in; a
/// larger one pairs with nothing.
const MAX_RENAME_BYTES: u64 = 256 << 10;
/// The most bytes read of all blobs, and pieces looked up, in one rename
/// search; past either, nothing pairs.
const MAX_RENAME_TOTAL: u64 = 8 << 20;
const MAX_RENAME_LOOKUPS: usize = 1 << 22;

/// The state of the files under `folder`, a realpath. An untracked folder
/// holding no tracked file is one path, as git status lists it. Renames are
/// the same blob at the new path, or a staged file at least half of whose
/// bytes a file the index deletes holds. Ignore files are as `Ignores` reads
/// them. A file over 256 MB whose stat data
/// changed counts as modified. A working tree file is compared as `Checkout`
/// says git cleans it. None when the folder is in no repository, or its
/// index, HEAD or objects can't be read: split or sparse indexes, SHA-256
/// repositories, reftables, alternates and missing objects.
pub fn status(folder: &Path) -> Option<Statuses> {
    // `find` looks for `.git` in each folder above the path, the folder first.
    let repo = Repo::find(&folder.join(".git"))?;
    let prefix = folder.strip_prefix(&repo.top).ok()?.as_os_str().as_bytes();
    let common = common(&repo.gitdir);
    let configs = configs(&common);
    if config_value(&configs[2], b"extensions", b"objectformat")
        .is_some_and(|format| !format.eq_ignore_ascii_case(b"sha1"))
    {
        return None;
    }

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
    let objects = Objects::open(&common.join("objects"));
    let checkout = Checkout {
        file_mode: setting(&configs, b"core", b"filemode")
            .is_none_or(|value| config_bool(&value) != Some(false)),
        crlf: setting(&configs, b"core", b"autocrlf").is_some_and(|value| {
            value.eq_ignore_ascii_case(b"input") || config_bool(&value) == Some(true)
        }),
        objects: &objects,
    };
    let tree = match head_commit(&repo.gitdir, &common)? {
        Some(commit) => Some(objects.commit_tree(commit)?),
        None => None,
    };
    let mut head = HashMap::new();
    let mut same = HashSet::new();
    if let Some(tree) = tree {
        if index.trees.get(&b""[..]) == Some(&tree) {
            same.insert(Vec::new());
        } else {
            objects.flatten(tree, prefix, &index.trees, &mut head, &mut same)?;
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
            worktree(
                &repo.top.join(OsStr::from_bytes(name)),
                entry,
                racy,
                &checkout,
            )
        };
        let status = match (staged, worktree) {
            (_, Some(Status::Deleted)) => Status::Deleted,
            (Some(status), _) | (None, Some(status)) => status,
            (None, None) => continue,
        };
        files.entry(name.to_vec()).or_insert(status);
    }

    // A file renamed into the folder can come from anywhere in HEAD.
    if let Some(tree) = tree.filter(|_| !prefix.is_empty() && !added.is_empty()) {
        objects.flatten(tree, b"", &index.trees, &mut head, &mut HashSet::new())?;
    }

    // Deleted files by blob, each list in reverse byte order of path, so a
    // rename takes the first.
    let mut deleted: HashMap<(u32, Oid), Vec<&Vec<u8>>> = HashMap::new();
    let mut gone: Vec<_> = head
        .iter()
        .filter(|(name, _)| !indexed.contains(&name[..]))
        .collect();
    gone.sort_by(|a, b| b.0.cmp(a.0));
    for (name, &(mode, id)) in gone {
        deleted.entry((canonical(mode), id)).or_default().push(name);
    }
    let empty = blob_id(b"");
    let mut unmatched = Vec::new();
    for entry in added {
        if files.get(&entry.name) != Some(&Status::New) || entry.id == empty {
            continue;
        }
        let from = deleted.get_mut(&(canonical(entry.mode), entry.id));
        if from.and_then(|names| names.pop()).is_some() {
            files.insert(entry.name.clone(), Status::Renamed);
        } else if canonical(entry.mode) & 0o170000 == 0o100000 {
            unmatched.push(entry);
        }
    }
    let mut gone: Vec<_> = deleted
        .into_iter()
        .flat_map(|((mode, id), names)| names.into_iter().map(move |name| (name, mode, id)))
        .collect();
    gone.sort_by(|a, b| a.0.cmp(b.0));
    let sources: Vec<_> = gone
        .iter()
        .filter(|(_, mode, id)| mode & 0o170000 == 0o100000 && *id != empty)
        .collect();
    let from: Vec<_> = sources.iter().map(|(_, _, id)| *id).collect();
    let to: Vec<_> = unmatched.iter().map(|entry| entry.id).collect();
    let mut renamed = HashSet::new();
    for (from, to) in similar(&objects, &from, &to) {
        renamed.insert(sources[from].0);
        files.insert(unmatched[to].name.clone(), Status::Renamed);
    }
    for (name, _, _) in gone {
        if !renamed.contains(name) {
            files.insert(name.clone(), Status::Deleted);
        }
    }

    let mut walk = Walk {
        top: &repo.top,
        indexed: &indexed,
        tracked_folders: &tracked_folders,
        ignores: Ignores::new(&repo.top, Some(&common)),
        files: &mut files,
    };
    // Nothing in an ignored folder is untracked.
    if prefix.is_empty() || !walk.ignores.ignored(prefix, true) {
        walk.walk(prefix);
    }

    // A file at the folder's own path is not under it.
    let files = files
        .into_iter()
        .filter_map(|(name, status)| {
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

/// The folder that holds a worktree's objects, refs and config.
fn common(gitdir: &Path) -> PathBuf {
    match read_line(&gitdir.join("commondir")) {
        Some(common) => gitdir.join(common),
        None => gitdir.to_path_buf(),
    }
}

fn home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

fn xdg_config() -> Option<PathBuf> {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|xdg| xdg.is_absolute())
        .or_else(|| Some(home()?.join(".config")))
}

/// The user's config files, then the repository's, each empty when it can't
/// be read: the order git reads them in, so the last value found decides.
/// The system config and includes are not read.
fn configs(common: &Path) -> [Vec<u8>; 3] {
    [
        xdg_config().map(|xdg| xdg.join("git/config")),
        home().map(|home| home.join(".gitconfig")),
        Some(common.join("config")),
    ]
    .map(|path| {
        path.and_then(|path| read_file(&path, MAX_INDEX).ok())
            .unwrap_or_default()
    })
}

/// The value of `key` in `section` that git takes from `configs`.
fn setting(configs: &[Vec<u8>], section: &[u8], key: &[u8]) -> Option<Vec<u8>> {
    configs
        .iter()
        .rev()
        .find_map(|config| config_value(config, section, key))
}

/// A boolean config value as git reads it, None when it isn't one.
fn config_bool(value: &[u8]) -> Option<bool> {
    match value.to_ascii_lowercase().as_slice() {
        b"true" | b"yes" | b"on" => Some(true),
        b"false" | b"no" | b"off" | b"" => Some(false),
        number => Some(std::str::from_utf8(number).ok()?.parse::<i64>().ok()? != 0),
    }
}

/// The ignore file `core.excludesFile` names in the config files `configs`
/// reads, else git's default, ~/.config/git/ignore. A relative path is from
/// `top`.
fn excludes_file(top: &Path, common: &Path) -> Option<PathBuf> {
    let Some(named) = setting(&configs(common), b"core", b"excludesfile") else {
        return Some(xdg_config()?.join("git/ignore"));
    };
    let path = PathBuf::from(OsStr::from_bytes(&named));
    Some(match path.strip_prefix("~") {
        Ok(rest) => home()?.join(rest),
        Err(_) => top.join(path),
    })
}

/// The last value `key` takes in `section`, without a subsection, in a git
/// config file. Both names are lowercase. Lines a backslash continues are not
/// joined.
fn config_value(bytes: &[u8], section: &[u8], key: &[u8]) -> Option<Vec<u8>> {
    let mut inside = false;
    let mut found = None;
    for line in bytes.split(|&byte| byte == b'\n') {
        let mut line = line.trim_ascii_start();
        if let Some(rest) = line.strip_prefix(b"[") {
            let Some(end) = rest.iter().position(|&byte| byte == b']') else {
                continue;
            };
            inside = rest[..end].trim_ascii().eq_ignore_ascii_case(section);
            line = rest[end + 1..].trim_ascii_start();
        }
        let name = line
            .iter()
            .position(|byte| !(byte.is_ascii_alphanumeric() || *byte == b'-'))
            .unwrap_or(line.len());
        if !inside || !line[..name].eq_ignore_ascii_case(key) {
            continue;
        }
        if let Some(value) = line[name..].trim_ascii_start().strip_prefix(b"=") {
            found = Some(config_string(value));
        }
    }
    found
}

/// A config value as git reads it: quotes and escapes taken out, a comment
/// and unquoted space at the ends dropped.
fn config_string(value: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut kept = 0;
    let mut quoted = false;
    let mut bytes = value.trim_ascii_start().iter();
    while let Some(&byte) = bytes.next() {
        match byte {
            b'"' => quoted = !quoted,
            b'#' | b';' if !quoted => break,
            b'\\' => {
                out.push(match bytes.next() {
                    Some(b'n') => b'\n',
                    Some(b't') => b'\t',
                    Some(b'b') => 8,
                    Some(&escaped) => escaped,
                    None => break,
                });
                kept = out.len();
            }
            _ => {
                out.push(byte);
                if quoted || !byte.is_ascii_whitespace() {
                    kept = out.len();
                }
            }
        }
    }
    out.truncate(kept);
    out
}

/// Pairs of a deleted and an added blob, by their places in `deleted` and
/// `added`, as git's rename detection pairs them: each blob once, best
/// score first, where the score is the bytes of lines (in pieces of 64 bytes
/// at most) the two have in common over the larger one's size, and at least
/// half. Nothing when there are more than git's default limit of pairs, or
/// the search passes `MAX_RENAME_TOTAL` or `MAX_RENAME_LOOKUPS`; a blob over
/// `MAX_RENAME_BYTES` pairs with nothing.
fn similar(objects: &Objects, deleted: &[Oid], added: &[Oid]) -> Vec<(usize, usize)> {
    if deleted.is_empty() || added.is_empty() || deleted.len() * added.len() > MAX_RENAME_PAIRS {
        return Vec::new();
    }
    // An object that can't be read is empty, which pairs with nothing.
    let mut left = MAX_RENAME_TOTAL;
    let mut read = |ids: &[Oid]| -> Option<Vec<Vec<u8>>> {
        ids.iter()
            .map(|id| {
                let bytes = objects
                    .read(*id, MAX_RENAME_BYTES)
                    .filter(|(kind, _)| *kind == 3)
                    .map(|(_, bytes)| bytes)
                    .unwrap_or_default();
                left = left.checked_sub(bytes.len() as u64)?;
                Some(bytes)
            })
            .collect()
    };
    let Some(deleted) = read(deleted) else {
        return Vec::new();
    };
    let Some(added) = read(added) else {
        return Vec::new();
    };
    let mut lookups = MAX_RENAME_LOOKUPS;
    let added_pieces: Vec<_> = added.iter().map(|blob| pieces(blob)).collect();
    let mut scores = Vec::new();
    for (d, blob) in deleted.iter().enumerate() {
        let counts = pieces(blob);
        for (a, (other, others)) in added.iter().zip(&added_pieces).enumerate() {
            let larger = blob.len().max(other.len());
            if larger == 0 || blob.len().min(other.len()) * 2 < larger {
                continue;
            }
            let Some(rest) = lookups.checked_sub(counts.len()) else {
                return Vec::new();
            };
            lookups = rest;
            let common: usize = counts
                .iter()
                .filter_map(|(piece, count)| Some(*count.min(others.get(piece)?)))
                .sum();
            if common * 2 >= larger {
                scores.push((common as u64 * MAX_SCORE / larger as u64, d, a));
            }
        }
    }
    scores.sort_by_key(|&(score, d, a)| (Reverse(score), d, a));
    let (mut from, mut to) = (HashSet::new(), HashSet::new());
    let mut pairs = Vec::new();
    for (_, d, a) in scores {
        if !from.contains(&d) && !to.contains(&a) {
            from.insert(d);
            to.insert(a);
            pairs.push((d, a));
        }
    }
    pairs
}

/// A blob's bytes by piece: each line, cut every 64 bytes.
fn pieces(blob: &[u8]) -> HashMap<&[u8], usize> {
    let mut counts = HashMap::new();
    for line in blob.split_inclusive(|&byte| byte == b'\n') {
        for piece in line.chunks(64) {
            *counts.entry(piece).or_default() += piece.len();
        }
    }
    counts
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

/// How git turns a working tree file into the blob it compares with the
/// index: the exec bit counts only with core.fileMode, core.autocrlf (true or
/// input) cleans a text file's CRLFs to LF, and a file whose staged blob is a
/// Git LFS pointer is cleaned to its pointer. Attributes are not read.
struct Checkout<'a> {
    file_mode: bool,
    crlf: bool,
    objects: &'a Objects,
}

const LFS_VERSION: &[u8] = b"version https://git-lfs.github.com/spec/v1\n";
/// Git LFS reads no larger pointer.
const MAX_LFS_POINTER: u64 = 1024;

impl Checkout<'_> {
    /// Whether git cleans `bytes`, which are not the blob `id` as they are,
    /// to that blob.
    fn cleans_to(&self, bytes: &[u8], id: Oid) -> bool {
        if self.crlf
            && let Some(text) = crlf_to_lf(bytes)
            && blob_id(&text) == id
        {
            return true;
        }
        let Some((3, pointer)) = self.objects.read(id, MAX_LFS_POINTER) else {
            return false;
        };
        pointer.starts_with(LFS_VERSION)
            && pointer.ends_with(format!("\nsize {}\n", bytes.len()).as_bytes())
            && pointer == lfs_pointer(bytes)
    }
}

/// `bytes` with each CRLF made LF, if git's autocrlf takes them for text and
/// they hold a CRLF: no NUL, no CR but before LF, and fewer than one byte in
/// 128 unprintable, as convert.c counts them.
fn crlf_to_lf(bytes: &[u8]) -> Option<Vec<u8>> {
    let (mut printable, mut unprintable, mut crlf) = (0usize, 0usize, false);
    let mut rest = bytes.iter().peekable();
    while let Some(&byte) = rest.next() {
        match byte {
            b'\r' if rest.next_if_eq(&&b'\n').is_some() => crlf = true,
            b'\r' | 0 => return None,
            b'\n' => {}
            8 | b'\t' | 0x0c | 0x1b => printable += 1,
            1..=31 | 127 => unprintable += 1,
            _ => printable += 1,
        }
    }
    // A DOS end-of-file mark at the end is not counted.
    if bytes.last() == Some(&0x1a) {
        unprintable -= 1;
    }
    (crlf && printable >> 7 >= unprintable).then(|| {
        bytes
            .iter()
            .copied()
            .filter(|&byte| byte != b'\r')
            .collect()
    })
}

// CommonCrypto, part of libSystem.
unsafe extern "C" {
    fn CC_SHA256(data: *const c_void, len: u32, md: *mut u8) -> *mut u8;
}

/// The pointer Git LFS's clean filter stores for `bytes`, at most
/// `MAX_INDEX` of them.
fn lfs_pointer(bytes: &[u8]) -> Vec<u8> {
    let mut digest = [0u8; 32];
    // SAFETY: `bytes` fits CC_LONG and `digest` holds the 32-byte digest.
    unsafe {
        CC_SHA256(
            bytes.as_ptr().cast(),
            bytes.len() as u32,
            digest.as_mut_ptr(),
        )
    };
    let mut pointer = String::from_utf8_lossy(LFS_VERSION).into_owned() + "oid sha256:";
    for byte in digest {
        let _ = write!(pointer, "{byte:02x}");
    }
    let _ = writeln!(pointer, "\nsize {}", bytes.len());
    pointer.into_bytes()
}

/// How the working tree's file differs from its index entry, if it does.
/// Matching stat data means unchanged unless the file is racy.
fn worktree(
    path: &Path,
    entry: &IndexEntry,
    racy: (i64, i64),
    checkout: &Checkout,
) -> Option<Status> {
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
        || (!link
            && checkout.file_mode
            && (entry.mode & 0o100 != 0) != (metadata.mode() & 0o100 != 0))
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
        match read_file(path, MAX_INDEX) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::FileTooLarge => {
                return Some(Status::Modified);
            }
            Err(_) => return None,
        }
    };
    let same = blob_id(&bytes) == entry.id || (!link && checkout.cleans_to(&bytes, entry.id));
    (!same).then_some(Status::Modified)
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
    if common.join("reftable").exists() {
        return None;
    }
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
        match read_file(&common.join(name), MAX_LINE_FILE) {
            Ok(bytes) => line = String::from_utf8(bytes).ok()?.lines().next()?.to_owned(),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return packed_ref(common, name);
            }
            Err(_) => return None,
        }
    }
    None
}

/// The ref's commit in packed-refs, None inside when it isn't there.
fn packed_ref(common: &Path, name: &str) -> Option<Option<Oid>> {
    let packed = match read_file(&common.join("packed-refs"), MAX_INDEX) {
        Ok(packed) => packed,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Some(None),
        Err(_) => return None,
    };
    for line in String::from_utf8_lossy(&packed).lines() {
        if let Some((id, named)) = line.split_once(' ')
            && named == name
        {
            return Some(Some(parse_oid(id)?));
        }
    }
    Some(None)
}

/// A repository's object store: loose objects, and packs with version 2
/// indexes.
struct Objects {
    folder: PathBuf,
    packs: Vec<Pack>,
}

struct Pack {
    idx: File,
    pack: File,
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
            let (Ok(idx), Ok(pack)) = (File::open(&path), File::open(path.with_extension("pack")))
            else {
                continue;
            };
            let mut header = [0u8; 8];
            if idx.read_exact_at(&mut header, 0).is_ok() && &header == b"\xfftOc\0\0\0\x02" {
                packs.push(Pack { idx, pack });
            }
        }
        Objects {
            folder: folder.to_path_buf(),
            packs,
        }
    }

    /// The object's type (1 commit, 2 tree, 3 blob, 4 tag) and bytes, its
    /// deltas applied, if they and its bases take at most `limit` bytes.
    fn read(&self, id: Oid, limit: u64) -> Option<(u8, Vec<u8>)> {
        let mut deltas = Vec::new();
        let mut inflated = 0u64;
        let mut next = id;
        let (kind, mut bytes) = 'chain: loop {
            let hex = next.to_string();
            if let Ok(loose) = read_file(&self.folder.join(&hex[..2]).join(&hex[2..]), MAX_INDEX) {
                break loose_object(&loose, limit)?;
            }
            let (pack, mut offset) = self
                .packs
                .iter()
                .find_map(|pack| Some((&pack.pack, pack.find(next)?)))?;
            loop {
                if deltas.len() > MAX_DEPTH {
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
                inflated += size;
                if inflated > limit {
                    return None;
                }
                match kind {
                    1..=4 => {
                        let at = offset + (length - head.len()) as u64;
                        break 'chain (kind, inflate_at(pack, at, size)?);
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
                        next = Oid(base.try_into().ok()?);
                        let at = offset + (length - head.len()) as u64;
                        deltas.push(inflate_at(pack, at, size)?);
                        continue 'chain;
                    }
                    _ => return None,
                }
            }
        };
        for delta in deltas.iter().rev() {
            bytes = apply(&bytes, delta, limit)?;
        }
        Some((kind, bytes))
    }

    fn commit_tree(&self, commit: Oid) -> Option<Oid> {
        let (kind, bytes) = self.read(commit, MAX_INFLATED)?;
        let line = bytes.strip_prefix(b"tree ")?.get(..40)?;
        (kind == 1).then(|| parse_oid(std::str::from_utf8(line).ok()?))?
    }

    /// Adds the files of `tree` that are under `folder`, by path, and the
    /// folders whose tree `trees` holds to `same` in place of theirs.
    fn flatten(
        &self,
        tree: Oid,
        folder: &[u8],
        trees: &HashMap<Vec<u8>, Oid>,
        files: &mut HashMap<Vec<u8>, (u32, Oid)>,
        same: &mut HashSet<Vec<u8>>,
    ) -> Option<()> {
        let mut entries = 0;
        let mut open = vec![(tree, Vec::new())];
        while let Some((tree, base)) = open.pop() {
            let (kind, bytes) = self.read(tree, MAX_INFLATED)?;
            if kind != 2 {
                return None;
            }
            let mut rest = &bytes[..];
            while !rest.is_empty() {
                entries += 1;
                if entries > MAX_TREE_ENTRIES {
                    return None;
                }
                let space = rest.iter().position(|&byte| byte == b' ')?;
                let mode =
                    u32::from_str_radix(std::str::from_utf8(&rest[..space]).ok()?, 8).ok()?;
                let nul = space + rest[space..].iter().position(|&byte| byte == 0)?;
                let path = join(&base, &rest[space + 1..nul]);
                let id = Oid(rest.get(nul + 1..nul + 21)?.try_into().ok()?);
                rest = &rest[nul + 21..];
                if mode == TREE {
                    if trees.get(&path) == Some(&id) {
                        same.insert(path);
                    } else if within(&path, folder) || within(folder, &path) {
                        open.push((id, path));
                    }
                } else if within(&path, folder) {
                    files.insert(path, (mode, id));
                }
            }
        }
        Some(())
    }
}

/// A loose object's type and bytes, if it has at most `limit`.
fn loose_object(compressed: &[u8], limit: u64) -> Option<(u8, Vec<u8>)> {
    let mut bytes = Vec::new();
    ZlibDecoder::new(compressed)
        .take(limit + 64)
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
    (size == bytes.len()).then_some((kind, bytes))
}

impl Pack {
    /// The offset of `id`, from the index: a 256-entry fanout of counts, the
    /// sorted ids, their CRCs, 31-bit offsets, then 64-bit ones.
    fn find(&self, id: Oid) -> Option<u64> {
        let read = |at: u64, bytes: &mut [u8]| self.idx.read_exact_at(bytes, at).ok();
        let word = |at: u64| {
            let mut bytes = [0u8; 4];
            read(at, &mut bytes)?;
            Some(u64::from(u32::from_be_bytes(bytes)))
        };
        let first = u64::from(id.0[0]);
        let count = word(8 + 4 * 255)?;
        let mut low = if first == 0 {
            0
        } else {
            word(8 + 4 * (first - 1))?
        };
        let mut high = word(8 + 4 * first)?.min(count);
        let ids = 8 + 4 * 256;
        let mut candidate = [0u8; 20];
        while low < high {
            let middle = (low + high) / 2;
            read(ids + 20 * middle, &mut candidate)?;
            match candidate.cmp(&id.0) {
                std::cmp::Ordering::Less => low = middle + 1,
                std::cmp::Ordering::Greater => high = middle,
                std::cmp::Ordering::Equal => {
                    let offsets = ids + 24 * count;
                    let offset = word(offsets + 4 * middle)?;
                    if offset & 0x8000_0000 == 0 {
                        return Some(offset);
                    }
                    let mut large = [0u8; 8];
                    read(offsets + 4 * count + 8 * (offset & 0x7fff_ffff), &mut large)?;
                    return Some(u64::from_be_bytes(large));
                }
            }
        }
        None
    }
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
/// base and inserts. Nothing when the result would pass `limit` bytes.
fn apply(base: &[u8], delta: &[u8], limit: u64) -> Option<Vec<u8>> {
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
    if length > limit.min(MAX_INDEX) {
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

/// A work tree's ignore rules, as git reads them: each folder's .gitignore,
/// then info/exclude, then the file `core.excludesFile` names. Each
/// .gitignore is read the first time a path under its folder is asked about.
pub struct Ignores {
    top: PathBuf,
    /// The patterns that apply from the top: `core.excludesFile`'s, then
    /// info/exclude's, which win.
    base: Vec<Pattern>,
    /// Each folder's .gitignore, by its path from the top.
    folders: HashMap<Vec<u8>, Vec<Pattern>>,
}

impl Ignores {
    /// The rules of the repository that holds `folder`, a realpath, and the
    /// folder's path from its top; or, in no repository, the rules of the
    /// folder's own .gitignore files.
    pub fn of(folder: &Path) -> (Ignores, Vec<u8>) {
        let Some(repo) = Repo::find(&folder.join(".git")) else {
            return (Ignores::new(folder, None), Vec::new());
        };
        let prefix = folder
            .strip_prefix(&repo.top)
            .map_or(Vec::new(), |prefix| prefix.as_os_str().as_bytes().to_vec());
        let common = common(&repo.gitdir);
        (Ignores::new(&repo.top, Some(&common)), prefix)
    }

    fn new(top: &Path, common: Option<&Path>) -> Ignores {
        let mut base = Vec::new();
        if let Some(common) = common {
            for path in excludes_file(top, common)
                .into_iter()
                .chain([common.join("info/exclude")])
            {
                if let Ok(bytes) = read_file(&path, MAX_INDEX) {
                    base.extend(patterns(&bytes));
                }
            }
        }
        Ignores {
            top: top.to_path_buf(),
            base,
            folders: HashMap::new(),
        }
    }

    /// Whether git ignores `path`, from the top: it or a folder above it
    /// matches.
    pub fn ignored(&mut self, path: &[u8], folder: bool) -> bool {
        path.iter()
            .enumerate()
            .filter(|(_, byte)| **byte == b'/')
            .any(|(at, _)| self.matches(&path[..at], true))
            || self.matches(path, folder)
    }

    /// Whether `path` itself matches. The last pattern to match decides,
    /// deeper ignore files first.
    fn matches(&mut self, path: &[u8], folder: bool) -> bool {
        let name = path.rsplit(|&byte| byte == b'/').next().unwrap_or(path);
        let mut parent = &path[..path.len() - name.len()];
        loop {
            parent = parent.strip_suffix(b"/").unwrap_or(parent);
            if !self.folders.contains_key(parent) {
                let file = self.top.join(OsStr::from_bytes(parent)).join(".gitignore");
                let found =
                    read_file(&file, MAX_INDEX).map_or(Vec::new(), |bytes| patterns(&bytes));
                self.folders.insert(parent.to_vec(), found);
            }
            let relative = if parent.is_empty() {
                path
            } else {
                &path[parent.len() + 1..]
            };
            if let Some(matched) = decide(&self.folders[parent], relative, name, folder) {
                return matched;
            }
            if parent.is_empty() {
                return decide(&self.base, path, name, folder).unwrap_or(false);
            }
            let at = parent
                .iter()
                .rposition(|&byte| byte == b'/')
                .map_or(0, |at| at + 1);
            parent = &parent[..at];
        }
    }
}

/// Whether the last of `patterns` that matches ignores the path, if one
/// does. `relative` is the path from the ignore file's folder.
fn decide(patterns: &[Pattern], relative: &[u8], name: &[u8], folder: bool) -> Option<bool> {
    patterns.iter().rev().find_map(|pattern| {
        let text = if pattern.anchored { relative } else { name };
        (!(pattern.folders_only && !folder) && wildmatch(&pattern.glob, text))
            .then_some(!pattern.negated)
    })
}

/// The walk for untracked files.
struct Walk<'a> {
    top: &'a Path,
    indexed: &'a HashSet<&'a [u8]>,
    tracked_folders: &'a HashSet<&'a [u8]>,
    ignores: Ignores,
    files: &'a mut BTreeMap<Vec<u8>, Status>,
}

impl Walk<'_> {
    fn ignored(&mut self, path: &[u8], folder: bool) -> bool {
        self.ignores.matches(path, folder)
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
    }

    /// Whether an untracked folder holds a file no ignore file matches. A
    /// repository inside counts as one.
    fn holds_untracked(&mut self, folder: &[u8]) -> bool {
        let top = self.top.join(OsStr::from_bytes(folder));
        if fs::symlink_metadata(top.join(".git")).is_ok() {
            return true;
        }
        self.list(folder).into_iter().any(|(path, is_folder)| {
            !self.ignored(&path, is_folder) && (!is_folder || self.holds_untracked(&path))
        })
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
        let found = statuses(&root);
        assert_eq!(found, expected);
        let paths: Vec<_> = found.into_iter().map(|(path, _)| path).collect();
        assert_eq!(paths, git_paths(&root, ""));
        assert_eq!(status(&root).unwrap().gitdir, root.join(".git"));

        // A rename into a folder from outside it is still a rename.
        assert_eq!(
            statuses(&root.join("new")),
            [
                ("guide.md".to_owned(), Renamed),
                ("name.md".to_owned(), Renamed)
            ]
        );

        // The sidebar's matcher reads the same ignore files.
        let (mut ignores, prefix) = Ignores::of(&root.join("docs"));
        assert_eq!(prefix, b"docs");
        for (path, ignored) in [
            ("docs/env.local", true),
            ("docs/nested/t.tmp", true),
            ("docs/drafts/d.md", true),
            ("docs/new.md", false),
            ("build/out.txt", true),
            ("keep.log", false),
            ("x.log", true),
            ("secret.md", true),
        ] {
            assert_eq!(ignores.ignored(path.as_bytes(), false), ignored, "{path}");
        }

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
    fn settings_and_filters_match_git_status() {
        // Git LFS's clean filter, without git-lfs.
        const LFS_CLEAN: &str = r#"f=$(mktemp) && cat >"$f" && printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize %s\n' "$(shasum -a 256 <"$f" | cut -c1-64)" "$(wc -c <"$f" | tr -d ' ')" && rm "$f""#;
        let (_dir, root) = repo(&[]);
        git(&root, &["config", "core.fileMode", "false"]);
        git(&root, &["config", "core.autocrlf", "true"]);
        git(&root, &["config", "filter.lfs.clean", LFS_CLEAN]);
        for (name, bytes) in [
            (".gitattributes", &b"*.bin filter=lfs\n"[..]),
            ("exec.sh", b"echo\n"),
            ("crlf.md", b"one\r\ntwo\r\n"),
            ("edited.md", b"one\r\ntwo\r\n"),
            ("big.bin", b"large\n"),
            ("other.bin", b"other\n"),
        ] {
            write(&root, name, bytes);
        }
        git(&root, &["add", "-A"]);
        git(&root, &["commit", "-q", "-m", "base"]);
        assert!(git(&root, &["cat-file", "-p", ":big.bin"]).starts_with("version "));

        // Rewritten with the same bytes, so only their content tells.
        fs::set_permissions(root.join("exec.sh"), fs::Permissions::from_mode(0o755)).unwrap();
        write(&root, "crlf.md", b"one\r\ntwo\r\n");
        write(&root, "edited.md", b"one\r\nTWO\r\n");
        write(&root, "big.bin", b"large\n");
        write(&root, "other.bin", b"changed\n");

        let found = statuses(&root);
        assert_eq!(
            found,
            [
                ("edited.md".to_owned(), Status::Modified),
                ("other.bin".to_owned(), Status::Modified)
            ]
        );
        let paths: Vec<_> = found.into_iter().map(|(path, _)| path).collect();
        assert_eq!(paths, git_paths(&root, ""));

        // SHA-256 ids don't fit this reader: no state rather than wrong ones.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        git(&root, &["init", "-q", "--object-format=sha256"]);
        write(&root, "a.md", b"a\n");
        git(&root, &["add", "-A"]);
        assert_eq!(status(&root), None);
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
