//! Roc's side of the host: the memory Roc allocates, what happens when it crashes, and the calls
//! into the app (`respond`, `stream`, `drop_feed`, a page's `mount`; `init`, `background`,
//! `isolated`, `isolated_call`; `run`).
//!
//! Every call into Roc is guarded (`guarded`): it runs with a jump target set (`guard.c`), and
//! what it allocates is linked into a list (`Ring`). If the call returns, what it still holds lives
//! on: an answer's strings are copied out and freed, and a stream or a page keeps its list, until
//! the call that sends or renders it. If a call crashes, `roc_crashed` jumps back to the guard, and
//! everything in the list is freed: the request's arguments, whatever Roc had built, a stream's
//! state, a page and what its components made.
//!
//! A value Roc makes in a call belongs to that call's thread until the call returns; after that the
//! host owns it and moves it (a stream to the thread that sends it), but never shares it, so no two
//! threads touch one value's counts at once.

use crate::abi::{self, RocHost, RocStr};
use std::alloc::{Layout, alloc, dealloc};
use std::cell::{Cell, RefCell, UnsafeCell};
use std::ffi::c_void;
use std::ptr::{self, NonNull};
use std::sync::atomic::{AtomicI64, AtomicIsize, Ordering};

// ---- Memory ----

/// What precedes each allocation Roc makes: its links into the list of the call that made it
/// (null once that call has returned), and what `dealloc` needs to free it.
#[repr(C)]
struct Header {
    prev: *mut Header,
    next: *mut Header,
    size: usize,
    align: usize,
}

const HEADER: usize = std::mem::size_of::<Header>();

/// Allocations Roc holds now, across all threads.
static LIVE: AtomicI64 = AtomicI64::new(0);

/// How many allocations Roc holds now. The tests check that a crash, or a client that goes in the
/// middle of a stream, leaves none behind.
pub fn live_allocations() -> i64 {
    LIVE.load(Ordering::Relaxed)
}

thread_local! {
    /// The list the call running on this thread adds to (a `Ring`'s sentinel), or null between
    /// calls.
    static TRACKING: Cell<*mut Header> = const { Cell::new(ptr::null_mut()) };
    /// Why the last call on this thread crashed.
    static CRASH: RefCell<Option<String>> = const { RefCell::new(None) };
    /// Why the last call on this thread failed, when a host effect failed it (`fail`) rather than
    /// Roc crashing: a signals computation whose nearest <Errored> shows it.
    static FAILURE: RefCell<Option<String>> = const { RefCell::new(None) };
    /// The list of the page being rendered on this thread (`Page::rendering`), which what its
    /// computations made and still hold joins when they return (`run`); or null.
    static KEEPING: Cell<*mut Header> = const { Cell::new(ptr::null_mut()) };
}

/// Ends the running call with a failure (not a crash): a host effect that can't answer, as the JS
/// runtime throws `Failed`. Jumps back to the call's guard, as a crash does; the caller of the
/// guarded call tells the two apart (`take_failure`). The calling frame must hold nothing to drop.
pub fn fail(message: String) -> ! {
    if unsafe { rocx_guard_active() } == 0 {
        eprintln!("rocx: a failure outside a call the host guards: {message}");
        std::process::abort();
    }
    FAILURE.with(|slot| *slot.borrow_mut() = Some(message.clone()));
    CRASH.with(|slot| *slot.borrow_mut() = Some(message));
    unsafe { rocx_guard_escape() }
}

/// Ends the running call with a crash: one a host effect saw in a call it made, passed on.
pub fn crash_outward(message: String) -> ! {
    if unsafe { rocx_guard_active() } == 0 {
        eprintln!("rocx: Roc crashed outside a call the host guards: {message}");
        std::process::abort();
    }
    CRASH.with(|slot| *slot.borrow_mut() = Some(message));
    unsafe { rocx_guard_escape() }
}

/// Whether the call that just ended was failed (`fail`), and why.
pub fn take_failure() -> Option<String> {
    FAILURE.with(|slot| slot.borrow_mut().take())
}

