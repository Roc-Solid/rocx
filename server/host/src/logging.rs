//! The server's log, on stderr: a line an event, the host's own (starting, stopping, crashes,
//! forwarding) and Roc's (`Log.info!` and the others, through `Host.log!`) alike, each a level, a
//! message and fields, written by one formatter in one of two formats:
//!
//! - pretty, for a person at a terminal: `14:03:12 INFO  gate failed error="no session" path=/admin`
//!   (the local time, the level, coloured when stderr is a terminal, the message, then the fields,
//!   a value quoted when it has a space, a quote, an `=` or a control character in it, or is empty);
//! - JSON, for a machine: `{"time":"2026-11-21T13:03:12.345Z","level":"info","msg":"gate failed",
//!   "error":"no session","path":"/admin"}` (the time in RFC 3339, UTC), the fields beside `time`,
//!   `level` and `msg`.
//!
//! A field named `time`, `level` or `msg` is written as `fields.time` (and so on), in both, so it
//! can't take the place of the line's own. Either way an event is one line: what would break it
//! (a newline in a message) is escaped.
//!
//! The app chooses the format in its `program` (`logs: { format: Auto }`, or `Pretty`, or `Json`),
//! which the platform hands over as it starts (`Host.log_format!`, `choose`). Before that (a server
//! that can't start), and under `Auto`: `ROCX_LOG` (`pretty` or `json`) if it is set, read once
//! (`start`), or else pretty when stderr is a terminal and JSON when it isn't (a server in
//! production, its log collected).
//!
//! Logging is off the request path: an event is a record (its time, level, message and fields, the
//! format it is to be written in) put on a queue, and the call goes on. One thread, the writer,
//! takes them in order (one queue, first in first out: a request's lines come out in the order it
//! logged them, and whole, never interleaved with another's), formats them (parsing Roc's fields
//! there too) and writes them through a buffer, flushed whenever the queue is empty: a line is out
//! at once when the server is quiet, and lines go out together when it is busy.
//!
//! The queue holds `QUEUED` events. When it is full, a call that logs waits for room: a log that
//! drops lines when the server is busiest loses what was most worth reading, and a log that grows
//! without bound turns a flood of lines into a server out of memory. Waiting slows the callers
//! down to what stderr takes, which is what the log can keep anyway. A stop flushes the queue
//! (`flush`, before the process exits), and so does a crash the host can't recover from, or a
//! panic. Before the writer starts, and on it, an event is written there and then.

use chrono::{DateTime, Utc};
use serde_json::Value;
use std::cell::Cell;
use std::io::{BufWriter, Write};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};
use std::time::Duration;

unsafe extern "C" {
    fn tzset();
}

/// How many events the queue holds before a call that logs waits for room.
const QUEUED: usize = 64 * 1024;

/// How long `flush` waits for the writer: it never hangs a stop.
const FLUSH_WAIT: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Level {
    Debug,
    Info,
    Warn,
    Error,
}

impl Level {
    /// The level `Host.log!` is given: 0 debug, 1 info, 2 warn, 3 (or more) error.
    fn from_code(code: u8) -> Level {
        match code {
            0 => Level::Debug,
            1 => Level::Info,
            2 => Level::Warn,
            _ => Level::Error,
        }
    }

