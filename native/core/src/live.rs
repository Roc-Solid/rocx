//! Live updates on a phone (D-140): streams of events (`Endpoint.listen!`) and channels
//! (`Endpoint.subscribe!`, `say!`, `resync!`) over the server's `/rocx/live`, as web/runtime.js's
//! `listenTo` and `Hub` do them, on the HTTP client's streams (`http::stream`, server-sent events).
//!
//! - **`listen!`** reads an endpoint's events (`accept: text/event-stream`); its handler runs for each
//!   event's data (`{"Event":…}`), then once at the end (`"Ended"`, or `{"Failed":…}` when it was cut
//!   off; `{"Refused":[status, body]}` for an answer that isn't a stream). Started in a component or a
//!   computation, it stops when that goes (the page that listens left).
//! - **Channels**: every subscription of the app on one stream, `GET /rocx/live?tab=…&c=<url>…`. The
//!   stream says its id first (`hello`); what the app subscribes to then changes by posts naming it
//!   (`subscribe`, `unsubscribe`, D-057), and what it says (`say!`) and its resyncs go in one `POST
//!   /rocx/live/send` a flush. A stream that drops is opened again after a wait that doubles each
//!   time (0.5 s to 30 s, a quarter at random added), and starts over at 0.5 s once one has stayed up
//!   10 s. With nothing left to subscribe to, it is closed. Where no server answers channels, every
//!   subscriber hears `Refused(404, …)`.
//! - The app is one tab: its id is made once a process (`tab`), and a new one when the server says
//!   another has it (`replaced`).
//!
//! Each subscriber hears its events in order; a handler that waits for the server runs again with
//! its answer, which may come after the next event's handler (the browser's runs the next once it
//! is done).

use crate::engine::{self, Asked};
use crate::fx::HashMap;
use crate::http::{Heard, Stopper};
use crate::json::{self, Value};
use crate::{Level, log};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::time::{Duration, Instant};

/// A `listen!`: its handler's box, what it runs in, and how to stop its stream.
struct Listening {
    kept: u64,
    scope: engine::Scope,
    owner: Option<u64>,
    stopper: Stopper,
    url: String,
}

struct Subscriber {
    kept: u64,
    url: String,
    scope: engine::Scope,
    owner: Option<u64>,
    queue: VecDeque<String>,
}

#[derive(Default)]
struct Channel {
    subscribers: Vec<u64>,
    open: bool,
    refused: Option<(u64, String)>,
    /// What the server ended it with (its JSON).
    ended: Option<String>,
}

/// The channels' stream: the URLs it carries (as the server was told), how to stop it, when it
/// opened, its id once it said hello, or `legacy` once it spoke without one.
struct Stream {
    id: u64,
    urls: BTreeSet<String>,
    stopper: Stopper,
    opened: Instant,
    said: Option<String>,
    legacy: bool,
}

#[derive(Default)]
pub struct Live {
    listening: HashMap<u64, Listening>,
    /// What a `listen!` or a subscription is, by the id its owner's cleanup names.
    subscribers: HashMap<u64, Subscriber>,
    channels: BTreeMap<String, Channel>,
    stream: Option<Stream>,
    /// The set changed: the stream follows it after the flush (`reconcile`).
    changed: bool,
    /// A wait before the stream is opened again is under way.
    retrying: bool,
    drops: u32,
    unavailable: Option<(u64, String)>,
    /// What the next post carries: each item's JSON, and the stream it names (a change of what it
    /// carries, dropped if another stream opens first).
    outbox: Vec<(String, Option<u64>)>,
    /// Told after the run that subscribed (`queueMicrotask`'s): a subscriber, and what it hears.
    told: Vec<(u64, String)>,
    tab: String,
}

const FIRST_WAIT: u64 = 500;
const MOST_WAIT: u64 = 30_000;
const STEADY: Duration = Duration::from_secs(10);

/// A random id (hex): the tab's, and a fresh one when another has it.
fn random_id() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut out = String::new();
    for round in 0..2u64 {
        let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
        hasher.write_u64(round);
        hasher.write_u128(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|since| since.as_nanos()).unwrap_or(0));
        out.push_str(&format!("{:016x}", hasher.finish()));
    }
    out[..24].to_string()
}

fn tab(live: &mut Live) -> String {
    if live.tab.is_empty() {
        live.tab = random_id();
    }
    live.tab.clone()
}

