//! What the host does for Roc: the functions `server/platform/Host.roc` declares, each exported
//! under the name the platform's `hosted` section gives it. They are general: Postgres, time, live
//! topics and rooms, settings and the environment, calls run in isolation, actors' mailboxes and
//! timers (`actors`), named values, TCP and TLS, HTTP requests, random numbers, AES-GCM. Jobs,
//! cron, migrations, actors' state and email are Roc, built on them (`server/platform`).
//!
//! Each runs in the call into Roc that asked for it, a coroutine on one of Roc's threads
//! (`coroutine`), so it may wait (on Postgres, say) without holding up other requests: the call
//! pauses until the future is done, and its thread runs other calls meanwhile (`wait`). It must not
//! panic into Roc, so each catches its own. One calls back into Roc, `isolated` (`roc::isolated`),
//! as a guarded call of its own, so a crash in it comes back here, and never skips a frame of ours.
//! An actor's turn (`actor_turn`) is a call of its own too, which its actor's task starts.
//!
//! Every call into Roc has a context (`call`): the request it answers (if any: `call_asking`), the
//! stream it sends (if any), whether it is a background loop, its deadline (a job's time limit),
//! the transaction it began, the topics it listens to, the rooms it is in, the connections it
//! opened, and, in an actor's turn, the actor and the ones waiting on it (`Turn`). When the call
//! ends, however it ends, the transaction is rolled back if still open, it leaves its rooms and
//! closes its connections.
//!
//! A call with a deadline (`Host.isolated!` given a time limit: a job's) is cut off by the first
//! effect that waits past it (Postgres, a socket, a request to another server, a sleep, an
//! actor's answer, a live topic): the effect stops waiting, lets go of what it holds (a statement
//! is cancelled and its connection closed), and jumps back to the call's guard, as a crash does
//! (`cut_off`), so the call can't carry on past its limit whatever it does with errors. Calls it
//! runs inside it share its deadline; an actor it asks doesn't (its turn is its own, and ends as
//! it would). Roc that loops without an effect is ended where it runs (`preempt`, D-057), which
//! is told the deadline of the call running on each thread as calls start, pause, resume and end.

use crate::abi::{
    AnonStruct2e6fc7635560c0c3 as Isolated, AnonStruct3ed536693d8b85f3 as Answered, AnonStructFa59a42fc999ca94 as Heard, HostDbExecuteResult,
    AnonStruct932918cc5391b9a4 as Ranged, AnonStructF4ca8ee1c443b810 as Headed, HostBlobHeadResult, HostBlobHeadResultPayload,
    HostBlobHeadResultTag, HostBlobKeysResult, HostBlobKeysResultPayload, HostBlobKeysResultTag, HostBlobRangeResult,
    HostBlobRangeResultPayload, HostBlobRangeResultTag, RocList,
    HostDbExecuteResultPayload, HostHttpSendResult, HostHttpSendResultPayload, HostHttpSendResultTag, HostZoneOffsetResult,
    HostZoneOffsetResultPayload, HostZoneOffsetResultTag,
    HostDbExecuteResultTag, HostDbScriptResult, HostDbScriptResultPayload, HostDbScriptResultTag, HostStoreGetResult as TextResult,
    HostStoreGetResultPayload as TextPayload, HostStoreGetResultTag as TextTag, HostTcpReadExactlyResult as BytesResult,
    HostTcpReadExactlyResultPayload as BytesPayload, HostTcpReadExactlyResultTag as BytesTag, RocListWith, RocStr,
};
use crate::{actors, blobs, client, coroutine, db, kv, live, memory, preempt, roc, settings, signals, tcp};
use bytes::Bytes;
use futures_util::future::select_all;
use std::cell::RefCell;
use std::future::Future;
use std::mem::ManuallyDrop;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::OnceLock;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::{broadcast, mpsc, watch};

static RUNTIME: OnceLock<tokio::runtime::Handle> = OnceLock::new();

/// The runtime hosted functions wait on.
pub fn set_runtime(handle: tokio::runtime::Handle) {
    let _ = RUNTIME.set(handle);
}

/// Waits for `future`; a panic becomes an error. In a call into Roc (a coroutine), the call pauses
/// until it is done, and other calls run on its thread meanwhile: what the call keeps in the
/// thread's thread-locals is taken out first and put back after (`Stashed`). Anywhere else, it
/// blocks the thread.
pub fn wait<T>(future: impl Future<Output = Result<T, String>>) -> Result<T, String> {
    if coroutine::in_call() {
        let stashed = Stashed::take();
        let waited = coroutine::pause(future);
        stashed.put_back();
        return waited.unwrap_or_else(|| Err("the host panicked".into()));
    }
    let Some(runtime) = RUNTIME.get() else { return Err("no runtime".into()) };
    catch_unwind(AssertUnwindSafe(|| runtime.block_on(future))).unwrap_or_else(|_| Err("the host panicked".into()))
}

/// What a call keeps in its thread's thread-locals, out of them while it is paused: its context
/// (`CALL`), Roc's (its list of allocations, the page whose render keeps what it makes, why it
/// crashed or failed, its guard's jump target), the render it is doing, and its connections. A
/// future must not touch any of them (it is polled while other calls run on the thread).
struct Stashed {
    call: Context,
    roc: roc::Stash,
    render: signals::Stash,
    sockets: tcp::Stash,
}

impl Stashed {
    fn take() -> Stashed {
        // Paused, the call isn't running here: its deadline isn't this thread's to watch.
        preempt::set_deadline(None);
        Stashed { call: CALL.with(|context| context.take()), roc: roc::stash(), render: signals::stash(), sockets: tcp::stash() }
    }

    fn put_back(self) {
        preempt::set_deadline(self.call.deadline);
        CALL.with(|context| *context.borrow_mut() = self.call);
        roc::unstash(self.roc);
        signals::unstash(self.render);
        tcp::unstash(self.sockets);
    }
}

// ---- Stopping ----

static STOP: OnceLock<watch::Receiver<bool>> = OnceLock::new();

/// What says when the server is stopping (SIGTERM, ^C).
pub fn set_stop(stop: watch::Receiver<bool>) {
    let _ = STOP.set(stop);
}

pub fn stopping() -> bool {
    STOP.get().is_some_and(|stop| *stop.borrow())
}

/// Resolves once the server is stopping.
pub async fn stopped() {
    match STOP.get() {
        Some(stop) => {
            let mut stop = stop.clone();
            let _ = stop.wait_for(|stopping| *stopping).await;
        }
        None => std::future::pending().await,
    }
}

// ---- A call's context ----

/// The request a call into Roc answers (`Host.request!`, `Host.location!`), and what it has said
/// about it: the status its page is to be answered with (`Host.status!`).
#[derive(Default, Clone)]
pub struct Asked {
    pub method: String,
    /// The path and the query, a trailing slash dropped.
    pub target: String,
    /// A `name: value` a line.
    pub headers: String,
    /// As it came: bytes, shared by the call's copies of it.
    pub body: Bytes,
    /// The address of the connection it came on (`203.0.113.7`, `::1`): `Server.Request`'s `peer`.
    /// A request the host makes in-process for a page has the page's.
    pub peer: String,
    /// What the server was started with (`--context-file`), which an in-process call is given too.
    pub started: String,
    /// Whether crashes show their message (`--dev`).
    pub dev: bool,
    /// The status a page rendered for it is answered with, if the page set one
    /// (`<HttpStatusCode>`).
    status: Option<u16>,
}

