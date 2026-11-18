use std::fs::{File, OpenOptions};
use std::io::{self, Read};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use regex::{Regex, RegexBuilder};

use crate::file;
use crate::jail::{Jail, JailError};
use crate::text::Opened;

/// Files over this many bytes are skipped.
const MAX_FILE: u64 = 64 << 20;
/// Characters a preview keeps before its match.
const BEFORE: usize = 12;
/// Characters a preview keeps in all, unless its match is longer.
const PREVIEW: usize = 160;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Options {
    pub match_case: bool,
    pub whole_word: bool,
    pub regex: bool,
}

/// Offsets are UTF-16 code units: `start..end` in the file's text after any
/// byte-order mark, `preview_start..preview_end` in `preview`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Match {
    /// Counted from 1. A line ends at "\n", "\r\n" or "\r".
    pub line: u32,
    pub start: u32,
    pub end: u32,
    /// The line around the match, with "…" where it was cut.
    pub preview: String,
    pub preview_start: u32,
    pub preview_end: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileMatches {
    /// The file's index in the paths searched.
    pub file: usize,
    pub matches: Vec<Match>,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Found {
    /// The files with a match, in the order searched.
    pub files: Vec<FileMatches>,
    /// The search stopped at its limit with matches left.
    pub stopped: bool,
}

/// What a search looks for: plain text, or a regular expression with
/// `regex`.
pub struct Query {
    /// The text, folded unless the case must match, or the pattern's source.
    text: String,
    pattern: Option<Regex>,
    options: Options,
}

impl Query {
    /// Without `match_case` letters match in any case, so "STRASSE" finds
    /// "Straße". With `whole_word` a match starts and ends at word
    /// boundaries; Han and kana characters are words on their own, since those
    /// scripts don't space their words. A match never spans lines, so text with
    /// a line break matches nothing. Err says why a pattern doesn't compile.
    pub fn new(query: &str, options: Options) -> Result<Self, String> {
        let pattern = options
            .regex
            .then(|| {
                RegexBuilder::new(query)
                    .case_insensitive(!options.match_case)
                    .build()
            })
            .transpose()
            .map_err(|error| error.to_string())?;
        let text = if options.match_case || options.regex {
            query.to_owned()
        } else {
            fold(query)
        };
        Ok(Self {
            text,
            pattern,
            options,
        })
    }

    /// Calls `each` with the number, byte offset and text of the line of each
    /// match, then the match's byte range in the line, until `each` returns
    /// false. Returns whether it did. A pattern's empty matches are skipped.
    fn each(
        &self,
        text: &str,
        mut each: impl FnMut(usize, usize, &str, usize, usize) -> bool,
    ) -> bool {
        if self.text.is_empty() || self.pattern.is_none() && self.text.contains(['\n', '\r']) {
            return false;
        }
        let whole =
            |line: &str, start, end| !self.options.whole_word || whole_word(line, start, end);
        let mut folded = Folded::default();
        for (number, offset, line) in lines(text) {
            if let Some(pattern) = &self.pattern {
                for found in pattern.find_iter(line) {
                    let (start, end) = (found.start(), found.end());
                    if start < end
                        && whole(line, start, end)
                        && !each(number, offset, line, start, end)
                    {
                        return true;
                    }
                }
                continue;
            }
            let haystack = if self.options.match_case {
                line
            } else {
                folded.fill(line);
                &folded.text
            };
            let mut from = 0;
            while let Some(at) = haystack[from..].find(&self.text) {
                let at = from + at;
                let after = at + self.text.len();
                let range = if self.options.match_case {
                    Some((at, after))
                } else {
                    folded.source(at, after)
                };
                let Some((start, end)) = range.filter(|&(start, end)| whole(line, start, end))
                else {
                    from = at + haystack[at..].chars().next().map_or(1, char::len_utf8);
                    continue;
                };
                if !each(number, offset, line, start, end) {
                    return true;
                }
                from = after;
            }
        }
        false
    }
}

/// Searches `paths` in order for `query`, and stops after `limit` matches.
/// Files over 64 MB, files that aren't UTF-8 and files that can't be read are
/// skipped.
pub fn search<P: AsRef<Path>>(paths: &[P], query: &Query, limit: usize) -> Found {
    let mut found = Found::default();
    let mut left = limit;
    for (file, path) in paths.iter().enumerate() {
        let Some(Opened::Utf8 { text, .. }) = read(path.as_ref()).map(Opened::new) else {
            continue;
        };
        let (matches, more) = find(&text, query, left);
        left -= matches.len();
        if !matches.is_empty() {
            found.files.push(FileMatches { file, matches });
        }
        if more {
            found.stopped = true;
            break;
        }
    }
    found
}

/// `text` with each match of `query` replaced by `with`, and how many there
/// were. For a pattern, `$1` or `${name}` in `with` stands for what a group
/// matched and `$$` for a dollar sign.
pub fn replace(text: &str, query: &Query, with: &str) -> (String, usize) {
    let mut out = String::with_capacity(text.len());
    let mut done = 0;
    let mut count = 0;
    query.each(text, |_, offset, line, start, end| {
        out.push_str(&text[done..offset + start]);
        match query
            .pattern
            .as_ref()
            .and_then(|pattern| pattern.captures_at(line, start))
        {
            Some(groups) => groups.expand(with, &mut out),
            None => out.push_str(with),
        }
        done = offset + end;
        count += 1;
        true
    });
    out.push_str(&text[done..]);
    (out, count)
}

/// Why a replace in a file wrote nothing.
#[derive(Debug)]
pub enum ReplaceError {
    /// The file resolves outside the folder.
    Outside,
    /// The file changed after it was read.
    Conflict,
    Io(io::Error),
}

/// Replaces each match of `query` in the file at `path` with `with`, as
/// `replace` does, and returns how many there were. Only a file that resolves
/// inside `root` is read and written, opened from the root with no symlink on
/// the way, and it is written only while it still holds what was read. A file
/// `search` skips is left alone.
pub fn replace_in_file(
    root: &Path,
    path: &Path,
    query: &Query,
    with: &str,
) -> Result<usize, ReplaceError> {
    let jail = Jail::new(root).map_err(ReplaceError::Io)?;
    let (opened, relative) = jail.open(path).map_err(|error| match error {
        JailError::Io(error) => ReplaceError::Io(error),
        JailError::Outside | JailError::Root(_) => ReplaceError::Outside,
    })?;
    let Some(bytes) = read_file(opened) else {
        return Ok(0);
    };
    let base = file::hash(&bytes);
    let Opened::Utf8 { bom, text } = Opened::new(bytes) else {
        return Ok(0);
    };
    let (text, count) = replace(&text, query, with);
    if count > 0 {
        let bytes = Opened::Utf8 { bom, text }.to_bytes();
        file::save(&jail.root().join(relative), &base, &bytes).map_err(|error| match error {
            file::SaveError::Conflict => ReplaceError::Conflict,
            file::SaveError::Io(error) => ReplaceError::Io(error),
        })?;
    }
    Ok(count)
}

/// The file's bytes, or None when it is not a regular file or is over
/// `MAX_FILE`. Opening doesn't wait, so a FIFO named like a note is skipped
/// instead of blocking.
fn read(path: &Path) -> Option<Vec<u8>> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)
        .ok()?;
    read_file(file)
}

