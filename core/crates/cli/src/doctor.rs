//! `dewline doctor`: whether the app matches this command, whether the agent hooks of docs/hooks.md are installed,
//! for the user or in the current folder's project files, and which companion tools are on PATH. `--install-hooks` merges the hooks in, asking first;
//! `--remove-hooks` takes them out of the user's settings, asking first.

use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use dewline_core::{file, links};
use serde_json::{Map, Value, json};

use crate::control::enclosing_app;

/// An agent whose hooks call `dewline notify --hook <name>`.
struct Agent {
    name: &'static str,
    title: &'static str,
    /// The settings file, relative to the home folder.
    settings: &'static str,
    /// A project's own files, relative to its folder, which the agent reads beside `settings` when it runs there.
    project: &'static [&'static str],
    /// Each hook event, with the tool matcher it takes.
    events: &'static [(&'static str, Option<&'static str>)],
    /// Cursor's shape: each event a list of `{"command"}` with no groups, under `"version": 1`.
    flat: bool,
}

/// Bash for its timing alone: a change that lands during a shell command says so.
const TOOLS: &str = "Read|Edit|MultiEdit|Write|Bash";

const AGENTS: [Agent; 3] = [
    Agent {
        name: "claude",
        title: "Claude Code",
        settings: ".claude/settings.json",
        project: &[".claude/settings.json", ".claude/settings.local.json"],
        events: &[
            ("PreToolUse", Some(TOOLS)),
            ("PostToolUse", Some(TOOLS)),
            ("PostToolUseFailure", Some(TOOLS)),
            ("Stop", None),
            ("StopFailure", None),
            ("UserPromptSubmit", None),
            ("SessionEnd", None),
            ("InstructionsLoaded", None),
        ],
        flat: false,
    },
    Agent {
        name: "codex",
        title: "Codex",
        settings: ".codex/hooks.json",
        project: &[".codex/hooks.json"],
        events: &[
            ("PreToolUse", Some("^apply_patch$")),
            ("PostToolUse", Some("^apply_patch$")),
            ("Stop", None),
            ("SessionEnd", None),
        ],
        flat: false,
    },
    Agent {
        name: "cursor",
        title: "Cursor",
        settings: ".cursor/hooks.json",
        project: &[".cursor/hooks.json"],
        events: &[
            ("preToolUse", Some("Write")),
            ("postToolUse", Some("Write")),
            ("afterFileEdit", None),
            ("stop", None),
        ],
        flat: true,
    },
];

/// Each companion's command and its Homebrew formula.
const COMPANIONS: [(&str, &str); 6] = [
    ("pandoc", "pandoc"),
    ("typst", "typst"),
    ("latexmk", "--cask mactex"),
    ("tectonic", "tectonic"),
    ("vale", "vale"),
    ("harper-ls", "harper"),
];

/// What `dewline doctor` does to the agent hooks.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Hooks {
    Check,
    Install,
    Remove,
}