impl Asked {
    pub fn new(method: &str, target: String, headers: String, body: Bytes, peer: String, started: String, dev: bool) -> Asked {
        Asked { method: method.to_string(), target, headers, body, peer, started, dev, ..Asked::default() }
    }
}

#[derive(Default)]
struct Context {
    /// The request this call answers, if it answers one.
    asked: Option<Asked>,
    /// The response of the stream this call sends.
    out: Option<mpsc::Sender<Bytes>>,
    /// A background loop: its waits end when the server stops.
    background: bool,
    /// When the call must be done by (a job's time limit), shared by the calls it runs.
    deadline: Option<Instant>,
    /// The time limit the deadline came from, in milliseconds, for the message.
    limit_ms: u64,
    /// Whether the deadline cut off an effect of this call, or of a call it ran.
    cut_off: bool,
    /// The connection of the transaction this call began.
    transaction: Option<db::Client>,
    /// Whether that transaction, or the last one, lost to another's write (a conflict, on Turso's
    /// MVCC, D-049), or needs to be exclusive: `Db.transaction!` runs its body again
    /// (`Host.db_conflicted!`).
    conflicted: bool,
    /// Whether the call's next transaction begins exclusive: a statement of its last one changed
    /// the schema, which a concurrent one can't.
    exclusive: bool,
    /// How many times in a row the call's transactions have lost to another's write: each run
    /// again waits a little longer first (`backoff`), so a slower writer isn't starved by faster
    /// ones taking the row before it every time.
    lost: u32,
    /// What its transaction notified, on SQLite: published when it commits (`Db.notify!`).
    notices: Vec<(String, String)>,
    listening: Vec<broadcast::Receiver<live::Message>>,
    rooms: Vec<String>,
    sockets: Vec<u64>,
    /// The answers from other servers whose bodies it reads in chunks (`Http.fetch_chunks!`).
    chunked: Vec<u64>,
    /// In an actor's turn, and the calls it runs: the actor, and the ones waiting on it.
    turn: Option<Turn>,
}

/// The actor whose turn a call is (`id`), and the actors whose turns wait on its answer
/// (`waiting`: it was asked in theirs). An ask from it to any of them would wait forever.
#[derive(Clone)]
struct Turn {
    id: actors::Id,
    waiting: Vec<actors::Id>,
}

impl Context {
    /// What a call leaves when it ends.
    fn end(mut self) {
        if let Some(client) = self.transaction.take() {
            crate::logging::warn("rocx server: a call ended with its transaction open: rolled back", &[]);
            rolled_back(client);
        }
        self.notices.clear();
        for room in self.rooms.drain(..) {
            live::leave(&room);
        }
        for id in self.sockets.drain(..) {
            tcp::close(id);
        }
        for id in self.chunked.drain(..) {
            client::let_go(id);
        }
    }

    /// Resolves when what this call waits on has gone: its stream's client, or, for a background
    /// loop, the server.
    fn gone(&self) -> impl Future<Output = ()> + use<> {
        let out = self.out.clone();
        let background = self.background;
        async move {
            match out {
                Some(out) => out.closed().await,
                None if background => stopped().await,
                None => std::future::pending().await,
            }
        }
    }
}

thread_local! {
    /// The context of the call running on this thread: a call that pauses takes it out (`wait`), and
    /// puts it back when it resumes.
    static CALL: RefCell<Context> = RefCell::new(Context::default());
}

/// Runs `run` (a call into Roc) with `context`, which keeps the deadline of the call it runs inside,
/// if that comes sooner, and its actor's turn, if it has none of its own. The outer call's context
/// comes back when it ends. Its result, and the time limit that cut it off, if its deadline did
/// (the outer call, sharing it, is told).
fn in_context<T>(mut context: Context, run: impl FnOnce() -> T) -> (T, Option<u64>) {
    let outer = CALL.with(|current| {
        let (deadline, limit_ms, turn) = {
            let current = current.borrow();
            (current.deadline, current.limit_ms, current.turn.clone())
        };
        if let Some(sooner) = deadline.filter(|outer| context.deadline.is_none_or(|own| *outer < own)) {
            context.deadline = Some(sooner);
            context.limit_ms = limit_ms;
        }
        if context.turn.is_none() {
            context.turn = turn;
        }
        preempt::set_deadline(context.deadline);
        current.replace(context)
    });
    let result = run();
    preempt::set_deadline(outer.deadline);
    let ended = CALL.with(|current| current.replace(outer));
    let cut_off = ended.cut_off.then_some(ended.limit_ms);
    if cut_off.is_some() {
        CALL.with(|current| {
            let mut current = current.borrow_mut();
            if current.deadline.is_some() {
                current.cut_off = true;
            }
        });
    }
    ended.end();
    (result, cut_off)
}

/// Runs `run` (a call into Roc) with a context of its own, `out` the response of the stream it
/// sends, if it sends one. The context of a call it runs inside (an isolated one, inside a
/// request's) comes back when it ends.
pub fn call<T>(out: Option<mpsc::Sender<Bytes>>, run: impl FnOnce() -> T) -> T {
    in_context(Context { out, ..Context::default() }, run).0
}

/// Runs `run` (a call into Roc that answers `asked`) with a context of its own, as `call` does.
pub fn call_asking<T>(asked: Asked, run: impl FnOnce() -> T) -> T {
    in_context(Context { asked: Some(asked), ..Context::default() }, run).0
}

/// Runs `run` (a call into Roc) with a context of its own that must be done within `limit_ms`
/// (0: no limit of its own): its result, and the limit, if the deadline cut it off.
fn call_within<T>(limit_ms: u64, run: impl FnOnce() -> T) -> (T, Option<u64>) {
    let deadline = (limit_ms > 0).then(|| Instant::now() + Duration::from_millis(limit_ms));
    in_context(Context { deadline, limit_ms, ..Context::default() }, run)
}

// ---- Deadlines ----

/// An effect waited past its call's deadline.
struct Late;

/// The running call's deadline, if it has one.
fn deadline() -> Option<Instant> {
    CALL.with(|context| context.borrow().deadline)
}

/// Whether the running call's deadline has passed.
fn past_deadline() -> bool {
    deadline().is_some_and(|at| Instant::now() >= at)
}

/// Waits for `future`, as `wait` does, but no longer than the running call's deadline.
fn within<T>(future: impl Future<Output = Result<T, String>>) -> Result<Result<T, String>, Late> {
    let Some(at) = deadline() else { return Ok(wait(future)) };
    if Instant::now() >= at {
        return Err(Late);
    }
    let mut late = false;
    let done = wait(async {
        match tokio::time::timeout_at(at.into(), future).await {
            Ok(done) => done,
            Err(_) => {
                late = true;
                Err(String::new())
            }
        }
    });
    if late { Err(Late) } else { Ok(done) }
}

