# Agent hooks

Dewline names an agent's change only when the agent's hooks report it (record 0007). `dewline doctor --install-hooks`, or Settings > Agents > Set Up All Hooks, installs them; this page has them by hand. Each hook runs the `dewline` command inside the app by absolute path. It reads the event's JSON, sends Dewline the file's realpath and BLAKE3 hashes (never its content), writes nothing, and exits 0, at once when Dewline isn't running.

## Claude Code

Merge into `~/.claude/settings.json`, or a project's `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [{"matcher": "Read|Edit|MultiEdit|Write", "hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook claude"}]}],
    "PostToolUse": [{"matcher": "Read|Edit|MultiEdit|Write", "hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook claude"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook claude"}]}],
    "StopFailure": [{"hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook claude"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook claude"}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook claude"}]}],
    "InstructionsLoaded": [{"hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook claude"}]}]
  }
}
```

The tool hooks name the file. Stop, StopFailure, UserPromptSubmit and SessionEnd end the autosave holds a session's tool calls put on its files; InstructionsLoaded holds a file the session loaded as instructions until the session ends.

## Codex

Merge into `~/.codex/hooks.json`:

```json
{
  "hooks": {
    "PreToolUse": [{"matcher": "^apply_patch$", "hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook codex"}]}],
    "PostToolUse": [{"matcher": "^apply_patch$", "hooks": [{"type": "command", "command": "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook codex"}]}]
  }
}
```

Codex runs a new or changed hook only once you trust it: start Codex, open `/hooks` and trust each Dewline hook. Dewline can't see that trust, so Settings shows Codex's hooks as Added, not Installed.

A hook whose command names a `dewline` that no longer exists, as after the app moved, counts as missing. Set Up replaces its command with the app's current path.

## Cursor

Dewline installs no Cursor hooks, and Cursor's edits show as "Another app" (record 0007). Rechecked on 2026-11-16: Cursor's hooks docs still give `tool_input` only for Shell, so a `preToolUse` for its `Write` tool can't declare what the edit wrote, and `afterFileEdit` carries the edit strings with no call id. Cursor hooks an earlier `dewline doctor --install-hooks` added to `~/.cursor/hooks.json` only report the end of each turn; delete them or leave them.

## What stays Unknown

Bash edits stay Unknown. A hook around a shell command can't say which bytes the command wrote, so a change made by Claude Code's Bash tool, Codex's shell, Cursor's terminal or agent, `codex exec`, or any edit that skips the hooks shows as "Unknown app". So does a tool call whose result `dewline notify` can't compute exactly, such as an Edit of a file with CRLF line endings.
