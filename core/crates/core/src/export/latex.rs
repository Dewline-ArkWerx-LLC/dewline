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

/// The commands math may use, from the symbol and function tables of the renderer that previews it in the app.
const MATH_COMMANDS: &str = "And Big Bigg Biggl Biggr Bigl Bigr Box Bumpeq Cap Cup Delta Diamond Doteq Downarrow Finv Game Gamma Im Join \
Lambda Leftarrow Leftrightarrow Lleftarrow Longleftarrow Longleftrightarrow Longrightarrow Lsh Omega P Phi Pi \
Pr Psi Re Rightarrow Rrightarrow Rsh S Sigma Subset Supset Theta Uparrow Updownarrow Upsilon Vdash Vert Vvdash \
Xi acute aleph allowbreak alpha amalg angle approx approxeq arccos arcsin arctan arg ast asymp backepsilon \
backprime backsim backsimeq backslash bar barwedge bcancel because beta beth between big bigcap bigcirc bigcup \
bigg biggl biggr bigl bigodot bigoplus bigotimes bigr bigsqcup bigstar bigtriangledown bigtriangleup biguplus \
bigvee bigwedge binom blacklozenge blacksquare blacktriangle blacktriangledown blacktriangleleft \
blacktriangleright bm bmod boldsymbol bot bowtie boxdot boxed boxminus boxplus boxtimes breve bullet bumpeq \
cancel cap cdot cdotp centerdot cfrac check checkmark chi circ circeq circlearrowleft circlearrowright \
circledR circledS circledast circledcirc circleddash clubsuit complement cong coprod cos cosh cot coth csc cup \
curlyeqprec curlyeqsucc curlyvee curlywedge curvearrowleft curvearrowright dag dagger daleth dashleftarrow \
dashrightarrow dashv dbinom ddag ddagger dddot ddot ddots deg degree delta det dfrac diagdown diagup diamond \
diamondsuit digamma dim displaystyle div divideontimes dot doteq doteqdot dotplus doublebarwedge doublecap \
doublecup downarrow downdownarrows downharpoonleft downharpoonright ell emptyset epsilon eqcirc eqsim \
eqslantgtr eqslantless equiv eta eth exists exp fallingdotseq flat forall frac frown gamma gcd ge geq geqq \
geqslant gets gg ggg gggtr gimel gnapprox gneq gneqq gnsim grave gt gtrapprox gtrdot gtreqless gtreqqless \
gtrless gtrsim hat hbar heartsuit hom hookleftarrow hookrightarrow hslash iiint iint imageof in inf infty int \
intercal intop iota kappa ker lVert lambda land langle lbrace lbrack lceil ldotp ldots le leadsto left \
leftarrow leftarrowtail leftharpoondown leftharpoonup leftleftarrows leftrightarrow leftrightarrows \
leftrightharpoons leftrightsquigarrow leftthreetimes leq leqq leqslant lessapprox lessdot lesseqgtr lesseqqgtr \
lessgtr lesssim lfloor lg lgroup lhd lim liminf limits limsup ll lll llless lmoustache ln lnapprox lneq lneqq \
lnot lnsim log longleftarrow longleftrightarrow longmapsto longrightarrow looparrowleft looparrowright lor \
lozenge lparen lt ltimes lvert maltese mapsto mathbb mathbf mathcal mathellipsis mathfrak mathit mathring \
mathrm mathscr mathsf mathsterling mathtt max mbox measuredangle mho mid middle min mod models mp mu multimap \
nLeftarrow nLeftrightarrow nRightarrow nVDash nVdash nabla natural ncong nearrow neg nexists ngeq ngtr ni \
nleftarrow nleftrightarrow nleq nless nmid nobreak nobreakspace nolimits nonumber not nparallel nprec npreceq \
nrightarrow nsim nsubseteq nsucc nsucceq nsupseteq ntriangleleft ntrianglelefteq ntriangleright \
ntrianglerighteq nu nvDash nvdash nwarrow odot oiiint oiint oint omega omicron ominus operatorname oplus \
origof oslash otimes overbrace overline overset owns parallel partial perp phantom phi pi pitchfork pm pmod \
pod pounds prec precapprox preccurlyeq preceq precnapprox precneqq precnsim precsim prime prod propto psi \
qquad quad rVert rangle rbrace rbrack rceil restriction rfloor rgroup rhd rho right rightarrow rightarrowtail \
rightharpoondown rightharpoonup rightleftarrows rightleftharpoons rightrightarrows rightsquigarrow \
rightthreetimes risingdotseq rmoustache rparen rtimes rvert scriptscriptstyle scriptstyle searrow sec setminus \
sharp shortmid shortparallel sigma sim simeq sin sinh smallfrown smallint smallsetminus smallsmile smile space \
spadesuit sphericalangle sqcap sqcup sqrt sqsubset sqsubseteq sqsupset sqsupseteq square stackrel star subset \
subseteq subseteqq subsetneq subsetneqq substack succ succapprox succcurlyeq succeq succnapprox succneqq \
succnsim succsim sum sup supset supseteq supseteqq supsetneq supsetneqq surd swarrow tan tanh tau tbinom text \
textbf textit textrm textsf textstyle texttt tfrac therefore theta thickapprox thicksim tilde times to top \
triangle triangledown triangleleft trianglelefteq triangleq triangleright trianglerighteq twoheadleftarrow \
twoheadrightarrow underbrace underline underset unlhd unrhd uparrow updownarrow upharpoonleft upharpoonright \
uplus upsilon upuparrows vDash varepsilon varkappa varnothing varphi varpi varpropto varrho varsigma vartheta \
vartriangle vartriangleleft vartriangleright varvdots vdash vec vee veebar vert wedge widehat widetilde wp wr \
xcancel xi xleftarrow xrightarrow yen zeta";

