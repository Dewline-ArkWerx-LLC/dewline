//! Writes the syntaxes `core::highlight` loads as an uncompressed newline dump: the syntaxes in `LANGUAGES` from
//! two-face (bat's curated set; the version is pinned in Cargo.toml) and every syntax they embed, and next to it
//! `LICENSES.md`, the license texts two-face lists for them. Plain "JavaScript" is refused: it never returns on `x /*`
//! (trishume/syntect#706), and "JavaScript (Babel)" takes its fences.
//! Usage: cargo run --release --manifest-path scripts/syntaxes/Cargo.toml -- app/Dewline/Syntaxes.packdump
//!
//! two-face ships one linked set, whose contexts point at each other by index. The cut reads each kept syntax's
//! contexts, turns those indexes back into names, and builds a new set from them, so syntect links it as it would
//! from source. The build then parses a sample in every kept syntax with both sets and requires the same scopes.

use std::collections::{BTreeSet, HashMap};

use serde::Deserialize;
use serde_json::{Value, json};
use syntect::dumps::{dump_to_uncompressed_file, from_binary};
use syntect::parsing::syntax_definition::{Context, ContextId};
use syntect::parsing::{
    ParseState, SyntaxDefinition, SyntaxReference, SyntaxSet, SyntaxSetBuilder,
};

/// The fence languages, by two-face's syntax names, with the bat folder the syntax comes from when it is not one of
/// sublimehq's Packages. Diff and Markdown are highlighted in the core without syntect.
const LANGUAGES: &[(&str, Option<&str>)] = &[
    ("Bourne Again Shell (bash)", None),
    ("C", None),
    ("C#", None),
    ("C++", None),
    ("CMake", Some("CMake")),
    ("CSS", None),
    ("Clojure", None),
    ("Dart", Some("Dart")),
    ("Dockerfile", Some("Docker")),
    ("Elixir", Some("Elixir")),
    ("Erlang", None),
    ("F#", Some("FSharp")),
    ("Fish", Some("Fish")),
    ("Go", None),
    ("GraphQL", Some("GraphQL")),
    ("Groovy", None),
    ("HTML", None),
    ("Haskell", None),
    ("INI", Some("INI")),
    ("JSON", None),
    ("Java", None),
    ("JavaScript (Babel)", Some("JavaScript_(Babel)")),
    ("Julia", Some("Julia")),
    ("Kotlin", Some("Kotlin")),
    ("LaTeX", None),
    ("Lua", None),
    ("MATLAB", None),
    ("Makefile", None),
    ("Nix", Some("Nix")),
    ("OCaml", None),
    ("Objective-C", None),
    ("Objective-C++", None),
    ("PHP", None),
    ("Perl", None),
    ("PowerShell", Some("PowerShell")),
    ("Protocol Buffer", Some("Protobuf")),
    ("Python", None),
    ("R", None),
    ("Regular Expression", None),
    ("Ruby", None),
    ("Rust", None),
    ("SCSS", Some("SCSS_Sass")),
    ("SQL", None),
    ("Sass", Some("SCSS_Sass")),
    ("Scala", None),
    ("Swift", Some("Swift")),
    ("TOML", Some("TOML")),
    ("Terraform", Some("Terraform")),
    ("TypeScript", Some("TypeScript")),
    ("TypeScriptReact", Some("TypeScript")),
    ("Typst", Some("Typst")),
    ("XML", None),
    ("YAML", None),
    ("Zig", Some("Zig")),
    ("nginx", Some("Nginx")),
    ("x86_64 Assembly", Some("Assembly (x86_64)")),
];

/// The two-face syntaxes no fence may reach.
const REFUSED: &[&str] = &["JavaScript"];