/// What an effect came to, or, if it waited past the call's deadline, the call cut off.
fn in_time<T>(waited: Result<T, Late>) -> T {
    match waited {
        Ok(done) => done,
        Err(Late) => cut_off(),
    }
}

/// Ends the running call because its deadline has passed, wherever Roc's code was (`preempt`): as
/// an effect that waited past it would (`cut_off`). Called from Roc's code, holding nothing.
pub fn preempted() -> ! {
    cut_off()
}

/// Ends the running call because its deadline has passed: marked as cut off, and jumped back to
/// its guard, as a crash is (what it allocated is freed; what it holds is given back when its
/// context ends). Called last in a hosted function, holding nothing to drop.
fn cut_off() -> ! {
    let limit_ms = CALL.with(|context| {
        let mut context = context.borrow_mut();
        context.cut_off = true;
        context.limit_ms
    });
    roc::crash_outward(format!("timed out after {limit_ms} ms"))
}

/// The request the running call answers, if it answers one.
pub fn asked() -> Option<Asked> {
    CALL.with(|context| context.borrow().asked.clone())
}

/// The status the running call's page set for its answer (`Host.status!`), if it set one.
pub fn status() -> Option<u16> {
    CALL.with(|context| context.borrow().asked.as_ref().and_then(|asked| asked.status))
}

/// Runs a background loop (`roc::background`) with a context of its own, whose waits end when
/// the server stops.
pub fn call_background(index: u64) -> Result<(), roc::Crash> {
    in_context(Context { background: true, ..Context::default() }, || roc::background(index)).0
}

/// Waits `duration`; true if the server began stopping meanwhile.
pub fn pause(duration: Duration) -> bool {
    wait(async {
        Ok(tokio::select! {
            _ = tokio::time::sleep(duration) => false,
            _ = stopped() => true,
        })
    })
    .unwrap_or(true)
}

/// A string Roc handed over, copied, and Roc's released.
fn taken(text: RocStr) -> String {
    let copy = text.as_str().to_owned();
    unsafe { text.decref(&roc::host()) };
    copy
}

fn roc_str(text: &str) -> RocStr {
    RocStr::from_str(text, &roc::host())
}

/// Bytes Roc handed over, copied, and Roc's released.
fn taken_bytes(bytes: RocListWith<u8, false>) -> Vec<u8> {
    let copy = bytes.as_slice().to_vec();
    unsafe { bytes.decref(&roc::host()) };
    copy
}

fn roc_bytes(bytes: &[u8]) -> RocListWith<u8, false> {
    unsafe { RocListWith::from_slice(bytes, &roc::host()) }
}

fn done(result: Result<(), String>) -> HostDbScriptResult {
    match result {
        Ok(()) => HostDbScriptResult { payload: HostDbScriptResultPayload { ok: [] }, tag: HostDbScriptResultTag::Ok },
        Err(why) => HostDbScriptResult { payload: HostDbScriptResultPayload { err: ManuallyDrop::new(roc_str(&why)) }, tag: HostDbScriptResultTag::Err },
    }
}

fn text_or_error(result: Result<String, String>) -> TextResult {
    match result {
        Ok(text) => TextResult { payload: TextPayload { ok: ManuallyDrop::new(roc_str(&text)) }, tag: TextTag::Ok },
        Err(why) => TextResult { payload: TextPayload { err: ManuallyDrop::new(roc_str(&why)) }, tag: TextTag::Err },
    }
}

fn number_or_error(result: Result<u64, String>) -> HostDbExecuteResult {
    match result {
        Ok(count) => HostDbExecuteResult { payload: HostDbExecuteResultPayload { ok: ManuallyDrop::new(count) }, tag: HostDbExecuteResultTag::Ok },
        Err(why) => HostDbExecuteResult { payload: HostDbExecuteResultPayload { err: ManuallyDrop::new(roc_str(&why)) }, tag: HostDbExecuteResultTag::Err },
    }
}

fn bytes_or_error(result: Result<Vec<u8>, String>) -> BytesResult {
    match result {
        Ok(bytes) => BytesResult { payload: BytesPayload { ok: ManuallyDrop::new(unsafe { RocListWith::from_slice(&bytes, &roc::host()) }) }, tag: BytesTag::Ok },
        Err(why) => BytesResult { payload: BytesPayload { err: ManuallyDrop::new(roc_str(&why)) }, tag: BytesTag::Err },
    }
}

/// Runs `with` and catches a panic: it must never unwind into Roc.
fn guarded<T>(with: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    catch_unwind(AssertUnwindSafe(with)).unwrap_or_else(|_| Err("the host panicked".into()))
}

/// Runs a statement (`work`) on the call's transaction's connection, if it has one (taken out of
/// the context while it is used, and put back), or on one from the pool; told whether it is in the
/// call's transaction. It waits no longer than the call's deadline: past it, the statement is
/// cancelled and its connection closed (`db::abandon`), even the transaction's, which ends with it.
fn on_db<T>(work: impl AsyncFnOnce(&db::Client, bool) -> Result<T, String>) -> Result<Result<T, String>, Late> {
    let pinned = CALL.with(|context| context.borrow_mut().transaction.take());
    let (done, kept) = match pinned {
        Some(client) => match within(work(&client, true)) {
            Err(Late) => {
                abandon(client);
                // Its transaction ends with the connection: what it notified goes too.
                CALL.with(|context| context.borrow_mut().notices.clear());
                (Err(Late), None)
            }
            done => {
                if let Ok(Err(why)) = &done {
                    noted(why);
                }
                (done, Some(client))
            }
        },
        None => match within(db::client()) {
            Ok(Ok(client)) => match within(work(&client, false)) {
                Err(Late) => {
                    abandon(client);
                    (Err(Late), None)
                }
                done => (done, None),
            },
            Ok(Err(why)) => (Ok(Err(why)), None),
            Err(Late) => (Err(Late), None),
        },
    };
    if kept.is_some() {
        CALL.with(|context| context.borrow_mut().transaction = kept);
    }
    done
}

/// Notes, of a statement of the call's transaction (or its commit) that failed, whether it lost to
/// another's write, or needs an exclusive transaction: `Db.transaction!` runs its body again.
fn noted(why: &str) {
    let (conflict, exclusive) = (db::is_conflict(why), db::is_exclusive(why));
    if conflict || exclusive {
        CALL.with(|context| {
            let mut context = context.borrow_mut();
            context.conflicted = true;
            context.exclusive |= exclusive;
        });
    }
}

fn abandon(client: db::Client) {
    match RUNTIME.get() {
        Some(runtime) => db::abandon(client, runtime),
        None => drop(client),
    }
}

fn rolled_back(client: db::Client) {
    let _ = wait(async {
        db::rollback(&client).await;
        Ok(())
    });
}

// ---- Log, time, streams ----

