//! The browser's host for an app's components: Roc's memory, strings in and out, and the hosted
//! functions, each passed through to the JS runtime (web/runtime.js), which keeps the boxes Roc
//! gives it (computations, handlers, values) by their pointers. A JS import may throw (an async
//! read that isn't in yet): the wasm frames above it unwind, so nothing here holds a borrow of the
//! host's state across a call out to JavaScript.
//!
//! No std: what the host needs of memory is rocx-memory's (web/memory, shared with the phone's host):
//! its allocator (Zig's for wasm, ported), and the tracking of what Roc gets of it.

#![no_std]

extern crate alloc;

#[allow(clippy::all, unsafe_op_in_unsafe_fn)]
#[path = "roc_platform_abi.rs"]
mod abi;

use rocx_memory as track;

use abi::{RocErasedCallable as Callable, RocHost, RocStr};
use core::cell::UnsafeCell;
use core::ffi::c_void;
use core::ptr::NonNull;

#[global_allocator]
static MEMORY: rocx_memory::brk::Memory = rocx_memory::brk::Memory;

/// The host's state, one of each: the wasm is single-threaded, and a call into it runs to its end
/// or throws (no state is borrowed across a call out).
pub(crate) struct Global<T>(UnsafeCell<T>);

unsafe impl<T> Sync for Global<T> {}

impl<T> Global<T> {
    pub(crate) const fn new(value: T) -> Self {
        Self(UnsafeCell::new(value))
    }

    #[allow(clippy::mut_from_ref)]
    pub(crate) fn get(&self) -> &mut T {
        unsafe { &mut *self.0.get() }
    }
}

