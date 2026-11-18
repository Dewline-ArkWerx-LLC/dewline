//! An EPUB 3 book of one exported HTML page: the page's body as one XHTML chapter, a table of contents from its
//! headings, and its inlined images and diagrams as files in the book. Links leave the book only for the web and mail;
//! an image the page could not inline shows its alt text.

use std::fmt::Write as _;
use std::io::{self, Cursor, Write};
use std::time::SystemTime;

use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::decisions::rfc3339;

/// `page`, a page `export::html` wrote, as an EPUB file titled by its first level-one heading, else `title`.
pub fn epub(page: &str, title: &str, modified: SystemTime) -> io::Result<Vec<u8>> {
    let between = |open: &str, close: &str| {
        let start = page.find(open)? + open.len();
        Some(&page[start..start + page[start..].find(close)?])
    };
    let css = between("<style>", "</style>").unwrap_or("");
    let body = between("<body>", "</body>").unwrap_or("");
    let mut book = Book::default();
    let body = book.body(body);
    let title = book
        .headings
        .iter()
        .find(|heading| heading.0 == 1)
        .map_or_else(|| super::escape(title), |heading| heading.2.clone());
    let identifier = blake3::hash(page.as_bytes()).to_hex();
    let chapter = format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<!DOCTYPE html>\n\
         <html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"en\" xml:lang=\"en\">\n\
         <head>\n<meta charset=\"utf-8\"/>\n<title>{title}</title>\n<style>{css}</style>\n</head>\n<body>{body}</body>\n</html>\n"
    );
    let mut manifest = String::new();
    for (index, (name, _)) in book.files.iter().enumerate() {
        let media = match name.rsplit('.').next() {
            Some("png") => "image/png",
            Some("jpeg") => "image/jpeg",
            Some("gif") => "image/gif",
            Some("webp") => "image/webp",
            _ => "image/svg+xml",
        };
        let _ = write!(
            manifest,
            "<item id=\"f{index}\" href=\"{name}\" media-type=\"{media}\"/>"
        );
    }
    let package = format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n\
         <package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"id\" xml:lang=\"en\">\n\
         <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\
         <dc:identifier id=\"id\">urn:dewline:{identifier}</dc:identifier><dc:title>{title}</dc:title>\
         <dc:language>en</dc:language><meta property=\"dcterms:modified\">{}</meta></metadata>\n\
         <manifest><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\
         <item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/>{manifest}</manifest>\n\
         <spine><itemref idref=\"chapter\"/></spine>\n</package>\n",
        rfc3339(modified)
    );
    let nav = format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<!DOCTYPE html>\n\
         <html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" lang=\"en\" xml:lang=\"en\">\n\
         <head><meta charset=\"utf-8\"/><title>{title}</title></head>\n\
         <body><nav epub:type=\"toc\" id=\"toc\"><h1>Contents</h1>{}</nav></body>\n</html>\n",
        contents(&book.headings, &title)
    );
    let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
    let container = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n\
        <container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">\
        <rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>\n";
    let files = [
        ("mimetype".to_owned(), b"application/epub+zip".to_vec()),
        ("META-INF/container.xml".into(), container.into()),
        ("OEBPS/content.opf".into(), package.into_bytes()),
        ("OEBPS/nav.xhtml".into(), nav.into_bytes()),
        ("OEBPS/chapter.xhtml".into(), chapter.into_bytes()),
    ];
    let images = book
        .files
        .into_iter()
        .map(|(name, bytes)| (format!("OEBPS/{name}"), bytes));
    for (name, bytes) in files.into_iter().chain(images) {
        zip.start_file(name, options).map_err(io::Error::other)?;
        zip.write_all(&bytes)?;
    }
    Ok(zip.finish().map_err(io::Error::other)?.into_inner())
}

#[derive(Default)]
struct Book {
    /// Level, id and text of each heading.
    headings: Vec<(u8, String, String)>,
    /// Images, by their path in the book's folder.
    files: Vec<(String, Vec<u8>)>,
}

