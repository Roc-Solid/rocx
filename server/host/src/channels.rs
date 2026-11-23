//! Channels (`Channel`, `Endpoint.subscribe!`): one stream per browser tab, `GET /rocx/live`, held
//! here, on the async side, never by a thread of Roc's. A stream carries the channels its query
//! names (`?tab=<id>&c=<url>&c=<url>…`); each is a route's `channel!`, at its URL.
//!
//! Roc runs only briefly, a call at a time (`in_roc`: a coroutine on one of Roc's threads, which
//! pauses while it waits): a channel's check when the stream opens (with its route's `on_open!`),
//! again on each beat, what a page says (`POST /rocx/live/send`, the route's `receive!`), and the
//! end of a subscription (its `on_close!`). Each is a request the host makes of the app (`respond!`) for the
//! channel's URL, with the stream's headers (its cookies), so the app's middleware and the route's
//! run as for any request to it, and `x-rocx-channel` saying what is asked: `open`, `check`,
//! `receive`, or `close` (which the app answers outside its middleware). No request from outside
//! carries that header: `http` drops it.
//!
//! What is published on a channel (`Endpoint.publish!`) is a `Live` topic, `channel:<url>`, and
//! what is published latest-wins (`publish_latest!`) is `latest:<url>`. A stream listens to a
//! channel's topics before its check runs, so nothing published meanwhile is missed: what comes is
//! held until the check has let it in, then sent after its `resync` and its `on_open!` messages.
//! Its own topic, `tab:<id>`, carries the tab's asks for a resync (`POST /rocx/live/send`).
//!
//! A tab has one stream, which says its id first (`event: hello`: random, 192 bits, the stream's
//! and its tab's alone). What the page subscribes to changes over it (D-057): the hub posts
//! `subscribe` and `unsubscribe` with that id (`POST /rocx/live/send?tab=…&stream=…`), and the
//! stream opens the channel (its check, then its `on_open!`) or ends it, telling its route's
//! `on_close!` `Dropped`; a stream that ends (its client gone, the server stopping) tells each
//! subscription still on it `Gone`. A post's request (its cookies: the tab's as they are now) is
//! what the stream asks the app with from then on, at its beats too. A post naming a stream that
//! has ended, or another tab's, is refused (404), as is one another site's page sent (403, by its
//! `Origin`).
//!
//! The hub opens a new stream when the old one dropped, and the host may hear the old one end after
//! the new one starts (a connection's close takes a while to reach it). So a new stream for a tab
//! ends the tab's old one first (`event: replaced`, should anyone still read it), waits for its
//! subscriptions' `on_close!`, and only then runs its own checks and `on_open!`: a route's hooks hear
//! a tab's subscriptions end before they start again, in order, as they do on one stream (an
//! unsubscribe's `on_close!` before a later subscribe's `on_open!`). A page that hears `replaced` is
//! another tab with the same id (a duplicated browser tab copies its sessionStorage): it takes a new
//! id, and connects again.
//!
//! The stream, as server-sent events: `event: hello`, its id, first; then `event: resync | message
//! | refused | ended`, the channel's URL as the first `data:` line, then what it says (a message's JSON; `{"status":403,"why":"…"}`; the
//! JSON string why it ended); and `: beat` every beat (15 s), on which each channel's check runs
//! again: one that now refuses is `ended`, and its `on_close!` is told. A server error at a beat
//! (500) ends nothing. A subscriber that falls behind its channel's backlog (`Live`'s 256) gets a
//! `resync` (and `on_open!`'s messages) instead of what it missed; one behind on latest-wins
//! messages only misses the older ones. A slow client's frames wait in a short queue; past it, its
//! ordered messages wait in their topics' backlogs, and its latest-wins ones replace each other.

use crate::http::{Body, Config};
use crate::{coroutine, hosted, live, logging, roc};
use bytes::Bytes;
use http_body_util::{BodyExt, Full, LengthLimitError, Limited, StreamBody};
use hyper::body::{Frame, Incoming};
use hyper::header::{ALLOW, CACHE_CONTROL, CONTENT_TYPE, HeaderMap, HeaderValue};
use hyper::{Method, Request, Response, StatusCode};
use serde_json::Value;
use std::collections::{HashMap, VecDeque};
use std::convert::Infallible;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tokio::sync::{Notify, broadcast, mpsc, watch};
use tokio::task::JoinHandle;

/// The most channels one stream carries.
const MOST_CHANNELS: usize = 64;
/// What a subscription holds while its check runs; past that, it is resynced once it is in.
const MOST_HELD: usize = 1024;
/// Frames waiting for a slow client, past which its ordered messages wait in their topics.
const MOST_QUEUED: usize = 64;
/// The most a `POST /rocx/live/send` carries: items, and bytes.
const MOST_SAID: usize = 256;
const MOST_SAID_BYTES: usize = 1 << 20;

/// How long a new stream waits for its tab's old one to have ended (its `on_close!`s told) before
/// it opens its own subscriptions anyway.
const MOST_WAIT_FOR_OLD: Duration = Duration::from_secs(10);

/// The random bytes of a stream's id (192 bits), as hex.
const STREAM_ID_BYTES: usize = 24;

/// The request headers a channel's requests don't pass on: their own, and the stream's conditions.
const NOT_PASSED: [&str; 10] = ["accept", "content-type", "content-length", "transfer-encoding", "connection", "range", "if-none-match", "if-modified-since", "x-rocx-channel", "x-rocx-tab"];