/// Checks, installs or removes the hooks of every agent, or of the agent named `only`.
pub fn run(hooks: Hooks, only: Option<&str>) -> Result<(), String> {
    let home = env::home_dir().ok_or("there is no home folder")?;
    // SAFETY: isatty only inspects the descriptor.
    if hooks != Hooks::Check && unsafe { libc::isatty(0) } != 1 {
        return Err("doctor asks before it changes a file, so it needs a terminal".into());
    }
    let exe = env::current_exe()
        .and_then(fs::canonicalize)
        .map_err(|error| format!("this command's path: {error}"))?;
    if hooks == Hooks::Install && misplaced(&exe) {
        return Err(format!(
            "this command runs from {}, which is gone once the disk image ejects or the app quits; move Dewline to Applications and set up the hooks from there",
            exe.display()
        ));
    }

    let app = enclosing_app(&exe).map_or_else(
        || PathBuf::from("/Applications/Dewline.app"),
        Path::to_path_buf,
    );
    let cli = env!("CARGO_PKG_VERSION");
    match app_version(&app) {
        Some(version) if version == cli => println!("Version: app and command are both {cli}"),
        Some(version) => println!(
            "Version: the app at {} is {version} but this command is {cli}; use the command inside the app",
            app.display()
        ),
        None => println!(
            "Version: this command is {cli}; no app at {}",
            app.display()
        ),
    }

    let command = format!("{} notify --hook", quoted(&exe));
    // The project the agents run in, when they run here.
    let project = env::current_dir().ok();
    println!("\nAgent hooks:");
    for agent in AGENTS
        .iter()
        .filter(|agent| only.is_none_or(|name| name == agent.name))
    {
        let path = home.join(agent.settings);
        let folder = path.parent().expect("a settings file is in a folder");
        let settings = match read(&path) {
            Ok(settings) => settings,
            Err(error) => {
                println!("  {}: {error}", agent.title);
                continue;
            }
        };
        if hooks == Hooks::Remove {
            remove_hooks(agent, &path, settings)?;
            continue;
        }
        let mut files: Vec<(PathBuf, Value)> = settings
            .iter()
            .map(|(value, _)| (path.clone(), value.clone()))
            .collect();
        for file in agent
            .project
            .iter()
            .filter_map(|file| Some(project.as_ref()?.join(file)))
        {
            match read(&file) {
                Ok(Some((value, _))) if file != path => files.push((file, value)),
                Ok(_) => {}
                Err(error) => println!("  {}: {error}", agent.title),
            }
        }
        if let Some((file, _)) = files
            .iter()
            .find(|(_, value)| value["disableAllHooks"] == true)
        {
            println!(
                "  {}: hooks off; disableAllHooks is set in {}",
                agent.title,
                file.display()
            );
            continue;
        }
        let installed = files
            .iter()
            .find(|(_, value)| missing(Some(value), agent, runs).is_empty());
        if let Some((file, settings)) = installed {
            let config = fs::read_to_string(folder.join("config.toml"))
                .ok()
                .and_then(|text| text.parse::<toml::Table>().ok());
            let trusted = agent.name != "codex"
                || trusted(settings, agent, &file.to_string_lossy(), config.as_ref());
            println!(
                "  {}: installed in {}{}",
                agent.title,
                file.display(),
                if trusted {
                    ""
                } else {
                    "; needs trust: in Codex, open /hooks and trust each Dewline hook"
                }
            );
        } else if !folder.is_dir() {
            println!("  {}: not installed; no {}", agent.title, folder.display());
        } else {
            let current = settings.as_ref().map(|(value, _)| value);
            let command = format!("{command} {}", agent.name);
            println!(
                "  {}: {} missing from {}",
                agent.title,
                missing(current, agent, runs).join(", "),
                path.display()
            );
            for entry in additions(current, agent, &command)? {
                println!("    {entry}");
            }
            if hooks == Hooks::Install {
                install_hooks(agent, &path, settings, &command)?;
            }
        }
    }
    if hooks == Hooks::Check {
        println!(
            "  `dewline doctor --install-hooks` merges the missing ones in, and `--remove-hooks` takes them out, asking first."
        );
    }

    println!("\nCompanions:");
    for (program, formula) in COMPANIONS {
        match on_path(program) {
            Some(path) => println!("  {program}: {}", path.display()),
            None => println!("  {program}: not installed; brew install {formula}"),
        }
    }
    Ok(())
}

/// True for a command on a disk image or in a copy macOS translocated, whose path a hook can't keep calling.
fn misplaced(exe: &Path) -> bool {
    exe.starts_with("/Volumes") || exe.to_string_lossy().contains("/AppTranslocation/")
}

fn app_version(app: &Path) -> Option<String> {
    let output = Command::new("/usr/bin/plutil")
        .args(["-extract", "CFBundleShortVersionString", "raw", "-o", "-"])
        .arg(app.join("Contents/Info.plist"))
        .output()
        .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

/// A settings file's JSON and bytes, or `None` when there is no file.
fn read(path: &Path) -> Result<Option<(Value, Vec<u8>)>, String> {
    match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(|value| Some((value, bytes)))
            .map_err(|error| format!("{} isn't JSON this can read: {error}", path.display())),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("{}: {error}", path.display())),
    }
}

/// The program of `command`, as a shell word, when `command` is a `dewline notify --hook <name>` hook of `agent`.
fn program<'a>(command: &'a str, agent: &Agent) -> Option<&'a str> {
    if !command.contains("dewline") {
        return None;
    }
    let suffix = format!(" notify --hook {}", agent.name);
    command.trim_end().strip_suffix(&suffix).map(str::trim)
}

