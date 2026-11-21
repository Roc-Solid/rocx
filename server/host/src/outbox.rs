//! The outbox in memory: email `Email.send!` kept instead of sending (no `--smtp-url`) when the
//! server has no database, the last hundred, for the dev mailbox (`server/platform/Mailbox.roc`,
//! `GET /__rocx/mail` with `--dev`). With a database the platform keeps them in Postgres instead
//! (`rocx_outbox`), so they outlast a restart.

use std::collections::VecDeque;
use std::sync::Mutex;

struct Outbox {
    messages: VecDeque<serde_json::Value>,
    /// The id the next message gets.
    next: u64,
}

static OUTBOX: Mutex<Outbox> = Mutex::new(Outbox { messages: VecDeque::new(), next: 1 });
const KEPT: usize = 100;

/// Keeps a message (a JSON object, as Roc wrote it), giving it the next id.
pub fn keep(json: &str) {
    let Ok(serde_json::Value::Object(mut message)) = serde_json::from_str(json) else { return };
    let mut outbox = OUTBOX.lock().unwrap();
    message.insert("id".into(), outbox.next.into());
    outbox.next += 1;
    if outbox.messages.len() == KEPT {
        outbox.messages.pop_front();
    }
    outbox.messages.push_back(serde_json::Value::Object(message));
}

/// The outbox, as a JSON array, oldest first.
pub fn json() -> String {
    serde_json::Value::Array(OUTBOX.lock().unwrap().messages.iter().cloned().collect()).to_string()
}

/// Empties it (the ids go on counting).
pub fn clear() {
    OUTBOX.lock().unwrap().messages.clear();
}
