//! The native host's core (D-063's spike): web/platform's hosted functions done natively, the
//! reactive engine (web/runtime.js's, without the DOM), and the app's screen as native views,
//! sent to the phone as one batch of ops a flush (`native.rs`). The phone's half (native/android)
//! gives it a `Platform`: how to wake the main thread, how to apply a batch, where logs go.
//!
//! Everything runs on one thread, the phone's main (UI) thread, as the browser runs the wasm and
//! runtime.js on its main thread: `start`, `event` and `pump` are called there. Requests and timers
//! wait on threads of their own and post what happened (`post`), then wake the main thread, which
//! calls `pump`.

#[allow(clippy::all, unsafe_op_in_unsafe_fn)]
#[path = "roc_platform_abi.rs"]
pub mod abi;
mod calls;
pub mod controls;
pub mod cookies;
pub mod css;
mod dom;
pub mod layout;
pub mod values;
pub mod engine;
mod hosted;
mod fx;
pub mod http;
mod json;
pub mod native;
pub mod live;
pub mod media;
pub mod nav;
pub mod roc;
pub mod svg;
pub mod url;
#[cfg(target_arch = "wasm32")]
mod web;
// In a browser (spike/wasm-engine), the browser's host's allocator (rocx-memory's, Zig's for wasm
// ported): fast and small, where Rust's default for wasm is dlmalloc.
#[cfg(target_arch = "wasm32")]
#[global_allocator]
static MEMORY: rocx_memory::brk::Memory = rocx_memory::brk::Memory;

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level {
    Debug,
    Info,
    Warn,
    Error,
}

/// The phone's half.
pub trait Platform: Send + Sync {
    /// From any thread: call `pump` on the main thread soon.
    fn wake(&self);
    /// On the main thread: one batch of ops (`native.rs`), applied to the native views.
    fn apply(&self, ops: &[u8]);
    fn log(&self, level: Level, text: &str);
    /// On the main thread, once a handler is done: `Browser.call!(name, arg)`'s native half (a
    /// plugin's: `audio.play`, `vibrate.pattern`), `arg` its JSON, `origin` the app's server (a
    /// path in `arg` is the server's). Whether the phone has a handler by that name.
    fn call(&self, _name: &str, _arg: &str, _origin: &str) -> bool {
        false
    }
    /// On the main thread: how far the screen is scrolled now (x, y, in the views' units), kept on
    /// the history entry a navigation leaves (D-138).
    fn scroll(&self) -> (f32, f32) {
        (0.0, 0.0)
    }
    /// On the main thread, after a batch is applied: the screen scrolled there (a navigation's top,
    /// back's kept place).
    fn scroll_to(&self, _x: f32, _y: f32) {}
    /// On the main thread: `url` opened by the system (another site's page in its browser, a
    /// `mailto:` or `tel:` link in its app). Whether it could be.
    fn open(&self, _url: &str) -> bool {
        false
    }
    /// On the main thread: the first of these views there is takes the focus (`Browser.call!`'s
    /// `focus`, `calls.rs`): an element's view, then those above it.
    fn focus(&self, _views: &[u64]) -> bool {
        false
    }
    /// On the main thread: the first of these views there is scrolled into view (`reveal`).
    fn reveal(&self, _views: &[u64]) -> bool {
        false
    }
    /// On the main thread (D-139): the system's file picker opened for file input `view` (its
    /// `accept`, and whether it takes several); what is picked comes back as the view's `files`
    /// event (`[{"name","type","size","path"}]`, each copied into the app's cache), nothing picked
    /// as `cancel`. Whether there is a picker.
    fn pick(&self, _view: u64, _accept: &str, _multiple: bool) -> bool {
        false
    }
    /// On the main thread (D-139): an event on custom element `view` (its `tag`), or on `target`
    /// inside it, for the app's phone half of the element, if it has one (Android's: Kotlin
    /// `ElementHalf`s, `Elements.kt`). `value` is the event's (a file input's files, a field's text).
    fn element(&self, _view: u64, _tag: &str, _event: &str, _target: u64, _value: &str) {}
    /// On the main thread: the answer to the shell's request `token` (`fetch`), or why there is
    /// none (status 0, the reason as the body).
    fn fetched(&self, _token: u64, _status: u16, _headers: &str, _body: &[u8]) {}
    /// On the main thread, while a flush is laid out (D-137): the size of text view `id` (whose
    /// text and look the batch just applied set) at a width, in dp. The Mac's is rough
    /// (`layout::rough_measure`); a phone's is its text engine's.
    fn measure(&self, _id: u64, content: &layout::Content, width: layout::Width) -> (f32, f32) {
        layout::rough_measure(content, width)
    }
    /// The screen's density: its pixels a CSS px (Android's `displayMetrics.density`), which an
    /// `<img>`'s `srcset` is picked by (D-139).
    fn density(&self) -> f32 {
        1.0
    }
    /// Where the app keeps files it can lose (Android's cache dir): images' files (D-139), files
    /// picked for a form. None: the system's temporary directory.
    fn cache_dir(&self) -> Option<String> {
        None
    }
}

