//! Code highlighting for fenced blocks and whole files (record 0008). One worker thread owns syntect's syntaxes and
//! each block's per-line parse states, so an edit reparses a block from its first changed line until the parser is back
//! in the state it had there. Diff and markdown are highlighted here without syntect. Spans come back as token classes
//! in UTF-16 offsets; the app picks the colors. `Syntaxes::html` colors a whole block at once for pages.

use std::collections::HashMap;
use std::fmt::Write;
use std::panic::{self, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use syntect::parsing::{ParseState, Scope, ScopeStack, SyntaxReference, SyntaxSet};

use crate::export::escape;
use crate::md::{self, TokenKind};

/// What a span of code is. The app maps each class to a theme color.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Class {
    Comment = 1,
    String,
    Escape,
    Number,
    Constant,
    Keyword,
    Operator,
    Type,
    Function,
    Tag,
    Attribute,
    Inserted,
    Deleted,
    Heading,
}

/// UTF-16 offsets in the block's text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub start: u32,
    pub end: u32,
    pub class: Class,
}

/// A line with more scope changes than this stays plain: the guard against patterns that split a line into a token
/// per character (the mdmost PR #21 budget).
pub const LINE_TOKENS: usize = 2_000;
/// A line longer than this in UTF-8 bytes is not parsed.
pub const LINE_BYTES: usize = 16_384;
/// A line whose parse takes longer than this stays plain, and so does the rest of its block. The unit tests share the
/// CPU with each other on an unoptimized build, so there it is a second.
pub const LINE_TIME: Duration = Duration::from_millis(if cfg!(test) { 1_000 } else { 30 });
/// The blocks whose line states the worker keeps.
const CACHED_BLOCKS: usize = 256;

/// What a request colors: a fenced block by its info string's first word, or a whole file by its path.
enum Source {
    Fence(String),
    File(String),
}

enum Job {
    Highlight {
        block: u64,
        generation: u64,
        source: Source,
        text: String,
        reply: Sender<Option<Vec<Span>>>,
    },
    Forget(u64),
}

/// The worker's handle. Each call to `highlight` waits for the worker, so the app calls it off the main thread.
pub struct Highlighter {
    jobs: Mutex<Sender<Job>>,
    /// The newest request's generation for each block; an older request still queued or running comes back `None`.
    latest: Arc<Mutex<HashMap<u64, u64>>>,
}

impl Highlighter {
    /// Starts the worker, which loads the syntaxes at `dump` (an uncompressed newline dump) before its first block.
    /// Without them every language but diff and markdown stays plain.
    pub fn new(dump: PathBuf) -> Self {
        let (jobs, inbox) = mpsc::channel();
        let latest = Arc::new(Mutex::new(HashMap::new()));
        let shared = latest.clone();
        std::thread::Builder::new()
            .name("dewline-highlight".into())
            .spawn(move || Worker::new(dump, shared).run(inbox))
            .expect("spawn the highlight worker");
        Self {
            jobs: Mutex::new(jobs),
            latest,
        }
    }

    /// The spans of `text`, a fenced block's content in `language` (its info string's first word), or `None` when a
    /// newer request for `block` or a `forget` overtook this one. `block` is any id the caller keeps for the block:
    /// the worker reuses its line states for the lines that did not change since the last request with that id.
    pub fn highlight(&self, block: u64, language: &str, text: &str) -> Option<Vec<Span>> {
        self.request(block, Source::Fence(language.to_string()), text)
    }

    /// `highlight` for a whole file, `text`, in the syntax its `path` names: by its file name (Makefile), its
    /// extension, or its first line (a `#!` line). Empty for a file without a syntax.
    pub fn highlight_file(&self, block: u64, path: &str, text: &str) -> Option<Vec<Span>> {
        self.request(block, Source::File(path.to_string()), text)
    }

    fn request(&self, block: u64, source: Source, text: &str) -> Option<Vec<Span>> {
        let generation = {
            let mut latest = self.latest.lock().unwrap();
            let next = latest.get(&block).map_or(1, |generation| generation + 1);
            latest.insert(block, next);
            next
        };
        let (reply, answer) = mpsc::channel();
        self.jobs
            .lock()
            .unwrap()
            .send(Job::Highlight {
                block,
                generation,
                source,
                text: text.to_string(),
                reply,
            })
            .ok()?;
        answer.recv().ok().flatten()
    }

    /// Cancels `block`'s requests and drops its line states.
    pub fn forget(&self, block: u64) {
        self.latest.lock().unwrap().remove(&block);
        let _ = self.jobs.lock().unwrap().send(Job::Forget(block));
    }
}

/// The syntaxes in a dump with the scope rules, for coloring whole blocks where no worker is wanted: the Quick Look
/// page and exports.
pub struct Syntaxes {
    set: SyntaxSet,
    rules: Rules,
}

impl Syntaxes {
    /// The syntaxes at `dump`, an uncompressed newline dump such as the app's `Syntaxes.packdump`.
    pub fn load(dump: &Path) -> Option<Self> {
        Some(Self {
            set: syntect::dumps::from_uncompressed_dump_file(dump).ok()?,
            rules: rules(),
        })
    }

