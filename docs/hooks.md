# Agent hooks

Dewline names an agent's change only when the agent's hooks report it (record 0007). `dewline doctor --install-hooks`, or Settings > Agents > Set Up Agent Hooks, installs them; `dewline doctor --remove-hooks`, or Remove beside an agent in Settings > Agents, takes them out of the user's settings, keeping a backup beside each file. `--agent claude`, `codex` or `cursor` limits either to one agent. Plain `dewline doctor` prints each entry `--install-hooks` would add. Dewline offers Set Up once for each folder that holds an agent's files (`.claude`, `.cursor`, `.codex`, `CLAUDE.md`, `AGENTS.md`), after the first change no hook named lands in a note open there. This page has them by hand. Each hook runs the `dewline` command inside the app by absolute path. It reads the event's JSON, sends Dewline the file's realpath and BLAKE3 hashes (never its content), writes nothing, and exits 0, at once when Dewline isn't running.

## Claude Code

Merge into `~/.claude/settings.json`, or a project's `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [{"matcher": "Read|Edit|MultiEdit|Write|Bash", "hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook claude"}]}],
    "PostToolUse": [{"matcher": "Read|Edit|MultiEdit|Write|Bash", "hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook claude"}]}],
    "PostToolUseFailure": [{"matcher": "Read|Edit|MultiEdit|Write|Bash", "hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook claude"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook claude"}]}],
    "StopFailure": [{"hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook claude"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook claude"}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook claude"}]}],
    "InstructionsLoaded": [{"hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook claude"}]}]
  }
}
```

The tool hooks name the file. An Edit, MultiEdit, Write or Codex apply_patch call holds the file's autosave from its PreToolUse to its PostToolUse (PostToolUseFailure when the call fails), at most 10 seconds. Read and InstructionsLoaded hold nothing. Bash sends its timing alone: a change that lands while a Bash command runs, or within a second after, stays unnamed and its mark says "During Claude Code's shell command" (record 0007: a hook can't say which bytes a command wrote). Hooks set up before Bash joined the matcher read as missing until Set Up widens it.

## Codex

Merge into `~/.codex/hooks.json`:

```json
{
  "hooks": {
    "PreToolUse": [{"matcher": "^apply_patch$", "hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook codex"}]}],
    "PostToolUse": [{"matcher": "^apply_patch$", "hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook codex"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook codex"}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook codex"}]}]
  }
}
```

Codex runs a new or changed hook only once you trust it: start Codex, open `/hooks` and trust each Dewline hook. `dewline doctor` says "needs trust" until `~/.codex/config.toml` records trust for each one; it can't tell a trusted hook that changed since. Set Up skips an agent whose folder (`~/.claude`, `~/.codex`, `~/.cursor`) doesn't exist.

A hook whose command names a `dewline` that no longer exists, as after the app moved, counts as missing. Set Up replaces its command with the app's current path.

## Cursor

Merge into `~/.cursor/hooks.json`:

```json
{
  "version": 1,
  "hooks": {
    "preToolUse": [{"matcher": "Write", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook cursor"}],
    "postToolUse": [{"matcher": "Write", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook cursor"}],
    "afterFileEdit": [{"command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook cursor"}],
    "stop": [{"command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook cursor"}]
  }
}
```

Dewline names two kinds of Cursor edit:

- A `cursor-agent` Write, from its `preToolUse` and `postToolUse`, which carry `tool_use_id` and `tool_input` `{file_path, content}`: named as Claude Code's Write is, when the file holds `content` after the call.
- An agent edit `afterFileEdit` reports, after the fact. The hook hashes the file, puts each hunk's old lines back where its new lines first appear, and sends both hashes. The change is named only when its bytes before and after match those two hashes, so a hunk put back in the wrong place, or a file written again since, names nothing.

Everything else Cursor writes shows as "Another app": Tab edits (`afterTabFileEdit`, not hooked), terminal commands, an edit that only deletes lines (its hunk has no new lines to place), and any edit `afterFileEdit` doesn't fire for.

What `afterFileEdit` carries, checked on 2026-11-17 against cursor.com/docs/agent/hooks and the source of the Cursor CLI (`cursor-agent` 2026.01.28-fd13201, `357.index.js`; no hook was installed or run):

- It fires after the agent's Write tool succeeds, the one local executor that writes a file, with the common `conversation_id` and `generation_id`, `file_path` (the tool's path) and `edits`. It has no `tool_use_id` and no hash. A failed or refused write fires none.
- `edits` is not what the model sent. The CLI reads the file before the write, then diffs it against the text written with no context lines: each hunk is one `{old_string, new_string}` of whole removed and added lines, with no position. A new file, or one over 256 KiB, is a single edit with an empty `old_string` and the whole text; an unchanged file is `[]`.
- The Cursor editor's agent is closed and may differ. Cursor staff confirmed (forum thread 156065, Cursor 2.6.21) that `afterFileEdit` there fires only for the first file of a multi-file edit and sometimes stops for the rest of a session.

## What stays Unknown

Bash edits stay Unknown. A hook around a shell command can't say which bytes the command wrote, so a change made by Claude Code's Bash tool, Codex's shell, Cursor's terminal, `codex exec`, or any edit that skips the hooks shows as "Another app". So does a tool call whose result `dewline notify` can't compute exactly, such as an Edit of a file that mixes CRLF and LF line endings or starts with a byte-order mark.
