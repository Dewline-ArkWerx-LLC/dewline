use std::path::Path;

use dewline_core::agents::AgentFiles;

/// Whether an agent loads the file at `path` as instructions, rules, skills,
/// plans or memory.
#[uniffi::export]
pub fn is_agent_file(path: String) -> bool {
    AgentFiles::builtin().matches(Path::new(&path))
}
