//! Values the server keeps in its memory by key, for Roc's `Kv` (`Host.kv_*!`): text (JSON, which
//! Roc encodes and decodes) or a list of texts, each with a deadline or none. Gone when the server
//! stops; never written anywhere.
//!
//! One map behind one lock: every operation is a few map and tree steps with nothing awaited while
//! the lock is held, so a call waits microseconds at most, and each operation is atomic (a counter
//! counts every increment, `add` lets one caller in, `take` gives a value once). Expired entries go
//! at the next operation, oldest deadline first. Past the limit (`--kv-max-mb`) the least recently
//! used entries go, never the one just written.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

/// What an entry costs besides its key and its text: the map's slot, the trees' nodes.
const OVERHEAD: usize = 96;

/// 64 MiB, unless the server was started with another `--kv-max-mb`.
const DEFAULT_LIMIT: usize = 64 * 1024 * 1024;

enum Value {
    Text(String),
    /// Newest first.
    List(VecDeque<String>),
}

struct Entry {
    value: Value,
    expires: Option<Instant>,
    /// When it was last read or written: its place in `by_use`.
    used: u64,
    size: usize,
}

struct Store {
    entries: HashMap<String, Entry>,
    /// Keys by their last use, oldest first: who goes when the store is full.
    by_use: BTreeMap<u64, String>,
    /// Keys by their deadline (with their last use, so two deadlines never collide).
    by_expiry: BTreeMap<(Instant, u64), String>,
    tick: u64,
    bytes: usize,
    limit: usize,
}

fn store() -> MutexGuard<'static, Store> {
    static STORE: OnceLock<Mutex<Store>> = OnceLock::new();
    STORE
        .get_or_init(|| {
            Mutex::new(Store { entries: HashMap::new(), by_use: BTreeMap::new(), by_expiry: BTreeMap::new(), tick: 0, bytes: 0, limit: DEFAULT_LIMIT })
        })
        .lock()
        // A panic while the lock was held left nothing half done that matters more than serving.
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// The most the store keeps, in bytes (`--kv-max-mb`).
pub fn set_limit(bytes: usize) {
    store().limit = bytes;
}

fn deadline(ttl_ms: u64) -> Option<Instant> {
    (ttl_ms > 0).then(|| Instant::now() + Duration::from_millis(ttl_ms))
}

fn size_of(key: &str, value: &Value) -> usize {
    OVERHEAD
        + key.len()
        + match value {
            Value::Text(text) => text.len(),
            Value::List(items) => items.iter().map(|item| item.len() + 24).sum(),
        }
}

impl Store {
    fn next_tick(&mut self) -> u64 {
        self.tick += 1;
        self.tick
    }

    /// Drops what has expired by now, oldest deadline first.
    fn sweep(&mut self) {
        let now = Instant::now();
        while let Some((&(at, _), _)) = self.by_expiry.first_key_value() {
            if at > now {
                break;
            }
            if let Some((_, key)) = self.by_expiry.pop_first() {
                self.forget(&key);
            }
        }
    }

    fn forget(&mut self, key: &str) -> Option<Entry> {
        let entry = self.entries.remove(key)?;
        self.by_use.remove(&entry.used);
        if let Some(at) = entry.expires {
            self.by_expiry.remove(&(at, entry.used));
        }
        self.bytes -= entry.size;
        Some(entry)
    }

    /// Keeps `value` under `key`, replacing any entry there, then makes room.
    fn put(&mut self, key: &str, value: Value, expires: Option<Instant>) {
        self.forget(key);
        let used = self.next_tick();
        let size = size_of(key, &value);
        self.by_use.insert(used, key.to_string());
        if let Some(at) = expires {
            self.by_expiry.insert((at, used), key.to_string());
        }
        self.bytes += size;
        self.entries.insert(key.to_string(), Entry { value, expires, used, size });
        self.make_room(key);
    }

    /// Marks `key` as just used: the last to go when the store is full.
    fn touch(&mut self, key: &str) {
        let used = self.next_tick();
        if let Some(entry) = self.entries.get_mut(key) {
            self.by_use.remove(&entry.used);
            if let Some(at) = entry.expires {
                self.by_expiry.remove(&(at, entry.used));
                self.by_expiry.insert((at, used), key.to_string());
            }
            entry.used = used;
            self.by_use.insert(used, key.to_string());
        }
    }

    /// Drops the least recently used entries, never `keep`, until the store is within its limit.
    fn make_room(&mut self, keep: &str) {
        while self.bytes > self.limit {
            let oldest = self.by_use.iter().map(|(_, key)| key).find(|key| key.as_str() != keep).cloned();
            match oldest {
                Some(key) => {
                    self.forget(&key);
                }
                None => break,
            }
        }
    }
}

/// The text under `key` (a list as a JSON array, newest first), or `None`.
pub fn get(key: &str) -> Option<String> {
    let mut store = store();
    store.sweep();
    let text = match &store.entries.get(key)?.value {
        Value::Text(text) => text.clone(),
        Value::List(items) => format!("[{}]", items.iter().map(String::as_str).collect::<Vec<_>>().join(",")),
    };
    store.touch(key);
    Some(text)
}

/// Keeps `text` under `key`, for `ttl_ms` (0: until the server stops), replacing what was there.
pub fn set(key: &str, text: &str, ttl_ms: u64) {
    let mut store = store();
    store.sweep();
    store.put(key, Value::Text(text.to_string()), deadline(ttl_ms));
}

