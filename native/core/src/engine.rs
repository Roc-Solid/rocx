//! The reactive engine: web/runtime.js's, in Rust, building the engine's own document
//! (`dom.rs`) where the browser builds the DOM. Roc builds markup whose holes are computations
//! (boxes the engine keeps by id); this runs them, tracks what each reads, runs it again when that
//! changes, and patches only its own node. A read whose value isn't in yet ends its computation
//! (`roc::Abort::Wait`): the nearest <Loading> shows its fallback until the first values are in,
//! and the computation runs again once its value is. A failure shows the nearest <Errored>.
//! Handlers run with their writes applied when they are done; one that waits for an answer runs
//! again once it is in. Each function here says which of runtime.js's it follows: where the two
//! differ, the browser is right.
//!
//! Not here yet (spike/native-apps/README.md): hydration (a phone mounts from nothing),
//! transitions and glides, drag and drop, `on:frame`, `on:viewport`, `<Document>`/`<Window>`
//! handlers, `listen!` and channels, `Browser.call!`'s native handlers, keyed elements.

use crate::abi::RocErasedCallable as Callable;
use crate::dom::{Dom, NodeId, Range};
use crate::roc::{self, Abort, Wait};
use crate::{Level, log};
use serde_json::Value;
use std::cell::RefCell;
use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};
use std::rc::Rc;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum CompKind {
    Root,
    Text,
    Attr,
    Flag,
    Class,
    Optional,
    Style,
    Html,
    Show,
    For,
    Memo,
    Reaction,
    Component,
    Boundary,
}

/// What a computation reads: a signal, a memo, a memo's pending state (`is_pending!`), a row's
/// index or item, an endpoint's submissions.
#[derive(Clone, PartialEq, Eq, Hash, Debug)]
pub enum Source {
    Signal(u64),
    Memo(u64),
    Pending(u64),
    Index(u64, String),
    Item(u64, String),
    Submission(String),
}

/// The contexts provided above, and the boundaries around: what a computation is made in.
#[derive(Clone, Default)]
pub struct Scope {
    contexts: Rc<HashMap<String, u64>>,
    loading: Option<u64>,
    errored: Option<u64>,
}

/// What runs when an owner runs again or goes: a box Roc kept (`on_cleanup!`), or the engine's own.
enum Cleanup {
    Kept(u64),
    Timer(u64),
    Title(u64),
    Action(String),
}

#[derive(Clone)]
struct Query {
    probe: u64,
    memos: Vec<u64>,
    answer: bool,
}

/// What a run makes, as it makes it (runtime.js's `making_`).
#[derive(Default)]
struct Made {
    children: Vec<u64>,
    kept: Vec<u64>,
    sources: Vec<Source>,
    signals: Vec<u64>,
    cleanups: Vec<Cleanup>,
    queries: Vec<Query>,
    live: bool,
    untracked: u32,
}