/// What every request about a stream's (or a post's) channels is made with: its request's headers
/// (cookies among them), the address its connection came from, what the server was started with,
/// and the tab.
struct Asking {
    headers: String,
    peer: String,
    started: String,
    dev: bool,
    tab: String,
}

impl Asking {
    fn new(headers: &HeaderMap, config: &Config, tab: String, peer: String) -> Asking {
        let headers = headers
            .iter()
            .filter(|(name, _)| !NOT_PASSED.contains(&name.as_str()))
            .map(|(name, value)| format!("{}: {}", name.as_str(), String::from_utf8_lossy(value.as_bytes())))
            .collect::<Vec<_>>()
            .join("\n");
        Asking { headers, peer, started: config.context.clone(), dev: config.dev, tab }
    }
}

/// What the app answered a request about a channel.
struct Answered {
    status: u16,
    text: String,
}

impl Answered {
    /// Why it refused, for the page: its text, or where it would have sent the visitor.
    fn why(&self, headers: &str) -> String {
        let location = headers.lines().find_map(|line| line.split_once(':').filter(|(name, _)| name.trim().eq_ignore_ascii_case("location")).map(|(_, value)| value.trim().to_string()));
        match location {
            Some(location) if (300..400).contains(&self.status) => format!("redirected to {location}"),
            _ => self.text.chars().take(500).collect(),
        }
    }
}