/// An event on the log (`Log.info!` and the others): its level (0 debug, 1 info, 2 warn, 3 error),
/// its message, and its fields as JSON, or "" (`logging::from_roc`). It is queued, and written by
/// the log's own thread.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_log(level: u8, message: RocStr, fields: RocStr) {
    crate::logging::from_roc(level, taken(message), taken(fields));
}

/// The log's format, as the app's `program` says (`logs.format`): 0 `Auto`, 1 `Pretty`, 2 `Json`.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_log_format(format: u8) {
    crate::logging::choose(format);
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_now_millis() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|since| since.as_millis() as u64).unwrap_or(0)
}

/// Nanoseconds since the Unix epoch: the system clock's reading when first asked, plus a steady
/// clock's time since, so a duration measured with it is never negative, even when the system clock
/// is set back.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_now_nanos() -> u64 {
    static START: OnceLock<(u64, Instant)> = OnceLock::new();
    let (at, steady) = START.get_or_init(|| (SystemTime::now().duration_since(UNIX_EPOCH).map(|since| since.as_nanos() as u64).unwrap_or(0), Instant::now()));
    at.saturating_add(steady.elapsed().as_nanos() as u64)
}

/// Writes to the stream's response, waiting while it is full (the client reads slower than the
/// stream writes); false once its client has gone (or no stream is being sent).
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_send(data: RocStr) -> bool {
    let data = taken(data);
    let Some(out) = CALL.with(|context| context.borrow().out.clone()) else { return false };
    wait(async move { Ok(out.send(Bytes::from(data)).await.is_ok()) }).unwrap_or(false)
}

/// Waits `ms` milliseconds; a stream's wait ends early when its client goes (its next `send!` then
/// says so), a background loop's when the server stops.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_sleep(ms: u64) {
    let gone = CALL.with(|context| context.borrow().gone());
    let slept = within(async {
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_millis(ms)) => {}
            _ = gone => {}
        }
        Ok(())
    });
    let _ = in_time(slept);
}

// ---- The request: what it is, where its page is ----

/// The request, as HTTP writes it: `METHOD target`, then the connection's address after a space
/// when there is one (`GET /about 203.0.113.7`), a header a line, a blank line, its body (as text:
/// a byte that isn't UTF-8 is U+FFFD; `respond!` was given the bytes). A call that answers none (a
/// job's, a background loop's) has "".
#[unsafe(no_mangle)]
pub extern "C" fn roc_request() -> RocStr {
    let written = CALL.with(|context| {
        context.borrow().asked.as_ref().map(|asked| {
            let headers = if asked.headers.is_empty() { String::new() } else { format!("\n{}", asked.headers) };
            let peer = if asked.peer.is_empty() { String::new() } else { format!(" {}", asked.peer) };
            format!("{} {}{peer}{headers}\n\n{}", asked.method, asked.target, String::from_utf8_lossy(&asked.body))
        })
    });
    roc_str(&written.unwrap_or_default())
}

/// The request's path and query (`Router.location!`): "/" for a call that answers none.
#[unsafe(no_mangle)]
pub extern "C" fn roc_location() -> RocStr {
    let target = CALL.with(|context| context.borrow().asked.as_ref().map(|asked| asked.target.clone()));
    roc_str(&target.unwrap_or_else(|| "/".into()))
}

/// The status the page being rendered is to be answered with (`<HttpStatusCode code>`): the last
/// one set wins. A GET a page reads as it renders, answered in-process, has a request of its own.
#[unsafe(no_mangle)]
pub extern "C" fn roc_status(code: u16) {
    CALL.with(|context| {
        if let Some(asked) = context.borrow_mut().asked.as_mut() {
            asked.status = Some(code);
        }
    });
}

// ---- Settings, isolation ----

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_setting(name: RocStr) -> RocStr {
    roc_str(&settings::get(&taken(name)))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_stopping() -> bool {
    stopping()
}

/// Runs a part of the app in a call of its own, within `limit_ms` (0: no limit): its answer (0), why
/// it failed (1), the crash that ended it (2), or that its time ran out (3).
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_isolated(what: RocStr, input: RocStr, limit_ms: u64) -> Isolated {
    let (what, input) = (taken(what), taken(input));
    let ran = catch_unwind(AssertUnwindSafe(|| call_within(limit_ms, || roc::isolated(&what, &input))));
    isolated_answer(ran)
}

/// What an isolated call came to, for Roc: its status and what it said. One its deadline cut off is
/// 3, with the crash's "timed out after …", even if it went on to answer.
fn isolated_answer(ran: std::thread::Result<(Result<Result<String, String>, roc::Crash>, Option<u64>)>) -> Isolated {
    let (status, out) = match ran {
        Ok((_, Some(limit_ms))) => (3, format!("timed out after {limit_ms} ms")),
        Ok((Ok(Ok(answer)), None)) => (0, answer),
        Ok((Ok(Err(why)), None)) => (1, why),
        Ok((Err(crash), None)) => (2, crash.0),
        Err(_) => (2, "the host panicked".to_string()),
    };
    Isolated { out: roc_str(&out), status }
}

// ---- Actors ----

/// How long an ask waits for its answer.
const ASK_PATIENCE: Duration = Duration::from_secs(30);

/// Runs an actor's turn: `message` (JSON) to the actor `id`, its state as its last turn left it
/// (`kept`: none until a turn has read it, from Postgres), in a call of its own (`actor_for_host!`),
/// whose asks know whose turns wait on it (`waiting`, and the actor itself). Its next state and its
/// reply (JSON), or why it has none: the message isn't one it takes, its kind is none of the app's,
/// it crashed (what the turn allocated is freed, and its state stays as it was).
pub fn actor_turn(id: &actors::Id, waiting: Vec<actors::Id>, kept: Option<&str>, message: &str) -> Result<(String, String), String> {
    let context = Context { turn: Some(Turn { id: id.clone(), waiting }), ..Context::default() };
    let ran = catch_unwind(AssertUnwindSafe(|| in_context(context, || roc::actor(&id.kind, &id.key, kept, message)).0));
    match ran {
        Ok(Ok(answered)) => answered,
        Ok(Err(crash)) => Err(format!("{} crashed: {}", id.who(), crash.0)),
        Err(_) => Err("the host panicked".to_string()),
    }
}

/// The kinds of actor the app has (`program.actors`), a name a line, as the platform starts.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_actor_kinds(names: RocStr) {
    let names = taken(names);
    actors::kinds(names.lines().filter(|name| !name.is_empty()).map(str::to_string));
}

/// A plugin's file (`Plugin.File`), as the platform starts: served at `url` before anything else
/// answers (`files`).
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_plugin_file(url: RocStr, content_type: RocStr, body: RocListWith<u8, false>) {
    let (url, content_type) = (taken(url), taken(content_type));
    crate::files::add(url, content_type, taken_bytes(body));
}

/// The plugins' scripts, a URL a line, as the platform starts: every page loads them.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_page_scripts(urls: RocStr) {
    crate::files::set_scripts(taken(urls).lines().filter(|url| !url.is_empty()).map(str::to_string).collect());
}

