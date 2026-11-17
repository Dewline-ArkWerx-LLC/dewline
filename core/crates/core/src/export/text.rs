//! Markdown as plain text: markers dropped, list bullets and numbers kept, tables as aligned columns, code, quotes and
//! display math indented, links followed by their address, images by their alt text.

use std::collections::HashMap;

use pulldown_cmark::{Alignment, Event, LinkType, Parser, Tag, TagEnd};

use super::{OPTIONS, code};

pub fn text(markdown: &str) -> String {
    let mut writer = Writer::default();
    let mut events = Parser::new_ext(markdown, OPTIONS);
    while let Some(event) = events.next() {
        match event {
            Event::Start(Tag::MetadataBlock(_)) => {
                code(&mut events);
            }
            Event::Start(Tag::Image { .. }) => {
                let alt = code(&mut events);
                writer.inline.push_str(&if alt.is_empty() {
                    "[image]".to_owned()
                } else {
                    format!("[image: {alt}]")
                });
            }
            event => writer.event(event),
        }
    }
    writer.flush();
    writer.out
}

#[derive(Default)]
struct Writer {
    out: String,
    /// The current block's text; a line break starts a new line.
    inline: String,
    /// The indent of each open quote, list item and code block, outermost first.
    indents: Vec<String>,
    /// A list item's bullet or number, written over its indent on the item's first line.
    marker: Option<String>,
    /// Each open list's next number, or `None` for bullets.
    lists: Vec<Option<u64>>,
    /// A blank line goes before the next line written.
    gap: bool,
    /// Each open link's address and where its text starts in `inline`.
    links: Vec<(String, usize)>,
    footnotes: HashMap<String, usize>,
    table: Option<Table>,
}

struct Table {
    columns: Vec<Alignment>,
    rows: Vec<Vec<String>>,
}

impl Writer {
    fn event(&mut self, event: Event<'_>) {
        match event {
            Event::Start(tag) => self.start(tag),
            Event::End(tag) => self.end(tag),
            Event::Text(text) | Event::Code(text) | Event::InlineMath(text) => {
                self.inline.push_str(&text)
            }
            Event::Html(html) | Event::InlineHtml(html) => self.inline.push_str(&html),
            Event::DisplayMath(tex) => {
                self.flush();
                self.indents.push("    ".into());
                self.inline.push_str(tex.trim());
                self.flush();
                self.indents.pop();
            }
            Event::FootnoteReference(label) => {
                let number = self.footnote(&label);
                self.inline.push_str(&format!("[{number}]"));
            }
            Event::SoftBreak => self.inline.push(' '),
            Event::HardBreak => self.inline.push('\n'),
            Event::Rule => {
                self.flush();
                self.line("----");
                self.gap = true;
            }
            Event::TaskListMarker(checked) => {
                self.inline.push_str(if checked { "[x] " } else { "[ ] " })
            }
        }
    }

    fn start(&mut self, tag: Tag<'_>) {
        match tag {
            Tag::BlockQuote(_) => {
                self.flush();
                self.indents.push("    ".into());
            }
            Tag::CodeBlock(_) => {
                self.flush();
                self.indents.push("    ".into());
            }
            Tag::List(start) => {
                self.flush();
                self.lists.push(start);
            }
            Tag::Item => {
                self.flush();
                let marker = match self.lists.last_mut() {
                    Some(Some(number)) => {
                        *number += 1;
                        format!("{}. ", *number - 1)
                    }
                    _ => "• ".into(),
                };
                self.indents.push(" ".repeat(marker.chars().count()));
                self.marker = Some(marker);
            }
            Tag::FootnoteDefinition(label) => {
                self.flush();
                let marker = format!("[{}] ", self.footnote(&label));
                self.indents.push(" ".repeat(marker.len()));
                self.marker = Some(marker);
            }
            Tag::DefinitionListDefinition => {
                self.flush();
                self.indents.push("    ".into());
            }
            Tag::Table(columns) => {
                self.flush();
                self.table = Some(Table {
                    columns,
                    rows: Vec::new(),
                });
            }
            Tag::TableHead | Tag::TableRow => {
                if let Some(table) = &mut self.table {
                    table.rows.push(Vec::new());
                }
            }
            Tag::Link {
                link_type,
                dest_url,
                ..
            } => {
                let shown =
                    !matches!(link_type, LinkType::WikiLink { .. }) && !dest_url.starts_with('#');
                self.links.push((
                    if shown {
                        dest_url.to_string()
                    } else {
                        String::new()
                    },
                    self.inline.len(),
                ));
            }
            _ => {}
        }
    }