    /// `code`, a fenced block's content in `language` (its info string's first word), as the HTML inside its
    /// `<pre><code>`: escaped, each span in a `<span>` with an inline color for a light and a dark page, or `None` for
    /// a language without a syntax. A span's color is the stylesheet's `--codeKeyword` and the like when it sets them,
    /// else the default themes' code colors through `light-dark()`, which follow the page's `color-scheme`.
    pub fn html(&self, language: &str, code: &str) -> Option<String> {
        let spans = match native(language) {
            Some(native) => native(code),
            None => self.spans(find(&self.set, language)?, code),
        };
        // The byte offset of each UTF-16 offset, and of the end.
        let mut bytes: Vec<usize> = code
            .char_indices()
            .flat_map(|(at, c)| std::iter::repeat_n(at, c.len_utf16()))
            .collect();
        bytes.push(code.len());
        let mut out = String::with_capacity(code.len() * 2);
        let mut at = 0;
        for span in spans {
            let (start, end) = (bytes[span.start as usize], bytes[span.end as usize]);
            out.push_str(&escape(&code[at..start]));
            let text = escape(&code[start..end]);
            match color(span.class) {
                Some(color) => {
                    let _ = write!(out, "<span style=\"color:{color}\">{text}</span>");
                }
                None => out.push_str(&text),
            }
            at = end;
        }
        out.push_str(&escape(&code[at..]));
        Some(out)
    }

    /// The spans of `code` in `syntax`, parsed from its first line.
    fn spans(&self, syntax: &SyntaxReference, code: &str) -> Vec<Span> {
        let (mut state, mut scopes) = (ParseState::new(syntax), ScopeStack::new());
        let mut spans = Vec::new();
        let mut at = 0;
        for text in code.split_inclusive('\n') {
            let (line, slow) = self.line(text, &mut state, &mut scopes);
            if slow {
                break;
            }
            spans.extend(line.into_iter().map(|span| Span {
                start: span.start + at,
                end: span.end + at,
                class: span.class,
            }));
            at += text.encode_utf16().count() as u32;
        }
        spans
    }

    /// One line's spans in UTF-16 offsets from its start, parsed on from `state` and `scopes`, and whether it took
    /// longer than `LINE_TIME`, which leaves it plain. A line over `LINE_BYTES` is not parsed.
    fn line(
        &self,
        text: &str,
        state: &mut ParseState,
        scopes: &mut ScopeStack,
    ) -> (Vec<Span>, bool) {
        if text.len() > LINE_BYTES {
            return (Vec::new(), false);
        }
        let started = Instant::now();
        // The syntaxes are built for lines that end in a line break.
        let owned;
        let parsed = if text.ends_with('\n') {
            text
        } else {
            owned = format!("{text}\n");
            &owned
        };
        let mut spans = match state.parse_line(parsed, &self.set) {
            Ok(ops) => classes(&self.rules, text, &ops, scopes),
            Err(_) => Vec::new(),
        };
        let slow = started.elapsed() > LINE_TIME;
        if slow {
            spans.clear();
        }
        (spans, slow)
    }

    /// The syntax for a file: by its name, as for a Makefile, then its extension, then its first line.
    fn for_file(&self, path: &str, text: &str) -> Option<&SyntaxReference> {
        let name = Path::new(path).file_name()?.to_str()?;
        self.set
            .find_syntax_by_extension(name)
            .or_else(|| find(&self.set, extension(path)))
            .or_else(|| self.set.find_syntax_by_first_line(text.lines().next()?))
            .filter(|syntax| visible(syntax))
    }
}

/// The colors a span's class takes on a page, light then dark: the code colors Tidewater and Nightwatch, the default
/// themes, derive in the app (`Theme.coded`). Operators keep the text's color.
fn color(class: Class) -> Option<&'static str> {
    Some(match class {
        Class::Comment => "var(--codeComment,light-dark(#555f5a,#a3a89f))",
        Class::String => "var(--codeString,light-dark(#3b0e00,#fdcffd))",
        Class::Escape | Class::Number | Class::Constant => {
            "var(--codeNumber,light-dark(#00243c,#bff0c1))"
        }
        Class::Keyword => "var(--codeKeyword,light-dark(#002b1c,#a7f3df))",
        Class::Type => "var(--codeType,light-dark(#2e0f37,#adeaff))",
        Class::Function => "var(--codeFunction,light-dark(#0f2600,#ffd2b1))",
        Class::Tag | Class::Attribute => "var(--codeTag,light-dark(#1a211e,#e6e0d3))",
        Class::Inserted => "var(--codeInserted,light-dark(#002907,#bbf0c5))",
        Class::Deleted => "var(--codeDeleted,light-dark(#3d090a,#ffcdc6))",
        Class::Heading => "var(--heading,light-dark(#1a211e,#e6e0d3))",
        Class::Operator => return None,
    })
}

struct Line {
    text: String,
    /// In UTF-16 offsets from the line's start.
    spans: Vec<Span>,
    /// The parser and scopes after the line.
    state: ParseState,
    scopes: ScopeStack,
}

struct Cache {
    syntax: String,
    lines: Vec<Line>,
    used: u64,
}

struct Worker {
    dump: PathBuf,
    syntaxes: Option<Option<Syntaxes>>,
    latest: Arc<Mutex<HashMap<u64, u64>>>,
    blocks: HashMap<u64, Cache>,
    clock: u64,
}

impl Worker {
    fn new(dump: PathBuf, latest: Arc<Mutex<HashMap<u64, u64>>>) -> Self {
        Self {
            dump,
            syntaxes: None,
            latest,
            blocks: HashMap::new(),
            clock: 0,
        }
    }

    fn run(mut self, inbox: Receiver<Job>) {
        for job in inbox {
            match job {
                Job::Forget(block) => {
                    self.blocks.remove(&block);
                }
                Job::Highlight {
                    block,
                    generation,
                    source,
                    text,
                    reply,
                } => {
                    let spans = panic::catch_unwind(AssertUnwindSafe(|| {
                        self.highlight(block, generation, &source, &text)
                    }))
                    .unwrap_or_else(|_| {
                        self.blocks.remove(&block);
                        Some(Vec::new())
                    });
                    let _ = reply.send(spans);
                }
            }
        }
    }

    fn current(&self, block: u64, generation: u64) -> bool {
        self.latest.lock().unwrap().get(&block) == Some(&generation)
    }

