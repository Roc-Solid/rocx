//! What the server keeps in its memory for Roc: named locks (`Host.lock!`: an actor's one message
//! at a time) and named values (`Host.store_get!`: an actor's state, between messages).
//!
//! A lock belongs to the call that took it, and goes when that call ends, if not before. A call
//! that asks for a lock it holds already, or one a call it runs inside holds (an actor asking
//! itself), is told so, instead of waiting for itself forever.

use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tokio::sync::{Mutex as Lock, OwnedMutexGuard};

type Locks = Mutex<HashMap<String, Arc<Lock<()>>>>;

fn locks() -> &'static Locks {
    static LOCKS: OnceLock<Locks> = OnceLock::new();
    LOCKS.get_or_init(Default::default)
}

thread_local! {
    /// The locks the calls on this thread hold now (a call, and the calls it runs inside).
    static HELD: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
}

/// A lock a call holds.
pub struct Held {
    name: String,
    _guard: OwnedMutexGuard<()>,
}

impl Drop for Held {
    fn drop(&mut self) {
        HELD.with(|held| {
            let mut held = held.borrow_mut();
            if let Some(at) = held.iter().rposition(|each| each == &self.name) {
                held.remove(at);
            }
        });
    }
}

pub enum Taken {
    Got(Held),
    Busy,
    Reentrant,
}

/// Takes the lock called `name`, waiting `patience` at most.
pub fn lock(name: &str, patience: Duration) -> Result<Taken, String> {
    if HELD.with(|held| held.borrow().iter().any(|each| each == name)) {
        return Ok(Taken::Reentrant);
    }
    let lock = locks().lock().unwrap().entry(name.to_string()).or_insert_with(|| Arc::new(Lock::new(()))).clone();
    let taken = crate::hosted::wait(async { Ok(tokio::time::timeout(patience, lock.lock_owned()).await.ok()) })?;
    Ok(match taken {
        Some(guard) => {
            HELD.with(|held| held.borrow_mut().push(name.to_string()));
            Taken::Got(Held { name: name.to_string(), _guard: guard })
        }
        None => Taken::Busy,
    })
}

impl Held {
    pub fn name(&self) -> &str {
        &self.name
    }
}

fn values() -> &'static Mutex<HashMap<String, String>> {
    static VALUES: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    VALUES.get_or_init(Default::default)
}

pub fn get(name: &str) -> Option<String> {
    values().lock().unwrap().get(name).cloned()
}

pub fn set(name: &str, value: &str) {
    values().lock().unwrap().insert(name.to_string(), value.to_string());
}
