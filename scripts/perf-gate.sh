#!/bin/bash
# The perf gate in release.yml's verify job: judges a perf.sh result against perf/budgets.jq. A v* tag fails when the
# file is missing or misses a budget. A rehearse/v* tag only warns (owner decision D26), so signing, notarization and
# feed signing can be rehearsed before the budgets hold. Missed budgets go to the job summary when there is one.
# A v* tag with no result passes with a warning when perf/<version>.waived holds the owner's reason for shipping
# unmeasured; the log and the job summary say the gate was waived and why. The budgets are perf/budgets.jq unless a
# third argument names another file, as release.yml's perf job does with perf/ci-budgets.jq.
# Usage: scripts/perf-gate.sh <perf/<version>.json> <tag> [budgets.jq]
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
usage="usage: scripts/perf-gate.sh <perf/<version>.json> <tag> [budgets.jq]"
result=${1:?$usage}
tag=${2:?$usage}
budgets=${3:-$root/perf/budgets.jq}

verdict() { # message
    if [[ $tag == rehearse/* ]]; then
        echo "::warning::$1 (advisory for rehearse/ tags)"
        exit 0
    fi
    echo "::error::$1"
    exit 1
}

waiver=${result%.json}.waived
if [[ ! -f $result && -s $waiver ]]; then
    reason=$(head -1 "$waiver")
    echo "::warning title=Perf gate waived::No budget was checked: $result is missing and $waiver waives it. Reason: $reason"
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
        printf '### Perf gate waived\n\nNo budget was checked: %s is missing and %s waives it.\n\n> %s\n' \
            "$result" "$waiver" "$reason" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
fi
[[ -f $result ]] || verdict "$result is missing (scripts/perf.sh writes it)"
judged=$(jq -f "$budgets" "$result") || verdict "$result is not perf.sh's JSON"
if jq -e .pass <<< "$judged" > /dev/null; then
    echo "perf-gate.sh: $result holds every budget in ${budgets#"$root"/}"
    exit 0
fi
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    jq -r '"### Missed perf budgets", "", "| Budget | Ceiling | Measured |", "|---|---|---|",
        (.budgets[] | select(.pass | not) | "| \(.metric) | \(.budget) \(.unit) | \(.measured // "missing") \(.unit) |")' \
        <<< "$judged" >> "$GITHUB_STEP_SUMMARY"
fi
verdict "$result misses budgets: $(jq -r '[.budgets[] | select(.pass | not) | .metric] | join("; ")' <<< "$judged")"