fn read_file(file: File) -> Option<Vec<u8>> {
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > MAX_FILE {
        return None;
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(MAX_FILE + 1).read_to_end(&mut bytes).ok()?;
    (bytes.len() as u64 <= MAX_FILE).then_some(bytes)
}

/// The matches of `query` in `text`, at most `limit`, and whether more were
/// left.
fn find(text: &str, query: &Query, limit: usize) -> (Vec<Match>, bool) {
    let mut matches = Vec::new();
    let mut cursor = (0, 0);
    let more = query.each(text, |number, offset, line, start, end| {
        if matches.len() == limit {
            return false;
        }
        let indent = line.len() - line.trim_start_matches([' ', '\t']).len();
        let (preview, preview_start, preview_end) = preview(line, indent, start, end);
        matches.push(Match {
            line: number as u32,
            start: utf16_at(text, &mut cursor, offset + start) as u32,
            end: utf16_at(text, &mut cursor, offset + end) as u32,
            preview,
            preview_start: preview_start as u32,
            preview_end: preview_end as u32,
        });
        true
    });
    (matches, more)
}

/// Each line's number from 1, its byte offset and its text without the line
/// break.
fn lines(text: &str) -> impl Iterator<Item = (usize, usize, &str)> {
    let bytes = text.as_bytes();
    let mut start = 0;
    let mut number = 0;
    std::iter::from_fn(move || {
        if start > text.len() {
            return None;
        }
        let end = bytes[start..]
            .iter()
            .position(|&byte| byte == b'\n' || byte == b'\r')
            .map_or(text.len(), |at| start + at);
        number += 1;
        let line = (number, start, &text[start..end]);
        start = match bytes.get(end) {
            None => end + 1,
            Some(b'\r') if bytes.get(end + 1) == Some(&b'\n') => end + 2,
            Some(_) => end + 1,
        };
        Some(line)
    })
}

/// `c` as case-insensitive matching compares it: lowercase, then upper and
/// lower again, so "ß" and "ẞ" fold to "ss" and "ς" to "σ".
fn fold_into(c: char, out: &mut String) {
    if c.is_ascii() {
        out.push(c.to_ascii_lowercase());
        return;
    }
    for lower in c.to_lowercase() {
        for upper in lower.to_uppercase() {
            out.extend(upper.to_lowercase());
        }
    }
}

fn fold(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        fold_into(c, &mut out);
    }
    out
}

