//! What the server was started with, for Roc (`Host.setting!`): `database_url` (`--database-url`),
//! `dev` ("yes" with `--dev`:
//! `Env.dev!`), `debug` ("yes" with `--debug`), `public_url` (`--public-url`, or where it listens:
//! `Env.public_url!`).
//! The platform's Roc reads them; the host only keeps them.

use std::collections::HashMap;
use std::sync::OnceLock;

static SETTINGS: OnceLock<HashMap<String, String>> = OnceLock::new();

pub fn set(settings: HashMap<String, String>) {
    let _ = SETTINGS.set(settings);
}

/// A setting's value, or "" when it wasn't given.
pub fn get(name: &str) -> String {
    SETTINGS.get().and_then(|settings| settings.get(name)).cloned().unwrap_or_default()
}