/// Whether `program`, a hook command's first word, can run. A path, bare or quoted as `quoted` quotes it, must name an
/// executable file; any other word resolves in the agent's shell, which this can't see, so it counts.
fn runs(program: &str) -> bool {
    let path = match program
        .strip_prefix('\'')
        .and_then(|word| word.strip_suffix('\''))
    {
        Some(inner) => inner.replace(r"'\''", "'"),
        None => program.to_owned(),
    };
    !path.starts_with('/')
        || fs::metadata(&path)
            .is_ok_and(|info| info.is_file() && info.permissions().mode() & 0o111 != 0)
}

/// A group's hooks: Claude Code and Codex list them under `"hooks"`; Cursor's group is one hook.
fn hooks<'a>(group: &'a Value, agent: &Agent) -> &'a [Value] {
    if agent.flat {
        return std::slice::from_ref(group);
    }
    group
        .get("hooks")
        .and_then(Value::as_array)
        .map_or(&[], Vec::as_slice)
}

/// The tools `matcher` names that `group`'s matcher leaves out, as alternatives in any order; none when it matches
/// every tool.
fn uncovered<'a>(group: &Value, matcher: &'a str) -> Vec<&'a str> {
    match group.get("matcher").and_then(Value::as_str) {
        None | Some("" | "*" | ".*") => Vec::new(),
        Some(have) => {
            let have: Vec<&str> = have.split('|').collect();
            matcher
                .split('|')
                .filter(|tool| !have.contains(tool))
                .collect()
        }
    }
}

/// Whether `group` runs for every tool `matcher` names.
fn covers(group: &Value, matcher: Option<&str>) -> bool {
    matcher.is_none_or(|matcher| uncovered(group, matcher).is_empty())
}

/// The events of `agent` with no hook calling `dewline notify --hook <name>` through a program that `runs`, in a group
/// whose matcher covers the event's tools. A hook whose program is gone, as after the app moved, is missing, and so
/// is one set up before the matcher took Bash.
fn missing(settings: Option<&Value>, agent: &Agent, runs: fn(&str) -> bool) -> Vec<&'static str> {
    let installed = |event: &str, matcher: Option<&str>| {
        settings
            .and_then(|settings| settings.pointer(&format!("/hooks/{event}")))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|group| covers(group, matcher))
            .flat_map(|group| hooks(group, agent))
            .filter_map(|hook| program(hook.get("command")?.as_str()?, agent))
            .any(runs)
    };
    agent
        .events
        .iter()
        .filter(|&&(event, matcher)| !installed(event, matcher))
        .map(|&(event, _)| event)
        .collect()
}