    /// As JSON writes it.
    fn name(self) -> &'static str {
        match self {
            Level::Debug => "debug",
            Level::Info => "info",
            Level::Warn => "warn",
            Level::Error => "error",
        }
    }

    /// As a pretty line shows it: as wide as each other.
    fn shown(self) -> &'static str {
        match self {
            Level::Debug => "DEBUG",
            Level::Info => "INFO ",
            Level::Warn => "WARN ",
            Level::Error => "ERROR",
        }
    }

    /// Its colour on a terminal (ANSI): grey, green, yellow, red.
    fn colour(self) -> &'static str {
        match self {
            Level::Debug => "\x1b[90m",
            Level::Info => "\x1b[32m",
            Level::Warn => "\x1b[33m",
            Level::Error => "\x1b[31m",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Format {
    Pretty,
    Json,
}

const UNCHOSEN: u8 = 0;
const PRETTY: u8 = 1;
const JSON: u8 = 2;

/// The format the app chose (`choose`), or `UNCHOSEN` until it has: then `Auto`'s.
static FORMAT: AtomicU8 = AtomicU8::new(UNCHOSEN);

/// `ROCX_LOG`, read once: the format it names, if it names one, and what it said.
static GIVEN: OnceLock<(Option<Format>, Option<String>)> = OnceLock::new();

fn given() -> &'static (Option<Format>, Option<String>) {
    GIVEN.get_or_init(|| {
        let said = std::env::var("ROCX_LOG").ok().map(|value| value.trim().to_string()).filter(|value| !value.is_empty());
        let format = match said.as_deref().map(str::to_ascii_lowercase).as_deref() {
            Some("pretty") => Some(Format::Pretty),
            Some("json") => Some(Format::Json),
            _ => None,
        };
        (format, said)
    })
}

static TERMINAL: OnceLock<bool> = OnceLock::new();

/// Whether stderr is a terminal (a person reads it), asked once.
fn terminal() -> bool {
    *TERMINAL.get_or_init(|| unsafe { libc::isatty(libc::STDERR_FILENO) } == 1)
}

/// `Auto`'s format: `ROCX_LOG`'s, or pretty on a terminal and JSON elsewhere.
fn auto() -> Format {
    given().0.unwrap_or(if terminal() { Format::Pretty } else { Format::Json })
}

fn format() -> Format {
    match FORMAT.load(Ordering::Relaxed) {
        PRETTY => Format::Pretty,
        JSON => Format::Json,
        _ => auto(),
    }
}

/// Whether the log is JSON, read without allocating or locking (a signal handler asks:
/// `coroutine::overflowed`): the app's choice, or else `Auto`'s, as far as it is known yet.
pub fn is_json() -> bool {
    match FORMAT.load(Ordering::Relaxed) {
        PRETTY => false,
        JSON => true,
        _ => match GIVEN.get().and_then(|given| given.0) {
            Some(format) => format == Format::Json,
            None => !matches!(TERMINAL.get(), Some(true)),
        },
    }
}

/// An event, as it waits on the queue: formatted by the writer.
struct Record {
    time: DateTime<Utc>,
    format: Format,
    level: Level,
    message: String,
    fields: Fields,
}

enum Fields {
    /// The host's.
    Pairs(Vec<(String, Value)>),
    /// Roc's: JSON, an object (a record's), or none ("").
    Json(String),
}

enum Message {
    Record(Record),
    /// Everything before this is written and flushed: then the writer says so.
    Flush(std::sync::mpsc::Sender<()>),
}

/// Where events are queued for the writer, once it has started.
static QUEUE: OnceLock<SyncSender<Message>> = OnceLock::new();

thread_local! {
    /// Whether this thread is the writer (which can't wait on its own queue).
    static WRITER: Cell<bool> = const { Cell::new(false) };
}

/// The server is starting: `ROCX_LOG` is read (once, now), and a value it doesn't know is said;
/// the writer starts, and a panic, from here on, is an event (flushed, as the process may end).
pub fn start() {
    // The time zone (`TZ`, or the system's), read now, for the pretty lines' local time.
    unsafe { tzset() };
    let (queue, queued) = sync_channel(QUEUED);
    let started = std::thread::Builder::new().name("rocx-log".into()).spawn(move || {
        WRITER.with(|writer| writer.set(true));
        write_all(queued);
    });
    if started.is_ok() {
        let _ = QUEUE.set(queue);
    }
    std::panic::set_hook(Box::new(|info| {
        let thread = std::thread::current().name().unwrap_or("unnamed").to_string();
        error("rocx server: the host panicked", &[("thread", thread.into()), ("error", info.to_string().into())]);
        flush();
    }));
    if let (None, Some(said)) = given() {
        warn("rocx server: ROCX_LOG is pretty or json; the log's format is guessed instead", &[("ROCX_LOG", said.as_str().into())]);
    }
}