/// A batch of ops applied now, in the middle of a render (its views' changes, before their layout
/// measures them).
pub(crate) fn apply_now(ops: &[u8]) {
    if let Some(platform) = PLATFORM.get() {
        platform.apply(ops);
    }
}

/// Text measured by the platform (rough without one: the tests').
pub(crate) struct PlatformMeasurer;

impl layout::Measurer for PlatformMeasurer {
    fn measure(&mut self, id: u64, content: &layout::Content, width: layout::Width) -> (f32, f32) {
        match PLATFORM.get() {
            Some(platform) => platform.measure(id, content, width),
            None => layout::rough_measure(content, width),
        }
    }
}

/// The screen's size in dp (the phone's, less its system bars), at start and whenever it changes
/// (a rotation): media queries and viewport units follow, and the screen is laid out again.
pub fn viewport(width: f32, height: f32) {
    if native::set_viewport(width, height) && engine::started() {
        pump();
    }
}

static PLATFORM: OnceLock<Box<dyn Platform>> = OnceLock::new();

/// What happened on another thread, for the main thread, with the generation of the app it is
/// for (`generation`): one for a build a dev client replaced is dropped.
pub enum Message {
    Answer(u64, u64, Result<http::Answered, String>),
    Fired(u64, u64),
    /// What a stream heard (`http::stream`, D-140).
    Heard(u64, u64, http::Heard),
    /// The wait after the channels' stream dropped is over (D-140).
    Retry(u64),
    /// An image's file is in, or not (D-139).
    Media(u64, media::Loaded),
    /// The answer to a request of the shell's (D-139, `fetch`).
    Fetched(u64, u64, Result<http::Bytes, String>),
}

/// The platform an app's library must be built for (core/build.rs): a dev client refuses another.
pub const FINGERPRINT: &str = env!("ROCX_FINGERPRINT");
/// The Roc compiler the fingerprint names (`roc version`).
pub const ROC_VERSION: &str = env!("ROCX_ROC_VERSION");

/// Which run of the app this is: one more each time a dev client loads a new build (`restart`).
static GENERATION: AtomicU64 = AtomicU64::new(0);

pub fn generation() -> u64 {
    GENERATION.load(Ordering::Relaxed)
}

static INBOX: Mutex<Vec<Message>> = Mutex::new(Vec::new());

pub fn log(level: Level, text: &str) {
    match PLATFORM.get() {
        Some(platform) => platform.log(level, text),
        None => eprintln!("{level:?}: {text}"),
    }
}

/// From any thread: something for the main thread, which is woken.
pub fn post(message: Message) {
    INBOX.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).push(message);
    if let Some(platform) = PLATFORM.get() {
        platform.wake();
    }
}