/// Whether Codex's `config` records trust for every Dewline hook in the hooks file at `file`, under the key Codex
/// gives a hook: the file, the event in snake case, and the hook's group and place in it. Codex voids trust when a
/// hook changes; a hook changed since it was trusted still counts here.
fn trusted(settings: &Value, agent: &Agent, file: &str, config: Option<&toml::Table>) -> bool {
    let state = config.and_then(|config| config.get("hooks")?.get("state")?.as_table());
    let Some(hooks) = settings.get("hooks").and_then(Value::as_object) else {
        return false;
    };
    hooks.iter().all(|(event, groups)| {
        let label: String = event
            .chars()
            .enumerate()
            .flat_map(|(i, c)| {
                let gap = (i > 0 && c.is_ascii_uppercase()).then_some('_');
                gap.into_iter().chain(c.to_lowercase())
            })
            .collect();
        groups
            .as_array()
            .into_iter()
            .flatten()
            .enumerate()
            .all(|(group, entry)| {
                entry["hooks"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .enumerate()
                    .all(|(handler, hook)| {
                        let ours = hook["command"]
                            .as_str()
                            .is_some_and(|command| program(command, agent).is_some());
                        let key = format!("{file}:{label}:{group}:{handler}");
                        !ours
                            || state
                                .and_then(|state| state.get(&key)?.get("trusted_hash")?.as_str())
                                .is_some()
                    })
            })
    })
}

/// `settings` with a hook running `command` for each of `agent`'s events that lacks one: a Dewline hook whose program
/// is gone gets `command`; a group of Dewline hooks only whose matcher is narrower gains the tools it lacks; a Dewline
/// hook sharing such a group with other hooks moves to a group of its own; and otherwise one is added. Every other key
/// and hook is kept as it was.
fn merge(
    settings: Option<&Value>,
    agent: &Agent,
    command: &str,
    runs: fn(&str) -> bool,
) -> Result<Value, String> {
    let missing = missing(settings, agent, runs);
    let mut settings = settings.cloned().unwrap_or_else(|| json!({}));
    let root = settings
        .as_object_mut()
        .ok_or("the settings aren't a JSON object")?;
    if agent.flat {
        root.entry("version").or_insert(json!(1));
    }
    let events = root
        .entry("hooks")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or("its \"hooks\" isn't a JSON object")?;
    for &(event, matcher) in agent.events {
        if !missing.contains(&event) {
            continue;
        }
        let groups = events
            .entry(event)
            .or_insert_with(|| json!([]))
            .as_array_mut()
            .ok_or_else(|| format!("its hooks for {event} aren't a JSON array"))?;
        let ours = |hook: &Value| {
            hook.get("command")
                .and_then(Value::as_str)
                .is_some_and(|old| program(old, agent).is_some())
        };
        if let Some(group) = groups
            .iter_mut()
            .find(|group| hooks(group, agent).iter().any(ours))
        {
            let lacks = matcher.map_or_else(Vec::new, |matcher| uncovered(group, matcher));
            if lacks.is_empty() || hooks(group, agent).iter().all(ours) {
                if !lacks.is_empty() {
                    let have = group["matcher"].as_str().unwrap_or_default();
                    group["matcher"] = json!(format!("{have}|{}", lacks.join("|")));
                }
                let hook = if agent.flat {
                    Some(group)
                } else {
                    group["hooks"]
                        .as_array_mut()
                        .and_then(|hooks| hooks.iter_mut().find(|hook| ours(hook)))
                };
                if let Some(hook) = hook {
                    hook["command"] = json!(command);
                }
                continue;
            }
            if let Some(hooks) = group["hooks"].as_array_mut() {
                hooks.retain(|hook| !ours(hook));
            }
        }
        let mut group = Map::new();
        if let Some(matcher) = matcher {
            group.insert("matcher".into(), json!(matcher));
        }
        if agent.flat {
            group.insert("command".into(), json!(command));
        } else {
            group.insert(
                "hooks".into(),
                json!([{"type": "command", "command": command}]),
            );
        }
        groups.push(Value::Object(group));
    }
    Ok(settings)
}

/// Each event `merge` sets for `agent`, as `{"Event": group}`: the group holding `command` after the merge.
fn additions(settings: Option<&Value>, agent: &Agent, command: &str) -> Result<Vec<Value>, String> {
    let merged = merge(settings, agent, command, runs)?;
    Ok(missing(settings, agent, runs)
        .into_iter()
        .map(|event| {
            let group = merged["hooks"][event].as_array().and_then(|groups| {
                groups.iter().find(|group| {
                    hooks(group, agent)
                        .iter()
                        .any(|hook| hook["command"] == command)
                })
            });
            json!({ (event): group })
        })
        .collect())
}

/// Asks `question` on the terminal; true for yes.
fn confirm(question: &str) -> Result<bool, String> {
    eprint!("  {question} [y/N] ");
    let mut answer = String::new();
    io::stdin()
        .read_line(&mut answer)
        .map_err(|error| format!("stdin: {error}"))?;
    Ok(matches!(answer.trim(), "y" | "Y" | "yes"))
}

fn install_hooks(
    agent: &Agent,
    path: &Path,
    settings: Option<(Value, Vec<u8>)>,
    command: &str,
) -> Result<(), String> {
    let (current, bytes) = settings.unzip();
    let merged = merge(current.as_ref(), agent, command, runs)
        .map_err(|error| format!("{}: {error}", path.display()))?;
    if !confirm(&format!("Merge them into {}?", path.display()))? {
        println!("  Left {} as it was.", path.display());
        return Ok(());
    }
    let text = serde_json::to_string_pretty(&merged).expect("a JSON value serializes") + "\n";
    write(path, bytes.as_deref(), text.as_bytes())
        .map_err(|error| format!("{}: {error}", path.display()))?;
    println!("  Merged into {}.", path.display());
    if agent.name == "codex" {
        println!(
            "  Codex runs a new or changed hook once you trust it: in Codex, open /hooks and trust each Dewline hook."
        );
    }
    Ok(())
}

/// `settings` without any hook calling `dewline notify --hook <name>` for `agent`, wherever its program is, and each
/// one taken out as `{"Event": hook}`. A group, an event and `"hooks"` left empty by it go too; every other key and
/// hook stays as it was.
fn unmerge(settings: &Value, agent: &Agent) -> (Value, Vec<Value>) {
    let mut settings = settings.clone();
    let mut removed = Vec::new();
    let ours = |hook: &Value| {
        hook.get("command")
            .and_then(Value::as_str)
            .is_some_and(|command| program(command, agent).is_some())
    };
    let Some(events) = settings.get_mut("hooks").and_then(Value::as_object_mut) else {
        return (settings, removed);
    };
    for (event, groups) in events.iter_mut() {
        let Some(groups) = groups.as_array_mut() else {
            continue;
        };
        groups.retain_mut(|group| {
            if agent.flat {
                if !ours(group) {
                    return true;
                }
                removed.push(json!({ (event.as_str()): group.clone() }));
                return false;
            }
            let Some(hooks) = group.get_mut("hooks").and_then(Value::as_array_mut) else {
                return true;
            };
            let before = hooks.len();
            hooks.retain(|hook| {
                let mine = ours(hook);
                if mine {
                    removed.push(json!({ (event.as_str()): hook.clone() }));
                }
                !mine
            });
            hooks.len() == before || !hooks.is_empty()
        });
    }
    if !removed.is_empty() {
        events.retain(|_, groups| groups.as_array().is_none_or(|groups| !groups.is_empty()));
        if events.is_empty()
            && let Some(root) = settings.as_object_mut()
        {
            root.retain(|key, _| key != "hooks");
        }
    }
    (settings, removed)
}

/// `dewline doctor --remove-hooks`: lists `agent`'s Dewline hooks in its settings at `path` and, asked, takes them out.
fn remove_hooks(
    agent: &Agent,
    path: &Path,
    settings: Option<(Value, Vec<u8>)>,
) -> Result<(), String> {
    let Some((current, bytes)) = settings else {
        println!("  {}: no {}", agent.title, path.display());
        return Ok(());
    };
    let (kept, removed) = unmerge(&current, agent);
    if removed.is_empty() {
        println!("  {}: no Dewline hooks in {}", agent.title, path.display());
        return Ok(());
    }
    println!("  {}: Dewline hooks in {}", agent.title, path.display());
    for entry in &removed {
        println!("    {entry}");
    }
    if !confirm(&format!("Remove them from {}?", path.display()))? {
        println!("  Left {} as it was.", path.display());
        return Ok(());
    }
    let text = serde_json::to_string_pretty(&kept).expect("a JSON value serializes") + "\n";
    write(path, Some(&bytes), text.as_bytes())
        .map_err(|error| format!("{}: {error}", path.display()))?;
    println!("  Removed from {}.", path.display());
    Ok(())
}

/// `dewline doctor --links`: each broken link and import under `dir` as `file:line: target (problem)`.
pub fn links(dir: &Path) -> Result<(), String> {
    let home = env::home_dir();
    let broken = links::check_dir(dir, home.as_deref());
    for item in &broken {
        let line = fs::read_to_string(&item.file)
            .map(|text| links::line_of(&text, item.target.range.start))
            .unwrap_or(0);
        println!(
            "{}:{line}: {} ({})",
            crate::printable(&item.file.to_string_lossy()),
            crate::printable(&item.target.text),
            item.problem.describe()
        );
    }
    match broken.len() {
        0 => {
            println!("No broken links under {}.", dir.display());
            Ok(())
        }
        1 => Err("1 broken link".into()),
        count => Err(format!("{count} broken links")),
    }
}

/// Writes `new` over a file that held `old`, after copying it to a dated backup beside it, or makes the file when
/// `old` is `None`. A file that changed since it was read is left alone.
fn write(path: &Path, old: Option<&[u8]>, new: &[u8]) -> io::Result<()> {
    let Some(old) = old else {
        if let Some(folder) = path.parent() {
            fs::create_dir_all(folder)?;
        }
        return OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)?
            .write_all(new);
    };
    if fs::read(path)? != old {
        return Err(io::Error::other(
            "it changed after it was read; run this again",
        ));
    }
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_secs());
    let mut backup = path.as_os_str().to_owned();
    backup.push(format!(".dewline-backup-{seconds}"));
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&backup)?
        .write_all(old)?;
    println!("  Backed up to {}.", Path::new(&backup).display());
    file::save(path, &file::hash(old), new)
        .map(drop)
        .map_err(|error| io::Error::other(error.to_string()))
}