/// Asks the app about the channel at `url` (`op`: `open`, `check`, `receive`, `close`), in this
/// call into Roc (`in_roc`), as a request of its own. A crash is a 500.
fn ask(asking: &Asking, op: &str, method: &str, url: &str, body: String) -> (Answered, String) {
    let mut headers = asking.headers.clone();
    for line in ["accept: application/json".to_string(), format!("x-rocx-channel: {op}"), format!("x-rocx-tab: {}", asking.tab)] {
        if !headers.is_empty() {
            headers.push('\n');
        }
        headers.push_str(&line);
    }
    if !body.is_empty() {
        headers.push_str("\ncontent-type: application/json");
    }
    let asked = hosted::Asked::new(method, url.to_string(), headers, Bytes::from(body), asking.peer.clone(), asking.started.clone(), asking.dev);
    let answered = hosted::call_asking(asked.clone(), || roc::respond(&asked));
    match answered {
        Ok(answer) => {
            if let Some(feed) = answer.feed {
                roc::drop_feed(feed);
            }
            if let Some(page) = answer.page {
                roc::drop_page(page);
            }
            let text = match answer.bytes {
                Some(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
                None => answer.body,
            };
            (Answered { status: answer.status, text }, answer.headers)
        }
        Err(crash) => {
            logging::error("rocx server: Roc crashed", &[("channel", url.into()), ("asked", op.into()), ("error", crash.0.as_str().into())]);
            let text = if asking.dev { format!("Roc crashed: {}", crash.0) } else { "Something went wrong.".into() };
            (Answered { status: 500, text }, String::new())
        }
    }
}

/// A channel's URL as a query names it: a path (`/org/acme/news`), no query, nothing that isn't text.
fn channel_url(given: &str) -> Option<String> {
    let fine = given.starts_with('/') && !given.starts_with("//") && given.len() <= 2048 && !given.chars().any(|c| c.is_control() || c == '?' || c == '#');
    fine.then(|| given.to_string())
}

/// A tab's id as a query names it: up to 64 letters, digits, `-` and `_`.
fn tab_id(given: &str) -> Option<String> {
    let fine = !given.is_empty() && given.len() <= 64 && given.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_');
    fine.then(|| given.to_string())
}

/// A query's fields, each decoded (`%2F` is `/`), in order.
fn query_fields(query: &str) -> Vec<(String, String)> {
    query
        .split('&')
        .filter(|pair| !pair.is_empty())
        .map(|pair| {
            let (name, value) = pair.split_once('=').unwrap_or((pair, ""));
            (decoded(name), decoded(value))
        })
        .collect()
}

fn decoded(text: &str) -> String {
    let bytes = text.as_bytes();
    let hex = |byte: u8| (byte as char).to_digit(16).map(|digit| digit as u8);
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            if let (Some(high), Some(low)) = (hex(bytes[index + 1]), hex(bytes[index + 2])) {
                out.push(high * 16 + low);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// A random tab id, for a stream whose query names none.
fn fresh_tab() -> String {
    random_hex(12)
}

/// `count` random bytes, as hex.
fn random_hex(count: usize) -> String {
    use ring::rand::SecureRandom;
    let mut bytes = vec![0u8; count];
    let _ = ring::rand::SystemRandom::new().fill(&mut bytes);
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Whether a request comes from a page of this site, or from no page (curl), as the app's
/// `Server.same_origin` reads it: a browser says which site's page sent it (`Origin`), and its
/// host must be the request's.
fn same_origin(headers: &HeaderMap) -> bool {
    let Some(origin) = headers.get("origin") else { return true };
    let origin = String::from_utf8_lossy(origin.as_bytes());
    let host = headers.get("host").map(|host| String::from_utf8_lossy(host.as_bytes()).into_owned());
    match origin.split_once("://") {
        Some((_, after)) => host.as_deref() == Some(after),
        None => false,
    }
}

/// An event of the stream: its kind, the channel's URL, and what it says (a `data:` line each).
fn event(kind: &str, url: &str, said: Option<&str>) -> Bytes {
    let mut frame = format!("event: {kind}\ndata: {url}\n");
    for line in said.into_iter().flat_map(|said| said.split('\n')) {
        frame.push_str("data: ");
        frame.push_str(line);
        frame.push('\n');
    }
    frame.push('\n');
    Bytes::from(frame)
}

fn refused_event(url: &str, status: u16, why: &str) -> Bytes {
    event("refused", url, Some(&serde_json::json!({ "status": status, "why": why }).to_string()))
}

fn ended_event(url: &str, why: &str) -> Bytes {
    event("ended", url, Some(&Value::String(why.to_string()).to_string()))
}

fn text(status: StatusCode, body: impl Into<Bytes>) -> Response<Body> {
    let mut response = Response::new(Full::new(body.into()).boxed());
    *response.status_mut() = status;
    response.headers_mut().insert(CONTENT_TYPE, HeaderValue::from_static("text/plain; charset=utf-8"));
    response
}

fn not_allowed(path: &str, allowed: &'static str, method: &Method) -> Response<Body> {
    let mut response = text(StatusCode::METHOD_NOT_ALLOWED, format!("{path} takes {allowed}, not {method}"));
    response.headers_mut().insert(ALLOW, HeaderValue::from_static(allowed));
    response
}

// ---- A tab's one stream ----

/// The stream a tab has: its number (a newer one replaces it), how to tell it it has been
/// replaced, and whether it has ended (its `on_close!`s told).
struct Held {
    number: u64,
    replaced: Arc<Notify>,
    ended: watch::Receiver<bool>,
}

/// Each tab's stream, by its id.
fn held() -> &'static Mutex<HashMap<String, Held>> {
    static HELD: OnceLock<Mutex<HashMap<String, Held>>> = OnceLock::new();
    HELD.get_or_init(|| Mutex::new(HashMap::new()))
}

/// A stream's place as its tab's one stream: told when a newer one replaces it, and telling the
/// newer one when it has ended.
struct Place {
    tab: String,
    number: u64,
    replaced: Arc<Notify>,
    ended: watch::Sender<bool>,
}

impl Place {
    /// The stream for `tab` from now on, and the one it replaces, if the tab had one: told so here.
    fn take(tab: &str) -> (Place, Option<watch::Receiver<bool>>) {
        static NUMBERS: OnceLock<std::sync::atomic::AtomicU64> = OnceLock::new();
        let number = NUMBERS.get_or_init(Default::default).fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
        let replaced = Arc::new(Notify::new());
        let (ended, ended_heard) = watch::channel(false);
        let old = held().lock().unwrap_or_else(|poisoned| poisoned.into_inner()).insert(tab.to_string(), Held { number, replaced: replaced.clone(), ended: ended_heard });
        let old = old.map(|old| {
            old.replaced.notify_one();
            old.ended
        });
        (Place { tab: tab.to_string(), number, replaced, ended }, old)
    }
}

impl Drop for Place {
    /// It has ended: the tab has no stream now, unless a newer one has taken its place.
    fn drop(&mut self) {
        let mut held = held().lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if held.get(&self.tab).is_some_and(|each| each.number == self.number) {
            held.remove(&self.tab);
        }
        drop(held);
        let _ = self.ended.send(true);
    }
}

// ---- A stream's id: what a page's posts change it by ----

/// What a page's post tells its tab's stream (D-057): subscribe to a channel, or drop one. Each
/// carries the post's request, which the stream asks the app with from then on.
enum Control {
    Subscribe { url: String, asking: Arc<Asking> },
    Unsubscribe { url: String, asking: Arc<Asking> },
}

/// An open stream, by its id: its tab, and how to tell it a page's changes.
struct Reachable {
    tab: String,
    control: mpsc::UnboundedSender<Control>,
}

fn reachable() -> &'static Mutex<HashMap<String, Reachable>> {
    static REACHABLE: OnceLock<Mutex<HashMap<String, Reachable>>> = OnceLock::new();
    REACHABLE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// A stream's id, reachable while it is held: the stream has ended once it is dropped.
struct StreamId(String);

impl StreamId {
    fn new(tab: &str, control: mpsc::UnboundedSender<Control>) -> StreamId {
        let id = random_hex(STREAM_ID_BYTES);
        reachable().lock().unwrap_or_else(|poisoned| poisoned.into_inner()).insert(id.clone(), Reachable { tab: tab.to_string(), control });
        StreamId(id)
    }
}

impl Drop for StreamId {
    fn drop(&mut self) {
        reachable().lock().unwrap_or_else(|poisoned| poisoned.into_inner()).remove(&self.0);
    }
}

// ---- The stream ----

/// `GET /rocx/live?tab=<id>&c=<url>&c=<url>…`: the tab's stream of its channels. It answers at once;
/// each channel's check runs as the stream starts.
pub fn stream(request: Request<Incoming>, config: &Config, peer: String) -> Response<Body> {
    if !matches!(*request.method(), Method::GET | Method::HEAD) {
        return not_allowed("/rocx/live", "GET", request.method());
    }
    let fields = query_fields(request.uri().query().unwrap_or(""));
    let tab = fields.iter().find(|(name, _)| name == "tab").and_then(|(_, value)| tab_id(value)).unwrap_or_else(fresh_tab);
    let mut urls: Vec<String> = Vec::new();
    for url in fields.iter().filter(|(name, _)| name == "c").filter_map(|(_, value)| channel_url(value)) {
        if !urls.contains(&url) {
            urls.push(url);
        }
    }
    if urls.len() > MOST_CHANNELS {
        return text(StatusCode::BAD_REQUEST, format!("a stream carries {MOST_CHANNELS} channels at the most"));
    }
    let mut response = Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, "text/event-stream")
        .header(CACHE_CONTROL, "no-store")
        // Proxies that buffer answers (nginx) send each event as it comes.
        .header("x-accel-buffering", "no");
    if *request.method() == Method::HEAD {
        return response.body(Full::new(Bytes::new()).boxed()).unwrap();
    }
    let asking = Arc::new(Asking::new(request.headers(), config, tab, peer));
    let (out, frames) = mpsc::channel::<Bytes>(16);
    // Its id, reachable from now: a post made as soon as the page hears it finds it.
    let (control_to, control) = mpsc::unbounded_channel();
    let id = StreamId::new(&asking.tab, control_to);
    tokio::spawn(run(asking, urls, out, config.live_beat, id, control));
    let frames = futures_util::stream::unfold(frames, |mut frames| async move { frames.recv().await.map(|data| (Ok::<_, Infallible>(Frame::data(data)), frames)) });
    response = response.header("x-rocx-live", "1");
    response.body(StreamBody::new(frames).boxed()).unwrap()
}

/// Where a subscription is: its check running as the stream starts (`Opening`), in (`Open`), or its
/// check running again for a resync (`Reopening`).
#[derive(PartialEq, Clone, Copy)]
enum State {
    Opening,
    Open,
    Reopening,
}

struct Subscription {
    id: u64,
    url: String,
    state: State,
    /// Who its check said the subscriber is (JSON), once it is in.
    who: Option<String>,
    /// Whether its route has `on_close!`, to be told when it ends.
    closes: bool,
    /// What came while its check ran, sent once it is in.
    held: Vec<Bytes>,
    /// It fell behind while its check ran: resynced again once it is in.
    behind: bool,
    /// The page dropped it while its check ran (D-057): once that is answered, its route's
    /// `on_close!` is told `Dropped` if it was let in, and it is gone.
    dropped: bool,
    forwarders: Vec<JoinHandle<()>>,
}

impl Drop for Subscription {
    fn drop(&mut self) {
        for forwarder in &self.forwarders {
            forwarder.abort();
        }
    }
}

/// What a forwarder heard on a subscription's topic: a message (its frame), or that it fell behind.
enum Heard {
    Message(Bytes),
    Behind,
    /// On the tab's own topic: a resync of the channel at this URL.
    Resync(String),
}

/// A request about a subscription, for the app.
enum Op {
    Open { id: u64, url: String },
    Check { id: u64, url: String },
    Close { url: String, who: String, why: Value },
}

/// Forwards what is published on a channel's topic, in order, to the stream's queue: when that is
/// full, it waits, and its topic's backlog holds what comes (and, past it, the stream hears `Behind`).
fn forward(id: u64, url: String, mut topic: broadcast::Receiver<live::Message>, to: mpsc::Sender<(u64, Heard)>) -> JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            let heard = match topic.recv().await {
                Ok(message) => Heard::Message(event("message", &url, Some(&message.text))),
                Err(broadcast::error::RecvError::Lagged(_)) => Heard::Behind,
                Err(broadcast::error::RecvError::Closed) => return,
            };
            if to.send((id, heard)).await.is_err() {
                return;
            }
        }
    })
}

