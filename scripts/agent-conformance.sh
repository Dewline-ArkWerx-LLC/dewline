#!/bin/bash
# Runs the real Claude Code and Codex over notes whose bytes test Dewline's copy of their edit tools (curly quotes,
# CRLF, a byte-order mark, replace_all, Write over CRLF, a patch of two files) and checks, from the lines
# `dewline notify` sends, that each PreToolUse's declared hash is the hash its PostToolUse found: the change gets a name.
# Everything runs in a temporary folder that is also the agents' HOME, so no user settings or notes are read or
# written. An agent is skipped when its CLI or API key (ANTHROPIC_API_KEY, OPENAI_API_KEY) is missing.
# Usage: scripts/agent-conformance.sh <dewline command>
set -euo pipefail

dewline=$(cd "$(dirname "${1:?usage: scripts/agent-conformance.sh <dewline command>}")" && pwd)/$(basename "$1")
work=$(mktemp -d)
listener=
cleanup() {
    if [[ -n $listener ]]; then
        kill "$listener"
        wait "$listener" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

agents=()
command -v claude >/dev/null && [[ -n ${ANTHROPIC_API_KEY:-} ]] && agents+=(claude) || echo "claude: skipped (no claude on PATH or no ANTHROPIC_API_KEY)"
command -v codex >/dev/null && [[ -n ${OPENAI_API_KEY:-} ]] && agents+=(codex) || echo "codex: skipped (no codex on PATH or no OPENAI_API_KEY)"
((${#agents[@]} > 0)) || exit 0

export HOME=$work/home DEWLINE_SOCKET=$work/control.sock
mkdir -p "$HOME"
# A stand-in for the app: each connection's bytes, appended to heard.jsonl.
python3 -I -c '
import socket, sys
server = socket.socket(socket.AF_UNIX)
server.bind(sys.argv[1])
server.listen(64)
with open(sys.argv[2], "ab", buffering=0) as heard:
    while True:
        connection, _ = server.accept()
        data = b""
        while chunk := connection.recv(65536):
            data += chunk
        connection.close()
        heard.write(data)
' "$DEWLINE_SOCKET" "$work/heard.jsonl" &
listener=$!
for _ in {1..50}; do [[ -S $DEWLINE_SOCKET ]] && break; sleep 0.1; done

# The hooks a user gets from Set Up, answered yes on a terminal of its own.
for agent in "${agents[@]}"; do mkdir -p "$HOME/.$agent"; done
python3 -I -c '
import os, subprocess, sys
main, side = os.openpty()
doctor = subprocess.Popen(sys.argv[2:], stdin=side, stdout=side, stderr=side)
os.close(side)
os.write(main, b"y\n" * int(sys.argv[1]))
try:
    while os.read(main, 4096):
        pass
except OSError:
    pass
sys.exit(doctor.wait())
' "${#agents[@]}" "$dewline" doctor --install-hooks
report=$("$dewline" doctor)
for title in "${agents[@]/claude/Claude Code}"; do
    grep -q "^  ${title/codex/Codex}: installed in " <<<"$report" || { echo "$report"; echo "Set Up left $title without hooks"; exit 1; }
done

# Each case: agent, file, expected result (named, or any where Dewline declares nothing on purpose), and the bytes.
cases=(
    "claude quotes.md named She said \xe2\x80\x9chello\xe2\x80\x9d and it\xe2\x80\x99s fine.\n"
    "claude crlf.md named one\r\ntwo\r\nthree\r\n"
    "claude bom.md any \xef\xbb\xbfalpha beta\n"
    "claude all.md named x y x y x\n"
    "claude write-crlf.md named old\r\nlines\r\n"
    "codex quotes.md named She said \xe2\x80\x9chello\xe2\x80\x9d and it\xe2\x80\x99s fine.\n"
    "codex crlf.md named one\r\ntwo\r\nthree\r\n"
    "codex bom.md any \xef\xbb\xbfalpha beta\n"
    "codex a.md named first\n"
    "codex b.md named second\n"
)
for case in "${cases[@]}"; do
    read -r agent name _ bytes <<<"$case"
    mkdir -p "$work/$agent"
    printf "$bytes" >"$work/$agent/$name"
done

claude_prompt='Make exactly these tool calls, in order, then stop. Use the Edit tool for edits and the Write tool for writes.
1. Read quotes.md, then Edit it with old_string She said "hello" (straight ASCII double quotes) and new_string She said "goodbye" (straight ASCII double quotes).
2. Read crlf.md, then Edit it with old_string two and new_string 2.
3. Read bom.md, then Edit it with old_string beta and new_string gamma.
4. Read all.md, then Edit it with old_string x, new_string z and replace_all true.
5. Read write-crlf.md, then Write it with the content "new" and "lines" on two lines, ending in a newline.'
codex_prompt='Make exactly these changes with the apply_patch tool, then stop. Run no shell commands.
1. In quotes.md, change She said "hello" to She said "goodbye", writing straight ASCII double quotes in the patch.
2. In crlf.md, change the line two to 2.
3. In bom.md, change beta to gamma.
4. In one apply_patch call, change first to 1st in a.md and second to 2nd in b.md.'

for agent in "${agents[@]}"; do
    echo "$agent: $("$agent" --version 2>&1 | head -n 1)"
    case $agent in
        claude)
            (cd "$work/claude" && claude -p "$claude_prompt" --permission-mode acceptEdits \
                --allowedTools Read Edit Write >"$work/claude.log" 2>&1) \
                || { echo "claude -p failed:"; tail -n 20 "$work/claude.log"; }
            ;;
        codex)
            printenv OPENAI_API_KEY | codex login --with-api-key >/dev/null
            codex exec --skip-git-repo-check --sandbox workspace-write --dangerously-bypass-hook-trust \
                -C "$work/codex" "$codex_prompt" >"$work/codex.log" 2>&1 \
                || { echo "codex exec failed:"; tail -n 20 "$work/codex.log"; }
            ;;
    esac
done
sleep 1

# A file is named when one call's PreToolUse declared the hash its PostToolUse found and the bytes changed.
printf '%s\n' "${cases[@]}" | python3 -I -c '
import json, os, sys
work, agents = sys.argv[1], sys.argv[2:]
calls = {}
for line in open(os.path.join(work, "heard.jsonl"), "rb").read().splitlines():
    if line.strip():
        claim = json.loads(line)
        if "tool_use_id" in claim and "path" in claim:
            key = (claim["vendor"], claim["tool_use_id"], claim["path"])
            calls.setdefault(key, {})[claim["event"]] = claim
failed = False
for case in sys.stdin.read().splitlines():
    agent, name, expected = case.split(" ")[:3]
    if agent not in agents:
        continue
    path = os.path.realpath(os.path.join(work, agent, name))
    pairs = [c for (vendor, _, p), c in calls.items() if vendor == agent and p == path and c.keys() == {"PreToolUse", "PostToolUse"}]
    pairs = [(c["PreToolUse"], c["PostToolUse"]) for c in pairs if c["PreToolUse"].get("hash") != c["PostToolUse"].get("hash")]
    if not pairs:
        result = "no change"
    elif any(pre.get("declared") is not None and pre.get("declared") != post.get("hash") for pre, post in pairs):
        result = "declared the wrong bytes"
    elif all(pre.get("declared") == post.get("hash") for pre, post in pairs):
        result = "named"
    else:
        result = "unnamed"
    ok = result == expected or (expected == "any" and result in ("named", "unnamed"))
    failed |= not ok
    print(f"{agent} {name}: {result}" + ("" if ok else f" (expected {expected})"))
sys.exit(1 if failed else 0)
' "$work" "${agents[@]}"