/// The app's format, from its `program` (`Host.log_format!`): 0 `Auto`, 1 `Pretty`, 2 `Json`.
pub fn choose(code: u8) {
    let format = match code {
        1 => Format::Pretty,
        2 => Format::Json,
        _ => auto(),
    };
    FORMAT.store(if format == Format::Pretty { PRETTY } else { JSON }, Ordering::Relaxed);
}

/// Waits (a few seconds at most) until every event logged before is written: before the process
/// exits, or aborts.
pub fn flush() {
    let Some(queue) = QUEUE.get() else { return };
    if WRITER.with(Cell::get) {
        return;
    }
    let (done, finished) = std::sync::mpsc::channel();
    if queue.send(Message::Flush(done)).is_ok() {
        let _ = finished.recv_timeout(FLUSH_WAIT);
    }
}

pub fn debug(message: &str, fields: &[(&str, Value)]) {
    log(Level::Debug, message, fields)
}

pub fn info(message: &str, fields: &[(&str, Value)]) {
    log(Level::Info, message, fields)
}

pub fn warn(message: &str, fields: &[(&str, Value)]) {
    log(Level::Warn, message, fields)
}

pub fn error(message: &str, fields: &[(&str, Value)]) {
    log(Level::Error, message, fields)
}

/// Logs an event: its level, its message and its fields.
pub fn log(level: Level, message: &str, fields: &[(&str, Value)]) {
    let fields = fields.iter().map(|(key, value)| (key.to_string(), value.clone())).collect();
    queued(Record { time: Utc::now(), format: format(), level, message: message.to_string(), fields: Fields::Pairs(fields) });
}

/// An event from Roc (`Host.log!`): its level's code, its message, and its fields as JSON, an
/// object (a record's), or none (""). Anything else JSON is one field, `fields`.
pub fn from_roc(level: u8, message: String, fields: String) {
    queued(Record { time: Utc::now(), format: format(), level: Level::from_code(level), message, fields: Fields::Json(fields) });
}

/// Puts the event on the queue, waiting for room if it is full; with no writer to take it (not
/// started yet, or this is it, or it has gone), writes it now. Waiting for room blocks the thread,
/// even a Roc thread (whose other calls wait too, rather than pause): the writer is a thread of its
/// own that never waits on Roc, so the queue soon has room, and a full one is rare (a burst of
/// thousands of lines), and a brake on whatever logs that much.
fn queued(record: Record) {
    let record = match QUEUE.get() {
        Some(queue) if !WRITER.with(Cell::get) => match queue.try_send(Message::Record(record)) {
            Ok(()) => return,
            Err(TrySendError::Full(message)) => match queue.send(message) {
                Ok(()) => return,
                Err(gone) => gone.0,
            },
            Err(TrySendError::Disconnected(message)) => message,
        },
        _ => Message::Record(record),
    };
    if let Message::Record(record) = record {
        let mut out = std::io::stderr().lock();
        let _ = out.write_all(line(&record).as_bytes());
    }
}

/// The writer: each event in turn, written to a buffer flushed whenever the queue is empty.
fn write_all(queued: Receiver<Message>) {
    let mut out = BufWriter::with_capacity(64 * 1024, std::io::stderr());
    while let Ok(first) = queued.recv() {
        let mut next = Some(first);
        while let Some(message) = next {
            match message {
                Message::Record(record) => {
                    let _ = out.write_all(line(&record).as_bytes());
                }
                Message::Flush(done) => {
                    let _ = out.flush();
                    let _ = done.send(());
                }
            }
            next = queued.try_recv().ok();
        }
        let _ = out.flush();
    }
    let _ = out.flush();
}

