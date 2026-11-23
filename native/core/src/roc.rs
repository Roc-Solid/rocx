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
//! What the skipped Roc frames held is not freed: a run that waits leaks the few values its frames
//! held (the browser's host frees them, `frame_unwound` and `reclaim`; the server's frees a failed
//! run's list). That is the spike's, and the next step (spike/native-apps/README.md).

use crate::abi::{self, RocErasedCallable as Callable, RocHost, RocStr};
use std::alloc::{Layout, alloc, dealloc};
use std::cell::RefCell;
use std::ffi::c_void;
use std::ptr::NonNull;
use std::sync::atomic::{AtomicI64, Ordering};

// ---- Memory ----

/// What precedes each allocation: what `dealloc` needs to free it.
#[repr(C)]
struct Header {
    size: usize,
    align: usize,
}

const HEADER: usize = std::mem::size_of::<Header>();

/// Allocations Roc holds now.
static LIVE: AtomicI64 = AtomicI64::new(0);

/// How many allocations Roc holds now.
pub fn live_allocations() -> i64 {
    LIVE.load(Ordering::Relaxed)
}

fn offset_for(align: usize) -> usize {
    let align = align.max(16);
    (HEADER + align - 1) & !(align - 1)
}

fn out_of_memory() -> ! {
    crate::log(crate::Level::Error, "rocx native: out of memory");
    std::process::abort()
}

fn allocate(length: usize, alignment: usize) -> NonNull<c_void> {
    let align = alignment.max(16);
    let offset = offset_for(align);
    let Some(size) = offset.checked_add(length) else { out_of_memory() };
    let Ok(layout) = Layout::from_size_align(size, align) else { out_of_memory() };
    unsafe {
        let base = alloc(layout);
        if base.is_null() {
            out_of_memory()
        }
        let user = base.add(offset);
        let header = user.sub(HEADER) as *mut Header;
        header.write(Header { size, align });
        LIVE.fetch_add(1, Ordering::Relaxed);
        NonNull::new_unchecked(user as *mut c_void)
    }
}

fn deallocate(user: *mut c_void) {
    if user.is_null() {
        return;
    }
    unsafe {
        let header = (user as *mut u8).sub(HEADER) as *mut Header;
        let Header { size, align } = header.read();
        let base = (user as *mut u8).sub(offset_for(align));
        dealloc(base, Layout::from_size_align_unchecked(size, align));
    }
    LIVE.fetch_sub(1, Ordering::Relaxed);
}

fn resize(user: *mut c_void, length: usize, alignment: usize) -> NonNull<c_void> {
    if user.is_null() {
        return allocate(length, alignment);
    }
    unsafe {
        let header = (user as *mut u8).sub(HEADER) as *mut Header;
        let old = (*header).size - offset_for((*header).align);
        let moved = allocate(length, alignment);
        std::ptr::copy_nonoverlapping(user as *const u8, moved.as_ptr() as *mut u8, old.min(length));
        deallocate(user);
        moved
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_alloc(length: usize, alignment: usize) -> NonNull<c_void> {
    allocate(length, alignment)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_dealloc(ptr: *mut c_void, _alignment: usize) {
    deallocate(ptr)
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
extern "C" fn host_dealloc(_: *mut RocHost, ptr: *mut c_void, _alignment: usize) {
    deallocate(ptr)
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
    unsafe { text.decref(&host()) };
    copy
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

/// Runs `call`, which calls into Roc, guarded: its result, or why it ended.
fn guarded<F: FnOnce() -> R, R>(call: F) -> Result<R, Abort> {
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
    let ended = unsafe { rocx_guarded(trampoline::<F, R>, &mut slot as *mut Slot<F, R> as *mut c_void) } != 0;
    if ended {
        let why = ABORT.with(|slot| slot.borrow_mut().take()).unwrap_or_else(|| Abort::Crash("crashed".into()));
        return Err(why);
    }
    Ok(slot.out.take().expect("a call that returned has its result"))
}

/// The app's markup (`main!`'s), as JSON, its holes kept by the host.
pub fn mount() -> Result<String, Abort> {
    let json = guarded(|| unsafe { abi::roc_mount() })?;
    Ok(taken(json))
}

/// Runs a box the host keeps (a computation, a handler, a fallback): its answer, as JSON.
pub fn run(callable: Callable) -> Result<String, Abort> {
    // `run_for_host!` takes a reference: the host keeps its own.
    retain(callable);
    let json = guarded(|| unsafe { abi::roc_run(callable) })?;
    Ok(taken(json))
}