impl Made {
    /// Read and made nothing that changes (D-052): a hole whose run is inert is static.
    fn inert(&self) -> bool {
        !self.live && self.sources.is_empty() && self.children.is_empty() && self.signals.is_empty() && self.cleanups.is_empty() && self.queries.is_empty()
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum MemoState {
    Pending,
    Ok,
    Failed,
}

#[derive(Clone, Copy, Debug)]
enum Target {
    None,
    Node(NodeId),
    Range(Range),
}

struct Comp {
    kind: CompKind,
    runner: Callable,
    scope: Scope,
    target: Target,
    name: String,
    sources: Vec<Source>,
    made: Made,
    making: Option<Made>,
    /// Its requests' answers, by method, URL and body (`fetchFor`).
    calls: HashMap<String, u64>,
    used: HashSet<String>,
    disposed: bool,
    untracked: bool,
    recheck: bool,
    queries: Vec<Query>,
    // A memo's.
    state: MemoState,
    value: Callable,
    next: Callable,
    error: String,
    refreshing: bool,
    stale: bool,
    // A <Show>'s and a <For>'s.
    node: Option<Rc<Value>>,
    holds: Option<bool>,
    part: Option<u64>,
    list: Option<u64>,
    fallback_range: Option<Range>,
    settled: bool,
    // A markup hole's first run (`peek`), before its place is known.
    peek: bool,
    peeked: Option<Vec<Value>>,
    // An effect's.
    cleanups: Vec<Cleanup>,
    apply: u64,
    render: bool,
    on_error: u64,
    failure: Option<String>,
    /// An <Errored>'s fallback: the boundary.
    boundary: Option<u64>,
    /// Submissions waiting for it to read again (`revalidate`).
    revalidating: Vec<u64>,
    title_seq: u64,
}

impl Comp {
    fn new(kind: CompKind, runner: Callable, scope: Scope, target: Target, name: &str) -> Comp {
        Comp {
            kind,
            runner,
            scope,
            target,
            name: name.to_string(),
            sources: Vec::new(),
            made: Made::default(),
            making: None,
            calls: HashMap::new(),
            used: HashSet::new(),
            disposed: false,
            untracked: false,
            recheck: false,
            queries: Vec::new(),
            state: MemoState::Pending,
            value: std::ptr::null_mut(),
            next: std::ptr::null_mut(),
            error: String::new(),
            refreshing: false,
            stale: false,
            node: None,
            holds: None,
            part: None,
            list: None,
            fallback_range: None,
            settled: false,
            peek: false,
            peeked: None,
            cleanups: Vec::new(),
            apply: 0,
            render: false,
            on_error: 0,
            failure: None,
            boundary: None,
            revalidating: Vec::new(),
            title_seq: 0,
        }
    }
}

struct Loading {
    waiting: HashSet<u64>,
    revealed: bool,
    built: bool,
    range: Range,
    children: NodeId,
}

struct Errored {
    runner: Callable,
    nodes: Vec<Value>,
    owner: Option<u64>,
    scope: Scope,
    range: Range,
    failed: Option<String>,
    memos: Vec<u64>,
    inside: Option<u64>,
    fallback: Option<u64>,
}

struct Row {
    runner: u64,
    range: Range,
    comp: u64,
    /// Made by this settle, still in its own fragment.
    fresh: Option<NodeId>,
}

#[derive(Default)]
struct List {
    order: Vec<String>,
    rows: HashMap<String, Row>,
    indexes: HashMap<String, u64>,
    items: HashMap<String, Callable>,
}

/// A handler running, or waiting to run again (runtime.js's `handle`).
struct Handler {
    runner: u64,
    calls: HashMap<String, u64>,
    writes: Vec<Write>,
    event: String,
    scope: Scope,
    owner: Option<u64>,
    /// An effect's apply: the effect, where what it starts goes.
    cleanups_of: Option<u64>,
    /// A timeout's box, let go of once it has run.
    release: Option<u64>,
}

struct Probe {
    memos: Vec<u64>,
    calls: HashMap<String, u64>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Current {
    Comp(u64),
    Handler(u64),
    Probe(u64),
}

/// A handler's writes, applied together once it is done.
enum Write {
    Signal(u64, Callable),
    Refresh(u64),
    Retry(u64),
    Effect(String, String),
    Cleared(String),
    Dropped(String, u64),
    Submit { method: String, url: String, body: String, input: String },
}

#[derive(Clone, Copy)]
enum Waiter {
    Comp(u64),
    Handler(u64),
}

/// A request's answer: on its way, in (`{"status":…,"body":…}`), or none (why).
#[derive(Clone)]
enum Answer {
    Pending,
    Ok(String),
    Failed(String),
}

struct Listener {
    event: String,
    kind: String,
    runner: u64,
    wanted: Option<String>,
    scope: Scope,
    owner: Option<u64>,
}

struct Timer {
    repeat: bool,
    scope: Scope,
    owner: Option<u64>,
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

struct Submission {
    id: u64,
    state: &'static str,
    input: String,
    json: bool,
    status: u16,
    body: String,
}

#[derive(Default)]
struct Submissions {
    list: Vec<Submission>,
    cleared: bool,
}

/// What a request was made for: a computation's or handler's read, or a submission.
pub enum Asked {
    Read,
    Submission { key: String, id: u64 },
}

/// A submission's result reading the page's reads again: how many are left, and the submission.
struct Revalidation {
    left: usize,
    key: String,
    id: u64,
    status: u16,
    body: String,
}

/// What happens later, after what is running now (runtime.js's microtasks).
enum Task {
    Fallback(u64),
    ReleaseKept(u64),
    /// A handler whose answer is in, run again.
    Wake(u64),
}

pub struct Engine {
    ids: u64,
    pub dom: Dom,
    /// What the app's server is: requests to a path go there (`http://10.0.2.2:8080`).
    pub origin: String,
    /// Where the app is (`Router.location!`): the start path.
    pub path: String,
    kept: HashMap<u64, Callable>,
    signals: HashMap<u64, Callable>,
    comps: HashMap<u64, Comp>,
    observers: HashMap<Source, Vec<u64>>,
    lists: HashMap<u64, List>,
    boundaries: HashMap<u64, Errored>,
    loadings: HashMap<u64, Loading>,
    handlers: HashMap<u64, Handler>,
    probes: HashMap<u64, Probe>,
    current: Option<Current>,
    dirty: BTreeSet<u64>,
    due: BTreeSet<u64>,
    tasks: VecDeque<Task>,
    waiters: HashMap<Wait, Vec<Waiter>>,
    requests: HashMap<u64, Answer>,
    asked: HashMap<u64, Asked>,
    readers: HashSet<u64>,
    listeners: HashMap<NodeId, Vec<Listener>>,
    /// What an `<input>` shows now (its `value` property), once it was typed in or patched.
    pub values: HashMap<NodeId, String>,
    timers: HashMap<u64, Timer>,
    titles: HashMap<u64, (u64, String)>,
    title_seqs: u64,
    pub title: Option<String>,
    calling: Vec<(String, String)>,
    place: String,
    actions: HashMap<String, u32>,
    submissions: HashMap<String, Submissions>,
    revalidations: HashMap<u64, Revalidation>,
    warned: HashSet<String>,
    /// A request to send: made in a run, sent once the engine is let go of (`send_requests`).
    outbox: Vec<(u64, String, String, Vec<(String, String)>, String)>,
}

thread_local! {
    static ENGINE: RefCell<Option<Engine>> = const { RefCell::new(None) };
}

/// Runs `f` with the engine. Never call Roc, or anything that does, inside: a hosted function
/// borrows it too.
pub fn with<R>(f: impl FnOnce(&mut Engine) -> R) -> R {
    ENGINE.with(|engine| {
        let mut engine = engine.borrow_mut();
        f(engine.as_mut().expect("rocx native: the engine isn't started"))
    })
}

/// Lets go of the engine (a dev client's new build replaces it): its timers stopped, and nothing
/// of Roc's released, since what releases it is the last build's code.
pub fn reset() {
    let engine = ENGINE.with(|engine| engine.borrow_mut().take());
    if let Some(engine) = engine {
        for timer in engine.timers.values() {
            timer.stop.store(true, std::sync::atomic::Ordering::Relaxed);
        }
    }
}

/// The fields someone typed in (`<input>`s and `<textarea>`s, but passwords), each by a key a
/// remount of the same page finds it by again (its tag, its place among the fields, its name and
/// placeholder), and what it holds.
pub fn fields() -> Vec<(String, String)> {
    with(|engine| {
        field_nodes(&engine.dom).into_iter().filter_map(|(key, node)| engine.values.get(&node).map(|value| (key, value.clone()))).collect()
    })
}

/// A field `fields` noted, typed in again: an `input` event on the field with the same key, if
/// the page has one.
pub fn restore_field(key: &str, value: &str) {
    let node = with(|engine| field_nodes(&engine.dom).into_iter().find(|(each, _)| each == key).map(|(_, node)| node));
    if let Some(node) = node {
        dispatch(node, "input", value);
    }
}

fn field_nodes(dom: &Dom) -> Vec<(String, NodeId)> {
    let mut out = Vec::new();
    let mut stack = vec![dom.root];
    while let Some(node) = stack.pop() {
        if let Some(tag) = dom.tag(node)
            && matches!(tag, "input" | "textarea")
        {
            let kind = dom.attr(node, "type").unwrap_or("").to_ascii_lowercase();
            if !matches!(kind.as_str(), "password" | "hidden" | "checkbox" | "radio" | "file") {
                let key = format!("{tag}:{}:{}:{}", out.len(), dom.attr(node, "name").unwrap_or(""), dom.attr(node, "placeholder").unwrap_or(""));
                out.push((key, node));
            }
        }
        for &child in dom.nodes[node].children.iter().rev() {
            stack.push(child);
        }
    }
    out
}

pub fn started() -> bool {
    ENGINE.with(|engine| engine.borrow().is_some())
}

pub fn init(origin: String, path: String) {
    ENGINE.with(|engine| {
        *engine.borrow_mut() = Some(Engine {
            ids: 0,
            dom: Dom::new(),
            origin,
            path,
            kept: HashMap::new(),
            signals: HashMap::new(),
            comps: HashMap::new(),
            observers: HashMap::new(),
            lists: HashMap::new(),
            boundaries: HashMap::new(),
            loadings: HashMap::new(),
            handlers: HashMap::new(),
            probes: HashMap::new(),
            current: None,
            dirty: BTreeSet::new(),
            due: BTreeSet::new(),
            tasks: VecDeque::new(),
            waiters: HashMap::new(),
            requests: HashMap::new(),
            asked: HashMap::new(),
            readers: HashSet::new(),
            listeners: HashMap::new(),
            values: HashMap::new(),
            timers: HashMap::new(),
            titles: HashMap::new(),
            title_seqs: 0,
            title: None,
            calling: Vec::new(),
            place: String::new(),
            actions: HashMap::new(),
            submissions: HashMap::new(),
            revalidations: HashMap::new(),
            warned: HashSet::new(),
            outbox: Vec::new(),
        })
    });
}

impl Engine {
    fn id(&mut self) -> u64 {
        self.ids += 1;
        self.ids
    }

    fn comp(&mut self, id: u64) -> Option<&mut Comp> {
        self.comps.get_mut(&id)
    }

    /// The running computation's run, if it is one that makes things.
    fn making(&mut self) -> Option<&mut Made> {
        match self.current {
            Some(Current::Comp(id)) => self.comps.get_mut(&id)?.making.as_mut(),
            _ => None,
        }
    }

    /// A new computation, adopted by its owner's run (or its last run's).
    fn new_comp(&mut self, kind: CompKind, runner: Callable, owner: Option<u64>, scope: Scope, target: Target, name: &str) -> u64 {
        let id = self.id();
        self.comps.insert(id, Comp::new(kind, runner, scope, target, name));
        if let Some(owner) = owner
            && let Some(owner) = self.comps.get_mut(&owner)
        {
            match owner.making.as_mut() {
                Some(making) => making.children.push(id),
                None => owner.made.children.push(id),
            }
        }
        id
    }

    /// A read in the running computation: it runs again when what it read changes (`track`).
    fn track(&mut self, source: Source) {
        if let Some(making) = self.making()
            && making.untracked == 0
            && !making.sources.contains(&source)
        {
            making.sources.push(source);
        }
    }

    /// The running computation read or made something that changes (`touch`).
    pub fn touch(&mut self, read: bool) {
        if let Some(making) = self.making()
            && !(read && making.untracked > 0)
        {
            making.live = true;
        }
    }

    fn observe(&mut self, source: &Source, id: u64) {
        let list = self.observers.entry(source.clone()).or_default();
        if !list.contains(&id) {
            list.push(id);
        }
    }

    fn unobserve(&mut self, source: &Source, id: u64) {
        if let Some(list) = self.observers.get_mut(source) {
            list.retain(|&each| each != id);
            if list.is_empty() {
                self.observers.remove(source);
            }
        }
    }

    fn observers_of(&self, source: &Source) -> Vec<u64> {
        self.observers.get(source).cloned().unwrap_or_default()
    }

    fn schedule(&mut self, id: u64) {
        let Some(comp) = self.comps.get_mut(&id) else { return };
        if comp.disposed {
            return;
        }
        comp.recheck = false;
        self.dirty.insert(id);
    }

    fn schedule_observers(&mut self, source: &Source) {
        for id in self.observers_of(source) {
            self.schedule(id);
        }
    }

    fn keep(&mut self, callable: Callable) -> u64 {
        let id = self.id();
        self.kept.insert(id, callable);
        id
    }

    /// Lets go of a kept box.
    fn release_kept(&mut self, id: u64) {
        if let Some(callable) = self.kept.remove(&id) {
            roc::release(callable);
        }
    }

    /// The current handler's, if it is one: in a handler, applied when it is done; elsewhere, now.
    fn handler(&mut self) -> Option<&mut Handler> {
        match self.current {
            Some(Current::Handler(id)) => self.handlers.get_mut(&id),
            _ => None,
        }
    }

    /// Says something once (`warned`).
    pub fn warn_once(&mut self, key: &str, message: &str) {
        if self.warned.insert(key.to_string()) {
            log(Level::Warn, message);
        }
    }

    /// The scope the running computation or handler is in.
    fn current_scope(&self) -> Scope {
        match self.current {
            Some(Current::Comp(id)) => self.comps.get(&id).map(|comp| comp.scope.clone()).unwrap_or_default(),
            Some(Current::Handler(id)) => self.handlers.get(&id).map(|handler| handler.scope.clone()).unwrap_or_default(),
            _ => Scope::default(),
        }
    }

    /// What runs now belongs to (`owner()`): a computation, itself; a handler, the one that made it.
    fn owner(&self) -> Option<u64> {
        match self.current {
            Some(Current::Comp(id)) if self.comps.get(&id).is_some_and(|comp| comp.making.is_some()) => Some(id),
            Some(Current::Handler(id)) => self.handlers.get(&id).and_then(|handler| handler.owner),
            _ => None,
        }
    }

    /// Where a cleanup made now goes (`cleanupsOf`): the running computation's run, or an effect's
    /// apply. False with neither.
    fn push_cleanup(&mut self, cleanup: Cleanup) -> Result<(), Cleanup> {
        match self.current {
            Some(Current::Comp(id)) => match self.comps.get_mut(&id).and_then(|comp| comp.making.as_mut()) {
                Some(making) => {
                    making.cleanups.push(cleanup);
                    Ok(())
                }
                None => Err(cleanup),
            },
            Some(Current::Handler(id)) => match self.handlers.get(&id).and_then(|handler| handler.cleanups_of) {
                Some(effect) => match self.comps.get_mut(&effect) {
                    Some(effect) => {
                        effect.cleanups.push(cleanup);
                        Ok(())
                    }
                    None => Err(cleanup),
                },
                None => Err(cleanup),
            },
            _ => Err(cleanup),
        }
    }

    /// A URL the app gives, as the phone asks for it: a path is the server's.
    fn under(&self, url: &str) -> String {
        if url.starts_with('/') && !url.starts_with("//") { format!("{}{url}", self.origin.trim_end_matches('/')) } else { url.to_string() }
    }

    fn submissions_changed(&mut self, key: &str) {
        self.schedule_observers(&Source::Submission(key.to_string()));
    }
}

// ---- Running ----

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Outcome {
    Ok,
    Pending,
    Failed,
}

/// Runs a computation (`run`). A complete run replaces what the last one made; one that waits or
/// fails keeps it. The last complete run's cleanups run first.
pub fn run(id: u64) -> Option<Outcome> {
    let (recheck, kind, runner) = with(|engine| {
        let comp = engine.comp(id)?;
        if comp.disposed {
            return None;
        }
        Some((std::mem::take(&mut comp.recheck), comp.kind, comp.runner))
    })?;
    if recheck && !answers_changed(id) {
        return None;
    }
    let cleanups = with(|engine| engine.comp(id).map(|comp| std::mem::take(&mut comp.made.cleanups)).unwrap_or_default());
    clean_up(cleanups);
    let previous = with(|engine| {
        let comp = engine.comp(id)?;
        comp.making = Some(Made::default());
        comp.used = HashSet::new();
        Some(engine.current.replace(Current::Comp(id)))
    })?;
    let result = if kind == CompKind::Root { roc::mount() } else { roc::run(runner) };
    with(|engine| engine.current = previous);
    let (outcome, out, failure) = match result {
        Ok(out) => (Outcome::Ok, Some(out), None),
        Err(Abort::Wait(wait)) => {
            with(|engine| engine.waiters.entry(wait).or_default().push(Waiter::Comp(id)));
            (Outcome::Pending, None, None)
        }
        Err(Abort::Failed(why, memo)) => (Outcome::Failed, None, Some((why, memo))),
        Err(Abort::Crash(why)) => {
            log(Level::Error, &format!("rocx native: Roc crashed: {why}"));
            (Outcome::Failed, None, Some((format!("crashed: {why}"), None)))
        }
    };
    // What it reads now is what it depends on, whatever the outcome; an untracked run depends on
    // nothing (a read that waits runs it again).
    with(|engine| {
        let Some(comp) = engine.comps.get_mut(&id) else { return };
        let old = std::mem::take(&mut comp.sources);
        let sources = if comp.untracked { Vec::new() } else { comp.making.as_ref().map(|making| making.sources.clone()).unwrap_or_default() };
        comp.sources = sources.clone();
        for source in &old {
            engine.unobserve(source, id);
        }
        for source in &sources {
            engine.observe(source, id);
        }
    });
    if outcome == Outcome::Ok {
        settle(id, out.unwrap_or_default());
        let old = with(|engine| {
            let comp = engine.comp(id)?;
            let making = comp.making.take().unwrap_or_default();
            let old = std::mem::replace(&mut comp.made, making);
            comp.queries = comp.made.queries.clone();
            let used = std::mem::take(&mut comp.used);
            comp.calls.retain(|key, _| used.contains(key));
            Some(old)
        });
        if let Some(old) = old {
            drop_made(old);
        }
        loading_done(id);
    } else {
        let making = with(|engine| {
            let comp = engine.comp(id)?;
            let making = comp.making.take();
            if comp.kind == CompKind::Memo {
                let next = std::mem::replace(&mut comp.next, std::ptr::null_mut());
                roc::release(next);
            }
            making
        });
        if let Some(making) = making {
            drop_made(making);
        }
        if outcome == Outcome::Pending {
            if kind == CompKind::Root {
                log(Level::Error, "rocx: a component read a value that isn't in yet outside its markup: read it in a hole ({…}), which waits");
            }
            if kind != CompKind::Reaction {
                loading_wait(id);
            }
        } else if let Some((why, memo)) = failure {
            failed(id, why, memo);
        }
    }
    if kind == CompKind::Memo {
        with(|engine| {
            if let Some(comp) = engine.comp(id) {
                comp.refreshing = outcome == Outcome::Pending && !comp.value.is_null() && comp.state != MemoState::Failed;
            }
        });
        restale(id);
        if outcome != Outcome::Pending {
            recheck_readers(id);
        }
    }
    if outcome != Outcome::Pending {
        revalidated(id);
    }
    Some(outcome)
}

/// Whether a memo, or one it reads, has a value and waits for a new one (`restale`).
fn restale(id: u64) {
    let changed = with(|engine| {
        let comp = engine.comps.get(&id)?;
        if comp.disposed {
            return None;
        }
        let mut stale = comp.refreshing;
        if comp.state != MemoState::Failed {
            for source in &comp.sources {
                if let Source::Memo(memo) = source
                    && engine.comps.get(memo).is_some_and(|memo| memo.stale)
                {
                    stale = true;
                }
            }
        }
        let comp = engine.comps.get_mut(&id)?;
        if stale == comp.stale {
            return None;
        }
        comp.stale = stale;
        Some(engine.observers_of(&Source::Memo(id)).into_iter().filter(|observer| engine.comps.get(observer).is_some_and(|comp| comp.kind == CompKind::Memo)).collect::<Vec<_>>())
    });
    if let Some(memos) = changed {
        recheck_readers(id);
        for memo in memos {
            restale(memo);
        }
    }
}

/// The computations whose `is_pending!` read the memo, rechecked in the flush.
fn recheck_readers(memo: u64) {
    with(|engine| {
        for reader in engine.observers_of(&Source::Pending(memo)) {
            if engine.dirty.contains(&reader) {
                continue;
            }
            let Some(comp) = engine.comps.get_mut(&reader) else { continue };
            if comp.disposed {
                continue;
            }
            comp.recheck = true;
            engine.dirty.insert(reader);
        }
    });
}

fn pending(memos: &[u64]) -> bool {
    with(|engine| memos.iter().any(|memo| engine.comps.get(memo).is_some_and(|memo| memo.stale)))
}

/// Whether an `is_pending!` the computation's last run called answers otherwise now.
fn answers_changed(id: u64) -> bool {
    let queries = with(|engine| engine.comps.get(&id).map(|comp| comp.queries.iter().map(|query| (engine.kept.get(&query.probe).copied(), query.memos.clone(), query.answer)).collect::<Vec<_>>()).unwrap_or_default());
    for (probe_box, memos, answer) in queries {
        let Some(probe_box) = probe_box else { return true };
        let now = probe(probe_box);
        if pending(&now) != answer || now != memos {
            return true;
        }
    }
    false
}

/// Runs an accessor once, its reads untracked: the memos it reads, in order (`probe`).
pub fn probe(callable: Callable) -> Vec<u64> {
    let (id, previous) = with(|engine| {
        let id = engine.id();
        engine.probes.insert(id, Probe { memos: Vec::new(), calls: HashMap::new() });
        (id, engine.current.replace(Current::Probe(id)))
    });
    let result = roc::run(callable);
    if let Err(Abort::Crash(why)) = result {
        log(Level::Error, &format!("rocx native: Roc crashed in a probe: {why}"));
    }
    with(|engine| {
        engine.current = previous;
        engine.probes.remove(&id).map(|probe| probe.memos).unwrap_or_default()
    })
}

/// A complete run's answer, applied: the node patched, or the memo's value set (`settle`).
fn settle(id: u64, out: String) {
    let Some((kind, target, name)) = with(|engine| engine.comps.get(&id).map(|comp| (comp.kind, comp.target, comp.name.clone()))) else { return };
    match kind {
        CompKind::Memo => {
            let waiters = with(|engine| {
                let comp = engine.comp(id)?;
                let old = std::mem::replace(&mut comp.value, std::ptr::null_mut());
                roc::release(old);
                comp.value = std::mem::replace(&mut comp.next, std::ptr::null_mut());
                comp.state = MemoState::Ok;
                engine.schedule_observers(&Source::Memo(id));
                engine.waiters.remove(&Wait::Memo(id))
            });
            wake(waiters.unwrap_or_default());
        }
        CompKind::Reaction => {
            let render = with(|engine| {
                let comp = engine.comp(id)?;
                comp.apply = out.trim_matches('"').parse().unwrap_or(0);
                comp.failure = None;
                let render = comp.render;
                if render {
                    engine.due.remove(&id);
                } else {
                    engine.due.insert(id);
                }
                Some(render)
            });
            if render == Some(true) {
                apply_reaction(id);
            }
        }
        CompKind::Show => settle_show(id, out == "true"),
        CompKind::For => {
            let entries: Vec<Value> = serde_json::from_str(&out).unwrap_or_default();
            settle_for(id, entries)
        }
        CompKind::Text | CompKind::Attr | CompKind::Optional | CompKind::Style | CompKind::Flag | CompKind::Class => {
            let Target::Node(node) = target else { return };
            let value: Value = serde_json::from_str(&out).unwrap_or(Value::Null);
            with(|engine| patch(engine, kind, node, &name, &value));
        }
        CompKind::Html | CompKind::Root => {
            let parsed: Value = serde_json::from_str(&out).unwrap_or(Value::Null);
            let nodes = match parsed {
                Value::Array(nodes) => nodes,
                other => vec![other],
            };
            let peek = with(|engine| {
                let comp = engine.comp(id)?;
                if comp.peek {
                    comp.peeked = Some(nodes.clone());
                    return Some(true);
                }
                Some(false)
            });
            if peek != Some(false) {
                return;
            }
            let Target::Range(range) = target else { return };
            let scope = with(|engine| engine.comps.get(&id).map(|comp| comp.scope.clone()).unwrap_or_default());
            let fragment = with(|engine| engine.dom.fragment());
            for node in &nodes {
                let built = build(node, Some(id), &scope);
                with(|engine| engine.dom.append(fragment, built));
            }
            with(|engine| engine.dom.replace_range(range, fragment));
        }
        _ => {}
    }
}

/// A node's text, attribute, flag, class or style, set when it differs.
fn patch(engine: &mut Engine, kind: CompKind, node: NodeId, name: &str, value: &Value) {
    let text = value.as_str().unwrap_or("").to_string();
    let on = value.as_bool().unwrap_or(false);
    match kind {
        CompKind::Text => {
            if engine.dom.text_of(node) != text {
                engine.dom.set_text(node, &text);
            }
        }
        CompKind::Attr => {
            if name == "value" {
                // What a field shows is its property once someone has typed in it.
                let now = engine.values.get(&node).cloned().or_else(|| engine.dom.attr(node, "value").map(str::to_string));
                if now.as_deref() != Some(text.as_str()) {
                    engine.dom.set_attr(node, name, &text);
                    engine.values.insert(node, text);
                }
            } else if engine.dom.attr(node, name) != Some(text.as_str()) {
                engine.dom.set_attr(node, name, &text);
            }
        }
        CompKind::Optional => {
            if text.is_empty() {
                engine.dom.remove_attr(node, name);
            } else {
                engine.dom.set_attr(node, name, &text);
            }
        }
        CompKind::Style => engine.dom.set_style(node, name, &text),
        CompKind::Class => engine.dom.toggle_class(node, name, on),
        CompKind::Flag => {
            if on {
                engine.dom.set_attr(node, name, "");
            } else {
                engine.dom.remove_attr(node, name);
            }
        }
        _ => {}
    }
}

/// What failed in a computation: a memo fails, an effect with an error handler is told, anything
/// else shows the nearest <Errored> (`failed`).
fn failed(id: u64, why: String, memo: Option<u64>) {
    loading_done(id);
    let (kind, errored, on_error) = match with(|engine| engine.comps.get(&id).map(|comp| (comp.kind, comp.scope.errored, comp.on_error))) {
        Some(found) => found,
        None => return,
    };
    if kind == CompKind::Memo {
        let waiters = with(|engine| {
            let comp = engine.comp(id)?;
            comp.state = MemoState::Failed;
            comp.error = why.clone();
            engine.schedule_observers(&Source::Memo(id));
            engine.waiters.remove(&Wait::Memo(id))
        });
        wake(waiters.unwrap_or_default());
        return;
    }
    if kind == CompKind::Reaction && on_error != 0 {
        with(|engine| {
            if let Some(comp) = engine.comp(id) {
                comp.failure = Some(why.clone());
            }
            engine.due.insert(id);
        });
        return;
    }
    let memo = if kind == CompKind::Memo { Some(id) } else { memo };
    match errored {
        Some(boundary) => errored_fail(boundary, why, memo),
        None => log(Level::Error, &format!("rocx: {why} (no <Errored> around it)")),
    }
}

/// Lets go of what a run made (`drop`): its computations stop (the last made first), its cleanups
/// run (the last first), and its boxes and signals are released.
fn drop_made(made: Made) {
    for child in made.children.iter().rev() {
        dispose(*child);
    }
    clean_up(made.cleanups);
    with(|engine| {
        for id in made.kept {
            stop_timer(engine, id);
            engine.release_kept(id);
        }
        for id in made.signals {
            if let Some(value) = engine.signals.remove(&id) {
                roc::release(value);
            }
        }
    });
}

pub fn dispose(id: u64) {
    let found = with(|engine| {
        let comp = engine.comp(id)?;
        if comp.disposed {
            return None;
        }
        comp.disposed = true;
        let sources = std::mem::take(&mut comp.sources);
        let kind = comp.kind;
        let cleanups = if kind == CompKind::Reaction { std::mem::take(&mut comp.cleanups) } else { Vec::new() };
        let made = std::mem::take(&mut comp.made);
        let part = comp.part.take();
        let list = comp.list;
        engine.readers.remove(&id);
        engine.due.remove(&id);
        engine.dirty.remove(&id);
        for source in &sources {
            engine.unobserve(source, id);
        }
        Some((kind, cleanups, made, part, list))
    });
    let Some((kind, cleanups, made, part, list)) = found else { return };
    revalidated(id);
    loading_done(id);
    if kind == CompKind::Reaction {
        clean_up(cleanups);
    }
    drop_made(made);
    if let Some(part) = part {
        dispose(part);
    }
    if let Some(list) = list {
        drop_list(list);
    }
    with(|engine| {
        if let Some(comp) = engine.comps.remove(&id) {
            // A memo's and an effect's computation is its own box (not one kept for markup).
            if matches!(comp.kind, CompKind::Memo | CompKind::Reaction) {
                roc::release(comp.runner);
            }
            roc::release(comp.value);
            roc::release(comp.next);
        }
    });
}

/// Runs cleanups, the last first (`cleanUp`): a kept box as a handler (it may write signals), then
/// let go of.
fn clean_up(cleanups: Vec<Cleanup>) {
    for cleanup in cleanups.into_iter().rev() {
        match cleanup {
            Cleanup::Kept(id) => {
                if with(|engine| engine.kept.contains_key(&id)) {
                    handle(id, String::new(), Scope::default(), None, None, None);
                    with(|engine| engine.release_kept(id));
                }
            }
            Cleanup::Timer(id) => with(|engine| {
                stop_timer(engine, id);
                engine.release_kept(id);
            }),
            Cleanup::Title(owner) => with(|engine| {
                engine.titles.remove(&owner);
                show_title(engine);
            }),
            Cleanup::Action(key) => with(|engine| {
                let left = engine.actions.get(&key).copied().unwrap_or(1).saturating_sub(1);
                if left > 0 {
                    engine.actions.insert(key, left);
                } else {
                    engine.actions.remove(&key);
                }
            }),
        }
    }
}

/// Wakes what waited for something now in: a computation runs again, a handler too.
fn wake(waiters: Vec<Waiter>) {
    for waiter in waiters {
        match waiter {
            Waiter::Comp(id) => with(|engine| engine.schedule(id)),
            Waiter::Handler(id) => with(|engine| engine.tasks.push_back(Task::Wake(id))),
        }
    }
}

/// Runs what is dirty, oldest first, then the effects whose apply is due, then what waits for
/// after them (`flush`).
pub fn flush() {
    loop {
        let next = with(|engine| {
            if let Some(id) = engine.dirty.pop_first() {
                return Some(Step::Run(id));
            }
            if let Some(id) = engine.due.pop_first() {
                return Some(Step::Apply(id));
            }
            engine.tasks.pop_front().map(Step::Task)
        });
        match next {
            Some(Step::Run(id)) => {
                run(id);
            }
            Some(Step::Apply(id)) => apply_reaction(id),
            Some(Step::Task(Task::Fallback(id))) => errored_fallback(id),
            Some(Step::Task(Task::ReleaseKept(id))) => with(|engine| engine.release_kept(id)),
            Some(Step::Task(Task::Wake(id))) => {
                let runs = with(|engine| engine.handlers.get(&id).is_some_and(|handler| engine.kept.contains_key(&handler.runner)));
                if runs {
                    go(id);
                } else {
                    with(|engine| engine.handlers.remove(&id));
                }
            }
            None => break,
        }
    }
    let calls = with(|engine| std::mem::take(&mut engine.calling));
    for (name, arg) in calls {
        crate::call_native(&name, &arg);
    }
}

enum Step {
    Run(u64),
    Apply(u64),
    Task(Task),
}

/// An effect's apply (`applyReaction`): its last apply's cleanups first, then the box its compute
/// kept, as a handler; a failed compute's error handler instead, given why.
fn apply_reaction(id: u64) {
    let found = with(|engine| {
        let comp = engine.comp(id)?;
        if comp.disposed {
            return None;
        }
        let failure = comp.failure.take();
        let runner = if failure.is_some() { comp.on_error } else { comp.apply };
        let cleanups = std::mem::take(&mut comp.cleanups);
        let scope = comp.scope.clone();
        if !engine.kept.contains_key(&runner) {
            if let Some(comp) = engine.comp(id) {
                comp.cleanups = cleanups;
            }
            return None;
        }
        Some((failure, runner, cleanups, scope))
    });
    let Some((failure, runner, cleanups, scope)) = found else { return };
    clean_up(cleanups);
    handle(runner, failure.unwrap_or_default(), scope, Some(id), Some(id), None);
}

/// Computes a memo again, asking the server again (`refresh`).
fn refresh(memo: u64) {
    with(|engine| {
        if let Some(comp) = engine.comp(memo) {
            comp.calls.clear();
            if comp.state == MemoState::Failed {
                comp.state = MemoState::Pending;
                comp.error.clear();
            }
        }
        engine.schedule(memo);
    });
}

/// Writes a handler made, applied together once it is done (`apply`).
fn apply(writes: Vec<Write>) {
    for write in writes {
        match write {
            Write::Signal(id, value) => with(|engine| {
                // Its part went away while the handler ran: nothing reads it.
                match engine.signals.get_mut(&id) {
                    Some(slot) => {
                        let old = std::mem::replace(slot, value);
                        roc::release(old);
                        engine.schedule_observers(&Source::Signal(id));
                    }
                    None => roc::release(value),
                }
            }),
            Write::Refresh(memo) => refresh(memo),
            Write::Retry(boundary) => errored_retry(boundary),
            Write::Effect(name, arg) => with(|engine| engine.calling.push((name, arg))),
            Write::Cleared(key) => with(|engine| {
                let source = engine.submissions.entry(key.clone()).or_default();
                source.list.pop();
                source.cleared = true;
                engine.submissions_changed(&key);
            }),
            Write::Dropped(key, id) => with(|engine| {
                let source = engine.submissions.entry(key.clone()).or_default();
                source.list.retain(|entry| entry.id != id);
                engine.submissions_changed(&key);
            }),
            Write::Submit { method, url, body, input } => send_action(&method, &url, &body, &input),
        }
    }
}

fn later(write: Write) {
    let now = with(|engine| match engine.handler() {
        Some(handler) => {
            handler.writes.push(write);
            None
        }
        None => Some(write),
    });
    if let Some(write) = now {
        apply(vec![write]);
    }
}

/// Runs a handler, a box the engine keeps (`handle`). If it waits for an answer from the server,
/// its writes are dropped, and it runs again once the answer is in. `owner`: what a timer it starts
/// belongs to; `cleanups_of`: an effect whose apply it is; `release`: a box let go of once it ran.
pub fn handle(runner: u64, event: String, scope: Scope, owner: Option<u64>, cleanups_of: Option<u64>, release: Option<u64>) {
    let id = with(|engine| {
        let id = engine.id();
        engine.handlers.insert(id, Handler { runner, calls: HashMap::new(), writes: Vec::new(), event, scope, owner, cleanups_of, release });
        id
    });
    go(id);
}

fn go(id: u64) {
    let found = with(|engine| {
        let handler = engine.handlers.get_mut(&id)?;
        handler.writes.clear();
        let runner = handler.runner;
        let effect = handler.cleanups_of;
        let callable = engine.kept.get(&runner).copied()?;
        let mark = effect.and_then(|effect| engine.comps.get(&effect)).map(|effect| effect.cleanups.len()).unwrap_or(0);
        Some((callable, effect, mark, engine.current.replace(Current::Handler(id))))
    });
    let Some((callable, effect, mark, previous)) = found else {
        with(|engine| engine.handlers.remove(&id));
        return;
    };
    let result = roc::run(callable);
    with(|engine| engine.current = previous);
    match result {
        Ok(_) => {
            let (writes, release) = with(|engine| engine.handlers.remove(&id).map(|handler| (handler.writes, handler.release)).unwrap_or_default());
            apply(writes);
            if let Some(kept) = release {
                with(|engine| engine.release_kept(kept));
            }
        }
        Err(why) => {
            let dropped = with(|engine| {
                let writes = engine.handlers.get_mut(&id).map(|handler| std::mem::take(&mut handler.writes)).unwrap_or_default();
                for write in writes {
                    if let Write::Signal(_, value) = write {
                        roc::release(value);
                    }
                }
                effect.and_then(|effect| engine.comp(effect)).map(|effect| effect.cleanups.split_off(mark.min(effect.cleanups.len()))).unwrap_or_default()
            });
            clean_up(dropped);
            match why {
                Abort::Wait(wait) => with(|engine| engine.waiters.entry(wait).or_default().push(Waiter::Handler(id))),
                Abort::Failed(why, _) | Abort::Crash(why) => {
                    log(Level::Error, &format!("rocx: a handler failed: {why}"));
                    let release = with(|engine| engine.handlers.remove(&id).and_then(|handler| handler.release));
                    if let Some(kept) = release {
                        with(|engine| engine.release_kept(kept));
                    }
                }
            }
        }
    }
}

// ---- Boundaries ----

fn loading_wait(id: u64) {
    with(|engine| {
        let Some(loading) = engine.comps.get(&id).and_then(|comp| comp.scope.loading) else { return };
        if let Some(loading) = engine.loadings.get_mut(&loading)
            && !loading.revealed
        {
            loading.waiting.insert(id);
        }
    });
}

/// A computation inside a <Loading> has its value (or failed, or went): the <Loading> shows what is
/// inside once everything has (`Loading.done`).
fn loading_done(id: u64) {
    with(|engine| {
        let Some(at) = engine.comps.get(&id).and_then(|comp| comp.scope.loading) else { return };
        let Some(loading) = engine.loadings.get_mut(&at) else { return };
        loading.waiting.remove(&id);
        if !loading.revealed && loading.built && loading.waiting.is_empty() {
            reveal(engine, at);
        }
    });
}

fn reveal(engine: &mut Engine, at: u64) {
    let Some(loading) = engine.loadings.get_mut(&at) else { return };
    loading.revealed = true;
    let (range, children) = (loading.range, loading.children);
    engine.dom.replace_range(range, children);
}

/// Builds what is inside an <Errored>, owned by a computation of its own (`Errored.build`).
fn errored_build(boundary: u64) -> NodeId {
    let (nodes, scope) = with(|engine| {
        let errored = engine.boundaries.get(&boundary).expect("an <Errored> it builds");
        let (owner, scope, nodes) = (errored.owner, errored.scope.clone(), errored.nodes.clone());
        let inner = Scope { errored: Some(boundary), ..scope };
        let inside = engine.new_comp(CompKind::Boundary, std::ptr::null_mut(), owner, inner.clone(), Target::None, "");
        if let Some(errored) = engine.boundaries.get_mut(&boundary) {
            errored.inside = Some(inside);
        }
        (nodes, (inside, inner))
    });
    let fragment = with(|engine| engine.dom.fragment());
    for node in &nodes {
        let built = build(node, Some(scope.0), &scope.1);
        with(|engine| engine.dom.append(fragment, built));
    }
    fragment
}

/// Something inside failed: once what failed is done, the fallback shows instead (`Errored.fail`).
fn errored_fail(boundary: u64, problem: String, memo: Option<u64>) {
    with(|engine| {
        let Some(errored) = engine.boundaries.get_mut(&boundary) else { return };
        if let Some(memo) = memo
            && !errored.memos.contains(&memo)
        {
            errored.memos.push(memo);
        }
        if errored.failed.is_some() {
            return;
        }
        errored.failed = Some(problem);
        engine.tasks.push_back(Task::Fallback(boundary));
    });
}

fn errored_fallback(boundary: u64) {
    let found = with(|engine| {
        let errored = engine.boundaries.get(&boundary)?;
        errored.failed.as_ref()?;
        Some((errored.inside, errored.runner, errored.owner, errored.scope.clone(), errored.range))
    });
    let Some((inside, runner, owner, scope, range)) = found else { return };
    if let Some(inside) = inside {
        dispose(inside);
    }
    let fallback = with(|engine| {
        let fallback = engine.new_comp(CompKind::Html, runner, owner, scope, Target::Range(range), "fallback");
        if let Some(comp) = engine.comp(fallback) {
            comp.boundary = Some(boundary);
        }
        if let Some(errored) = engine.boundaries.get_mut(&boundary) {
            errored.fallback = Some(fallback);
        }
        fallback
    });
    run(fallback);
}

/// Shows what is inside again, and reads again what failed (`Errored.retry`).
fn errored_retry(boundary: u64) {
    let found = with(|engine| {
        let errored = engine.boundaries.get_mut(&boundary)?;
        errored.failed.as_ref()?;
        errored.failed = None;
        let memos = std::mem::take(&mut errored.memos);
        Some((errored.fallback.take(), memos, errored.range))
    });
    let Some((fallback, memos, range)) = found else { return };
    if let Some(fallback) = fallback {
        dispose(fallback);
    }
    let failed = with(|engine| {
        let mut failed = memos.clone();
        let mut at = 0;
        while at < failed.len() {
            if let Some(memo) = engine.comps.get(&failed[at]) {
                for source in &memo.sources {
                    if let Source::Memo(up) = source
                        && engine.comps.get(up).is_some_and(|up| up.state == MemoState::Failed)
                        && !failed.contains(up)
                    {
                        failed.push(*up);
                    }
                }
            }
            at += 1;
        }
        failed
    });
    for memo in failed {
        refresh(memo);
    }
    let built = errored_build(boundary);
    with(|engine| engine.dom.replace_range(range, built));
}

// ---- <Show> and <For> ----

/// A part of the markup, built in `range`, owned by a computation of its own (`part`).
fn part(nodes: &[Value], scope: &Scope, range: Range) -> u64 {
    let owner = with(|engine| engine.new_comp(CompKind::Boundary, std::ptr::null_mut(), None, scope.clone(), Target::None, ""));
    let fragment = with(|engine| engine.dom.fragment());
    for node in nodes {
        let built = build(node, Some(owner), scope);
        with(|engine| engine.dom.append(fragment, built));
    }
    with(|engine| engine.dom.replace_range(range, fragment));
    owner
}

/// A <Show>: only a change of whether its condition holds switches what it shows (`settleShow`).
fn settle_show(id: u64, holds: bool) {
    let found = with(|engine| {
        let comp = engine.comp(id)?;
        if comp.holds == Some(holds) {
            return None;
        }
        comp.holds = Some(holds);
        let Target::Range(range) = comp.target else { return None };
        Some((comp.part.take(), comp.node.clone()?, range, comp.scope.clone()))
    });
    let Some((old, node, range, scope)) = found else { return };
    if let Some(old) = old {
        dispose(old);
    }
    let with_box = node.get("with").and_then(Value::as_u64);
    let made = if holds && let Some(with_box) = with_box {
        // A function child: made when it shows, by its own computation, once, untracked.
        let made = with(|engine| {
            let runner = engine.kept.get(&with_box).copied().unwrap_or(std::ptr::null_mut());
            let made = engine.new_comp(CompKind::Html, runner, None, scope.clone(), Target::Range(range), "");
            if let Some(comp) = engine.comp(made) {
                comp.untracked = true;
            }
            made
        });
        run(made);
        made
    } else {
        let nodes: Vec<Value> = if holds { node.get("c").and_then(Value::as_array).cloned().unwrap_or_default() } else { node.get("fallback").cloned().into_iter().collect() };
        part(&nodes, &scope, range)
    };
    with(|engine| {
        if let Some(comp) = engine.comp(id) {
            comp.part = Some(made);
        }
    });
}

/// A <For>'s rows, from what its list says now (`settleFor`): a row whose key is still there is
/// kept and moved, a new key gets a new row, a key that is gone takes its row and item with it.
fn settle_for(id: u64, entries: Vec<Value>) {
    let Some((list, range, scope, node)) = with(|engine| {
        let comp = engine.comp(id)?;
        comp.settled = true;
        let Target::Range(range) = comp.target else { return None };
        Some((comp.list?, range, comp.scope.clone(), comp.node.clone()?))
    }) else {
        return;
    };
    let mut order = Vec::new();
    for (index, entry) in entries.iter().enumerate() {
        let key = entry.get("k").and_then(Value::as_str).unwrap_or("").to_string();
        let runner = entry.get("r").and_then(Value::as_u64).unwrap_or(0);
        let fresh = with(|engine| {
            if let Some(making) = engine.comp(id).and_then(|comp| comp.making.as_mut()) {
                making.kept.retain(|&kept| kept != runner);
            }
            let exists = engine.lists.get(&list).is_some_and(|list| list.rows.contains_key(&key));
            if exists {
                // Still there: the box this run made for it isn't needed.
                engine.release_kept(runner);
                let moved = engine.lists.get_mut(&list).and_then(|list| {
                    let at = list.indexes.get_mut(&key)?;
                    if *at == index as u64 {
                        return None;
                    }
                    *at = index as u64;
                    Some(())
                });
                if moved.is_some() {
                    engine.schedule_observers(&Source::Index(list, key.clone()));
                }
                return None;
            }
            let (row_range, fragment) = engine.dom.make_range();
            let callable = engine.kept.get(&runner).copied().unwrap_or(std::ptr::null_mut());
            let comp = engine.new_comp(CompKind::Html, callable, None, scope.clone(), Target::Range(row_range), "");
            if let Some(row) = engine.comp(comp) {
                row.untracked = true;
            }
            let list = engine.lists.get_mut(&list)?;
            list.indexes.insert(key.clone(), index as u64);
            list.rows.insert(key.clone(), Row { runner, range: row_range, comp, fresh: Some(fragment) });
            Some(comp)
        });
        if let Some(comp) = fresh {
            run(comp);
        }
        if !order.contains(&key) {
            order.push(key);
        }
    }
    // Rows whose key is gone, and their items.
    let gone = with(|engine| {
        let list = engine.lists.get_mut(&list)?;
        let gone: Vec<String> = list.rows.keys().filter(|key| !order.contains(key)).cloned().collect();
        let items: Vec<String> = list.items.keys().filter(|key| !order.contains(key)).cloned().collect();
        for key in items {
            if let Some(item) = list.items.remove(&key) {
                roc::release(item);
            }
        }
        Some(gone)
    });
    for key in gone.unwrap_or_default() {
        drop_row(list, &key);
    }
    with(|engine| {
        if let Some(list) = engine.lists.get_mut(&list) {
            list.order = order.clone();
        }
    });
    // The fallback while there are no rows.
    let (part_now, fallback_range) = with(|engine| engine.comp(id).map(|comp| (comp.part, comp.fallback_range)).unwrap_or_default());
    if !order.is_empty() {
        if let Some(part) = part_now {
            dispose(part);
        }
        with(|engine| {
            if let Some(comp) = engine.comp(id) {
                comp.part = None;
                if let Some(fallback) = comp.fallback_range.take() {
                    engine.dom.remove_range(fallback);
                }
            }
        });
    } else if fallback_range.is_none() {
        let (fallback, fragment) = with(|engine| {
            let (fallback, fragment) = engine.dom.make_range();
            if let Some(parent) = engine.dom.nodes[range.end].parent {
                engine.dom.insert_before(parent, fragment, Some(range.end));
            }
            (fallback, fragment)
        });
        let _ = fragment;
        let nodes: Vec<Value> = node.get("fallback").cloned().into_iter().collect();
        let made = part(&nodes, &scope, fallback);
        with(|engine| {
            if let Some(comp) = engine.comp(id) {
                comp.part = Some(made);
                comp.fallback_range = Some(fallback);
            }
        });
    }
    // Rows in order: one already where it goes stays; the others move (or arrive) there.
    with(|engine| {
        let Some(parent) = engine.dom.nodes[range.start].parent else { return };
        let mut at = engine.dom.next_sibling(range.start);
        for key in &order {
            let Some(row) = engine.lists.get_mut(&list).and_then(|list| list.rows.get_mut(key)) else { continue };
            let (row_range, fresh) = (row.range, row.fresh.take());
            if at == Some(row_range.start) {
                at = engine.dom.next_sibling(row_range.end);
                continue;
            }
            let moving = match fresh {
                Some(fragment) => fragment,
                None => engine.dom.collect_range(row_range),
            };
            engine.dom.insert_before(parent, moving, at);
        }
    });
}

fn drop_row(list: u64, key: &str) {
    let row = with(|engine| {
        let list = engine.lists.get_mut(&list)?;
        list.indexes.remove(key);
        list.rows.remove(key)
    });
    let Some(row) = row else { return };
    dispose(row.comp);
    with(|engine| {
        engine.release_kept(row.runner);
        engine.dom.remove_range(row.range);
    });
}

fn drop_list(list: u64) {
    let keys = with(|engine| engine.lists.get(&list).map(|list| list.rows.keys().cloned().collect::<Vec<_>>()).unwrap_or_default());
    for key in keys {
        drop_row(list, &key);
    }
    with(|engine| {
        if let Some(list) = engine.lists.get_mut(&list) {
            for (_, item) in list.items.drain() {
                roc::release(item);
            }
            list.rows.clear();
            list.order.clear();
        }
    });
}

// ---- Building ----

fn kept_box(id: Option<u64>) -> Callable {
    with(|engine| id.and_then(|id| engine.kept.get(&id).copied()).unwrap_or(std::ptr::null_mut()))
}

/// A static hole's computation, let go of: nothing will run it (`forget`).
fn forget(id: u64, owner: Option<u64>) {
    with(|engine| {
        if engine.comps.get(&id).is_none_or(|comp| !comp.made.kept.is_empty()) {
            return;
        }
        if let Some(owner) = owner.and_then(|owner| engine.comps.get_mut(&owner)) {
            let children = match owner.making.as_mut() {
                Some(making) => &mut making.children,
                None => &mut owner.made.children,
            };
            if children.last() == Some(&id) {
                children.pop();
            }
        }
        engine.comps.remove(&id);
    });
}

fn is_static(id: u64, outcome: Option<Outcome>) -> bool {
    outcome == Some(Outcome::Ok) && with(|engine| engine.comps.get(&id).is_some_and(|comp| comp.made.inert()))
}

/// Builds a node of the markup's JSON (`build`): a node of the engine's document, or a fragment.
pub fn build(node: &Value, owner: Option<u64>, scope: &Scope) -> NodeId {
    let kind = node.get("t").and_then(Value::as_str).unwrap_or("");
    let reference = node.get("r").and_then(Value::as_u64);
    match kind {
        "s" | "raw" => with(|engine| engine.dom.text(node.get("v").and_then(Value::as_str).unwrap_or(""))),
        "x" => {
            let (text, comp) = with(|engine| {
                let text = engine.dom.text("");
                let runner = reference.and_then(|id| engine.kept.get(&id).copied()).unwrap_or(std::ptr::null_mut());
                (text, engine.new_comp(CompKind::Text, runner, owner, scope.clone(), Target::Node(text), ""))
            });
            let outcome = run(comp);
            if is_static(comp, outcome) {
                forget(comp, owner);
            }
            text
        }
        "h" | "l" => {
            let runner = kept_box(reference);
            let comp = with(|engine| {
                let comp = engine.new_comp(CompKind::Html, runner, owner, scope.clone(), Target::None, "");
                if let Some(made) = engine.comp(comp) {
                    made.peek = true;
                }
                comp
            });
            let outcome = run(comp);
            let nodes = with(|engine| {
                let made = engine.comp(comp)?;
                made.peek = false;
                made.peeked.take()
            });
            if is_static(comp, outcome) {
                let fragment = with(|engine| engine.dom.fragment());
                for child in nodes.unwrap_or_default() {
                    let built = build(&child, Some(comp), scope);
                    with(|engine| engine.dom.append(fragment, built));
                }
                return fragment;
            }
            let (range, fragment) = with(|engine| {
                let (range, fragment) = engine.dom.make_range();
                if let Some(made) = engine.comp(comp) {
                    made.target = Target::Range(range);
                }
                (range, fragment)
            });
            if let Some(nodes) = nodes {
                for child in nodes {
                    let built = build(&child, Some(comp), scope);
                    with(|engine| engine.dom.insert_before(fragment, built, Some(range.end)));
                }
            }
            fragment
        }
        "f" => {
            let fragment = with(|engine| engine.dom.fragment());
            for child in children(node) {
                let built = build(child, owner, scope);
                with(|engine| engine.dom.append(fragment, built));
            }
            fragment
        }
        "e" => element(node, owner, scope),
        "loading" => {
            let (at, range, fragment, inner) = with(|engine| {
                let at = engine.id();
                let (range, fragment) = engine.dom.make_range();
                let children = engine.dom.fragment();
                engine.loadings.insert(at, Loading { waiting: HashSet::new(), revealed: false, built: false, range, children });
                (at, range, fragment, Scope { loading: Some(at), ..scope.clone() })
            });
            for child in children(node) {
                let built = build(child, owner, &inner);
                with(|engine| {
                    let children = engine.loadings[&at].children;
                    engine.dom.append(children, built)
                });
            }
            let waiting = with(|engine| {
                let loading = engine.loadings.get_mut(&at)?;
                loading.built = true;
                Some(!loading.waiting.is_empty())
            });
            if waiting == Some(true) {
                let fallback = node.get("fallback").cloned().unwrap_or(Value::Null);
                let built = build(&fallback, owner, scope);
                with(|engine| engine.dom.replace_range(range, built));
            } else {
                with(|engine| {
                    if !engine.loadings[&at].revealed {
                        reveal(engine, at)
                    }
                });
            }
            fragment
        }
        "show" | "for" => {
            let runner = kept_box(reference);
            let shared = Rc::new(node.clone());
            let (comp, fragment) = with(|engine| {
                let (range, fragment) = engine.dom.make_range();
                let comp = engine.new_comp(if kind == "show" { CompKind::Show } else { CompKind::For }, runner, owner, scope.clone(), Target::Range(range), "");
                let list = node.get("id").and_then(Value::as_u64);
                if let Some(list) = list {
                    engine.lists.entry(list).or_default();
                }
                if let Some(made) = engine.comp(comp) {
                    made.node = Some(shared);
                    if kind == "for" {
                        made.list = list;
                    }
                }
                (comp, fragment)
            });
            run(comp);
            fragment
        }
        "errored" => {
            let runner = kept_box(reference);
            let (boundary, range, fragment) = with(|engine| {
                let (range, fragment) = engine.dom.make_range();
                let boundary = engine.id();
                engine.boundaries.insert(boundary, Errored { runner, nodes: children(node).cloned().collect(), owner, scope: scope.clone(), range, failed: None, memos: Vec::new(), inside: None, fallback: None });
                (boundary, range, fragment)
            });
            let built = errored_build(boundary);
            with(|engine| engine.dom.insert_before(fragment, built, Some(range.end)));
            fragment
        }
        "c" => {
            let (comp, nodes) = component(reference, owner, scope);
            let fragment = with(|engine| engine.dom.fragment());
            for child in &nodes {
                let built = build(child, comp, scope);
                with(|engine| engine.dom.append(fragment, built));
            }
            fragment
        }
        "ctx" => {
            let mut contexts = (*scope.contexts).clone();
            if let (Some(name), Some(value)) = (node.get("n").and_then(Value::as_str), node.get("v").and_then(Value::as_u64)) {
                contexts.insert(name.to_string(), value);
            }
            let inner = Scope { contexts: Rc::new(contexts), ..scope.clone() };
            let fragment = with(|engine| engine.dom.fragment());
            for child in children(node) {
                let built = build(child, owner, &inner);
                with(|engine| engine.dom.append(fragment, built));
            }
            fragment
        }
        "doctype" => with(|engine| engine.dom.fragment()),
        "nh" => with(|engine| {
            engine.warn_once("nh", "rocx native: a <NoHydration> is the server's, and a phone has no server render: it is empty here");
            engine.dom.fragment()
        }),
        "listen" => with(|engine| {
            engine.warn_once("listen", "rocx native: <Document>'s and <Window>'s handlers aren't on phones yet: ignored");
            engine.dom.fragment()
        }),
        other => with(|engine| {
            engine.warn_once(&format!("node {other}"), &format!("rocx native: unknown node {other}: ignored"));
            engine.dom.fragment()
        }),
    }
}

fn children(node: &Value) -> impl Iterator<Item = &Value> {
    node.get("c").and_then(Value::as_array).into_iter().flatten()
}

/// An element, its attributes set and its holes and handlers bound (`element`, `bind`).
fn element(node: &Value, owner: Option<u64>, scope: &Scope) -> NodeId {
    let tag = node.get("tag").and_then(Value::as_str).unwrap_or("div");
    let attrs: Vec<&Vec<Value>> = node.get("a").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_array).collect();
    let field = |attr: &Vec<Value>, at: usize| attr.get(at).and_then(Value::as_str).unwrap_or("").to_string();
    let element = with(|engine| {
        let element = engine.dom.element(tag);
        let mut classes = Vec::new();
        for attr in &attrs {
            let kind = field(attr, 0);
            let name = field(attr, 1);
            match kind.as_str() {
                "v" if name == "class" => classes.push(field(attr, 2)),
                "ci" if attr.get(2).and_then(Value::as_bool) == Some(true) => classes.push(name),
                _ => {}
            }
        }
        if !classes.is_empty() {
            engine.dom.set_attr(element, "class", &classes.join(" "));
        }
        for attr in &attrs {
            let kind = field(attr, 0);
            let name = field(attr, 1);
            match kind.as_str() {
                "v" if name != "class" => engine.dom.set_attr(element, &name, &field(attr, 2)),
                "o" if !field(attr, 2).is_empty() => engine.dom.set_attr(element, &name, &field(attr, 2)),
                "f" if attr.get(2).and_then(Value::as_bool) == Some(true) => engine.dom.set_attr(element, &name, ""),
                "sv" if !field(attr, 2).is_empty() => engine.dom.set_style(element, &name, &field(attr, 2)),
                _ => {}
            }
        }
        element
    });
    for attr in &attrs {
        let kind = field(attr, 0);
        let name = field(attr, 1);
        let computed = match kind.as_str() {
            "vo" => Some(CompKind::Attr),
            "fo" => Some(CompKind::Flag),
            "co" => Some(CompKind::Class),
            "oo" => Some(CompKind::Optional),
            "so" => Some(CompKind::Style),
            _ => None,
        };
        if let Some(computed) = computed {
            let runner = kept_box(attr.get(2).and_then(Value::as_u64));
            let comp = with(|engine| engine.new_comp(computed, runner, owner, scope.clone(), Target::Node(element), &name));
            let outcome = run(comp);
            if is_static(comp, outcome) {
                forget(comp, owner);
            }
            continue;
        }
        match kind.as_str() {
            "on" | "onp" | "onk" => {
                let runner = attr.get(2).and_then(Value::as_u64).unwrap_or(0);
                let wanted = attr.get(3).and_then(Value::as_str).map(str::to_string);
                with(|engine| engine.listeners.entry(element).or_default().push(Listener { event: name.clone(), kind: kind.clone(), runner, wanted, scope: scope.clone(), owner }));
            }
            "frame" | "view" | "tr" | "tro" | "k" | "ko" => with(|engine| {
                engine.warn_once(&format!("attr {kind}"), &format!("rocx native: `{kind}` ({}) isn't on phones yet: ignored", attr_name(&kind)));
            }),
            _ => {}
        }
    }
    for child in children(node) {
        let built = build(child, owner, scope);
        with(|engine| engine.dom.append(element, built));
    }
    element
}

fn attr_name(kind: &str) -> &'static str {
    match kind {
        "frame" => "on:frame",
        "view" => "on:viewport",
        "tr" | "tro" => "transition",
        _ => "key",
    }
}

/// A component, run where it is rendered, once, its reads untracked (`component`).
fn component(reference: Option<u64>, owner: Option<u64>, scope: &Scope) -> (Option<u64>, Vec<Value>) {
    let runner = kept_box(reference);
    let (comp, previous, place) = with(|engine| {
        let comp = engine.new_comp(CompKind::Component, runner, owner, scope.clone(), Target::None, "");
        if let Some(made) = engine.comp(comp) {
            made.making = Some(Made::default());
        }
        (comp, engine.current.replace(Current::Comp(comp)), std::mem::take(&mut engine.place))
    });
    let result = roc::run(runner);
    with(|engine| {
        engine.current = previous;
        engine.place = place;
        if let Some(made) = engine.comp(comp) {
            made.made = made.making.take().unwrap_or_default();
        }
    });
    match result {
        Ok(json) => (Some(comp), vec![serde_json::from_str(&json).unwrap_or(Value::Null)]),
        Err(Abort::Wait(_)) => {
            log(Level::Error, "rocx: a component read a value that isn't in yet outside its markup: read it in a hole ({…}), which waits");
            (Some(comp), Vec::new())
        }
        Err(Abort::Failed(why, memo)) => {
            failed(comp, why, memo);
            (Some(comp), Vec::new())
        }
        Err(Abort::Crash(why)) => {
            log(Level::Error, &format!("rocx native: Roc crashed in a component: {why}"));
            failed(comp, format!("crashed: {why}"), None);
            (Some(comp), Vec::new())
        }
    }
}

/// Mounts the app's markup on the screen (`mount`).
pub fn mount() {
    let root = with(|engine| {
        let (range, fragment) = engine.dom.make_range();
        let root = engine.dom.root;
        engine.dom.append(root, fragment);
        engine.new_comp(CompKind::Root, std::ptr::null_mut(), None, Scope::default(), Target::Range(range), "")
    });
    run(root);
}

// ---- Events ----

/// An event on a native view (`id`, the node it shows), given its value (what a field holds now):
/// the handlers of the node and of each element above it, as the DOM bubbles it. A tap on a
/// button in a form (not `type="button"`) submits the form too.
pub fn dispatch(node: NodeId, event: &str, value: &str) {
    if event == "input" {
        with(|engine| {
            engine.values.insert(node, value.to_string());
        });
    }
    let path = with(|engine| {
        let mut path = Vec::new();
        let mut at = Some(node);
        while let Some(node) = at {
            path.push(node);
            at = engine.dom.nodes.get(node).and_then(|node| node.parent);
        }
        path
    });
    for at in &path {
        let listeners: Vec<(u64, Scope, Option<u64>, Option<String>, String)> = with(|engine| {
            engine.listeners.get(at).map(|listeners| listeners.iter().filter(|listener| listener.event == event).map(|listener| (listener.runner, listener.scope.clone(), listener.owner, listener.wanted.clone(), listener.kind.clone())).collect()).unwrap_or_default()
        });
        for (runner, scope, owner, wanted, kind) in listeners {
            if kind != "onk" && wanted.is_some() && wanted.as_deref() != Some(value) {
                continue;
            }
            if with(|engine| engine.kept.contains_key(&runner)) {
                handle(runner, value.to_string(), scope, owner, None, None);
            }
        }
    }
    if event == "click" {
        let form = with(|engine| {
            if engine.dom.tag(node) != Some("button") || engine.dom.attr(node, "type").is_some_and(|kind| kind.eq_ignore_ascii_case("button")) {
                return None;
            }
            path.iter().copied().find(|&at| engine.dom.tag(at) == Some("form"))
        });
        if let Some(form) = form {
            dispatch(form, "submit", "");
            submitted(form);
        }
    }
}

// ---- Requests ----

/// An HTTP request for the running computation or handler (`fetchFor`): its answer, as
/// `{"status":…,"body":…}`, from its calls if in, or asked for now (and it waits).
pub fn fetch_for(method: &str, url: &str, headers: &str, body: &str) -> Result<String, Abort> {
    with(|engine| {
        let tracked = !engine.making().is_some_and(|making| making.untracked > 0);
        if tracked {
            engine.touch(false);
        }
        let key = format!("{method} {url}\n{body}");
        let current = engine.current;
        let known = match current {
            Some(Current::Comp(id)) => engine.comps.get(&id).and_then(|comp| comp.calls.get(&key).copied()),
            Some(Current::Handler(id)) => engine.handlers.get(&id).and_then(|handler| handler.calls.get(&key).copied()),
            Some(Current::Probe(id)) => engine.probes.get(&id).and_then(|probe| probe.calls.get(&key).copied()),
            None => None,
        };
        let request = match known {
            Some(request) => request,
            None => {
                let request = engine.id();
                engine.requests.insert(request, Answer::Pending);
                engine.asked.insert(request, Asked::Read);
                let lines: Vec<(String, String)> = headers.lines().filter_map(|line| line.split_once(": ")).map(|(name, value)| (name.to_string(), value.to_string())).collect();
                let full = engine.under(url);
                engine.outbox.push((request, method.to_string(), full, lines, if method == "GET" || method == "HEAD" { String::new() } else { body.to_string() }));
                match current {
                    Some(Current::Comp(id)) => {
                        if let Some(comp) = engine.comp(id) {
                            comp.calls.insert(key.clone(), request);
                        }
                    }
                    Some(Current::Handler(id)) => {
                        if let Some(handler) = engine.handlers.get_mut(&id) {
                            handler.calls.insert(key.clone(), request);
                        }
                    }
                    Some(Current::Probe(id)) => {
                        if let Some(probe) = engine.probes.get_mut(&id) {
                            probe.calls.insert(key.clone(), request);
                        }
                    }
                    None => {}
                }
                request
            }
        };
        if let Some(Current::Comp(id)) = current
            && let Some(comp) = engine.comps.get_mut(&id)
        {
            comp.used.insert(key.clone());
            const READERS: [CompKind; 10] = [CompKind::Memo, CompKind::Text, CompKind::Attr, CompKind::Flag, CompKind::Class, CompKind::Optional, CompKind::Style, CompKind::Html, CompKind::Show, CompKind::For];
            if method == "GET" && tracked && (READERS.contains(&comp.kind) || comp.kind == CompKind::Reaction) {
                engine.readers.insert(id);
            }
        }
        match engine.requests.get(&request).cloned().unwrap_or(Answer::Failed(format!("{method} {url}: lost"))) {
            Answer::Pending => Err(Abort::Wait(Wait::Request(request))),
            Answer::Failed(why) => Err(Abort::Failed(why, None)),
            Answer::Ok(json) => Ok(json),
        }
    })
}

/// Sends the requests made since the last time (`fetch_for` notes them while it holds the engine).
pub fn send_requests() {
    let outbox = with(|engine| std::mem::take(&mut engine.outbox));
    for (id, method, url, headers, body) in outbox {
        crate::http::send(id, method, url, headers, body);
    }
}

/// A request's answer, in (on the main thread): what waited for it runs again.
pub fn answered(id: u64, result: Result<(u16, Vec<(String, String)>, String), String>) {
    let asked = with(|engine| engine.asked.remove(&id));
    match asked {
        Some(Asked::Submission { key, id: entry }) => {
            match result {
                Ok((status, headers, body)) => {
                    if headers.iter().any(|(name, _)| name.eq_ignore_ascii_case("x-rocx-redirect")) {
                        log(Level::Warn, "rocx native: a submission was answered with a redirect: pages aren't navigated on phones yet");
                    }
                    if status == 200 {
                        revalidate(key, entry, status, body);
                    } else {
                        submission_done(&key, entry, status, body);
                    }
                }
                Err(why) => submission_done(&key, entry, 0, why),
            }
        }
        _ => {
            let waiters = with(|engine| {
                let answer = match result {
                    Ok((status, _, body)) => Answer::Ok(serde_json::json!({ "status": status, "body": body }).to_string()),
                    Err(why) => Answer::Failed(why),
                };
                engine.requests.insert(id, answer);
                engine.waiters.remove(&Wait::Request(id)).unwrap_or_default()
            });
            wake(waiters);
        }
    }
}

// ---- Submissions ----

fn submission_json(entry: &Submission, listed: bool) -> String {
    let mut value = serde_json::json!({ "state": entry.state, "input": entry.input, "json": entry.json, "status": entry.status, "body": entry.body });
    if listed {
        value["id"] = serde_json::json!(entry.id);
    }
    value.to_string()
}

pub fn action(url: String) {
    let refused = with(|engine| {
        engine.touch(false);
        *engine.actions.entry(url.clone()).or_default() += 1;
        engine.push_cleanup(Cleanup::Action(url.clone())).is_err()
    });
    let _ = refused;
}

pub fn submission(url: String, all: bool) -> String {
    with(|engine| {
        engine.touch(true);
        engine.track(Source::Submission(url.clone()));
        let source = engine.submissions.entry(url).or_default();
        if all {
            if source.list.is_empty() && !source.cleared {
                return String::new();
            }
            let list: Vec<String> = source.list.iter().map(|entry| submission_json(entry, true)).collect();
            return format!("{{\"cleared\":{},\"list\":[{}]}}", source.cleared, list.join(","));
        }
        if source.cleared {
            return submission_json(&Submission { id: 0, state: "cleared", input: String::new(), json: false, status: 0, body: String::new() }, false);
        }
        source.list.last().map(|entry| submission_json(entry, false)).unwrap_or_default()
    })
}

pub fn submission_clear(url: String) {
    later(Write::Cleared(url));
}

pub fn submission_drop(url: String, id: u64) {
    later(Write::Dropped(url, id));
}

/// An action (`use_action!`), from a handler: sent once it is done.
pub fn submit(method: String, url: String, body: String, input: String) -> Result<(), String> {
    with(|engine| match engine.handler() {
        Some(handler) => {
            handler.writes.push(Write::Submit { method, url, body, input });
            Ok(())
        }
        None => Err(format!("use_action!({url})'s function sends from a handler (an event, a timer, an effect's apply), not while computing")),
    })
}

fn send_action(method: &str, url: &str, body: &str, input: &str) {
    let headers = if method == "GET" || method == "HEAD" { Vec::new() } else { vec![("content-type".to_string(), "application/json".to_string())] };
    send_submission(url, method, headers, body, input, true);
}

/// A form submitted: sent if it posts to an endpoint a component reads the submission of
/// (`submitted`), its named fields URL-encoded.
fn submitted(form: NodeId) {
    let found = with(|engine| {
        let method = engine.dom.attr(form, "method").unwrap_or("").to_ascii_lowercase();
        let action = engine.dom.attr(form, "action").unwrap_or("").to_string();
        if method != "post" || !engine.actions.contains_key(&action) {
            return None;
        }
        let mut fields = Vec::new();
        let mut stack = vec![form];
        while let Some(node) = stack.pop() {
            let tag = engine.dom.tag(node).unwrap_or("");
            if matches!(tag, "input" | "textarea" | "select")
                && let Some(name) = engine.dom.attr(node, "name")
            {
                let kind = engine.dom.attr(node, "type").unwrap_or("").to_ascii_lowercase();
                if !(matches!(kind.as_str(), "checkbox" | "radio") && engine.dom.attr(node, "checked").is_none()) {
                    let value = engine.values.get(&node).cloned().or_else(|| engine.dom.attr(node, "value").map(str::to_string)).unwrap_or_else(|| if kind == "checkbox" { "on".into() } else { String::new() });
                    fields.push(format!("{}={}", encode(name), encode(&value)));
                }
            }
            for child in engine.dom.nodes[node].children.iter().rev() {
                stack.push(*child);
            }
        }
        Some((action, fields.join("&")))
    });
    if let Some((action, fields)) = found {
        send_submission(&action, "POST", vec![("content-type".into(), "application/x-www-form-urlencoded".into())], &fields, &fields, false);
    }
}

fn encode(text: &str) -> String {
    let mut out = String::new();
    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'*' => out.push(byte as char),
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// Sends a submission (`submit`): a new one in its endpoint's list, pending until it is answered.
fn send_submission(key: &str, method: &str, mut headers: Vec<(String, String)>, body: &str, input: &str, json: bool) {
    with(|engine| {
        let entry = engine.id();
        let source = engine.submissions.entry(key.to_string()).or_default();
        source.list.push(Submission { id: entry, state: "pending", input: input.to_string(), json, status: 0, body: String::new() });
        source.cleared = false;
        engine.submissions_changed(key);
        headers.push(("accept".into(), "application/json".into()));
        headers.push(("x-rocx-submission".into(), "1".into()));
        let request = engine.id();
        engine.asked.insert(request, Asked::Submission { key: key.to_string(), id: entry });
        let full = engine.under(key);
        engine.outbox.push((request, method.to_string(), full, headers, if method == "GET" || method == "HEAD" { String::new() } else { body.to_string() }));
    });
}

fn submission_done(key: &str, id: u64, status: u16, body: String) {
    with(|engine| {
        let Some(source) = engine.submissions.get_mut(key) else { return };
        if let Some(entry) = source.list.iter_mut().find(|entry| entry.id == id) {
            entry.state = "done";
            entry.status = status;
            entry.body = body;
            engine.submissions_changed(key);
        }
    });
}

/// Reads the page's reads again, then the submission is done (`revalidate`).
fn revalidate(key: String, entry: u64, status: u16, body: String) {
    let targets = with(|engine| {
        let targets: Vec<u64> = engine.readers.iter().copied().filter(|id| engine.comps.get(id).is_some_and(|comp| !comp.disposed && comp.calls.keys().any(|key| key.starts_with("GET ")))).collect();
        if targets.is_empty() {
            return targets;
        }
        let at = engine.id();
        engine.revalidations.insert(at, Revalidation { left: targets.len(), key: key.clone(), id: entry, status, body: body.clone() });
        for target in &targets {
            if let Some(comp) = engine.comp(*target) {
                comp.revalidating.push(at);
            }
        }
        targets
    });
    if targets.is_empty() {
        return submission_done(&key, entry, status, body);
    }
    for target in targets {
        refresh(target);
    }
}

fn revalidated(id: u64) {
    let done = with(|engine| {
        let waiting = engine.comps.get_mut(&id).map(|comp| std::mem::take(&mut comp.revalidating)).unwrap_or_default();
        let mut done = Vec::new();
        for at in waiting {
            if let Some(revalidation) = engine.revalidations.get_mut(&at) {
                revalidation.left -= 1;
                if revalidation.left == 0 {
                    done.push(engine.revalidations.remove(&at).expect("it is there"));
                }
            }
        }
        done
    });
    for revalidation in done {
        submission_done(&revalidation.key, revalidation.id, revalidation.status, revalidation.body);
    }
}

// ---- Timers ----

fn stop_timer(engine: &mut Engine, id: u64) {
    if let Some(timer) = engine.timers.remove(&id) {
        timer.stop.store(true, std::sync::atomic::Ordering::Relaxed);
    }
}

/// A component's timer (`startTimer`): its handler runs after `ms`, or every `ms`, until it is
/// cleared or what started it is cleaned up.
pub fn start_timer(ms: u64, repeat: bool, callable: Callable) -> u64 {
    let (id, stop) = with(|engine| {
        engine.touch(false);
        let id = engine.keep(callable);
        if engine.push_cleanup(Cleanup::Timer(id)).is_err() {
            let owner = engine.owner();
            if let Some(owner) = owner.and_then(|owner| engine.comp(owner)) {
                owner.made.kept.push(id);
            }
        }
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let (scope, owner) = (engine.current_scope(), engine.owner());
        engine.timers.insert(id, Timer { repeat, scope, owner, stop: stop.clone() });
        (id, stop)
    });
    crate::timer(id, ms, repeat, stop);
    id
}

/// A timer's time came (on the main thread).
pub fn fired(id: u64) {
    let found = with(|engine| {
        if !engine.kept.contains_key(&id) {
            return None;
        }
        let timer = engine.timers.get(&id)?;
        let found = (timer.repeat, timer.scope.clone(), timer.owner);
        if !timer.repeat {
            engine.timers.remove(&id);
        }
        Some(found)
    });
    let Some((repeat, scope, owner)) = found else { return };
    handle(id, String::new(), scope, owner, None, if repeat { None } else { Some(id) });
}

pub fn clear_timer(id: u64) {
    with(|engine| {
        stop_timer(engine, id);
        if engine.handler().is_some() {
            engine.tasks.push_back(Task::ReleaseKept(id));
        } else {
            engine.release_kept(id);
        }
    });
}

// ---- Titles ----

/// A `<Title>`'s hole says the title (`js_title`): the last one rendered that is still there is
/// the screen's.
pub fn title(text: String) -> Result<(), String> {
    with(|engine| {
        engine.touch(false);
        let Some(Current::Comp(owner)) = engine.current else { return Err("a <Title> says the title in its own hole: Html.document_title is rocx's to write".into()) };
        if engine.push_cleanup(Cleanup::Title(owner)).is_err() {
            return Err("a <Title> says the title in its own hole: Html.document_title is rocx's to write".into());
        }
        let seq = match engine.comps.get_mut(&owner) {
            Some(comp) => {
                if comp.title_seq == 0 {
                    engine.title_seqs += 1;
                    comp.title_seq = engine.title_seqs;
                }
                comp.title_seq
            }
            None => 0,
        };
        engine.titles.insert(owner, (seq, text));
        show_title(engine);
        Ok(())
    })
}

fn show_title(engine: &mut Engine) {
    engine.title = engine.titles.values().max_by_key(|(seq, _)| *seq).map(|(_, title)| title.clone());
}

// ---- What the hosted functions do ----

pub fn keep(callable: Callable) -> u64 {
    with(|engine| {
        let id = engine.keep(callable);
        if let Some(making) = engine.making() {
            making.kept.push(id);
        }
        id
    })
}

pub fn signal_new(value: Callable) -> u64 {
    with(|engine| {
        engine.touch(false);
        let id = engine.id();
        engine.signals.insert(id, value);
        if let Some(making) = engine.making() {
            making.signals.push(id);
        }
        id
    })
}

pub fn signal_get(id: u64) -> Result<Callable, String> {
    with(|engine| {
        let value = engine.signals.get(&id).copied().ok_or_else(|| "rocx: a signal was read after the part that made it went away".to_string())?;
        engine.track(Source::Signal(id));
        Ok(roc::retain(value))
    })
}

pub fn signal_set(id: u64, value: Callable) -> Result<(), Callable> {
    with(|engine| match engine.handler() {
        Some(handler) => {
            handler.writes.push(Write::Signal(id, value));
            Ok(())
        }
        None => Err(value),
    })
}

pub fn memo_new(runner: Callable) -> u64 {
    let id = with(|engine| {
        engine.touch(false);
        let owner = match engine.current {
            Some(Current::Comp(id)) => Some(id),
            _ => None,
        };
        let scope = engine.current_scope();
        engine.new_comp(CompKind::Memo, runner, owner, scope, Target::None, "")
    });
    run(id);
    id
}

pub fn memo_done(value: Callable) {
    with(|engine| {
        if let Some(Current::Comp(id)) = engine.current
            && let Some(comp) = engine.comps.get_mut(&id)
        {
            let old = std::mem::replace(&mut comp.next, value);
            roc::release(old);
            return;
        }
        roc::release(value);
    });
}

pub fn memo_get(id: u64) -> Result<Callable, Abort> {
    with(|engine| {
        if let Some(Current::Probe(probe)) = engine.current
            && let Some(probe) = engine.probes.get_mut(&probe)
            && !probe.memos.contains(&id)
        {
            probe.memos.push(id);
        }
        engine.track(Source::Memo(id));
        let Some(memo) = engine.comps.get(&id) else { return Err(Abort::Failed("rocx: a memo was read after the part that made it went away".into(), None)) };
        if memo.state == MemoState::Failed {
            return Err(Abort::Failed(memo.error.clone(), Some(id)));
        }
        if !memo.value.is_null() {
            return Ok(roc::retain(memo.value));
        }
        Err(Abort::Wait(Wait::Memo(id)))
    })
}

pub fn refresh_probe(callable: Callable) {
    let memos = probe(callable);
    roc::release(callable);
    for memo in memos {
        later(Write::Refresh(memo));
    }
}

pub fn is_pending(callable: Callable) -> bool {
    with(|engine| engine.touch(true));
    let memos = probe(callable);
    let answer = pending(&memos);
    with(|engine| {
        let tracked = engine.making().is_some_and(|making| making.untracked == 0);
        if !tracked {
            roc::release(callable);
            return answer;
        }
        let id = engine.keep(callable);
        if let Some(making) = engine.making() {
            making.kept.push(id);
            making.queries.push(Query { probe: id, memos: memos.clone(), answer });
        }
        for memo in memos {
            engine.track(Source::Pending(memo));
        }
        answer
    })
}

pub fn event_value() -> String {
    with(|engine| engine.handler().map(|handler| handler.event.clone()).unwrap_or_default())
}

pub fn boundary() -> u64 {
    with(|engine| match engine.current {
        Some(Current::Comp(id)) => engine.comps.get(&id).and_then(|comp| comp.boundary).unwrap_or(0),
        _ => 0,
    })
}

pub fn problem() -> String {
    with(|engine| {
        let boundary = match engine.current {
            Some(Current::Comp(id)) => engine.comps.get(&id).and_then(|comp| comp.boundary),
            _ => None,
        };
        boundary.and_then(|boundary| engine.boundaries.get(&boundary)).and_then(|errored| errored.failed.clone()).unwrap_or_default()
    })
}

pub fn retry(id: u64) {
    later(Write::Retry(id));
}

pub fn for_new() -> u64 {
    with(|engine| {
        let id = engine.id();
        engine.lists.insert(id, List::default());
        id
    })
}

pub fn row_index(list: u64, key: String) -> u64 {
    with(|engine| {
        let index = engine.lists.get(&list).and_then(|list| list.indexes.get(&key).copied()).unwrap_or(0);
        engine.track(Source::Index(list, key));
        index
    })
}

pub fn row_set(list: u64, key: String, value: Callable) {
    with(|engine| {
        let Some(items) = engine.lists.get_mut(&list).map(|list| &mut list.items) else {
            roc::release(value);
            return;
        };
        match items.insert(key.clone(), value) {
            None => {}
            Some(old) => {
                roc::release(old);
                engine.schedule_observers(&Source::Item(list, key));
            }
        }
    });
}

pub fn row_get(list: u64, key: String) -> Result<Callable, String> {
    with(|engine| {
        let item = engine.lists.get(&list).and_then(|list| list.items.get(&key).copied()).ok_or_else(|| format!("rocx: no row {key} in its <For>"))?;
        engine.track(Source::Item(list, key));
        Ok(roc::retain(item))
    })
}

pub fn context_value(value: Callable) -> u64 {
    keep(value)
}

pub fn context_find(name: &str) -> u64 {
    with(|engine| engine.current_scope().contexts.get(name).copied().unwrap_or(0))
}

pub fn context_get(id: u64) -> Result<Callable, String> {
    with(|engine| engine.kept.get(&id).copied().map(roc::retain).ok_or_else(|| "rocx: a context's value was read after what provided it went".to_string()))
}

pub fn location() -> String {
    with(|engine| engine.path.clone())
}

pub fn browser_call(name: String, arg: String) -> Result<(), String> {
    with(|engine| match engine.handler() {
        Some(handler) => {
            handler.writes.push(Write::Effect(name, arg));
            Ok(())
        }
        None => Err(format!("Browser.call!(\"{name}\") is a handler's: call it from an event, a frame or a timer, not while computing")),
    })
}

pub fn effect_new(runner: Callable) -> Result<(), String> {
    let id = with(|engine| {
        engine.touch(false);
        let owner = match engine.current {
            Some(Current::Comp(id)) if engine.comps.get(&id).is_some_and(|comp| comp.making.is_some()) => id,
            _ => return Err("create_effect! is made in a component or a computation, not in a handler or an effect's apply: nothing would own it".to_string()),
        };
        let scope = engine.current_scope();
        Ok(engine.new_comp(CompKind::Reaction, runner, Some(owner), scope, Target::None, ""))
    });
    match id {
        Ok(id) => {
            run(id);
            Ok(())
        }
        Err(why) => {
            roc::release(runner);
            Err(why)
        }
    }
}

pub fn effect_options(render: bool, error_box: u64) {
    with(|engine| {
        if let Some(Current::Comp(id)) = engine.current
            && let Some(comp) = engine.comps.get_mut(&id)
            && comp.kind == CompKind::Reaction
        {
            comp.render = render;
            comp.on_error = error_box;
        }
    });
}

pub fn cleanup(runner: Callable) -> Result<(), String> {
    let refused = with(|engine| {
        engine.touch(false);
        let id = engine.keep(runner);
        match engine.push_cleanup(Cleanup::Kept(id)) {
            Ok(()) => false,
            Err(_) => {
                engine.kept.remove(&id);
                true
            }
        }
    });
    if refused {
        roc::release(runner);
        return Err("on_cleanup! is called in a component, a computation or an effect: in a handler, nothing would ever run it".into());
    }
    Ok(())
}

pub fn untrack(on: bool) {
    with(|engine| {
        if let Some(making) = engine.making() {
            making.untracked = if on { making.untracked + 1 } else { making.untracked.saturating_sub(1) };
        }
    });
}

pub fn read_at(place: String) -> String {
    with(|engine| std::mem::replace(&mut engine.place, place))
}

pub fn warn(key: &str, message: &str) {
    with(|engine| engine.warn_once(key, message));
}