    fn highlight(
        &mut self,
        block: u64,
        generation: u64,
        source: &Source,
        text: &str,
    ) -> Option<Vec<Span>> {
        if !self.current(block, generation) {
            return None;
        }
        let word = match source {
            Source::Fence(language) => language.as_str(),
            Source::File(path) => extension(path),
        };
        if let Some(native) = native(word) {
            return Some(native(text));
        }
        if self.syntaxes.is_none() {
            self.syntaxes = Some(Syntaxes::load(&self.dump));
        }
        let Some(syntaxes) = self.syntaxes.as_ref().unwrap() else {
            return Some(Vec::new());
        };
        let syntax = match source {
            Source::Fence(language) => find(&syntaxes.set, language),
            Source::File(path) => syntaxes.for_file(path, text),
        };
        let Some(syntax) = syntax else {
            return Some(Vec::new());
        };
        self.clock += 1;
        let mut cache = self
            .blocks
            .remove(&block)
            .filter(|cache| cache.syntax == syntax.name)
            .unwrap_or_else(|| Cache {
                syntax: syntax.name.clone(),
                lines: Vec::new(),
                used: 0,
            });
        cache.used = self.clock;
        let new: Vec<&str> = text.split_inclusive('\n').collect();
        let mut old = std::mem::take(&mut cache.lines);
        let kept = old
            .iter()
            .zip(&new)
            .take_while(|(line, text)| line.text == **text)
            .count();
        // The lines after the edit, which the old text ends with too, and the state the old text entered them in.
        let same = old[kept..]
            .iter()
            .rev()
            .zip(new[kept..].iter().rev())
            .take_while(|(line, text)| line.text == **text)
            .count();
        let mut tail = old.split_off(old.len() - same);
        let entered = old
            .last()
            .map(|line| (line.state.clone(), line.scopes.clone()));
        old.truncate(kept);
        cache.lines = old;
        let mut stalled = false;
        for (at, text) in new.iter().enumerate().skip(kept) {
            if !self.current(block, generation) {
                return None;
            }
            let (mut state, mut scopes) = cache.lines.last().map_or_else(
                || (ParseState::new(syntax), ScopeStack::new()),
                |line| (line.state.clone(), line.scopes.clone()),
            );
            if let Some(index) = at.checked_sub(new.len() - same)
                && !stalled
            {
                let before = match index {
                    0 => entered.as_ref().map(|(state, scopes)| (state, scopes)),
                    _ => Some((&tail[index - 1].state, &tail[index - 1].scopes)),
                };
                let back = match before {
                    Some((before, outer)) => *before == state && *outer == scopes,
                    None => cache.lines.is_empty(),
                };
                if back {
                    // The parser is back where the old text had it, so the old lines from here still hold.
                    cache.lines.extend(tail.drain(index..));
                    break;
                }
            }
            let mut spans = Vec::new();
            if !stalled {
                (spans, stalled) = syntaxes.line(text, &mut state, &mut scopes);
            }
            cache.lines.push(Line {
                text: text.to_string(),
                spans,
                state,
                scopes,
            });
        }
        let mut spans = Vec::new();
        let mut at = 0;
        for line in &cache.lines {
            spans.extend(line.spans.iter().map(|span| Span {
                start: span.start + at,
                end: span.end + at,
                class: span.class,
            }));
            at += line.text.encode_utf16().count() as u32;
        }
        if stalled {
            // A slow line leaves the rest plain; the next request starts over at it rather than reuse plain lines.
            cache.lines.truncate(kept);
        }
        if self.blocks.len() >= CACHED_BLOCKS {
            let oldest = self
                .blocks
                .iter()
                .min_by_key(|(_, cache)| cache.used)
                .map(|(block, _)| *block);
            oldest.map(|block| self.blocks.remove(&block));
        }
        self.blocks.insert(block, cache);
        Some(spans)
    }
}

/// The highlighter for diff and markdown, which need no syntax, by a fence's word or a file's extension.
fn native(word: &str) -> Option<fn(&str) -> Vec<Span>> {
    match word.to_ascii_lowercase().as_str() {
        "diff" | "patch" | "udiff" => Some(diff),
        "md" | "markdown" | "mdown" | "mkd" | "pandoc" => Some(markdown),
        _ => None,
    }
}

/// A path's extension, or "" without one.
fn extension(path: &str) -> &str {
    Path::new(path)
        .extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or("")
}

fn visible(syntax: &SyntaxReference) -> bool {
    !syntax.hidden && syntax.name != "Unnamed"
}

/// The syntax for a fence's language as GitHub reads it: a Linguist name or alias, then a syntax's extension or name.
fn find<'a>(set: &'a SyntaxSet, language: &str) -> Option<&'a SyntaxReference> {
    // An info string's first word as GitHub reads it: ` ```rust,ignore ` and ` ```{python} ` too.
    let language = language
        .split(',')
        .next()
        .unwrap_or_default()
        .trim_matches(['{', '}', '.'])
        .to_ascii_lowercase();
    // Linguist's names and aliases for the languages in the dump that the syntaxes' own extensions and names miss,
    // mapped to an extension that finds the right one.
    let token = match language.as_str() {
        "shell" | "shell-script" | "zsh" | "ksh" | "envrc" | "console" | "shellsession"
        | "sh-session" => "bash",
        "javascript" | "node" => "js",
        "csharp" | "cake" | "cakescript" => "cs",
        "golang" => "go",
        "python3" | "rusthon" => "py",
        "h" => "c",
        "jruby" | "macruby" | "rake" | "rbx" => "rb",
        "rscript" | "splus" => "r",
        "cperl" => "pl",
        "fsharp" => "fs",
        "octave" => "matlab",
        "obj-c" | "objc" | "objectivec" => "m",
        "obj-c++" | "objc++" | "objectivec++" => "mm",
        "posh" | "pwsh" => "ps1",
        "jsonc" | "json5" | "jsonl" | "geojson" | "topojson" | "sarif" => "json",
        "docker" | "containerfile" => "dockerfile",
        "bsdmake" | "mf" => "make",
        "opentofu" | "tofu" => "tf",
        "nixos" => "nix",
        "assembly" | "s" => "asm",
        "nginxconf" | "vhost" => "nginx",
        "conf" | "dosini" => "ini",
        "regex" | "regexp" => "re",
        "wsdl" | "xsd" | "rss" | "plist" => "xml",
        other => other,
    };
    if token.is_empty() {
        return None;
    }
    set.find_syntax_by_token(token)
        .filter(|syntax| visible(syntax))
}