fn encode(text: &str) -> String {
    let mut out = String::new();
    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(byte as char),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn quoted(text: &str) -> String {
    let mut out = String::new();
    json::quote(text, &mut out);
    out
}

// ---- listen! ----

/// `Endpoint.listen!(url, handler)` (`listenTo`): the stream read, its handler run for each event.
pub fn listen(url: String, runner: crate::abi::RocErasedCallable) {
    let held = engine::live_keep(runner, false).unwrap_or_else(|_| unreachable!("a listen! is kept whether or not something owns it"));
    let stopper = Stopper::default();
    let full = engine::with(|engine| engine.full_url(&url));
    engine::with(|engine| {
        engine.live.listening.insert(held.id, Listening { kept: held.kept, scope: held.scope, owner: held.owner, stopper: stopper.clone(), url: url.clone() });
    });
    crate::http::stream(held.id, full, vec![("accept".into(), "text/event-stream".into())], stopper);
}

fn listen_heard(id: u64, heard: Heard) {
    let found = engine::with(|engine| engine.live.listening.get(&id).map(|listening| (listening.kept, listening.scope.clone(), listening.owner, listening.url.clone())));
    let Some((kept, scope, owner, url)) = found else { return };
    let (said, done) = match heard {
        Heard::Opened { status, events, body } => {
            if events && (200..300).contains(&status) {
                return;
            }
            (format!("{{\"Refused\":[{status},{}]}}", quoted(&body)), true)
        }
        Heard::Event { name, data } => {
            if name == "end" {
                ("\"Ended\"".to_string(), true)
            } else {
                (format!("{{\"Event\":{}}}", quoted(&data)), false)
            }
        }
        Heard::Closed(None) => (format!("{{\"Failed\":{}}}", quoted("the stream was cut off before it ended")), true),
        Heard::Closed(Some(why)) => (format!("{{\"Failed\":{}}}", quoted(&format!("{url}: {why}"))), true),
    };
    if engine::with(|engine| engine.has_kept(kept)) {
        engine::handle(kept, said, scope, owner, None, None);
    }
    if done {
        stop_listening(id);
    }
}

fn stop_listening(id: u64) {
    let found = engine::with(|engine| engine.live.listening.remove(&id));
    if let Some(listening) = found {
        listening.stopper.stop();
        engine::release_later(listening.kept);
    }
}

/// What a `listen!` or a subscription's owner went (its cleanup): the stream stopped, or the
/// subscriber gone.
pub fn cleanup(id: u64) {
    if engine::with(|engine| engine.live.listening.contains_key(&id)) {
        stop_listening(id);
        return;
    }
    unsubscribe(id);
}

// ---- Channels ----

/// `Endpoint.subscribe!(url, handler)` (`Hub.subscribe`), in a component, a computation or an
/// effect: its handler kept until that goes.
pub fn subscribe(url: String, runner: crate::abi::RocErasedCallable) -> Result<(), String> {
    let held = match engine::live_keep(runner, true) {
        Ok(held) => held,
        Err(runner) => {
            crate::roc::release(runner);
            return Err(format!("Endpoint.subscribe!({url}) is called in a component, a computation or an effect, not in a handler: nothing would end it"));
        }
    };
    engine::with(|engine| {
        let live = &mut engine.live;
        let fresh = !live.channels.contains_key(&url);
        let channel = live.channels.entry(url.clone()).or_default();
        channel.subscribers.push(held.id);
        // What the others on this channel heard that still holds: told once this run is done.
        let told = if let Some((status, why)) = &live.unavailable {
            Some(format!("{{\"Refused\":[{status},{}]}}", quoted(why)))
        } else if let Some((status, why)) = &channel.refused {
            Some(format!("{{\"Refused\":[{status},{}]}}", quoted(why)))
        } else {
            channel.ended.as_ref().map(|ended| format!("{{\"Ended\":{ended}}}"))
        };
        let open = channel.open;
        live.subscribers.insert(held.id, Subscriber { kept: held.kept, url: url.clone(), scope: held.scope, owner: held.owner, queue: VecDeque::new() });
        match told {
            Some(told) => live.told.push((held.id, told)),
            // A new subscriber to a channel the stream has open: its resync again.
            None if open => post(live, format!("{{\"channel\":{},\"resync\":true}}", quoted(&url)), None),
            None => {}
        }
        if fresh {
            live.changed = true;
        }
    });
    Ok(())
}

fn unsubscribe(id: u64) {
    let kept = engine::with(|engine| {
        let live = &mut engine.live;
        let subscriber = live.subscribers.remove(&id)?;
        if let Some(channel) = live.channels.get_mut(&subscriber.url) {
            channel.subscribers.retain(|each| *each != id);
            // Its last subscriber gone, the channel stays until the stream follows the set: one
            // subscribing meanwhile (the next page's, as a navigation renders it) finds it open.
            if channel.subscribers.is_empty() {
                live.changed = true;
            }
        }
        Some(subscriber.kept)
    });
    if let Some(kept) = kept {
        engine::release_later(kept);
    }
}

/// `Endpoint.say!(url, json)`: for the next post.
pub fn say(url: String, said: String) {
    engine::with(|engine| post(&mut engine.live, format!("{{\"channel\":{},\"message\":{said}}}", quoted(&url)), None));
}

/// `Endpoint.resync!(url)`: asked of the server, if the channel is open.
pub fn resync(url: String) {
    engine::with(|engine| {
        if engine.live.channels.get(&url).is_some_and(|channel| channel.open) {
            post(&mut engine.live, format!("{{\"channel\":{},\"resync\":true}}", quoted(&url)), None);
        }
    });
}

fn post(live: &mut Live, item: String, stream: Option<u64>) {
    if live.unavailable.is_none() {
        live.outbox.push((item, stream));
    }
}

/// After each flush (`lib::pump`): what was told subscribers as they subscribed, the stream made to
/// follow the set (`reconcile`), and what was said sent.
pub fn reconcile() {
    if !engine::started() {
        return;
    }
    let told = engine::with(|engine| std::mem::take(&mut engine.live.told));
    for (subscriber, said) in told {
        deliver(subscriber, said);
    }
    if engine::with(|engine| std::mem::take(&mut engine.live.changed)) {
        follow();
    }
    send();
}

/// The stream follows the set (`Hub.reconcile`): opened with it, told what was added and dropped,
/// or opened again when it can't be told (an older server's).
fn follow() {
    let connect = engine::with(|engine| {
        let live = &mut engine.live;
        live.channels.retain(|_, channel| !channel.subscribers.is_empty());
        if live.unavailable.is_some() || live.retrying {
            return None;
        }
        let urls: BTreeSet<String> = live.channels.keys().cloned().collect();
        let Some(stream) = live.stream.as_mut() else {
            return (!urls.is_empty()).then_some(urls);
        };
        let dropped: Vec<String> = stream.urls.difference(&urls).cloned().collect();
        let added: Vec<String> = urls.difference(&stream.urls).cloned().collect();
        if dropped.is_empty() && added.is_empty() {
            return None;
        }
        if stream.legacy {
            stream.stopper.stop();
            live.stream = None;
            return (!urls.is_empty()).then_some(urls);
        }
        // Not said hello yet: told once it has.
        if stream.said.is_none() {
            return None;
        }
        let id = stream.id;
        for url in &dropped {
            stream.urls.remove(url);
        }
        for url in &added {
            stream.urls.insert(url.clone());
        }
        for url in dropped {
            post(live, format!("{{\"channel\":{},\"unsubscribe\":true}}", quoted(&url)), Some(id));
        }
        for url in added {
            post(live, format!("{{\"channel\":{},\"subscribe\":true}}", quoted(&url)), Some(id));
        }
        None
    });
    if let Some(urls) = connect {
        open(urls);
    }
}

fn open(urls: BTreeSet<String>) {
    let (id, url, stopper) = engine::with(|engine| {
        let id = engine.next_id();
        let tab = tab(&mut engine.live);
        let live = &mut engine.live;
        // What was waiting to be told the old stream: this one carries the set as it is.
        live.outbox.retain(|(_, stream)| stream.is_none());
        for channel in live.channels.values_mut() {
            channel.open = false;
            channel.refused = None;
            channel.ended = None;
        }
        let query: Vec<String> = std::iter::once(format!("tab={}", encode(&tab))).chain(urls.iter().map(|url| format!("c={}", encode(url)))).collect();
        let stopper = Stopper::default();
        live.stream = Some(Stream { id, urls, stopper: stopper.clone(), opened: Instant::now(), said: None, legacy: false });
        (id, engine.full_url(&format!("/rocx/live?{}", query.join("&"))), stopper)
    });
    log(Level::Info, "rocx: the channels' stream opened (/rocx/live)");
    crate::http::stream(id, url, vec![("accept".into(), "text/event-stream".into()), ("cache-control".into(), "no-store".into())], stopper);
}

fn stream_heard(heard: Heard) {
    match heard {
        Heard::Opened { status, events, .. } => {
            if events {
                return;
            }
            // A 5xx (a proxy while the server restarts) is tried again; anything else says no server
            // answers channels here.
            if status < 500 {
                give_up();
            } else {
                dropped(format!("{status}"));
            }
        }
        Heard::Event { name, data } => {
            let (url, said) = data.split_once('\n').map(|(url, said)| (url.to_string(), said.to_string())).unwrap_or((data.clone(), String::new()));
            if name == "hello" {
                engine::with(|engine| {
                    if let Some(stream) = engine.live.stream.as_mut() {
                        stream.said = Some(url.clone());
                    }
                });
                follow();
                send();
                return;
            }
            let legacy = engine::with(|engine| match engine.live.stream.as_mut() {
                Some(stream) if stream.said.is_none() && !stream.legacy => {
                    stream.legacy = true;
                    true
                }
                _ => false,
            });
            if legacy {
                follow();
            }
            dispatch(&name, &url, &said);
        }
        Heard::Closed(why) => dropped(why.unwrap_or_else(|| "closed".into())),
    }
}

/// The stream dropped: opened again after a wait (`connect`'s end).
fn dropped(why: String) {
    let wait = engine::with(|engine| {
        let live = &mut engine.live;
        let stream = live.stream.take()?;
        stream.stopper.stop();
        live.drops = if stream.opened.elapsed() >= STEADY { 0 } else { live.drops + 1 };
        let doubled = FIRST_WAIT.saturating_mul(1u64 << live.drops.saturating_sub(1).min(16));
        let jitter = 1.0 + (random_id().as_bytes()[0] as f64 % 16.0) / 64.0;
        live.retrying = true;
        Some(((doubled.min(MOST_WAIT)) as f64 * jitter) as u64)
    });
    let Some(wait) = wait else { return };
    log(Level::Info, &format!("rocx: the channels' stream dropped ({why}): opened again in {wait} ms"));
    let made = crate::generation();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(wait));
        crate::post(crate::Message::Retry(made));
    });
}