#[cfg_attr(target_arch = "wasm32", link(wasm_import_module = "env"))]
unsafe extern "C" {
    fn js_log(ptr: *const u8, len: usize);
    fn js_crashed(ptr: *const u8, len: usize);
    /// The bytes of the text the last import answered with, its length then: `js_take`.
    fn js_take(dest: *mut u8);
    fn js_keep(callable: usize) -> u32;
    fn js_signal_new(value: usize) -> u32;
    fn js_signal_get(id: u32) -> usize;
    fn js_signal_set(id: u32, value: usize);
    fn js_memo_new(run: usize) -> u32;
    fn js_memo_done(value: usize, same: u32);
    fn js_memo_get(id: u32) -> usize;
    fn js_selector_new(run: usize) -> u32;
    fn js_selector_is(id: u32, ptr: *const u8, len: usize) -> u32;
    fn js_template(ptr: *const u8, len: usize) -> u32;
    fn js_refresh(probe: usize);
    fn js_is_pending(probe: usize) -> u32;
    fn js_fail(ptr: *const u8, len: usize);
    fn js_event_value() -> usize;
    fn js_boundary() -> u32;
    fn js_problem() -> usize;
    fn js_retry(id: u32);
    fn js_request() -> usize;
    fn js_for_new() -> u32;
    fn js_row_index(id: u32, key_ptr: *const u8, key_len: usize) -> u32;
    fn js_row_set(id: u32, key_ptr: *const u8, key_len: usize, value: usize, same: u32) -> u32;
    fn js_row_last(id: u32, key_ptr: *const u8, key_len: usize) -> usize;
    fn js_row_get(id: u32, key_ptr: *const u8, key_len: usize) -> usize;
    fn js_context_value(value: usize) -> u32;
    fn js_context_find(name_ptr: *const u8, name_len: usize) -> u32;
    fn js_context_get(id: u32) -> usize;
    #[allow(clippy::too_many_arguments)]
    fn js_fetch(
        method_ptr: *const u8,
        method_len: usize,
        url_ptr: *const u8,
        url_len: usize,
        headers_ptr: *const u8,
        headers_len: usize,
        body_ptr: *const u8,
        body_len: usize,
    ) -> usize;
    /// Throws what the last `js_fetch` that answered `WAITS` would have: its caller waits, or fails.
    fn js_waits();
    fn js_listen(url_ptr: *const u8, url_len: usize, handler: usize);
    fn js_subscribe(url_ptr: *const u8, url_len: usize, handler: usize);
    fn js_say(url_ptr: *const u8, url_len: usize, said_ptr: *const u8, said_len: usize);
    fn js_resync(url_ptr: *const u8, url_len: usize);
    fn js_live_publish(topic_ptr: *const u8, topic_len: usize, message_ptr: *const u8, message_len: usize);
    fn js_timer(ms: u32, repeat: u32, handler: usize) -> u32;
    fn js_clear_timer(id: u32);
    fn js_browser_call(name_ptr: *const u8, name_len: usize, arg_ptr: *const u8, arg_len: usize);
    fn js_location() -> usize;
    fn js_app(build_ptr: *const u8, build_len: usize, dev: u32, routes_ptr: *const u8, routes_len: usize);
    fn js_navigate(to_ptr: *const u8, to_len: usize, replace: u32, scroll: u32);
    fn js_is_routing() -> u32;
    fn js_before_leave(callable: usize);
    fn js_leave_prevent(id: u32);
    fn js_leave_retry(id: u32, force: u32);
    fn js_status(code: u32);
    fn js_effect_new(callable: usize);
    fn js_cleanup(callable: usize);
    fn js_flash(ptr: *const u8, len: usize) -> usize;
    fn js_action(ptr: *const u8, len: usize);
    fn js_submission(ptr: *const u8, len: usize) -> usize;
    fn js_submission_clear(ptr: *const u8, len: usize);
    fn js_submissions(ptr: *const u8, len: usize) -> usize;
    #[allow(clippy::too_many_arguments)]
    fn js_submit(
        method_ptr: *const u8,
        method_len: usize,
        url_ptr: *const u8,
        url_len: usize,
        body_ptr: *const u8,
        body_len: usize,
        input_ptr: *const u8,
        input_len: usize,
    );
    fn js_submission_drop(ptr: *const u8, len: usize, id: u32);
    fn js_title(ptr: *const u8, len: usize);
    fn js_head(key_ptr: *const u8, key_len: usize, markup_ptr: *const u8, markup_len: usize);
    fn js_revalidate(ptr: *const u8, len: usize);
    fn js_submission_retry(ptr: *const u8, len: usize, id: u32);
    fn js_optimistic_set(id: u32, value: usize);
    fn js_untrack(on: u32);
    fn js_effect_options(render: u32, error_box: u32);
    fn js_read_at(ptr: *const u8, len: usize) -> usize;
    fn js_tracking() -> u32;
    fn js_memo_last() -> usize;
    fn js_signal_latest(id: u32) -> usize;
    /// `Date.now()`, and `performance.timeOrigin + performance.now()`: milliseconds, as JS has them.
    fn js_now_millis() -> f64;
    fn js_now_precise() -> f64;
}

/// What the glue's helpers (a string's `decref`, a box's) call for memory: the host's own, tracked.
fn host() -> RocHost {
    RocHost {
        env: core::ptr::null_mut(),
        roc_alloc: host_alloc,
        roc_dealloc: host_dealloc,
        roc_realloc: host_realloc,
        roc_dbg: host_log,
        roc_expect_failed: host_log,
        roc_crashed: host_crashed,
    }
}

extern "C" fn host_alloc(_: *mut RocHost, length: usize, alignment: usize) -> NonNull<c_void> {
    roc_alloc(length, alignment)
}

extern "C" fn host_dealloc(_: *mut RocHost, ptr: *mut c_void, alignment: usize) {
    roc_dealloc(ptr, alignment)
}

extern "C" fn host_realloc(_: *mut RocHost, ptr: *mut c_void, new_length: usize, alignment: usize) -> NonNull<c_void> {
    roc_realloc(ptr, new_length, alignment)
}

