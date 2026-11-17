//! Markdown as a standalone LaTeX article: math as written, code in `verbatim`, tables as `tabular`, footnotes as
//! `\footnote`, and each diagram and each PNG or JPEG image inside the document's folder as a file beside it, included
//! with graphicx. Other images show their alt text.

use std::collections::HashMap;
use std::fmt::Write as _;
use std::path::Path;

use pulldown_cmark::{
    Alignment, CodeBlockKind, Event, HeadingLevel, LinkType, Parser, Tag, TagEnd,
};

use super::{OPTIONS, code, files_folder, read_image};

const PREAMBLE: &str = r"\documentclass{article}
\usepackage{iftex}
\ifPDFTeX
  \usepackage[T1]{fontenc}
  \usepackage[utf8]{inputenc}
  \usepackage{lmodern}
\else
  \usepackage{fontspec}
\fi
\usepackage{amsmath,amssymb}
\usepackage{graphicx}
\usepackage[normalem]{ulem}
\usepackage{hyperref}
\makeatletter
\def\maxwidth{\ifdim\Gin@nat@width>\linewidth\linewidth\else\Gin@nat@width\fi}
\makeatother
";

/// `markdown` as a `.tex` file named `name`, and the files to write beside it: its diagrams as PNGs drawn by `diagram`,
/// and its images read from inside `folder`, each at a path relative to the `.tex` file. The title is the first
/// heading when the text opens with a level-one heading, else `name`.
pub fn latex(
    markdown: &str,
    name: &str,
    folder: Option<&Path>,
    diagram: &dyn Fn(&str) -> Option<Vec<u8>>,
) -> (String, Vec<(String, Vec<u8>)>) {
    let mut writer = Writer {
        files_folder: files_folder(name),
        ..Writer::default()
    };
    let mut title = escape(name);
    let mut events = Parser::new_ext(markdown, OPTIONS).peekable();
    while let Some(Event::Start(Tag::MetadataBlock(_))) = events.peek() {
        events.next();
        code(&mut events);
    }
    if let Some(Event::Start(Tag::Heading {
        level: HeadingLevel::H1,
        ..
    })) = events.peek()
    {
        events.next();
        for event in events.by_ref() {
            if event == Event::End(TagEnd::Heading(HeadingLevel::H1)) {
                break;
            }
            writer.event(event);
        }
        title = std::mem::take(&mut writer.out);
    }
    while let Some(event) = events.next() {
        match event {
            Event::Start(Tag::MetadataBlock(_)) => {
                code(&mut events);
            }
            Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(info)))
                if info.split_whitespace().next() == Some("mermaid") =>
            {
                let source = code(&mut events);
                match diagram(&source) {
                    Some(png) => {
                        let path = writer.file("diagram", "png", png);
                        let _ = write!(
                            writer.out,
                            "\\begin{{center}}\n\\includegraphics[width=\\maxwidth]{{{path}}}\n\\end{{center}}\n\n"
                        );
                    }
                    None => verbatim(&mut writer.out, &source),
                }
            }
            Event::Start(Tag::Image { dest_url, .. }) => {
                let alt = code(&mut events);
                let copied = writer.images.get(dest_url.as_ref()).cloned().or_else(|| {
                    let (extension, bytes) =
                        match folder.and_then(|folder| read_image(folder, &dest_url))? {
                            ("image/png", bytes) => ("png", bytes),
                            ("image/jpeg", bytes) => ("jpg", bytes),
                            _ => return None,
                        };
                    let path = writer.file("image", extension, bytes);
                    writer.images.insert(dest_url.to_string(), path.clone());
                    Some(path)
                });
                let _ = match copied {
                    Some(path) => {
                        write!(writer.out, "\\includegraphics[width=\\maxwidth]{{{path}}}")
                    }
                    None => write!(writer.out, "[image: {}]", escape(&alt)),
                };
            }
            Event::Start(Tag::CodeBlock(_)) => {
                let source = code(&mut events);
                verbatim(&mut writer.out, &source);
            }
            event => writer.event(event),
        }
    }
    let mut body = String::with_capacity(writer.out.len());
    for (index, part) in writer.out.split('\u{0}').enumerate() {
        if index % 2 == 0 {
            body.push_str(part);
        } else if let Some(note) = writer.notes.get(part) {
            body.push_str(note.trim());
        }
    }
    let tex = format!(
        "{PREAMBLE}\\title{{{title}}}\n\\author{{}}\n\\date{{}}\n\n\\begin{{document}}\n\\maketitle\n\n{}\n\\end{{document}}\n",
        body.trim_end()
    );
    (tex, writer.files)
}