/// Scope prefixes and their classes, most specific first; a token's class is the first match for its innermost scope
/// that has one. A string inside a mapping's key reads as an attribute.
struct Rules {
    classes: Vec<(Scope, Class)>,
    keys: Vec<Scope>,
}

fn rules() -> Rules {
    let classes = [
        ("comment", Class::Comment),
        ("constant.character.escape", Class::Escape),
        ("string", Class::String),
        ("constant.numeric", Class::Number),
        ("constant", Class::Constant),
        ("support.constant", Class::Constant),
        ("variable.language", Class::Keyword),
        ("keyword.operator", Class::Operator),
        ("keyword", Class::Keyword),
        ("storage", Class::Keyword),
        ("entity.name.function", Class::Function),
        ("support.function", Class::Function),
        ("variable.function", Class::Function),
        ("entity.name.tag", Class::Tag),
        ("entity.other.attribute-name", Class::Attribute),
        ("support.type.property-name", Class::Attribute),
        ("entity.name", Class::Type),
        ("entity.other.inherited-class", Class::Type),
        ("support.type", Class::Type),
        ("support.class", Class::Type),
        ("markup.inserted", Class::Inserted),
        ("markup.deleted", Class::Deleted),
        ("markup.heading", Class::Heading),
    ];
    let scope = |name: &str| Scope::new(name).unwrap();
    Rules {
        classes: classes
            .into_iter()
            .map(|(name, class)| (scope(name), class))
            .collect(),
        keys: vec![
            scope("meta.mapping.key"),
            scope("meta.structure.dictionary.key"),
        ],
    }
}

fn class(rules: &Rules, scopes: &ScopeStack) -> Option<Class> {
    let stack = scopes.as_slice();
    let found = stack.iter().rev().find_map(|scope| {
        rules
            .classes
            .iter()
            .find(|(rule, _)| rule.is_prefix_of(*scope))
            .map(|(_, class)| *class)
    });
    if found == Some(Class::String)
        && stack
            .iter()
            .any(|scope| rules.keys.iter().any(|key| key.is_prefix_of(*scope)))
    {
        return Some(Class::Attribute);
    }
    found
}

/// Applies a line's scope changes to `scopes` and returns the line's spans in UTF-16 offsets from its start, or none
/// when the line has more than `LINE_TOKENS` changes.
fn classes(
    rules: &Rules,
    line: &str,
    ops: &[(usize, syntect::parsing::ScopeStackOp)],
    scopes: &mut ScopeStack,
) -> Vec<Span> {
    if ops.len() > LINE_TOKENS {
        for (_, op) in ops {
            let _ = scopes.apply(op);
        }
        return Vec::new();
    }
    let bare = line.trim_end_matches(['\n', '\r']).len();
    let mut spans: Vec<Span> = Vec::new();
    // The byte the last span ended at and its UTF-16 offset, so the line's offsets convert once.
    let mut cursor = (0, 0);
    let mut push = |from: usize, to: usize, class: Option<Class>| {
        let to = to.min(bare);
        let (Some(class), true) = (class, from < to) else {
            return;
        };
        let mut units = |byte: usize| {
            cursor = (
                byte,
                cursor.1 + line[cursor.0..byte].encode_utf16().count() as u32,
            );
            cursor.1
        };
        let (start, end) = (units(from), units(to));
        match spans.last_mut() {
            Some(last) if last.class == class && last.end == start => last.end = end,
            _ => spans.push(Span { start, end, class }),
        }
    };
    let mut at = 0;
    for (offset, op) in ops {
        let offset = (*offset).min(line.len());
        push(at, offset, class(rules, scopes));
        at = offset;
        let _ = scopes.apply(op);
    }
    push(at, line.len(), class(rules, scopes));
    spans
}

/// A unified diff's lines: file and hunk headers, insertions and deletions.
fn diff(text: &str) -> Vec<Span> {
    let mut spans = Vec::new();
    let mut at = 0;
    for line in text.split_inclusive('\n') {
        let length = line.encode_utf16().count() as u32;
        let bare = line.trim_end_matches(['\n', '\r']).encode_utf16().count() as u32;
        let class = if ["+++", "---", "@@", "diff ", "index "]
            .iter()
            .any(|head| line.starts_with(head))
        {
            Some(Class::Heading)
        } else if line.starts_with('+') {
            Some(Class::Inserted)
        } else if line.starts_with('-') {
            Some(Class::Deleted)
        } else {
            None
        };
        if let (Some(class), true) = (class, bare > 0) {
            spans.push(Span {
                start: at,
                end: at + bare,
                class,
            });
        }
        at += length;
    }
    spans
}

