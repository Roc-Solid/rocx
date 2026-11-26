//! Roc's side of the native host: the memory Roc allocates, what happens when it crashes, and the
//! calls into the app (`mount`, `run`).
//!
//! Every call into Roc is guarded (`guarded`): it runs with a jump target set (`guard.c`, the
//! server's). A hosted function that ends the running computation (a read whose value isn't in yet,
//! a failure) notes why (`abort`) and jumps back to it, as the browser's runtime throws through the
//! wasm frames, and so does a crash (`roc_crashed`). The frames it skips are Roc's and the
//! trampoline's, which hold nothing to drop; a hosted function jumps only once it has let go of
//! what it holds, and never while it borrows the engine.
//!
//! What the skipped Roc frames held is freed as the browser's host frees it (rocx-memory, shared):
//! each call runs in a frame, and one that ends early answers its frame (`Unwound`), which its
//! caller reclaims once it has let go of what the run made.

use crate::abi::{self, RocErasedCallable as Callable, RocHost, RocStr};
use rocx_memory as memory;
use std::cell::RefCell;
use std::ffi::c_void;
use std::ptr::NonNull;

// ---- Memory ----
//
// Roc's memory is rocx-memory's (web/memory, the browser's host's too): each allocation numbered by
// the call into Roc that made it, so what a call that ends early held is freed once the engine has
// let go of what it handed over (`Unwound::reclaim`).

/// How many allocations Roc holds now.
pub fn live_allocations() -> i64 {
    memory::live()
}

/// The host's notes of what runs allocate (0 between runs, unless a run that ended early waits to
/// be reclaimed), and how many allocations Roc has made: for the tests.
pub fn memory_notes() -> (u32, i64) {
    (memory::notes_kept(), memory::allocated())
}

fn out_of_memory() -> ! {
    crate::log(crate::Level::Error, "rocx native: out of memory");
    std::process::abort()
}

fn allocated(ptr: *mut u8) -> NonNull<c_void> {
    NonNull::new(ptr.cast()).unwrap_or_else(|| out_of_memory())
}

fn allocate(length: usize, alignment: usize) -> NonNull<c_void> {
    allocated(memory::alloc_for_roc(length, alignment))
}

fn deallocate(user: *mut c_void, alignment: usize) {
    if !user.is_null() {
        memory::dealloc_for_roc(user.cast(), alignment);
    }
}