/// Environments math may open.
const MATH_ENVIRONMENTS: &[&str] = &[
    "matrix", "pmatrix", "bmatrix", "vmatrix", "cases", "aligned", "gathered", "array", "split",
];

/// Whether `tex` is plain math: every command is on the allowlist, groups balance, and nothing hides a character
/// or ends the math early. Anything else could run TeX, so the caller writes it as text.
fn safe_math(tex: &str) -> bool {
    if tex.contains("^^") {
        return false;
    }
    let mut depth = 0usize;
    let mut rest = tex;
    while let Some(at) = rest.find(['\\', '{', '}', '%', '$', '@', '#']) {
        let after = &rest[at + 1..];
        match rest.as_bytes()[at] {
            b'{' => depth += 1,
            b'}' => match depth.checked_sub(1) {
                Some(open) => depth = open,
                None => return false,
            },
            b'\\' => {
                let name_len = after
                    .find(|c: char| !c.is_ascii_alphabetic())
                    .unwrap_or(after.len());
                if name_len > 0 {
                    let name = &after[..name_len];
                    if name == "begin" || name == "end" {
                        let Some(env) = after[name_len..]
                            .strip_prefix('{')
                            .and_then(|tail| tail.split_once('}'))
                        else {
                            return false;
                        };
                        if !MATH_ENVIRONMENTS.contains(&env.0) {
                            return false;
                        }
                    } else if !MATH_COMMANDS.split_whitespace().any(|known| known == name) {
                        return false;
                    }
                    rest = &after[name_len..];
                    continue;
                }
                match after.chars().next() {
                    Some(c) if "\\{},;:!|&_$% >".contains(c) => {
                        rest = &after[c.len_utf8()..];
                        continue;
                    }
                    _ => return false,
                }
            }
            _ => return false,
        }
        rest = after;
    }
    depth == 0
}