/// Markdown through `core::md`: each token's markers and content, inner tokens over outer ones.
fn markdown(text: &str) -> Vec<Span> {
    let parse = md::parse(text);
    let mut painted: Vec<Option<Class>> = vec![None; text.encode_utf16().count()];
    let mut paint = |from: u32, to: u32, class: Option<Class>| {
        if let Some(class) = class {
            painted[from as usize..to as usize].fill(Some(class));
        }
    };
    for token in &parse.tokens {
        let (markers, content) = match token.kind {
            TokenKind::Heading { .. } => (Some(Class::Heading), Some(Class::Heading)),
            TokenKind::InlineCode | TokenKind::FencedCode => {
                (Some(Class::Operator), Some(Class::String))
            }
            TokenKind::Link | TokenKind::Image | TokenKind::WikiLink | TokenKind::Embed => {
                (Some(Class::Operator), Some(Class::Function))
            }
            TokenKind::Callout => (Some(Class::Keyword), Some(Class::Keyword)),
            TokenKind::FootnoteReference
            | TokenKind::FootnoteDefinition
            | TokenKind::Definition => (Some(Class::Attribute), Some(Class::Attribute)),
            TokenKind::InlineMath | TokenKind::DisplayMath => {
                (Some(Class::Operator), Some(Class::Number))
            }
            TokenKind::Comment | TokenKind::FrontMatter => {
                (Some(Class::Comment), Some(Class::Comment))
            }
            TokenKind::Tag => (Some(Class::Constant), Some(Class::Constant)),
            TokenKind::Html => (Some(Class::Tag), Some(Class::Tag)),
            TokenKind::TableHead | TokenKind::TableRow | TokenKind::TableCell => (None, None),
            _ => (Some(Class::Operator), None),
        };
        paint(token.start, token.content_start, markers);
        paint(token.content_end, token.end, markers);
        paint(token.content_start, token.content_end, content);
    }
    let mut spans: Vec<Span> = Vec::new();
    for (index, class) in painted.into_iter().enumerate() {
        let Some(class) = class else { continue };
        let index = index as u32;
        match spans.last_mut() {
            Some(last) if last.class == class && last.end == index => last.end += 1,
            _ => spans.push(Span {
                start: index,
                end: index + 1,
                class,
            }),
        }
    }
    spans
}

#[cfg(test)]
mod tests {
    use super::*;

    fn highlighter() -> Highlighter {
        Highlighter::new(PathBuf::from(DUMP))
    }

    /// The text of each span with its class.
    fn read(text: &str, spans: &[Span]) -> Vec<(String, Class)> {
        let units: Vec<u16> = text.encode_utf16().collect();
        spans
            .iter()
            .map(|span| {
                (
                    String::from_utf16(&units[span.start as usize..span.end as usize]).unwrap(),
                    span.class,
                )
            })
            .collect()
    }

    fn has(found: &[(String, Class)], text: &str, class: Class) -> bool {
        found
            .iter()
            .any(|(span, found)| span == text && *found == class)
    }

    #[test]
    fn rust() {
        let text = "// sum\nfn add(a: u32) -> u32 {\n    let s = \"é\\n\";\n    a + 42\n}\n";
        let found = read(text, &highlighter().highlight(1, "rust", text).unwrap());
        assert!(has(&found, "// sum", Class::Comment), "{found:?}");
        assert!(has(&found, "fn", Class::Keyword), "{found:?}");
        assert!(has(&found, "add", Class::Function), "{found:?}");
        assert!(has(&found, "\\n", Class::Escape), "{found:?}");
        assert!(has(&found, "42", Class::Number), "{found:?}");
        assert!(
            found
                .iter()
                .any(|(span, class)| span.contains('é') && *class == Class::String),
            "{found:?}"
        );
    }

    #[test]
    fn python() {
        let text = "def greet(name):\n    # hi\n    return f\"hi {name}\" if name else None\n";
        let found = read(text, &highlighter().highlight(1, "py", text).unwrap());
        assert!(has(&found, "def", Class::Keyword), "{found:?}");
        assert!(has(&found, "greet", Class::Function), "{found:?}");
        assert!(has(&found, "# hi", Class::Comment), "{found:?}");
        assert!(has(&found, "None", Class::Constant), "{found:?}");
    }

    #[test]
    fn json() {
        let text = "{\"name\": \"dewline\", \"size\": 1.5, \"open\": true}";
        let found = read(text, &highlighter().highlight(1, "json", text).unwrap());
        assert!(has(&found, "\"name\"", Class::Attribute), "{found:?}");
        assert!(has(&found, "\"dewline\"", Class::String), "{found:?}");
        assert!(has(&found, "1.5", Class::Number), "{found:?}");
        assert!(has(&found, "true", Class::Constant), "{found:?}");
    }

    #[test]
    fn an_edit_reparses_from_its_line() {
        let highlighter = highlighter();
        let before = "let a = 1;\nlet b = 2;\n";
        let after = "let a = 1;\nlet b = \"2\";\n";
        let first = highlighter.highlight(7, "rs", before).unwrap();
        let second = read(after, &highlighter.highlight(7, "rs", after).unwrap());
        assert_eq!(read(before, &first)[..2], second[..2]);
        assert!(has(&second, "\"2\"", Class::String), "{second:?}");
    }

    #[test]
    fn a_line_over_the_token_budget_stays_plain() {
        let numbers = vec!["1"; LINE_TOKENS].join(",");
        let text = format!("[1]\n[{numbers}]\n[2]\n");
        let started = Instant::now();
        let found = read(&text, &highlighter().highlight(1, "json", &text).unwrap());
        assert!(
            has(&found, "1", Class::Number) && has(&found, "2", Class::Number),
            "{found:?}"
        );
        assert_eq!(
            found
                .iter()
                .filter(|(_, class)| *class == Class::Number)
                .count(),
            2,
            "{:?}",
            started.elapsed()
        );
    }