/// Forwards a channel's latest-wins messages (`<key JSON>\n<message JSON>`): never waiting, and a
/// subscriber behind on them misses the older ones, with no resync.
fn forward_latest(id: u64, url: String, mut topic: broadcast::Receiver<live::Message>, to: mpsc::UnboundedSender<(u64, String, Bytes)>) -> JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            match topic.recv().await {
                Ok(message) => {
                    let (key, said) = message.text.split_once('\n').unwrap_or(("", &message.text));
                    if to.send((id, key.to_string(), event("message", &url, Some(said)))).is_err() {
                        return;
                    }
                }
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => return,
            }
        }
    })
}

/// Runs `work` (requests of the app, one after another) where Roc's calls run: a call of its own,
/// a coroutine on one of Roc's threads (`coroutine`). The one place this module starts Roc.
fn in_roc<T: Send + 'static>(work: impl FnOnce() -> T + Send + 'static) -> coroutine::Running<T> {
    coroutine::run(work)
}

/// Runs the requests about subscriptions, one after another (`in_roc`).
fn asked(asking: &Arc<Asking>, ops: Vec<Op>) -> coroutine::Running<Vec<(Op, Answered)>> {
    let asking = asking.clone();
    in_roc(move || {
        ops.into_iter()
            .map(|op| {
                let (answered, headers) = match &op {
                    Op::Open { url, .. } => ask(&asking, "open", "GET", url, String::new()),
                    Op::Check { url, .. } => ask(&asking, "check", "GET", url, String::new()),
                    Op::Close { url, who, why } => ask(&asking, "close", "POST", url, serde_json::json!({ "who": serde_json::from_str::<Value>(who).unwrap_or(Value::Null), "why": why }).to_string()),
                };
                let answered = if answered.status == 200 || answered.status == 204 { answered } else { Answered { text: answered.why(&headers), ..answered } };
                (op, answered)
            })
            .collect()
    })
}

/// Waits for the running requests, if there are any.
async fn running(job: &mut Option<coroutine::Running<Vec<(Op, Answered)>>>) -> Vec<(Op, Answered)> {
    match job {
        Some(handle) => handle.await.unwrap_or_default(),
        None => std::future::pending().await,
    }
}

