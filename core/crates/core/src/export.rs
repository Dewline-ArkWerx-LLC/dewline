//! Markdown to one standalone HTML page. Raw HTML in the source is shown as text, never passed through.

pub mod docx;
pub mod epub;
pub mod latex;
pub mod portable;
pub mod text;

use std::collections::HashMap;
use std::fmt::Write;
use std::io::Read;
use std::path::{Component, Path};

use pulldown_cmark::{
    Alignment, CodeBlockKind, Event, HeadingLevel, LinkType, MetadataBlockKind, Options, Parser,
    Tag, TagEnd,
};

use crate::jail::Jail;

/// What the page needs beyond the markdown.
pub struct ExportOptions<'a> {
    pub title: &'a str,
    /// The theme's stylesheet, inlined in the head.
    pub css: &'a str,
    /// A Mermaid source as inline SVG, or `None` to show the source.
    pub diagram: &'a dyn Fn(&str) -> Option<String>,
    /// TeX as inline HTML, display math when the flag is set, or `None` to show the source.
    pub math: &'a dyn Fn(&str, bool) -> Option<String>,
    /// A fenced block's code in its info string's first word as highlighted HTML, as `highlight::Syntaxes::html`
    /// writes it, or `None` to show it plain.
    pub code: &'a dyn Fn(&str, &str) -> Option<String>,
    /// The document's folder: images inside it are inlined as data URLs, all others keep their paths.
    pub folder: Option<&'a Path>,
}

/// The largest image file inlined.
const MAX_IMAGE: u64 = 20 << 20;

/// Scripts never run; styles and images come only from the page itself and data URLs.
pub const CSP: &str = "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:";

pub(crate) const OPTIONS: Options =
    crate::md::OPTIONS.union(Options::ENABLE_YAML_STYLE_METADATA_BLOCKS);

/// A page titled by its front matter's `title`, else `options.title`, in its `lang`, else English.
pub fn html(text: &str, options: &ExportOptions<'_>) -> String {
    let front = front_matter(text);
    let field = |key: &str| {
        front.lines().find_map(|line| {
            let value = line.strip_prefix(key)?.strip_prefix(':')?.trim();
            let value = value.trim_matches(['"', '\'']);
            (!value.is_empty()).then_some(value)
        })
    };
    let mut out = String::with_capacity(text.len() * 2);
    let _ = write!(
        out,
        "<!DOCTYPE html>\n<html lang=\"{}\">\n<head>\n<meta charset=\"utf-8\">\n\
         <meta http-equiv=\"Content-Security-Policy\" content=\"{CSP}\">\n\
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n\
         <title>{}</title>\n<style>\n{}\n</style>\n</head>\n<body>\n",
        escape(field("lang").unwrap_or("en")),
        escape(field("title").unwrap_or(options.title)),
        options.css.replace("</", "<\\/"),
    );
    Writer {
        out: &mut out,
        options,
        footnotes: HashMap::new(),
        anchors: HashMap::new(),
        columns: Vec::new(),
        column: 0,
        head: false,
    }
    .run(Parser::new_ext(text, OPTIONS));
    out.push_str("</body>\n</html>\n");
    out
}

/// The YAML front matter that opens `text`, or "".
fn front_matter(text: &str) -> String {
    let mut events = Parser::new_ext(text, OPTIONS);
    match events.next() {
        Some(Event::Start(Tag::MetadataBlock(MetadataBlockKind::YamlStyle))) => code(&mut events),
        _ => String::new(),
    }
}

/// A heading's anchor as GitHub writes it: lowercase, letters, digits, `-` and `_` kept, spaces as `-`.
pub(crate) fn slug(heading: &str) -> String {
    heading
        .to_lowercase()
        .chars()
        .filter_map(|c| match c {
            ' ' => Some('-'),
            c if c.is_alphanumeric() || c == '-' || c == '_' => Some(c),
            _ => None,
        })
        .collect()
}

