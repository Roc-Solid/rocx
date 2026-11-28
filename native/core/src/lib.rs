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
    /// On the main thread, while a flush is laid out (D-137): the size of text view `id` (whose
    /// text and look the batch just applied set) at a width, in dp. The Mac's is rough
    /// (`layout::rough_measure`); a phone's is its text engine's.
    fn measure(&self, _id: u64, content: &layout::Content, width: layout::Width) -> (f32, f32) {
        layout::rough_measure(content, width)
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

/// How far the screen is scrolled (`Platform::scroll`).
pub(crate) fn scrolled() -> (f32, f32) {
    PLATFORM.get().map(|platform| platform.scroll()).unwrap_or((0.0, 0.0))
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
    GENERATION.fetch_add(1, Ordering::Relaxed);
    INBOX.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clear();
    engine::init(origin.to_string(), path.to_string());
    nav::start(path);
    pump();
}

/// An event on a native view (its id, the event's name, its value), as the DOM's.
pub fn event(id: u64, name: &str, value: &str) {
    if let Some(node) = native::node_of(id) {
        native::note(node, name);
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
}

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
/// name (Android's: `audio.play`, `vibrate.pattern`; native/android/app's `Calls`). One it hasn't
/// is logged, as the browser logs an effect no script registered.
pub(crate) fn call_native(name: &str, arg: &str) {
    let origin = engine::with(|engine| engine.origin.clone());
    if PLATFORM.get().is_some_and(|platform| platform.call(name, arg, &origin)) {
        return;
    }
    let plugin = name.split_once('.').map(|(plugin, _)| plugin);
    let said = match plugin {
        Some(plugin) => format!("the {plugin} plugin has no native half on this platform"),
        None => "this platform has no native handler by that name".to_string(),
    };
    log(Level::Error, &format!("rocx native: no native handler is called {name}: {said}"));
}