fn verbatim(out: &mut String, source: &str) {
    let _ = write!(
        out,
        "\\begin{{verbatim}}\n{}\n\\end{{verbatim}}\n\n",
        source.trim_end_matches('\n')
    );
}

/// `text` with LaTeX's special characters as commands that print them.
fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '\\' => out.push_str("\\textbackslash{}"),
            '^' => out.push_str("\\textasciicircum{}"),
            '~' => out.push_str("\\textasciitilde{}"),
            '{' | '}' | '$' | '&' | '#' | '_' | '%' => {
                out.push('\\');
                out.push(c);
            }
            c => out.push(c),
        }
    }
    out
}

#[derive(Default)]
struct Writer {
    out: String,
    files_folder: String,
    files: Vec<(String, Vec<u8>)>,
    /// The path of each image copied, by its address in the text.
    images: HashMap<String, String>,
    /// Each footnote's text, by label. The body holds each reference's label between NULs until the end, when an
    /// undefined one goes.
    notes: HashMap<String, String>,
    /// The body written before the footnote being written.
    outside: Option<(String, String)>,
    /// Each open ordered list: whether it is ordered.
    lists: Vec<bool>,
    /// Each open link: whether it opened `\href`.
    links: Vec<bool>,
    cell: usize,
}

impl Writer {
    /// Adds a file to write beside the `.tex` file and returns its path.
    fn file(&mut self, kind: &str, extension: &str, bytes: Vec<u8>) -> String {
        let path = format!(
            "{}/{kind}-{}.{extension}",
            self.files_folder,
            self.files.len() + 1
        );
        self.files.push((path.clone(), bytes));
        path
    }

    fn event(&mut self, event: Event<'_>) {
        match event {
            Event::Start(tag) => self.start(tag),
            Event::End(tag) => self.end(tag),
            Event::Text(text) | Event::Html(text) | Event::InlineHtml(text) => {
                self.out.push_str(&escape(&text))
            }
            Event::Code(text) => {
                let _ = write!(self.out, "\\texttt{{{}}}", escape(&text));
            }
            Event::InlineMath(tex) => {
                let _ = write!(self.out, "${tex}$");
            }
            Event::DisplayMath(tex) => {
                let _ = write!(self.out, "\\[{}\\]", tex.trim());
            }
            Event::FootnoteReference(label) => {
                let _ = write!(self.out, "\\footnote{{\u{0}{label}\u{0}}}");
            }
            Event::SoftBreak => self.out.push('\n'),
            Event::HardBreak => self.out.push_str("\\\\\n"),
            Event::Rule => self
                .out
                .push_str("\\par\\noindent\\rule{\\linewidth}{0.4pt}\n\n"),
            Event::TaskListMarker(checked) => {
                if self.out.ends_with("\\item ") {
                    self.out.truncate(self.out.len() - 1);
                }
                self.out.push_str(if checked {
                    "[$\\boxtimes$] "
                } else {
                    "[$\\square$] "
                });
            }
        }
    }