    const DUMP: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../app/Dewline/Syntaxes.packdump"
    );

    /// Lines that leave contexts open or nested, among them `x /*`, on which syntect 5.3.0 loops forever in two contexts
    /// that `set` each other without consuming (trishume/syntect#706), as older JavaScript syntaxes do.
    const PATHOLOGICAL: &[&str] = &[
        "x /*",
        "/*",
        "*/ */",
        "\"",
        "'",
        "`",
        "${",
        "#{",
        "@{",
        "%{",
        "{{",
        "}}",
        "<!--",
        "<<EOF",
        "<<-'EOF'",
        "\"\"\"",
        "'''",
        "(*",
        "{-",
        "--[[",
        "[[",
        "]]",
        "<?php",
        "?>",
        "<script>",
        "<style>",
        "\\",
        "r#\"",
        "@\"",
        "$(",
        "$((",
        "#!",
        "%>",
        "<%",
        "(?<",
        "[^",
        "\\\\\\",
        "/\\/",
        "=begin",
        "\"\\",
        "x = \"a\\",
        "</",
    ];

    /// Every syntax in the dump, hidden ones too, returns on each pathological line from a fresh state and on all of
    /// them in a row. One thread takes the syntaxes in turn, so the other tests' 30 ms line guard keeps its meaning.
    #[test]
    fn every_syntax_returns_on_pathological_lines() {
        let set: SyntaxSet = syntect::dumps::from_uncompressed_dump_file(DUMP).unwrap();
        let names: Vec<String> = set
            .syntaxes()
            .iter()
            .map(|syntax| syntax.name.clone())
            .collect();
        let nested: Vec<String> = ["(", "{", "[", "<", "\"", "/*", "${"]
            .iter()
            .map(|open| open.repeat(400))
            .collect();
        let (sent, received) = mpsc::channel();
        std::thread::spawn(move || {
            for syntax in set.syntaxes() {
                let mut together = ParseState::new(syntax);
                for line in PATHOLOGICAL
                    .iter()
                    .copied()
                    .chain(nested.iter().map(String::as_str))
                {
                    let line = format!("{line}\n");
                    let _ = ParseState::new(syntax).parse_line(&line, &set);
                    let _ = together.parse_line(&line, &set);
                }
                let _ = sent.send(());
            }
        });
        for name in &names {
            assert!(
                received.recv_timeout(Duration::from_secs(10)).is_ok(),
                "{name} never returned"
            );
        }
    }

    /// A short, typical snippet for each fence language, by a word people write for it.
    const SNIPPETS: &[(&str, &str)] = &[
        ("bash", "# c\necho \"hi $USER\" && exit 1\n"),
        (
            "c",
            "#include <stdio.h>\nint main(void) { return 0; } // c\n",
        ),
        (
            "csharp",
            "// c\npublic class A { string s = \"x\"; int n = 1; }\n",
        ),
        (
            "cpp",
            "#include <vector>\nint main() { auto x = 1; return x; } // c\n",
        ),
        (
            "cmake",
            "# c\ncmake_minimum_required(VERSION 3.20)\nproject(demo LANGUAGES C)\n",
        ),
        ("css", "/* c */\n.a > #b { color: #fff; margin: 0 1px; }\n"),
        ("clojure", "; c\n(defn add [a b] (+ a b 42))\n"),
        ("dart", "// c\nvoid main() { var s = 'x'; print(s); }\n"),
        ("dockerfile", "# c\nFROM alpine:3.20\nRUN echo \"hi\"\n"),
        (
            "elixir",
            "# c\ndefmodule A do\n  def f(x), do: x + 1\nend\n",
        ),
        ("erlang", "% c\n-module(a).\nf(X) -> X + 1.\n"),
        (
            "fsharp",
            "// c\nlet add x y = x + y + 1\nprintfn \"%d\" (add 1 2)\n",
        ),
        ("fish", "# c\nfunction greet\n    echo \"hi $argv\"\nend\n"),
        (
            "go",
            "// c\npackage main\nfunc main() { s := \"x\"; _ = s }\n",
        ),
        (
            "graphql",
            "# c\nquery Hero($id: ID!) { hero(id: $id) { name } }\n",
        ),
        (
            "groovy",
            "// c\ndef greet(name) { println \"hi ${name}\"; return 1 }\n",
        ),
        ("html", "<!-- c -->\n<a href=\"#\">x</a>\n"),
        ("haskell", "-- c\nmain :: IO ()\nmain = putStrLn \"hi\"\n"),
        ("ini", "; c\n[section]\nkey = value\n"),
        ("json", "{\"a\": 1, \"b\": \"x\"}\n"),
        (
            "java",
            "// c\npublic class A { static int f() { return 1; } }\n",
        ),
        ("javascript", "// c\nconst f = (a) => `x${a}` + 1;\n"),
        ("julia", "# c\nfunction f(x)\n    return x + 1\nend\n"),
        ("kotlin", "// c\nfun main() { val s = \"x\"; println(s) }\n"),
        (
            "latex",
            "% c\n\\begin{document}\nHello $x^2$\n\\end{document}\n",
        ),
        (
            "lua",
            "-- c\nlocal function f(x) return x + 1 end\nprint(\"hi\")\n",
        ),
        ("matlab", "% c\nfunction y = f(x)\n  y = x + 1;\nend\n"),
        ("makefile", "# c\nall: main.o\n\t$(CC) -o app main.o\n"),
        ("nix", "# c\n{ pkgs ? import <nixpkgs> {} }: pkgs.hello\n"),
        ("ocaml", "(* c *)\nlet add x y = x + y + 1\n"),
        ("objc", "// c\n@interface A : NSObject\n- (int)f;\n@end\n"),
        (
            "objc++",
            "// c\n#import <Foundation/Foundation.h>\nint main() { return 0; }\n",
        ),
        ("php", "<?php\n// c\necho \"hi\" . 1;\n"),
        ("perl", "# c\nmy $x = \"hi\";\nprint $x . 1;\n"),
        (
            "powershell",
            "# c\nfunction Get-A { param($x) Write-Output \"hi $x\" }\n",
        ),
        (
            "protobuf",
            "// c\nsyntax = \"proto3\";\nmessage A { int32 id = 1; }\n",
        ),
        ("python", "# c\ndef f(x):\n    return x + 1\n"),
        ("r", "# c\nf <- function(x) { x + 1 }\nprint(\"hi\")\n"),
        ("regex", "^(?:[a-z]+|\\d{2,})$\n"),
        ("ruby", "# c\ndef f(x)\n  \"hi #{x}\"\nend\n"),
        ("rust", "// c\nfn main() { let s = \"x\"; }\n"),
        ("scss", "// c\n$x: 1px;\n.a { .b { margin: $x; } }\n"),
        ("sql", "-- c\nSELECT a, 1 FROM t WHERE b = 'x';\n"),
        ("sass", "// c\n$x: 1px\n.a\n  margin: $x\n"),
        ("scala", "// c\nobject A { def f(x: Int): Int = x + 1 }\n"),
        (
            "swift",
            "// c\nfunc f(_ x: Int) -> String { return \"\\(x)\" }\n",
        ),
        ("toml", "# c\n[package]\nname = \"x\"\nversion = 1\n"),
        (
            "hcl",
            "# c\nresource \"aws_s3_bucket\" \"b\" {\n  bucket = \"x\"\n}\n",
        ),
        (
            "typescript",
            "// c\nconst f = (a: number): string => `${a}`;\n",
        ),
        ("typst", "// c\n= Title\n#let x = 1 + 2\n"),
        (
            "tsx",
            "// c\nconst A = () => <div className=\"x\">{1}</div>;\n",
        ),
        (
            "xml",
            "<?xml version=\"1.0\"?>\n<!-- c -->\n<a b=\"x\">y</a>\n",
        ),
        ("yaml", "# c\nkey: value\nlist: [1, 2]\n"),
        (
            "zig",
            "// c\nconst std = @import(\"std\");\npub fn main() void {}\n",
        ),
        (
            "nginx",
            "# c\nserver {\n    listen 80;\n    server_name example.com;\n}\n",
        ),
        ("asm", "; c\nsection .text\nmov rax, 60\nsyscall\n"),
        ("diff", "@@ -1 +1 @@\n-a\n+b\n"),
        ("markdown", "# Title\n\nSee `code`.\n"),
    ];

    #[test]
    fn a_snippet_in_every_language_gets_more_than_one_class() {
        let highlighter = highlighter();
        let plain: Vec<(&str, Vec<(String, Class)>)> = SNIPPETS
            .iter()
            .enumerate()
            .filter_map(|(block, (language, text))| {
                let found = read(
                    text,
                    &highlighter.highlight(block as u64, language, text).unwrap(),
                );
                let classes: std::collections::HashSet<Class> =
                    found.iter().map(|(_, class)| *class).collect();
                (classes.len() < 2).then_some((*language, found))
            })
            .collect();
        assert!(plain.is_empty(), "{plain:#?}");
    }

    /// The fence words GitHub Linguist knows for these languages find the syntax it means.
    #[test]
    fn fence_words_find_their_syntax() {
        let set: SyntaxSet = syntect::dumps::from_uncompressed_dump_file(DUMP).unwrap();
        let wanted = [
            ("csharp", "C#"),
            ("cs", "C#"),
            ("c#", "C#"),
            ("objc", "Objective-C"),
            ("objective-c", "Objective-C"),
            ("objectivec", "Objective-C"),
            ("objc++", "Objective-C++"),
            ("mm", "Objective-C++"),
            ("fs", "F#"),
            ("fsharp", "F#"),
            ("f#", "F#"),
            ("h", "C"),
            ("m", "Objective-C"),
            ("octave", "MATLAB"),
            ("js", "JavaScript (Babel)"),
            ("javascript", "JavaScript (Babel)"),
            ("jsx", "JavaScript (Babel)"),
            ("mjs", "JavaScript (Babel)"),
            ("node", "JavaScript (Babel)"),
            ("ts", "TypeScript"),
            ("tsx", "TypeScriptReact"),
            ("py3", "Python"),
            ("python3", "Python"),
            ("shell", "Bourne Again Shell (bash)"),
            ("zsh", "Bourne Again Shell (bash)"),
            ("console", "Bourne Again Shell (bash)"),
            ("sh", "Bourne Again Shell (bash)"),
            ("golang", "Go"),
            ("c++", "C++"),
            ("pwsh", "PowerShell"),
            ("ps1", "PowerShell"),
            ("docker", "Dockerfile"),
            ("containerfile", "Dockerfile"),
            ("make", "Makefile"),
            ("mk", "Makefile"),
            ("proto", "Protocol Buffer"),
            ("protobuf", "Protocol Buffer"),
            ("hcl", "Terraform"),
            ("terraform", "Terraform"),
            ("tf", "Terraform"),
            ("tex", "LaTeX"),
            ("latex", "LaTeX"),
            ("typ", "Typst"),
            ("asm", "x86_64 Assembly"),
            ("nasm", "x86_64 Assembly"),
            ("conf", "INI"),
            ("ini", "INI"),
            ("nginx", "nginx"),
            ("regex", "Regular Expression"),
            ("jsonc", "JSON"),
            ("json5", "JSON"),
            ("yml", "YAML"),
            ("plist", "XML"),
            ("gql", "GraphQL"),
            ("rb", "Ruby"),
            ("kts", "Kotlin"),
            ("exs", "Elixir"),
            ("rscript", "R"),
            ("jl", "Julia"),
            ("cmake", "CMake"),
            ("rust,ignore", "Rust"),
            ("{python}", "Python"),
        ];
        let wrong: Vec<(&str, &str, Option<&str>)> = wanted
            .iter()
            .map(|(word, name)| {
                (
                    *word,
                    *name,
                    find(&set, word).map(|syntax| syntax.name.as_str()),
                )
            })
            .filter(|(_, name, found)| *found != Some(name))
            .collect();
        assert!(wrong.is_empty(), "{wrong:?}");
    }

    #[test]
    fn an_edit_stops_reparsing_once_the_parser_is_back() {
        let highlighter = highlighter();
        let body: String = (0..2_000).map(|n| format!("x{n} = {n}\n")).collect();
        let before = format!("a = 1\n{body}");
        highlighter.highlight(9, "py", &before).unwrap();
        let after = format!("a = 2\n{body}");
        let spans = read(&after, &highlighter.highlight(9, "py", &after).unwrap());
        let fresh = read(&after, &highlighter.highlight(10, "py", &after).unwrap());
        assert_eq!(spans, fresh);
        // Only the edited line is parsed again: every other line keeps a mark put in its cached spans.
        let mut worker = Worker::new(
            PathBuf::from(DUMP),
            Arc::new(Mutex::new(HashMap::from([(9, 1)]))),
        );
        let python = Source::Fence("py".into());
        worker.highlight(9, 1, &python, &before).unwrap();
        let mark = vec![Span {
            start: 0,
            end: 0,
            class: Class::Heading,
        }];
        for line in &mut worker.blocks.get_mut(&9).unwrap().lines {
            line.spans = mark.clone();
        }
        worker.highlight(9, 1, &python, &after).unwrap();
        let lines = &worker.blocks[&9].lines;
        assert_eq!(lines.len(), 2_001);
        assert_eq!(lines.iter().filter(|line| line.spans != mark).count(), 1);
        // An edit that opens a string changes every line after it, and closing it changes them back.
        let opened = format!("a = \"\"\"\n{body}");
        let spans = read(&opened, &highlighter.highlight(9, "py", &opened).unwrap());
        assert!(
            has(&spans, "x1999 = 1999", Class::String),
            "{:?}",
            &spans[spans.len() - 1..]
        );
        let spans = read(&after, &highlighter.highlight(9, "py", &after).unwrap());
        assert_eq!(spans, fresh);
    }

    #[test]
    fn inserted_and_deleted_lines_keep_the_lines_after_them() {
        let highlighter = highlighter();
        let text = "fn a() {}\n// note\nfn b() {}\n";
        highlighter.highlight(11, "rust", text).unwrap();
        for edited in [
            "fn a() {}\nlet s = \"x\";\n// note\nfn b() {}\n",
            "// note\nfn b() {}\n",
            "/* open\n// note\nfn b() {}\n",
            "fn b() {}\n",
        ] {
            let found = read(edited, &highlighter.highlight(11, "rust", edited).unwrap());
            assert_eq!(
                found,
                read(edited, &highlighter.highlight(12, "rust", edited).unwrap()),
                "{edited}"
            );
        }
    }

    #[test]
    fn a_file_finds_its_syntax_by_its_path() {
        let highlighter = highlighter();
        let found = |path: &str, text: &str| {
            read(text, &highlighter.highlight_file(1, path, text).unwrap())
        };
        assert!(has(
            &found("/x/main.rs", "fn main() {}\n"),
            "fn",
            Class::Keyword
        ));
        assert!(has(
            &found("/x/Makefile", "all:\n\techo hi # c\n"),
            "# c",
            Class::Comment
        ));
        assert!(has(
            &found("/x/Dockerfile", "FROM alpine\n"),
            "FROM",
            Class::Keyword
        ));
        assert!(has(
            &found("/x/run", "#!/bin/bash\necho \"hi\"\n"),
            "\"hi\"",
            Class::String
        ));
        assert!(has(&found("/x/a.patch", "+new\n"), "+new", Class::Inserted));
        assert!(found("/x/notes.txt", "plain\n").is_empty());
    }

    #[test]
    fn html_colors_spans_inline_for_light_and_dark() {
        let syntaxes = Syntaxes::load(Path::new(DUMP)).unwrap();
        let html = syntaxes.html("rust", "// é <b>\nlet s = \"&\";\n").unwrap();
        assert!(
            html.starts_with("<span style=\"color:var(--codeComment,light-dark(#555f5a,#a3a89f))\">// é &lt;b&gt;</span>\n"),
            "{html}"
        );
        assert!(html.contains("&quot;&amp;&quot;</span>"), "{html}");
        assert_eq!(syntaxes.html("klingon", "x < y"), None);
        assert!(
            syntaxes
                .html("diff", "+a\n")
                .unwrap()
                .contains("codeInserted")
        );
    }

    #[test]
    fn an_unknown_language_has_no_spans() {
        let highlighter = highlighter();
        assert_eq!(
            highlighter.highlight(1, "klingon", "qapla'\n"),
            Some(Vec::new())
        );
        assert_eq!(highlighter.highlight(2, "", "plain\n"), Some(Vec::new()));
    }

    #[test]
    fn diff_and_markdown_are_native() {
        let text = "@@ -1 +1 @@\n-old\n+new\n same\n";
        let found = read(text, &highlighter().highlight(1, "diff", text).unwrap());
        assert_eq!(
            found,
            [
                ("@@ -1 +1 @@".into(), Class::Heading),
                ("-old".into(), Class::Deleted),
                ("+new".into(), Class::Inserted)
            ]
        );
        let text = "# Title\n\nSee `code`.\n";
        let found = read(text, &highlighter().highlight(1, "markdown", text).unwrap());
        assert!(
            has(&found, "# Title", Class::Heading) && has(&found, "code", Class::String),
            "{found:?}"
        );
    }

    #[test]
    fn a_newer_request_cancels_an_older_one() {
        let highlighter = Arc::new(highlighter());
        let text: String = (0..20_000).map(|n| format!("let x{n} = {n};\n")).collect();
        let older = {
            let (highlighter, text) = (highlighter.clone(), text.clone());
            std::thread::spawn(move || highlighter.highlight(3, "rust", &text))
        };
        std::thread::sleep(Duration::from_millis(20));
        assert!(highlighter.highlight(3, "rust", "let y = 1;\n").is_some());
        assert_eq!(older.join().unwrap(), None);
    }
}