/// A field's name as the line writes it: one that would take the place of the line's own is moved
/// aside.
fn key(name: &str) -> std::borrow::Cow<'_, str> {
    match name {
        "time" | "level" | "msg" => format!("fields.{name}").into(),
        _ => name.into(),
    }
}

/// Roc's fields, from their JSON.
fn parsed(fields: &str) -> Vec<(String, Value)> {
    if fields.trim().is_empty() {
        return Vec::new();
    }
    match serde_json::from_str::<Value>(fields) {
        Ok(Value::Object(object)) => object.into_iter().collect(),
        Ok(Value::Null) => Vec::new(),
        Ok(other) => vec![("fields".to_string(), other)],
        Err(_) => vec![("fields".to_string(), Value::String(fields.to_string()))],
    }
}

/// The event's line, in its format, ending in a newline.
fn line(record: &Record) -> String {
    let parsed;
    let fields: &[(String, Value)] = match &record.fields {
        Fields::Pairs(pairs) => pairs,
        Fields::Json(json) => {
            parsed = self::parsed(json);
            &parsed
        }
    };
    let level = record.level;
    let mut out = String::with_capacity(64 + record.message.len());
    match record.format {
        Format::Pretty => {
            out.push_str(&local_time(record.time));
            out.push(' ');
            if terminal() {
                out.push_str(level.colour());
                out.push_str(level.shown());
                out.push_str("\x1b[0m");
            } else {
                out.push_str(level.shown());
            }
            out.push(' ');
            one_line(&record.message, &mut out);
            for (name, value) in fields {
                out.push(' ');
                one_line(&key(name), &mut out);
                out.push('=');
                out.push_str(&pretty(value));
            }
        }
        Format::Json => {
            out.push_str("{\"time\":\"");
            out.push_str(&record.time.to_rfc3339_opts(chrono::SecondsFormat::Millis, true));
            out.push_str("\",\"level\":\"");
            out.push_str(level.name());
            out.push_str("\",\"msg\":");
            out.push_str(&json_string(&record.message));
            for (name, value) in fields {
                out.push(',');
                out.push_str(&json_string(&key(name)));
                out.push(':');
                out.push_str(&value.to_string());
            }
            out.push('}');
        }
    }
    out.push('\n');
    out
}

/// The time of day where the server is (`HH:MM:SS`), from the C library: chrono's own time zone
/// lookup needs CoreFoundation on macOS, which an app isn't linked with.
fn local_time(time: DateTime<Utc>) -> String {
    let seconds = time.timestamp() as libc::time_t;
    let mut parts: libc::tm = unsafe { std::mem::zeroed() };
    if unsafe { libc::localtime_r(&seconds, &mut parts) }.is_null() {
        return time.format("%H:%M:%S").to_string();
    }
    format!("{:02}:{:02}:{:02}", parts.tm_hour, parts.tm_min, parts.tm_sec)
}

fn json_string(text: &str) -> String {
    serde_json::to_string(text).unwrap_or_else(|_| "\"\"".into())
}

/// A field's value on a pretty line: text as it is, anything else as JSON; quoted (as a JSON
/// string) when it is empty or has a space, a quote, an `=` or a control character in it.
fn pretty(value: &Value) -> String {
    let text = match value {
        Value::String(text) => text.clone(),
        other => other.to_string(),
    };
    if text.is_empty() || text.chars().any(|c| c.is_whitespace() || c.is_control() || c == '"' || c == '=') {
        json_string(&text)
    } else {
        text
    }
}

/// Text on a pretty line, kept to it: a control character (a newline, an escape that would talk to
/// the terminal) is written escaped, a tab as it is.
fn one_line(text: &str, out: &mut String) {
    for c in text.chars() {
        if c.is_control() && c != '\t' {
            out.extend(c.escape_default());
        } else {
            out.push(c);
        }
    }
}
