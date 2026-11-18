# Changelog

What changed in each Dewline release, newest first.

## 0.2.0 (18 Nov 2026)

Notes save themselves, undecided changes are never lost, and Dewline gains ten export formats and code highlighting in 50 languages. Live collaboration, the agent chat panel, Follow Changes, the Preview pane and the font catalog are gone.

- Closing a tab, quitting, sleeping the Mac or switching apps saves your notes with no save sheet. Typing without a pause saves within 10 seconds. When a save is refused, the status bar says why and offers Save Now, and the text is kept as a draft that reopening the note offers to restore. Symlinked notes save in place.
- Changes you have not decided on survive closing a tab and quitting, and reopening shows them at the same lines. A write to a closed note by another app, or while Dewline was quit, shows up as marked changes when you open it, and the sidebar badges the note with the writer and the count. Reading a note no longer credits an agent for someone else's later write.
- A new look: the window, toolbar, tab strip and sidebar are redrawn, with a new palette, Seravek for text and SF Mono for code. The scroller rail shows headings and waiting changes, each change is reviewed at the change, and the sidebar shows each file's git status.
- The keyboard moves through table cells, text zoom resizes the page, and images keep their original bytes. Copy as Markdown or HTML, and pasting rich HTML gives Markdown.
- Export to plain text, RTF, OpenDocument, EPUB, LaTeX, PNG and portable Markdown, besides PDF, Word and HTML. Portable Markdown turns wikilinks into relative links and copies images beside the file.
- Code blocks highlight 50 languages, in Quick Look too. Hovering a block shows its language and a Copy button. A Developer setting opens code files with the same highlighting.
- Find in Files takes regular expressions, a `path:` filter and a Replace field. Replace All asks first, counts what it changed, and is one undo in an open note.
- View > Sidebar Outline swaps the tree for the note's headings. Typing [[ lists the folder's notes. Renaming a note in the sidebar rewrites the links to it across the folder, and undo points them back. Backlinks come from the same link reader that `dewline mcp` uses.
- The `.claude`, `.cursor` and `.github` folders and `.mdc` files show in the tree, Quick Open and Find in Files. `dewline open <folder>` opens a folder in its window, and File > Open Recent lists recent folders and notes.
- Settings has four panes: General, Editor, Appearance and Agents. There are four themes: Tidewater and Onionskin for light, Nightwatch and Carbon for dark, and a retired theme becomes the nearest of these. Body, headings and code take any font on your Mac. Link previews stay off until you turn them on in Settings > Editor.
- File > Capture is the one place in the app that adds a line to your inbox. The Service, the App Intent, `dewline capture` and MCP work as before, and Settings > General holds the inbox path.
- Agent setup skips agents you have not installed and says when Codex needs to trust Dewline's hooks. Edits made with curly quotes or in CRLF files are matched, so more agent edits carry the agent's name, and a failed edit no longer delays the next change. A nightly test runs Claude Code and Codex against these checks.
- Removed: live collaboration is off for now, so Share, Join Shared Note and `dewline://join` are not in this build. The agent chat panel, Follow Changes, the Preview pane, the font catalog and installable fonts, the extra theme pack, and the daily note, Dock capture and capture shortcut are gone.
- Security fixes in the URL scheme and in LaTeX and EPUB export, for files and links that come from other people.
- Idle memory use is lower.

## 0.1.1 (2 Nov 2026)

A new look and a calmer window, a live preview, and a panel for your own coding agent.

- The window title names the open note and its folder. The sidebar starts at your folder's name, with + for a new note, and a native toolbar replaces the old top bar.
- Open the preview to see the note rendered on the right while you edit its Markdown on the left.
- Chat with your own coding agent beside the note. Dewline talks to it over the Agent Client Protocol, and its edits arrive marked, with Keep and Revert. Dewline ships no model and needs no account.
- Links are quieter. A link on its own line shows a preview card, and hovering a link shows one; Settings turns previews off.
- Which instruction files your agents read in a folder now shows in the status bar.
- Reopening a note brings you back to the same place in it.
- Sharing a note works again: the share popover opens, and join requests show in the status bar with Approve and Deny.
- `dewline export --to pdf` writes the PDF again.
- A new app icon, and headings use the system font by default.

## 0.1.0 (2 Nov 2026)

The first public build. Dewline is a native Markdown editor for Mac: it opens the .md files you already keep, in place, and renders them as you write. Links, embeds, math, diagrams, export and live collaboration are built in, and every save changes only what you edited. No account and no telemetry.

- Open any Markdown file and edit it in place. Syntax hides until the caret reaches it; tables, task boxes, footnotes, callouts and highlighted code render in the page, and math and Mermaid diagrams are drawn natively. Wikilinks, embeds and #tags follow Obsidian's syntax.
- Saves change only the bytes you edited, and never overwrite a newer version on disk. File > Snapshots restores an earlier version of the file. Export to HTML, PDF or DOCX, and preview .md files in Finder with Quick Look.
- Open a folder or an Obsidian vault in place. A sidebar for the folder and your agent files, tabs, Quick Open (Shift-Command-O), find in files (Shift-Command-F) and one palette for files, commands and settings (Shift-Command-P).
- Edit a file live with someone by invite link, peer to peer.
- Six themes plus a pack of four, installable fonts, Vim mode, a Source view, and focus and typewriter modes.
- When git, a sync app, a script or a coding agent changes the open file, Dewline marks each change, and names the agent when its hooks report it. Keep or revert each one, or all at once; Dewline snapshots the file first.
- `dewline open file.md:12 --wait` works as `$EDITOR`, `dewline notify` lets agent hooks name their edits, and `dewline mcp` serves a folder's notes to an agent.
