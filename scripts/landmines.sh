#!/usr/bin/env bash
# The testing rules of interfere-inc/landmines, ported to the Swift and Rust tests: no fixed sleeps, no flake masking,
# no wall-clock asserts. A call to a function in the same file whose body sleeps, itself or through another such call,
# counts as a sleep, so a helper such as settle() or until {} counts at each call. scripts/landmines.allow holds each
# file's exact count of the violations it had when a rule came in; a file over its count fails, and so does one under
# it, so the list only shrinks.
# Usage: scripts/landmines.sh
set -euo pipefail

cd "$(dirname "$0")/.."
allow=scripts/landmines.allow

exempt=$(awk '$2 == "exempt" { print $1 }' "$allow")
files=$(
    {
        find app/DewlineTests Packages -name '*.swift' \( -path 'app/DewlineTests/*' -o -path 'Packages/*/Tests/*' \)
        find core/crates -name '*.rs' -not -path '*/target/*'
        find .github/workflows -name '*.yml'
        find scripts -name '*.sh' -not -name landmines.sh
    } | grep -vxF -e "$exempt" | sort
)

# One line per violation: rule, path, line, text.
hits=$(
    # shellcheck disable=SC2086
    awk '
    function report(rule, line, text) {
        sub(/^[ \t]+/, "", text)
        printf "%s\t%s\t%d\t%s\n", rule, FILENAME, line, text
    }
    # Each call to a function of the file that sleeps, once every sleeping function is known.
    function helpers(   n, changed) {
        do {
            changed = 0
            for (n = 1; n <= calls; n++) {
                if ((called[n] in sleeps) && caller[n] != "" && !(caller[n] in sleeps)) { sleeps[caller[n]] = 1; changed = 1 }
            }
        } while (changed)
        for (n = 1; n <= calls; n++) {
            if (called[n] in sleeps) printf "no-fixed-sleep\t%s\t%d\t%s() sleeps: %s\n", file, at[n], called[n], said[n]
        }
        split("", sleeps); calls = 0
    }
    function assertion(text, from, measured) {
        if (text !~ / (<|>|<=|>=) /) return
        measured = "elapsed|ContinuousClock|clock\\.now|Instant::now|\\.(milli|micro|nano)?seconds\\(|Duration::from_|as_(secs|millis|micros|nanos)\\("
        if (timers != "") measured = measured "|(^|[^A-Za-z0-9_])(" timers ")([^A-Za-z0-9_]|$)"
        if (text ~ measured) report("no-wall-clock-asserts", from, text)
    }
    FNR == 1 {
        helpers(); file = FILENAME; braces = 0; top = 0
        kind = (FILENAME ~ /\.(swift|rs)$/) ? "test" : "ci"
        inside = (FILENAME !~ /\.rs$/ || FILENAME ~ /\/tests\// || FILENAME ~ /\/tests\.rs$/)
        armed = 0; depth = 0; buffer = ""; timers = ""
    }
    kind == "ci" {
        if ($0 !~ /^[ \t]*#/ && $0 ~ /retry-tests-on-failure|test-iterations|--retries/) report("no-flake-masking", FNR, $0)
        next
    }
    !inside {
        if (armed && $0 ~ /^[ \t]*(pub(\(crate\))? )?mod [A-Za-z_]+ \{/) inside = 1
        armed = $0 ~ /^[ \t]*#\[cfg\(test\)\][ \t]*$/
        next
    }
    $0 ~ /^[ \t]*\/\// { next }
    {
        # The function each line is in: a stack of declarations, each popped when the braces it opened close.
        line = $0
        opens = gsub(/\{/, "", line); closes = gsub(/\}/, "", line)
        declared = ""
        if (match($0, /(^|[^A-Za-z0-9_])(func|fn) [A-Za-z_][A-Za-z0-9_]*/)) {
            declared = substr($0, RSTART, RLENGTH); sub(/^.*(func|fn) /, "", declared)
            if (top && !opened[top] && base[top] == braces) top--
            fns[++top] = declared; base[top] = braces; opened[top] = 0
        }
        if ($0 ~ /Thread\.sleep|usleep\(|Task\.sleep|\.run\(until:|before: Date\(timeIntervalSinceNow|asyncAfter\(|thread::sleep|time::sleep\(|(^|[^.:A-Za-z_])sleep\(/) {
            report("no-fixed-sleep", FNR, $0)
            if (top) sleeps[fns[top]] = 1
        }
        rest = $0
        while (match(rest, /(^|[^A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*[ \t]*[({]/)) {
            callee = substr(rest, RSTART, RLENGTH); before = substr(rest, 1, RSTART); rest = substr(rest, RSTART + RLENGTH)
            sub(/^[^A-Za-z_]/, "", callee); sub(/[ \t]*[({]$/, "", callee)
            if (callee == declared || (top && callee == fns[top])) continue
            # A static function of another type, such as MainWindowController.resume, is no helper of this file.
            if (before ~ /(^|[^A-Za-z0-9_])[A-Z][A-Za-z0-9_]*\.$/ && before !~ /(^|[^A-Za-z0-9_])Self\.$/) continue
            calls++; called[calls] = callee; caller[calls] = top ? fns[top] : ""; at[calls] = FNR
            said[calls] = $0; sub(/^[ \t]+/, "", said[calls])
        }
        braces += opens - closes
        if (top && braces > base[top]) opened[top] = 1
        while (top && braces <= base[top] && (opened[top] || opens)) top--
        if ($0 ~ /\.timeLimit\(|executionTimeAllowance|for (attempt|retry|tries|rerun)[A-Za-z]* in /)
            report("no-flake-masking", FNR, $0)
        if (match($0, /(let|var) (mut )?[A-Za-z_][A-Za-z0-9_]* = /) && $0 ~ /\.elapsed\(\)|\.measure \{|ContinuousClock\.now - |clock\.now - /) {
            name = substr($0, RSTART, RLENGTH)
            sub(/^(let|var) (mut )?/, "", name); sub(/ = $/, "", name)
            timers = timers == "" ? name : timers "|" name
        }
        if (depth == 0 && $0 ~ /#expect\(|#require\(|XCTAssert[A-Za-z]*\(|assert(_eq|_ne)?!\(/) { buffer = ""; from = FNR; depth = 0.5 }
        if (depth > 0) {
            buffer = buffer " " $0
            line = $0
            depth += gsub(/\(/, "", line) - gsub(/\)/, "", line)
            if (depth < 1 || FNR - from > 20) { depth = 0; assertion(buffer, from) }
        }
    }
    END { helpers() }
    ' $files
)

# The verdict: every file over or under its count in the allowlist.
printf '%s\n' "$hits" | awk -F '\t' -v allow="$allow" -v actions="${GITHUB_ACTIONS:-}" '
BEGIN {
    advice["no-fixed-sleep"] = "Replace this fixed sleep with a signal: await the operation itself, or the notification, continuation, callback or confirmation it ends with. To move time, inject a clock and advance it. A poll loop is the same sleep. A sleep guesses how long real work takes and fails under CI load."
    advice["no-flake-masking"] = "Do not retry tests or raise their time limits. A test that passes on rerun is a flake: wait on the event it depends on and fix the cause."
    advice["no-wall-clock-asserts"] = "Do not assert measured wall-clock time outside the measurement suites: a CI runner is slower and noisier than any budget. Assert the outcome, or inject a clock and assert on its readings. Budgets belong in PerfTests and perf/."
    while ((getline entry < allow) > 0) {
        if (entry ~ /^[ \t]*(#|$)/) continue
        split(entry, field, /[ \t]+/)
        if (field[2] == "exempt") {
            if (system("test -e \"" field[1] "\"") != 0) problem(allow ": " field[1] " is exempt but does not exist; delete its entry.")
            continue
        }
        if (!(field[2] in advice) || field[3] !~ /^[0-9]+$/) { problem(allow ": cannot read \"" entry "\""); continue }
        key = field[1] SUBSEP field[2]
        if (!(key in allowed)) order[++keys] = key
        allowed[key] = field[3]
    }
}
function problem(message) {
    print message
    if (actions == "true") print "::error::" message
    failed = 1
}
NF == 4 {
    key = $2 SUBSEP $1
    if (!(key in allowed) && !(key in found)) order[++keys] = key
    found[key]++
    listed[key] = listed[key] sprintf("  %s:%d: %s\n", $2, $3, $4)
    if (actions == "true") annotations[key] = annotations[key] sprintf("::error file=%s,line=%d,title=%s::%s\n", $2, $3, $1, advice[$1])
}
END {
    for (n = 1; n <= keys; n++) {
        key = order[n]
        split(key, part, SUBSEP)
        count = found[key] + 0; limit = allowed[key] + 0
        if (count > limit) {
            printf "%s: %d %s, %d allowed\n%s  %s\n", part[1], count, part[2], limit, listed[key], advice[part[2]]
            printf "%s", annotations[key]
            failed = 1
        } else if (count < limit) {
            problem(part[1] " now has " count " " part[2] "; lower its entry in " allow " to " count (count ? "." : ", that is, delete it."))
        }
    }
    if (failed) exit 1
    print "landmines.sh: no file has more fixed sleeps, flake masking or wall-clock asserts than " allow " allows"
}
'