/// What a channel's check answered as the stream opened it: where it is, who it let in, what it is
/// sent first, and whether its route has `on_close!`.
struct Opened {
    url: String,
    who: String,
    opened: Vec<String>,
    closes: bool,
}

fn opened_of(answered: &Answered) -> Result<Opened, String> {
    let value: Value = serde_json::from_str(&answered.text).map_err(|error| format!("the channel's answer isn't one ({error})"))?;
    let url = value.get("url").and_then(Value::as_str).ok_or("the channel's answer has no url")?.to_string();
    let who = value.get("who").map(Value::to_string).ok_or("the channel's answer has no who")?;
    let opened = value.get("opened").and_then(Value::as_array).map(|messages| messages.iter().map(Value::to_string).collect()).unwrap_or_default();
    let closes = value.get("closes").and_then(Value::as_bool).unwrap_or(false);
    Ok(Opened { url, who, opened, closes })
}

/// Listens to a channel's topics, and adds its subscription, its check still to run (`Opening`).
/// Listening before the check runs: nothing published meanwhile is missed.
fn subscribed(subscriptions: &mut Vec<Subscription>, id: u64, url: String, heard_to: &mpsc::Sender<(u64, Heard)>, latest_to: &mpsc::UnboundedSender<(u64, String, Bytes)>) {
    let ordered = forward(id, url.clone(), live::listen(&format!("channel:{url}")), heard_to.clone());
    let newest = forward_latest(id, url.clone(), live::listen(&format!("latest:{url}")), latest_to.clone());
    subscriptions.push(Subscription { id, url, state: State::Opening, who: None, closes: false, held: Vec::new(), behind: false, dropped: false, forwarders: vec![ordered, newest] });
}