/// Asks the actor of kind `kind` called `key` (its message as JSON): its reply (JSON), once it has
/// handled the messages before it; or why there is none. An actor asking one whose turn waits on it
/// is refused at once; an ask not answered in 30 s (or by the call's deadline) is given up on.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_actor_ask(kind: RocStr, key: RocStr, message: RocStr) -> TextResult {
    let answered = {
        let to = actors::Id { kind: taken(kind), key: taken(key) };
        let message = taken(message);
        let waiting = CALL.with(|context| {
            context.borrow().turn.as_ref().map(|turn| {
                let mut waiting = turn.waiting.clone();
                waiting.push(turn.id.clone());
                waiting
            })
        });
        let waiting = waiting.unwrap_or_default();
        if waiting.last() == Some(&to) {
            Ok(Err(format!("{} asked itself: it would wait for its own answer forever", to.who())))
        } else if let (true, Some(asker)) = (waiting.contains(&to), waiting.last()) {
            Ok(Err(format!("{} asked {}, whose turn waits on its answer: it would wait forever", asker.who(), to.who())))
        } else {
            match actors::ask(to.clone(), message, waiting) {
                Err(why) => Ok(Err(why)),
                Ok(answer) => within(async move {
                    match tokio::time::timeout(ASK_PATIENCE, answer).await {
                        Ok(Ok(reply)) => reply,
                        Ok(Err(_)) => Err(format!("{} didn't answer: the server is stopping", to.who())),
                        Err(_) => Err(format!("{} hasn't answered in 30 s (is it waiting on one that is waiting on it?)", to.who())),
                    }
                }),
            }
        }
    };
    text_or_error(in_time(answered))
}

/// Sends the actor of kind `kind` called `key` a message (JSON), answered by no one.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_actor_tell(kind: RocStr, key: RocStr, message: RocStr) {
    actors::tell(actors::Id { kind: taken(kind), key: taken(key) }, taken(message));
}

/// Sends the actor of kind `kind` called `key` a message (JSON) in `ms` milliseconds: the timer's
/// number, for `roc_host_actor_cancel`.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_actor_after(kind: RocStr, key: RocStr, ms: u64, message: RocStr) -> u64 {
    actors::after(actors::Id { kind: taken(kind), key: taken(key) }, ms, taken(message))
}

/// Stops a timer that hasn't fired.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_actor_cancel(timer: u64) {
    actors::cancel(timer);
}