extern "C" fn host_log(_: *mut RocHost, bytes: *const u8, len: usize) {
    roc_dbg(bytes, len)
}

extern "C" fn host_crashed(_: *mut RocHost, bytes: *const u8, len: usize) {
    roc_crashed(bytes, len)
}

/// A crash: the runtime is told (it throws), and the wasm stops if it didn't.
pub(crate) fn crashed(why: &[u8]) -> ! {
    unsafe { js_crashed(why.as_ptr(), why.len()) };
    trap()
}

fn trap() -> ! {
    #[cfg(target_arch = "wasm32")]
    core::arch::wasm32::unreachable();
    #[cfg(not(target_arch = "wasm32"))]
    loop {}
}

#[cfg(not(test))]
#[panic_handler]
fn panic(info: &core::panic::PanicInfo) -> ! {
    crashed(info.message().as_str().unwrap_or("the host panicked").as_bytes())
}

// ---- Roc's memory, and what it reports ----

#[unsafe(no_mangle)]
pub extern "C" fn roc_alloc(length: usize, alignment: usize) -> NonNull<c_void> {
    allocated(track::alloc_for_roc(length, alignment))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_dealloc(ptr: *mut c_void, alignment: usize) {
    track::dealloc_for_roc(ptr.cast(), alignment)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_realloc(ptr: *mut c_void, new_length: usize, alignment: usize) -> NonNull<c_void> {
    allocated(track::realloc_for_roc(ptr.cast(), new_length, alignment))
}

/// What Roc asked for, or the end: Roc writes through it unchecked.
fn allocated(ptr: *mut u8) -> NonNull<c_void> {
    match NonNull::new(ptr.cast()) {
        Some(ptr) => ptr,
        None => crashed(b"roc_alloc: out of memory"),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_dbg(bytes: *const u8, len: usize) {
    unsafe { js_log(bytes, len) }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_expect_failed(bytes: *const u8, len: usize) {
    unsafe { js_log(bytes, len) }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_crashed(bytes: *const u8, len: usize) {
    crashed(unsafe { core::slice::from_raw_parts(bytes, len) })
}

// ---- The runtime's calls: runs, frames, and the last run's answer ----

/// The last run's answer, held until the next replaces it, for the runtime to read.
static RESULT: Global<Option<RocStr>> = Global::new(None);

fn set_result(text: RocStr) {
    if let Some(old) = RESULT.get().take() {
        unsafe { old.decref(&host()) };
    }
    if !text.is_small_str() {
        track::held(string_allocation(&text));
    }
    *RESULT.get() = Some(text);
}

/// Where a (big) string's allocation starts, if it has one: Roc puts a string's bytes a word after
/// its allocation's start (the reference count is between), and a seamless slice names the bytes
/// of the allocation it is in. A string in the module's data has none (track.rs's `marked` says
/// no).
fn string_allocation(text: &RocStr) -> usize {
    let bytes = if text.is_seamless_slice() { text.capacity_or_alloc_ptr & !1 } else { text.bytes as usize };
    bytes.wrapping_sub(size_of::<usize>())
}

/// The app's markup, as JSON: the result.
#[unsafe(no_mangle)]
pub extern "C" fn mount() {
    set_result(unsafe { abi::roc_mount() })
}

/// Runs a box the runtime keeps (it keeps its own reference); the answer is the result.
#[unsafe(no_mangle)]
pub extern "C" fn run(at: usize) {
    let boxed = at as Callable;
    unsafe { abi::incref_erased_callable(boxed, 1) };
    set_result(unsafe { abi::roc_run(boxed) })
}

/// The runtime lets go of a box: Roc releases what it holds when nothing else does.
#[unsafe(no_mangle)]
pub extern "C" fn release(at: usize) {
    unsafe { abi::decref_erased_callable(at as Callable, &host()) }
}

#[unsafe(no_mangle)]
pub extern "C" fn result_ptr() -> u32 {
    match RESULT.get() {
        Some(text) if !text.is_empty() => text.as_slice().as_ptr() as u32,
        _ => 0,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn result_len() -> u32 {
    RESULT.get().as_ref().map_or(0, |text| text.len() as u32)
}

#[unsafe(no_mangle)]
pub extern "C" fn live_allocations() -> i64 {
    // The last run's answer, which the host holds until the next run replaces it, isn't one: what a
    // run answers is JSON, small or not as what it shows is (an `if`'s part's markup, D-070), and a
    // count of what is left over shouldn't change with which run came last.
    let held = RESULT.get().as_ref().is_some_and(|text| !text.is_small_str());
    track::live() - held as i64
}

/// For the tests: the host's notes of what runs allocate, as counts that don't vary with the
/// machine: how many it keeps (0 between runs, unless an unwound run waits for `reclaim`), and the
/// room it keeps for them (a big run's given back when it is done).
#[unsafe(no_mangle)]
pub extern "C" fn notes_kept() -> u32 {
    track::notes_kept()
}

#[unsafe(no_mangle)]
pub extern "C" fn notes_room() -> u32 {
    track::notes_room()
}

/// How many allocations Roc has made since the module started: the tests' measure of what a change
/// allocates.
#[unsafe(no_mangle)]
pub extern "C" fn allocations() -> i64 {
    track::allocated()
}

#[unsafe(no_mangle)]
pub extern "C" fn frame_begin() -> u32 {
    track::frame_begin()
}

#[unsafe(no_mangle)]
pub extern "C" fn frame_end(id: u32) {
    track::frame_end(id)
}

#[unsafe(no_mangle)]
pub extern "C" fn frame_unwound(id: u32) {
    track::frame_unwound(id)
}

#[unsafe(no_mangle)]
pub extern "C" fn reclaim(id: u32) {
    track::reclaim(id)
}

// ---- Strings and boxes across ----

/// The text the last import answered with, `len` bytes, as a Roc string: written by the runtime
/// straight into the string's own bytes.
fn taken(len: usize) -> RocStr {
    const SMALL: usize = size_of::<RocStr>();
    if len < SMALL {
        let mut text = RocStr::empty();
        let bytes = &mut text as *mut RocStr as *mut u8;
        unsafe {
            if len > 0 {
                js_take(bytes);
            }
            *bytes.add(SMALL - 1) = len as u8 | 0x80;
        }
        return text;
    }
    // A big string: its reference count (1), then its bytes.
    let word = size_of::<usize>();
    let base = allocated(track::alloc_for_roc(word + len, align_of::<usize>())).as_ptr().cast::<u8>();
    unsafe {
        let bytes = base.add(word);
        *(base as *mut isize) = 1;
        js_take(bytes);
        RocStr { bytes, capacity_or_alloc_ptr: len << 1, length: len }
    }
}

/// A box handed to the runtime: noted in the innermost frame open (track.rs's `reclaim`).
fn address(boxed: Callable) -> usize {
    let at = boxed as usize;
    if at != 0 {
        track::hand(at);
    }
    at
}

/// A box the runtime keeps, given to Roc: a new reference.
fn given(at: usize) -> Callable {
    let value = at as Callable;
    unsafe { abi::incref_erased_callable(value, 1) };
    value
}

/// A string Roc gave the host, let go of.
fn drop_str(text: RocStr) {
    unsafe { text.decref(&host()) }
}

/// A string's bytes, for a call out.
fn parts(text: &RocStr) -> (*const u8, usize) {
    let bytes = text.as_slice();
    (bytes.as_ptr(), bytes.len())
}

// ---- Hosted: each passes to the runtime. A box given to the runtime is the runtime's reference;
// a box given back to Roc is a new one. A string argument is let go of once the call out returns
// (one that throws skips it, as Zig's defers were skipped). ----

#[unsafe(no_mangle)]
pub extern "C" fn roc_keep(run_it: Callable) -> u64 {
    unsafe { js_keep(address(run_it)) as u64 }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_signal_new(value: Callable) -> u64 {
    unsafe { js_signal_new(address(value)) as u64 }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_signal_get(id: u64) -> Callable {
    given(unsafe { js_signal_get(id as u32) })
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_signal_set(id: u64, value: Callable) {
    unsafe { js_signal_set(id as u32, address(value)) }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_memo_new(run_it: Callable) -> u64 {
    unsafe { js_memo_new(address(run_it)) as u64 }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_memo_done(value: Callable, same: bool) {
    unsafe { js_memo_done(address(value), same as u32) }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_memo_get(id: u64) -> Callable {
    given(unsafe { js_memo_get(id as u32) })
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_selector_new(run_it: Callable) -> u64 {
    unsafe { js_selector_new(address(run_it)) as u64 }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_selector_is(id: u64, key: RocStr) -> bool {
    let (ptr, len) = parts(&key);
    let is = unsafe { js_selector_is(id as u32, ptr, len) } != 0;
    drop_str(key);
    is
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_template(site: RocStr) -> u32 {
    let (ptr, len) = parts(&site);
    let id = unsafe { js_template(ptr, len) };
    drop_str(site);
    id
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_refresh(probe: Callable) {
    unsafe { js_refresh(address(probe)) }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_is_pending(probe: Callable) -> bool {
    unsafe { js_is_pending(address(probe)) != 0 }
}

/// Fails the running read: the runtime throws, so `why` is never let go of here.
#[unsafe(no_mangle)]
pub extern "C" fn roc_fail(why: RocStr) {
    let (ptr, len) = parts(&why);
    unsafe { js_fail(ptr, len) }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_event_value() -> RocStr {
    taken(unsafe { js_event_value() })
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_boundary() -> u64 {
    unsafe { js_boundary() as u64 }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_problem() -> RocStr {
    taken(unsafe { js_problem() })
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_retry(id: u64) {
    unsafe { js_retry(id as u32) }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_request() -> RocStr {
    taken(unsafe { js_request() })
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_for_new() -> u64 {
    unsafe { js_for_new() as u64 }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_row_index(id: u64, key: RocStr) -> u64 {
    let (ptr, len) = parts(&key);
    let index = unsafe { js_row_index(id as u32, ptr, len) };
    drop_str(key);
    index as u64
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_row_set(id: u64, key: RocStr, value: Callable, same: bool) -> bool {
    let (ptr, len) = parts(&key);
    let changed = unsafe { js_row_set(id as u32, ptr, len, address(value), same as u32) } != 0;
    drop_str(key);
    changed
}

/// A row's item, a new reference, or `fallback` (given back) for a row not there yet (D-053).
#[unsafe(no_mangle)]
pub extern "C" fn roc_row_last(id: u64, key: RocStr, fallback: Callable) -> Callable {
    let (ptr, len) = parts(&key);
    let at = unsafe { js_row_last(id as u32, ptr, len) };
    drop_str(key);
    or_fallback(at, fallback)
}

/// The runtime's value at `at` (a new reference), or `fallback` when it has none (0).
fn or_fallback(at: usize, fallback: Callable) -> Callable {
    if at == 0 {
        return fallback;
    }
    unsafe { abi::decref_erased_callable(fallback, &host()) };
    given(at)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_row_get(id: u64, key: RocStr) -> Callable {
    let (ptr, len) = parts(&key);
    let at = unsafe { js_row_get(id as u32, ptr, len) };
    drop_str(key);
    given(at)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_context_value(value: Callable) -> u64 {
    unsafe { js_context_value(address(value)) as u64 }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_context_find(name: RocStr) -> u64 {
    let (ptr, len) = parts(&name);
    let id = unsafe { js_context_find(ptr, len) };
    drop_str(name);
    id as u64
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_context_get(id: u64) -> Callable {
    given(unsafe { js_context_get(id as u32) })
}

/// What `js_fetch` answers for a request that unwinds its caller (`js_waits` throws why).
const WAITS: usize = usize::MAX;

/// A request's answer. One that isn't in yet (or failed) unwinds the caller, by a JS throw: the
/// runtime answers `WAITS`, and throws (`js_waits`) only once the arguments are let go of.
#[unsafe(no_mangle)]
pub extern "C" fn roc_fetch(method: RocStr, url: RocStr, headers: RocStr, body: RocStr) -> RocStr {
    let (m, m_len) = parts(&method);
    let (u, u_len) = parts(&url);
    let (h, h_len) = parts(&headers);
    let (b, b_len) = parts(&body);
    let length = unsafe { js_fetch(m, m_len, u, u_len, h, h_len, b, b_len) };
    for text in [method, url, headers, body] {
        drop_str(text);
    }
    if length == WAITS {
        unsafe { js_waits() };
    }
    taken(length)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_listen(url: RocStr, handler: Callable) {
    let (ptr, len) = parts(&url);
    unsafe { js_listen(ptr, len, address(handler)) };
    drop_str(url);
}

// Channels: the runtime's hub, one stream for the tab (`/rocx/live`), keeps each subscription's
// handler until its owner is cleaned up; what is said goes with the frame's other sayings.
// Publishing is the server's: the runtime fails it.

#[unsafe(no_mangle)]
pub extern "C" fn roc_subscribe(url: RocStr, handler: Callable) {
    let (ptr, len) = parts(&url);
    unsafe { js_subscribe(ptr, len, address(handler)) };
    drop_str(url);
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_say(url: RocStr, said: RocStr) {
    let (u, u_len) = parts(&url);
    let (s, s_len) = parts(&said);
    unsafe { js_say(u, u_len, s, s_len) };
    drop_str(url);
    drop_str(said);
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_resync(url: RocStr) {
    let (ptr, len) = parts(&url);
    unsafe { js_resync(ptr, len) };
    drop_str(url);
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_live_publish(topic: RocStr, message: RocStr) {
    let (t, t_len) = parts(&topic);
    let (m, m_len) = parts(&message);
    unsafe { js_live_publish(t, t_len, m, m_len) };
    drop_str(topic);
    drop_str(message);
}

// A component's timers: the browser's (setTimeout, setInterval), its handler kept by the runtime
// until it is cleared, done, or what made it goes. A wait longer than the browser's (2^31 - 1 ms,
// some 24 days) is that long.

fn timer_ms(ms: u64) -> u32 {
    ms.min(i32::MAX as u64) as u32
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_timeout(ms: u64, handler: Callable) -> u64 {
    unsafe { js_timer(timer_ms(ms), 0, address(handler)) as u64 }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_interval(ms: u64, handler: Callable) -> u64 {
    unsafe { js_timer(timer_ms(ms), 1, address(handler)) as u64 }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_clear_timer(id: u64) {
    unsafe { js_clear_timer(id as u32) }
}

/// A call of the page's own function (`Browser.call!`): the runtime queues it on the handler
/// running, and calls it once the page is patched; anywhere else it throws, and the frames above
/// unwind.
#[unsafe(no_mangle)]
pub extern "C" fn roc_browser_call(name: RocStr, arg: RocStr) {
    let (n, n_len) = parts(&name);
    let (a, a_len) = parts(&arg);
    unsafe { js_browser_call(n, n_len, a, a_len) };
    drop_str(name);
    drop_str(arg);
}

// The page's location and status: the runtime's, which keeps them while it renders as a server
// would (in Node), and gives the browser's location.

#[unsafe(no_mangle)]
pub extern "C" fn roc_location() -> RocStr {
    taken(unsafe { js_location() })
}

/// The app, as its root renders (`Router.app!`, D-040): its build's id, whether it is a dev build,
/// and its route table, the runtime's to keep.
#[unsafe(no_mangle)]
pub extern "C" fn roc_app(build: RocStr, dev: bool, routes: RocStr) {
    let (b, b_len) = parts(&build);
    let (r, r_len) = parts(&routes);
    unsafe { js_app(b, b_len, dev as u32, r, r_len) };
    drop_str(build);
    drop_str(routes);
}

/// `Router.navigate!`: queued on the handler running, as a `Browser.call!` is; anywhere else it
/// throws, and the frames above unwind.
#[unsafe(no_mangle)]
pub extern "C" fn roc_navigate(to: RocStr, replace: bool, scroll: bool) {
    let (ptr, len) = parts(&to);
    unsafe { js_navigate(ptr, len, replace as u32, scroll as u32) };
    drop_str(to);
}

/// `Router.is_routing!`: whether a navigation in place is on its way (tracked).
#[unsafe(no_mangle)]
pub extern "C" fn roc_is_routing() -> bool {
    unsafe { js_is_routing() != 0 }
}

/// `Router.use_before_leave!`: the runtime keeps the listener, owned by what is running; a leave
/// stopped while its listeners are asked, or navigated to after all, by its id.
#[unsafe(no_mangle)]
pub extern "C" fn roc_before_leave(listener: Callable) {
    unsafe { js_before_leave(address(listener)) }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_leave_prevent(id: u64) {
    unsafe { js_leave_prevent(id as u32) }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_leave_retry(id: u64, force: bool) {
    unsafe { js_leave_retry(id as u32, force as u32) }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_status(code: u16) {
    unsafe { js_status(code as u32) }
}

// Effects and cleanups: the runtime keeps their boxes, owned by what is running.

#[unsafe(no_mangle)]
pub extern "C" fn roc_effect_new(run_it: Callable) {
    unsafe { js_effect_new(address(run_it)) }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_cleanup(run_it: Callable) {
    unsafe { js_cleanup(address(run_it)) }
}

// A plain form's flash, and the runtime's form submissions.

#[unsafe(no_mangle)]
pub extern "C" fn roc_flash(found: RocStr) -> RocStr {
    let (ptr, len) = parts(&found);
    let length = unsafe { js_flash(ptr, len) };
    drop_str(found);
    taken(length)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_action(url: RocStr) {
    let (ptr, len) = parts(&url);
    unsafe { js_action(ptr, len) };
    drop_str(url);
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_submission(url: RocStr) -> RocStr {
    let (ptr, len) = parts(&url);
    let length = unsafe { js_submission(ptr, len) };
    drop_str(url);
    taken(length)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_submission_clear(url: RocStr) {
    let (ptr, len) = parts(&url);
    unsafe { js_submission_clear(ptr, len) };
    drop_str(url);
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_submissions(url: RocStr) -> RocStr {
    let (ptr, len) = parts(&url);
    let length = unsafe { js_submissions(ptr, len) };
    drop_str(url);
    taken(length)
}

/// An action (`Router.use_action!`): its method, URL, body, and what it sent, as JSON.
#[unsafe(no_mangle)]
pub extern "C" fn roc_submit(method: RocStr, url: RocStr, body: RocStr, input: RocStr) {
    let (m, m_len) = parts(&method);
    let (u, u_len) = parts(&url);
    let (b, b_len) = parts(&body);
    let (i, i_len) = parts(&input);
    unsafe { js_submit(m, m_len, u, u_len, b, b_len, i, i_len) };
    for text in [method, url, body, input] {
        drop_str(text);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_submission_drop(url: RocStr, id: u64) {
    let (ptr, len) = parts(&url);
    unsafe { js_submission_drop(ptr, len, id as u32) };
    drop_str(url);
}

/// The document's title, as a `<Title>`'s hole says it: the runtime's, which keeps the last one
/// rendered that is still there as `document.title` (or, rendering as a server would, the page's).
#[unsafe(no_mangle)]
pub extern "C" fn roc_title(title: RocStr) {
    let (ptr, len) = parts(&title);
    unsafe { js_title(ptr, len) };
    drop_str(title);
}

/// A `<Meta>`, `<Link>` or `<Style>`'s hole: its key and markup, the runtime's to keep in `<head>`
/// while the hole is there (or, rendering as a server would, the page's).
#[unsafe(no_mangle)]
pub extern "C" fn roc_head(key: RocStr, markup: RocStr) {
    let (k, k_len) = parts(&key);
    let (m, m_len) = parts(&markup);
    unsafe { js_head(k, k_len, m, m_len) };
    drop_str(key);
    drop_str(markup);
}

/// `Router.revalidate!`: the reads to read again (JSON), once the handler is done.
#[unsafe(no_mangle)]
pub extern "C" fn roc_revalidate(keys: RocStr) {
    let (ptr, len) = parts(&keys);
    unsafe { js_revalidate(ptr, len) };
    drop_str(keys);
}

/// `Submission.retry!`, `Submissions.retry!`: a submission sent again, by its id (0, the latest).
#[unsafe(no_mangle)]
pub extern "C" fn roc_submission_retry(url: RocStr, id: u64) {
    let (ptr, len) = parts(&url);
    unsafe { js_submission_retry(ptr, len, id as u32) };
    drop_str(url);
}

/// `create_optimistic!`'s write: a signal's, held until its handler's submissions are done.
#[unsafe(no_mangle)]
pub extern "C" fn roc_optimistic_set(id: u64, value: Callable) {
    unsafe { js_optimistic_set(id as u32, address(value)) }
}

/// `Solid.untrack!`: the running computation's reads untracked from on to off.
#[unsafe(no_mangle)]
pub extern "C" fn roc_untrack(on: bool) {
    unsafe { js_untrack(on as u32) }
}

/// An effect's options (`create_render_effect!`, `create_effect_with!`), told by its compute.
#[unsafe(no_mangle)]
pub extern "C" fn roc_effect_options(render: bool, error_box: u64) {
    unsafe { js_effect_options(render as u32, error_box as u32) }
}

/// Whether the running computation tracks its reads: a store's selection is made only then (D-053).
#[unsafe(no_mangle)]
pub extern "C" fn roc_tracking() -> bool {
    unsafe { js_tracking() != 0 }
}

/// The running memo's value, a new reference, or `fallback` (given back) when it has none yet.
#[unsafe(no_mangle)]
pub extern "C" fn roc_memo_last(fallback: Callable) -> Callable {
    or_fallback(unsafe { js_memo_last() }, fallback)
}

/// A signal's value with the running handler's own write, not yet applied, if it made one.
#[unsafe(no_mangle)]
pub extern "C" fn roc_signal_latest(id: u64) -> Callable {
    given(unsafe { js_signal_latest(id as u32) })
}

/// A dev build's `Html.read_at!`: where a component's body reads, for the runtime's warning; the
/// place before, to put back.
#[unsafe(no_mangle)]
pub extern "C" fn roc_read_at(place: RocStr) -> RocStr {
    let (ptr, len) = parts(&place);
    let length = unsafe { js_read_at(ptr, len) };
    drop_str(place);
    taken(length)
}

// The browser's clock (`Time`): JS's milliseconds, a float, as Roc's whole numbers (`as` truncates
// toward zero, which for a time after 1970 is down).

#[unsafe(no_mangle)]
pub extern "C" fn roc_now_millis() -> u64 {
    unsafe { js_now_millis() }.max(0.0) as u64
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_now_nanos() -> u64 {
    let ms = unsafe { js_now_precise() }.max(0.0);
    let whole = ms as u64;
    whole * 1_000_000 + ((ms - whole as f64) * 1_000_000.0 + 0.5) as u64
}