pub fn delete(key: &str) {
    let mut store = store();
    store.sweep();
    store.forget(key);
}

/// The text under `key`, gone from the store as it is read: one caller gets it.
pub fn take(key: &str) -> Option<String> {
    let mut store = store();
    store.sweep();
    match store.forget(key)?.value {
        Value::Text(text) => Some(text),
        Value::List(items) => Some(format!("[{}]", items.iter().map(String::as_str).collect::<Vec<_>>().join(","))),
    }
}

/// Keeps `text` under `key` only if nothing is there: whether it did.
pub fn add(key: &str, text: &str, ttl_ms: u64) -> bool {
    let mut store = store();
    store.sweep();
    if store.entries.contains_key(key) {
        return false;
    }
    store.put(key, Value::Text(text.to_string()), deadline(ttl_ms));
    true
}

/// Adds `by` to the integer under `key` (0 if nothing is there, its deadline then `ttl_ms` from
/// now; an existing one keeps its own): the new value. An error if what is there isn't an integer.
pub fn increment(key: &str, by: i64, ttl_ms: u64) -> Result<i64, String> {
    let mut store = store();
    store.sweep();
    let (now, expires) = match store.entries.get(key) {
        None => (by, deadline(ttl_ms)),
        Some(Entry { value: Value::Text(text), expires, .. }) => {
            let was: i64 = text.trim().parse().map_err(|_| format!("{key} holds {text}, not an integer"))?;
            (was.saturating_add(by), *expires)
        }
        Some(Entry { value: Value::List(_), .. }) => return Err(format!("{key} holds a list, not an integer")),
    };
    store.put(key, Value::Text(now.to_string()), expires);
    Ok(now)
}

/// Puts `text` at the front of the list under `key`, keeping the newest `keep` (a text there is
/// replaced by a list). A new list's deadline is `ttl_ms` from now; an existing one keeps its own.
pub fn push(key: &str, text: &str, keep: u64, ttl_ms: u64) {
    let mut store = store();
    store.sweep();
    let (mut items, expires) = match store.forget(key) {
        Some(Entry { value: Value::List(items), expires, .. }) => (items, expires),
        _ => (VecDeque::new(), deadline(ttl_ms)),
    };
    items.push_front(text.to_string());
    items.truncate(usize::try_from(keep.max(1)).unwrap_or(usize::MAX));
    store.put(key, Value::List(items), expires);
}

#[cfg(test)]
mod tests {
    use super::*;

    // One store for the process: each test keeps to keys of its own.

    #[test]
    fn set_get_delete_take() {
        set("t1:a", "1", 0);
        assert_eq!(get("t1:a").as_deref(), Some("1"));
        delete("t1:a");
        assert_eq!(get("t1:a"), None);
        set("t1:b", "\"x\"", 0);
        assert_eq!(take("t1:b").as_deref(), Some("\"x\""));
        assert_eq!(take("t1:b"), None, "taken once");
    }

    #[test]
    fn expiry() {
        set("t2:a", "1", 30);
        assert_eq!(get("t2:a").as_deref(), Some("1"));
        std::thread::sleep(Duration::from_millis(60));
        assert_eq!(get("t2:a"), None);
        assert!(add("t2:a", "2", 0), "an expired key is free again");
    }

    #[test]
    fn add_once_and_increment() {
        assert!(add("t3:a", "1", 0));
        assert!(!add("t3:a", "2", 0));
        assert_eq!(increment("t3:n", 1, 0), Ok(1));
        assert_eq!(increment("t3:n", 5, 0), Ok(6));
        set("t3:s", "\"no\"", 0);
        assert!(increment("t3:s", 1, 0).is_err());
    }

    #[test]
    fn increments_from_many_threads_all_count() {
        let threads: Vec<_> = (0..8).map(|_| std::thread::spawn(|| (0..500).for_each(|_| drop(increment("t4:n", 1, 0))))).collect();
        threads.into_iter().for_each(|thread| thread.join().unwrap());
        assert_eq!(get("t4:n").as_deref(), Some("4000"));
    }

    #[test]
    fn full_it_drops_the_least_recently_used_never_the_one_just_written() {
        let mut store = Store { entries: HashMap::new(), by_use: BTreeMap::new(), by_expiry: BTreeMap::new(), tick: 0, bytes: 0, limit: 3 * (OVERHEAD + 2) };
        for key in ["a1", "b1", "c1"] {
            store.put(key, Value::Text(String::new()), None);
        }
        store.touch("a1");
        store.put("d1", Value::Text(String::new()), None);
        assert!(!store.entries.contains_key("b1"), "the least recently used goes");
        assert!(store.entries.contains_key("a1"), "a read keeps it");
        assert!(store.entries.contains_key("d1"));
        store.put("big", Value::Text("x".repeat(10_000)), None);
        assert!(store.entries.contains_key("big"), "the one just written stays, alone if it must");
        assert_eq!(store.entries.len(), 1);
        assert_eq!(store.bytes, size_of("big", &Value::Text("x".repeat(10_000))));
    }

    #[test]
    fn a_capped_list_newest_first() {
        for each in ["1", "2", "3", "4"] {
            push("t5:l", each, 3, 0);
        }
        assert_eq!(get("t5:l").as_deref(), Some("[4,3,2]"));
    }
}
