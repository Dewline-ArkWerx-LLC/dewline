# Budgets for what release.yml's perf job measures on the CI runner: PerfTests.folderWindow in the Test configuration,
# a folder window on a git repository with ten notes in tabs, then a 10 MB note opened in one more tab and styled. Each
# ceiling is the slowest of the CI runs in docs/decisions/0010-perf-budgets.md plus headroom, so the runner's noise
# passes and a regression fails. Same shape as perf/budgets.jq; scripts/perf-gate.sh judges with it.
def row($metric; $unit; $budget; $measured):
    {metric: $metric, unit: $unit, budget: $budget, measured: $measured,
     pass: (($measured | type) == "number" and $measured <= $budget)};

. + {budgets: [
    row("Folder window, 10 tabs open and styled"; "ms"; 7000; .folderWindow.tabsMs),
    row("Folder window, 10 MB opened in a tab, to styled"; "ms"; 44000; .folderWindow.styled10MBMs),
    row("Folder window, 10 tabs and 10 MB, memory added"; "MB"; 250; .folderWindow.footprintMB)
]} | .pass = all(.budgets[]; .pass)
