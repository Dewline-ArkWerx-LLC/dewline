# 0010: Performance budgets for 0.1.0

Date: 2026-11-02. Decided by the owner after perf pass 3 (#73).

Four of the plan's budgets were set before anything was measured. Three perf passes brought the rest under budget; these four sit at what macOS and TextKit allow on the owner's Mac (M4 Pro, macOS 27.2, perf.sh with the app in front). Each new ceiling sits just above the pass 3 run, so `perf/budgets.jq` still fails a regression.

| Budget | Was | Now | Pass 3 run | Why |
|---|---|---|---|---|
| Keystroke, 1 MB, p50 | 8 ms | 9.5 ms | 8.9 ms | Dewline's own code is about 0.5 ms of a keystroke; the rest is TextKit 2 layout, the Core Animation commit and AppKit's software glyph drawing into 64-bit pixels. |
| Cold launch, slowest of 3 | 300 ms | 750 ms | 715 ms | A near-empty AppKit app that opens a file takes about 315 ms cold here. A new copy's first launch costs about 10 ms per MB of bundle whether the code loads or not, and the Rust library is 16.5 MB per architecture. |
| Warm launch, median of 5 | 150 ms | 425 ms | 403 ms | The same near-empty app takes about 240 ms warm. Dewline adds about 100 ms, in pieces of 3 to 13 ms. |
| Open 1 MB | 50 ms | 85 ms | 80 ms | The first text draw in a process blocks 10 to 30 ms while Core Animation sets up Metal, and perf.sh's 1 MB open is that first draw. |

The other ten budgets are unchanged.

**2 Nov 2026, for 0.1.1.** The owner raised idle memory with a 10 MB document from 150 MB to 200 MB. The 0.1.1 run measured 186 MB, up from 132 MB at 0.1.0, after the redesign added the right pane (preview, agent and changes), link previews and the status bar. The 1 MB budget stays at 80 MB (69.8 MB measured). Work to bring the 10 MB footprint back down continues in its own PR. The owner also raised keystroke p50 at 1 MB from 9.5 ms to 10 ms; the 0.1.1 run measured 9.8 ms with a clock probe of 52.9 µs against 44.5 µs in the 0.1.0 run, so the CPU ran about 19% slower.

Reopens if: the memory work lands and the 10 MB footprint falls back near 132 MB, the Rust library loses a large dependency (Mermaid, Loro or the sync stack), which lowers cold launch; TextKit or AppKit changes the keystroke path; or a pass finds a piece of launch worth more than 20 ms.

**18 Nov 2026, E2: budgets CI measures.** The budgets above come from perf.sh on the owner's Mac and cover single files. release.yml's `perf` job now measures what they leave out, on the CI runner at every tag: `PerfTests.folderWindow` opens ten 16 KB notes from a git repository as the app opens a file, so they become ten tabs of one folder window with its sidebar, watchers and git status, then opens the 10 MB corpus in an eleventh tab. It times the ten tabs to styled, the 10 MB note from opening to styled, and the memory the window adds once idle. `scripts/perf-gate.sh` judges the result against `perf/ci-budgets.jq` beside verify's perf.sh gate (a `rehearse/v*` tag only warns), and release approval waits on it.

The runner is the `xcode-27` image, an Apple M1 (Virtual) with 3 cores and 7 GB, building the Test configuration. Fifteen runs on PR #154, five per round: A on main before #151 and #153, B the same with `SWIFT_OPTIMIZATION_LEVEL=-O` (about 20% off the 10 MB styling, too little to measure a build the app never ships), C on main after them. Each ceiling is the slowest run plus 50% for time and 25% for memory, rounded up; the ten-tab and memory ceilings take the slowest of all fifteen, the 10 MB ceiling round C's.

| Budget | A | B | C | Ceiling |
|---|---|---|---|---|
| 10 tabs open and styled | 1,398 to 2,832 ms | 1,855 to 4,624 ms | 1,947 to 3,546 ms | 7,000 ms |
| 10 MB opened in a tab, to styled | 15,064 to 19,462 ms | 11,542 to 16,392 ms | 21,834 to 28,792 ms | 44,000 ms |
| Memory the window adds, 10 tabs and 10 MB | 168.6 to 180.2 MB | 179.2 to 198.5 MB | 155.0 to 180.6 MB | 250 MB |

These are runner numbers, not what a user sees: the same 10 MB styling takes 2,250 ms on the owner's M4 Pro. Timings on the runner vary up to 3x between runs and memory about 15%, hence the wider margin on time. The job runs once per tag, as the first run after its build, which is usually the slowest. The 10 MB styling rose about 50% from A to C, across #151 (Source line numbers, H1 to H3 rail ticks) and #153 (core gitignores); that is not yet separated from runner noise.

Reopens if: the runner image changes hardware; W6 lands or the A-to-C rise is found and fixed (the 10 MB ceiling then comes down to its new slowest plus 50%); or the job fails a tag on noise alone.

**18 Nov 2026, Wave 4: nightly on main.** nightly.yml's `perf` job runs the tag measurement on main every night against `perf/ci-budgets.jq`, so a regression fails within a day of merging instead of at the next tag. The 10 MB ceiling comes down from 44,000 ms to 36,000 ms: the slowest of five runs of main's app code after #159 (16,433 to 29,891 ms; run 44429066227, each the first run after its build, as the jobs measure) plus 20%, rounded up. The ten-tab and memory ceilings stay; those runs measured 2,395 to 4,419 ms and 148.1 to 188.1 MB.

The ceilings are the comparison with main's numbers: each night is judged against main's measured slowest plus headroom, not against the night before. One run on the runner varies up to 3x from the next, so a night-to-night comparison would fail on noise; perf-ci.json's numbers stay in the job log (`jq .folderWindow`). A ceiling moves only through this record, when main's measured numbers move.

Reopens if: the nightly job fails on noise alone, or W6's 10 MB work lands and the slowest run falls.