/// Lines each kept syntax parses with both sets, which must give the same scopes.
const SAMPLE: &str = "#!/usr/bin/env x\n<a href=\"#\">{{ x }}</a> <script>let s = `${1 + 2}`; /* c */</script>\n\
    fn main() { let x: u32 = 0x1F; // note\n  return \"str\\n\" + 'c' + r#\"raw\"#; }\n\
    def f(a, *b, **c):\n    \"\"\"doc\"\"\"\n    return [i ** 2 for i in range(10) if i % 2]\n\
    SELECT * FROM t WHERE x = 'y' -- c\nkey: value # c\n- [1, 2.5, true, null]\n\\begin{x} $a^2$ \\end{x}\n\
    @media (max-width: 1px) { .a > #b { color: #fff; } }\n<?php echo $x; ?>\nx /*\n";

/// A syntax's contexts and their names, as the linked set holds them.
#[derive(Deserialize)]
struct Lazy {
    context_ids: HashMap<String, ContextId>,
    contexts: Vec<Context>,
}

fn lazy(syntax: &SyntaxReference) -> Lazy {
    #[derive(Deserialize)]
    struct Serialized {
        serialized_lazy_contexts: Vec<u8>,
    }
    let serialized: Serialized = serde_json::from_value(json!(syntax)).unwrap();
    from_binary(&serialized.serialized_lazy_contexts)
}

/// A context id's syntax and context indexes.
fn indexes(id: &Value) -> Option<(usize, usize)> {
    Some((
        id.get("syntax_index")?.as_u64()? as usize,
        id.get("context_index")?.as_u64()? as usize,
    ))
}

/// Every `Direct` reference in `value`, rewritten by `rewrite`.
fn directs(value: &mut Value, rewrite: &mut impl FnMut((usize, usize)) -> Value) {
    match value {
        Value::Object(map) => {
            if map.len() == 1
                && let Some(id) = map.get("Direct").and_then(indexes)
            {
                *value = rewrite(id);
                return;
            }
            map.values_mut().for_each(|value| directs(value, rewrite));
        }
        Value::Array(values) => values.iter_mut().for_each(|value| directs(value, rewrite)),
        _ => {}
    }
}