/// The wait after a drop is over: the stream opened again with the set as it is.
pub fn retry() {
    engine::with(|engine| {
        engine.live.retrying = false;
        engine.live.changed = true;
    });
}

fn give_up() {
    let subscribers = engine::with(|engine| {
        let live = &mut engine.live;
        if let Some(stream) = live.stream.take() {
            stream.stopper.stop();
        }
        live.unavailable = Some((404, "no server answers channels here (a static copy of the site?)".into()));
        live.subscribers.keys().copied().collect::<Vec<u64>>()
    });
    let told = format!("{{\"Refused\":[404,{}]}}", quoted("no server answers channels here (a static copy of the site?)"));
    for subscriber in subscribers {
        deliver(subscriber, told.clone());
    }
}

/// An event of the stream, for the channel at `url` (`Hub.dispatch`).
fn dispatch(kind: &str, url: &str, said: &str) {
    if kind == "replaced" {
        engine::with(|engine| engine.live.tab = random_id());
        return;
    }
    let found = engine::with(|engine| {
        let channel = engine.live.channels.get_mut(url)?;
        let heard = match kind {
            "resync" => {
                channel.open = true;
                channel.refused = None;
                channel.ended = None;
                "\"Resync\"".to_string()
            }
            "message" => format!("{{\"Message\":{}}}", quoted(said)),
            "refused" => {
                let refusal = json::parse(said);
                let status = refusal.as_ref().and_then(|value| value.get("status")).and_then(Value::as_u64).unwrap_or(0);
                let why = refusal.as_ref().and_then(|value| value.get("why")).and_then(Value::as_str).unwrap_or("").to_string();
                channel.refused = Some((status, why.clone()));
                format!("{{\"Refused\":[{status},{}]}}", quoted(&why))
            }
            "ended" => {
                channel.open = false;
                let ended = if json::parse(said).is_some() { said.to_string() } else { quoted(said) };
                channel.ended = Some(ended.clone());
                format!("{{\"Ended\":{ended}}}")
            }
            _ => return None,
        };
        Some((heard, channel.subscribers.clone()))
    });
    let Some((heard, subscribers)) = found else { return };
    for subscriber in subscribers {
        deliver(subscriber, heard.clone());
    }
}