fn resize(user: *mut c_void, length: usize, alignment: usize) -> NonNull<c_void> {
    if user.is_null() {
        return allocate(length, alignment);
    }
    allocated(memory::realloc_for_roc(user.cast(), length, alignment))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_alloc(length: usize, alignment: usize) -> NonNull<c_void> {
    allocate(length, alignment)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_dealloc(ptr: *mut c_void, alignment: usize) {
    deallocate(ptr, alignment)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_realloc(ptr: *mut c_void, length: usize, alignment: usize) -> NonNull<c_void> {
    resize(ptr, length, alignment)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_dbg(bytes: *const u8, len: usize) {
    crate::log(crate::Level::Debug, &format!("dbg: {}", text(bytes, len)));
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_expect_failed(bytes: *const u8, len: usize) {
    crate::log(crate::Level::Error, &format!("expect failed: {}", text(bytes, len)));
}

/// A crash ends the call it happened in: it jumps back to the guard, as Roc's ABI asks (it never
/// returns).
#[unsafe(no_mangle)]
pub extern "C" fn roc_crashed(bytes: *const u8, len: usize) {
    let message = text(bytes, len);
    abort(Abort::Crash(message))
}

fn text(bytes: *const u8, len: usize) -> String {
    String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(bytes, len) }).into_owned()
}

extern "C" fn host_alloc(_: *mut RocHost, length: usize, alignment: usize) -> NonNull<c_void> {
    allocate(length, alignment)
}
extern "C" fn host_dealloc(_: *mut RocHost, ptr: *mut c_void, alignment: usize) {
    deallocate(ptr, alignment)
}
extern "C" fn host_realloc(_: *mut RocHost, ptr: *mut c_void, length: usize, alignment: usize) -> NonNull<c_void> {
    resize(ptr, length, alignment)
}
extern "C" fn host_dbg(_: *mut RocHost, bytes: *const u8, len: usize) {
    roc_dbg(bytes, len)
}
extern "C" fn host_expect_failed(_: *mut RocHost, bytes: *const u8, len: usize) {
    roc_expect_failed(bytes, len)
}
extern "C" fn host_crashed(_: *mut RocHost, bytes: *const u8, len: usize) {
    roc_crashed(bytes, len)
}

/// The context the glue's helpers take (`RocStr::from_str`, `decref`): the same allocator.
pub fn host() -> RocHost {
    RocHost {
        env: std::ptr::null_mut(),
        roc_alloc: host_alloc,
        roc_dealloc: host_dealloc,
        roc_realloc: host_realloc,
        roc_dbg: host_dbg,
        roc_expect_failed: host_expect_failed,
        roc_crashed: host_crashed,
    }
}

/// A Str for Roc, its one reference Roc's.
pub fn given(text: &str) -> RocStr {
    RocStr::from_str(text, &host())
}

/// A Str Roc gave a hosted function, copied, and let go of.
pub fn taken(text: RocStr) -> String {
    let copy = text.as_str().to_owned();
    if !in_read_only_data(&text) {
        unsafe { text.decref(&host()) };
    }
    copy
}

/// Whether a Str is a literal in the app's read-only data (its refcount 0: never let go of) that
/// sits at an address no allocation would: what Roc allocates is word-aligned, a literal (the
/// route table `Router.app!` is given, say) needn't be, and the glue's `decref` reads the refcount
/// as an aligned word, which a debug build checks.
fn in_read_only_data(text: &RocStr) -> bool {
    let small = (text.length as isize) < 0;
    let slice = !small && text.capacity_or_alloc_ptr & 1 != 0;
    let allocation = if slice { text.capacity_or_alloc_ptr & !1 } else { text.bytes as usize };
    !small && allocation != 0 && !allocation.is_multiple_of(std::mem::align_of::<usize>())
}

/// Lets go of a reference to a box Roc gave the host.
pub fn release(callable: Callable) {
    if !callable.is_null() {
        unsafe { abi::decref_erased_callable(callable, &host()) }
    }
}

/// Another reference to a box the host holds, for Roc to take.
pub fn retain(callable: Callable) -> Callable {
    unsafe { abi::incref_erased_callable(callable, 1) };
    callable
}

// ---- Calls ----

/// What a read waits for: a request's answer, or a memo's first value.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Wait {
    Request(u64),
    Memo(u64),
}

/// Why a call into Roc ended without an answer: it waits (the browser's `NotReady`), it failed
/// (`Failed`: the nearest <Errored> shows why; a memo's failure names the memo), or Roc crashed.
#[derive(Debug)]
pub enum Abort {
    Wait(Wait),
    Failed(String, Option<u64>),
    Crash(String),
}

unsafe extern "C" {
    fn rocx_guarded(call: extern "C" fn(*mut c_void), data: *mut c_void) -> i32;
    fn rocx_guard_active() -> i32;
    fn rocx_guard_escape() -> !;
}

thread_local! {
    /// Why the call running on this thread is ending, for its guard.
    static ABORT: RefCell<Option<Abort>> = const { RefCell::new(None) };
}

/// Ends the running call into Roc, with why: jumps back to its guard. The calling frame must hold
/// nothing to drop (and no borrow of the engine).
pub fn abort(why: Abort) -> ! {
    if unsafe { rocx_guard_active() } == 0 {
        crate::log(crate::Level::Error, &format!("rocx native: Roc ended outside a call the host guards: {why:?}"));
        std::process::abort();
    }
    ABORT.with(|slot| *slot.borrow_mut() = Some(why));
    unsafe { rocx_guard_escape() }
}

/// A call into Roc that ended early: its frame, whose allocations wait until the engine has let go
/// of everything the run handed it (its computations, signals, boxes), then are freed (`reclaim`).
/// One never reclaimed (a crash) is a leak, never a use after free.
#[must_use]
#[derive(Debug)]
pub struct Unwound(u32);

impl Unwound {
    pub fn reclaim(self) {
        memory::reclaim(self.0)
    }
}

/// Runs `call`, which calls into Roc, guarded and in a frame of its own: its result, or why it
/// ended and its frame.
fn guarded<F: FnOnce() -> R, R>(call: F) -> Result<R, (Abort, Unwound)> {
    struct Slot<F, R> {
        call: Option<F>,
        out: Option<R>,
    }
    extern "C" fn trampoline<F: FnOnce() -> R, R>(data: *mut c_void) {
        let slot = unsafe { &mut *(data as *mut Slot<F, R>) };
        if let Some(call) = slot.call.take() {
            slot.out = Some(call());
        }
    }
    let mut slot = Slot { call: Some(call), out: None };
    let frame = memory::frame_begin();
    let ended = unsafe { rocx_guarded(trampoline::<F, R>, &mut slot as *mut Slot<F, R> as *mut c_void) } != 0;
    if ended {
        memory::frame_unwound(frame);
        let why = ABORT.with(|slot| slot.borrow_mut().take()).unwrap_or_else(|| Abort::Crash("crashed".into()));
        return Err((why, Unwound(frame)));
    }
    memory::frame_end(frame);
    Ok(slot.out.take().expect("a call that returned has its result"))
}

// The app's two entry points: linked in, or, with the `dynamic` feature, found in the app's library
// when it is loaded (`set_entries`, the dev client's).
#[cfg(feature = "dynamic")]
static ENTRIES: std::sync::Mutex<Option<(usize, usize)>> = std::sync::Mutex::new(None);

/// The app's `roc_mount` and `roc_run`, from the library just loaded.
#[cfg(feature = "dynamic")]
pub fn set_entries(mount: usize, run: usize) {
    *ENTRIES.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some((mount, run));
}

#[cfg(feature = "dynamic")]
fn entries() -> (usize, usize) {
    match *ENTRIES.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) {
        Some(entries) => entries,
        None => abort(Abort::Crash("rocx native: no app is loaded".into())),
    }
}

fn call_mount() -> RocStr {
    #[cfg(feature = "dynamic")]
    {
        let mount: extern "C" fn() -> RocStr = unsafe { std::mem::transmute(entries().0) };
        mount()
    }
    #[cfg(not(feature = "dynamic"))]
    unsafe {
        abi::roc_mount()
    }
}

fn call_run(callable: Callable) -> RocStr {
    #[cfg(feature = "dynamic")]
    {
        let run: extern "C" fn(Callable) -> RocStr = unsafe { std::mem::transmute(entries().1) };
        run(callable)
    }
    #[cfg(not(feature = "dynamic"))]
    unsafe {
        abi::roc_run(callable)
    }
}

/// The app's markup (`main!`'s), as JSON, its holes kept by the host.
pub fn mount() -> Result<String, (Abort, Unwound)> {
    let json = guarded(call_mount)?;
    Ok(taken(json))
}

/// Runs a box the host keeps (a computation, a handler, a fallback): its answer, as JSON.
pub fn run(callable: Callable) -> Result<String, (Abort, Unwound)> {
    // `run_for_host!` takes a reference: the host keeps its own.
    retain(callable);
    let json = guarded(|| call_run(callable))?;
    Ok(taken(json))
}
