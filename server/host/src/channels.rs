//! Channels (`Channel`, `Endpoint.subscribe!`): one stream per browser tab, `GET /rocx/live`, held
//! here, on the async side, never by a thread of Roc's. A stream carries the channels its query
//! names (`?tab=<id>&c=<url>&c=<url>…`); each is a route's `channel!`, at its URL.
//!
//! Roc runs only briefly, a call at a time, on a thread from the blocking pool that goes back when
//! the call is done: a channel's check when the stream opens (with its route's `on_open!`), again
//! on each beat, what a page says (`POST /rocx/live/send`, the route's `receive!`), and the end of a
//! subscription (its `on_close!`). Each is a request the host makes of the app (`respond!`) for the
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
//! The stream, as server-sent events: `event: resync | message | refused | ended`, the channel's URL
//! as the first `data:` line, then what it says (a message's JSON; `{"status":403,"why":"…"}`; the
//! JSON string why it ended); and `: beat` every beat (15 s), on which each channel's check runs
//! again: one that now refuses is `ended`, and its `on_close!` is told. A server error at a beat
//! (500) ends nothing. A subscriber that falls behind its channel's backlog (`Live`'s 256) gets a
//! `resync` (and `on_open!`'s messages) instead of what it missed; one behind on latest-wins
//! messages only misses the older ones. A slow client's frames wait in a short queue; past it, its
//! ordered messages wait in their topics' backlogs, and its latest-wins ones replace each other.

use crate::http::{Body, Config};
use crate::{hosted, live, logging, roc};
use bytes::Bytes;
use http_body_util::{BodyExt, Full, LengthLimitError, Limited, StreamBody};
use hyper::body::{Frame, Incoming};
use hyper::header::{ALLOW, CACHE_CONTROL, CONTENT_TYPE, HeaderMap, HeaderValue};
use hyper::{Method, Request, Response, StatusCode};
use serde_json::Value;
use std::collections::VecDeque;
use std::convert::Infallible;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{broadcast, mpsc};
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

/// The request headers a channel's requests don't pass on: their own, and the stream's conditions.
const NOT_PASSED: [&str; 10] = ["accept", "content-type", "content-length", "transfer-encoding", "connection", "range", "if-none-match", "if-modified-since", "x-rocx-channel", "x-rocx-tab"];

/// What every request about a stream's (or a post's) channels is made with: its request's headers
/// (cookies among them), what the server was started with, and the tab.
struct Asking {
    headers: String,
    started: String,
    dev: bool,
    tab: String,
}