/// A line folded for case-insensitive matching.
#[derive(Default)]
struct Folded {
    text: String,
    /// Where each character's folding starts in `text` and where the
    /// character starts in the line, then both ends. Empty for an ASCII line,
    /// whose offsets are the same in both.
    starts: Vec<(usize, usize)>,
}

impl Folded {
    fn fill(&mut self, line: &str) {
        self.text.clear();
        self.starts.clear();
        if line.is_ascii() {
            self.text.push_str(line);
            self.text.make_ascii_lowercase();
            return;
        }
        for (at, c) in line.char_indices() {
            self.starts.push((self.text.len(), at));
            fold_into(c, &mut self.text);
        }
        self.starts.push((self.text.len(), line.len()));
    }

    /// The line's byte range for `text[start..end]`, or None when either end
    /// falls inside one character's folding.
    fn source(&self, start: usize, end: usize) -> Option<(usize, usize)> {
        if self.starts.is_empty() {
            return Some((start, end));
        }
        let at = |folded| {
            self.starts
                .binary_search_by_key(&folded, |&(folded, _)| folded)
                .ok()
                .map(|index| self.starts[index].1)
        };
        Some((at(start)?, at(end)?))
    }
}

fn whole_word(line: &str, start: usize, end: usize) -> bool {
    let found = &line[start..end];
    boundary(line[..start].chars().next_back(), found.chars().next())
        && boundary(found.chars().next_back(), line[end..].chars().next())
}

/// Whether a word ends between `a` and `b`. A combining accent belongs to
/// the word before it.
fn boundary(a: Option<char>, b: Option<char>) -> bool {
    let word = |c: char| c.is_alphanumeric() || c == '_' || ('\u{300}'..='\u{36F}').contains(&c);
    match (a, b) {
        (Some(a), Some(b)) => !word(a) || !word(b) || unspaced(a) || unspaced(b),
        _ => true,
    }
}

/// Han, hiragana and katakana, whose words have no spaces between them.
fn unspaced(c: char) -> bool {
    matches!(c,
        '\u{3005}'..='\u{3007}'
        | '\u{3040}'..='\u{30FF}'
        | '\u{31F0}'..='\u{31FF}'
        | '\u{3400}'..='\u{4DBF}'
        | '\u{4E00}'..='\u{9FFF}'
        | '\u{F900}'..='\u{FAFF}'
        | '\u{FF66}'..='\u{FF9F}'
        | '\u{20000}'..='\u{323AF}')
}