/// `path` as one shell word.
fn quoted(path: &Path) -> String {
    let text = path.to_string_lossy();
    if text
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b"/-._+".contains(&byte))
    {
        text.into_owned()
    } else {
        format!("'{}'", text.replace('\'', r"'\''"))
    }
}

fn on_path(program: &str) -> Option<PathBuf> {
    env::split_paths(&env::var_os("PATH")?)
        .map(|folder| folder.join(program))
        .find(|path| fs::metadata(path).is_ok_and(|info| info.is_file()))
}

#[cfg(test)]
mod tests {
    use super::*;

    const COMMAND: &str = "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook claude";

    /// Counts every hook's program as present.
    fn every(_: &str) -> bool {
        true
    }

    #[test]
    fn merging_adds_every_event_once_and_keeps_the_rest() {
        let claude = &AGENTS[0];
        let settings = json!({
            "model": "opus",
            "permissions": {"allow": ["Bash(ls)"]},
            "hooks": {
                "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "guard.sh"}]}],
                "Notification": [{"hooks": [{"type": "command", "command": "say hi"}]}],
            },
        });
        let once = merge(Some(&settings), claude, COMMAND, every).unwrap();
        assert!(missing(Some(&once), claude, every).is_empty());
        assert_eq!(merge(Some(&once), claude, COMMAND, every).unwrap(), once);
        assert_eq!(once["model"], "opus");
        assert_eq!(once["permissions"], settings["permissions"]);
        assert_eq!(
            once["hooks"]["Notification"],
            settings["hooks"]["Notification"]
        );
        assert_eq!(
            once["hooks"]["PreToolUse"][0],
            settings["hooks"]["PreToolUse"][0]
        );
        assert_eq!(
            once["hooks"]["PreToolUse"][1],
            json!({"matcher": TOOLS, "hooks": [{"type": "command", "command": COMMAND}]})
        );
        assert_eq!(
            once["hooks"]["Stop"],
            json!([{"hooks": [{"type": "command", "command": COMMAND}]}])
        );
        let keys: Vec<_> = once.as_object().unwrap().keys().collect();
        assert_eq!(keys, ["model", "permissions", "hooks"]);
        let events: Vec<_> = once["hooks"].as_object().unwrap().keys().collect();
        assert_eq!(events[..2], ["PreToolUse", "Notification"]);
    }