    fn start(&mut self, tag: Tag<'_>) {
        match tag {
            Tag::Heading { level, .. } => {
                let command = match level {
                    HeadingLevel::H1 => "section",
                    HeadingLevel::H2 => "subsection",
                    HeadingLevel::H3 => "subsubsection",
                    HeadingLevel::H4 => "paragraph",
                    _ => "subparagraph",
                };
                let _ = write!(self.out, "\\{command}*{{");
            }
            Tag::BlockQuote(_) => self.out.push_str("\\begin{quote}\n"),
            Tag::List(start) => {
                self.lists.push(start.is_some());
                match start {
                    Some(start) => {
                        let _ = writeln!(self.out, "\\begin{{enumerate}}");
                        if start != 1 {
                            let depth = self.lists.iter().filter(|&&ordered| ordered).count();
                            let counter = ["i", "ii", "iii", "iv"][depth.clamp(1, 4) - 1];
                            let _ = writeln!(
                                self.out,
                                "\\setcounter{{enum{counter}}}{{{}}}",
                                start - 1
                            );
                        }
                    }
                    None => self.out.push_str("\\begin{itemize}\n"),
                }
            }
            Tag::Item => self.out.push_str("\\item "),
            Tag::FootnoteDefinition(label) => {
                let body = std::mem::take(&mut self.out);
                self.outside = Some((label.to_string(), body));
            }
            Tag::DefinitionList => self.out.push_str("\\begin{description}\n"),
            Tag::DefinitionListTitle => self.out.push_str("\\item["),
            Tag::Table(columns) => {
                let spec: String = columns
                    .iter()
                    .map(|column| match column {
                        Alignment::Center => 'c',
                        Alignment::Right => 'r',
                        _ => 'l',
                    })
                    .collect();
                let _ = write!(
                    self.out,
                    "\\begin{{center}}\n\\begin{{tabular}}{{{spec}}}\n\\hline\n"
                );
            }
            Tag::TableHead | Tag::TableRow => self.cell = 0,
            Tag::TableCell => {
                if self.cell > 0 {
                    self.out.push_str(" & ");
                }
                self.cell += 1;
            }
            Tag::Emphasis => self.out.push_str("\\emph{"),
            Tag::Strong => self.out.push_str("\\textbf{"),
            Tag::Strikethrough => self.out.push_str("\\sout{"),
            Tag::Superscript => self.out.push_str("\\textsuperscript{"),
            Tag::Subscript => self.out.push_str("\\textsubscript{"),
            Tag::Link {
                link_type,
                dest_url,
                ..
            } => {
                let web = ["http:", "https:", "mailto:"]
                    .iter()
                    .any(|scheme| dest_url.starts_with(scheme));
                let href = web && !matches!(link_type, LinkType::WikiLink { .. });
                if href {
                    let target = dest_url
                        .replace('\\', "")
                        .replace('%', "\\%")
                        .replace('#', "\\#");
                    let _ = write!(self.out, "\\href{{{target}}}{{");
                }
                self.links.push(href);
            }
            _ => {}
        }
    }

