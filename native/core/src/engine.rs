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
//! Navigation is nav.rs's (D-138) and live updates live.rs's (D-140), each reaching in through the
//! `pub(crate)` functions here. Not here yet (spike/native-apps/README.md): hydration (a phone mounts
//! from nothing), transitions and glides, drag and drop, `on:frame`, `on:viewport`,
//! `<Document>`/`<Window>` handlers, keyed elements.

use crate::abi::RocErasedCallable as Callable;
use crate::dom::{Dom, NodeId, Range};
use crate::roc::{self, Abort, Wait};
use crate::{Level, log};
use crate::json::{self, Value};
use std::cell::RefCell;
use crate::fx::{HashMap, HashSet};
use std::collections::{BTreeSet, VecDeque};
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
    /// `create_selector!`: its run answers its source's key, kept in `holds`.
    Selector,
    Reaction,
    Component,
    Boundary,
}

/// What a computation reads: a signal, a memo, a memo's pending state (`is_pending!`), a row's
/// index or item, an endpoint's submissions, whether a selector's key is one key.
#[derive(Clone, PartialEq, Eq, Hash, Debug)]
pub enum Source {
    Signal(u64),
    Memo(u64),
    Pending(u64),
    Index(u64, String),
    Item(u64, String),
    Submission(String),
    Selector(u64, String),
    /// Where the app is (`Router.location!`, D-138): a navigation runs again what read it.
    Location,
    /// Whether a navigation is on its way (`Router.is_routing!`).
    Routing,
}

/// The contexts provided above, and the boundaries around: what a computation is made in.
#[derive(Clone, Default)]
pub struct Scope {
    contexts: Rc<HashMap<String, u64>>,
    loading: Option<u64>,
    errored: Option<u64>,
    /// The level it is in (D-040: a route's keyed part, made anew when a read of the location in it
    /// won't follow a navigation: `nav::read_once`).
    level: Option<u64>,
}

/// What runs when an owner runs again or goes: a box Roc kept (`on_cleanup!`), or the engine's own.
enum Cleanup {
    Kept(u64),
    Timer(u64),
    Title(u64),
    Action(String),
    /// A `use_before_leave!` listener (D-138), gone with its owner.
    Leave(u64),
    /// A `listen!`'s stream or a channel's subscriber (D-140), stopped with its owner.
    Live(u64),
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
    /// Its run's value is the one it had (a store's selection, D-053): its readers aren't told.
    same: bool,
    // A <Show>'s and a <For>'s.
    node: Option<Rc<Value>>,
    /// What its condition answered last (`true`, `false`, or a keyed one's case, `"#…"`).
    holds: Option<String>,
    part: Option<u64>,
    list: Option<u64>,
    fallback_range: Option<Range>,
    settled: bool,
    // A markup hole's first run (`peek`), before its place is known.
    peek: bool,
    peeked: Option<Vec<Value>>,
    // A D-070 hole while it shows text alone: its target a text node, patched as a text hole's.
    hole_text: bool,
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
    /// What made it (`owner`), and whether it is an `if`'s or `match`'s part picking its branch.
    owner: Option<u64>,
    choosing: bool,
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
            calls: HashMap::default(),
            used: HashSet::default(),
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
            same: false,
            node: None,
            holds: None,
            part: None,
            list: None,
            fallback_range: None,
            settled: false,
            peek: false,
            hole_text: false,
            peeked: None,
            cleanups: Vec::new(),
            apply: 0,
            render: false,
            on_error: 0,
            failure: None,
            boundary: None,
            revalidating: Vec::new(),
            title_seq: 0,
            owner: None,
            choosing: false,
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
    /// How many `Solid.update!`s it is inside now, whose reads of signals give its writes (D-094).
    own: u32,
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
    /// `create_optimistic!`'s write (D-054): held by the transition the handler's writes open.
    Optimistic(u64, Callable),
    /// `Router.revalidate!` (D-054): the reads of a GET whose URL is one of these, read again.
    Revalidate(Vec<String>),
    /// `retry!` (D-054): a submission (its endpoint, its id or 0 for the latest) sent again.
    Retried(String, u64),
    /// `Router.navigate!` (D-040, D-138): once the handler is done.
    Navigate { to: String, replace: bool, scroll: bool },
    /// `Leave.retry!`: a leave let go after all.
    LeaveRetry(u64, bool),
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
    /// What was sent, for `retry!`.
    sent: Sent,
    /// The transition it joined (optimistic writes, D-054): it ends once its submissions are done.
    transition: Option<u64>,
    /// A form nothing on the page reads, sent as the browser would post it (D-118), and the form it
    /// came from (emptied once it succeeds, D-122; its failure shown around it, D-121).
    plain: bool,
    form: Option<NodeId>,
    /// How many navigations were committed when it was sent: its redirect is followed only if none
    /// was since (D-138).
    navigations: u64,
}

#[derive(Clone, Default)]
struct Sent {
    method: String,
    /// Where it goes, when not its endpoint's path (a form's URL with fields, `with_fields`).
    url: Option<String>,
    headers: Vec<(String, String)>,
    body: String,
}

/// A handler's optimistic writes (`create_optimistic!`, D-054), held until the submissions sent with
/// them are done, or, with none, until the flush is over (runtime.js's `openTransition`).
#[derive(Default)]
struct Transition {
    pending: usize,
    sent: bool,
    signals: Vec<u64>,
}

/// A signal's optimistic writes, each with its transition, and its value before them (`hold`).
/// While held, the signal shows the latest write.
struct Held {
    base: Callable,
    writes: Vec<(Callable, u64)>,
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
    /// A stylesheet a `<link rel="stylesheet">` names (the app's, a file since D-040).
    Sheet(String),
    /// A navigation's document (D-138: `nav::answered`).
    Navigation(u64),
    /// What the app said on its channels, and asked of them (D-140: `live::sent`): the items, and
    /// the stream it named.
    LiveSend(Vec<(String, Option<u64>)>, Option<u64>),
}

/// A linked stylesheet: on its way, in (its text), or not to be had.
#[derive(Clone)]
pub enum Sheet {
    Loading,
    Loaded(String),
    Failed,
}

/// A submission's result reading the page's reads again: how many are left, and the submission.
struct Revalidation {
    left: usize,
    /// What is done once the reads are in.
    then: Finish,
}

/// What a revalidation does once its reads are in (`revalidate`'s `done`).
#[derive(Clone)]
enum Finish {
    /// `Router.revalidate!`'s: nothing.
    Nothing,
    /// A submission's result: it is done, its form emptied (D-122).
    Result { key: String, entry: u64, status: u16, body: String },
    /// A submission whose answer was a redirect, followed (D-138): done with no result; a plain
    /// form's (D-118) leaves the list, its flash saying what happened.
    Redirected { key: String, entry: u64, plain: bool },
}

/// What happens later, after what is running now (runtime.js's microtasks).
enum Task {
    Fallback(u64),
    ReleaseKept(u64),
    /// A handler whose answer is in, run again.
    Wake(u64),
    /// `Router.navigate!`, once the handler that called it is done (D-138).
    Navigate { to: String, replace: bool, scroll: bool },
    /// `Leave.retry!`, likewise.
    LeaveRetry(u64, bool),
}

pub struct Engine {
    ids: u64,
    pub dom: Dom,
    /// What the app's server is: requests to a path go there (`http://10.0.2.2:8080`).
    pub origin: String,
    /// Where the app is (`Router.location!`): its path and query, as a navigation committed it.
    pub path: String,
    /// Navigation (D-138): the route table, the history, the document being committed.
    pub nav: crate::nav::Nav,
    /// The root's computation (`mount`).
    root: Option<u64>,
    /// Live updates (D-140): `listen!`'s streams, the channels and their stream.
    pub live: crate::live::Live,
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
    /// What an element's computed `class` (`class={…}`) last was: a new one keeps the `class:name`s
    /// that are on beside it (`whole_class`).
    classes: HashMap<NodeId, String>,
    timers: HashMap<u64, Timer>,
    titles: HashMap<u64, (u64, String)>,
    title_seqs: u64,
    pub title: Option<String>,
    calling: Vec<(String, String)>,
    place: String,
    actions: HashMap<String, u32>,
    /// The paths of the app's endpoints that take a POST (the route table's, D-095), whose forms
    /// are sent whoever asks for their submissions.
    posts: Vec<String>,
    submissions: HashMap<String, Submissions>,
    revalidations: HashMap<u64, Revalidation>,
    /// The transition a handler's optimistic writes opened, open until the flush is over (a
    /// submission sent meanwhile joins it); the transitions not over; each held signal's writes.
    transition: Option<u64>,
    transitions: HashMap<u64, Transition>,
    held: HashMap<u64, Held>,
    /// The stylesheets `<link>`s name, by their `href`.
    sheets: HashMap<String, Sheet>,
    warned: HashSet<String>,
    /// Templates (D-084): each site's id, and each id's skeleton once it is here (`None` before,
    /// and for id 0, which says "no template").
    template_ids: HashMap<String, usize>,
    templates: Vec<Option<Rc<Template>>>,
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
        crate::live::stop_all(&engine.live);
    }
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
            nav: crate::nav::Nav::default(),
            root: None,
            live: crate::live::Live::default(),
            kept: HashMap::default(),
            signals: HashMap::default(),
            comps: HashMap::default(),
            observers: HashMap::default(),
            lists: HashMap::default(),
            boundaries: HashMap::default(),
            loadings: HashMap::default(),
            handlers: HashMap::default(),
            probes: HashMap::default(),
            current: None,
            dirty: BTreeSet::new(),
            due: BTreeSet::new(),
            tasks: VecDeque::new(),
            waiters: HashMap::default(),
            requests: HashMap::default(),
            asked: HashMap::default(),
            readers: HashSet::default(),
            listeners: HashMap::default(),
            values: HashMap::default(),
            classes: HashMap::default(),
            timers: HashMap::default(),
            titles: HashMap::default(),
            title_seqs: 0,
            title: None,
            calling: Vec::new(),
            place: String::new(),
            actions: HashMap::default(),
            posts: Vec::new(),
            submissions: HashMap::default(),
            revalidations: HashMap::default(),
            transition: None,
            transitions: HashMap::default(),
            held: HashMap::default(),
            sheets: HashMap::default(),
            warned: HashSet::default(),
            template_ids: HashMap::default(),
            templates: vec![None],
            outbox: Vec::new(),
        })
    });
}

impl Engine {
    fn id(&mut self) -> u64 {
        self.ids += 1;
        self.ids
    }

    pub(crate) fn next_id(&mut self) -> u64 {
        self.id()
    }

    /// A request of the host's own (a navigation's document, a stream's), sent once the engine is
    /// let go of; its answer goes where `asked` says (`answered`).
    pub(crate) fn ask(&mut self, asked: Asked, method: &str, url: String, headers: Vec<(String, String)>, body: String) {
        let request = self.id();
        self.asked.insert(request, asked);
        self.outbox.push((request, method.to_string(), url, headers, body));
    }

    /// Answers no read holds any more, let go of (a computation gone, a call it no longer makes, a
    /// handler done): a page's answers don't outlive it (D-138).
    fn forget_requests(&mut self, requests: &[u64]) {
        for request in requests {
            self.requests.remove(request);
        }
    }

    /// A handler done: taken out, its requests' answers let go of.
    fn end_handler(&mut self, id: u64) -> Option<Handler> {
        let handler = self.handlers.remove(&id)?;
        let requests: Vec<u64> = handler.calls.values().copied().collect();
        self.forget_requests(&requests);
        Some(handler)
    }

    /// How many answers the engine keeps now (the Mac runner's `where`).
    pub fn answers_kept(&self) -> usize {
        self.requests.len()
    }

    pub(crate) fn has_kept(&self, id: u64) -> bool {
        self.kept.contains_key(&id)
    }

    /// A path the app gives, as the phone asks for it (`under`): the server's.
    pub(crate) fn full_url(&self, url: &str) -> String {
        self.under(url)
    }