fn main() {
    let out = std::env::args()
        .nth(1)
        .expect("usage: syntaxes <out.packdump>");
    let all = two_face::syntax::extra_newlines();
    let syntaxes = all.syntaxes();
    let lazies: Vec<Lazy> = syntaxes.iter().map(lazy).collect();
    // The name of each context, by syntax and context index.
    let mut names: Vec<HashMap<usize, String>> = vec![HashMap::new(); syntaxes.len()];
    for lazy in &lazies {
        for (name, id) in &lazy.context_ids {
            let (syntax, context) = indexes(&json!(id)).unwrap();
            names[syntax].insert(context, name.clone());
        }
    }

    // The languages and every syntax their contexts or prototypes reach.
    let index = |name: &str| {
        let found: Vec<usize> = (0..syntaxes.len())
            .filter(|&at| syntaxes[at].name == name)
            .collect();
        assert_eq!(
            found.len(),
            1,
            "{name}: {} syntaxes by that name",
            found.len()
        );
        found[0]
    };
    let mut kept: BTreeSet<usize> = LANGUAGES.iter().map(|(name, _)| index(name)).collect();
    let mut queue: Vec<usize> = kept.iter().copied().collect();
    while let Some(at) = queue.pop() {
        for context in &lazies[at].contexts {
            let mut value = json!(context);
            directs(&mut value, &mut |(syntax, _)| {
                if kept.insert(syntax) {
                    queue.push(syntax);
                }
                Value::Null
            });
            if let Some((syntax, _)) = indexes(&value["prototype"])
                && kept.insert(syntax)
            {
                queue.push(syntax);
            }
        }
    }
    for name in REFUSED {
        assert!(!kept.contains(&index(name)), "{name} is reached");
    }

    let mut builder = SyntaxSetBuilder::new();
    for &at in &kept {
        let source = &syntaxes[at];
        let mut contexts = HashMap::new();
        for (name, id) in &lazies[at].context_ids {
            let (_, context) = indexes(&json!(id)).unwrap();
            let mut value = json!(lazies[at].contexts[context]);
            directs(&mut value, &mut |(syntax, context)| {
                let name = names[syntax][&context].clone();
                if syntax == at {
                    json!({ "Named": name })
                } else {
                    json!({ "File": { "name": syntaxes[syntax].name, "sub_context": name, "with_escape": false } })
                }
            });
            // The linker sets each context's prototype again from the names.
            value["prototype"] = Value::Null;
            contexts.insert(name.clone(), serde_json::from_value(value).unwrap());
        }
        builder.add(SyntaxDefinition {
            name: source.name.clone(),
            file_extensions: source.file_extensions.clone(),
            scope: source.scope,
            first_line_match: source.first_line_match.clone(),
            hidden: source.hidden,
            variables: source.variables.clone(),
            contexts,
        });
    }
    let set = builder.build();
    check(&all, &set);
    dump_to_uncompressed_file(&set, &out).unwrap();
    licenses(&set);
    println!(
        "{out}: {} syntaxes: {}",
        set.syntaxes().len(),
        set.syntaxes()
            .iter()
            .map(|syntax| syntax.name.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    );
}

/// Every syntax in `cut` parses `SAMPLE` into the same scopes as in `all`.
fn check(all: &SyntaxSet, cut: &SyntaxSet) {
    for syntax in cut.syntaxes() {
        let parse = |set: &SyntaxSet| {
            let mut state = ParseState::new(set.find_syntax_by_name(&syntax.name).unwrap());
            SAMPLE
                .split_inclusive('\n')
                .take_while(|line| *line != "x /*\n" || syntax.name != "JavaScript")
                .map(|line| state.parse_line(line, set).unwrap())
                .collect::<Vec<_>>()
        };
        assert!(
            parse(all) == parse(cut),
            "{} parses differently once cut",
            syntax.name
        );
    }
}

/// Writes `LICENSES.md` beside the script: the syntaxes in `set`, and the license text two-face lists for each kept
/// bat folder. The syntaxes without a folder are sublimehq's Packages, under `Packages-LICENSE`.
fn licenses(set: &SyntaxSet) {
    let folders: BTreeSet<&str> = LANGUAGES.iter().filter_map(|(_, folder)| *folder).collect();
    let mut found = BTreeSet::new();
    let mut texts = String::new();
    for license in two_face::acknowledgement::listing().for_syntaxes() {
        let path = license.rel_path.to_string_lossy();
        let folder = folders
            .iter()
            .find(|folder| path.starts_with(&format!("syntaxes/02_Extra/{folder}/")));
        if folder.is_some() || path == "syntaxes/01_Packages/Rust/LICENSE.txt" {
            found.extend(folder);
            texts.push_str(&format!(
                "## {path}\n\n```text\n{}\n```\n\n",
                license.text.trim()
            ));
        }
    }
    let names: Vec<&str> = set
        .syntaxes()
        .iter()
        .map(|syntax| syntax.name.as_str())
        .collect();
    let bare: Vec<&str> = folders.difference(&found).copied().collect();
    let text = format!(
        "# Syntax licenses\n\nWritten by scripts/syntaxes. Syntaxes.packdump holds these syntaxes from bat 0.26.1 \
         (https://github.com/sharkdp/bat), through two-face 0.5.2 (MIT OR Apache-2.0): {}.\n\nThose from bat's \
         02_Extra folder carry the license texts below; these folders have none in bat's tree: {}. The rest are \
         sublimehq's Packages, under Packages-LICENSE.\n\n{texts}",
        names.join(", "),
        bare.join(", "),
    );
    std::fs::write(
        concat!(env!("CARGO_MANIFEST_DIR"), "/LICENSES.md"),
        text.trim_end().to_string() + "\n",
    )
    .unwrap();
}