    fn end(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::Paragraph
            | TagEnd::Heading(_)
            | TagEnd::HtmlBlock
            | TagEnd::DefinitionListTitle => {
                self.flush();
                self.gap |= self.lists.is_empty();
            }
            TagEnd::BlockQuote(_) | TagEnd::CodeBlock | TagEnd::DefinitionListDefinition => {
                self.flush();
                self.indents.pop();
                self.gap |= self.lists.is_empty();
            }
            TagEnd::Item | TagEnd::FootnoteDefinition => {
                self.flush();
                self.indents.pop();
                self.marker = None;
            }
            TagEnd::List(_) => {
                self.flush();
                self.lists.pop();
                self.gap |= self.lists.is_empty();
            }
            TagEnd::TableCell => {
                let cell = std::mem::take(&mut self.inline);
                if let Some(row) = self.table.as_mut().and_then(|table| table.rows.last_mut()) {
                    row.push(cell.trim().to_owned());
                }
            }
            TagEnd::Table => {
                if let Some(table) = self.table.take() {
                    self.table_lines(&table);
                }
                self.gap |= self.lists.is_empty();
            }
            TagEnd::Link => {
                if let Some((address, start)) = self.links.pop() {
                    let text = &self.inline[start..];
                    let mail = address.strip_prefix("mailto:");
                    if !address.is_empty() && text != address && mail != Some(text) {
                        self.inline.push_str(&format!(" ({address})"));
                    }
                }
            }
            _ => {}
        }
    }

    fn footnote(&mut self, label: &str) -> usize {
        let next = self.footnotes.len() + 1;
        *self.footnotes.entry(label.to_owned()).or_insert(next)
    }

    /// Writes the current block's text, one line per line break; a code block keeps its blank lines.
    fn flush(&mut self) {
        let text = std::mem::take(&mut self.inline);
        let text = text.trim_end_matches('\n');
        if text.trim().is_empty() {
            return;
        }
        for line in text.split('\n') {
            self.line(line);
        }
    }

    fn line(&mut self, line: &str) {
        if self.gap && !self.out.is_empty() {
            self.out.push('\n');
        }
        self.gap = false;
        let mut prefix = self.indents.concat();
        if let Some(marker) = self.marker.take() {
            let last = self.indents.last().map_or(0, String::len);
            prefix.truncate(prefix.len() - last);
            prefix.push_str(&marker);
        }
        let line = format!("{prefix}{line}");
        self.out.push_str(line.trim_end());
        self.out.push('\n');
    }

    /// The table as columns two spaces apart, each as wide as its widest cell, with a rule under the header.
    fn table_lines(&mut self, table: &Table) {
        let count = table.rows.iter().map(Vec::len).max().unwrap_or(0);
        let widths: Vec<usize> = (0..count)
            .map(|column| {
                table
                    .rows
                    .iter()
                    .filter_map(|row| row.get(column))
                    .map(|cell| cell.chars().count())
                    .max()
                    .unwrap_or(0)
            })
            .collect();
        let row_line = |row: &[String]| {
            (0..count)
                .map(|column| {
                    let cell = row.get(column).map_or("", String::as_str);
                    let space = widths[column] - cell.chars().count();
                    let before = match table.columns.get(column) {
                        Some(Alignment::Right) => space,
                        Some(Alignment::Center) => space / 2,
                        _ => 0,
                    };
                    format!("{}{cell}{}", " ".repeat(before), " ".repeat(space - before))
                })
                .collect::<Vec<_>>()
                .join("  ")
        };
        for (index, row) in table.rows.iter().enumerate() {
            let line = row_line(row);
            self.line(&line);
            if index == 0 {
                let rule = widths
                    .iter()
                    .map(|&width| "-".repeat(width))
                    .collect::<Vec<_>>()
                    .join("  ");
                self.line(&rule);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markers_go_and_lists_keep_their_bullets_and_numbers() {
        let out = text(
            "---\ntitle: x\n---\n# Plan\n\nSome **bold** and *it* with `code` and ~~gone~~.\n\n\
             - one\n- two\n  - nested\n\n3. third\n4. fourth\n\n- [x] done\n",
        );
        assert_eq!(
            out,
            "Plan\n\nSome bold and it with code and gone.\n\n• one\n• two\n  • nested\n\n3. third\n4. fourth\n\n\
             • [x] done\n"
        );
    }

    #[test]
    fn tables_align_their_columns() {
        let out =
            text("| Name | Qty | Mid |\n|:--|--:|:-:|\n| apple | 3 | x |\n| kiwi | 120 | yy |\n");
        assert_eq!(
            out,
            "Name   Qty  Mid\n-----  ---  ---\napple    3   x\nkiwi   120  yy\n"
        );
    }

    #[test]
    fn code_quotes_math_links_images_and_footnotes_read_as_text() {
        let out = text(
            "> quoted\n\n```rust\nfn a() {}\n\n  b\n```\n\n$$x^2$$\n\nSee [docs](https://x.dev), <https://y.dev>, \
             [[note|the note]] and ![a dot](dot.png)[^n].\n\n[^n]: A note.\n",
        );
        assert_eq!(
            out,
            "    quoted\n\n    fn a() {}\n\n      b\n\n    x^2\n\nSee docs (https://x.dev), https://y.dev, the note and \
             [image: a dot][1].\n\n[1] A note.\n"
        );
    }
}