    #[test]
    fn removing_takes_out_only_dewline_hooks() {
        let claude = &AGENTS[0];
        let settings = json!({
            "model": "opus",
            "hooks": {
                "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "guard.sh"}]}],
                "Notification": [{"hooks": [{"type": "command", "command": "say hi"}]}],
            },
        });
        let merged = merge(Some(&settings), claude, COMMAND, every).unwrap();
        let (kept, removed) = unmerge(&merged, claude);
        assert_eq!(kept, settings);
        assert_eq!(removed.len(), claude.events.len());
        assert_eq!(unmerge(&kept, claude), (settings, Vec::new()));

        let bare = merge(None, claude, COMMAND, every).unwrap();
        assert_eq!(unmerge(&bare, claude).0, json!({}));

        let cursor = &AGENTS[2];
        let mine = "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook cursor";
        let settings = json!({"version": 1, "hooks": {"stop": [{"command": "say done"}]}});
        let merged = merge(Some(&settings), cursor, mine, every).unwrap();
        assert_eq!(unmerge(&merged, cursor).0, settings);
    }

    #[test]
    fn hooks_installed_by_hand_count() {
        let codex = &AGENTS[1];
        let by_hand = json!({"hooks": {
            "PreToolUse": [{"matcher": "^apply_patch$", "hooks": [{"type": "command", "command": "/opt/dewline notify --hook codex"}]}],
        }});
        assert_eq!(
            missing(Some(&by_hand), codex, every),
            ["PostToolUse", "Stop", "SessionEnd"]
        );
        assert_eq!(
            missing(None, codex, every),
            ["PreToolUse", "PostToolUse", "Stop", "SessionEnd"]
        );
        let merged = merge(Some(&by_hand), codex, "dewline notify --hook codex", every).unwrap();
        assert_eq!(merged["hooks"]["PreToolUse"].as_array().unwrap().len(), 1);
        assert!(missing(Some(&merged), codex, every).is_empty());
    }