    fn end(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::Paragraph => self.out.push_str("\n\n"),
            TagEnd::Heading(_) => self.out.push_str("}\n\n"),
            TagEnd::BlockQuote(_) => self.out.push_str("\\end{quote}\n\n"),
            TagEnd::List(_) => {
                let ordered = self.lists.pop() == Some(true);
                self.out.push_str(if ordered {
                    "\\end{enumerate}\n\n"
                } else {
                    "\\end{itemize}\n\n"
                });
            }
            TagEnd::Item => self.out.push('\n'),
            TagEnd::FootnoteDefinition => {
                if let Some((label, body)) = self.outside.take() {
                    let note = std::mem::replace(&mut self.out, body);
                    self.notes.entry(label).or_insert(note);
                }
            }
            TagEnd::DefinitionList => self.out.push_str("\\end{description}\n\n"),
            TagEnd::DefinitionListTitle => self.out.push_str("] "),
            TagEnd::DefinitionListDefinition => self.out.push('\n'),
            TagEnd::TableHead => self.out.push_str(" \\\\\n\\hline\n"),
            TagEnd::TableRow => self.out.push_str(" \\\\\n"),
            TagEnd::Table => self
                .out
                .push_str("\\hline\n\\end{tabular}\n\\end{center}\n\n"),
            TagEnd::Emphasis
            | TagEnd::Strong
            | TagEnd::Strikethrough
            | TagEnd::Superscript
            | TagEnd::Subscript => self.out.push('}'),
            TagEnd::Link => {
                if self.links.pop() == Some(true) {
                    self.out.push('}');
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn tex(markdown: &str) -> String {
        latex(markdown, "notes", None, &|_| Some(b"png".to_vec())).0
    }

    #[test]
    fn the_first_heading_titles_a_standalone_article() {
        let out = tex("# Field *notes*\n\n## Plan\n\nText & 100% of $5_x.\n");
        assert!(out.starts_with("\\documentclass{article}\n"), "{out}");
        assert!(out.contains("\\title{Field \\emph{notes}}\n"), "{out}");
        assert!(
            out.contains("\\subsection*{Plan}\n\nText \\& 100\\% of \\$5\\_x.\n"),
            "{out}"
        );
        assert!(out.ends_with("\\end{document}\n"), "{out}");
        assert!(tex("Just text.").contains("\\title{notes}"));
    }

    #[test]
    fn math_passes_through_and_code_goes_in_verbatim() {
        let out = tex(
            "Inline $a^2 + b_1$ and\n\n$$\\int_0^1 x\\,dx$$\n\n```rust\nlet a = {1};\n```\n\nSay `x_y`.\n",
        );
        assert!(out.contains("Inline $a^2 + b_1$ and"), "{out}");
        assert!(out.contains("\\[\\int_0^1 x\\,dx\\]"), "{out}");
        assert!(
            out.contains("\\begin{verbatim}\nlet a = {1};\n\\end{verbatim}"),
            "{out}"
        );
        assert!(out.contains("\\texttt{x\\_y}"), "{out}");
    }

    #[test]
    fn tables_lists_links_and_footnotes() {
        let out = tex(
            "| a | b | c |\n|:-|:-:|-:|\n| 1 | 2 | 3 |\n\n3. three\n4. four\n\n- [x] done\n- plain\n\n\
             See [docs](https://x.dev/a#b), [[note]] and this[^n].\n\n[^n]: The *note*.\n",
        );
        assert!(
            out.contains("\\begin{tabular}{lcr}\n\\hline\na & b & c \\\\\n\\hline\n1 & 2 & 3 \\\\\n\\hline\n\\end{tabular}"),
            "{out}"
        );
        assert!(
            out.contains("\\begin{enumerate}\n\\setcounter{enumi}{2}\n\\item three\n"),
            "{out}"
        );
        assert!(
            out.contains("\\item[$\\boxtimes$] done\n\\item plain\n"),
            "{out}"
        );
        assert!(
            out.contains(
                "See \\href{https://x.dev/a\\#b}{docs}, note and this\\footnote{The \\emph{note}.}."
            ),
            "{out}"
        );
        assert!(!out.contains('\u{0}'), "{out}");
    }

    #[test]
    fn diagrams_and_images_become_files_beside_the_tex() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("dot.png"), b"\x89PNG\r\n\x1a\nrest").unwrap();
        fs::write(dir.path().join("pic.gif"), b"GIF89a rest").unwrap();
        let (out, files) = latex(
            "```mermaid\nflowchart LR\n```\n\n![dot](dot.png) ![pic](pic.gif) ![web](https://x.dev/a.png)\n\n```mermaid\nbad\n```\n\n\
             ![[dot.png]]\n",
            "launch plan v1.2",
            Some(dir.path()),
            &|source| (source != "bad\n").then(|| b"png".to_vec()),
        );
        let names: Vec<&str> = files.iter().map(|(name, _)| name.as_str()).collect();
        assert_eq!(
            names,
            [
                "launch-plan-v1-2-files/diagram-1.png",
                "launch-plan-v1-2-files/image-2.png"
            ]
        );
        assert!(
            out.contains(
                "\\includegraphics[width=\\maxwidth]{launch-plan-v1-2-files/diagram-1.png}"
            ),
            "{out}"
        );
        assert!(out.contains("\\includegraphics[width=\\maxwidth]{launch-plan-v1-2-files/image-2.png} [image: pic] [image: web]"), "{out}");
        assert!(
            out.contains("\\begin{verbatim}\nbad\n\\end{verbatim}"),
            "{out}"
        );
        assert_eq!(files[1].1, b"\x89PNG\r\n\x1a\nrest");
    }
}