/// The UTF-16 offset of `byte`, counted on from `cursor`, which moves there.
fn utf16_at(text: &str, cursor: &mut (usize, usize), byte: usize) -> usize {
    let (from, units) = *cursor;
    let units = units + utf16_len(&text[from..byte]);
    *cursor = (byte, units);
    units
}

fn utf16_len(text: &str) -> usize {
    text.chars().map(char::len_utf16).sum()
}

/// The line around `line[start..end]` and the match's UTF-16 range in it:
/// from a word start at most `BEFORE` characters before the match, or the
/// line's first non-blank character, `indent` bytes in, when that is
/// nearer, to `PREVIEW` characters in all.
fn preview(line: &str, indent: usize, start: usize, end: usize) -> (String, usize, usize) {
    let mut from = indent.min(start);
    let window = line[..start]
        .char_indices()
        .rev()
        .nth(BEFORE - 1)
        .map_or(0, |(at, _)| at);
    let cut = window > from;
    if cut {
        from = line[window..start]
            .char_indices()
            .map(|(at, _)| window + at)
            .find(|&at| {
                line[..at].ends_with(char::is_whitespace)
                    && !line[at..].starts_with(char::is_whitespace)
            })
            .unwrap_or(window);
    }
    let room = PREVIEW.saturating_sub(line[from..end].chars().count());
    let to = line[end..]
        .char_indices()
        .nth(room)
        .map_or(line.len(), |(at, _)| end + at);
    let mut preview = String::with_capacity(to - from + 6);
    if cut {
        preview.push('…');
    }
    preview.push_str(&line[from..to]);
    if to < line.len() {
        preview.push('…');
    }
    let preview_start = usize::from(cut) + utf16_len(&line[from..start]);
    (
        preview,
        preview_start,
        preview_start + utf16_len(&line[start..end]),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use std::ffi::CString;
    use std::fs::{self, File};
    use std::os::unix::ffi::OsStrExt;
    use std::path::PathBuf;

    const ANY_CASE: Options = Options {
        match_case: false,
        whole_word: false,
        regex: false,
    };
    const MATCH_CASE: Options = Options {
        match_case: true,
        whole_word: false,
        regex: false,
    };
    const WHOLE_WORD: Options = Options {
        match_case: false,
        whole_word: true,
        regex: false,
    };
    const PATTERN: Options = Options {
        match_case: false,
        whole_word: false,
        regex: true,
    };

    fn find(text: &str, query: &str, options: Options, limit: usize) -> (Vec<Match>, bool) {
        super::find(text, &Query::new(query, options).unwrap(), limit)
    }

    fn search<P: AsRef<Path>>(paths: &[P], query: &str, options: Options, limit: usize) -> Found {
        super::search(paths, &Query::new(query, options).unwrap(), limit)
    }

    fn replaced(text: &str, query: &str, with: &str, options: Options) -> (String, usize) {
        replace(text, &Query::new(query, options).unwrap(), with)
    }

    /// Each match as the text it covers, found through its UTF-16 range.
    fn found(text: &str, query: &str, options: Options) -> Vec<String> {
        let units: Vec<u16> = text.encode_utf16().collect();
        find(text, query, options, usize::MAX)
            .0
            .iter()
            .map(|m| String::from_utf16(&units[m.start as usize..m.end as usize]).unwrap())
            .collect()
    }

    /// Each match's preview with its range in brackets.
    fn previews(text: &str, query: &str) -> Vec<String> {
        find(text, query, MATCH_CASE, usize::MAX)
            .0
            .iter()
            .map(|m| {
                let units: Vec<u16> = m.preview.encode_utf16().collect();
                let part = |range: std::ops::Range<u32>| {
                    String::from_utf16(&units[range.start as usize..range.end as usize]).unwrap()
                };
                format!(
                    "{}[{}]{}",
                    part(0..m.preview_start),
                    part(m.preview_start..m.preview_end),
                    part(m.preview_end..units.len() as u32)
                )
            })
            .collect()
    }

    fn files(contents: &[&[u8]]) -> (tempfile::TempDir, Vec<PathBuf>) {
        let dir = tempfile::tempdir().unwrap();
        let paths = contents
            .iter()
            .enumerate()
            .map(|(index, bytes)| {
                let path = dir.path().join(format!("note {index}.md"));
                fs::write(&path, bytes).unwrap();
                path
            })
            .collect();
        (dir, paths)
    }

    #[test]
    fn patterns_match_within_a_line_in_any_case_unless_case_must_match() {
        let text = "Plan 12\nplan 345 PLAN6";
        assert_eq!(found(text, r"\d+", PATTERN), ["12", "345", "6"]);
        assert_eq!(found(text, "^plan", PATTERN), ["Plan", "plan"]);
        let exact = Options {
            match_case: true,
            ..PATTERN
        };
        assert_eq!(found(text, "plan|PLAN", exact), ["plan", "PLAN"]);
        let whole = Options {
            whole_word: true,
            ..PATTERN
        };
        assert_eq!(found(text, r"plan\d*", whole), ["Plan", "plan", "PLAN6"]);
        // Empty matches are not matches.
        assert_eq!(found(text, "x*", PATTERN), Vec::<String>::new());
        assert!(Query::new("(plan", PATTERN).is_err());
        assert!(Query::new("(plan", ANY_CASE).is_ok());
    }

    #[test]
    fn replacing_keeps_line_breaks_and_expands_groups() {
        assert_eq!(
            replaced("Plan\r\nplan PLAN", "plan", "note", ANY_CASE),
            ("note\r\nnote note".into(), 3)
        );
        assert_eq!(
            replaced(
                "due 2026-11-17, $5",
                r"(\d+)-(\d+)-(\d+)",
                "$3.$2.$1 ($)",
                PATTERN
            ),
            ("due 17.11.2026 ($), $5".into(), 1)
        );
        assert_eq!(
            replaced("Straße", "STRASSE", "Weg", ANY_CASE),
            ("Weg".into(), 1)
        );
        assert_eq!(replaced("plan", "note", "x", ANY_CASE), ("plan".into(), 0));
    }

    #[test]
    fn replacing_in_a_file_keeps_its_byte_order_mark() {
        let (dir, paths) = files(&[b"\xEF\xBB\xBFplan\nplan", b"\xFFplan"]);
        let query = Query::new("plan", ANY_CASE).unwrap();
        assert_eq!(
            replace_in_file(dir.path(), &paths[0], &query, "note").unwrap(),
            2
        );
        assert_eq!(fs::read(&paths[0]).unwrap(), b"\xEF\xBB\xBFnote\nnote");
        // Not UTF-8: left alone.
        assert_eq!(
            replace_in_file(dir.path(), &paths[1], &query, "note").unwrap(),
            0
        );
        assert_eq!(fs::read(&paths[1]).unwrap(), b"\xFFplan");
    }

    #[test]
    fn replacing_never_writes_through_a_link_out_of_the_folder() {
        let base = tempfile::tempdir().unwrap();
        let (root, outside) = (base.path().join("root"), base.path().join("outside"));
        fs::create_dir_all(root.join("notes")).unwrap();
        fs::create_dir_all(&outside).unwrap();
        fs::write(outside.join("secret.md"), "plan").unwrap();
        fs::write(root.join("notes/plan.md"), "plan").unwrap();
        std::os::unix::fs::symlink(outside.join("secret.md"), root.join("secret.md")).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("out")).unwrap();
        std::os::unix::fs::symlink("notes/plan.md", root.join("alias.md")).unwrap();
        let query = Query::new("plan", ANY_CASE).unwrap();
        for path in ["secret.md", "out/secret.md", "../outside/secret.md"] {
            assert!(
                matches!(
                    replace_in_file(&root, &root.join(path), &query, "note"),
                    Err(ReplaceError::Outside)
                ),
                "{path}"
            );
        }
        assert_eq!(fs::read(outside.join("secret.md")).unwrap(), b"plan");
        // A link that stays inside writes the file it names, and leaves the link.
        assert_eq!(
            replace_in_file(&root, &root.join("alias.md"), &query, "note").unwrap(),
            1
        );
        assert_eq!(fs::read(root.join("notes/plan.md")).unwrap(), b"note");
        assert!(
            fs::symlink_metadata(root.join("alias.md"))
                .unwrap()
                .is_symlink()
        );
    }

    #[test]
    fn letters_match_in_any_case_unless_case_must_match() {
        let text = "Café CAFÉ café Ärger ärger ДОМ дом";
        assert_eq!(found(text, "café", ANY_CASE), ["Café", "CAFÉ", "café"]);
        assert_eq!(found(text, "ÄRGER", ANY_CASE), ["Ärger", "ärger"]);
        assert_eq!(found(text, "дом", ANY_CASE), ["ДОМ", "дом"]);
        assert_eq!(found(text, "café", MATCH_CASE), ["café"]);
        assert_eq!(found(text, "cafe", ANY_CASE), Vec::<String>::new());
    }

    #[test]
    fn folding_covers_expansions_and_final_sigma() {
        assert_eq!(
            found("Straße STRASSE", "strasse", ANY_CASE),
            ["Straße", "STRASSE"]
        );
        assert_eq!(found("STRAẞE", "straße", ANY_CASE), ["STRAẞE"]);
        assert_eq!(found("ΟΔΟΣ οδος", "οδοσ", ANY_CASE), ["ΟΔΟΣ", "οδος"]);
        // A match covers whole characters, so "s" is not half of "ß".
        assert_eq!(found("ß", "s", ANY_CASE), Vec::<String>::new());
        assert_eq!(found("ß", "ss", ANY_CASE), ["ß"]);
        // The Kelvin sign folds to k.
        assert_eq!(found("5 \u{212A}", "k", ANY_CASE), ["\u{212A}"]);
    }

    #[test]
    fn folding_twice_changes_nothing() {
        let mut once = String::new();
        let mut twice = String::new();
        for c in (0..=0x10FFFF).filter_map(char::from_u32) {
            once.clear();
            fold_into(c, &mut once);
            twice.clear();
            for folded in once.chars() {
                fold_into(folded, &mut twice);
            }
            assert_eq!(once, twice, "U+{:04X}", c as u32);
        }
    }

    #[test]
    fn whole_words_end_at_punctuation_and_spaces() {
        let text = "plan, (plan) plan's planning _plan plan2 -plan plan.";
        assert_eq!(found(text, "plan", WHOLE_WORD).len(), 5);
        assert_eq!(
            found("planning plans", "plan", WHOLE_WORD),
            Vec::<String>::new()
        );
        // A query that starts or ends with punctuation has its own boundary.
        assert_eq!(found("a-plan", "-plan", WHOLE_WORD), ["-plan"]);
        assert_eq!(found("plan.b", "plan.", WHOLE_WORD), ["plan."]);
        assert_eq!(found("Plan🙂", "plan", WHOLE_WORD), ["Plan"]);
        // "café" spelled with a combining accent is one word.
        let (matches, _) = find("cafe\u{301} cafe", "cafe", WHOLE_WORD, usize::MAX);
        assert_eq!(matches.iter().map(|m| m.start).collect::<Vec<_>>(), [6]);
    }

    #[test]
    fn whole_words_end_at_every_han_and_kana_character() {
        assert_eq!(found("東京都に住む", "東京", WHOLE_WORD), ["東京"]);
        assert_eq!(found("Rust言語で書く", "rust", WHOLE_WORD), ["Rust"]);
        assert_eq!(found("「計画」、計画。", "計画", WHOLE_WORD).len(), 2);
        assert_eq!(found("カタカナとひらがな", "カナ", WHOLE_WORD), ["カナ"]);
        // Hangul spaces its words, so a word runs on through the next syllable.
        assert_eq!(found("서울에 서울", "서울", WHOLE_WORD), ["서울"]);
    }

    #[test]
    fn offsets_count_utf16_units_through_emoji_and_crlf() {
        let text = "🙂 one\r\n👩‍💻 two\rthree\n\ntwo🙂two";
        let (matches, more) = find(text, "two", ANY_CASE, usize::MAX);
        assert!(!more);
        let spans: Vec<_> = matches.iter().map(|m| (m.line, m.start, m.end)).collect();
        // 🙂 is two units; 👩‍💻 is five; "\r\n" is two.
        assert_eq!(spans, [(2, 14, 17), (5, 25, 28), (5, 30, 33)]);
        assert_eq!(found(text, "two", ANY_CASE), ["two", "two", "two"]);
        assert_eq!(matches[0].preview, "👩‍💻 two");
        assert_eq!((matches[0].preview_start, matches[0].preview_end), (6, 9));
    }

    #[test]
    fn a_query_matches_within_one_line() {
        assert_eq!(find("one\ntwo", "one\ntwo", ANY_CASE, 10).0, []);
        assert_eq!(find("one\r\ntwo", "one\r", MATCH_CASE, 10).0, []);
    }

    #[test]
    fn an_empty_query_matches_nothing() {
        assert_eq!(find("anything", "", ANY_CASE, 10), (vec![], false));
        let (_dir, paths) = files(&[b"anything"]);
        assert_eq!(search(&paths, "", WHOLE_WORD, 10), Found::default());
    }

    #[test]
    fn matches_do_not_overlap_but_a_rejected_one_lets_the_next_start_inside_it() {
        assert_eq!(found("aaaa", "aa", ANY_CASE).len(), 2);
        let (matches, _) = find("xa-a-a", "a-a", WHOLE_WORD, usize::MAX);
        assert_eq!(
            matches.iter().map(|m| (m.start, m.end)).collect::<Vec<_>>(),
            [(3, 6)]
        );
    }

    #[test]
    fn long_lines_are_cut_around_the_match() {
        let text = format!(
            "{}the needle here {}",
            "lorem ipsum ".repeat(20),
            "dolor ".repeat(60)
        );
        let [preview] = previews(&text, "needle").try_into().unwrap();
        assert!(
            preview.starts_with("…ipsum the [needle] here dolor"),
            "{preview}"
        );
        assert!(preview.ends_with("dolor …"), "{preview}");
        assert_eq!(preview.chars().count(), PREVIEW + 2 + 2);
        // No space within reach: the cut falls BEFORE characters back.
        let [preview] = previews(&format!("{}needle", "x".repeat(50)), "needle")
            .try_into()
            .unwrap();
        assert_eq!(preview, format!("…{}[needle]", "x".repeat(BEFORE)));
        // A short line keeps everything but its indent.
        assert_eq!(previews("    - the needle", "needle"), ["- the [needle]"]);
        assert_eq!(previews("  needle", "  needle"), ["[  needle]"]);
    }

    #[test]
    fn previews_count_their_ellipsis_and_emoji() {
        let text = format!("{} 🙂🙂 needle", "word ".repeat(10));
        let matches = find(&text, "needle", MATCH_CASE, 1).0;
        let [m] = matches.as_slice() else { panic!() };
        assert!(m.preview.starts_with('…'));
        let units: Vec<u16> = m.preview.encode_utf16().collect();
        assert_eq!(
            String::from_utf16(&units[m.preview_start as usize..m.preview_end as usize]).unwrap(),
            "needle"
        );
    }

    #[test]
    fn files_are_searched_in_order_with_their_bom_left_out() {
        let (_dir, paths) = files(&[b"\xEF\xBB\xBFplan\r\nPlan", b"nothing here", b"PLAN"]);
        let found = search(&paths, "plan", ANY_CASE, 10);
        assert!(!found.stopped);
        let summary: Vec<_> = found
            .files
            .iter()
            .map(|file| {
                (
                    file.file,
                    file.matches
                        .iter()
                        .map(|m| (m.line, m.start))
                        .collect::<Vec<_>>(),
                )
            })
            .collect();
        assert_eq!(summary, [(0, vec![(1, 0), (2, 6)]), (2, vec![(1, 0)])]);
    }

    #[test]
    fn files_that_are_not_utf8_large_or_regular_are_skipped() {
        let (dir, mut paths) = files(&[b"caf\xE9 plan", b"\xEF\xBB\xBF\xFF plan", b"plan"]);
        let large = dir.path().join("large.md");
        let mut file = File::create(&large).unwrap();
        std::io::Write::write_all(&mut file, b"plan").unwrap();
        file.set_len(MAX_FILE + 1).unwrap();
        let fifo = dir.path().join("fifo.md");
        let name = CString::new(fifo.as_os_str().as_bytes()).unwrap();
        // SAFETY: the path outlives the call.
        assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
        paths.extend([
            large,
            fifo,
            dir.path().to_owned(),
            dir.path().join("gone.md"),
        ]);
        let found = search(&paths, "plan", ANY_CASE, 10);
        assert_eq!(
            found.files.iter().map(|file| file.file).collect::<Vec<_>>(),
            [2]
        );
    }

    #[test]
    fn a_file_at_the_size_limit_is_searched() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("big.md");
        let mut file = File::create(&path).unwrap();
        std::io::Write::write_all(&mut file, b"plan").unwrap();
        file.set_len(MAX_FILE).unwrap();
        assert_eq!(search(&[path], "plan", MATCH_CASE, 10).files.len(), 1);
    }

    #[test]
    fn the_limit_stops_the_search_only_when_matches_are_left() {
        let (_dir, paths) = files(&[b"plan plan", b"none", b"plan", b"none"]);
        let count = |found: &Found| found.files.iter().map(|f| f.matches.len()).sum::<usize>();
        let all = search(&paths, "plan", ANY_CASE, 3);
        assert_eq!((count(&all), all.stopped), (3, false));
        let first = search(&paths, "plan", ANY_CASE, 2);
        assert_eq!((count(&first), first.stopped), (2, true));
        assert_eq!(first.files.len(), 1);
        let one = search(&paths, "plan", ANY_CASE, 1);
        assert_eq!((count(&one), one.stopped), (1, true));
        // A limit of zero only asks whether there is a match.
        let none = search(&paths[1..], "plan", ANY_CASE, 0);
        assert_eq!((none.files.len(), none.stopped), (0, true));
        assert!(!search(&paths[3..], "plan", ANY_CASE, 0).stopped);
    }

    #[test]
    fn ten_thousand_matches_stop_the_search() {
        let text = "plan ".repeat(10_001);
        let (_dir, paths) = files(&[text.as_bytes()]);
        let found = search(&paths, "plan", ANY_CASE, 10_000);
        assert_eq!(found.files[0].matches.len(), 10_000);
        assert!(found.stopped);
    }

    proptest! {
        #[test]
        fn every_match_is_the_query_in_the_text_and_its_preview(
            text in "[aAbB🙂é\r\n ]{0,200}",
            query in "[aAbB🙂é ]{1,3}",
            match_case in any::<bool>(),
        ) {
            let options = Options {
                match_case,
                ..Options::default()
            };
            let units: Vec<u16> = text.encode_utf16().collect();
            let (matches, _) = find(&text, &query, options, usize::MAX);
            let expected = if match_case {
                text.matches(&query).count()
            } else {
                fold(&text).matches(&fold(&query)).count()
            };
            prop_assert_eq!(matches.len(), expected);
            for m in matches {
                let found = String::from_utf16(&units[m.start as usize..m.end as usize]).unwrap();
                let preview: Vec<u16> = m.preview.encode_utf16().collect();
                let shown = String::from_utf16(&preview[m.preview_start as usize..m.preview_end as usize]).unwrap();
                prop_assert_eq!(&shown, &found);
                if match_case {
                    prop_assert_eq!(&found, &query);
                } else {
                    prop_assert_eq!(fold(&found), fold(&query));
                }
            }
        }

        #[test]
        fn matches_cover_whole_characters_whose_folding_is_longer(
            text in "[sSßẞİiIﬁf🙂\r\n ]{0,200}",
            query in "[sSßẞİiIﬁf ]{1,3}",
            whole_word in any::<bool>(),
        ) {
            let options = Options {
                whole_word,
                ..Options::default()
            };
            let units: Vec<u16> = text.encode_utf16().collect();
            for m in find(&text, &query, options, usize::MAX).0 {
                let found = String::from_utf16(&units[m.start as usize..m.end as usize]).unwrap();
                prop_assert_eq!(fold(&found), fold(&query));
            }
        }
    }
}
