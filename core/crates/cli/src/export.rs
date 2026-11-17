//! `dewline export`: HTML and DOCX here, through core's exporters; the other formats through the app, which owns the
//! layout, the theme and the diagram and math renderers.

use std::fs;
use std::path::{self, Path};

use clap::ValueEnum;
use dewline_core::export::{self, ExportOptions};

use crate::control::Socket;

/// Each named by its extension, as the app names it on the socket.
#[derive(Clone, Copy, ValueEnum)]
pub enum Format {
    Pdf,
    Docx,
    Html,
    Rtf,
    Odt,
    Epub,
    Tex,
    Txt,
    Png,
}

impl Format {
    fn extension(self) -> &'static str {
        match self {
            Format::Pdf => "pdf",
            Format::Docx => "docx",
            Format::Html => "html",
            Format::Rtf => "rtf",
            Format::Odt => "odt",
            Format::Epub => "epub",
            Format::Tex => "tex",
            Format::Txt => "txt",
            Format::Png => "png",
        }
    }
}

fn utf8(path: &Path) -> Result<&str, String> {
    path.to_str()
        .ok_or_else(|| format!("{}: the path is not UTF-8", path.display()))
}

/// The page's look without the app's theme: system faces, a readable measure, light and dark.
const CSS: &str = "\
:root { color-scheme: light dark; }
body { font: 16px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; max-width: 42em; margin: 2em auto; padding: 0 1em; }
pre, code { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; }
pre { padding: 0.75em 1em; overflow-x: auto; background: rgba(127, 127, 127, 0.1); border-radius: 6px; }
blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid rgba(127, 127, 127, 0.4); }
table { border-collapse: collapse; }
th, td { border: 1px solid rgba(127, 127, 127, 0.4); padding: 0.3em 0.6em; }
img { max-width: 100%; }
";

pub fn run(file: &Path, format: Format, out: Option<&Path>) -> Result<(), String> {
    let source = fs::canonicalize(file).map_err(|error| format!("{}: {error}", file.display()))?;
    let out = match out {
        Some(out) => path::absolute(out).map_err(|error| format!("{}: {error}", out.display()))?,
        None => source.with_extension(format.extension()),
    };
    if fs::canonicalize(&out).is_ok_and(|out| out == source) {
        return Err(format!(
            "{}: the export would replace its own source",
            out.display()
        ));
    }
    match format {
        Format::Html => {
            let text = fs::read_to_string(&source)
                .map_err(|error| format!("{}: {error}", source.display()))?;
            let title = source.file_stem().unwrap_or_default().to_string_lossy();
            let page = export::html(
                &text,
                &ExportOptions {
                    title: &title,
                    css: CSS,
                    diagram: &|_| None,
                    math: &|_, _| None,
                    folder: source.parent(),
                },
            );
            fs::write(&out, page).map_err(|error| format!("{}: {error}", out.display()))
        }
        Format::Docx => {
            let text = fs::read_to_string(&source)
                .map_err(|error| format!("{}: {error}", source.display()))?;
            let folder = source.parent().unwrap_or(Path::new("/"));
            let bytes = export::docx::docx(&text, folder)
                .map_err(|error| format!("{}: {error}", source.display()))?;
            fs::write(&out, bytes).map_err(|error| format!("{}: {error}", out.display()))
        }
        _ => {
            let extension = format.extension();
            if out
                .extension()
                .is_none_or(|ending| !ending.eq_ignore_ascii_case(extension))
            {
                return Err(format!(
                    "{}: a .{extension} export has to end in .{extension}",
                    out.display()
                ));
            }
            Socket::find()?.export(utf8(&source)?, utf8(&out)?, extension)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn html_lands_beside_the_file_with_its_images_inlined() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("launch plan.md");
        fs::write(&file, "# Plan\n\n![dot](dot.png) <script>x</script>\n").unwrap();
        fs::write(dir.path().join("dot.png"), b"\x89PNG\r\n\x1a\nrest").unwrap();
        run(&file, Format::Html, None).unwrap();
        let page = fs::read_to_string(dir.path().join("launch plan.html")).unwrap();
        assert!(page.contains("<title>launch plan</title>"));
        assert!(page.contains("<h1>Plan</h1>"));
        assert!(page.contains("data:image/png;base64,"));
        assert!(!page.contains("<script>"));
        let out = dir.path().join("out/page.html");
        fs::create_dir(dir.path().join("out")).unwrap();
        run(&file, Format::Html, Some(&out)).unwrap();
        assert!(out.exists());
        assert!(run(&file, Format::Html, Some(&file)).is_err());
    }
}
