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
pub mod css;
mod dom;
pub mod engine;
mod hosted;
mod http;
pub mod native;
pub mod roc;

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
}

static PLATFORM: OnceLock<Box<dyn Platform>> = OnceLock::new();

/// What happened on another thread, for the main thread, with the generation of the app it is
/// for (`generation`): one for a build a dev client replaced is dropped.
pub enum Message {
    Answer(u64, u64, Result<(u16, Vec<(String, String)>, String), String>),
    Fired(u64, u64),
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
/// at `path` (`/`), its screen mounted and sent.
pub fn start(platform: Box<dyn Platform>, origin: &str, path: &str) {
    let _ = PLATFORM.set(platform);
    if engine::started() {
        // The activity was made again (a rotation): the screen is sent again, whole.
        native::forget_shown();
        pump();
        return;
    }
    engine::init(origin.to_string(), path.to_string());
    engine::mount();
    pump();
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
    engine::mount();
    pump();
}

/// An event on a native view (its id, the event's name, its value), as the DOM's.
pub fn event(id: u64, name: &str, value: &str) {
    if let Some(node) = native::node_of(id) {
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
            _ => {}
        }
    }
    engine::flush();
    engine::send_requests();
    let ops = native::render();
    if !ops.is_empty()
        && let Some(platform) = PLATFORM.get()
    {
        platform.apply(&ops);
    }
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

/// `Browser.call!(name, arg)`, once the screen is patched: a native handler by that name. None yet
/// (D-063's §10: audio, push, the camera's native halves come later).
pub(crate) fn call_native(name: &str, _arg: &str) {
    let plugin = name.split_once('.').map(|(plugin, _)| plugin);
    let said = match plugin {
        Some(plugin) => format!("the {plugin} plugin has no native half yet"),
        None => "phones have no native handlers yet".to_string(),
    };
    log(Level::Error, &format!("rocx native: no native handler is called {name}: {said}"));
}
