//! Named values the server keeps in its memory for Roc (`Host.store_get!`, `Host.store_set!`):
//! what the platform's start keeps for the modules that can't see the app's `program` (`Registry`:
//! the kinds of job, the schedules). Set a handful of times, read often, never locked: a list that
//! only grows at its head, one compare-and-swap a value. A value set again is put in front of the
//! one before, which stays (unread) for as long as the server runs: this is for what is set at the
//! start, not for state that changes.

use std::ptr;
use std::sync::atomic::{AtomicPtr, Ordering};

struct Value {
    name: String,
    value: String,
    /// The value set before it (of any name), or null.
    before: *const Value,
}

/// The value set last, or null.
static LAST: AtomicPtr<Value> = AtomicPtr::new(ptr::null_mut());

/// The value called `name`: the one set last.
pub fn get(name: &str) -> Option<String> {
    let mut at = LAST.load(Ordering::Acquire) as *const Value;
    // Each value is set whole before it is put at the head, and never changed or freed after.
    while let Some(value) = unsafe { at.as_ref() } {
        if value.name == name {
            return Some(value.value.clone());
        }
        at = value.before;
    }
    None
}

pub fn set(name: &str, value: &str) {
    let new = Box::into_raw(Box::new(Value { name: name.to_string(), value: value.to_string(), before: ptr::null() }));
    let mut last = LAST.load(Ordering::Acquire);
    loop {
        unsafe { (*new).before = last };
        match LAST.compare_exchange_weak(last, new, Ordering::AcqRel, Ordering::Acquire) {
            Ok(_) => return,
            Err(now) => last = now,
        }
    }
}