/// Its subscriber hears it after what it heard before (`deliver`, `pump`).
fn deliver(subscriber: u64, heard: String) {
    let ready = engine::with(|engine| {
        let found = engine.live.subscribers.get_mut(&subscriber)?;
        found.queue.push_back(heard);
        Some(())
    });
    if ready.is_none() {
        return;
    }
    loop {
        let next = engine::with(|engine| {
            let found = engine.live.subscribers.get_mut(&subscriber)?;
            let heard = found.queue.pop_front()?;
            let (kept, scope, owner) = (found.kept, found.scope.clone(), found.owner);
            engine.has_kept(kept).then_some((kept, scope, owner, heard))
        });
        let Some((kept, scope, owner, heard)) = next else { return };
        engine::handle(kept, heard, scope, owner, None, None);
    }
}

/// What was said and asked for, in one `POST /rocx/live/send` (`Hub.send`).
fn send() {
    let found = engine::with(|engine| {
        let live = &mut engine.live;
        let current = live.stream.as_ref().map(|stream| stream.id);
        let items: Vec<(String, Option<u64>)> = std::mem::take(&mut live.outbox).into_iter().filter(|(_, stream)| stream.is_none() || *stream == current).collect();
        if items.is_empty() {
            return None;
        }
        let said = live.stream.as_ref().and_then(|stream| stream.said.clone());
        let query = format!("tab={}{}", encode(&tab(live)), said.map(|said| format!("&stream={}", encode(&said))).unwrap_or_default());
        let body = format!("[{}]", items.iter().map(|(item, _)| item.as_str()).collect::<Vec<_>>().join(","));
        let url = engine.full_url(&format!("/rocx/live/send?{query}"));
        engine.ask(Asked::LiveSend(items, current), "POST", url, vec![("content-type".into(), "application/json".into())], body);
        Some(())
    });
    let _ = found;
}