/// A list of allocations: what a call made and still holds. A request's is let go of when the
/// answer is out (what's left lives on untracked); a stream's goes with it, from the call that made
/// it to the call that sends it, so a crash there frees all of it.
struct Ring(Box<UnsafeCell<Header>>);

impl Ring {
    fn new() -> Ring {
        let ring = Ring(Box::new(UnsafeCell::new(Header { prev: ptr::null_mut(), next: ptr::null_mut(), size: 0, align: 0 })));
        let sentinel = ring.sentinel();
        unsafe {
            (*sentinel).prev = sentinel;
            (*sentinel).next = sentinel;
        }
        ring
    }

    fn sentinel(&self) -> *mut Header {
        self.0.get()
    }

    /// Moves every allocation in it to the list whose sentinel is `into`.
    fn move_into(&self, into: *mut Header) {
        let sentinel = self.sentinel();
        unsafe {
            let (first, last) = ((*sentinel).next, (*sentinel).prev);
            if first == sentinel {
                return;
            }
            (*last).next = (*into).next;
            (*(*into).next).prev = last;
            (*into).next = first;
            (*first).prev = into;
            (*sentinel).prev = sentinel;
            (*sentinel).next = sentinel;
        }
    }

    /// Unlinks every allocation in it, freeing each if `free`.
    fn empty(&self, free: bool) {
        let sentinel = self.sentinel();
        unsafe {
            let mut each = (*sentinel).next;
            while each != sentinel {
                let next = (*each).next;
                (*each).prev = ptr::null_mut();
                (*each).next = ptr::null_mut();
                if free {
                    free_block(each);
                }
                each = next;
            }
            (*sentinel).prev = sentinel;
            (*sentinel).next = sentinel;
        }
    }
}

impl Drop for Ring {
    /// What is left lives on, untracked: nothing may point at a sentinel that's gone.
    fn drop(&mut self) {
        self.empty(false);
    }
}

/// Where the user's bytes begin in a block aligned to `align`: after the header, aligned.
fn offset_for(align: usize) -> usize {
    let align = align.max(16);
    (HEADER + align - 1) & !(align - 1)
}

fn out_of_memory() -> ! {
    eprintln!("rocx: out of memory");
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
        header.write(Header { prev: ptr::null_mut(), next: ptr::null_mut(), size, align });
        let ring = TRACKING.with(Cell::get);
        if !ring.is_null() {
            (*header).next = (*ring).next;
            (*header).prev = ring;
            (*(*ring).next).prev = header;
            (*ring).next = header;
        }
        LIVE.fetch_add(1, Ordering::Relaxed);
        NonNull::new_unchecked(user as *mut c_void)
    }
}

unsafe fn header_of(user: *mut c_void) -> *mut Header {
    unsafe { (user as *mut u8).sub(HEADER) as *mut Header }
}

/// Frees a block, unlinking it first if a call is still tracking it.
unsafe fn free_block(header: *mut Header) {
    unsafe {
        if !(*header).prev.is_null() {
            (*(*header).prev).next = (*header).next;
            (*(*header).next).prev = (*header).prev;
        }
        let Header { size, align, .. } = header.read();
        let base = (header as *mut u8).add(HEADER).sub(offset_for(align));
        dealloc(base, Layout::from_size_align_unchecked(size, align));
    }
    LIVE.fetch_sub(1, Ordering::Relaxed);
}