// ---- Values, randomness ----

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_store_get(name: RocStr) -> TextResult {
    text_or_error(memory::get(&taken(name)).ok_or_else(String::new))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_store_set(name: RocStr, value: RocStr) {
    memory::set(&taken(name), &taken(value));
}

// ---- The key-value store (`Kv`) ----

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_kv_get(key: RocStr) -> TextResult {
    text_or_error(kv::get(&taken(key)).ok_or_else(String::new))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_kv_set(key: RocStr, text: RocStr, ttl_ms: u64) {
    kv::set(&taken(key), &taken(text), ttl_ms);
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_kv_delete(key: RocStr) {
    kv::delete(&taken(key));
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_kv_take(key: RocStr) -> TextResult {
    text_or_error(kv::take(&taken(key)).ok_or_else(String::new))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_kv_add(key: RocStr, text: RocStr, ttl_ms: u64) -> bool {
    kv::add(&taken(key), &taken(text), ttl_ms)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_kv_swap(key: RocStr, was: RocStr, text: RocStr, ttl_ms: u64) -> bool {
    kv::swap(&taken(key), &taken(was), &taken(text), ttl_ms)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_kv_increment(key: RocStr, by: i64, ttl_ms: u64) -> TextResult {
    text_or_error(kv::increment(&taken(key), by, ttl_ms).map(|now| now.to_string()))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_kv_push(key: RocStr, text: RocStr, keep: u64, ttl_ms: u64) {
    kv::push(&taken(key), &taken(text), keep, ttl_ms);
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_random_u64() -> u64 {
    use ring::rand::SecureRandom;
    let mut bytes = [0u8; 8];
    let _ = ring::rand::SystemRandom::new().fill(&mut bytes);
    u64::from_le_bytes(bytes)
}

/// So many random bytes. The operating system failing to give them crashes the call: no key or
/// token is ever made of anything less.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_random_bytes(count: u64) -> RocListWith<u8, false> {
    match random(count as usize) {
        Ok(bytes) => roc_bytes(&bytes),
        Err(why) => roc::crash_outward(why),
    }
}

fn random(count: usize) -> Result<Vec<u8>, String> {
    use ring::rand::SecureRandom;
    let mut bytes = vec![0u8; count];
    ring::rand::SystemRandom::new().fill(&mut bytes).map_err(|_| "the operating system gave no random bytes".to_string())?;
    Ok(bytes)
}

/// The process's environment variable `name`; an `Err` when it has none.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_env_var(name: RocStr) -> TextResult {
    let name = taken(name);
    text_or_error(guarded(|| std::env::var_os(&name).map(|value| value.to_string_lossy().into_owned()).ok_or_else(String::new)))
}

// ---- The database (Postgres, SQLite or Turso) ----

/// Opens the app's database at `url` (`postgres://…`, `sqlite:<path>`, `turso:<path>`), which the
/// platform's start works out from the program and `--database-url`: its flavor ("postgres",
/// "sqlite", "turso").
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_db_open(url: RocStr) -> TextResult {
    let url = taken(url);
    text_or_error(wait(async { db::open(&url).await.map(|flavor| flavor.name().to_string()) }))
}

/// The database the server opened: "postgres", "sqlite", "turso", or "" for none.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_db_flavor() -> RocStr {
    roc_str(db::flavor().map(db::Flavor::name).unwrap_or(""))
}

/// Tells the listeners of `channel` (the topic `db:<channel>`) `payload`, when the call's transaction
/// commits (never, if it rolls back), or at once outside one: on Postgres with `pg_notify`, which
/// other processes hear too; on SQLite and Turso in the process, the host keeping the call's notices.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_db_notify(channel: RocStr, payload: RocStr) -> HostDbScriptResult {
    if db::flavor().is_some_and(db::Flavor::in_process) {
        let (channel, payload) = (taken(channel), taken(payload));
        let kept = CALL.with(|context| {
            let mut context = context.borrow_mut();
            if context.transaction.is_some() {
                context.notices.push((channel.clone(), payload.clone()));
                true
            } else {
                false
            }
        });
        if !kept {
            live::publish(&format!("db:{channel}"), &payload);
        }
        return done(Ok(()));
    }
    let waited = {
        let (channel, payload) = (taken(channel), taken(payload));
        on_db(async |client, _| db::notify(client, &channel, &payload).await)
    };
    done(in_time(waited))
}

/// What the call's transaction notified, published now that it has committed.
fn publish_notices() {
    let notices = CALL.with(|context| std::mem::take(&mut context.borrow_mut().notices));
    for (channel, payload) in notices {
        live::publish(&format!("db:{channel}"), &payload);
    }
}

// Each runs its statement in `on_db` and drops what it took before `in_time`, which may cut the call
// off (the frame must hold nothing to drop then).

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_db_query(sql: RocStr, params: RocStr) -> TextResult {
    let waited = {
        let (sql, params) = (taken(sql), taken(params));
        on_db(async |client, _| db::query(client, &sql, &params).await)
    };
    text_or_error(in_time(waited))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_db_execute(sql: RocStr, params: RocStr) -> HostDbExecuteResult {
    let waited = {
        let (sql, params) = (taken(sql), taken(params));
        on_db(async |client, _| db::execute(client, &sql, &params).await)
    };
    number_or_error(in_time(waited))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_db_script(sql: RocStr) -> HostDbScriptResult {
    let waited = {
        let sql = taken(sql);
        on_db(async |client, in_transaction| db::script(client, in_transaction, &sql).await)
    };
    done(in_time(waited))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_db_begin() -> HostDbScriptResult {
    if CALL.with(|context| context.borrow().transaction.is_some()) {
        return done(Err("a transaction is open already: one at a time".into()));
    }
    // The connection, then `begin` on it: one cut off after `begin` was sent is closed, never given
    // back to the pool with a transaction open. Exclusive if the last one needed it.
    let (exclusive, lost) = CALL.with(|context| {
        let mut context = context.borrow_mut();
        context.lost = if context.conflicted && !context.exclusive { context.lost + 1 } else { 0 };
        context.conflicted = false;
        (std::mem::take(&mut context.exclusive), context.lost)
    });
    // Run again after losing to another's write: a pause first, random, longer each time.
    if lost > 0 {
        let pause = db::backoff(lost);
        if within(async move {
            tokio::time::sleep(pause).await;
            Ok(())
        })
        .is_err()
        {
            cut_off();
        }
    }
    let waited = match within(db::client()) {
        Ok(Ok(client)) => match within(db::begin(&client, exclusive)) {
            Err(Late) => {
                abandon(client);
                Err(Late)
            }
            Ok(begun) => Ok(begun.map(|()| CALL.with(|context| context.borrow_mut().transaction = Some(client)))),
        },
        Ok(Err(why)) => Ok(Err(why)),
        Err(Late) => Err(Late),
    };
    done(in_time(waited))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_db_commit() -> HostDbScriptResult {
    let pinned = CALL.with(|context| context.borrow_mut().transaction.take());
    let Some(client) = pinned else { return done(Err("no transaction is open".into())) };
    let waited = match within(db::commit(&client)) {
        Err(Late) => {
            abandon(client);
            Err(Late)
        }
        Ok(committed) => {
            if let Err(why) = &committed {
                noted(why);
                rolled_back(client);
            }
            Ok(committed)
        }
    };
    match &waited {
        Ok(Ok(())) => publish_notices(),
        _ => CALL.with(|context| context.borrow_mut().notices.clear()),
    }
    done(in_time(waited))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_db_rollback() {
    let pinned = CALL.with(|context| {
        let mut context = context.borrow_mut();
        context.notices.clear();
        context.transaction.take()
    });
    if let Some(client) = pinned {
        rolled_back(client);
    }
}

/// Whether the call's last transaction, rolled back, lost to another's write, or needed to be
/// exclusive (Turso's MVCC, D-049): `Db.transaction!` runs its body again.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_db_conflicted() -> bool {
    CALL.with(|context| context.borrow().conflicted)
}

/// Listens to a channel of the database's: this call hears what is notified on it (`Db.notify!`,
/// or Postgres's `pg_notify`) on the topic `db:<channel>`.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_db_listen(channel: RocStr) -> HostDbScriptResult {
    let channel = taken(channel);
    // Listening on the topic first, so a notification while Postgres is told isn't missed.
    let receiver = live::listen(&format!("db:{channel}"));
    CALL.with(|context| context.borrow_mut().listening.push(receiver));
    done(wait(db::listen(&channel)))
}

// ---- Live ----

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_live_publish(topic: RocStr, message: RocStr) {
    live::publish(&taken(topic), &taken(message));
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_live_listen(topic: RocStr) {
    let receiver = live::listen(&taken(topic));
    CALL.with(|context| context.borrow_mut().listening.push(receiver));
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_live_join(room: RocStr) {
    let room = taken(room);
    // Joining is published before this call listens, so it doesn't hear its own.
    live::join(&room);
    let receiver = live::listen(&room);
    CALL.with(|context| {
        let mut context = context.borrow_mut();
        context.listening.push(receiver);
        context.rooms.push(room);
    });
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_live_count(room: RocStr) -> u64 {
    live::count(&taken(room))
}

/// The next message on a topic the call listens to (0), none within `ms` (1), or what the call
/// waits on has gone: its stream's client, or the server, for a background loop (2).
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_live_next(ms: u64) -> Heard {
    let (mut listening, gone) = CALL.with(|context| {
        let mut context = context.borrow_mut();
        (std::mem::take(&mut context.listening), context.gone())
    });
    let at = deadline();
    let heard: Result<(u8, Option<live::Message>), String> = wait(async {
        let quiet = tokio::time::sleep(Duration::from_millis(ms));
        let next = async {
            if listening.is_empty() {
                return std::future::pending().await;
            }
            loop {
                let receivers = listening.iter_mut().map(|receiver| Box::pin(receiver.recv()));
                let (got, _, _) = select_all(receivers).await;
                match got {
                    Ok(message) => return message,
                    // Fell behind: the oldest are gone; hear the next.
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => return std::future::pending().await,
                }
            }
        };
        let late = async {
            match at {
                Some(at) => tokio::time::sleep_until(at.into()).await,
                None => std::future::pending().await,
            }
        };
        Ok(tokio::select! {
            message = next => (0, Some(message)),
            _ = quiet => (1, None),
            _ = gone => (2, None),
            _ = late => (3, None),
        })
    });
    CALL.with(|context| context.borrow_mut().listening = listening);
    let waited = match heard.unwrap_or((1, None)) {
        (3, _) => Err(Late),
        (status, message) => {
            let (topic, text) = message.map(|message| (message.topic, message.text)).unwrap_or_default();
            Ok(Heard { message: roc_str(&text), topic: roc_str(&topic), status })
        }
    };
    in_time(waited)
}

// ---- TCP ----

/// What a socket's effect came to, or `Late` if it failed because the call's deadline passed.
fn socket_in_time<T>(done: Result<T, String>) -> Result<Result<T, String>, Late> {
    match done {
        Err(_) if past_deadline() => Err(Late),
        done => Ok(done),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_tcp_connect(host: RocStr, port: u16, tls: bool) -> HostDbExecuteResult {
    let waited = {
        let host = taken(host);
        let made = guarded(|| tcp::connect(&host, port, tls, deadline()));
        if let Ok(id) = made {
            CALL.with(|context| context.borrow_mut().sockets.push(id));
        }
        socket_in_time(made)
    };
    number_or_error(in_time(waited))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_tcp_start_tls(id: u64, host: RocStr) -> HostDbScriptResult {
    let waited = {
        let host = taken(host);
        socket_in_time(guarded(|| tcp::start_tls(id, &host, deadline())))
    };
    done(in_time(waited))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_tcp_write(id: u64, bytes: RocListWith<u8, false>) -> HostDbScriptResult {
    let waited = {
        let copy = taken_bytes(bytes);
        socket_in_time(guarded(|| tcp::write(id, &copy, deadline())))
    };
    done(in_time(waited))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_tcp_read_exactly(id: u64, count: u64) -> BytesResult {
    let waited = socket_in_time(guarded(|| tcp::read_exactly(id, count as usize, deadline())));
    bytes_or_error(in_time(waited))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_tcp_read_up_to(id: u64, count: u64) -> BytesResult {
    let waited = socket_in_time(guarded(|| tcp::read_up_to(id, count as usize, deadline())));
    bytes_or_error(in_time(waited))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_tcp_read_until(id: u64, byte: u8) -> BytesResult {
    let waited = socket_in_time(guarded(|| tcp::read_until(id, byte, deadline())));
    bytes_or_error(in_time(waited))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_tcp_close(id: u64) {
    tcp::close(id);
    CALL.with(|context| context.borrow_mut().sockets.retain(|each| *each != id));
}

// ---- HTTP: requests to other servers ----

/// Makes a request and reads its answer whole (`client::fetch`), through the proxy `via` says
/// (`env`, `direct`, `via <url>`): any status is an answer; an `Err` is "timed out", "too large",
/// or why there was none.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_http_send(
    method: RocStr,
    url: RocStr,
    headers: RocStr,
    body: RocListWith<u8, false>,
    timeout_ms: u64,
    max_bytes: u64,
    follow: bool,
    via: RocStr,
) -> HostHttpSendResult {
    let waited = {
        let (method, url, headers, body, via) = (taken(method), taken(url), taken(headers), taken_bytes(body), taken(via));
        let fetched = guarded(|| {
            let outbound = client::Outbound::new(&method, &url, &headers, body)?.through(&via)?;
            let (timeout, max_bytes) = (request_timeout(timeout_ms), (max_bytes > 0).then_some(max_bytes));
            wait(async { Ok(client::fetch(outbound, timeout, max_bytes, follow).await) })?.map_err(failure)
        });
        socket_in_time(fetched)
    };
    match in_time(waited) {
        Ok(answer) => {
            let answered = Answered { body: roc_bytes(&answer.body), headers: roc_str(&answer.headers), status: answer.status };
            HostHttpSendResult { payload: HostHttpSendResultPayload { ok: ManuallyDrop::new(answered) }, tag: HostHttpSendResultTag::Ok }
        }
        Err(why) => HostHttpSendResult { payload: HostHttpSendResultPayload { err: ManuallyDrop::new(roc_str(&why)) }, tag: HostHttpSendResultTag::Err },
    }
}

/// The time a request may take: `timeout_ms` (0: no limit), and no longer than the call's deadline.
fn request_timeout(timeout_ms: u64) -> Option<Duration> {
    let timeout = (timeout_ms > 0).then(|| Duration::from_millis(timeout_ms));
    let left = deadline().map(|at| at.saturating_duration_since(Instant::now()));
    match (timeout, left) {
        (Some(given), Some(left)) => Some(given.min(left)),
        (given, left) => given.or(left),
    }
}

/// Why a request to another server came to nothing, as Roc reads it.
fn failure(failure: client::Failure) -> String {
    match failure {
        client::Failure::Http(why) => why,
        client::Failure::TimedOut => "timed out".to_string(),
        client::Failure::TooLarge => "too large".to_string(),
    }
}

/// Makes a request as `roc_host_http_send` does, and keeps its answer's body for the call to read
/// in chunks (`roc_host_http_read`): `<id> <status>`, then its headers, a `name: value` a line.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_http_open(
    method: RocStr,
    url: RocStr,
    headers: RocStr,
    body: RocListWith<u8, false>,
    timeout_ms: u64,
    max_bytes: u64,
    follow: bool,
    via: RocStr,
) -> TextResult {
    let waited = {
        let (method, url, headers, body, via) = (taken(method), taken(url), taken(headers), taken_bytes(body), taken(via));
        let opened = guarded(|| {
            let outbound = client::Outbound::new(&method, &url, &headers, body)?.through(&via)?;
            let (timeout, max_bytes) = (request_timeout(timeout_ms), (max_bytes > 0).then_some(max_bytes));
            let (id, status, headers) = wait(async { Ok(client::open_chunked(outbound, timeout, max_bytes, follow).await) })?.map_err(failure)?;
            CALL.with(|context| context.borrow_mut().chunked.push(id));
            Ok(format!("{id} {status}\n{headers}"))
        });
        socket_in_time(opened)
    };
    text_or_error(in_time(waited))
}

/// The next chunk of an answer's body this call keeps (`roc_host_http_open`), as it comes: empty at
/// its end; "timed out", "too large", or why it broke off. After either, it is let go.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_http_read(id: u64) -> BytesResult {
    let waited = {
        let read = guarded(|| {
            if !CALL.with(|context| context.borrow().chunked.contains(&id)) {
                return Err("that answer's body isn't this call's to read".to_string());
            }
            let read = wait(async { Ok(client::chunk(id).await) })?.map_err(failure);
            if !matches!(&read, Ok(chunk) if !chunk.is_empty()) {
                CALL.with(|context| context.borrow_mut().chunked.retain(|each| *each != id));
            }
            read
        });
        socket_in_time(read)
    };
    bytes_or_error(in_time(waited))
}

/// Lets go of an answer's body this call keeps, read or not: its connection is closed, unless what
/// is left of the body has come already.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_http_close(id: u64) {
    if CALL.with(|context| context.borrow().chunked.contains(&id)) {
        client::let_go(id);
        CALL.with(|context| context.borrow_mut().chunked.retain(|each| *each != id));
    }
}

// ---- AES-256-GCM ----

/// `plaintext` sealed under `key` (32 bytes): a fresh random nonce, the ciphertext, the tag.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_aes_gcm_seal(key: RocListWith<u8, false>, plaintext: RocListWith<u8, false>) -> BytesResult {
    let (key, plaintext) = (taken_bytes(key), taken_bytes(plaintext));
    bytes_or_error(guarded(|| seal(&key, &plaintext)))
}

/// What `roc_host_aes_gcm_seal` sealed under `key`; "bad key", or "forged".
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_aes_gcm_open(key: RocListWith<u8, false>, sealed: RocListWith<u8, false>) -> BytesResult {
    let (key, sealed) = (taken_bytes(key), taken_bytes(sealed));
    bytes_or_error(guarded(|| open(&key, &sealed)))
}

const NONCE: usize = 12;
const TAG: usize = 16;

fn aes_key(key: &[u8]) -> Result<ring::aead::LessSafeKey, String> {
    let key = ring::aead::UnboundKey::new(&ring::aead::AES_256_GCM, key).map_err(|_| "bad key".to_string())?;
    Ok(ring::aead::LessSafeKey::new(key))
}

fn seal(key: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, String> {
    let key = aes_key(key)?;
    let nonce: [u8; NONCE] = random(NONCE)?.try_into().map_err(|_| "no nonce".to_string())?;
    let mut sealed = Vec::with_capacity(NONCE + plaintext.len() + TAG);
    sealed.extend_from_slice(&nonce);
    sealed.extend_from_slice(plaintext);
    let tag = key
        .seal_in_place_separate_tag(ring::aead::Nonce::assume_unique_for_key(nonce), ring::aead::Aad::empty(), &mut sealed[NONCE..])
        .map_err(|_| "too long to seal".to_string())?;
    sealed.extend_from_slice(tag.as_ref());
    Ok(sealed)
}

fn open(key: &[u8], sealed: &[u8]) -> Result<Vec<u8>, String> {
    let key = aes_key(key)?;
    if sealed.len() < NONCE + TAG {
        return Err("forged".into());
    }
    let (nonce, rest) = sealed.split_at(NONCE);
    let nonce = ring::aead::Nonce::try_assume_unique_for_key(nonce).map_err(|_| "forged".to_string())?;
    let mut buffer = rest.to_vec();
    let plaintext = key.open_in_place(nonce, ring::aead::Aad::empty(), &mut buffer).map_err(|_| "forged".to_string())?;
    Ok(plaintext.to_vec())
}

// ---- Time zones ----

/// The offset from UTC, in seconds, of the IANA time zone `zone` at `at_ms` (milliseconds since the
/// epoch), summer time counted, from the zone database compiled in (chrono-tz); an `Err` for a name
/// it doesn't have.
#[unsafe(no_mangle)]
pub extern "C" fn roc_host_zone_offset(zone: RocStr, at_ms: i64) -> HostZoneOffsetResult {
    use chrono::{Offset, TimeZone};
    let zone = taken(zone);
    let offset = zone.parse::<chrono_tz::Tz>().map_err(|_| format!("no time zone is called {zone}")).and_then(|tz| {
        let at = chrono::DateTime::from_timestamp_millis(at_ms).ok_or_else(|| format!("{at_ms} ms isn't a moment"))?;
        Ok(i64::from(tz.offset_from_utc_datetime(&at.naive_utc()).fix().local_minus_utc()))
    });
    match offset {
        Ok(seconds) => HostZoneOffsetResult { payload: HostZoneOffsetResultPayload { ok: ManuallyDrop::new(seconds) }, tag: HostZoneOffsetResultTag::Ok },
        Err(why) => HostZoneOffsetResult { payload: HostZoneOffsetResultPayload { err: ManuallyDrop::new(roc_str(&why)) }, tag: HostZoneOffsetResultTag::Err },
    }
}

// ---- Objects kept by key (packages/storage's file: and memory: buckets, D-047) ----

/// Runs `work` (files: it blocks) on a thread for blocking work, the call paused meanwhile.
fn blocking<T: Send + 'static>(work: impl FnOnce() -> Result<T, String> + Send + 'static) -> Result<T, String> {
    wait(async move { tokio::task::spawn_blocking(work).await.unwrap_or_else(|_| Err("the host panicked".into())) })
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_blob_put(root: RocStr, key: RocStr, bytes: RocListWith<u8, false>, content_type: RocStr) -> HostDbScriptResult {
    let (root, key, content_type) = (taken(root), taken(key), taken(content_type));
    let owned = bytes.as_slice().to_vec();
    unsafe { bytes.decref(&roc::host()) };
    done(blocking(move || blobs::put(&blobs::root(&root)?, &key, owned, &content_type)))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_blob_get(root: RocStr, key: RocStr) -> BytesResult {
    let (root, key) = (taken(root), taken(key));
    bytes_or_error(blocking(move || blobs::get(&blobs::root(&root)?, &key)))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_blob_range(root: RocStr, key: RocStr, offset: u64, length: u64) -> HostBlobRangeResult {
    let (root, key) = (taken(root), taken(key));
    match blocking(move || blobs::range(&blobs::root(&root)?, &key, offset, length)) {
        Ok((bytes, size)) => HostBlobRangeResult {
            payload: HostBlobRangeResultPayload { ok: ManuallyDrop::new(Ranged { size, bytes: roc_bytes(&bytes) }) },
            tag: HostBlobRangeResultTag::Ok,
        },
        Err(why) => HostBlobRangeResult { payload: HostBlobRangeResultPayload { err: ManuallyDrop::new(roc_str(&why)) }, tag: HostBlobRangeResultTag::Err },
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_blob_head(root: RocStr, key: RocStr) -> HostBlobHeadResult {
    let (root, key) = (taken(root), taken(key));
    match blocking(move || blobs::head(&blobs::root(&root)?, &key)) {
        Ok(info) => HostBlobHeadResult {
            payload: HostBlobHeadResultPayload { ok: ManuallyDrop::new(Headed { size: info.size, content_type: roc_str(&info.content_type), etag: roc_str(&info.etag) }) },
            tag: HostBlobHeadResultTag::Ok,
        },
        Err(why) => HostBlobHeadResult { payload: HostBlobHeadResultPayload { err: ManuallyDrop::new(roc_str(&why)) }, tag: HostBlobHeadResultTag::Err },
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_blob_delete(root: RocStr, key: RocStr) -> HostDbScriptResult {
    let (root, key) = (taken(root), taken(key));
    done(blocking(move || blobs::delete(&blobs::root(&root)?, &key)))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_blob_compose(root: RocStr, parts: RocList<RocStr>, key: RocStr, content_type: RocStr) -> HostDbScriptResult {
    let (root, key, content_type) = (taken(root), taken(key), taken(content_type));
    let named: Vec<String> = parts.as_slice().iter().map(|part| part.as_str().to_owned()).collect();
    unsafe { crate::abi::decref_list_of_str(parts, &roc::host()) };
    done(blocking(move || blobs::compose(&blobs::root(&root)?, &named, &key, &content_type)))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_blob_check(root: RocStr) -> HostDbScriptResult {
    let root = taken(root);
    done(blocking(move || blobs::check(&blobs::root(&root)?)))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_blob_secret(root: RocStr) -> RocStr {
    roc_str(&blobs::secret(&taken(root)))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_blob_keys(root: RocStr, prefix: RocStr) -> HostBlobKeysResult {
    let (root, prefix) = (taken(root), taken(prefix));
    match blocking(move || blobs::keys(&blobs::root(&root)?, &prefix)) {
        Ok(keys) => {
            let host = roc::host();
            let listed: Vec<RocStr> = keys.iter().map(|key| roc_str(key)).collect();
            HostBlobKeysResult { payload: HostBlobKeysResultPayload { ok: ManuallyDrop::new(unsafe { RocList::from_slice(&listed, &host) }) }, tag: HostBlobKeysResultTag::Ok }
        }
        Err(why) => HostBlobKeysResult { payload: HostBlobKeysResultPayload { err: ManuallyDrop::new(roc_str(&why)) }, tag: HostBlobKeysResultTag::Err },
    }
}