/// Starts the app: the engine, pointed at the server (`origin`, `http://10.0.2.2:8080`), the app
/// at `path` (`/`): its document asked for, as a browser's first load (D-138: the page's middleware
/// runs, a guard's redirect is followed), and the app mounted once it is in, its screen sent.
pub fn start(platform: Box<dyn Platform>, origin: &str, path: &str) {
    let _ = PLATFORM.set(platform);
    if engine::started() {
        // The activity was made again (a rotation): the screen is sent again, whole.
        native::forget_shown();
        pump();
        return;
    }
    engine::init(origin.to_string(), path.to_string());
    // In a browser (spike/wasm-engine), the page is the document already.
    #[cfg(target_arch = "wasm32")]
    engine::mount();
    #[cfg(not(target_arch = "wasm32"))]
    nav::start(path);
    pump();
}

/// Where the app keeps what outlives its process (the app's files dir: the cookie jar, D-138).
/// Called before `start`.
pub fn files(dir: &str) {
    cookies::keep_in(dir, now_millis());
}

fn now_millis() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|since| since.as_millis() as u64).unwrap_or(0)
}

/// Android's back (the button, the gesture), on the main thread: the history's entry before
/// (D-138), and the screen's changes sent. False at the first entry: the app closes.
pub fn back() -> bool {
    if !engine::started() {
        return false;
    }
    let went = nav::back();
    pump();
    went
}

/// The screen's density (`Platform::density`), asked once.
pub(crate) fn density() -> f32 {
    static DENSITY: OnceLock<f32> = OnceLock::new();
    match PLATFORM.get() {
        Some(platform) => *DENSITY.get_or_init(|| platform.density()),
        None => 1.0,
    }
}

/// Where files that may be lost are kept (`Platform::cache_dir`), asked once.
pub(crate) fn cache_dir() -> Option<String> {
    static CACHE: OnceLock<Option<String>> = OnceLock::new();
    CACHE.get_or_init(|| PLATFORM.get().and_then(|platform| platform.cache_dir())).clone()
}

/// How far the screen is scrolled (`Platform::scroll`).
pub(crate) fn scrolled() -> (f32, f32) {
    PLATFORM.get().map(|platform| platform.scroll()).unwrap_or((0.0, 0.0))
}

/// A view focused (`Platform::focus`).
pub(crate) fn focus(views: &[u64]) -> bool {
    PLATFORM.get().is_some_and(|platform| platform.focus(views))
}

/// An element's phone half told of an event (`Platform::element`).
pub(crate) fn element_event(view: u64, tag: &str, event: &str, target: u64, value: &str) {
    if let Some(platform) = PLATFORM.get() {
        platform.element(view, tag, event, target, value);
    }
}

/// A request of the shell's (D-139: an element's phone half uploading a file), on a thread of its
/// own, as the page's are: its path the app's server's, the app's cookies, `origin` on what isn't
/// a GET. Its answer comes back on the main thread (`Platform::fetched`).
pub fn fetch(token: u64, method: &str, url: &str, headers: &str, body: Vec<u8>) {
    let (full, origin) = engine::with(|engine| (engine.full_url(url), url::Url::parse(&engine.origin).map(|url| url.origin)));
    let mut lines: Vec<(String, String)> = headers.lines().filter_map(|line| line.split_once(':')).map(|(name, value)| (name.trim().to_string(), value.trim().to_string())).collect();
    if !matches!(method, "GET" | "HEAD")
        && let Some(origin) = origin
        && !lines.iter().any(|(name, _)| name.eq_ignore_ascii_case("origin"))
    {
        lines.push(("origin".into(), origin));
    }
    let made = generation();
    let method = method.to_string();
    std::thread::spawn(move || {
        let answer = http::fetch_bytes(&method, &full, &lines, &body, false);
        post(Message::Fetched(made, token, answer));
    });
}

/// A file input's picker opened (`Platform::pick`).
pub(crate) fn pick(view: u64, accept: &str, multiple: bool) -> bool {
    PLATFORM.get().is_some_and(|platform| platform.pick(view, accept, multiple))
}

/// A view scrolled into view (`Platform::reveal`).
pub(crate) fn reveal(views: &[u64]) -> bool {
    PLATFORM.get().is_some_and(|platform| platform.reveal(views))
}