impl Book {
    /// The page's body as XHTML: each void tag closed, each heading given an id, each diagram and data-URL image moved
    /// to a file, each other image replaced by its alt text, and links to anything but the web, mail and this page
    /// emptied. Every `<` in the body opens a tag, since `export::html` escapes the text.
    fn body(&mut self, body: &str) -> String {
        let mut out = String::with_capacity(body.len());
        let mut rest = body;
        while let Some(at) = rest.find('<') {
            out.push_str(&rest[..at]);
            rest = &rest[at..];
            let end = rest.find('>').map_or(rest.len(), |end| end + 1);
            let tag = &rest[..end];
            let name = tag[1..]
                .split(|c: char| c.is_ascii_whitespace() || c == '>' || c == '/')
                .next()
                .unwrap_or("");
            match name {
                "svg" => {
                    let close = rest.find("</svg>").map_or(rest.len(), |close| close + 6);
                    let name = format!("images/diagram-{}.svg", self.files.len() + 1);
                    let _ = write!(out, "<img src=\"{name}\" alt=\"diagram\"/>");
                    self.files.push((name, rest.as_bytes()[..close].to_vec()));
                    rest = &rest[close..];
                    continue;
                }
                "img" => self.image(tag, &mut out),
                "br" | "hr" => {
                    let _ = write!(out, "<{name}/>");
                }
                "input" => out.push_str(
                    &tag.replace(" disabled", " disabled=\"disabled\"")
                        .replace(" checked", " checked=\"checked\"")
                        .replace('>', "/>"),
                ),
                "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                    let close = rest.find("</h").unwrap_or(rest.len());
                    let id = format!("h{}", self.headings.len() + 1);
                    let level = name.as_bytes()[1] - b'0';
                    self.headings
                        .push((level, id.clone(), strip(&rest[end..close])));
                    let _ = write!(out, "<{name} id=\"{id}\">");
                }
                "a" => match attribute(tag, "href") {
                    Some(href)
                        if href.starts_with('#')
                            || ["http:", "https:", "mailto:"]
                                .iter()
                                .any(|scheme| href.starts_with(scheme)) =>
                    {
                        out.push_str(tag)
                    }
                    _ => out.push_str("<a>"),
                },
                _ => out.push_str(tag),
            }
            rest = &rest[end..];
        }
        out.push_str(rest);
        out
    }

    fn image(&mut self, tag: &str, out: &mut String) {
        let alt = attribute(tag, "alt").unwrap_or("");
        let data = attribute(tag, "src").and_then(|src| {
            let (kind, data) = src.strip_prefix("data:image/")?.split_once(";base64,")?;
            Some((
                if kind == "svg+xml" { "svg" } else { kind },
                unbase64(data)?,
            ))
        });
        let Some((extension, bytes)) = data else {
            let _ = write!(out, "[image: {alt}]");
            return;
        };
        let name = format!("images/image-{}.{extension}", self.files.len() + 1);
        let class =
            attribute(tag, "class").map_or(String::new(), |class| format!(" class=\"{class}\""));
        let style =
            attribute(tag, "style").map_or(String::new(), |style| format!(" style=\"{style}\""));
        let _ = write!(out, "<img{class} src=\"{name}\" alt=\"{alt}\"{style}/>");
        self.files.push((name, bytes));
    }
}

/// The value of `name="…"` in `tag`, as written.
fn attribute<'t>(tag: &'t str, name: &str) -> Option<&'t str> {
    let start = tag.find(&format!(" {name}=\""))? + name.len() + 3;
    Some(&tag[start..start + tag[start..].find('"')?])
}

/// `html` without its tags.
fn strip(html: &str) -> String {
    let mut text = String::new();
    let mut inside = false;
    for c in html.chars() {
        match c {
            '<' => inside = true,
            '>' => inside = false,
            c if !inside => text.push(c),
            _ => {}
        }
    }
    text.trim().to_owned()
}