    #[test]
    fn settings_of_another_shape_are_refused() {
        let claude = &AGENTS[0];
        assert!(merge(Some(&json!([])), claude, COMMAND, every).is_err());
        assert!(merge(Some(&json!({"hooks": []})), claude, COMMAND, every).is_err());
        assert!(
            merge(
                Some(&json!({"hooks": {"Stop": {}}})),
                claude,
                COMMAND,
                every
            )
            .is_err()
        );
    }

    #[test]
    fn a_hook_whose_program_is_gone_is_missing_and_set_up_replaces_it() {
        let dir = tempfile::tempdir().unwrap();
        let live = dir.path().join("it's here/dewline");
        fs::create_dir(live.parent().unwrap()).unwrap();
        fs::write(&live, "#!/bin/sh\n").unwrap();
        fs::set_permissions(&live, fs::Permissions::from_mode(0o755)).unwrap();
        let gone = dir.path().join("Old Dewline.app/Contents/Helpers/dewline");
        assert!(runs(&quoted(&live)));
        assert!(!runs(&quoted(&gone)));
        assert!(runs("dewline"), "a bare word resolves in the agent's shell");
        fs::set_permissions(&live, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(!runs(&quoted(&live)));

        let codex = &AGENTS[1];
        let old = format!("{} notify --hook codex", quoted(&gone));
        let moved = json!({"hooks": {
            "PreToolUse": [{"matcher": "^apply_patch$", "hooks": [{"type": "command", "command": old}]}],
            "PostToolUse": [{"matcher": "^apply_patch$", "hooks": [{"type": "command", "command": old}]}],
        }});
        assert_eq!(
            missing(Some(&moved), codex, runs),
            ["PreToolUse", "PostToolUse", "Stop", "SessionEnd"]
        );
        let command = "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook codex";
        let merged = merge(Some(&moved), codex, command, runs).unwrap();
        for event in ["PreToolUse", "PostToolUse"] {
            assert_eq!(
                merged["hooks"][event],
                json!([{"matcher": "^apply_patch$", "hooks": [{"type": "command", "command": command}]}])
            );
        }
    }

    #[test]
    fn codex_trust_is_read_from_its_config() {
        let codex = &AGENTS[1];
        let file = "/Users/someone/.codex/hooks.json";
        let settings = merge(None, codex, "dewline notify --hook codex", every).unwrap();
        let mut config: toml::Table = r#"model = "gpt"
[hooks.state."/Users/someone/.codex/hooks.json:pre_tool_use:0:0"]
trusted_hash = "sha256:1"
[hooks.state."/Users/someone/.codex/hooks.json:post_tool_use:0:0"]
trusted_hash = "sha256:2"
[hooks.state."/Users/someone/.codex/hooks.json:stop:0:0"]
trusted_hash = "sha256:3"
"#
        .parse()
        .unwrap();
        assert!(!trusted(&settings, codex, file, None));
        assert!(!trusted(&settings, codex, file, Some(&config)));
        let session_end = r#"trusted_hash = "sha256:4""#.parse::<toml::Table>().unwrap();
        config["hooks"]["state"].as_table_mut().unwrap().insert(
            format!("{file}:session_end:0:0"),
            toml::Value::Table(session_end),
        );
        assert!(trusted(&settings, codex, file, Some(&config)));
        assert!(!trusted(
            &settings,
            codex,
            "/elsewhere/hooks.json",
            Some(&config)
        ));
    }

    #[test]
    fn a_hook_set_up_before_bash_is_missing_and_set_up_widens_its_matcher() {
        let claude = &AGENTS[0];
        let group = |matcher: &str| json!({"matcher": matcher, "hooks": [{"type": "command", "command": COMMAND}]});
        let old = json!({"hooks": {"PreToolUse": [group("Read|Edit|MultiEdit|Write")]}});
        assert!(missing(Some(&old), claude, every).contains(&"PreToolUse"));
        let merged = merge(Some(&old), claude, COMMAND, every).unwrap();
        assert_eq!(merged["hooks"]["PreToolUse"], json!([group(TOOLS)]));
        let any = json!({"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": COMMAND}]}]}});
        assert!(!missing(Some(&any), claude, every).contains(&"PreToolUse"));
        let reordered = json!({"hooks": {"PreToolUse": [group("Bash|Write|MultiEdit|Edit|Read")]}});
        assert!(!missing(Some(&reordered), claude, every).contains(&"PreToolUse"));

        let custom = json!({"hooks": {"PreToolUse": [group("Write|NotebookEdit|Edit")]}});
        let merged = merge(Some(&custom), claude, COMMAND, every).unwrap();
        assert_eq!(
            merged["hooks"]["PreToolUse"],
            json!([group("Write|NotebookEdit|Edit|Read|MultiEdit|Bash")])
        );

        let guard = json!({"type": "command", "command": "guard.sh"});
        let shared = json!({"hooks": {"PreToolUse": [{"matcher": "Edit|Write", "hooks": [guard, {"type": "command", "command": COMMAND}]}]}});
        let merged = merge(Some(&shared), claude, COMMAND, every).unwrap();
        assert_eq!(
            merged["hooks"]["PreToolUse"],
            json!([{"matcher": "Edit|Write", "hooks": [guard]}, group(TOOLS)])
        );
        assert!(missing(Some(&merged), claude, every).is_empty());
    }

    #[test]
    fn cursor_hooks_are_flat_under_version_1() {
        let cursor = &AGENTS[2];
        let command = "/Applications/Dewline.app/Contents/Helpers/dewline notify --hook cursor";
        let settings = json!({"hooks": {"stop": [{"command": "say done"}]}});
        let merged = merge(Some(&settings), cursor, command, every).unwrap();
        assert_eq!(merged["version"], 1);
        assert_eq!(
            merged["hooks"]["preToolUse"],
            json!([{"matcher": "Write", "command": command}])
        );
        assert_eq!(
            merged["hooks"]["afterFileEdit"],
            json!([{"command": command}])
        );
        assert_eq!(
            merged["hooks"]["stop"],
            json!([{"command": "say done"}, {"command": command}])
        );
        assert!(missing(Some(&merged), cursor, every).is_empty());
        assert_eq!(
            merge(Some(&merged), cursor, command, every).unwrap(),
            merged
        );
    }

    #[test]
    fn a_write_backs_up_first_and_never_clobbers_a_newer_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        fs::write(&path, "{\"a\": 1}").unwrap();
        write(&path, Some(b"{\"a\": 1}"), b"{\"a\": 2}").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"{\"a\": 2}");
        let backups: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .filter(|name| name.starts_with("settings.json.dewline-backup-"))
            .collect();
        assert_eq!(backups.len(), 1);
        assert_eq!(
            fs::read(dir.path().join(&backups[0])).unwrap(),
            b"{\"a\": 1}"
        );
        let stale = dir.path().join("stale.json");
        fs::write(&stale, "{\"a\": 2}").unwrap();
        assert!(write(&stale, Some(b"{\"a\": 1}"), b"{\"a\": 3}").is_err());
        assert_eq!(fs::read(&stale).unwrap(), b"{\"a\": 2}");
        let fresh = dir.path().join("new/hooks.json");
        write(&fresh, None, b"{}").unwrap();
        assert_eq!(fs::read(&fresh).unwrap(), b"{}");
    }

    #[test]
    fn a_command_on_a_disk_image_or_translocated_is_misplaced() {
        for path in [
            "/Volumes/Dewline/Dewline.app/Contents/Helpers/dewline",
            "/private/var/folders/x/T/AppTranslocation/1F2E/d/Dewline.app/Contents/Helpers/dewline",
        ] {
            assert!(misplaced(Path::new(path)), "{path}");
        }
        for path in [
            "/Applications/Dewline.app/Contents/Helpers/dewline",
            "/VolumesX/dewline",
        ] {
            assert!(!misplaced(Path::new(path)), "{path}");
        }
    }

    #[test]
    fn a_path_is_one_shell_word() {
        assert_eq!(
            quoted(Path::new("/Applications/Dewline.app/x")),
            "/Applications/Dewline.app/x"
        );
        assert_eq!(
            quoted(Path::new("/Users/me/it's here")),
            r"'/Users/me/it'\''s here'"
        );
    }
}