fn reallocate(user: *mut c_void, length: usize, alignment: usize) -> NonNull<c_void> {
    unsafe {
        let header = header_of(user);
        let old_length = (*header).size - offset_for((*header).align);
        let moved = allocate(length, alignment);
        ptr::copy_nonoverlapping(user as *const u8, moved.as_ptr() as *mut u8, old_length.min(length));
        free_block(header);
        moved
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_alloc(length: usize, alignment: usize) -> NonNull<c_void> {
    allocate(length, alignment)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_dealloc(ptr: *mut c_void, _alignment: usize) {
    if !ptr.is_null() {
        unsafe { free_block(header_of(ptr)) }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_realloc(ptr: *mut c_void, length: usize, alignment: usize) -> NonNull<c_void> {
    if ptr.is_null() {
        return allocate(length, alignment);
    }
    reallocate(ptr, length, alignment)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_dbg(bytes: *const u8, len: usize) {
    eprintln!("[roc dbg] {}", text(bytes, len));
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_expect_failed(bytes: *const u8, len: usize) {
    eprintln!("[roc expect failed] {}", text(bytes, len));
}

/// A crash ends the call it happened in: the message is kept for the guard, which this jumps back
/// to. It never returns, as Roc's ABI asks.
#[unsafe(no_mangle)]
pub extern "C" fn roc_crashed(bytes: *const u8, len: usize) {
    let message = text(bytes, len);
    if unsafe { rocx_guard_active() } == 0 {
        eprintln!("rocx: Roc crashed outside a call the host guards: {message}");
        std::process::abort();
    }
    CRASH.with(|slot| *slot.borrow_mut() = Some(message));
    unsafe { rocx_guard_escape() }
}

fn text(bytes: *const u8, len: usize) -> String {
    String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(bytes, len) }).into_owned()
}

// The glue's helpers (`RocStr::from_str`, `decref`) allocate and free through a `RocHost`; these
// send them to the same allocator Roc uses, so what they make is tracked like the rest.
extern "C" fn host_alloc(_: *mut RocHost, length: usize, alignment: usize) -> NonNull<c_void> {
    allocate(length, alignment)
}
extern "C" fn host_dealloc(_: *mut RocHost, ptr: *mut c_void, alignment: usize) {
    roc_dealloc(ptr, alignment)
}
extern "C" fn host_realloc(_: *mut RocHost, ptr: *mut c_void, length: usize, alignment: usize) -> NonNull<c_void> {
    roc_realloc(ptr, length, alignment)
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

/// The context the glue's helpers take.
pub fn host() -> RocHost {
    RocHost {
        env: ptr::null_mut(),
        roc_alloc: host_alloc,
        roc_dealloc: host_dealloc,
        roc_realloc: host_realloc,
        roc_dbg: host_dbg,
        roc_expect_failed: host_expect_failed,
        roc_crashed: host_crashed,
    }
}

// ---- Calls ----

unsafe extern "C" {
    fn rocx_guarded(call: extern "C" fn(*mut c_void), data: *mut c_void) -> i32;
    fn rocx_guard_active() -> i32;
    fn rocx_guard_escape() -> !;
}

/// Why a call into Roc failed: the message it crashed with.
#[derive(Debug)]
pub struct Crash(pub String);

/// Runs `call`, which calls into Roc, guarded, adding what it allocates to `ring`: its result, or
/// the crash that ended it, after freeing everything in `ring`.
///
/// `call` must hold nothing that needs dropping while Roc runs (only references and the glue's
/// plain values): a crash skips its frame.
fn guarded<F: FnOnce() -> R, R>(ring: &Ring, call: F) -> Result<R, Crash> {
    struct Slot<F, R> {
        call: Option<F>,
        out: Option<R>,
    }
    extern "C" fn run<F: FnOnce() -> R, R>(data: *mut c_void) {
        let slot = unsafe { &mut *(data as *mut Slot<F, R>) };
        if let Some(call) = slot.call.take() {
            slot.out = Some(call());
        }
    }

    // A call may run inside another (an actor's, from a request's hosted `ask!`): it has a list
    // and a jump target of its own, and the outer call's come back when it ends. A crash in it
    // jumps back to its own guard, inside the hosted function, which goes on.
    let outer = TRACKING.with(|tracking| tracking.replace(ring.sentinel()));
    let mut slot = Slot { call: Some(call), out: None };
    let crashed = unsafe { rocx_guarded(run::<F, R>, &mut slot as *mut Slot<F, R> as *mut c_void) } != 0;
    TRACKING.with(|tracking| tracking.set(outer));

    if crashed {
        ring.empty(true);
        let message = CRASH.with(|slot| slot.borrow_mut().take()).unwrap_or_else(|| "crashed".into());
        return Err(Crash(message));
    }
    Ok(slot.out.take().expect("a call that returned has its result"))
}

/// A stream of events (a box holding the loop that sends it), which only Roc runs or releases, and
/// the allocations it holds. The host owns it alone, and moves it to the thread that sends it.
pub struct Feed {
    boxed: *mut abi::RespondForHostFeed,
    held: Ring,
}

unsafe impl Send for Feed {}

/// A page of components (a box holding its mount: run, it renders the page's markup, its holes
/// kept by the host, as JSON), which only Roc runs, and the allocations the answer holds. The host
/// owns it alone, on the thread that answers the request (`signals::render_page`).
///
/// Its render keeps what it makes in that list too, and when the page is let go of
/// (`drop_page`), whatever is left in it is freed. A computation that fails or crashes may never
/// give back its reference to the box it ran (Roc's optimized code lets go of it after the
/// computation returns), and the list is how that box is freed anyway.
pub struct Page {
    callable: abi::RocErasedCallable,
    held: Ring,
    /// Whether a crash in its mount freed it, with everything in `held`.
    freed: Cell<bool>,
}

unsafe impl Send for Page {}

impl Page {
    /// Runs `render`, which mounts the page and runs its computations (`run`): what each makes and
    /// still holds when it returns joins the answer's list.
    pub fn rendering<T>(&self, render: impl FnOnce() -> T) -> T {
        let outer = KEEPING.with(|keeping| keeping.replace(self.held.sentinel()));
        let rendered = render();
        KEEPING.with(|keeping| keeping.set(outer));
        rendered
    }

    /// Runs the page's box, in a call guarded with the answer's list: its markup, as JSON. What the
    /// mount registers with the host (the boxes it keeps) joins that list. If it crashes,
    /// everything in the list is freed, the page's box among it.
    pub fn mount(&self) -> Result<String, Crash> {
        if self.freed.get() {
            return Err(Crash("rocx: a page mounted after it was freed".into()));
        }
        let host = host();
        unsafe { abi::incref_erased_callable(self.callable, 1) };
        match guarded(&self.held, || unsafe { abi::roc_run(self.callable) }) {
            Ok(json) => Ok(copied(json, &host)),
            Err(crash) => {
                self.freed.set(true);
                Err(crash)
            }
        }
    }
}

/// Lets go of a page: rendered (after the host released what the render registered), or not (an
/// answer to HEAD; a server function's call answered with one). Its box is released, and what the
/// answer and the render still hold is freed: the request is over, and nothing outlives it.
pub fn drop_page(page: Page) {
    if !page.freed.get() {
        release(page.callable);
    }
    page.held.empty(true);
}

/// An answer to a request.
pub struct Answer {
    pub status: u16,
    /// A `name: value` a line.
    pub headers: String,
    /// Its text (or the page, rendered).
    pub body: String,
    /// Its bytes, if the answer sends bytes rather than text.
    pub bytes: Option<Vec<u8>>,
    /// Where its body comes from, if the host fetches it and sends it on (`Server.forward`).
    pub forward: Option<Upstream>,
    /// The stream, if the answer is one (server-sent events).
    pub feed: Option<Feed>,
    /// The page, if the answer is one, for the host to render.
    pub page: Option<Page>,
}

/// The request a forwarded answer's body comes from (`Server.Upstream`), for the host to make.
pub struct Upstream {
    pub method: String,
    pub url: String,
    /// A `name: value` a line.
    pub headers: String,
}

fn copied(text: RocStr, host: &RocHost) -> String {
    let copy = text.as_str().to_owned();
    unsafe { text.decref(host) };
    copy
}

/// The app's answer to a request (`respond!`). A call during another (a server function's, from a
/// component the host renders: `signals::roc_call`) has a list and a guard of its own.
pub fn respond(method: &str, target: &str, headers: &str, body: &[u8], context: &str) -> Result<Answer, Crash> {
    let host = host();
    let host = &host;
    let made = Ring::new();
    let answer = guarded(&made, || unsafe {
        abi::roc_respond(
            RocStr::from_str(method, host),
            RocStr::from_str(target, host),
            RocStr::from_str(headers, host),
            abi::RocListWith::from_slice(body, host),
            RocStr::from_str(context, host),
        )
    })?;
    // The strings and bytes are copied out and freed (leaving `made`); what is left is the
    // stream's, or the page's. The box the answer doesn't send is released.
    let (headers, body) = (copied(answer.headers, host), copied(answer.text, host));
    let bytes = (answer.kind == BYTES).then(|| answer.bytes.as_slice().to_vec());
    unsafe { answer.bytes.decref(host) };
    let upstream = Upstream { method: copied(answer.upstream.method, host), url: copied(answer.upstream.url, host), headers: copied(answer.upstream.headers, host) };
    let forward = (answer.kind == FORWARD).then_some(upstream);
    let (feed, page) = match answer.kind {
        STREAM => {
            release(answer.page);
            (Some(Feed { boxed: answer.feed, held: made }), None)
        }
        PAGE => {
            unsafe { abi::roc_drop_feed(answer.feed) };
            (None, Some(Page { callable: answer.page, held: made, freed: Cell::new(false) }))
        }
        _ => {
            unsafe { abi::roc_drop_feed(answer.feed) };
            release(answer.page);
            (None, None)
        }
    };
    Ok(Answer { status: answer.status, headers, body, bytes, forward, feed, page })
}

/// What an answer sends (`Server.for_host`'s `kind`): its text (0), its page, its stream, its
/// bytes, or a body fetched from elsewhere.
const PAGE: u8 = 1;
const STREAM: u8 = 2;
const BYTES: u8 = 3;
const FORWARD: u8 = 4;

/// Sends a stream to its end (`stream_for_host!`, which runs the feed), on this thread: Roc writes
/// each event and waits between them through the hosted `send!` and `sleep!` (`hosted::call`, with
/// the response). If it crashes, everything it held, from before it began and since, is freed.
pub fn stream(feed: Feed) -> Result<(), Crash> {
    let Feed { boxed, held } = feed;
    guarded(&held, || unsafe { abi::roc_stream(boxed) })
}

/// Lets go of a stream that won't be sent (an answer to HEAD).
pub fn drop_feed(feed: Feed) {
    unsafe { abi::roc_drop_feed(feed.boxed) }
}

/// The platform's start (`init_for_host!`): its schedules checked, its migrations applied, the jobs
/// a stop cut short queued again. Ok, or why the server can't start.
pub fn init() -> Result<Result<(), String>, Crash> {
    let host = host();
    let made = Ring::new();
    let done = guarded(&made, || unsafe { abi::roc_init() })?;
    Ok(match done.tag {
        abi::InitForHostResultTag::Ok => Ok(()),
        abi::InitForHostResultTag::Err => Err(copied(unsafe { core::mem::ManuallyDrop::into_inner(done.payload.err) }, &host)),
    })
}

/// How many background loops the platform runs (the job workers, the schedules, the mail check).
pub fn background_count() -> Result<u64, Crash> {
    let made = Ring::new();
    guarded(&made, || unsafe { abi::roc_background_count() })
}

/// Runs background loop `index` to its end, on this thread.
pub fn background(index: u64) -> Result<(), Crash> {
    let made = Ring::new();
    guarded(&made, || unsafe { abi::roc_background(index) })
}

/// Runs a part of the app in a call of its own (`isolated_for_host!`: a job): its answer, or why it
/// failed; a crash in it ends this call only, and frees what it allocated.
pub fn isolated(what: &str, input: &str) -> Result<Result<String, String>, Crash> {
    let host = host();
    let host = &host;
    let made = Ring::new();
    let done = guarded(&made, || unsafe { abi::roc_isolated(RocStr::from_str(what, host), RocStr::from_str(input, host)) })?;
    Ok(answered(done, host))
}

/// Runs a function Roc gave the host (`isolated_call_for_host!`: an actor's `receive!`) with
/// `input`, in a call of its own, as `isolated` runs a part of the app. `input` is made in the call,
/// so a crash frees it; what the function captured was made by the caller, and stays the caller's.
///
/// Who owns the box: Roc hands it to the host with one reference, the host's (`Actor.ask!` makes a
/// box for this call alone, so it is the only one), and the call into Roc takes that reference:
/// Roc lets go of it as it runs the function. Code built with `--opt=dev` has let go of it before a
/// crash in the function can come; optimized code (`--opt=speed`) lets go only after the function
/// returns, so a crash skips that, and the box, made by the calling call and in its list, would
/// outlive it, as a page's box would (`Page`, whose list frees it). So on a crash, and only then,
/// the host lets go of the reference the call took, if the call didn't: when the box was held alone
/// as it was handed over, and is still a block in the calling call's list (a box let go of is
/// freed, which takes it out). Once, by its count, as Roc would have on return: what it captured is
/// let go of with it. A box shared with anything else, or static, is left as it is.
pub fn isolated_call(callable: abi::RocErasedCallable, input: &str) -> Result<Result<String, String>, Crash> {
    let host = host();
    let host = &host;
    let alone = references(callable) == 1;
    let caller = TRACKING.with(Cell::get);
    let made = Ring::new();
    let done = match guarded(&made, || unsafe { abi::roc_isolated_call(callable, RocStr::from_str(input, host)) }) {
        Ok(done) => done,
        Err(crash) => {
            if alone && holds(caller, block_of(callable)) {
                release(callable);
            }
            return Err(crash);
        }
    };
    Ok(answered(done, host))
}

/// How many references a boxed function (`Box(a => b)`) has: its count, just before its payload
/// (the glue's `allocate_box`); 0 for a static one.
fn references(callable: abi::RocErasedCallable) -> isize {
    unsafe { (*((callable as *mut u8).sub(std::mem::size_of::<isize>()) as *const AtomicIsize)).load(Ordering::Acquire) }
}

/// The block a boxed function lives in: its payload after its count, padded to the payload's
/// alignment (the glue's `allocate_box`, and `free_box_allocation`, which frees it so), and the
/// block's header before that (`allocate`). Only its address: nothing there is read.
fn block_of(callable: abi::RocErasedCallable) -> *mut Header {
    let header_bytes = abi::ROC_ERASED_CALLABLE_PAYLOAD_ALIGNMENT.max(std::mem::size_of::<usize>());
    unsafe { header_of((callable as *mut u8).sub(header_bytes) as *mut c_void) }
}

/// Whether the list whose sentinel is `ring` (none: null) holds the block `block`, by its address:
/// only the list's own blocks are read.
fn holds(ring: *mut Header, block: *mut Header) -> bool {
    if ring.is_null() {
        return false;
    }
    unsafe {
        let mut each = (*ring).next;
        while each != ring {
            if each == block {
                return true;
            }
            each = (*each).next;
        }
    }
    false
}

/// An isolated call's answer, or why it failed, copied out and released.
fn answered(done: abi::IsolatedForHostResult, host: &RocHost) -> Result<String, String> {
    match done.tag {
        abi::IsolatedForHostResultTag::Ok => Ok(copied(unsafe { core::mem::ManuallyDrop::into_inner(done.payload.ok) }, host)),
        abi::IsolatedForHostResultTag::Err => Err(copied(unsafe { core::mem::ManuallyDrop::into_inner(done.payload.err) }, host)),
    }
}

/// Runs a computation kept for a render (a box the host holds a reference to: a hole, a memo, a
/// fallback): its answer, as JSON. While a page renders, what it made and still holds joins the
/// page's list (`Page::rendering`).
pub fn run(callable: abi::RocErasedCallable) -> Result<String, Crash> {
    let host = host();
    let made = Ring::new();
    unsafe { abi::incref_erased_callable(callable, 1) };
    let json = guarded(&made, || unsafe { abi::roc_run(callable) })?;
    let keeping = KEEPING.with(Cell::get);
    if !keeping.is_null() {
        made.move_into(keeping);
    }
    Ok(copied(json, &host))
}

/// Lets go of the host's reference to a box Roc gave it.
pub fn release(callable: abi::RocErasedCallable) {
    unsafe { abi::decref_erased_callable(callable, &host()) }
}

/// Another reference to a box the host holds, for Roc to take.
pub fn retain(callable: abi::RocErasedCallable) -> abi::RocErasedCallable {
    unsafe { abi::incref_erased_callable(callable, 1) };
    callable
}
