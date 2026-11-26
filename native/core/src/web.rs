//! The browser's half (spike/wasm-engine): the engine run in the page's wasm, as the phone runs it,
//! its document's changes sent to the page's JavaScript as one batch of ops a flush (`Dom::ops`),
//! which makes them on the real DOM (web/engine.js). A call into Roc is guarded by a `try` in
//! JavaScript (`js_guarded`), as web/runtime.js guards one: wasm has no setjmp, and a crash or a
//! read that waits ends the call with a throw through the wasm frames (`js_escape`).

use crate::{engine, Level, Platform};
use std::ffi::c_void;
use std::sync::Mutex;
use std::sync::atomic::{AtomicI32, Ordering};

#[link(wasm_import_module = "env")]
unsafe extern "C" {
    fn js_log(level: u32, ptr: *const u8, len: usize);
    fn js_apply(ptr: *const u8, len: usize);
    fn js_guarded(call: usize, data: usize) -> i32;
    fn js_escape() -> !;
}

/// Calls into Roc being run, guarded (`rocx_guarded`, nested).
static DEPTH: AtomicI32 = AtomicI32::new(0);

#[unsafe(no_mangle)]
pub extern "C" fn rocx_guarded(call: extern "C" fn(*mut c_void), data: *mut c_void) -> i32 {
    DEPTH.fetch_add(1, Ordering::Relaxed);
    let ended = unsafe { js_guarded(call as usize, data as usize) };
    DEPTH.fetch_sub(1, Ordering::Relaxed);
    ended
}

#[unsafe(no_mangle)]
pub extern "C" fn rocx_guard_active() -> i32 {
    (DEPTH.load(Ordering::Relaxed) > 0) as i32
}

#[unsafe(no_mangle)]
pub extern "C" fn rocx_guard_escape() -> ! {
    unsafe { js_escape() }
}

/// JavaScript's side of a guard (`js_guarded`): runs `call(data)` inside its `try`.
#[unsafe(no_mangle)]
pub extern "C" fn rocx_call(call: usize, data: usize) {
    let call: extern "C" fn(*mut c_void) = unsafe { std::mem::transmute(call) };
    call(data as *mut c_void);
}

/// Where the page writes text for the engine (a path, an event's name and value).
static SCRATCH: Mutex<Vec<u8>> = Mutex::new(Vec::new());

/// Room for `len` bytes of text from the page: where to write them.
#[unsafe(no_mangle)]
pub extern "C" fn rocx_scratch(len: usize) -> *mut u8 {
    let mut scratch = SCRATCH.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    scratch.resize(len, 0);
    scratch.as_mut_ptr()
}

fn scratch_text(from: usize, len: usize) -> String {
    let scratch = SCRATCH.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    String::from_utf8_lossy(&scratch[from..from + len]).into_owned()
}

/// The page, as the engine's platform: logs, and each flush's ops.
struct Page;

impl Platform for Page {
    fn wake(&self) {}
    fn apply(&self, ops: &[u8]) {
        unsafe { js_apply(ops.as_ptr(), ops.len()) }
    }
    fn log(&self, level: Level, text: &str) {
        let level = match level {
            Level::Debug => 0,
            Level::Info => 1,
            Level::Warn => 2,
            Level::Error => 3,
        };
        unsafe { js_log(level, text.as_ptr(), text.len()) }
    }
}

/// Starts the app at the path the page wrote (`rocx_scratch`, `len` bytes): mounted, its first
/// ops sent.
#[unsafe(no_mangle)]
pub extern "C" fn rocx_start(len: usize) {
    std::panic::set_hook(Box::new(|info| {
        let text = format!("rocx engine panicked: {info}");
        unsafe { js_log(3, text.as_ptr(), text.len()) }
    }));
    let path = scratch_text(0, len);
    crate::start(Box::new(Page), "", &path);
}

/// An event on the engine's node `node` (its name, then its value, in the scratch), handled as the
/// DOM's: from that node up. Then a flush, and its ops.
#[unsafe(no_mangle)]
pub extern "C" fn rocx_event(node: u32, name_len: usize, value_len: usize) {
    let name = scratch_text(0, name_len);
    let value = scratch_text(name_len, value_len);
    engine::dispatch(node as usize, &name, &value);
    crate::pump();
}

/// Each flush's ops, from the engine's document (`Dom::ops`).
pub(crate) fn ops() -> Vec<u8> {
    engine::with(|engine| std::mem::take(&mut engine.dom.ops))
}