/// `path` with every byte but ASCII letters, digits and `-._~/` percent-encoded.
pub(crate) fn encode(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    for &byte in path.as_bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~/".contains(&byte) {
            out.push(byte as char);
        } else {
            let _ = write!(out, "%{byte:02X}");
        }
    }
    out
}

pub(crate) fn percent_decoded(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            index += 3;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// The folder beside an export named `name` that holds its images and diagrams: the name with every character but
/// ASCII letters, digits and `-` as `-`, then `-files`, a path LaTeX and Markdown renderers take as written.
pub fn files_folder(name: &str) -> String {
    let name: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' {
                c
            } else {
                '-'
            }
        })
        .collect();
    format!("{name}-files")
}

/// `text` with the five HTML-significant characters as entities.
pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
    out
}

/// A link's target, unescaped, unless its scheme can run code: an email autolink as a `mailto:` URL and a wikilink as
/// its note's exported page, `Note.html#section`.
pub(crate) fn link_target(kind: LinkType, target: &str) -> Option<String> {
    match kind {
        LinkType::Email => Some(format!("mailto:{target}")),
        LinkType::WikiLink { .. } => {
            let (note, section) = target.split_once('#').unwrap_or((target, ""));
            let note = note.strip_suffix(".md").unwrap_or(note);
            let page = if note.is_empty() {
                String::new()
            } else {
                encode(note) + ".html"
            };
            let fragment = if section.is_empty() {
                String::new()
            } else {
                format!("#{}", slug(section))
            };
            Some(page + &fragment)
        }
        _ => safe(target).then(|| target.to_owned()),
    }
}

/// A link target, unless its scheme can run code: relative paths, fragments and web, mail and data-image URLs.
fn url(target: &str) -> Option<String> {
    safe(target).then(|| escape(target))
}

fn safe(target: &str) -> bool {
    match target.find([':', '/', '?', '#']) {
        Some(at) if target[at..].starts_with(':') => {
            let scheme = target[..at].to_ascii_lowercase();
            matches!(scheme.as_str(), "http" | "https" | "mailto")
                || target[at + 1..].starts_with("image/") && scheme == "data"
        }
        _ => true,
    }
}

/// A data URL of the image `read_image` finds, its path percent-decoded.
fn inline_image(folder: &Path, path: &str) -> Option<String> {
    let path = percent_decoded(path).unwrap_or_else(|| path.to_owned());
    let (mime, bytes) = read_image(folder, &path)?;
    Some(format!("data:{mime};base64,{}", base64(&bytes)))
}

/// The media type and bytes of the image at `path` relative to `folder`: a relative path without `..` that resolves,
/// symlinks followed, to a regular file inside the folder, at most `MAX_IMAGE` bytes, whose bytes are PNG, JPEG, GIF,
/// WebP or SVG.
fn read_image(folder: &Path, path: &str) -> Option<(&'static str, Vec<u8>)> {
    let relative = Path::new(path);
    if path.contains(':')
        || !relative
            .components()
            .all(|part| matches!(part, Component::Normal(_) | Component::CurDir))
    {
        return None;
    }
    let (file, target) = Jail::new(folder).ok()?.open(relative).ok()?;
    let info = file.metadata().ok()?;
    if !info.is_file() || info.len() > MAX_IMAGE {
        return None;
    }
    let mut bytes = Vec::with_capacity(info.len() as usize);
    file.take(MAX_IMAGE + 1).read_to_end(&mut bytes).ok()?;
    let head = &bytes[..bytes.len().min(1024)];
    let mime = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        "image/png"
    } else if bytes.starts_with(b"\xff\xd8\xff") {
        "image/jpeg"
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        "image/gif"
    } else if bytes.len() > 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        "image/webp"
    } else if target
        .extension()
        .is_some_and(|extension| extension.eq_ignore_ascii_case("svg"))
        && head.windows(4).any(|window| window == b"<svg")
    {
        "image/svg+xml"
    } else {
        return None;
    };
    (bytes.len() as u64 <= MAX_IMAGE).then_some((mime, bytes))
}