/// The table of contents: one list, nested as the headings are.
fn contents(headings: &[(u8, String, String)], title: &str) -> String {
    if headings.is_empty() {
        return format!("<ol><li><a href=\"chapter.xhtml\">{title}</a></li></ol>");
    }
    let mut out = String::new();
    // The level of each open list: a heading joins the innermost list whose parent is shallower than it.
    let mut levels: Vec<u8> = Vec::new();
    for (level, id, text) in headings {
        while levels.len() > 1 && levels[levels.len() - 2] >= *level {
            levels.pop();
            out.push_str("</li></ol>");
        }
        match levels.last_mut() {
            Some(last) if *last >= *level => {
                *last = *level;
                out.push_str("</li>");
            }
            _ => {
                levels.push(*level);
                out.push_str("<ol>");
            }
        }
        let _ = write!(out, "<li><a href=\"chapter.xhtml#{id}\">{text}</a>");
    }
    out + &"</li></ol>".repeat(levels.len())
}

fn unbase64(text: &str) -> Option<Vec<u8>> {
    let value = |byte: u8| match byte {
        b'A'..=b'Z' => Some(byte - b'A'),
        b'a'..=b'z' => Some(byte - b'a' + 26),
        b'0'..=b'9' => Some(byte - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    };
    let mut out = Vec::with_capacity(text.len() / 4 * 3);
    for chunk in text.trim_end_matches('=').as_bytes().chunks(4) {
        let n = chunk.iter().enumerate().try_fold(0u32, |n, (i, &byte)| {
            Some(n | u32::from(value(byte)?) << (18 - 6 * i))
        })?;
        out.extend_from_slice(&n.to_be_bytes()[1..chunk.len()]);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::super::{ExportOptions, base64, html};
    use super::*;
    use std::io::Read;

    fn book(markdown: &str) -> Vec<(String, Vec<u8>)> {
        let page = html(
            markdown,
            &ExportOptions {
                title: "notes",
                css: "body { margin: 0 }",
                diagram: &|_| {
                    Some("<svg xmlns=\"http://www.w3.org/2000/svg\"><text>A</text></svg>".into())
                },
                math: &|tex, _| {
                    Some(format!(
                        "<img class=\"math\" alt=\"{tex}\" style=\"width:4px\" src=\"data:image/png;base64,{}\">",
                        base64(b"\x89PNG math")
                    ))
                },
                code: &|_, _| None,
                folder: None,
            },
        );
        let bytes = epub(&page, "notes", SystemTime::UNIX_EPOCH).unwrap();
        let mut archive = zip::ZipArchive::new(Cursor::new(bytes)).unwrap();
        (0..archive.len())
            .map(|index| {
                let mut file = archive.by_index(index).unwrap();
                let mut bytes = Vec::new();
                file.read_to_end(&mut bytes).unwrap();
                (file.name().unwrap().into_owned(), bytes)
            })
            .collect()
    }

    #[test]
    fn the_mimetype_comes_first_uncompressed_and_every_part_is_there() {
        let bytes = epub("<body>\n<p>x</p>\n</body>", "t", SystemTime::UNIX_EPOCH).unwrap();
        assert_eq!(&bytes[..4], b"PK\x03\x04");
        assert_eq!(u16::from_le_bytes([bytes[8], bytes[9]]), 0, "stored");
        assert_eq!(
            u16::from_le_bytes([bytes[28], bytes[29]]),
            0,
            "no extra field"
        );
        assert_eq!(&bytes[30..38], b"mimetype");
        assert_eq!(&bytes[38..58], b"application/epub+zip");
        let names: Vec<String> = book("x").into_iter().map(|(name, _)| name).collect();
        assert_eq!(
            names,
            [
                "mimetype",
                "META-INF/container.xml",
                "OEBPS/content.opf",
                "OEBPS/nav.xhtml",
                "OEBPS/chapter.xhtml"
            ]
        );
    }

    #[test]
    fn headings_make_the_contents_and_images_and_diagrams_become_files() {
        let files = book(
            "# Field *notes*\n\n## One\n\n### Deep\n\n## Two\n\nA $x$ and ![gone](missing.png) and [[note]] and \
             [web](https://x.dev).\n\n- [x] done\n\n---\n\n```mermaid\nflowchart LR\n```\n",
        );
        let bytes = |name: &str| {
            files
                .iter()
                .find(|(file, _)| file == name)
                .unwrap()
                .1
                .clone()
        };
        let file = |name: &str| String::from_utf8(bytes(name)).unwrap();
        let chapter = file("OEBPS/chapter.xhtml");
        assert!(
            chapter.contains("<h1 id=\"h1\">Field <em>notes</em></h1>"),
            "{chapter}"
        );
        assert!(chapter.contains("<title>Field notes</title>"), "{chapter}");
        assert!(
            chapter.contains(
                "<img class=\"math\" src=\"images/image-1.png\" alt=\"x\" style=\"width:4px\"/>"
            ),
            "{chapter}"
        );
        assert!(
            chapter.contains("[image: gone]") && chapter.contains("<a>note</a>"),
            "{chapter}"
        );
        assert!(
            chapter.contains("<a href=\"https://x.dev\">web</a>"),
            "{chapter}"
        );
        assert!(
            chapter
                .contains("<input type=\"checkbox\" disabled=\"disabled\" checked=\"checked\"/>"),
            "{chapter}"
        );
        assert!(chapter.contains("<hr/>"), "{chapter}");
        assert!(
            chapter.contains("<figure class=\"diagram\"><img src=\"images/diagram-2.svg\" alt=\"diagram\"/></figure>"),
            "{chapter}"
        );
        assert_eq!(bytes("OEBPS/images/image-1.png"), b"\x89PNG math");
        assert!(file("OEBPS/images/diagram-2.svg").starts_with("<svg xmlns"));
        let nav = file("OEBPS/nav.xhtml");
        assert!(
            nav.contains(
                "<ol><li><a href=\"chapter.xhtml#h1\">Field notes</a><ol><li><a href=\"chapter.xhtml#h2\">One</a>\
                 <ol><li><a href=\"chapter.xhtml#h3\">Deep</a></li></ol></li><li><a href=\"chapter.xhtml#h4\">Two</a>\
                 </li></ol></li></ol>"
            ),
            "{nav}"
        );
        let package = file("OEBPS/content.opf");
        assert!(
            package.contains("<dc:title>Field notes</dc:title>"),
            "{package}"
        );
        assert!(package.contains("1970-01-01T00:00:00Z"), "{package}");
        assert!(
            package.contains("href=\"images/image-1.png\" media-type=\"image/png\"")
                && package.contains("href=\"images/diagram-2.svg\" media-type=\"image/svg+xml\""),
            "{package}"
        );
    }

    #[test]
    fn a_shallower_heading_after_a_deeper_one_stays_in_one_list() {
        let heading = |level, id: &str| (level, id.to_owned(), id.to_owned());
        assert_eq!(
            contents(
                &[
                    heading(2, "a"),
                    heading(1, "b"),
                    heading(3, "c"),
                    heading(2, "d")
                ],
                "t"
            ),
            "<ol><li><a href=\"chapter.xhtml#a\">a</a></li><li><a href=\"chapter.xhtml#b\">b</a><ol><li>\
             <a href=\"chapter.xhtml#c\">c</a></li><li><a href=\"chapter.xhtml#d\">d</a></li></ol></li></ol>"
        );
    }

    #[test]
    fn without_a_heading_the_title_is_the_file_name_and_base64_round_trips() {
        let files = book("Just text.\n");
        let (_, package) = files
            .iter()
            .find(|(name, _)| name == "OEBPS/content.opf")
            .unwrap();
        assert!(String::from_utf8_lossy(package).contains("<dc:title>notes</dc:title>"));
        for bytes in [&b""[..], b"M", b"Ma", b"Man", b"\x89PNG\r\n\x1a\n"] {
            assert_eq!(unbase64(&base64(bytes)).as_deref(), Some(bytes));
        }
    }
}
