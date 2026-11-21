//! `Live` (`server/platform/Live.roc`): topics, which carry messages to every call listening, and
//! rooms, which count who is in them, all in the server's memory (one server, so no broker).

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use tokio::sync::broadcast;

/// A message on a topic.
#[derive(Clone, Debug)]
pub struct Message {
    pub topic: String,
    pub text: String,
}

/// Each topic's channel; a listener lagging this far behind misses the oldest.
const BACKLOG: usize = 256;

fn topics() -> &'static Mutex<HashMap<String, broadcast::Sender<Message>>> {
    static TOPICS: OnceLock<Mutex<HashMap<String, broadcast::Sender<Message>>>> = OnceLock::new();
    TOPICS.get_or_init(Default::default)
}

fn rooms() -> &'static Mutex<HashMap<String, u64>> {
    static ROOMS: OnceLock<Mutex<HashMap<String, u64>>> = OnceLock::new();
    ROOMS.get_or_init(Default::default)
}

fn channel(topic: &str) -> broadcast::Sender<Message> {
    let mut topics = topics().lock().unwrap();
    // A topic nobody listens to any more is forgotten when it is next used.
    topics.retain(|_, sender| sender.receiver_count() > 0);
    topics.entry(topic.to_string()).or_insert_with(|| broadcast::channel(BACKLOG).0).clone()
}

/// Sends `text` to everyone listening to `topic` (no one, perhaps).
pub fn publish(topic: &str, text: &str) {
    let _ = channel(topic).send(Message { topic: topic.to_string(), text: text.to_string() });
}

/// A way to hear what is published on `topic` from now on.
pub fn listen(topic: &str) -> broadcast::Receiver<Message> {
    channel(topic).subscribe()
}

/// One more in `room`; those listening hear `join`.
pub fn join(room: &str) {
    *rooms().lock().unwrap().entry(room.to_string()).or_insert(0) += 1;
    publish(room, "join");
}

/// One fewer in `room`; those listening hear `leave`.
pub fn leave(room: &str) {
    {
        let mut rooms = rooms().lock().unwrap();
        if let Some(count) = rooms.get_mut(room) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                rooms.remove(room);
            }
        }
    }
    publish(room, "leave");
}

pub fn count(room: &str) -> u64 {
    rooms().lock().unwrap().get(room).copied().unwrap_or(0)
}