/// `url` opened by the system (`Platform::open`).
pub(crate) fn open(url: &str) -> bool {
    let shown = url.split(['?', '#']).next().unwrap_or(url);
    log(Level::Info, &format!("rocx: opening {shown} elsewhere"));
    PLATFORM.get().is_some_and(|platform| platform.open(url))
}

/// A new build of the app (a dev client's, whose library `roc::set_entries` just named), started
/// afresh as a browser's reload starts a page: the last build's engine let go of (its Roc values
/// never released: their code may be gone, and this is dev's), nothing of its state kept, the new
/// one started at `path`, mounted, and the whole screen sent.
#[cfg(feature = "dynamic")]
pub fn restart(platform: Box<dyn Platform>, origin: &str, path: &str) {
    let _ = PLATFORM.set(platform);
    engine::reset();
    native::forget_shown();
    media::forget();
    GENERATION.fetch_add(1, Ordering::Relaxed);
    INBOX.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clear();
    engine::init(origin.to_string(), path.to_string());
    nav::start(path);
    pump();
}

/// What the phone's shell asks the host (D-139), on the main thread: `cookie` (the jar's `cookie`
/// header for a URL: a video's player sends it), `attr` (`<view id>\n<name>`: an element's attribute
/// as `=<value>`, "" when it has none, for an element's phone half), `tag` (`<view id>`: its tag),
/// `reload` (the page asked for
/// again where it is, a half's `location.reload()`). "" for nothing.
pub fn ask(what: &str, arg: &str) -> String {
    match what {
        "cookie" => cookies::for_request(arg, now_millis()).unwrap_or_default(),
        "attr" => {
            let Some((id, name)) = arg.split_once('\n') else { return String::new() };
            let Some(node) = id.parse::<u64>().ok().and_then(native::node_of) else { return String::new() };
            // `=` and its value; "" when it has none (an empty one is `=`).
            engine::with(|engine| engine.dom.attr(node, name).map(|value| format!("={value}"))).unwrap_or_default()
        }
        // An element's tag (`<view id>`).
        "tag" => {
            let Some(node) = arg.parse::<u64>().ok().and_then(native::node_of) else { return String::new() };
            engine::with(|engine| engine.dom.tag(node).map(str::to_string)).unwrap_or_default()
        }
        // A half's `location.reload()`: the page asked for again where it is.
        "reload" => {
            let path = engine::with(|engine| engine.path.clone());
            nav::navigate(&path, nav::Options { replace: true, ..Default::default() });
            pump();
            String::new()
        }
        _ => String::new(),
    }
}

/// An event on a native view (its id, the event's name, its value), as the DOM's.
pub fn event(id: u64, name: &str, value: &str) {
    // A video's player knows its size (D-139): the element's natural size from now on.
    if name == "loadedmetadata"
        && let Some(src) = native::shown_views().get(&id).and_then(|view| view.props.get("src").cloned())
    {
        media::video_said(&src, value);
        if let Some(node) = native::node_of(id) {
            engine::with(|engine| engine.dom.touch(node));
        }
    }
    if let Some(node) = native::node_of(id) {
        // What the system's picker gave a file input (D-139): what it holds, then its `input` and
        // `change`, given the files as a browser gives them (`Html.File`s).
        if name == "files" {
            let files = controls::picked(node, value);
            engine::dispatch(node, "input", &files);
            engine::dispatch(node, "change", &files);
            pump();
            return;
        }
        native::note(node, name);
        if name == "scroll" {
            native::scrolled(node, value);
        }
        engine::dispatch(node, name, value);
    }
    pump();
}