/// The post's answer (`Hub.send`'s): refusals said, a stream the server doesn't know replaced, and
/// the stream closed once nothing is left to subscribe to.
pub fn sent(items: Vec<(String, Option<u64>)>, stream: Option<u64>, result: Result<crate::http::Answered, String>) {
    match result {
        Ok(answer) if answer.status == 200 => {
            let refused = json::parse(&answer.body).and_then(|body| body.get("refused").cloned()).and_then(Value::into_array).unwrap_or_default();
            for each in refused {
                let index = each.get("index").and_then(Value::as_u64).unwrap_or(0) as usize;
                let status = each.get("status").and_then(Value::as_u64).unwrap_or(0);
                let why = each.get("why").and_then(Value::as_str).unwrap_or("").to_string();
                let Some((item, named)) = items.get(index) else { continue };
                if named.is_some() && status == 404 {
                    // The stream it named has ended (or the server never had it): a new one.
                    let current = engine::with(|engine| engine.live.stream.as_ref().map(|stream| stream.id));
                    if current == stream && stream.is_some() {
                        engine::with(|engine| {
                            if let Some(old) = engine.live.stream.take() {
                                old.stopper.stop();
                            }
                            engine.live.changed = true;
                        });
                    }
                } else {
                    let channel = json::parse(item).and_then(|item| item.get("channel").and_then(Value::as_str).map(str::to_string)).unwrap_or_default();
                    log(Level::Warn, &format!("rocx: {channel} refused what was said: {status} {why}"));
                }
            }
        }
        Ok(answer) if answer.status == 404 || answer.status == 405 => engine::with(|engine| {
            engine.live.unavailable.get_or_insert((404, "no server answers channels here (a static copy of the site?)".into()));
        }),
        Ok(answer) if answer.status >= 300 => log(Level::Warn, &format!("rocx: what was said wasn't heard: {} {}", answer.status, answer.body)),
        // Offline: what was said is lost, as it would be if the tab closed.
        _ => {}
    }
    // Nothing left to subscribe to, and the stream told so: it closes.
    engine::with(|engine| {
        let live = &mut engine.live;
        if live.channels.is_empty()
            && let Some(current) = live.stream.as_ref()
            && Some(current.id) == stream
            && current.urls.is_empty()
        {
            current.stopper.stop();
            live.stream = None;
        }
    });
}

/// What a stream heard (`Message::Heard`), on the main thread: a `listen!`'s, or the channels'.
pub fn heard(id: u64, heard: Heard) {
    if !engine::started() {
        return;
    }
    if engine::with(|engine| engine.live.listening.contains_key(&id)) {
        listen_heard(id, heard);
        return;
    }
    if engine::with(|engine| engine.live.stream.as_ref().is_some_and(|stream| stream.id == id)) {
        stream_heard(heard);
    }
}

/// Every stream stopped (a dev client's new build replaces the engine).
pub fn stop_all(live: &Live) {
    for listening in live.listening.values() {
        listening.stopper.stop();
    }
    if let Some(stream) = &live.stream {
        stream.stopper.stop();
    }
}
