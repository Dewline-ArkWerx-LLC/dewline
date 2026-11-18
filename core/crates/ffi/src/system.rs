//! What the app's system entry points need from the core: the Quick Look page, the inbox append behind the App Intent
//! and the Service, and the path check behind the `dewline://` URLs.

use std::env;
use std::path::{Path, PathBuf};

use dewline_core::{export, highlight, inbox, jail};

use crate::{Panicked, contained};

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum Refusal {
    #[error("{message}")]
    Refused { message: String },
}

fn refused(message: impl ToString) -> Refusal {
    Refusal::Refused {
        message: message.to_string(),
    }
}

/// A Quick Look page of `text`: the page export writes, with diagrams and math as their source, no image inlined, and
/// fenced code colored in the syntaxes at `syntaxes` (the app's `Syntaxes.packdump`) when they load.
#[uniffi::export]
pub fn preview_html(
    text: String,
    title: String,
    css: String,
    syntaxes: Option<String>,
) -> Result<String, Panicked> {
    contained(|| {
        let syntaxes = syntaxes.and_then(|dump| highlight::Syntaxes::load(Path::new(&dump)));
        export::html(
            &text,
            &export::ExportOptions {
                title: &title,
                css: &css,
                diagram: &|_| None,
                math: &|_, _| None,
                code: &|language, code| syntaxes.as_ref()?.html(language, code),
                folder: None,
            },
        )
    })
}

/// Appends `text` to the inbox at `path`, or at the default inbox in the home folder, as one entry from `source`.
#[uniffi::export]
pub fn inbox_append(path: Option<String>, source: String, text: String) -> Result<(), Refusal> {
    let path = match path {
        Some(path) => PathBuf::from(path),
        None => inbox::default_path(&home()?),
    };
    inbox::append(&path, &source, &text)
        .map_err(|error| refused(format!("{}: {error}", path.display())))
}

/// `path`, absolute, with every link resolved, if it lies inside the home folder but not inside ~/Library or a `.ssh`
/// folder. A file not there yet is checked through its folder.
#[uniffi::export]
pub fn jailed_path(path: String) -> Result<String, Refusal> {
    jail::in_home(Path::new(&path), &home()?)
        .map_err(|error| refused(format!("{path}: {error}")))?
        .into_os_string()
        .into_string()
        .map_err(|_| refused(format!("{path}: the path is not UTF-8")))
}

fn home() -> Result<PathBuf, Refusal> {
    env::home_dir().ok_or_else(|| refused("there is no home folder"))
}