/// A link target with the characters TeX reads as commands, groups or comments percent-encoded.
fn href_target(url: &str) -> String {
    let mut out = String::with_capacity(url.len());
    for c in url.chars() {
        if c.is_whitespace() || "\\{}^~%#".contains(c) {
            let mut bytes = [0; 4];
            for byte in c.encode_utf8(&mut bytes).bytes() {
                let _ = write!(out, "\\%{byte:02X}");
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn verbatim(out: &mut String, source: &str) {
    let source = source.trim_end_matches('\n');
    if source.contains("\\end") {
        out.push_str("{\\ttfamily\\noindent\n");
        for (index, line) in source.split('\n').enumerate() {
            if index > 0 {
                out.push_str("\\\\\n");
            }
            out.push_str(&escape(line).replace(' ', "\\ "));
        }
        out.push_str("\\par}\n\n");
        return;
    }
    let _ = write!(out, "\\begin{{verbatim}}\n{source}\n\\end{{verbatim}}\n\n");
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
                let _ = if safe_math(&tex) {
                    write!(self.out, "${tex}$")
                } else {
                    write!(self.out, "{}", escape(&format!("${tex}$")))
                };
            }
            Event::DisplayMath(tex) => {
                let _ = if safe_math(&tex) {
                    write!(self.out, "\\[{}\\]", tex.trim())
                } else {
                    write!(self.out, "{}", escape(&format!("$${tex}$$")))
                };
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
                    let _ = write!(self.out, "\\href{{{}}}{{", href_target(&dest_url));
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
            TagEnd::Link if self.links.pop() == Some(true) => self.out.push('}'),
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
    fn code_cannot_close_verbatim() {
        for src in ["\\end{verbatim}", "\\end {verbatim}", "\\end{ verbatim }"] {
            let out = tex(&format!("```\na {{b}}\n  {src}\\input{{x}}\n```\n"));
            assert!(!out.contains("\\begin{verbatim}"), "{out}");
            assert!(!out.contains("\\end{verbatim}"), "{out}");
            assert!(!out.contains("\\end {"), "{out}");
            assert!(
                out.contains("a\\ \\{b\\}\\\\\n\\ \\ \\textbackslash{}end"),
                "{out}"
            );
        }
    }

    #[test]
    fn link_targets_are_percent_encoded() {
        let out = tex("[a](<https://x.dev/a b\\c{d}^~%#e>)");
        assert!(
            out.contains("\\href{https://x.dev/a\\%20b\\%5Cc\\%7Bd\\%7D\\%5E\\%7E\\%25\\%23e}{a}"),
            "{out}"
        );
    }

    #[test]
    fn math_outside_the_allowlist_is_text() {
        for bad in [
            "\\gdef\\x{y}",
            "\\InputIfFileExists{/etc/passwd}{}{}",
            "\\directlua{os.execute('x')}",
            "\\^^5cinput{x}",
            "^^5cinput{x}",
            "\\begin{filecontents}x\\end{filecontents}",
            "a % b",
            "\\frac{a}{b",
        ] {
            let out = tex(&format!("${bad}$ and\n\n$${bad}$$\n"));
            assert!(!out.contains("${bad}$"), "{out}");
            assert!(!out.contains("\\["), "{out}");
            assert!(out.contains("\\$"), "{out}");
        }
        let formula = "\\begin{pmatrix} \\alpha & \\frac{1}{\\sqrt{2}} \\\\ \\mathbb{R} \\le \\sum_{i=1}^n x_i\\,\\} \\end{pmatrix}";
        let out = tex(&format!(
            "${formula}$\n\n$$\\int_0^1 \\left( x \\right) dx$$\n"
        ));
        assert!(out.contains(&format!("${formula}$")), "{out}");
        assert!(
            out.contains("\\[\\int_0^1 \\left( x \\right) dx\\]"),
            "{out}"
        );
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
                "See \\href{https://x.dev/a\\%23b}{docs}, note and this\\footnote{The \\emph{note}.}."
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
