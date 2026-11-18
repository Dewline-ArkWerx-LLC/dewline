# 0008: Code highlighting

Date: 2026-10-30. Decided by research (26 Oct), as the owner authorized.

| Decision | Choice | Reopens if |
|---|---|---|
| Engine | syntect 5.3.0 with the onig backend, on one Rust worker thread that owns the syntaxes and each block's per-line parse states, so an edit reparses from its first changed line. | syntect's next release lands #706, or a syntax we ship needs `branch` (syntect cannot run current Sublime packages) |
| Syntaxes | 69 in `app/Dewline/Syntaxes.packdump` (576 KB), an uncompressed newline dump loaded with `from_uncompressed_dump_file`: 55 fence languages from bat 0.26.1 through two-face 0.5.2 (pinned) and what they embed, without plain JavaScript (#706). `scripts/syntaxes` cuts it from two-face and checks every kept syntax parses as it does there. Fence words follow GitHub Linguist's names and aliases (16 Nov 2026). | users ask for a language we lack |
| Diff and markdown | Highlighted in `core::highlight` without syntect; markdown goes through `core::md`. | a fence language needs grammar the prefixes and tokens cannot give |
| Across the FFI | Spans as (start, end, class) in UTF-16 offsets; Swift maps the 14 classes to the heading token and 9 code tokens derived from each theme's link, accent, ink2 and heading. | a theme needs its own code colors |
| In the editor | Colors are TextKit 2 rendering attributes set in the layout manager's validator, so a result redraws without layout. Fenced code is monospaced; a language without a syntax stays plain. | a result that lands redraws nothing until the next layout |
| Pathological lines | A line with over 2,000 scope changes stays plain (the mdmost PR #21 budget), a line over 16 KB is not parsed, and a line that takes over 30 ms leaves the rest of its block plain. | real files trip the budget |

**#706.** syntect 5.3.0 still loops forever on two contexts that `set` each other without consuming input; the fix is merged upstream but unreleased. We do not vendor a fork. A time cap cannot stop a `parse_line` that never returns, so the guard is the data: the known trigger, `x /*` in older JavaScript, is left out of the dump, and a test runs every shipped syntax over that line and other unclosed and nested ones. A loop the dump still hides would pin the highlight worker, never the main thread, and leave code plain.

**Size.** The 16-language dump added 0.13 MB compressed and the 69-syntax one 0.49 MB; the arm64 library grows 0.65 MB (0.25 MB compressed). A universal DMG grows about 0.6 to 0.7 MB.