pub fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |n, (i, &b)| n | u32::from(b) << (16 - 8 * i));
        for i in 0..4 {
            out.push(if i <= chunk.len() {
                ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char
            } else {
                '='
            });
        }
    }
    out
}

struct Writer<'o, 'a> {
    out: &'o mut String,
    options: &'o ExportOptions<'a>,
    /// Footnote labels by the number they show, in order of first mention.
    footnotes: HashMap<String, usize>,
    /// How many headings took each anchor so far.
    anchors: HashMap<String, usize>,
    columns: Vec<Alignment>,
    column: usize,
    head: bool,
}

impl Writer<'_, '_> {
    fn footnote(&mut self, label: &str) -> usize {
        let next = self.footnotes.len() + 1;
        *self.footnotes.entry(label.to_owned()).or_insert(next)
    }

    /// The anchor of a heading reading `text`: its slug, with `-1`, `-2` and so on after the first use.
    fn anchor(&mut self, text: &str) -> String {
        let slug = match slug(text) {
            slug if slug.is_empty() => "heading".to_owned(),
            slug => slug,
        };
        let used = self.anchors.entry(slug.clone()).or_default();
        *used += 1;
        match *used {
            1 => slug,
            n => format!("{slug}-{}", n - 1),
        }
    }

    fn run<'t>(&mut self, events: impl Iterator<Item = Event<'t>>) {
        let mut events = events;
        while let Some(event) = events.next() {
            match event {
                Event::Start(Tag::Heading { level, .. }) => {
                    let inner: Vec<Event<'t>> = events
                        .by_ref()
                        .take_while(|event| !matches!(event, Event::End(TagEnd::Heading(_))))
                        .collect();
                    let id = self.anchor(&code(&mut inner.iter().cloned()));
                    let _ = write!(self.out, "<{} id=\"{}\">", heading(level), escape(&id));
                    self.run(inner.into_iter());
                    self.end(TagEnd::Heading(level));
                }
                Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(info)))
                    if info.split_whitespace().next() == Some("mermaid") =>
                {
                    let source = code(&mut events);
                    match (self.options.diagram)(&source) {
                        Some(svg) => {
                            let _ = writeln!(self.out, "<figure class=\"diagram\">{svg}</figure>");
                        }
                        None => {
                            let _ = writeln!(
                                self.out,
                                "<pre><code class=\"language-mermaid\">{}</code></pre>",
                                escape(&source)
                            );
                        }
                    }
                }
                Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(info)))
                    if !info.trim().is_empty() =>
                {
                    let language = info.split_whitespace().next().unwrap_or_default();
                    let source = code(&mut events);
                    let inner =
                        (self.options.code)(language, &source).unwrap_or_else(|| escape(&source));
                    let _ = writeln!(
                        self.out,
                        "<pre><code class=\"language-{}\">{inner}</code></pre>",
                        escape(language)
                    );
                }
                Event::Start(Tag::MetadataBlock(_)) => {
                    code(&mut events);
                }
                Event::Start(Tag::Image {
                    link_type,
                    dest_url,
                    title,
                    ..
                }) => {
                    let alt = code(&mut events);
                    let inlined = self
                        .options
                        .folder
                        .and_then(|folder| inline_image(folder, &dest_url));
                    if inlined.is_none()
                        && let LinkType::WikiLink { .. } = link_type
                    {
                        // An embedded note, or an image outside the folder, links to it instead of breaking.
                        if let Some(href) = link_target(link_type, &dest_url) {
                            let _ = write!(
                                self.out,
                                "<a href=\"{}\">{}</a>",
                                escape(&href),
                                escape(&alt)
                            );
                        }
                        continue;
                    }
                    self.out.push_str("<img");
                    if let Some(src) = inlined.or_else(|| url(&dest_url)) {
                        let _ = write!(self.out, " src=\"{src}\"");
                    }
                    let _ = write!(self.out, " alt=\"{}\"", escape(&alt));
                    if !title.is_empty() {
                        let _ = write!(self.out, " title=\"{}\"", escape(&title));
                    }
                    self.out.push('>');
                }
                Event::Start(tag) => self.start(tag),
                Event::End(tag) => self.end(tag),
                Event::Text(text) => self.out.push_str(&escape(&text)),
                Event::Code(text) => {
                    let _ = write!(self.out, "<code>{}</code>", escape(&text));
                }
                Event::InlineMath(tex) => match (self.options.math)(&tex, false) {
                    Some(math) => self.out.push_str(&math),
                    None => {
                        let _ = write!(self.out, "<code class=\"math\">{}</code>", escape(&tex));
                    }
                },
                Event::DisplayMath(tex) => match (self.options.math)(&tex, true) {
                    Some(math) => {
                        let _ = write!(self.out, "<span class=\"math-display\">{math}</span>");
                    }
                    None => {
                        let _ = write!(
                            self.out,
                            "<code class=\"math math-display\">{}</code>",
                            escape(&tex)
                        );
                    }
                },
                Event::Html(html) | Event::InlineHtml(html) => self.out.push_str(&escape(&html)),
                Event::FootnoteReference(label) => {
                    let number = self.footnote(&label);
                    let _ = write!(
                        self.out,
                        "<sup class=\"footnote-reference\"><a href=\"#fn-{}\">{number}</a></sup>",
                        escape(&label)
                    );
                }
                Event::SoftBreak => self.out.push('\n'),
                Event::HardBreak => self.out.push_str("<br>\n"),
                Event::Rule => self.out.push_str("<hr>\n"),
                Event::TaskListMarker(checked) => {
                    let _ = write!(
                        self.out,
                        "<input type=\"checkbox\" disabled{}> ",
                        if checked { " checked" } else { "" }
                    );
                }
            }
        }
    }

    fn start(&mut self, tag: Tag<'_>) {
        match tag {
            Tag::Paragraph => self.out.push_str("<p>"),
            Tag::BlockQuote(_) => self.out.push_str("<blockquote>\n"),
            // A fenced block with a language is written whole in `run`.
            Tag::CodeBlock(_) => self.out.push_str("<pre><code>"),
            Tag::HtmlBlock => self.out.push_str("<pre class=\"html\">"),
            Tag::List(Some(1)) => self.out.push_str("<ol>\n"),
            Tag::List(Some(start)) => {
                let _ = writeln!(self.out, "<ol start=\"{start}\">");
            }
            Tag::List(None) => self.out.push_str("<ul>\n"),
            Tag::Item => self.out.push_str("<li>"),
            Tag::FootnoteDefinition(label) => {
                let number = self.footnote(&label);
                let _ = write!(
                    self.out,
                    "<div class=\"footnote-definition\" id=\"fn-{}\"><sup class=\"footnote-definition-label\">{number}</sup>",
                    escape(&label)
                );
            }
            Tag::DefinitionList => self.out.push_str("<dl>\n"),
            Tag::DefinitionListTitle => self.out.push_str("<dt>"),
            Tag::DefinitionListDefinition => self.out.push_str("<dd>"),
            Tag::Table(columns) => {
                self.columns = columns;
                self.out.push_str("<table>\n");
            }
            Tag::TableHead => {
                self.head = true;
                self.column = 0;
                self.out.push_str("<thead><tr>");
            }
            Tag::TableRow => {
                self.column = 0;
                self.out.push_str("<tr>");
            }
            Tag::TableCell => {
                let cell = if self.head { "th" } else { "td" };
                let align = match self.columns.get(self.column) {
                    Some(Alignment::Left) => " style=\"text-align:left\"",
                    Some(Alignment::Center) => " style=\"text-align:center\"",
                    Some(Alignment::Right) => " style=\"text-align:right\"",
                    _ => "",
                };
                let _ = write!(self.out, "<{cell}{align}>");
            }
            Tag::Emphasis => self.out.push_str("<em>"),
            Tag::Strong => self.out.push_str("<strong>"),
            Tag::Strikethrough => self.out.push_str("<del>"),
            Tag::Superscript => self.out.push_str("<sup>"),
            Tag::Subscript => self.out.push_str("<sub>"),
            Tag::Link {
                link_type,
                dest_url,
                title,
                ..
            } => {
                self.out.push_str("<a");
                if let Some(href) = link_target(link_type, &dest_url) {
                    let href = escape(&href);
                    let _ = write!(self.out, " href=\"{href}\"");
                }
                if !title.is_empty() {
                    let _ = write!(self.out, " title=\"{}\"", escape(&title));
                }
                self.out.push('>');
            }
            Tag::Heading { .. } | Tag::Image { .. } | Tag::MetadataBlock(_) => {}
        }
    }

    fn end(&mut self, tag: TagEnd) {
        let close = match tag {
            TagEnd::Paragraph => "</p>\n",
            TagEnd::Heading(level) => {
                let _ = writeln!(self.out, "</{}>", heading(level));
                return;
            }
            TagEnd::BlockQuote(_) => "</blockquote>\n",
            TagEnd::CodeBlock => "</code></pre>\n",
            TagEnd::HtmlBlock => "</pre>\n",
            TagEnd::List(true) => "</ol>\n",
            TagEnd::List(false) => "</ul>\n",
            TagEnd::Item => "</li>\n",
            TagEnd::FootnoteDefinition => "</div>\n",
            TagEnd::DefinitionList => "</dl>\n",
            TagEnd::DefinitionListTitle => "</dt>\n",
            TagEnd::DefinitionListDefinition => "</dd>\n",
            TagEnd::Table => "</tbody></table>\n",
            TagEnd::TableHead => {
                self.head = false;
                "</tr></thead>\n<tbody>\n"
            }
            TagEnd::TableRow => "</tr>\n",
            TagEnd::TableCell => {
                self.column += 1;
                if self.head { "</th>" } else { "</td>" }
            }
            TagEnd::Emphasis => "</em>",
            TagEnd::Strong => "</strong>",
            TagEnd::Strikethrough => "</del>",
            TagEnd::Superscript => "</sup>",
            TagEnd::Subscript => "</sub>",
            TagEnd::Link => "</a>",
            TagEnd::Image | TagEnd::MetadataBlock(_) => "",
        };
        self.out.push_str(close);
    }
}