    /// Whether an element has a handler for `event` (a view to make tappable, D-138).
    pub fn listens(&self, node: NodeId, event: &str) -> bool {
        self.listeners.get(&node).is_some_and(|listeners| listeners.iter().any(|listener| listener.event == event))
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
        let mut comp = Comp::new(kind, runner, scope, target, name);
        comp.owner = owner;
        self.comps.insert(id, comp);
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
    /// A stylesheet a `<link>` names: asked of the server the first time (as a browser fetches
    /// one), its text once it is in.
    pub fn sheet(&mut self, href: &str) -> Sheet {
        if let Some(sheet) = self.sheets.get(href) {
            return sheet.clone();
        }
        self.sheets.insert(href.to_string(), Sheet::Loading);
        let request = self.id();
        self.asked.insert(request, Asked::Sheet(href.to_string()));
        let full = self.under(href);
        self.outbox.push((request, "GET".into(), full, vec![("accept".into(), "text/css".into())], String::new()));
        Sheet::Loading
    }

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

    /// The open transition, if any, joined by a submission being sent: it waits for its answer.
    fn join_transition(&mut self) -> Option<u64> {
        let id = self.transition?;
        let open = self.transitions.get_mut(&id)?;
        open.pending += 1;
        open.sent = true;
        Some(id)
    }

    /// A submission's request, sent once the engine is let go of (`send`).
    fn send(&mut self, key: &str, entry: u64, sent: Sent) {
        let request = self.id();
        self.asked.insert(request, Asked::Submission { key: key.to_string(), id: entry });
        let full = self.under(sent.url.as_deref().unwrap_or(key));
        self.outbox.push((request, sent.method, full, sent.headers, sent.body));
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
        comp.used = HashSet::default();
        Some(engine.current.replace(Current::Comp(id)))
    })?;
    let result = if kind == CompKind::Root { roc::mount() } else { roc::run(runner) };
    with(|engine| engine.current = previous);
    // A run that waits or fails: its frame, reclaimed once what it made is let go of (a crash's
    // isn't, as the browser's isn't).
    let mut unwound = None;
    let (outcome, out, failure) = match result {
        Ok(out) => (Outcome::Ok, Some(out), None),
        Err((Abort::Wait(wait), frame)) => {
            with(|engine| engine.waiters.entry(wait).or_default().push(Waiter::Comp(id)));
            unwound = Some(frame);
            (Outcome::Pending, None, None)
        }
        Err((Abort::Failed(why, memo), frame)) => {
            unwound = Some(frame);
            (Outcome::Failed, None, Some((why, memo)))
        }
        Err((Abort::Crash(why), _)) => {
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
            let dropped: Vec<u64> = comp.calls.iter().filter(|(key, _)| !used.contains(*key)).map(|(_, &request)| request).collect();
            comp.calls.retain(|key, _| used.contains(key));
            engine.forget_requests(&dropped);
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
        if let Some(frame) = unwound {
            frame.reclaim();
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
        engine.probes.insert(id, Probe { memos: Vec::new(), calls: HashMap::default() });
        (id, engine.current.replace(Current::Probe(id)))
    });
    let result = roc::run(callable);
    match result {
        Err((Abort::Crash(why), _)) => log(Level::Error, &format!("rocx native: Roc crashed in a probe: {why}")),
        Err((_, frame)) => frame.reclaim(),
        Ok(_) => {}
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
                // A store's selection whose part is the one it had, an answer it had (D-053), keeps
                // quiet: its readers aren't told. It keeps the newest value all the same.
                let quiet = comp.same && comp.state == MemoState::Ok && !comp.value.is_null();
                comp.same = false;
                let old = std::mem::replace(&mut comp.value, std::ptr::null_mut());
                roc::release(old);
                comp.value = std::mem::replace(&mut comp.next, std::ptr::null_mut());
                comp.state = MemoState::Ok;
                if !quiet {
                    engine.schedule_observers(&Source::Memo(id));
                }
                engine.waiters.remove(&Wait::Memo(id))
            });
            wake(waiters.unwrap_or_default());
        }
        CompKind::Selector => {
            // Only the readers of the key it had and of the key it has run again.
            let waiters = with(|engine| {
                let comp = engine.comp(id)?;
                let was = comp.holds.replace(out.clone());
                if let Some(was) = was
                    && was != out
                {
                    engine.schedule_observers(&Source::Selector(id, was));
                    engine.schedule_observers(&Source::Selector(id, out));
                }
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
        CompKind::Show => settle_show(id, out),
        CompKind::For => {
            let entries = json::parse(&out).and_then(Value::into_array).unwrap_or_default();
            settle_for(id, entries)
        }
        CompKind::Text | CompKind::Attr | CompKind::Optional | CompKind::Style | CompKind::Flag | CompKind::Class => {
            let Target::Node(node) = target else { return };
            let value = json::parse(&out).unwrap_or(Value::Null);
            with(|engine| patch(engine, kind, node, &name, &value));
        }
        CompKind::Html | CompKind::Root => {
            let parsed = json::parse(&out).unwrap_or(Value::Null);
            // D-070's hole answers text alone as a JSON string, as a text hole's run answers.
            let nodes = match parsed {
                Value::Array(nodes) => nodes,
                Value::String(text) => vec![Value::text_node(text)],
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
            // D-070's hole while it shows text alone: its text patched; markup now, its text's place a
            // range from here on.
            let target = match target {
                Target::Node(text) if with(|engine| engine.comps.get(&id).is_some_and(|comp| comp.hole_text)) => {
                    if let Some(value) = lone_text(&nodes) {
                        with(|engine| {
                            if engine.dom.text_of(text) != value {
                                engine.dom.set_text(text, &value);
                            }
                        });
                        return;
                    }
                    with(|engine| {
                        let range = engine.dom.wrap_in_range(text);
                        if let Some(made) = engine.comp(id) {
                            made.target = Target::Range(range);
                            made.hole_text = false;
                        }
                        Target::Range(range)
                    })
                }
                other => other,
            };
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

/// What D-070's hole shows, when it is text alone (one text node's JSON): that text.
fn lone_text(nodes: &[Value]) -> Option<String> {
    match nodes {
        [only] if only.get("t").and_then(Value::as_str) == Some("s") => Some(only.get("v").and_then(Value::as_str).unwrap_or("").to_string()),
        _ => None,
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
        // A computed `class`: the `class:name`s that are on beside it stay.
        CompKind::Attr | CompKind::Optional if name == "class" => {
            let old = engine.classes.insert(node, text.clone()).unwrap_or_default();
            let now = engine.dom.attr(node, "class");
            let whole = whole_class(now.unwrap_or(""), &old, &text);
            if whole.is_empty() && kind == CompKind::Optional {
                if now.is_some() {
                    engine.dom.remove_attr(node, "class");
                }
            } else if now != Some(whole.as_str()) {
                engine.dom.set_attr(node, "class", &whole);
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
            // The app says whether it is checked: a tap's state gives way.
            if name == "checked" {
                engine.values.remove(&node);
            }
            if on {
                engine.dom.set_attr(node, name, "");
            } else {
                engine.dom.remove_attr(node, name);
            }
        }
        _ => {}
    }
}

/// An element's `class` when its computed one becomes `new` (it was `old`): `new`'s names, then the
/// ones it has now that weren't `old`'s (`class:name`s that are on, static ones), as they are.
fn whole_class(now: &str, old: &str, new: &str) -> String {
    let mut names: Vec<&str> = new.split_whitespace().collect();
    for name in now.split_whitespace() {
        if !old.split_whitespace().any(|was| was == name) && !names.contains(&name) {
            names.push(name);
        }
    }
    names.join(" ")
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
            let value = engine.signals.remove(&id);
            // Held (optimistic writes): it shows the latest write, so each write and its value
            // before them are let go of instead.
            match engine.held.remove(&id) {
                Some(held) => {
                    roc::release(held.base);
                    for (write, _) in held.writes {
                        roc::release(write);
                    }
                }
                None => {
                    if let Some(value) = value {
                        roc::release(value);
                    }
                }
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
        let requests: Vec<u64> = comp.calls.drain().map(|(_, request)| request).collect();
        engine.forget_requests(&requests);
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
            // A memo's, a selector's and an effect's computation is its own box (not one kept for
            // markup).
            if matches!(comp.kind, CompKind::Memo | CompKind::Selector | CompKind::Reaction) {
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
            Cleanup::Live(id) => crate::live::cleanup(id),
            Cleanup::Leave(id) => with(|engine| {
                if let Some(at) = engine.nav.listeners.iter().position(|listener| listener.id == id) {
                    let listener = engine.nav.listeners.remove(at);
                    engine.release_kept(listener.runner);
                }
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
            Some(Step::Task(Task::Navigate { to, replace, scroll })) => crate::nav::navigate(&to, crate::nav::Options { replace, scroll, ..Default::default() }),
            Some(Step::Task(Task::LeaveRetry(id, force))) => crate::nav::retry(id, force),
            Some(Step::Task(Task::Wake(id))) => {
                let runs = with(|engine| engine.handlers.get(&id).is_some_and(|handler| engine.kept.contains_key(&handler.runner)));
                if runs {
                    go(id);
                } else {
                    with(|engine| engine.handlers.remove(&id));
                }
            }
            None => {
                // The flush is over: a transition open since a handler's optimistic writes is
                // closed, and ends now if no submission joined it (Solid 2.0 undoes an optimistic
                // write outside a transition); the undo runs in this flush.
                let unsent = with(|engine| engine.transition.take().filter(|id| engine.transitions.get(id).is_some_and(|transition| !transition.sent || transition.pending == 0)));
                match unsent {
                    Some(id) => end_transition(id),
                    None => break,
                }
            }
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
            let dropped: Vec<u64> = comp.calls.drain().map(|(_, request)| request).collect();
            engine.forget_requests(&dropped);
            let Some(comp) = engine.comp(memo) else { return };
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
    // Optimistic writes (D-054) open a transition the submissions sent with them join.
    if writes.iter().any(|write| matches!(write, Write::Optimistic(..))) {
        with(|engine| {
            let id = engine.id();
            engine.transitions.insert(id, Transition::default());
            engine.transition = Some(id);
        });
    }
    for write in writes {
        match write {
            Write::Signal(id, value) => with(|engine| {
                // Held by a transition: the value under its optimistic writes, shown once they end.
                if let Some(held) = engine.held.get_mut(&id) {
                    let old = std::mem::replace(&mut held.base, value);
                    roc::release(old);
                    return;
                }
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
            Write::Optimistic(id, value) => hold(id, value),
            Write::Revalidate(keys) => revalidate(Finish::Nothing, Some(keys), None),
            Write::Navigate { to, replace, scroll } => with(|engine| engine.tasks.push_back(Task::Navigate { to, replace, scroll })),
            Write::LeaveRetry(id, force) => with(|engine| engine.tasks.push_back(Task::LeaveRetry(id, force))),
            Write::Retried(key, id) => retry_submission(&key, id),
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
        engine.handlers.insert(id, Handler { runner, calls: HashMap::default(), writes: Vec::new(), event, scope, owner, cleanups_of, release, own: 0 });
        id
    });
    go(id);
}

fn go(id: u64) {
    let found = with(|engine| {
        let handler = engine.handlers.get_mut(&id)?;
        handler.writes.clear();
        handler.own = 0;
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
            let (writes, release) = with(|engine| engine.end_handler(id).map(|handler| (handler.writes, handler.release)).unwrap_or_default());
            apply(writes);
            if let Some(kept) = release {
                with(|engine| engine.release_kept(kept));
            }
        }
        Err((why, frame)) => {
            let dropped = with(|engine| {
                let writes = engine.handlers.get_mut(&id).map(|handler| std::mem::take(&mut handler.writes)).unwrap_or_default();
                for write in writes {
                    if let Write::Signal(_, value) | Write::Optimistic(_, value) = write {
                        roc::release(value);
                    }
                }
                effect.and_then(|effect| engine.comp(effect)).map(|effect| effect.cleanups.split_off(mark.min(effect.cleanups.len()))).unwrap_or_default()
            });
            clean_up(dropped);
            if !matches!(why, Abort::Crash(_)) {
                frame.reclaim();
            }
            match why {
                Abort::Wait(wait) => with(|engine| engine.waiters.entry(wait).or_default().push(Waiter::Handler(id))),
                Abort::Failed(why, _) | Abort::Crash(why) => {
                    log(Level::Error, &format!("rocx: a handler failed: {why}"));
                    let release = with(|engine| engine.end_handler(id).and_then(|handler| handler.release));
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

/// A <Show>: only a change of what its condition answers switches what it shows (`settleShow`):
/// whether it holds, or, keyed (a `<Switch>`, a keyed `<Show>`, a route's level: `Html.switched`,
/// D-053, D-040), its case's name (`"#…"`), a new one making it anew.
fn settle_show(id: u64, answer: String) {
    let holds = !matches!(answer.as_str(), "false" | "null" | "\"\"" | "0");
    let found = with(|engine| {
        let comp = engine.comp(id)?;
        if comp.holds.as_deref() == Some(answer.as_str()) {
            return None;
        }
        comp.holds = Some(answer);
        let Target::Range(range) = comp.target else { return None };
        Some((comp.part.take(), comp.node.clone()?, range, comp.scope.clone()))
    });
    let Some((old, node, range, scope)) = found else { return };
    if let Some(old) = old {
        dispose(old);
    }
    // What it makes is a level (D-040): a read of the location once, in it, makes it anew. An `if`'s
    // or `match`'s part (D-070, `"b"`) belongs to the level around it.
    let choosing_part = node.get("b").is_some();
    let scope = if choosing_part { scope } else { Scope { level: Some(id), ..scope } };
    let with_box = node.get("with").and_then(Value::as_u64);
    let made = if holds && let Some(with_box) = with_box {
        // A function child: made when it shows, by its own computation, once, untracked.
        let made = with(|engine| {
            let runner = engine.kept.get(&with_box).copied().unwrap_or(std::ptr::null_mut());
            let made = engine.new_comp(CompKind::Html, runner, None, scope.clone(), Target::Range(range), "");
            if let Some(comp) = engine.comp(made) {
                comp.untracked = true;
                comp.choosing = choosing_part;
                comp.owner = Some(id);
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
    let mut seen: HashSet<String> = HashSet::with_capacity_and_hasher(entries.len(), Default::default());
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
        if seen.insert(key.clone()) {
            order.push(key);
        }
    }
    // Rows whose key is gone, and their items.
    let gone = with(|engine| {
        let list = engine.lists.get_mut(&list)?;
        let gone: Vec<String> = list.rows.keys().filter(|key| !seen.contains(*key)).cloned().collect();
        let items: Vec<String> = list.items.keys().filter(|key| !seen.contains(*key)).cloned().collect();
        for key in items {
            if let Some(item) = list.items.remove(&key) {
                roc::release(item);
            }
        }
        Some(gone)
    });
    let gone = gone.unwrap_or_default();
    if order.is_empty() && !gone.is_empty() {
        // Every row went: their computations disposed, then their nodes taken off at once.
        for key in &gone {
            drop_row_quietly(list, key);
        }
        with(|engine| {
            for node in engine.dom.free_inside(range) {
                engine.listeners.remove(&node);
                engine.values.remove(&node);
                engine.classes.remove(&node);
            }
        });
    } else {
        for key in gone {
            drop_row(list, &key);
        }
    }
    // The order the rows were in, for the moves below.
    let was = with(|engine| engine.lists.get_mut(&list).map(|list| std::mem::replace(&mut list.order, order.clone()))).unwrap_or_default();
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
    // Rows in order, as runtime.js's `steady` puts them: the longest run of rows already in order
    // stays where it is, and the others move (or arrive) around it, last to first, each before
    // the row after it. A swap moves two rows.
    with(|engine| {
        let Some(parent) = engine.dom.nodes[range.start].parent else { return };
        let Some(rows) = engine.lists.get(&list).map(|list| &list.rows) else { return };
        let position: HashMap<&str, usize> = was.iter().enumerate().map(|(at, key)| (key.as_str(), at)).collect();
        let places: Vec<Option<usize>> = order
            .iter()
            .map(|key| match rows.get(key) {
                Some(row) if row.fresh.is_none() => position.get(key.as_str()).copied(),
                _ => None,
            })
            .collect();
        let stays = steady(&places);
        let mut before = range.end;
        for (at, key) in order.iter().enumerate().rev() {
            let Some(row) = engine.lists.get_mut(&list).and_then(|list| list.rows.get_mut(key)) else { continue };
            let (row_range, fresh) = (row.range, row.fresh.take());
            if !stays[at] {
                match fresh {
                    Some(fragment) => engine.dom.insert_before(parent, fragment, Some(before)),
                    None => engine.dom.move_range(row_range, parent, Some(before)),
                }
            }
            before = row_range.start;
        }
    });
}

/// Which of the rows, by where each was (`None`: new), stay where they are: a longest run of them
/// in the order they were in (a longest increasing subsequence, in n log n).
fn steady(places: &[Option<usize>]) -> Vec<bool> {
    let mut stays = vec![false; places.len()];
    // The run of each length so far whose last place is least, by its last row; each row's row
    // before it in its run.
    let mut ends: Vec<usize> = Vec::new();
    let mut before = vec![usize::MAX; places.len()];
    for (at, place) in places.iter().enumerate() {
        let Some(place) = *place else { continue };
        let length = ends.partition_point(|&end| places[end].is_some_and(|end| end < place));
        if length > 0 {
            before[at] = ends[length - 1];
        }
        if length == ends.len() {
            ends.push(at);
        } else {
            ends[length] = at;
        }
    }
    let mut at = ends.last().copied();
    while let Some(row) = at {
        stays[row] = true;
        at = (before[row] != usize::MAX).then_some(before[row]);
    }
    stays
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
        // Its computations disposed, nothing names its nodes but their handlers and typed values.
        for node in engine.dom.free_range(row.range) {
            engine.listeners.remove(&node);
            engine.values.remove(&node);
            engine.classes.remove(&node);
        }
    });
}

/// A row's computations disposed and its box let go of, its nodes left for its caller to take off
/// with the others' (`Dom::free_inside`).
fn drop_row_quietly(list: u64, key: &str) {
    let row = with(|engine| {
        let list = engine.lists.get_mut(&list)?;
        list.indexes.remove(key);
        list.rows.remove(key)
    });
    let Some(row) = row else { return };
    dispose(row.comp);
    with(|engine| engine.release_kept(row.runner));
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
        // A hole of either kind (D-070): while it shows text alone, a text node patched as a text
        // hole's; markup, a range as a markup hole's (text that turns into markup turns into one).
        "hx" => {
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
            if let Some(value) = nodes.as_deref().and_then(lone_text) {
                return with(|engine| {
                    let text = engine.dom.text(&value);
                    if let Some(made) = engine.comp(comp) {
                        made.target = Target::Node(text);
                        made.hole_text = true;
                    }
                    text
                });
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
        // A template (D-084): its skeleton the first time, kept; then the skeleton built with the
        // row's parts put in, in its slots' order, as the markup they make up would be.
        "tpl" => {
            let id = node.get("s").and_then(Value::as_u64).unwrap_or(0) as usize;
            let template = with(|engine| {
                if let Some(skeleton) = node.get("k")
                    && id < engine.templates.len()
                {
                    let mut html = String::new();
                    template_html(skeleton, &mut html);
                    let root = compile(&mut engine.dom, skeleton);
                    engine.templates[id] = Some(Rc::new(Template { root, html }));
                }
                engine.templates.get(id).cloned().flatten()
            });
            let Some(template) = template else {
                return with(|engine| {
                    engine.warn_once("tpl", "rocx native: a template's copy came before its skeleton: left out");
                    engine.dom.fragment()
                });
            };
            let parts = node.get("p").and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]);
            instantiate(id, &template, parts, owner, scope)
        }
        "loading" => {
            let (at, range, fragment, inner) = with(|engine| {
                let at = engine.id();
                let (range, fragment) = engine.dom.make_range();
                let children = engine.dom.fragment();
                engine.loadings.insert(at, Loading { waiting: HashSet::default(), revealed: false, built: false, range, children });
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
    let element = element_of(tag, &attrs, owner, scope);
    for child in children(node) {
        let built = build(child, owner, scope);
        with(|engine| engine.dom.append(element, built));
    }
    element
}

/// A template (D-084): its skeleton, compiled once (`compile`), and its markup for the page.
pub(crate) struct Template {
    root: Skel,
    html: String,
}

/// A skeleton's node, ready to copy: an element's tag and written attributes shared, its attributes
/// in the markup's order (`None` where a part goes), the text written in the file, a slot.
enum Skel {
    Text(Rc<str>),
    Element { tag: String, written: Vec<(Rc<str>, Rc<str>)>, attrs: Vec<Option<Vec<Value>>>, parts: bool, children: Vec<Skel> },
    Slot,
}

/// A skeleton's JSON (`Html.skeleton`), compiled: what `skeletal` copies.
fn compile(dom: &mut Dom, node: &Value) -> Skel {
    match node.get("t").and_then(Value::as_str) {
        Some("s") => Skel::Text(Rc::from(node.get("v").and_then(Value::as_str).unwrap_or(""))),
        Some("e") => {
            let attrs: Vec<Option<Vec<Value>>> = node
                .get("a")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_array)
                .map(|attr| (attr.first().and_then(Value::as_str) != Some("?")).then(|| attr.clone()))
                .collect();
            let field = |attr: &Vec<Value>, at: usize| attr.get(at).and_then(Value::as_str).unwrap_or("").to_string();
            let written: Vec<&Vec<Value>> = attrs.iter().flatten().collect();
            // The classes first, then the others, as `fill` sets them.
            let classes: Vec<String> = written.iter().filter(|attr| field(attr, 1) == "class").map(|attr| field(attr, 2)).collect();
            let mut shared = Vec::new();
            if !classes.is_empty() {
                shared.push((dom.name("class"), Rc::from(classes.join(" "))));
            }
            for attr in &written {
                if field(attr, 1) != "class" {
                    shared.push((dom.name(&field(attr, 1)), Rc::from(field(attr, 2))));
                }
            }
            let parts = attrs.iter().any(Option::is_none);
            Skel::Element {
                tag: node.get("tag").and_then(Value::as_str).unwrap_or("div").to_string(),
                written: shared,
                attrs,
                parts,
                children: children(node).map(|child| compile(dom, child)).collect(),
            }
        }
        _ => Skel::Slot,
    }
}

/// A template's slot, in its parts' order: an element whose attributes include parts (its
/// attributes, `None` where each part goes), or the placeholder where a child goes.
enum Slot<'a> {
    Attrs(NodeId, &'a [Option<Vec<Value>>]),
    Child(NodeId),
}

/// A copy of template `id`'s skeleton with a row's parts put in, as runtime.js's `instantiate`
/// makes it: the skeleton built quietly here and copied on the page at once (a CLONE op, its
/// markup sent the first time: TEMPLATE), then each slot filled in its parts' order, an element's
/// attribute parts as `element` sets and binds them, a child built where its placeholder was.
fn instantiate(id: usize, template: &Template, parts: &[Value], owner: Option<u64>, scope: &Scope) -> NodeId {
    let mut slots = Vec::new();
    let root = with(|engine| {
        if cfg!(target_arch = "wasm32") && !engine.dom.template_sent(id) {
            engine.dom.template_op(id, &template.html);
        }
        let mut nodes = Vec::new();
        let root = engine.dom.quietly(|dom| skeletal(dom, &template.root, &mut nodes, &mut slots));
        engine.dom.clone_op(id, &nodes);
        root
    });
    let mut at = 0;
    for slot in slots {
        match slot {
            Slot::Attrs(element, attrs) => {
                let (mut all, mut own) = (Vec::new(), Vec::new());
                for attr in attrs {
                    match attr {
                        Some(written) => all.push(written),
                        None => {
                            if let Some(part) = parts.get(at).and_then(Value::as_array) {
                                all.push(part);
                                own.push(part);
                            }
                            at += 1;
                        }
                    }
                }
                fill(element, &all, &own, owner, scope);
            }
            Slot::Child(placeholder) => {
                let part = parts.get(at).unwrap_or(&Value::Null);
                at += 1;
                let built = build(part, owner, scope);
                with(|engine| {
                    engine.dom.replace(placeholder, built);
                    engine.dom.let_go(vec![placeholder]);
                });
            }
        }
    }
    root.unwrap_or_else(|| with(|engine| engine.dom.fragment()))
}

/// A skeleton's nodes, made (quietly): an element with the attributes written in the file, the
/// text written in the file (but empty text, which markup can't hold), and a placeholder comment
/// where each other child goes; each node in document order (`nodes`), each slot in its parts'
/// order (`slots`).
fn skeletal<'a>(dom: &mut Dom, node: &'a Skel, nodes: &mut Vec<NodeId>, slots: &mut Vec<Slot<'a>>) -> Option<NodeId> {
    match node {
        Skel::Text(text) => {
            if text.is_empty() {
                return None;
            }
            let made = dom.text(text);
            nodes.push(made);
            Some(made)
        }
        Skel::Element { tag, written, attrs, parts, children } => {
            let element = dom.element(tag);
            nodes.push(element);
            for (name, value) in written {
                dom.set_shared_attr(element, name, value);
            }
            if *parts {
                slots.push(Slot::Attrs(element, attrs));
            }
            for child in children {
                if let Some(made) = skeletal(dom, child, nodes, slots) {
                    dom.append(element, made);
                }
            }
            Some(element)
        }
        Skel::Slot => {
            let placeholder = dom.comment();
            nodes.push(placeholder);
            slots.push(Slot::Child(placeholder));
            Some(placeholder)
        }
    }
}

/// A skeleton as markup, for the page's copy (TEMPLATE): what `skeletal` makes, node for node.
fn template_html(node: &Value, out: &mut String) {
    let escape = |text: &str, out: &mut String, quotes: bool| {
        for c in text.chars() {
            match c {
                '&' => out.push_str("&amp;"),
                '<' => out.push_str("&lt;"),
                '>' => out.push_str("&gt;"),
                '"' if quotes => out.push_str("&quot;"),
                _ => out.push(c),
            }
        }
    };
    match node.get("t").and_then(Value::as_str) {
        Some("s") => escape(node.get("v").and_then(Value::as_str).unwrap_or(""), out, false),
        Some("e") => {
            let tag = node.get("tag").and_then(Value::as_str).unwrap_or("div");
            let written: Vec<&Vec<Value>> = node.get("a").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_array).filter(|attr| attr.first().and_then(Value::as_str) != Some("?")).collect();
            let field = |attr: &Vec<Value>, at: usize| attr.get(at).and_then(Value::as_str).unwrap_or("").to_string();
            out.push('<');
            out.push_str(tag);
            let classes: Vec<String> = written.iter().filter(|attr| field(attr, 1) == "class").map(|attr| field(attr, 2)).collect();
            if !classes.is_empty() {
                out.push_str(" class=\"");
                escape(&classes.join(" "), out, true);
                out.push('"');
            }
            for attr in &written {
                let name = field(attr, 1);
                if name != "class" {
                    out.push(' ');
                    out.push_str(&name);
                    out.push_str("=\"");
                    escape(&field(attr, 2), out, true);
                    out.push('"');
                }
            }
            out.push('>');
            if matches!(tag, "area" | "base" | "br" | "col" | "embed" | "hr" | "img" | "input" | "link" | "meta" | "source" | "track" | "wbr") {
                return;
            }
            for child in children(node) {
                template_html(child, out);
            }
            out.push_str("</");
            out.push_str(tag);
            out.push('>');
        }
        _ => out.push_str("<!---->"),
    }
}

/// An element of `tag` with `attrs` set, bound and computed: its children are its caller's.
fn element_of(tag: &str, attrs: &[&Vec<Value>], owner: Option<u64>, scope: &Scope) -> NodeId {
    let element = with(|engine| engine.dom.element(tag));
    fill(element, attrs, attrs, owner, scope);
    element
}

/// An element given its attributes `own` (`all` of them, in the markup's order; the others are on
/// it already, a template's written ones): set, bound and computed (runtime.js's `fill`).
fn fill(element: NodeId, all: &[&Vec<Value>], own: &[&Vec<Value>], owner: Option<u64>, scope: &Scope) {
    with(|engine| {
        if own.iter().any(|attr| text_at(attr, 0) == "ci" || (matches!(text_at(attr, 0), "v" | "o") && text_at(attr, 1) == "class")) {
            let mut classes = Vec::new();
            for attr in all {
                let kind = text_at(attr, 0);
                let name = text_at(attr, 1);
                match kind {
                    "v" if name == "class" => classes.push(text_at(attr, 2).to_string()),
                    "o" if name == "class" && !text_at(attr, 2).is_empty() => classes.push(text_at(attr, 2).to_string()),
                    "ci" if attr.get(2).and_then(Value::as_bool) == Some(true) => classes.push(name.to_string()),
                    _ => {}
                }
            }
            if !classes.is_empty() {
                engine.dom.set_attr(element, "class", &classes.join(" "));
            }
        }
        for attr in own {
            let kind = text_at(attr, 0);
            let name = text_at(attr, 1);
            match kind {
                "v" if name != "class" => engine.dom.set_attr(element, name, text_at(attr, 2)),
                "o" if name != "class" && !text_at(attr, 2).is_empty() => engine.dom.set_attr(element, name, text_at(attr, 2)),
                "f" if attr.get(2).and_then(Value::as_bool) == Some(true) => engine.dom.set_attr(element, name, ""),
                "sv" if !text_at(attr, 2).is_empty() => engine.dom.set_style(element, name, text_at(attr, 2)),
                _ => {}
            }
        }
    });
    for attr in own {
        let kind = text_at(attr, 0);
        let name = text_at(attr, 1);
        let computed = match kind {
            "vo" => Some(CompKind::Attr),
            "fo" => Some(CompKind::Flag),
            "co" => Some(CompKind::Class),
            "oo" => Some(CompKind::Optional),
            "so" => Some(CompKind::Style),
            _ => None,
        };
        if let Some(computed) = computed {
            let runner = kept_box(attr.get(2).and_then(Value::as_u64));
            let comp = with(|engine| engine.new_comp(computed, runner, owner, scope.clone(), Target::Node(element), name));
            let outcome = run(comp);
            if is_static(comp, outcome) {
                forget(comp, owner);
            }
            continue;
        }
        match kind {
            "on" | "onp" | "onk" => {
                let runner = attr.get(2).and_then(Value::as_u64).unwrap_or(0);
                let wanted = attr.get(3).and_then(Value::as_str).map(str::to_string);
                with(|engine| engine.listeners.entry(element).or_default().push(Listener { event: name.to_string(), kind: kind.to_string(), runner, wanted, scope: scope.clone(), owner }));
            }
            // `on:viewport` (D-137): its handler told the element's scroll and size once it is laid
            // out and each time they change (native::render's `viewports`, `fire`).
            "view" => {
                let runner = attr.get(2).and_then(Value::as_u64).unwrap_or(0);
                with(|engine| engine.listeners.entry(element).or_default().push(Listener { event: "viewport".to_string(), kind: kind.to_string(), runner, wanted: None, scope: scope.clone(), owner }));
            }
            "frame" | "tr" | "tro" | "k" | "ko" => with(|engine| {
                engine.warn_once(&format!("attr {kind}"), &format!("rocx native: `{kind}` ({}) isn't on phones yet: ignored", attr_name(kind)));
            }),
            _ => {}
        }
    }
}

/// An attribute's field `at` as text ("" when it isn't).
fn text_at(attr: &[Value], at: usize) -> &str {
    attr.get(at).and_then(Value::as_str).unwrap_or("")
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
        Ok(out) => (Some(comp), vec![json::parse(&out).unwrap_or(Value::Null)]),
        // A wait here is the app's mistake, and its frame stays (as the browser's throws).
        Err((Abort::Wait(_), _)) => {
            log(Level::Error, "rocx: a component read a value that isn't in yet outside its markup: read it in a hole ({…}), which waits");
            (Some(comp), Vec::new())
        }
        Err((Abort::Failed(why, memo), frame)) => {
            failed(comp, why, memo);
            frame.reclaim();
            (Some(comp), Vec::new())
        }
        Err((Abort::Crash(why), _)) => {
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
        let id = engine.new_comp(CompKind::Root, std::ptr::null_mut(), None, Scope::default(), Target::Range(range), "");
        engine.root = Some(id);
        id
    });
    run(root);
}

/// The root made anew in its place (D-040's `remakeRoot`, phase 1's way): everything the app shows,
/// from the root layout down.
pub(crate) fn remake_root() {
    let Some((old, range)) = with(|engine| {
        let old = engine.root?;
        let Target::Range(range) = engine.comps.get(&old)?.target else { return None };
        Some((old, range))
    }) else {
        return mount();
    };
    dispose(old);
    let root = with(|engine| {
        let id = engine.new_comp(CompKind::Root, std::ptr::null_mut(), None, Scope::default(), Target::Range(range), "");
        engine.root = Some(id);
        id
    });
    run(root);
}

// ---- What navigation asks of the engine (nav.rs, D-138) ----

/// What a `listen!` or a subscription keeps (D-140): its box, what it runs in, and the id its
/// owner's cleanup names.
pub(crate) struct LiveHeld {
    pub kept: u64,
    pub scope: Scope,
    pub owner: Option<u64>,
    pub id: u64,
}

/// A handler kept for live updates, with a cleanup on what runs now (its owner going stops it);
/// `required`: refused (the box given back) when nothing runs that it could go with.
pub(crate) fn live_keep(runner: Callable, required: bool) -> Result<LiveHeld, Callable> {
    with(|engine| {
        engine.touch(false);
        let id = engine.id();
        let kept = engine.keep(runner);
        if engine.push_cleanup(Cleanup::Live(id)).is_err() && required {
            engine.kept.remove(&kept);
            return Err(runner);
        }
        Ok(LiveHeld { kept, scope: engine.current_scope(), owner: engine.owner(), id })
    })
}

/// A kept box let go of after what runs now (which may be its own handler).
pub(crate) fn release_later(kept: u64) {
    with(|engine| engine.tasks.push_back(Task::ReleaseKept(kept)));
}

/// Commits where the app is (`commitLocation`): what read it runs again.
pub(crate) fn commit_location(to: &str) {
    with(|engine| {
        if engine.path == to {
            return;
        }
        engine.path = to.to_string();
        engine.schedule_observers(&Source::Location);
    });
}

/// What read the location runs again, the location the same (the same page navigated to again).
pub(crate) fn schedule_location() {
    with(|engine| engine.schedule_observers(&Source::Location));
}

pub(crate) fn schedule_routing() {
    with(|engine| engine.schedule_observers(&Source::Routing));
}

/// Whether a computation is still there.
pub(crate) fn alive(engine: &Engine, id: u64) -> bool {
    engine.comps.get(&id).is_some_and(|comp| !comp.disposed)
}

pub(crate) fn schedule_if_alive(id: u64) -> bool {
    with(|engine| {
        if !alive(engine, id) {
            return false;
        }
        engine.schedule(id);
        true
    })
}

impl Engine {
    /// What read a GET from the server now (`readers`).
    pub(crate) fn readers_now(&self) -> Vec<u64> {
        self.readers.iter().copied().collect()
    }
}

/// A computation's reads of a GET, each with its answer now (`{"status":…,"body":…}`, if in); none
/// for one that is gone or read nothing.
pub(crate) fn reads_of(id: u64) -> Option<Vec<(String, Option<String>)>> {
    with(|engine| {
        let comp = engine.comps.get(&id).filter(|comp| !comp.disposed)?;
        let reads: Vec<(String, Option<String>)> = comp
            .calls
            .iter()
            .filter(|(key, _)| key.starts_with("GET "))
            .map(|(key, request)| {
                let answer = match engine.requests.get(request) {
                    Some(Answer::Ok(json)) => Some(json.clone()),
                    _ => None,
                };
                (key.clone(), answer)
            })
            .collect();
        (!reads.is_empty()).then_some(reads)
    })
}

/// A computation runs again, reading `keys` afresh (from the document's answers, if it has them).
pub(crate) fn read_again(id: u64, keys: Vec<String>) {
    with(|engine| {
        let mut dropped = Vec::new();
        if let Some(comp) = engine.comp(id) {
            for key in &keys {
                dropped.extend(comp.calls.remove(key));
            }
        }
        engine.forget_requests(&dropped);
        engine.schedule(id);
    });
}

/// The `<Errored>` boundaries that show their fallback now.
pub(crate) fn failed_boundaries() -> Vec<u64> {
    with(|engine| engine.boundaries.iter().filter(|(_, boundary)| boundary.failed.is_some() && boundary.fallback.is_some() && engine.dom.connected(boundary.range.start)).map(|(&id, _)| id).collect())
}

/// A boundary that still shows its fallback, tried again.
pub(crate) fn retry_failed(boundary: u64) {
    let failed = with(|engine| engine.boundaries.get(&boundary).is_some_and(|boundary| boundary.failed.is_some() && engine.dom.connected(boundary.range.start)));
    if failed {
        errored_retry(boundary);
    }
}

/// A level (a route's keyed part) made anew: run again, its part made as if its key had changed.
pub(crate) fn remake_level(level: u64) {
    with(|engine| {
        if !alive(engine, level) {
            return;
        }
        if let Some(comp) = engine.comp(level) {
            comp.holds = Some(REMADE.to_string());
        }
        engine.schedule(level);
    });
}

/// A level's case that no `<Show>` answers (D-040: it read the location once), so its part is made
/// anew.
const REMADE: &str = "\u{1}remade";

// ---- Events ----

/// An event on a native view (`id`, the node it shows), given its value (what a field holds now):
/// the handlers of the node and of each element above it, as the DOM bubbles it. A tap on a
/// button in a form (not `type="button"`) submits the form too.
/// An event for the element alone, which doesn't bubble (`on:viewport`'s, D-137): its own handlers
/// for it run, given `value`.
pub fn fire(node: NodeId, event: &str, value: &str) {
    let listeners: Vec<(u64, Scope, Option<u64>)> = with(|engine| engine.listeners.get(&node).map(|listeners| listeners.iter().filter(|listener| listener.event == event).map(|listener| (listener.runner, listener.scope.clone(), listener.owner)).collect()).unwrap_or_default());
    for (runner, scope, owner) in listeners {
        if with(|engine| engine.kept.contains_key(&runner)) {
            handle(runner, value.to_string(), scope, owner, None, None);
        }
    }
}

pub fn dispatch(node: NodeId, event: &str, value: &str) -> bool {
    if event == "input" {
        with(|engine| {
            engine.values.insert(node, value.to_string());
        });
        crate::controls::set_invalid(node, None);
    }
    // A checkbox's or radio's tap (its view's `click`, with whether it is checked now): what it
    // holds, until the app sets its `checked` (a radio's group mates in its form unchecked).
    if event == "click" && matches!(value, "true" | "false") {
        with(|engine| {
            if engine.dom.tag(node) != Some("input") {
                return;
            }
            let kind = engine.dom.attr(node, "type").unwrap_or("").to_ascii_lowercase();
            if kind != "checkbox" && kind != "radio" {
                return;
            }
            engine.values.insert(node, value.to_string());
            if kind == "radio" && value == "true"
                && let Some(name) = engine.dom.attr(node, "name").map(str::to_string)
            {
                let mut top = node;
                while let Some(parent) = engine.dom.nodes.get(top).and_then(|each| each.parent) {
                    top = parent;
                    if engine.dom.tag(top) == Some("form") {
                        break;
                    }
                }
                let mut stack = vec![top];
                while let Some(at) = stack.pop() {
                    if at != node && engine.dom.tag(at) == Some("input") && engine.dom.attr(at, "name") == Some(name.as_str()) && engine.dom.attr(at, "type").is_some_and(|kind| kind.eq_ignore_ascii_case("radio")) {
                        engine.values.insert(at, "false".into());
                    }
                    stack.extend(engine.dom.children(at));
                }
            }
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
    // Whether a handler took what the browser would do (`.prevent`, a submit's, a key's): the
    // runtime's listener (a link's navigation, a form's sending) leaves it then.
    let mut prevented = false;
    for at in &path {
        let listeners: Vec<(u64, Scope, Option<u64>, Option<String>, String)> = with(|engine| {
            engine.listeners.get(at).map(|listeners| listeners.iter().filter(|listener| listener.event == event).map(|listener| (listener.runner, listener.scope.clone(), listener.owner, listener.wanted.clone(), listener.kind.clone())).collect()).unwrap_or_default()
        });
        for (runner, scope, owner, wanted, kind) in listeners {
            // A key's handler (`on:keydown.Enter`) runs for that key; `.checked`, `.data`, `.files`
            // say what a handler is given, not which event it takes.
            if kind != "onk" && wanted.as_deref().is_some_and(|wanted| !wanted.starts_with('.')) && wanted.as_deref() != Some(value) {
                continue;
            }
            if kind == "onp" || event == "submit" || (kind != "onk" && wanted.as_deref().is_some_and(|wanted| !wanted.starts_with('.'))) {
                prevented = true;
            }
            if with(|engine| engine.kept.contains_key(&runner)) {
                handle(runner, value.to_string(), scope, owner, None, None);
            }
        }
    }
    if event == "click" && !prevented {
        let (form, link) = with(|engine| {
            let submits = engine.dom.tag(node) == Some("button") && !engine.dom.attr(node, "type").is_some_and(|kind| kind.eq_ignore_ascii_case("button") || kind.eq_ignore_ascii_case("reset"));
            let form = if submits { path.iter().copied().find(|&at| engine.dom.tag(at) == Some("form")) } else { None };
            // A link (D-138): the nearest `<a>` with an `href`, as the browser's `linkOf` finds it.
            let link = path.iter().copied().find(|&at| engine.dom.tag(at) == Some("a")).and_then(|anchor| {
                let href = engine.dom.attr(anchor, "href").or_else(|| engine.dom.attr(anchor, "xlink:href"))?.to_string();
                Some((href, engine.dom.attr(anchor, "target").map(str::to_string), engine.dom.attr(anchor, "download").is_some(), engine.dom.attr(anchor, "replace").is_some(), engine.dom.attr(anchor, "noscroll").is_some()))
            });
            (form, link)
        });
        if let Some(form) = form {
            submit_form(form, Some(node));
        } else if let Some((href, target, download, replace, noscroll)) = link {
            crate::nav::tapped_link(&href, target.as_deref(), download, replace, noscroll);
        } else if let Some(activation) = with(|engine| crate::controls::activation(&engine.dom, &path)) {
            // D-139: a summary's, a label's, a file input's default action.
            activate(activation);
        }
    }
    // The keyboard's Enter in a form's field submits it, as a browser's implicit submission does
    // (the form has a submit button, or this is its one field).
    if event == "keydown" && value == "Enter" && !prevented {
        let form = with(|engine| {
            if engine.dom.tag(node) != Some("input") {
                return None;
            }
            let form = path.iter().copied().find(|&at| engine.dom.tag(at) == Some("form"))?;
            let (mut fields, mut button) = (0, false);
            let mut stack = vec![form];
            while let Some(at) = stack.pop() {
                match engine.dom.tag(at) {
                    Some("input") if !engine.dom.attr(at, "type").is_some_and(|kind| matches!(kind.to_ascii_lowercase().as_str(), "hidden" | "checkbox" | "radio" | "submit" | "button")) => fields += 1,
                    Some("input") if engine.dom.attr(at, "type").is_some_and(|kind| kind.eq_ignore_ascii_case("submit")) => button = true,
                    Some("button") if !engine.dom.attr(at, "type").is_some_and(|kind| kind.eq_ignore_ascii_case("button") || kind.eq_ignore_ascii_case("reset")) => button = true,
                    _ => {}
                }
                stack.extend(engine.dom.children(at));
            }
            (button || fields == 1).then_some(form)
        });
        if let Some(form) = form {
            submit_form(form, None);
        }
    }
    prevented
}

/// A form submitted by its button or the keyboard's Enter, as `requestSubmit` does (D-139): not
/// while a field keeps it back (`controls::invalid`: the field focused, its message beside it),
/// then its `submit` event, then, unless a handler took it, sent.
fn submit_form(form: NodeId, submitter: Option<NodeId>) {
    if let Some((field, said)) = with(|engine| crate::controls::invalid(&engine.dom, &engine.values, form, submitter)) {
        crate::controls::set_invalid(field, Some(said));
        dispatch(field, "invalid", "");
        crate::focus(&views_up(field));
        return;
    }
    if !dispatch(form, "submit", "") {
        submitted(form, submitter);
    }
}

/// A node's view, then those of the elements above it (the first that has one is the one shown).
fn views_up(node: NodeId) -> Vec<u64> {
    with(|engine| {
        let mut chain = Vec::new();
        let mut at = Some(node);
        while let Some(each) = at {
            chain.push(each as u64 + 1);
            at = engine.dom.nodes.get(each).and_then(|each| each.parent);
        }
        chain
    })
}

/// A tap's default action (D-139, `controls::activation`): a `<details>` opened or closed (its
/// `toggle` fired), a label's control used (a checkbox or radio toggled as its own tap does, a file
/// input's picker opened, a field focused), a file input's picker opened.
fn activate(activation: crate::controls::Activation) {
    use crate::controls::Activation;
    match activation {
        Activation::Toggle(details) => {
            with(|engine| {
                if engine.dom.attr(details, "open").is_some() {
                    engine.dom.remove_attr(details, "open");
                } else {
                    engine.dom.set_attr(details, "open", "");
                }
            });
            dispatch(details, "toggle", "");
        }
        Activation::Pick(input) => pick(input),
        Activation::Label(control) => {
            let (tag, kind, checked) = with(|engine| {
                let kind = engine.dom.attr(control, "type").unwrap_or("").to_ascii_lowercase();
                let checked = engine.values.get(&control).map(|now| now == "true").unwrap_or_else(|| engine.dom.attr(control, "checked").is_some());
                (engine.dom.tag(control).unwrap_or("").to_string(), kind, checked)
            });
            if with(|engine| engine.dom.attr(control, "disabled").is_some()) {
                return;
            }
            match (tag.as_str(), kind.as_str()) {
                ("input", "checkbox") => {
                    let now = (!checked).to_string();
                    dispatch(control, "click", &now);
                    dispatch(control, "input", &now);
                    dispatch(control, "change", &now);
                }
                ("input", "radio") if !checked => {
                    dispatch(control, "click", "true");
                    dispatch(control, "input", "true");
                    dispatch(control, "change", "true");
                }
                ("input", "radio") => {}
                ("input", "file") => pick(control),
                ("button", _) => {
                    dispatch(control, "click", "");
                }
                _ => {
                    crate::focus(&views_up(control));
                }
            }
        }
    }
}

/// A file input's picker opened by the phone (its `accept` and `multiple`); what is picked comes
/// back as the input's `files` event (`crate::event`).
fn pick(input: NodeId) {
    let (accept, multiple, disabled) = with(|engine| (engine.dom.attr(input, "accept").unwrap_or("").to_string(), engine.dom.attr(input, "multiple").is_some(), engine.dom.attr(input, "disabled").is_some()));
    if !disabled && !crate::pick(input as u64 + 1, &accept, multiple) {
        crate::log(crate::Level::Warn, "rocx native: this platform has no file picker");
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
        let seeded = if known.is_none() { engine.nav.answers.get(&key).cloned() } else { None };
        let request = match known {
            Some(request) => request,
            // The server answered it as it made the page's document (D-138): read here, not asked.
            None if seeded.is_some() => {
                let request = engine.id();
                engine.requests.insert(request, Answer::Ok(seeded.unwrap_or_default()));
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
    let (outbox, origin) = with(|engine| {
        let outbox = std::mem::take(&mut engine.outbox);
        let origin = crate::url::Url::parse(&engine.origin).map(|url| url.origin);
        (outbox.into_iter().map(|request| (matches!(engine.asked.get(&request.0), Some(Asked::Sheet(_))), request)).collect::<Vec<_>>(), origin)
    });
    for (sheet, (id, method, url, mut headers, body)) in outbox {
        // As a page's request carries its site (D-138): a form's post without it is a cross-site one
        // to a server that checks (SvelteKit's check, the app's own).
        if !matches!(method.as_str(), "GET" | "HEAD")
            && let Some(origin) = &origin
            && !headers.iter().any(|(name, _)| name.eq_ignore_ascii_case("origin"))
        {
            headers.push(("origin".into(), origin.clone()));
        }
        // A stylesheet holds the first frame (`native::render`): one its server refuses is given up
        // on at once, as a browser shows the page unstyled when a stylesheet's connection is
        // refused, not after the 3 s a read waits for a server being restarted.
        crate::http::send(id, method, url, headers, body, !sheet);
    }
}

/// A request's answer, in (on the main thread): what waited for it runs again.
pub fn answered(id: u64, result: Result<crate::http::Answered, String>) {
    let asked = with(|engine| engine.asked.remove(&id));
    match asked {
        Some(Asked::Navigation(navigation)) => crate::nav::answered(navigation, result),
        Some(Asked::LiveSend(items, stream)) => crate::live::sent(items, stream, result),
        Some(Asked::Sheet(href)) => with(|engine| {
            let sheet = match result {
                // A browser takes a stylesheet only as CSS (a redirect to a sign-in page isn't one).
                Ok(answer) if answer.status == 200 && answer.header("content-type").is_none_or(|kind| kind.to_ascii_lowercase().starts_with("text/css")) => Sheet::Loaded(answer.body),
                Ok(answer) if answer.status == 200 => {
                    log(Level::Warn, &format!("rocx native: the stylesheet {href} wasn't had: {} answered {}", answer.url, answer.header("content-type").unwrap_or("")));
                    Sheet::Failed
                }
                Ok(crate::http::Answered { status, .. }) => {
                    log(Level::Warn, &format!("rocx native: the stylesheet {href} wasn't had: {status}"));
                    Sheet::Failed
                }
                Err(why) => {
                    log(Level::Warn, &format!("rocx native: the stylesheet {href} wasn't had: {why}"));
                    Sheet::Failed
                }
            };
            engine.sheets.insert(href, sheet);
        }),
        Some(Asked::Submission { key, id: entry }) => {
            match result {
                Ok(answer) => {
                    let to = answer.header("x-rocx-redirect").map(str::to_string);
                    let revalidating = answer.header("x-rocx-revalidate").and_then(|value| json::parse(value).and_then(Value::into_strings));
                    let crate::http::Answered { status, headers, body, url, redirected } = answer;
                    // A redirect of the endpoint's own (`x-rocx-redirect`), or one the client followed
                    // (a middleware's, a plain form's flash back): where the app goes (`sendSubmission`).
                    if to.is_some() || redirected {
                        submission_redirect(&key, entry, to.unwrap_or(url), revalidating);
                        return;
                    }
                    let plain = with(|engine| engine.submissions.get(&key).and_then(|source| source.list.iter().find(|each| each.id == entry)).is_some_and(|each| each.plain));
                    if status == 200 {
                        // The reads the answer names (`x-rocx-revalidate`, `Router.revalidate!` in
                        // the endpoint, D-054), or every one.
                        let _ = headers;
                        revalidate(Finish::Result { key, entry, status, body }, revalidating, None);
                    } else if plain {
                        // A plain form's answer that isn't where to go (a crash, a middleware's
                        // refusal): shown where the form is, as the browser would show it (D-121).
                        let form = with(|engine| engine.submissions.get(&key).and_then(|source| source.list.iter().find(|each| each.id == entry)).and_then(|each| each.form));
                        fail_around(form, format!("POST {key}: {status}: {body}"));
                        submission_done(&key, entry, status, body);
                    } else {
                        unread(&key, status, &body);
                        submission_done(&key, entry, status, body);
                    }
                }
                Err(why) => {
                    unread(&key, 0, &why);
                    submission_done(&key, entry, 0, why)
                }
            }
        }
        _ => {
            let waiters = with(|engine| {
                let answer = match result {
                    Ok(crate::http::Answered { status, body, .. }) => {
                        let mut answer = format!("{{\"status\":{status},\"body\":");
                        json::quote(&body, &mut answer);
                        answer.push('}');
                        Answer::Ok(answer)
                    }
                    Err(why) => Answer::Failed(why),
                };
                // What asked for it went meanwhile (a page left, a run that asks no more): let go of.
                if !engine.requests.contains_key(&id) {
                    return engine.waiters.remove(&Wait::Request(id)).map(|_| Vec::new()).unwrap_or_default();
                }
                engine.requests.insert(id, answer);
                engine.waiters.remove(&Wait::Request(id)).unwrap_or_default()
            });
            wake(waiters);
        }
    }
}

// ---- Submissions ----

/// A submission refused, or with no answer, that no component asks for (D-095): nothing on the page
/// shows it, so the log says so, as the browser's console does.
fn unread(key: &str, status: u16, why: &str) {
    if with(|engine| engine.actions.contains_key(key)) {
        return;
    }
    let what = if status == 0 { format!("had no answer ({why})") } else { format!("was refused ({status}: {why})") };
    log(Level::Warn, &format!("rocx: a submission to {key} {what}, and nothing on the page reads it: use_submission! or use_submissions! shows it"));
}

fn submission_json(entry: &Submission, listed: bool) -> String {
    // serde_json's order: its keys sorted.
    let mut out = String::from("{\"body\":");
    json::quote(&entry.body, &mut out);
    if listed {
        out.push_str(&format!(",\"id\":{}", entry.id));
    }
    out.push_str(",\"input\":");
    json::quote(&entry.input, &mut out);
    out.push_str(&format!(",\"json\":{},\"state\":", entry.json));
    json::quote(entry.state, &mut out);
    out.push_str(&format!(",\"status\":{}}}", entry.status));
    out
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
            return submission_json(&Submission { id: 0, state: "cleared", input: String::new(), json: false, status: 0, body: String::new(), sent: Sent::default(), transition: None, plain: false, form: None, navigations: 0 }, false);
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
    // An arg naming a picked file (D-054's `fileOf`, D-139): sent as a form with files.
    if let Some((content_type, form)) = files_form(body) {
        send_submission(url, None, method, vec![("content-type".to_string(), content_type)], &form, input, true, false, None);
        return;
    }
    let headers = if method == "GET" || method == "HEAD" { Vec::new() } else { vec![("content-type".to_string(), "application/json".to_string())] };
    send_submission(url, None, method, headers, body, input, true, false, None);
}

/// An action's JSON as a form with files (runtime.js's `filesForm`), if a top-level field of it
/// holds the URL of a file a file input was given (or a list of them): each such file a part of
/// that field's name, the other fields as a form's (text as it is, a number or a flag as written, a
/// list as its items, null left out).
fn files_form(json: &str) -> Option<(String, String)> {
    let arg = json::parse(json)?;
    let Value::Object(fields) = &arg else { return None };
    let file = |value: &Value| value.as_str().and_then(crate::controls::file_of);
    let holds = fields.iter().any(|(_, value)| file(value).is_some() || value.as_array().is_some_and(|items| !items.is_empty() && items.iter().all(|item| file(item).is_some())));
    if !holds {
        return None;
    }
    let mut parts = Vec::new();
    for (name, value) in fields {
        let items: Vec<&Value> = match value.as_array() {
            Some(items) => items.iter().collect(),
            None => vec![value],
        };
        for item in items {
            if let Some(found) = file(item) {
                parts.push((name.to_string(), crate::controls::Part::File(found)));
            } else if item.is_null() {
                continue;
            } else {
                let text = match item {
                    Value::String(text) => text.to_string(),
                    Value::Bool(flag) => flag.to_string(),
                    Value::Number(json::Number::Whole(n)) => n.to_string(),
                    Value::Number(json::Number::Negative(n)) => n.to_string(),
                    Value::Number(json::Number::Fraction(n)) => n.to_string(),
                    _ => return None,
                };
                parts.push((name.to_string(), crate::controls::Part::Text(text)));
            }
        }
    }
    Some(crate::controls::multipart(&parts, &crate::controls::boundary()))
}

/// `Router.app!`'s route table (D-040): its pages (which a link may navigate to, D-138), and the paths
/// of the app's endpoints that take a POST (D-095).
pub fn app(routes: &str) {
    let table = json::parse(routes);
    let posts = table.as_ref().and_then(|table| table.get("posts").cloned()).and_then(Value::into_strings).unwrap_or_default();
    let pages = table.as_ref().map(crate::nav::pages_of).unwrap_or_default();
    with(|engine| {
        engine.posts = posts;
        engine.nav.has_table = table.is_some();
        engine.nav.pages = pages;
    });
}

/// Whether one of the app's endpoints that take a POST is at an action's path (its query and hash
/// left out; a path from the root, as `Endpoint.url_of` writes one), each `[param]` of its path any
/// one segment.
fn posted_to(posts: &[String], action: &str) -> bool {
    let path = action.split(['?', '#']).next().unwrap_or("");
    if !path.starts_with('/') {
        return false;
    }
    let segments: Vec<&str> = path.split('/').filter(|part| !part.is_empty()).collect();
    posts.iter().any(|post| {
        let parts: Vec<&str> = post.split('/').filter(|part| !part.is_empty()).collect();
        parts.len() == segments.len() && parts.iter().zip(&segments).all(|(part, segment)| (part.starts_with('[') && part.ends_with(']')) || part == segment)
    })
}

/// A form submitted (`submitted`): its named fields (and its button's, if it has a name),
/// URL-encoded. One posting to one of the app's endpoints (D-095), or to one a component reads the
/// submission of (`with_fields` URLs too), is sent by the host: as the runtime's if a component reads
/// it, else as a plain form (D-118). Any other is the browser's, which a phone does as a navigation
/// (D-138): a GET form goes to its URL with its fields as the query, a POST's answer (its redirect
/// followed) is the page the app goes to.
fn submitted(form: NodeId, submitter: Option<NodeId>) {
    let found = with(|engine| {
        let of = |name: &str, attribute: &str| submitter.and_then(|button| engine.dom.attr(button, attribute)).or_else(|| engine.dom.attr(form, name)).unwrap_or("").to_string();
        let method = of("method", "formmethod").to_ascii_lowercase();
        let action = of("action", "formaction");
        let action = if action.is_empty() { engine.path.clone() } else { action };
        // Each named field's value, in order (a file input's files, D-139).
        let mut parts: Vec<(String, crate::controls::Part)> = Vec::new();
        let mut stack = vec![form];
        while let Some(node) = stack.pop() {
            let tag = engine.dom.tag(node).unwrap_or("");
            if matches!(tag, "input" | "textarea" | "select")
                && let Some(name) = engine.dom.attr(node, "name")
                && engine.dom.attr(node, "disabled").is_none()
            {
                let kind = engine.dom.attr(node, "type").unwrap_or("").to_ascii_lowercase();
                let checkable = matches!(kind.as_str(), "checkbox" | "radio");
                let checked = engine.values.get(&node).map(|now| now == "true").unwrap_or_else(|| engine.dom.attr(node, "checked").is_some());
                if kind == "file" {
                    for file in crate::controls::files_of(node) {
                        parts.push((name.to_string(), crate::controls::Part::File(file)));
                    }
                } else if !(checkable && !checked) && !matches!(kind.as_str(), "submit" | "button" | "reset" | "image") {
                    let value = if checkable { engine.dom.attr(node, "value").unwrap_or("on").to_string() } else { crate::controls::value_of(&engine.dom, &engine.values, node) };
                    parts.push((name.to_string(), crate::controls::Part::Text(value)));
                }
            }
            let at = stack.len();
            stack.extend(engine.dom.children(node));
            stack[at..].reverse();
        }
        if let Some(button) = submitter
            && let Some(name) = engine.dom.attr(button, "name")
        {
            parts.push((name.to_string(), crate::controls::Part::Text(engine.dom.attr(button, "value").unwrap_or("").to_string())));
        }
        // As URL-encoded fields (a file by its name, as a browser's URL-encoded form sends one).
        let fields = parts
            .iter()
            .map(|(name, part)| match part {
                crate::controls::Part::Text(value) => format!("{}={}", encode(name), encode(value)),
                crate::controls::Part::File(file) => format!("{}={}", encode(name), encode(&file.name)),
            })
            .collect::<Vec<_>>()
            .join("&");
        if method != "post" {
            return Some(Submitted::Get(action, fields));
        }
        // Its endpoint: one a component asks for (by its URL, or its URL with fields after it), or
        // one of the app's that takes a POST.
        let key = if engine.actions.contains_key(&action) {
            Some(action.clone())
        } else {
            engine.actions.keys().filter(|known| action.starts_with(&format!("{known}?")) || action.starts_with(&format!("{known}&"))).max_by_key(|known| known.len()).cloned().or_else(|| posted_to(&engine.posts, &action).then(|| action.split(['?', '#']).next().unwrap_or("").to_string()))
        };
        let reload = [submitter, Some(form)].into_iter().flatten().any(|node| reloads(&engine.dom, node));
        let enctype = of("enctype", "formenctype").to_ascii_lowercase();
        // A form with files (D-054, D-139): its fields and files as `multipart/form-data`.
        let (content_type, body) = if enctype == "multipart/form-data" { crate::controls::multipart(&parts, &crate::controls::boundary()) } else { ("application/x-www-form-urlencoded".to_string(), fields.clone()) };
        match key {
            Some(key) if !reload && enctype != "text/plain" => {
                let query = action.split_once('?').map(|(_, query)| query.split('#').next().unwrap_or("").to_string()).unwrap_or_default();
                let input = [query, fields.clone()].into_iter().filter(|part| !part.is_empty()).collect::<Vec<_>>().join("&");
                let plain = !engine.actions.contains_key(&key);
                Some(Submitted::Endpoint { key, url: action, body, content_type, input, plain })
            }
            _ => Some(Submitted::Document(action, body, content_type)),
        }
    });
    enum Submitted {
        Get(String, String),
        Endpoint { key: String, url: String, body: String, content_type: String, input: String, plain: bool },
        Document(String, String, String),
    }
    match found {
        Some(Submitted::Endpoint { key, url, body, content_type, input, plain }) => {
            let url = (url != key).then_some(url);
            send_submission(&key, url, "POST", vec![("content-type".into(), content_type)], &body, &input, false, plain, Some(form));
        }
        Some(Submitted::Get(action, fields)) => {
            let path = action.split(['?', '#']).next().unwrap_or("");
            crate::nav::navigate(&if fields.is_empty() { path.to_string() } else { format!("{path}?{fields}") }, crate::nav::Options { scroll: true, ..Default::default() });
        }
        Some(Submitted::Document(action, body, content_type)) => crate::nav::post(&action, crate::nav::Form { method: "POST".into(), body, content_type }),
        None => {}
    }
}

/// Whether the app says a link or form is the browser's (`data-rocx-reload` on it or above it, but
/// not `"off"`: D-124). A phone has no browser to load it, so it is navigated to all the same.
fn reloads(dom: &Dom, node: NodeId) -> bool {
    let mut at = Some(node);
    while let Some(node) = at {
        if let Some(marked) = dom.attr(node, "data-rocx-reload") {
            return marked != "off";
        }
        at = dom.nodes.get(node).and_then(|node| node.parent);
    }
    false
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
/// A form nothing on the page reads (`plain`) goes as the browser would post it (D-118: `accept:
/// text/html` and `x-rocx-in-place`), answered as a plain form, its redirect followed in place.
fn send_submission(key: &str, url: Option<String>, method: &str, mut headers: Vec<(String, String)>, body: &str, input: &str, json: bool, plain: bool, form: Option<NodeId>) {
    if plain {
        headers.push(("accept".into(), "text/html,application/xhtml+xml,*/*;q=0.8".into()));
        headers.push(("x-rocx-in-place".into(), "1".into()));
    } else {
        headers.push(("accept".into(), "application/json".into()));
        headers.push(("x-rocx-submission".into(), "1".into()));
    }
    let sent = Sent { method: method.to_string(), url, headers, body: if method == "GET" || method == "HEAD" { String::new() } else { body.to_string() } };
    with(|engine| {
        let entry = engine.id();
        let transition = engine.join_transition();
        let navigations = engine.nav.navigations;
        let source = engine.submissions.entry(key.to_string()).or_default();
        source.list.push(Submission { id: entry, state: "pending", input: input.to_string(), json, status: 0, body: String::new(), sent: sent.clone(), transition, plain, form, navigations });
        source.cleared = false;
        engine.submissions_changed(key);
        engine.send(key, entry, sent);
    });
}

/// Sends a submission again (`retry!`, D-054), by its id (0: the latest), with what it sent:
/// pending again, its answer to come. One on its way, or forgotten, isn't.
fn retry_submission(key: &str, id: u64) {
    with(|engine| {
        let transition = engine.transition;
        let Some(source) = engine.submissions.get_mut(key) else { return };
        let cleared = source.cleared;
        let entry = if id == 0 { if cleared { None } else { source.list.last_mut() } } else { source.list.iter_mut().find(|entry| entry.id == id) };
        let Some(entry) = entry else { return };
        if entry.state == "pending" {
            return;
        }
        entry.state = "pending";
        entry.status = 0;
        entry.body.clear();
        let (entry, sent) = (entry.id, entry.sent.clone());
        let navigations = engine.nav.navigations;
        if let Some(found) = engine.submissions.get_mut(key).and_then(|source| source.list.iter_mut().find(|each| each.id == entry)) {
            found.navigations = navigations;
        }
        // Sent again inside a transition (an optimistic write in the same handler): it joins it.
        if transition.is_some() {
            let joined = engine.join_transition();
            if let Some(found) = engine.submissions.get_mut(key).and_then(|source| source.list.iter_mut().find(|each| each.id == entry)) {
                found.transition = joined;
            }
        }
        engine.submissions_changed(key);
        engine.send(key, entry, sent);
    });
}

fn submission_done(key: &str, id: u64, status: u16, body: String) {
    let ended = with(|engine| {
        let source = engine.submissions.get_mut(key)?;
        let entry = source.list.iter_mut().find(|entry| entry.id == id)?;
        entry.state = "done";
        entry.status = status;
        entry.body = body;
        let transition = entry.transition.take();
        engine.submissions_changed(key);
        // The last of its transition's submissions: its optimistic writes are undone.
        let transition = transition?;
        let open = engine.transitions.get_mut(&transition)?;
        open.pending = open.pending.saturating_sub(1);
        (open.pending == 0 && engine.transition != Some(transition)).then_some(transition)
    });
    if let Some(transition) = ended {
        end_transition(transition);
    }
}

/// Reads the page's reads again (Solid Router revalidating after an action), then the submission,
/// if any, is done: every computation that read a GET from the server asks it again, its last
/// value shown meanwhile. With `keys` (`Router.revalidate!`'s, or an answer's
/// `x-rocx-revalidate`, D-054), only the reads of a GET whose URL is one, or begins with one and a
/// `/` or a `?` (`revalidate`).
fn revalidate(then: Finish, keys: Option<Vec<String>>, among: Option<Vec<u64>>) {
    let named = |call: &str| {
        let Some(rest) = call.strip_prefix("GET ") else { return false };
        let Some(keys) = &keys else { return true };
        let url = rest.split('\n').next().unwrap_or(rest);
        keys.iter().any(|wanted| url == wanted || url.starts_with(&format!("{wanted}/")) || url.starts_with(&format!("{wanted}?")))
    };
    let targets = with(|engine| {
        let targets: Vec<u64> = engine.readers.iter().copied().filter(|id| among.as_ref().is_none_or(|among| among.contains(id)) && engine.comps.get(id).is_some_and(|comp| !comp.disposed && comp.calls.keys().any(|call| named(call)))).collect();
        if targets.is_empty() {
            return targets;
        }
        let at = engine.id();
        engine.revalidations.insert(at, Revalidation { left: targets.len(), then: then.clone() });
        for target in &targets {
            if let Some(comp) = engine.comp(*target) {
                comp.revalidating.push(at);
            }
        }
        targets
    });
    if targets.is_empty() {
        finished(then);
        return;
    }
    for target in targets {
        refresh(target);
    }
}

/// A revalidation's reads are in: what it does then.
fn finished(then: Finish) {
    match then {
        Finish::Nothing => {}
        Finish::Result { key, entry, status, body } => {
            let form = with(|engine| engine.submissions.get(&key).and_then(|source| source.list.iter().find(|each| each.id == entry)).and_then(|each| each.form));
            submission_done(&key, entry, status, body);
            emptied(form);
        }
        Finish::Redirected { key, entry, plain } => {
            let form = with(|engine| engine.submissions.get(&key).and_then(|source| source.list.iter().find(|each| each.id == entry)).and_then(|each| each.form));
            submission_done(&key, entry, 200, String::new());
            // Succeeded: its form empty again, unless the page it came back to says it was refused.
            let refused = plain && with(|engine| json::parse(&engine.nav.flash).and_then(|flash| flash.get("status").and_then(Value::as_u64)).unwrap_or(0) >= 400);
            if !refused {
                emptied(form);
            }
            if plain {
                with(|engine| {
                    if let Some(source) = engine.submissions.get_mut(&key) {
                        source.list.retain(|each| each.id != entry);
                    }
                    engine.submissions_changed(&key);
                });
            }
        }
    }
}

/// A form the host sent, emptied once it succeeded (D-122), as `form.reset()` does: what was typed
/// in its fields forgotten, so each shows its `value` again. Not one marked `data-rocx-keep` (on it
/// or above it), nor one gone from the screen.
fn emptied(form: Option<NodeId>) {
    let Some(form) = form else { return };
    with(|engine| {
        if !engine.dom.connected(form) {
            return;
        }
        let mut at = Some(form);
        while let Some(node) = at {
            if engine.dom.attr(node, "data-rocx-keep").is_some() {
                return;
            }
            at = engine.dom.nodes.get(node).and_then(|node| node.parent);
        }
        let mut stack = vec![form];
        while let Some(node) = stack.pop() {
            if matches!(engine.dom.tag(node), Some("input" | "textarea" | "select")) {
                engine.values.remove(&node);
            }
            stack.extend(engine.dom.children(node));
        }
    });
}

/// What failed, shown where `node` is (`failAround`, D-121): the nearest `<Errored>` around it
/// shows its fallback; with none, the log says so.
fn fail_around(node: Option<NodeId>, problem: String) {
    let nearest = with(|engine| {
        let node = node?;
        let mut best: Option<(u64, usize)> = None;
        for (&id, boundary) in &engine.boundaries {
            if boundary.failed.is_some() || !engine.dom.connected(boundary.range.start) {
                continue;
            }
            // Inside: the node is among the range's (its depth below the range's parent says how near).
            let inside = engine.dom.inside(boundary.range);
            let mut depth = 0;
            let mut at = Some(node);
            let mut found = false;
            while let Some(each) = at {
                if inside.contains(&each) {
                    found = true;
                    break;
                }
                depth += 1;
                at = engine.dom.nodes.get(each).and_then(|each| each.parent);
            }
            if found && best.is_none_or(|(_, nearest)| depth < nearest) {
                best = Some((id, depth));
            }
        }
        best.map(|(id, _)| id)
    });
    match nearest {
        Some(boundary) => errored_fail(boundary, problem, None),
        None => log(Level::Error, &format!("rocx: {problem}, and no <Errored> on the page is around the form to show it")),
    }
}

/// A submission answered with a redirect (`sendSubmission`, D-138): where it goes is where the app
/// goes, unless the visitor went elsewhere since it was sent; then what the navigation kept reads
/// again (`submission_redirected`).
fn submission_redirect(key: &str, entry: u64, to: String, keys: Option<Vec<String>>) {
    let (sent_at, plain, navigations, before) = with(|engine| {
        let found = engine.submissions.get(key).and_then(|source| source.list.iter().find(|each| each.id == entry));
        (found.map(|each| each.navigations), found.is_some_and(|each| each.plain), engine.nav.navigations, engine.readers.iter().copied().collect::<Vec<u64>>())
    });
    if sent_at == Some(navigations) {
        crate::nav::follow(&to, crate::nav::After { key: key.to_string(), entry, plain, keys, before });
    } else {
        finished(Finish::Redirected { key: key.to_string(), entry, plain });
    }
}

/// A submission's redirect followed (`nav::follow`, once its page is in): what the page had read
/// before and the navigation didn't read again from its document reads from the server (D-117),
/// every read or the answer's `x-rocx-revalidate` keys; then the submission is done.
pub(crate) fn submission_redirected(key: &str, entry: u64, plain: bool, keys: Option<Vec<String>>, rest: Vec<u64>) {
    revalidate(Finish::Redirected { key: key.to_string(), entry, plain }, keys, Some(rest));
}

// ---- Optimistic values (`create_optimistic!`, D-054) ----

/// An optimistic write: the signal shows it, held (with its value before any, `base`) until its
/// transition ends; the latest held shows (`hold`).
fn hold(signal: u64, value: Callable) {
    with(|engine| {
        let Some(transition) = engine.transition else {
            roc::release(value);
            return;
        };
        let Some(slot) = engine.signals.get_mut(&signal) else {
            roc::release(value);
            return;
        };
        let shown = std::mem::replace(slot, value);
        match engine.held.get_mut(&signal) {
            // `shown` is the latest write, still held.
            Some(held) => held.writes.push((value, transition)),
            None => {
                engine.held.insert(signal, Held { base: shown, writes: vec![(value, transition)] });
            }
        }
        if let Some(open) = engine.transitions.get_mut(&transition)
            && !open.signals.contains(&signal)
        {
            open.signals.push(signal);
        }
        engine.schedule_observers(&Source::Signal(signal));
    });
}

/// A transition is over: its writes are undone, each signal showing the latest still held, or its
/// value before them (`endTransition`).
fn end_transition(transition: u64) {
    with(|engine| {
        let Some(open) = engine.transitions.remove(&transition) else { return };
        if engine.transition == Some(transition) {
            engine.transition = None;
        }
        for signal in open.signals {
            // Gone with its part: its writes were let go of then.
            let Some(mut held) = engine.held.remove(&signal) else { continue };
            let mut kept = Vec::new();
            for (write, of) in held.writes.drain(..) {
                if of == transition {
                    roc::release(write);
                } else {
                    kept.push((write, of));
                }
            }
            let shown = kept.last().map(|(write, _)| *write).unwrap_or(held.base);
            engine.signals.insert(signal, shown);
            if !kept.is_empty() {
                held.writes = kept;
                engine.held.insert(signal, held);
            }
            engine.schedule_observers(&Source::Signal(signal));
        }
    });
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
        finished(revalidation.then);
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

/// A template's state, by its site (D-084, runtime.js's `js_template`): its id times two, plus one
/// once its skeleton is here. Ids start at 1: 0 says "no template".
pub fn template(site: String) -> u32 {
    with(|engine| {
        let next = engine.templates.len();
        let id = *engine.template_ids.entry(site).or_insert(next);
        if id == engine.templates.len() {
            engine.templates.push(None);
        }
        (id * 2 + usize::from(engine.templates[id].is_some())) as u32
    })
}

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
        let mut value = engine.signals.get(&id).copied().ok_or_else(|| "rocx: a signal was read after the part that made it went away".to_string())?;
        engine.track(Source::Signal(id));
        // Inside `update!` (D-094): the handler's own write, not yet applied, if it made one.
        if let Some(handler) = engine.handler()
            && handler.own > 0
            && let Some(written) = own_write(handler, id)
        {
            value = written;
        }
        Ok(roc::retain(value))
    })
}

/// The value a handler's latest write to a signal gave it, not yet applied (an optimistic write's
/// too); none if it wrote none.
fn own_write(handler: &Handler, id: u64) -> Option<Callable> {
    handler.writes.iter().rev().find_map(|write| match write {
        Write::Signal(signal, written) | Write::Optimistic(signal, written) if *signal == id => Some(*written),
        _ => None,
    })
}

/// `Solid.update!` (D-094): the running handler's reads of signals give its own writes from on to
/// off. Only a handler writes, so anywhere else there is nothing to give.
pub fn own_writes(on: bool) {
    with(|engine| {
        if let Some(handler) = engine.handler() {
            handler.own = if on { handler.own + 1 } else { handler.own.saturating_sub(1) };
        }
    });
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

/// A selector (`create_selector!`): its computation, run now and again when what it reads changes.
pub fn selector_new(runner: Callable) -> u64 {
    let id = with(|engine| {
        engine.touch(false);
        let owner = match engine.current {
            Some(Current::Comp(id)) => Some(id),
            _ => None,
        };
        let scope = engine.current_scope();
        engine.new_comp(CompKind::Selector, runner, owner, scope, Target::None, "")
    });
    run(id);
    id
}

/// Whether `key` is the selector's key, tracked by that key alone; waits while the selector does.
pub fn selector_is(id: u64, key: String) -> Result<bool, Abort> {
    with(|engine| {
        engine.touch(true);
        let Some(selector) = engine.comps.get(&id) else { return Err(Abort::Failed("rocx: a selector was read after the part that made it went away".into(), None)) };
        let answer = selector.holds.as_ref().map(|held| *held == key);
        engine.track(Source::Selector(id, key));
        answer.ok_or(Abort::Wait(Wait::Memo(id)))
    })
}

/// The running memo's new value; `same`: a store's selection whose part is what it was (D-053), so
/// its readers aren't told.
pub fn memo_done(value: Callable, same: bool) {
    with(|engine| {
        if let Some(Current::Comp(id)) = engine.current
            && let Some(comp) = engine.comps.get_mut(&id)
        {
            let old = std::mem::replace(&mut comp.next, value);
            roc::release(old);
            comp.same = same;
            return;
        }
        roc::release(value);
    });
}

/// Whether the running computation tracks its reads, and so runs again when they change: a
/// store's selection is made only then (`tracking!`, D-053).
pub fn tracking() -> bool {
    with(|engine| match engine.current {
        Some(Current::Comp(id)) => engine.comps.get(&id).is_some_and(|comp| !comp.untracked && comp.kind != CompKind::Component && comp.making.as_ref().is_some_and(|making| making.untracked == 0)),
        _ => false,
    })
}

/// The running memo's value, for a store's selection to compare its new one with, or `fallback`
/// when it has none yet (or failed) (`memo_last!`, D-053).
pub fn memo_last(fallback: Callable) -> Callable {
    with(|engine| {
        let last = match engine.current {
            Some(Current::Comp(id)) => engine.comps.get(&id).filter(|comp| comp.kind == CompKind::Memo && comp.state == MemoState::Ok && !comp.value.is_null()).map(|comp| comp.value),
            _ => None,
        };
        match last {
            Some(value) => {
                roc::release(fallback);
                roc::retain(value)
            }
            None => fallback,
        }
    })
}

/// A signal's value with the running handler's own write, not yet applied, if it made one: a
/// store's setter starts from it, so two in one handler compose (`signal_latest!`, D-053).
/// Untracked.
pub fn signal_latest(id: u64) -> Result<Callable, String> {
    with(|engine| {
        let mut value = engine.signals.get(&id).copied().ok_or_else(|| "rocx: a signal was read after the part that made it went away".to_string())?;
        if let Some(written) = engine.handler().and_then(|handler| own_write(handler, id)) {
            value = written;
        }
        Ok(roc::retain(value))
    })
}

/// `create_optimistic!`'s write (D-054): applied with the handler's writes, held by their
/// transition.
pub fn optimistic_set(id: u64, value: Callable) -> Result<(), Callable> {
    with(|engine| match engine.handler() {
        Some(handler) => {
            handler.writes.push(Write::Optimistic(id, value));
            Ok(())
        }
        None => Err(value),
    })
}

/// `Router.revalidate!` in a handler (D-054): the reads of those URLs read again once it is done.
pub fn revalidate_keys(keys: String) -> Result<(), String> {
    let keys = json::parse(&keys).and_then(Value::into_strings).ok_or_else(|| format!("Router.revalidate!: not a list of strings: {keys}"))?;
    with(|engine| match engine.handler() {
        Some(handler) => {
            handler.writes.push(Write::Revalidate(keys));
            Ok(())
        }
        None => Err("Router.revalidate! reads again from a handler (an event, a timer, an effect's apply), not while computing".into()),
    })
}

/// `Router.navigate!` (D-040), from a handler: once it is done, as its writes are (`js_navigate`).
pub fn navigate(to: String, replace: bool, scroll: bool) -> Result<(), String> {
    with(|engine| match engine.handler() {
        Some(handler) => {
            handler.writes.push(Write::Navigate { to, replace, scroll });
            Ok(())
        }
        None => Err(format!("Router.navigate!(\"{to}\") is a handler's: call it from an event, a timer or an effect's apply, not while computing (render <Navigate> to send the visitor elsewhere as a page renders)")),
    })
}

/// `Router.is_routing!`: tracked.
pub fn is_routing() -> bool {
    with(|engine| {
        engine.touch(true);
        engine.track(Source::Routing);
        engine.nav.routing
    })
}

/// `Router.use_before_leave!` (D-040): a listener owned by what is running (it goes when that goes),
/// asked before each navigation and back (`nav::may_leave`).
pub fn before_leave(runner: Callable) -> Result<(), Callable> {
    with(|engine| {
        engine.touch(false);
        let Some(Current::Comp(owner)) = engine.current else { return Err(runner) };
        if engine.comps.get(&owner).is_none_or(|comp| comp.making.is_none()) {
            return Err(runner);
        }
        let kept = engine.keep(runner);
        let id = engine.id();
        let scope = engine.current_scope();
        engine.nav.listeners.push(crate::nav::Listener { id, runner: kept, scope, owner: Some(owner) });
        let _ = engine.push_cleanup(Cleanup::Leave(id));
        Ok(())
    })
}

/// `Leave.retry!`: once the handler is done, as `navigate!` is.
pub fn leave_retry(id: u64, force: bool) -> Result<(), String> {
    with(|engine| match engine.handler() {
        Some(handler) => {
            handler.writes.push(Write::LeaveRetry(id, force));
            Ok(())
        }
        None => Err("Leave.retry! is a handler's: call it from an event, a timer or an effect's apply, not while computing".into()),
    })
}

/// The flash the page came with (`js_flash`): what reads it runs again when a navigation brings
/// another (D-119).
pub fn flash() -> String {
    with(|engine| {
        if let Some(Current::Comp(id)) = engine.current
            && !engine.nav.flash_readers.contains(&id)
        {
            engine.nav.flash_readers.push(id);
        }
        engine.nav.flash.clone()
    })
}

/// `retry!` (D-054): a submission sent again, once the handler is done.
pub fn submission_retry(key: String, id: u64) {
    later(Write::Retried(key, id));
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

/// A row's item; `same`: it is `==` the one the row had (`<For compared>`, D-053), so the row isn't
/// told (it keeps the newest).
pub fn row_set(list: u64, key: String, value: Callable, same: bool) {
    with(|engine| {
        let Some(items) = engine.lists.get_mut(&list).map(|list| &mut list.items) else {
            roc::release(value);
            return;
        };
        match items.insert(key.clone(), value) {
            None => {}
            Some(old) => {
                roc::release(old);
                if !same {
                    engine.schedule_observers(&Source::Item(list, key));
                }
            }
        }
    });
}

/// A row's item, untracked, for a `<For compared>` to compare its new one with, or `fallback` for a
/// new row (`row_last!`, D-053).
pub fn row_last(list: u64, key: String, fallback: Callable) -> Callable {
    with(|engine| match engine.lists.get(&list).and_then(|list| list.items.get(&key).copied()) {
        Some(value) => {
            roc::release(fallback);
            roc::retain(value)
        }
        None => fallback,
    })
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

/// Whether a computation is an `if`'s or `match`'s part picking its branch (D-070), or made by one
/// as it does: up to the first component, which reads for itself (`choosing`).
fn choosing(engine: &Engine, id: u64) -> bool {
    let mut at = Some(id);
    while let Some(id) = at {
        let Some(comp) = engine.comps.get(&id) else { return false };
        if comp.choosing {
            return true;
        }
        if comp.kind == CompKind::Component {
            return false;
        }
        at = comp.owner;
    }
    false
}

/// `Router.location!` (`js_location`): a source the computation reading it tracks, so a navigation
/// runs it again (D-040, D-138). A component's body, or a read inside `untrack!`, reads it once: the
/// level it is in is made anew when it changes (`nav::read_once`).
pub fn location() -> String {
    with(|engine| {
        engine.touch(true);
        engine.track(Source::Location);
        if let Some(Current::Comp(id)) = engine.current
            && let Some(comp) = engine.comps.get(&id)
            && !choosing(engine, id)
            && (comp.kind == CompKind::Component || comp.untracked || comp.making.as_ref().is_some_and(|making| making.untracked > 0))
        {
            let level = comp.scope.level;
            crate::nav::read_once(engine, level);
        }
        engine.path.clone()
    })
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_computed_class_keeps_the_class_names_on_beside_it() {
        // First run: the static `class:name`s fill wrote stay.
        assert_eq!(whole_class("dashed", "", "tile big"), "tile big dashed");
        // A new value: the old one's names go, a `class:name` that is on stays.
        assert_eq!(whole_class("dot waiting on", "dot waiting", "dot out"), "dot out on");
        assert_eq!(whole_class("dot waiting", "dot waiting", "dot waiting"), "dot waiting");
        assert_eq!(whole_class("a on", "a", ""), "on");
    }

    #[test]
    fn a_form_is_an_endpoints_by_its_path() {
        let posts = vec!["/members/join".to_string(), "/lists/[id]".to_string(), "/".to_string()];
        for (action, sent) in [("/members/join", true), ("/members/join?then=%2F", true), ("/lists/7", true), ("/lists/7/tasks", false), ("/lists", false), ("/", true), ("/sign-out", false), ("", false), ("lists/7", false)] {
            assert_eq!(posted_to(&posts, action), sent, "{action:?}");
        }
        assert!(!posted_to(&[], "/members/join"), "no route table: no endpoint");
    }
}