/// The stream, from its start to its client's going (or the server's stopping): each channel's
/// check, then what is published, a beat at a time, and the channels the page subscribes to and
/// drops (`control`); then each subscription's end, told.
async fn run(mut asking: Arc<Asking>, urls: Vec<String>, out: mpsc::Sender<Bytes>, beat: Duration, id: StreamId, mut control: mpsc::UnboundedReceiver<Control>) {
    let (heard_to, mut heard) = mpsc::channel::<(u64, Heard)>(256);
    let (latest_to, mut latest_heard) = mpsc::unbounded_channel::<(u64, String, Bytes)>();
    let mut queue: VecDeque<Bytes> = VecDeque::from([Bytes::from_static(b": rocx live\n\n"), Bytes::from(format!("event: hello\ndata: {}\n\n", id.0))]);
    let mut latest: Vec<(u64, String, Bytes)> = Vec::new();
    let mut subscriptions: Vec<Subscription> = Vec::new();
    let mut ids = 0;
    for url in urls {
        ids += 1;
        subscribed(&mut subscriptions, ids, url, &heard_to, &latest_to);
    }
    // The tab's own topic: its asks for a resync.
    let tab_topic = live::listen(&format!("tab:{}", asking.tab));
    let tab_forwarder = {
        let to = heard_to.clone();
        let mut topic = tab_topic;
        tokio::spawn(async move {
            loop {
                match topic.recv().await {
                    Ok(message) => {
                        if let Some(url) = message.text.strip_prefix("resync ") {
                            if to.send((0, Heard::Resync(url.to_string()))).await.is_err() {
                                return;
                            }
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => return,
                }
            }
        })
    };

    // The tab's one stream from now on: its old one, if it is still held, ends first, and its
    // subscriptions' ends are told before these start (listening already, so nothing is missed).
    let (place, old) = Place::take(&asking.tab);
    if let Some(mut old) = old {
        let _ = tokio::time::timeout(MOST_WAIT_FOR_OLD, old.wait_for(|ended| *ended)).await;
    }

    let mut ops: VecDeque<Op> = subscriptions.iter().map(|each| Op::Open { id: each.id, url: each.url.clone() }).collect();
    let mut job = None;
    let mut checking = false;
    let mut beats = tokio::time::interval_at(tokio::time::Instant::now() + beat, beat);
    beats.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        if job.is_none() && !ops.is_empty() {
            job = Some(asked(&asking, ops.drain(..).collect()));
        }
        tokio::select! {
            biased;
            _ = out.closed() => break,
            _ = hosted::stopped() => break,
            _ = place.replaced.notified() => {
                // A newer stream for this tab: this one ends. Its page, if it still reads, is another
                // tab with this one's id, and takes an id of its own.
                let _ = out.try_send(Bytes::from_static(b"event: replaced\ndata: \n\n"));
                break;
            }
            done = running(&mut job) => {
                job = None;
                // The ends of subscriptions the page dropped while their checks ran: told before
                // anything asked since (a subscribe to the same channel again, say).
                let mut first = Vec::new();
                for (op, answered) in done {
                    match op {
                        Op::Open { id, url } => opened(&mut subscriptions, id, &url, answered, &mut queue, &mut ops, &mut first),
                        Op::Check { id, url } => {
                            checking = false;
                            checked(&mut subscriptions, id, &url, answered, &mut queue, &mut ops);
                        }
                        Op::Close { url, .. } => {
                            if answered.status >= 300 {
                                logging::warn("rocx server: a channel's on_close! failed", &[("channel", url.as_str().into()), ("status", answered.status.into()), ("error", answered.text.as_str().into())]);
                            }
                        }
                    }
                }
                for op in first.into_iter().rev() {
                    ops.push_front(op);
                }
            }
            Some(said) = control.recv() => {
                match said {
                    Control::Subscribe { url, asking: now } => {
                        asking = now;
                        if let Some(each) = subscriptions.iter_mut().find(|each| each.url == url && !each.dropped) {
                            // Subscribed already (a post that crossed a reconnect): it is sent its
                            // resync again, as a new subscriber to an open channel is.
                            resync(each, &mut ops);
                        } else if subscriptions.iter().filter(|each| !each.dropped).count() >= MOST_CHANNELS {
                            queue.push_back(refused_event(&url, 400, &format!("a stream carries {MOST_CHANNELS} channels at the most")));
                        } else {
                            ids += 1;
                            subscribed(&mut subscriptions, ids, url.clone(), &heard_to, &latest_to);
                            ops.push_back(Op::Open { id: ids, url });
                        }
                    }
                    Control::Unsubscribe { url, asking: now } => {
                        asking = now;
                        unsubscribed(&mut subscriptions, &url, &mut queue, &mut latest, &mut ops);
                    }
                }
            }
            _ = beats.tick() => {
                queue.push_back(Bytes::from_static(b": beat\n\n"));
                // Every channel in is checked again, unless the last beat's checks are still running.
                if !checking {
                    let open: Vec<Op> = subscriptions.iter().filter(|each| each.state == State::Open).map(|each| Op::Check { id: each.id, url: each.url.clone() }).collect();
                    checking = !open.is_empty();
                    ops.extend(open);
                }
            }
            permit = out.reserve(), if !queue.is_empty() || !latest.is_empty() => {
                let Ok(permit) = permit else { break };
                let frame = match queue.pop_front() {
                    Some(frame) => frame,
                    None => latest.remove(0).2,
                };
                permit.send(frame);
            }
            Some((id, said)) = heard.recv(), if queue.len() < MOST_QUEUED => {
                match said {
                    Heard::Resync(url) => {
                        if let Some(each) = subscriptions.iter_mut().find(|each| each.url == url) {
                            resync(each, &mut ops);
                        }
                    }
                    Heard::Message(frame) => {
                        if let Some(each) = subscriptions.iter_mut().find(|each| each.id == id) {
                            if each.state == State::Open {
                                queue.push_back(frame);
                            } else if each.held.len() < MOST_HELD {
                                each.held.push(frame);
                            } else {
                                each.held.clear();
                                each.behind = true;
                            }
                        }
                    }
                    Heard::Behind => {
                        if let Some(each) = subscriptions.iter_mut().find(|each| each.id == id) {
                            resync(each, &mut ops);
                        }
                    }
                }
            }
            Some((id, key, frame)) = latest_heard.recv() => {
                if subscriptions.iter().any(|each| each.id == id && each.state == State::Open) {
                    match latest.iter_mut().find(|(at, said, _)| *at == id && *said == key) {
                        Some(waiting) => waiting.2 = frame,
                        None => latest.push((id, key, frame)),
                    }
                }
            }
        }
    }

    // The client has gone (or the server stops): posts reach it no more; what was asked finishes,
    // then the ends already due are told (those the page dropped, or a beat's check refused), then
    // each subscription still on it that its check let in is told `Gone` (one the page dropped
    // while its check ran, `Dropped`).
    drop(id);
    drop(out);
    tab_forwarder.abort();
    if let Some(handle) = job.take() {
        for (op, answered) in handle.await.unwrap_or_default() {
            if let Op::Open { id, .. } = op {
                if let (Some(each), Ok(opened)) = (subscriptions.iter_mut().find(|each| each.id == id), opened_of(&answered)) {
                    if answered.status == 200 {
                        each.who = Some(opened.who);
                        each.closes = opened.closes;
                    }
                }
            }
        }
    }
    let mut closes: Vec<Op> = ops.drain(..).filter(|op| matches!(op, Op::Close { .. })).collect();
    closes.extend(subscriptions.drain(..).filter_map(|each| match (&each.who, each.closes) {
        (Some(who), true) => Some(Op::Close { url: each.url.clone(), who: who.clone(), why: Value::String(if each.dropped { "Dropped" } else { "Gone" }.into()) }),
        _ => None,
    }));
    if !closes.is_empty() {
        for (op, answered) in asked(&asking, closes).await.unwrap_or_default() {
            if let (Op::Close { url, .. }, true) = (op, answered.status >= 300) {
                logging::warn("rocx server: a channel's on_close! failed", &[("channel", url.as_str().into()), ("status", answered.status.into()), ("error", answered.text.as_str().into())]);
            }
        }
    }
    // Ended, every end told: a newer stream for the tab may start its subscriptions.
    drop(place);
}

/// A subscription that fell behind, or whose tab asked: its check runs again, and once it is in,
/// it gets a `resync` and its `on_open!` messages; meanwhile what comes is held.
fn resync(each: &mut Subscription, ops: &mut VecDeque<Op>) {
    match each.state {
        State::Open => {
            each.state = State::Reopening;
            ops.push_back(Op::Open { id: each.id, url: each.url.clone() });
        }
        // Its check is running: once it is in, again.
        State::Opening | State::Reopening => each.behind = true,
    }
}

/// What a channel's check answered as it was opened (or opened again). One the page dropped
/// meanwhile is gone now, its route's `on_close!` told `Dropped` (in `first`) if it was in.
fn opened(subscriptions: &mut Vec<Subscription>, id: u64, url: &str, answered: Answered, queue: &mut VecDeque<Bytes>, ops: &mut VecDeque<Op>, first: &mut Vec<Op>) {
    let Some(at) = subscriptions.iter().position(|each| each.id == id) else { return };
    let let_in = if answered.status == 200 {
        match opened_of(&answered) {
            Ok(opened) if opened.url == url => Ok(opened),
            Ok(opened) => Err((400, format!("the channel is at {}", opened.url))),
            Err(why) => Err((500, why)),
        }
    } else {
        Err((answered.status, answered.text))
    };
    if subscriptions[at].dropped {
        let each = subscriptions.remove(at);
        let (who, closes) = match let_in {
            Ok(opened) => (Some(opened.who), opened.closes),
            // Refused as it opened again: it was in until then.
            Err(_) => (each.who.clone(), each.closes),
        };
        if let (Some(who), true) = (who, closes) {
            first.push(Op::Close { url: each.url.clone(), who, why: Value::String("Dropped".into()) });
        }
        return;
    }
    let each = &mut subscriptions[at];
    match let_in {
        Ok(opened) => {
            each.who = Some(opened.who);
            each.closes = opened.closes;
            each.state = State::Open;
            queue.push_back(event("resync", url, None));
            for message in &opened.opened {
                queue.push_back(event("message", url, Some(message)));
            }
            queue.extend(each.held.drain(..));
            if std::mem::take(&mut each.behind) {
                resync(each, ops);
            }
        }
        // Refused as the stream opened it: it never was in.
        Err((status, why)) if each.state == State::Opening => {
            queue.push_back(refused_event(url, status, &why));
            subscriptions.remove(at);
        }
        // Refused as it opened again: it was in, and has ended.
        Err((_, why)) => ended(subscriptions, at, &why, queue, ops),
    }
}

/// What a channel's check answered at a beat: still in (who it is now), or ended. A server error
/// (500) ends nothing: the next beat checks again.
fn checked(subscriptions: &mut Vec<Subscription>, id: u64, url: &str, answered: Answered, queue: &mut VecDeque<Bytes>, ops: &mut VecDeque<Op>) {
    let Some(at) = subscriptions.iter().position(|each| each.id == id && each.state == State::Open) else { return };
    match answered.status {
        200 => {
            if let Some(who) = serde_json::from_str::<Value>(&answered.text).ok().and_then(|value| value.get("who").map(Value::to_string)) {
                subscriptions[at].who = Some(who);
            }
        }
        500.. => logging::warn("rocx server: a channel's check failed at a beat", &[("channel", url.into()), ("status", answered.status.into()), ("error", answered.text.as_str().into())]),
        _ => ended(subscriptions, at, &answered.text, queue, ops),
    }
}

/// The page dropped the channel at `url` (D-057): it is gone, what it had waiting to be sent goes
/// with it, and its route's `on_close!` is told `Dropped`, if its check let it in. One whose check
/// hasn't been asked is gone at once (it never was in, unless it was being opened again); one whose
/// check is being answered goes once it has been (`opened`).
fn unsubscribed(subscriptions: &mut Vec<Subscription>, url: &str, queue: &mut VecDeque<Bytes>, latest: &mut Vec<(u64, String, Bytes)>, ops: &mut VecDeque<Op>) {
    let Some(at) = subscriptions.iter().position(|each| each.url == url && !each.dropped) else { return };
    let id = subscriptions[at].id;
    let asked = |op: &Op| matches!(op, Op::Open { id: of, .. } | Op::Check { id: of, .. } if *of == id);
    let waiting = ops.iter().any(|op| matches!(op, Op::Open { id: of, .. } if *of == id));
    ops.retain(|op| !asked(op));
    queue.retain(|frame| !for_channel(frame, url));
    latest.retain(|(of, _, _)| *of != id);
    let each = &mut subscriptions[at];
    let in_flight = matches!(each.state, State::Opening | State::Reopening) && !waiting;
    if in_flight {
        each.dropped = true;
        each.held.clear();
        for forwarder in each.forwarders.drain(..) {
            forwarder.abort();
        }
        return;
    }
    let each = subscriptions.remove(at);
    let was_in = each.state != State::Opening;
    if let (Some(who), true, true) = (&each.who, each.closes, was_in) {
        ops.push_back(Op::Close { url: each.url.clone(), who: who.clone(), why: Value::String("Dropped".into()) });
    }
}

/// Whether a frame of the stream is about the channel at `url` (its first `data:` line).
fn for_channel(frame: &Bytes, url: &str) -> bool {
    let text = String::from_utf8_lossy(frame);
    let mut lines = text.split('\n');
    lines.next().is_some_and(|line| line.starts_with("event: ")) && lines.next().and_then(|line| line.strip_prefix("data: ")) == Some(url)
}

/// A subscription its check now refuses: `ended`, its route's `on_close!` told, and it is gone.
fn ended(subscriptions: &mut Vec<Subscription>, at: usize, why: &str, queue: &mut VecDeque<Bytes>, ops: &mut VecDeque<Op>) {
    let each = subscriptions.remove(at);
    queue.push_back(ended_event(&each.url, why));
    if let (Some(who), true) = (&each.who, each.closes) {
        ops.push_back(Op::Close { url: each.url.clone(), who: who.clone(), why: serde_json::json!({ "Refused": why }) });
    }
}

// ---- What pages say ----

/// `POST /rocx/live/send?tab=<id>&stream=<id>`, a JSON list, each `{"channel":"<url>","message":…}`
/// (what a page says: its channel's check runs, then its route's `receive!`),
/// `{"channel":"<url>","resync":true}` (the tab's stream resyncs that channel), or
/// `{"channel":"<url>","subscribe":true}` and `{"channel":"<url>","unsubscribe":true}` (the stream
/// `stream` names, the tab's, opens the channel or drops it: D-057). 204 when every item was taken;
/// else 200, `{"refused":[{"index":0,"status":403,"why":"…"}]}`. Sent by another site's page (its
/// `Origin`), 403.
pub async fn send(request: Request<Incoming>, config: Arc<Config>, peer: String) -> Response<Body> {
    if *request.method() != Method::POST {
        return not_allowed("/rocx/live/send", "POST", request.method());
    }
    if !same_origin(request.headers()) {
        return text(StatusCode::FORBIDDEN, "POST /rocx/live/send is sent from a page of this site");
    }
    // JSON only: a form from another site can't send it without asking first (CORS).
    let json = request.headers().get(CONTENT_TYPE).and_then(|value| value.to_str().ok()).is_some_and(|value| value.split(';').next().unwrap_or("").trim().eq_ignore_ascii_case("application/json"));
    if !json {
        return text(StatusCode::UNSUPPORTED_MEDIA_TYPE, "/rocx/live/send reads JSON (application/json)");
    }
    let fields = query_fields(request.uri().query().unwrap_or(""));
    let tab = fields.iter().find(|(name, _)| name == "tab").and_then(|(_, value)| tab_id(value));
    let stream = fields.iter().find(|(name, _)| name == "stream").map(|(_, value)| value.clone()).unwrap_or_default();
    let asking = Arc::new(Asking::new(request.headers(), &config, tab.clone().unwrap_or_default(), peer));
    let body = match Limited::new(request.into_body(), MOST_SAID_BYTES).collect().await {
        Ok(collected) => collected.to_bytes(),
        Err(error) if error.is::<LengthLimitError>() => return text(StatusCode::PAYLOAD_TOO_LARGE, "what was said is too large"),
        Err(_) => return text(StatusCode::BAD_REQUEST, "could not read what was said"),
    };
    let items = match serde_json::from_slice::<Value>(&body) {
        Ok(Value::Array(items)) if items.len() <= MOST_SAID => items,
        Ok(Value::Array(_)) => return text(StatusCode::BAD_REQUEST, format!("say {MOST_SAID} things a post at the most")),
        _ => return text(StatusCode::BAD_REQUEST, "/rocx/live/send reads a list: [{\"channel\":\"/…\",\"message\":…}]"),
    };
    let mut refused = Vec::new();
    let mut said = Vec::new();
    // The stream `stream` names, if it is open and the tab's: its changes go there, in order.
    let control = tab.as_ref().and_then(|tab| {
        let reachable = reachable().lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        reachable.get(&stream).filter(|open| open.tab == *tab).map(|open| open.control.clone())
    });
    for (index, item) in items.into_iter().enumerate() {
        let Some(url) = item.get("channel").and_then(Value::as_str).and_then(channel_url) else {
            refused.push(serde_json::json!({ "index": index, "status": 400, "why": "which channel? (\"channel\": its URL)" }));
            continue;
        };
        let subscribe = item.get("subscribe").and_then(Value::as_bool) == Some(true);
        if subscribe || item.get("unsubscribe").and_then(Value::as_bool) == Some(true) {
            let changed = match &control {
                Some(control) => {
                    let asking = asking.clone();
                    control.send(if subscribe { Control::Subscribe { url, asking } } else { Control::Unsubscribe { url, asking } }).is_ok()
                }
                None => false,
            };
            if !changed {
                refused.push(serde_json::json!({ "index": index, "status": 404, "why": "no open stream of this tab has that id (?stream=): open one (GET /rocx/live)" }));
            }
        } else if item.get("resync").and_then(Value::as_bool) == Some(true) {
            match &tab {
                Some(tab) => live::publish(&format!("tab:{tab}"), &format!("resync {url}")),
                None => refused.push(serde_json::json!({ "index": index, "status": 400, "why": "a resync is the tab's: ?tab=<id>" })),
            }
        } else if let Some(message) = item.get("message") {
            said.push((index, url, message.to_string()));
        } else {
            refused.push(serde_json::json!({ "index": index, "status": 400, "why": "say a message, subscribe, unsubscribe, or ask for a resync" }));
        }
    }
    if !said.is_empty() {
        let answers = in_roc(move || said.into_iter().map(|(index, url, message)| (index, ask(&asking, "receive", "POST", &url, message))).collect::<Vec<_>>()).await.unwrap_or_default();
        for (index, (answered, headers)) in answers {
            if !(200..300).contains(&answered.status) {
                refused.push(serde_json::json!({ "index": index, "status": answered.status, "why": answered.why(&headers) }));
            }
        }
    }
    if refused.is_empty() {
        let mut response = Response::new(Full::new(Bytes::new()).boxed());
        *response.status_mut() = StatusCode::NO_CONTENT;
        return response;
    }
    refused.sort_by_key(|each| each["index"].as_u64());
    let mut response = Response::new(Full::new(Bytes::from(serde_json::json!({ "refused": refused }).to_string())).boxed());
    response.headers_mut().insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    response
}