fn heading(level: HeadingLevel) -> &'static str {
    match level {
        HeadingLevel::H1 => "h1",
        HeadingLevel::H2 => "h2",
        HeadingLevel::H3 => "h3",
        HeadingLevel::H4 => "h4",
        HeadingLevel::H5 => "h5",
        HeadingLevel::H6 => "h6",
    }
}

/// The text up to the end of the tag just started, with nested markup dropped: a code block's source, an image's alt.
fn code<'t>(events: &mut impl Iterator<Item = Event<'t>>) -> String {
    let mut text = String::new();
    let mut depth = 1;
    for event in events {
        match event {
            Event::Start(_) => depth += 1,
            Event::End(_) => {
                depth -= 1;
                if depth == 0 {
                    break;
                }
            }
            Event::Text(t) | Event::Code(t) | Event::InlineMath(t) | Event::DisplayMath(t) => {
                text.push_str(&t)
            }
            Event::SoftBreak | Event::HardBreak => text.push(' '),
            _ => {}
        }
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn export(text: &str) -> String {
        html(
            text,
            &ExportOptions {
                title: "t",
                css: "",
                diagram: &|_| Some("<svg>diagram</svg>".into()),
                math: &|tex, display| Some(format!("[{display}:{tex}]")),
                code: &|language, code| language.starts_with("rust").then(|| format!("[{code}]")),
                folder: None,
            },
        )
    }

    fn body(page: &str) -> &str {
        &page[page.find("<body>").unwrap()..]
    }

    #[test]
    fn fenced_code_takes_the_highlighters_html() {
        let page =
            export("```rust,ignore\nlet a = 1;\n```\n\n```klingon\n<x>\n```\n\n```\nplain\n```\n");
        assert!(
            page.contains("<pre><code class=\"language-rust,ignore\">[let a = 1;\n]</code></pre>"),
            "{page}"
        );
        assert!(
            page.contains("<pre><code class=\"language-klingon\">&lt;x&gt;\n</code></pre>"),
            "{page}"
        );
        assert!(page.contains("<pre><code>plain\n</code></pre>"), "{page}");
    }

    #[test]
    fn tables_render_with_alignment() {
        let page = export("| a | b |\n|:-|-:|\n| 1 | 2 |\n");
        assert!(page.contains("<thead><tr><th style=\"text-align:left\">a</th><th style=\"text-align:right\">b</th></tr></thead>"), "{page}");
        assert!(
            page.contains(
                "<tr><td style=\"text-align:left\">1</td><td style=\"text-align:right\">2</td></tr>"
            ),
            "{page}"
        );
    }

    #[test]
    fn task_lists_render_as_disabled_boxes() {
        let page = export("- [x] done\n- [ ] todo\n");
        assert!(
            page.contains("<li><input type=\"checkbox\" disabled checked> done</li>"),
            "{page}"
        );
        assert!(
            page.contains("<li><input type=\"checkbox\" disabled> todo</li>"),
            "{page}"
        );
    }

    #[test]
    fn footnotes_number_in_order_of_mention() {
        let page = export("One[^b] two[^a].\n\n[^a]: First.\n[^b]: Second.\n");
        assert!(
            page.contains("<a href=\"#fn-b\">1</a>") && page.contains("<a href=\"#fn-a\">2</a>"),
            "{page}"
        );
        assert!(
            page.contains("id=\"fn-a\"><sup class=\"footnote-definition-label\">2</sup>"),
            "{page}"
        );
    }

    #[test]
    fn strikethrough_diagrams_and_math_render() {
        let page = export("~~gone~~ $x$\n\n$$y$$\n\n```mermaid\nflowchart LR\n```\n");
        assert!(page.contains("<del>gone</del>"), "{page}");
        assert!(
            page.contains("[false:x]") && page.contains("[true:y]"),
            "{page}"
        );
        assert!(
            page.contains("<figure class=\"diagram\"><svg>diagram</svg></figure>"),
            "{page}"
        );
    }

    #[test]
    fn raw_html_is_escaped() {
        let page = export("<script>alert(1)</script>\n\nText <img src=x onerror=alert(2)> here.\n");
        let body = body(&page);
        assert!(
            !body.contains("<script") && !body.contains("<img"),
            "{body}"
        );
        assert!(
            body.contains("&lt;script&gt;alert(1)&lt;/script&gt;"),
            "{body}"
        );
        assert!(
            body.contains("&lt;img src=x onerror=alert(2)&gt;"),
            "{body}"
        );
        assert!(page.contains(CSP));
    }

    #[test]
    fn script_urls_lose_their_target_and_images_keep_their_paths() {
        let page = export(
            "[a](javascript:alert(1)) [b](JavaScript:x) ![alt \"q\"](img/a.png) [c](https://x.dev)",
        );
        assert!(
            !page.contains("javascript:") && !page.contains("JavaScript:"),
            "{page}"
        );
        assert!(
            page.contains("<img src=\"img/a.png\" alt=\"alt &quot;q&quot;\">"),
            "{page}"
        );
        assert!(page.contains("<a href=\"https://x.dev\">c</a>"), "{page}");
    }

    #[test]
    fn front_matter_stays_out_and_the_stylesheet_cannot_close_its_tag() {
        let page = html(
            "---\nsecret: 1\n---\n# Hi\n",
            &ExportOptions {
                title: "<t>",
                css: "p{}</style><script>",
                diagram: &|_| None,
                math: &|_, _| None,
                code: &|_, _| None,
                folder: None,
            },
        );
        assert!(
            !page.contains("secret") && page.contains("<h1 id=\"hi\">Hi</h1>"),
            "{page}"
        );
        assert!(
            page.contains("<title>&lt;t&gt;</title>") && !page.contains("</style><script>"),
            "{page}"
        );
    }

    #[test]
    fn images_inside_the_folder_inline_and_all_others_keep_their_paths() {
        let root = tempfile::tempdir().unwrap();
        let folder = root.path().join("doc");
        fs::create_dir_all(folder.join("img")).unwrap();
        let png = b"\x89PNG\r\n\x1a\nrest".to_vec();
        fs::write(folder.join("img/a.png"), &png).unwrap();
        fs::write(folder.join("notes.png"), b"not an image").unwrap();
        fs::write(root.path().join("secret.png"), &png).unwrap();
        std::os::unix::fs::symlink(root.path().join("secret.png"), folder.join("link.png"))
            .unwrap();
        let page = html(
            "![a](img/a.png) ![b](link.png) ![c](../secret.png) ![d](notes.png) ![e](missing.png)",
            &ExportOptions {
                title: "t",
                css: "",
                diagram: &|_| None,
                math: &|_, _| None,
                code: &|_, _| None,
                folder: Some(&folder),
            },
        );
        assert!(
            page.contains(&format!(
                "<img src=\"data:image/png;base64,{}\" alt=\"a\">",
                base64(&png)
            )),
            "{page}"
        );
        for kept in ["link.png", "../secret.png", "notes.png", "missing.png"] {
            assert!(
                page.contains(&format!("<img src=\"{kept}\"")),
                "{kept}: {page}"
            );
        }
        assert_eq!(base64(b"Ma"), "TWE=");
    }
    #[test]
    fn front_matter_titles_the_page_and_sets_its_language() {
        let page = export("---\ntitle: \"Plan <b>\"\nlang: fr\n---\n# Hi\n");
        assert!(
            page.contains("<html lang=\"fr\">") && page.contains("<title>Plan &lt;b&gt;</title>"),
            "{page}"
        );
        assert!(export("# Hi\n").contains("<html lang=\"en\">"));
    }

    #[test]
    fn headings_take_unique_anchors_and_wikilinks_reach_exported_pages() {
        let page = export(
            "# Next *Step*\n\n## Next Step\n\n## !!\n\n[a](#next-step) [[Other Note#Some Section]] [[#Next Step]] \
             ![[Other Note]] <someone@example.com>\n",
        );
        assert!(
            page.contains("<h1 id=\"next-step\">Next <em>Step</em></h1>")
                && page.contains("<h2 id=\"next-step-1\">Next Step</h2>")
                && page.contains("<h2 id=\"heading\">!!</h2>"),
            "{page}"
        );
        assert!(
            page.contains("<a href=\"Other%20Note.html#some-section\">")
                && page.contains("<a href=\"#next-step\">")
                && page.contains("<a href=\"Other%20Note.html\">Other Note</a>")
                && page.contains("<a href=\"mailto:someone@example.com\">"),
            "{page}"
        );
        assert!(!body(&page).contains("<img"), "{page}");
    }

    #[test]
    fn percent_encoded_image_paths_inline() {
        let folder = tempfile::tempdir().unwrap();
        fs::create_dir(folder.path().join("sub dir")).unwrap();
        fs::write(
            folder.path().join("sub dir/a b.png"),
            b"\x89PNG\r\n\x1a\nrest",
        )
        .unwrap();
        let page = html(
            "![x](sub%20dir/a%20b.png)",
            &ExportOptions {
                title: "t",
                css: "",
                diagram: &|_| None,
                math: &|_, _| None,
                code: &|_, _| None,
                folder: Some(folder.path()),
            },
        );
        assert!(page.contains("<img src=\"data:image/png;base64,"), "{page}");
    }

    /// The parts of a DOCX export of `text` in `folder`, by name.
    fn docx_parts(text: &str, folder: &Path) -> HashMap<String, String> {
        let bytes = docx::docx(text, folder).unwrap();
        let mut zip = zip::ZipArchive::new(std::io::Cursor::new(bytes)).unwrap();
        (0..zip.len())
            .map(|index| {
                let mut part = zip.by_index(index).unwrap();
                let mut bytes = Vec::new();
                part.read_to_end(&mut bytes).unwrap();
                (
                    part.name().unwrap().into_owned(),
                    String::from_utf8_lossy(&bytes).into_owned(),
                )
            })
            .collect()
    }

    #[test]
    fn docx_leaves_out_front_matter_and_keeps_math_and_html_block_text() {
        let folder = tempfile::tempdir().unwrap();
        let parts = docx_parts(
            "---\ntitle: Secret\n---\n$e^{-x^2}\\,dx$\n\n<div>\nInside a div\n</div>\n\n<details><summary>Click</summary>Hidden</details>\n",
            folder.path(),
        );
        let document = &parts["word/document.xml"];
        assert!(
            !document.contains("Secret") && !document.contains("w:pBdr"),
            "{document}"
        );
        assert!(document.contains(r"e^{-x^2}\,dx"), "{document}");
        assert!(
            document.contains("Inside a div")
                && document.contains("Click Hidden")
                && !document.contains("div&gt;"),
            "{document}"
        );
    }

    #[test]
    fn docx_links_pass_the_allowlist_and_email_gets_mailto() {
        let folder = tempfile::tempdir().unwrap();
        let parts = docx_parts(
            "[a](javascript:alert(1)) [b](vbscript:x) [c](file:///etc/passwd) [d](data:text/html,x) [e](https://x.dev) \
             <someone@example.com> [[Note]]\n",
            folder.path(),
        );
        let rels = &parts["word/_rels/document.xml.rels"];
        for gone in ["javascript:", "vbscript:", "file:", "data:", "Note"] {
            assert!(!rels.contains(gone), "{gone}: {rels}");
        }
        assert!(
            rels.contains("Target=\"https://x.dev\"")
                && rels.contains("Target=\"mailto:someone@example.com\""),
            "{rels}"
        );
    }

    #[test]
    fn docx_code_blocks_stay_apart_footnotes_repeat_and_images_store_once() {
        let folder = tempfile::tempdir().unwrap();
        fs::write(
            folder.path().join("dot.png"),
            b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\0\x01\0\0\0\x01",
        )
        .unwrap();
        let deep: String = (0..12)
            .map(|level| format!("{}- {level}\n", "  ".repeat(level)))
            .collect();
        let parts = docx_parts(
            &format!(
                "```js\na\nb\n```\n```\nc\n```\n\nOne[^1] two[^1].\n\n[^1]: Note.\n\n![](dot.png) ![](dot.png)\n\n{deep}"
            ),
            folder.path(),
        );
        let document = &parts["word/document.xml"];
        assert!(
            document.contains(
                r#"<w:pStyle w:val="CodeLanguage"/></w:pPr><w:r><w:t xml:space="preserve">js</w:t>"#
            ) && document.contains(
                r#"<w:t xml:space="preserve">a</w:t><w:br/><w:t xml:space="preserve">b</w:t>"#
            ) && document.matches("w:val=\"CodeLanguage\"").count() == 2,
            "{document}"
        );
        assert_eq!(
            document.matches("<w:footnoteReference").count(),
            1,
            "{document}"
        );
        assert!(!document.contains("w:ilvl w:val=\"9\""), "{document}");
        let media: Vec<&String> = parts
            .keys()
            .filter(|name| name.starts_with("word/media/"))
            .collect();
        assert_eq!(media.len(), 1, "{media:?}");
    }
}
