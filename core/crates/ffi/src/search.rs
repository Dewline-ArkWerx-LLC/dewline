use std::path::Path;

use dewline_core::search;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SearchError {
    /// The pattern doesn't compile.
    #[error("{message}")]
    Pattern { message: String },
    #[error("the file is outside the folder")]
    Outside,
    #[error("the file changed after it was read")]
    Conflict,
    #[error("{message}")]
    Io { message: String },
}

fn query(
    text: &str,
    match_case: bool,
    whole_word: bool,
    regex: bool,
) -> Result<search::Query, SearchError> {
    let options = search::Options {
        match_case,
        whole_word,
        regex,
    };
    search::Query::new(text, options).map_err(|message| SearchError::Pattern { message })
}

/// Offsets are UTF-16 code units: `start..end` in the file's text after any
/// byte-order mark, `preview_start..preview_end` in `preview`.
#[derive(uniffi::Record)]
pub struct SearchMatch {
    /// Counted from 1.
    pub line: u32,
    pub start: u32,
    pub end: u32,
    /// The line around the match, with "…" where it was cut.
    pub preview: String,
    pub preview_start: u32,
    pub preview_end: u32,
}

#[derive(uniffi::Record)]
pub struct SearchFile {
    /// The file's index in the paths searched.
    pub file: u32,
    pub matches: Vec<SearchMatch>,
}

#[derive(uniffi::Record)]
pub struct SearchResults {
    /// The files with a match, in the order searched.
    pub files: Vec<SearchFile>,
    /// The search stopped at its limit with matches left.
    pub stopped: bool,
}

/// Searches `paths` in order for `query`, plain text or with `regex` a
/// regular expression, and stops after `limit` matches. Files over 64 MB,
/// files that aren't UTF-8 and files that can't be read are skipped.
#[uniffi::export]
pub fn search_files(
    paths: Vec<String>,
    query: String,
    match_case: bool,
    whole_word: bool,
    regex: bool,
    limit: u32,
) -> Result<SearchResults, SearchError> {
    let query = self::query(&query, match_case, whole_word, regex)?;
    let found = search::search(&paths, &query, limit as usize);
    Ok(SearchResults {
        files: found
            .files
            .into_iter()
            .map(|file| SearchFile {
                file: file.file as u32,
                matches: file
                    .matches
                    .into_iter()
                    .map(|m| SearchMatch {
                        line: m.line,
                        start: m.start,
                        end: m.end,
                        preview: m.preview,
                        preview_start: m.preview_start,
                        preview_end: m.preview_end,
                    })
                    .collect(),
            })
            .collect(),
        stopped: found.stopped,
    })
}

#[derive(uniffi::Record)]
pub struct Replaced {
    pub text: String,
    pub count: u32,
}

/// `text` with each match of `query` replaced by `with`, where a pattern's
/// `$1` or `${name}` stands for what a group matched.
#[uniffi::export]
pub fn replace_text(
    text: String,
    query: String,
    with: String,
    match_case: bool,
    whole_word: bool,
    regex: bool,
) -> Result<Replaced, SearchError> {
    let query = self::query(&query, match_case, whole_word, regex)?;
    let (text, count) = search::replace(&text, &query, &with);
    Ok(Replaced {
        text,
        count: count as u32,
    })
}

/// Replaces each match of `query` in the file at `path` as `replace_text`
/// does, and returns how many there were. Only a file that resolves inside
/// `root` is written, and only while it still holds what was read.
#[uniffi::export]
pub fn replace_in_file(
    root: String,
    path: String,
    query: String,
    with: String,
    match_case: bool,
    whole_word: bool,
    regex: bool,
) -> Result<u32, SearchError> {
    let query = self::query(&query, match_case, whole_word, regex)?;
    match search::replace_in_file(Path::new(&root), Path::new(&path), &query, &with) {
        Ok(count) => Ok(count as u32),
        Err(search::ReplaceError::Outside) => Err(SearchError::Outside),
        Err(search::ReplaceError::Conflict) => Err(SearchError::Conflict),
        Err(search::ReplaceError::Io(error)) => Err(SearchError::Io {
            message: error.to_string(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_matches_by_file_index() {
        let dir = tempfile::tempdir().unwrap();
        let paths: Vec<String> = ["a.md", "b.md"]
            .iter()
            .map(|name| dir.path().join(name).to_str().unwrap().to_owned())
            .collect();
        std::fs::write(&paths[0], "nothing").unwrap();
        std::fs::write(&paths[1], "# Plan\r\nThe plan").unwrap();
        let results = search_files(paths, "plan".into(), false, true, false, 1).unwrap();
        assert!(results.stopped);
        let [file] = results.files.as_slice() else {
            panic!("one file has matches");
        };
        let [m] = file.matches.as_slice() else {
            panic!("the limit is one match");
        };
        assert_eq!((file.file, m.line, m.start, m.end), (1, 1, 2, 6));
        assert_eq!(
            (m.preview.as_str(), m.preview_start, m.preview_end),
            ("# Plan", 2, 6)
        );
    }
}
