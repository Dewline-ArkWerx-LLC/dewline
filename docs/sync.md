# Sync and mobile

Dewline has no sync service and no iPhone app. Notes are files, so the story is the folder's:

- Keep the folder in iCloud Drive, or in a git repo.
- On iPhone or iPad, edit notes from Files in iA Writer or another Markdown editor, or in Working Copy for a repo.
- Back on the Mac, Dewline marks each edit that arrived while you were away, with Keep and Revert. A write to a closed note, or one made while the app was quit, is in the engine's `closed_changes` and lands marked when the note opens (#123).

Welcome.md, `site/docs/sync/` and the landing page say this.

## What Dewline does in a synced folder

- **Saves.** A save is the engine's compare-and-swap (`core/crates/core/src/file.rs`): it writes nothing over bytes it has not seen, so a download that lands mid-save comes back as a change, not an overwrite. Saves are not file-coordinated yet: `LiveFile.save` takes `coordinatedWrite` (`app/Dewline/Sync.swift`) after the agents lane's `LiveFile.swift` work merges. Until then only the version switch below is coordinated, and I1, I10 and F1 test the uncoordinated save.
- **Downloads.** A sync client's write is an outside write: it lands as a change from Another app, marked.
- **iCloud conflict versions.** When iCloud keeps a second version of an open note (`NSFileVersion` unresolved conflicts), Dewline asks "iCloud has two versions of “Plan.md”" with the other version's device and time: Keep This Version, or Use the Other Version. Using it replaces the file in a coordinated write, and the engine lands the switch as a marked change, so Revert brings the text back. Either choice marks that version resolved and lets the system discard it. It asks when the version arrives (`presentedItemDidGain`) and when the note's window shows. Code: `app/Dewline/Sync.swift`.
- **Other sync apps.** Dropbox, Google Drive and OneDrive write a second version as a separate file ("Plan (conflicted copy).md"), which shows in the sidebar as a note.

## Device test

Run on a Mac signed in to iCloud with iCloud Drive on, an iPhone on the same Apple ID with iA Writer installed, and one File Provider folder: Google Drive for desktop in Stream mode, or Dropbox, under `~/Library/CloudStorage`. Use a test folder, not real notes. Record each result as pass, fail (with what happened) or not run.

### iCloud Drive

Make `iCloud Drive/Dewline Test` and open it in Dewline (⌥⌘O).

| # | Step | Expect | Result |
|---|---|---|---|
| I1 | New note `Sync.md`, type a line, wait 5 s | The line shows on the iPhone in Files and iA Writer within a minute | |
| I2 | With `Sync.md` open on the Mac, add a line on the iPhone | The line lands in the open note, marked from Another app, with Keep and Revert | |
| I3 | Close the note's tab, edit on the iPhone, wait for the Mac to download | Changes list (⇧⌘R) lists `Sync.md`; opening it shows the edit marked | |
| I4 | Quit Dewline, edit on the iPhone, wait, relaunch and open the note | The edit is marked | |
| I5 | iPhone in Airplane Mode: edit the first paragraph. On the Mac, edit the same paragraph with the note open and wait for the save. Turn Airplane Mode off | A sheet: "iCloud has two versions of “Sync.md”", naming the iPhone and a time | |
| I6 | In I5's sheet, click Use the Other Version | The iPhone's text replaces the paragraph, marked; Revert brings the Mac's text back; no second sheet | |
| I7 | Repeat I5, click Keep This Version | The window keeps the Mac's text; the iPhone shows it after sync; no second sheet | |
| I8 | Repeat I5 with the note's tab closed, then open the note | The sheet comes up when the note opens | |
| I9 | In Finder, Remove Download on `Sync.md`, then open it in Dewline | The note opens with its full text (an evicted file is read with `O_NONBLOCK`, `engine.rs`; this is the step that proves it downloads) | |
| I10 | Type in a note for 30 s, wait, then list the folder in Terminal: `ls -a` | No `.dewline.*.tmp` files are left; iCloud shows no extra copies | |

### File Provider folder

Make `Dewline Test` in the Google Drive or Dropbox folder and open it in Dewline.

| # | Step | Expect | Result |
|---|---|---|---|
| F1 | New note `Sync.md`, type a line, wait 5 s | The web view or a second device shows the line; no `.dewline.*.tmp` file is uploaded | |
| F2 | With the note open, edit it on the web or a second device | The edit lands in the open note, marked from Another app | |
| F3 | Make the file online-only, then open it in Dewline | The note opens with its full text | |
| F4 | Edit the note offline on two devices, then reconnect both | The client's conflicted copy shows in the sidebar as its own note; Dewline shows no sheet | |