/// On the main thread: what other threads posted (answers, timers), then a flush, then the
/// screen's changes, sent as one batch.
pub fn pump() {
    let messages = std::mem::take(&mut *INBOX.lock().unwrap_or_else(|poisoned| poisoned.into_inner()));
    let now = generation();
    for message in messages {
        match message {
            Message::Answer(made, id, result) if made == now => engine::answered(id, result),
            Message::Fired(made, id) if made == now => engine::fired(id),
            Message::Heard(made, id, heard) if made == now => live::heard(id, heard),
            Message::Retry(made) if made == now => live::retry(),
            Message::Media(made, loaded) if made == now => media::loaded(loaded),
            Message::Fetched(made, token, answer) if made == now => {
                if let Some(platform) = PLATFORM.get() {
                    match answer {
                        Ok(answer) => {
                            let headers: Vec<String> = answer.headers.iter().map(|(name, value)| format!("{name}: {value}")).collect();
                            platform.fetched(token, answer.status, &headers.join("\n"), &answer.body);
                        }
                        Err(why) => platform.fetched(token, 0, "", why.as_bytes()),
                    }
                }
            }
            _ => {}
        }
    }
    engine::flush();
    engine::with(nav::mark_links);
    engine::send_requests();
    // A page's DOM is changed as the engine's document was (spike/wasm-engine); a phone's views are
    // its projection.
    #[cfg(target_arch = "wasm32")]
    let ops = web::ops();
    #[cfg(not(target_arch = "wasm32"))]
    let ops = native::render();
    // Nodes let go of in this flush are in no render from now on: their ids may be used again.
    engine::with(|engine| engine.dom.recycle());
    // A stylesheet the render found named (`Engine::sheet`).
    engine::send_requests();
    if !ops.is_empty()
        && let Some(platform) = PLATFORM.get()
    {
        platform.apply(&ops);
    }
    // A navigation's scroll, once its views are there (D-138).
    if let Some((x, y)) = engine::with(|engine| engine.nav.scroll_to.take())
        && let Some(platform) = PLATFORM.get()
    {
        platform.scroll_to(x, y);
    }
    live::reconcile();
    // `on:viewport` (D-137): what the layout found changed, told, and the screen made again (a
    // few rounds at most, as a browser's ResizeObserver loop stops).
    let told = native::viewports();
    if !told.is_empty() {
        let depth = VIEWPORT_ROUNDS.fetch_add(1, Ordering::Relaxed);
        if depth < 4 {
            for (node, value) in told {
                engine::fire(node, "viewport", &value);
            }
            pump();
        }
        VIEWPORT_ROUNDS.fetch_sub(1, Ordering::Relaxed);
    }
}

/// How deep `on:viewport`'s rounds of pumps are.
static VIEWPORT_ROUNDS: AtomicU64 = AtomicU64::new(0);

/// A timer's thread: posts `Fired(id)` after `ms`, or every `ms`, until `stop`.
pub(crate) fn timer(id: u64, ms: u64, repeat: bool, stop: Arc<AtomicBool>) {
    let made = generation();
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(std::time::Duration::from_millis(ms.max(1)));
            if stop.load(Ordering::Relaxed) {
                return;
            }
            post(Message::Fired(made, id));
            if !repeat {
                return;
            }
        }
    });
}

/// `Browser.call!(name, arg)`, once the handler is done: the platform's native handler by that
/// name (Android's: `audio.play`, `vibrate.pattern`; native/android/app's `Calls`), else one of the
/// page functions apps commonly register (`calls.rs`: focus, click, reveal, go, replace_query).
/// Any other is logged, as the browser logs an effect no script registered.
pub(crate) fn call_native(name: &str, arg: &str) {
    let origin = engine::with(|engine| engine.origin.clone());
    if PLATFORM.get().is_some_and(|platform| platform.call(name, arg, &origin)) {
        return;
    }
    // The page functions apps commonly register, done on the engine's document (D-138).
    if calls::call(name, arg) {
        return;
    }
    let plugin = name.split_once('.').map(|(plugin, _)| plugin);
    let said = match plugin {
        Some(plugin) => format!("the {plugin} plugin has no native half on this platform"),
        None => "this platform has no native handler by that name".to_string(),
    };
    log(Level::Error, &format!("rocx native: no native handler is called {name}: {said}"));
}