impl Asking {
    fn new(headers: &HeaderMap, config: &Config, tab: String) -> Asking {
        let headers = headers
            .iter()
            .filter(|(name, _)| !NOT_PASSED.contains(&name.as_str()))
            .map(|(name, value)| format!("{}: {}", name.as_str(), String::from_utf8_lossy(value.as_bytes())))
            .collect::<Vec<_>>()
            .join("\n");
        Asking { headers, started: config.context.clone(), dev: config.dev, tab }
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

/// Asks the app about the channel at `url` (`op`: `open`, `check`, `receive`, `close`), on this
/// (blocking) thread, as a request of its own. A crash is a 500.
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
    let asked = hosted::Asked::new(method, url.to_string(), headers, Bytes::from(body), asking.started.clone(), asking.dev);
    let answered = hosted::call_asking(asked.clone(), || roc::respond(&asked.method, &asked.target, &asked.headers, &asked.body, &asked.started));
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
    use ring::rand::SecureRandom;
    let mut bytes = [0u8; 12];
    let _ = ring::rand::SystemRandom::new().fill(&mut bytes);
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
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

// ---- The stream ----

/// `GET /rocx/live?tab=<id>&c=<url>&c=<url>…`: the tab's stream of its channels. It answers at once;
/// each channel's check runs as the stream starts.
pub fn stream(request: Request<Incoming>, config: &Config) -> Response<Body> {
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
    let asking = Arc::new(Asking::new(request.headers(), config, tab));
    let (out, frames) = mpsc::channel::<Bytes>(16);
    tokio::spawn(run(asking, urls, out, config.live_beat));
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

/// Runs the requests about subscriptions, one after another, on a thread of the blocking pool.
fn asked(asking: &Arc<Asking>, ops: Vec<Op>) -> JoinHandle<Vec<(Op, Answered)>> {
    let asking = asking.clone();
    tokio::task::spawn_blocking(move || {
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
async fn running(job: &mut Option<JoinHandle<Vec<(Op, Answered)>>>) -> Vec<(Op, Answered)> {
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

/// The stream, from its start to its client's going (or the server's stopping): each channel's
/// check, then what is published, a beat at a time; then each subscription's end, told.
async fn run(asking: Arc<Asking>, urls: Vec<String>, out: mpsc::Sender<Bytes>, beat: Duration) {
    let (heard_to, mut heard) = mpsc::channel::<(u64, Heard)>(256);
    let (latest_to, mut latest_heard) = mpsc::unbounded_channel::<(u64, String, Bytes)>();
    let mut queue: VecDeque<Bytes> = VecDeque::from([Bytes::from_static(b": rocx live\n\n")]);
    let mut latest: Vec<(u64, String, Bytes)> = Vec::new();
    let mut subscriptions: Vec<Subscription> = Vec::new();
    // Listening before the checks run: nothing published meanwhile is missed.
    let mut ids = 0;
    for url in urls {
        ids += 1;
        let ordered = forward(ids, url.clone(), live::listen(&format!("channel:{url}")), heard_to.clone());
        let newest = forward_latest(ids, url.clone(), live::listen(&format!("latest:{url}")), latest_to.clone());
        subscriptions.push(Subscription { id: ids, url, state: State::Opening, who: None, closes: false, held: Vec::new(), behind: false, forwarders: vec![ordered, newest] });
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
    drop((heard_to, latest_to));

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
            done = running(&mut job) => {
                job = None;
                for (op, answered) in done {
                    match op {
                        Op::Open { id, url } => opened(&mut subscriptions, id, &url, answered, &mut queue, &mut ops),
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

    // The client has gone (or the server stops): what was asked finishes, then each subscription
    // its check let in is told it ended.
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
    let closes: Vec<Op> = subscriptions
        .drain(..)
        .filter_map(|each| match (&each.who, each.closes) {
            (Some(who), true) => Some(Op::Close { url: each.url.clone(), who: who.clone(), why: Value::String("Gone".into()) }),
            _ => None,
        })
        .collect();
    if !closes.is_empty() {
        for (op, answered) in asked(&asking, closes).await.unwrap_or_default() {
            if let (Op::Close { url, .. }, true) = (op, answered.status >= 300) {
                logging::warn("rocx server: a channel's on_close! failed", &[("channel", url.as_str().into()), ("status", answered.status.into()), ("error", answered.text.as_str().into())]);
            }
        }
    }
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

/// What a channel's check answered as it was opened (or opened again).
fn opened(subscriptions: &mut Vec<Subscription>, id: u64, url: &str, answered: Answered, queue: &mut VecDeque<Bytes>, ops: &mut VecDeque<Op>) {
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

/// A subscription its check now refuses: `ended`, its route's `on_close!` told, and it is gone.
fn ended(subscriptions: &mut Vec<Subscription>, at: usize, why: &str, queue: &mut VecDeque<Bytes>, ops: &mut VecDeque<Op>) {
    let each = subscriptions.remove(at);
    queue.push_back(ended_event(&each.url, why));
    if let (Some(who), true) = (&each.who, each.closes) {
        ops.push_back(Op::Close { url: each.url.clone(), who: who.clone(), why: serde_json::json!({ "Refused": why }) });
    }
}

// ---- What pages say ----

/// `POST /rocx/live/send?tab=<id>`, a JSON list, each `{"channel":"<url>","message":…}` (what a
/// page says: its channel's check runs, then its route's `receive!`), or
/// `{"channel":"<url>","resync":true}` (the tab's stream resyncs that channel). 204 when every
/// item was taken; else 200, `{"refused":[{"index":0,"status":403,"why":"…"}]}`.
pub async fn send(request: Request<Incoming>, config: Arc<Config>) -> Response<Body> {
    if *request.method() != Method::POST {
        return not_allowed("/rocx/live/send", "POST", request.method());
    }
    // JSON only: a form from another site can't send it without asking first (CORS).
    let json = request.headers().get(CONTENT_TYPE).and_then(|value| value.to_str().ok()).is_some_and(|value| value.split(';').next().unwrap_or("").trim().eq_ignore_ascii_case("application/json"));
    if !json {
        return text(StatusCode::UNSUPPORTED_MEDIA_TYPE, "/rocx/live/send reads JSON (application/json)");
    }
    let fields = query_fields(request.uri().query().unwrap_or(""));
    let tab = fields.iter().find(|(name, _)| name == "tab").and_then(|(_, value)| tab_id(value));
    let asking = Arc::new(Asking::new(request.headers(), &config, tab.clone().unwrap_or_default()));
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
    for (index, item) in items.into_iter().enumerate() {
        let Some(url) = item.get("channel").and_then(Value::as_str).and_then(channel_url) else {
            refused.push(serde_json::json!({ "index": index, "status": 400, "why": "which channel? (\"channel\": its URL)" }));
            continue;
        };
        if item.get("resync").and_then(Value::as_bool) == Some(true) {
            match &tab {
                Some(tab) => live::publish(&format!("tab:{tab}"), &format!("resync {url}")),
                None => refused.push(serde_json::json!({ "index": index, "status": 400, "why": "a resync is the tab's: ?tab=<id>" })),
            }
        } else if let Some(message) = item.get("message") {
            said.push((index, url, message.to_string()));
        } else {
            refused.push(serde_json::json!({ "index": index, "status": 400, "why": "say a message, or ask for a resync" }));
        }
    }
    if !said.is_empty() {
        let answers = tokio::task::spawn_blocking(move || said.into_iter().map(|(index, url, message)| (index, ask(&asking, "receive", "POST", &url, message))).collect::<Vec<_>>()).await.unwrap_or_default();
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

