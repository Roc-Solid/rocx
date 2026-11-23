//! Where Roc runs (D-027): every call into Roc (a request, a stream, an actor's turn, a background
//! loop, the platform's start) is a stackful coroutine on one of a few threads of Roc's own (as many
//! as the machine has cores, or `ROCX_ROC_THREADS`). When an effect waits (Postgres, a socket,
//! another server, a sleep), the call pauses (`pause`): its stack is kept as it is, and its thread
//! goes on to run other calls. The thread polls the future the call waits on, and resumes the call,
//! on that same thread, once it is done. So a call that waits holds no thread, and any number of them
//! (an open stream's, say) can wait at once.
//!
//! A call never moves to another thread: it is started by whichever of Roc's threads is free (they
//! take new calls from one queue), and stays there. Compiled code may keep a thread-local's address
//! across a call, so a call resumed elsewhere could read another thread's state; and what the host
//! keeps per call in thread-locals (`hosted::wait` takes it out while the call is paused, and puts
//! it back when it resumes) is then always on the thread the call left it on.
//!
//! Futures are polled with the server's tokio runtime entered, so the sockets, timers and tasks they
//! make are that runtime's, as they were when a blocking thread waited on them: its threads drive
//! them, and wake the Roc thread whose call waits.
//!
//! Costs: Roc that computes for long without an effect (a long pure loop) can't pause, so the calls
//! queued on its thread wait for it (one with a deadline, a job's, is cut off there: `preempt`). A
//! paused call keeps its stack (8 MiB reserved; only the pages it touched cost memory). Profilers
//! and debuggers see calls on stacks of their own, not threads'. A call that overflows its stack
//! hits the guard below it, and the process ends, as a thread's overflow did: it says so on stderr
//! first (`overflowed`).

use corosensei::stack::{Stack, StackPointer};
use corosensei::{Coroutine, CoroutineResult, Yielder};
use std::cell::Cell;
use std::collections::VecDeque;
use std::ffi::c_void;
use std::future::Future;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::pin::Pin;
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::task::{Context, Poll, Wake, Waker};
use std::thread::Thread;

/// How deep a call's stack may grow: Roc's own default, as deep as the threads Roc used to run on
/// (a page is a deep tree to render). Reserved, not used: a call costs only the pages it touches.
pub const STACK: usize = 8 << 20;

/// Below each stack, never readable or writable: a call that overflows its stack faults there,
/// rather than writing over whatever is below. Many pages, so a large frame can't step over it.
const GUARD: usize = 256 << 10;

/// Stacks each Roc thread keeps for its next calls (beyond that, a stack is unmapped when its call
/// ends).
const KEPT: usize = 64;

/// The alternate stack a Roc thread's signal handler runs on (its call's stack has no room left
/// when it overflows).
const SIGNAL_STACK: usize = 128 << 10;

// ---- Starting calls ----

/// A call into Roc, given to Roc's threads.
type Job = Box<dyn FnOnce() + Send>;

/// Roc's threads: the calls waiting for one to start them, and each thread's own state.
struct Pool {
    queue: Mutex<Queue>,
    threads: Vec<Arc<Shared>>,
}

struct Queue {
    /// Calls not started yet, oldest first.
    jobs: VecDeque<Job>,
    /// The threads with nothing to do, parked until a call comes (the last to park first).
    idle: Vec<usize>,
}

/// What a Roc thread shares with the wakers of its calls' futures.
struct Shared {
    /// The paused calls whose futures have been woken: their slots and generations.
    woken: Mutex<Vec<(usize, u64)>>,
    thread: OnceLock<Thread>,
}

impl Shared {
    fn unpark(&self) {
        if let Some(thread) = self.thread.get() {
            thread.unpark();
        }
    }
}

static POOL: OnceLock<Pool> = OnceLock::new();

/// Set when the server has stopped: Roc's threads resume nothing more, and the process exits.
static HALTED: AtomicBool = AtomicBool::new(false);

/// How many threads Roc runs on, unless `ROCX_ROC_THREADS` says: one a core.
pub fn default_threads() -> usize {
    std::thread::available_parallelism().map(usize::from).unwrap_or(4)
}

/// Starts Roc's `count` threads, which poll futures with `runtime` entered.
pub fn start(count: usize, runtime: tokio::runtime::Handle) -> Result<(), String> {
    let threads = (0..count.max(1)).map(|_| Arc::new(Shared { woken: Mutex::new(Vec::new()), thread: OnceLock::new() })).collect();
    if POOL.set(Pool { queue: Mutex::new(Queue { jobs: VecDeque::new(), idle: Vec::new() }), threads }).is_err() {
        return Err("Roc's threads have started already".into());
    }
    let pool = POOL.get().expect("just set");
    crate::preempt::start();
    for (index, shared) in pool.threads.iter().enumerate() {
        let runtime = runtime.clone();
        let started = std::thread::Builder::new()
            .name(format!("rocx-roc-{index}"))
            .spawn(move || work(index, runtime))
            .map_err(|error| format!("Roc's thread {index}: {error}"))?;
        let _ = shared.thread.set(started.thread().clone());
    }
    Ok(())
}

/// The server has stopped (its grace is over): Roc's threads resume nothing more. A call still
/// running goes on to its next wait, and stays there until the process exits.
pub fn halt() {
    HALTED.store(true, Ordering::Release);
}

/// A call that ended without an answer: it panicked, or Roc's threads never started it.
#[derive(Debug)]
pub struct Lost;

/// Runs `call` (a call into Roc) on one of Roc's threads, in a coroutine of its own, started now:
/// what it returns, once it has (`Running`, awaited).
pub fn run<T: Send + 'static>(call: impl FnOnce() -> T + Send + 'static) -> Running<T> {
    let (answer, answered) = tokio::sync::oneshot::channel();
    submit(Box::new(move || {
        if let Ok(out) = catch_unwind(AssertUnwindSafe(call)) {
            let _ = answer.send(out);
        }
    }));
    Running(answered)
}

/// A call into Roc that has started (`run`): what it returns, when awaited. Dropped, the call goes
/// on to its end all the same, and what it returns is dropped.
pub struct Running<T>(tokio::sync::oneshot::Receiver<T>);

impl<T> Future for Running<T> {
    type Output = Result<T, Lost>;

    fn poll(mut self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<Result<T, Lost>> {
        Pin::new(&mut self.0).poll(context).map(|done| done.map_err(|_| Lost))
    }
}

fn submit(job: Job) {
    let Some(pool) = POOL.get() else {
        crate::logging::error("rocx server: a call into Roc before Roc's threads started", &[]);
        return;
    };
    let idle = {
        let mut queue = pool.queue.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        queue.jobs.push_back(job);
        queue.idle.pop()
    };
    if let Some(index) = idle {
        pool.threads[index].unpark();
    }
}

// ---- Pausing ----

/// What a paused call waits on: a future on the call's own stack (which stays where it is until the
/// call resumes), and whether polling it panicked.
struct Waiting {
    future: *mut (dyn Future<Output = ()> + 'static),
    panicked: bool,
}

/// A call's coroutine, and where its stack's guard begins.
struct Call {
    coroutine: Coroutine<(), *mut Waiting, (), CallStack>,
    low: usize,
}

thread_local! {
    /// The call running on this thread (its coroutine's yielder), or null between calls.
    static RUNNING: Cell<*const Yielder<(), *mut Waiting>> = const { Cell::new(ptr::null()) };
    /// The guard below the stack of the call running on this thread (for `overflowed`), or (0, 0).
    static GUARDED: Cell<(usize, usize)> = const { Cell::new((0, 0)) };
}

/// Whether this is a call into Roc, which can pause.
pub fn in_call() -> bool {
    !RUNNING.with(Cell::get).is_null()
}

/// Waits for `future`, pausing the running call (`in_call`) until it is done: its output, or None
/// if polling it panicked. The caller takes out what the call keeps in thread-locals first, and
/// puts it back after: other calls run on this thread meanwhile.
pub fn pause<F: Future>(future: F) -> Option<F::Output> {
    let yielder = RUNNING.with(|running| running.replace(ptr::null()));
    assert!(!yielder.is_null(), "pause outside a call into Roc");
    let mut output = None;
    let panicked = {
        let wrapped = async {
            output = Some(future.await);
        };
        let mut wrapped = std::pin::pin!(wrapped);
        let future: *mut (dyn Future<Output = ()> + '_) = unsafe { wrapped.as_mut().get_unchecked_mut() };
        // The future borrows from this frame, which is kept while the call is paused, and the
        // thread polls it only until it is done, before the call resumes: never after.
        let future: *mut (dyn Future<Output = ()> + 'static) = unsafe { std::mem::transmute(future) };
        let mut waiting = Waiting { future, panicked: false };
        unsafe { (*yielder).suspend(&mut waiting) };
        waiting.panicked
    };
    RUNNING.with(|running| running.set(yielder));
    if panicked { None } else { output }
}

/// Polls a paused call's future; a panic counts as done (the call sees it as an error).
fn poll(waiting: *mut Waiting, waker: &Waker) -> Poll<()> {
    let waiting = unsafe { &mut *waiting };
    let mut context = Context::from_waker(waker);
    let future = unsafe { Pin::new_unchecked(&mut *waiting.future) };
    match catch_unwind(AssertUnwindSafe(|| future.poll(&mut context))) {
        Ok(polled) => polled,
        Err(_) => {
            waiting.panicked = true;
            Poll::Ready(())
        }
    }
}

// ---- A Roc thread ----

/// What wakes a paused call: its thread's list gets its slot, once until it is polled again.
struct Signal {
    shared: Arc<Shared>,
    slot: usize,
    generation: u64,
    queued: AtomicBool,
}

impl Wake for Signal {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }

    fn wake_by_ref(self: &Arc<Self>) {
        if !self.queued.swap(true, Ordering::AcqRel) {
            self.shared.woken.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).push((self.slot, self.generation));
            self.shared.unpark();
        }
    }
}

/// A call that has paused at least once keeps a slot (and its waker) until it ends.
struct Slot {
    generation: u64,
    signal: Arc<Signal>,
    waker: Waker,
    /// The call, while it is paused, and what it waits on.
    paused: Option<(Call, *mut Waiting)>,
}

/// A Roc thread's own: its calls' slots, and stacks to reuse.
struct Local {
    shared: Arc<Shared>,
    slots: Vec<Slot>,
    free: Vec<usize>,
    stacks: Vec<CallStack>,
}

/// A Roc thread: the calls whose futures are done resumed, then a new call started, one at a
/// time; parked when there is neither.
fn work(index: usize, runtime: tokio::runtime::Handle) {
    let _entered = runtime.enter();
    let _signals = signal_stack();
    crate::preempt::register();
    let pool = POOL.get().expect("Roc's threads start after the pool");
    let shared = pool.threads[index].clone();
    let mut local = Local { shared: shared.clone(), slots: Vec::new(), free: Vec::new(), stacks: Vec::new() };
    let mut woken = Vec::new();
    loop {
        if HALTED.load(Ordering::Acquire) {
            std::thread::park();
            continue;
        }
        std::mem::swap(&mut woken, &mut *shared.woken.lock().unwrap_or_else(|poisoned| poisoned.into_inner()));
        for (slot, generation) in woken.drain(..) {
            local.woken(slot, generation);
        }
        let job = {
            let mut queue = pool.queue.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            let job = queue.jobs.pop_front();
            if job.is_none() && !queue.idle.contains(&index) {
                queue.idle.push(index);
            }
            job
        };
        match job {
            Some(job) => local.start(job),
            None => {
                if shared.woken.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).is_empty() {
                    std::thread::park();
                }
                pool.queue.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).idle.retain(|each| *each != index);
            }
        }
    }
}

impl Local {
    /// Starts a call in a coroutine, on a stack kept from an earlier one if there is one.
    fn start(&mut self, job: Job) {
        let stack = match self.stacks.pop() {
            Some(stack) => stack,
            None => match CallStack::new() {
                Ok(stack) => stack,
                Err(error) => {
                    // Dropped: its caller hears that it was lost.
                    crate::logging::error("rocx server: no stack for a call into Roc", &[("error", error.to_string().into())]);
                    return;
                }
            },
        };
        let low = stack.low;
        let coroutine = Coroutine::with_stack(stack, move |yielder: &Yielder<(), *mut Waiting>, ()| {
            RUNNING.with(|running| running.set(yielder));
            let _ = catch_unwind(AssertUnwindSafe(job));
            RUNNING.with(|running| running.set(ptr::null()));
        });
        self.advance(Call { coroutine, low }, None);
    }

    /// A paused call's future was woken: polled, and the call resumed if it is done.
    fn woken(&mut self, index: usize, generation: u64) {
        let Some(slot) = self.slots.get_mut(index) else { return };
        if slot.generation != generation {
            return;
        }
        let Some((call, waiting)) = slot.paused.take() else { return };
        slot.signal.queued.store(false, Ordering::Release);
        match poll(waiting, &slot.waker) {
            Poll::Pending => slot.paused = Some((call, waiting)),
            Poll::Ready(()) => self.advance(call, Some(index)),
        }
    }

    /// Resumes `call` until it pauses on a future that isn't done, or ends.
    fn advance(&mut self, mut call: Call, mut slot: Option<usize>) {
        loop {
            GUARDED.with(|guarded| guarded.set((call.low, call.low + GUARD)));
            let resumed = call.coroutine.resume(());
            GUARDED.with(|guarded| guarded.set((0, 0)));
            match resumed {
                CoroutineResult::Return(()) => {
                    if let Some(index) = slot {
                        self.free.push(index);
                    }
                    if self.stacks.len() < KEPT {
                        self.stacks.push(call.coroutine.into_stack());
                    }
                    return;
                }
                CoroutineResult::Yield(waiting) => {
                    let index = match slot {
                        Some(index) => index,
                        None => {
                            let index = self.claim();
                            slot = Some(index);
                            index
                        }
                    };
                    let slot = &mut self.slots[index];
                    if poll(waiting, &slot.waker).is_pending() {
                        slot.paused = Some((call, waiting));
                        return;
                    }
                }
            }
        }
    }

    /// A slot for a call that pauses, with a waker of its own (a stale waker of the slot's last
    /// call wakes nothing: its generation is past).
    fn claim(&mut self) -> usize {
        let index = self.free.pop().unwrap_or(self.slots.len());
        let generation = self.slots.get(index).map_or(0, |slot| slot.generation + 1);
        let signal = Arc::new(Signal { shared: self.shared.clone(), slot: index, generation, queued: AtomicBool::new(false) });
        let slot = Slot { generation, signal: signal.clone(), waker: Waker::from(signal), paused: None };
        if index == self.slots.len() {
            self.slots.push(slot);
        } else {
            self.slots[index] = slot;
        }
        index
    }
}

// ---- Stacks ----

/// A call's stack: `STACK` bytes, readable and writable, above a `GUARD` that is neither. Mapped,
/// not committed: memory is used only for the pages a call touches.
struct CallStack {
    low: usize,
}

impl CallStack {
    fn new() -> std::io::Result<CallStack> {
        #[cfg(target_os = "linux")]
        let flags = libc::MAP_PRIVATE | libc::MAP_ANONYMOUS | libc::MAP_NORESERVE;
        #[cfg(not(target_os = "linux"))]
        let flags = libc::MAP_PRIVATE | libc::MAP_ANONYMOUS;
        unsafe {
            let mapped = libc::mmap(ptr::null_mut(), GUARD + STACK, libc::PROT_NONE, flags, -1, 0);
            if mapped == libc::MAP_FAILED {
                return Err(std::io::Error::last_os_error());
            }
            let stack = CallStack { low: mapped as usize };
            if libc::mprotect((stack.low + GUARD) as *mut c_void, STACK, libc::PROT_READ | libc::PROT_WRITE) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(stack)
        }
    }
}

impl Drop for CallStack {
    fn drop(&mut self) {
        unsafe { libc::munmap(self.low as *mut c_void, GUARD + STACK) };
    }
}

unsafe impl Stack for CallStack {
    fn base(&self) -> StackPointer {
        StackPointer::new(self.low + GUARD + STACK).expect("a mapped stack")
    }

    fn limit(&self) -> StackPointer {
        StackPointer::new(self.low).expect("a mapped stack")
    }
}

// ---- A stack that overflows ----

/// Gives this thread an alternate stack for signals, and (once) handles SIGSEGV and SIGBUS there:
/// a fault in the guard of the running call's stack is an overflow, said on stderr before the
/// process ends. The mapping, kept for the thread's life.
fn signal_stack() -> Option<usize> {
    static HANDLED: OnceLock<()> = OnceLock::new();
    unsafe {
        let mapped = libc::mmap(ptr::null_mut(), SIGNAL_STACK, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_PRIVATE | libc::MAP_ANONYMOUS, -1, 0);
        if mapped == libc::MAP_FAILED {
            return None;
        }
        let alternate = libc::stack_t { ss_sp: mapped, ss_flags: 0, ss_size: SIGNAL_STACK };
        if libc::sigaltstack(&alternate, ptr::null_mut()) != 0 {
            libc::munmap(mapped, SIGNAL_STACK);
            return None;
        }
        HANDLED.get_or_init(|| {
            for signal in [libc::SIGSEGV, libc::SIGBUS] {
                let mut action: libc::sigaction = std::mem::zeroed();
                action.sa_sigaction = overflowed as *const () as usize;
                action.sa_flags = libc::SA_SIGINFO | libc::SA_ONSTACK;
                libc::sigemptyset(&mut action.sa_mask);
                libc::sigaction(signal, &action, ptr::null_mut());
            }
        });
        Some(mapped as usize)
    }
}

/// SIGSEGV or SIGBUS on a Roc thread: if the fault is in the guard below the running call's stack,
/// the call overflowed it, which is said (in the log's format, with a raw write: nothing else is
/// safe here). Either way the signal's default comes back, and the fault, repeated, ends the
/// process.
extern "C" fn overflowed(signal: libc::c_int, info: *mut libc::siginfo_t, _: *mut c_void) {
    let address = unsafe { fault_address(info) };
    let (low, high) = GUARDED.with(Cell::get);
    if address >= low && address < high {
        let said: &[u8] = if crate::logging::is_json() {
            b"{\"level\":\"error\",\"msg\":\"rocx server: a call into Roc overflowed its stack (8 MiB): the process ends\"}\n"
        } else {
            b"ERROR rocx server: a call into Roc overflowed its stack (8 MiB): the process ends\n"
        };
        unsafe { libc::write(2, said.as_ptr() as *const c_void, said.len()) };
    }
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = libc::SIG_DFL;
        libc::sigemptyset(&mut action.sa_mask);
        libc::sigaction(signal, &action, ptr::null_mut());
    }
}

#[cfg(target_os = "linux")]
unsafe fn fault_address(info: *mut libc::siginfo_t) -> usize {
    unsafe { (*info).si_addr() as usize }
}

#[cfg(not(target_os = "linux"))]
unsafe fn fault_address(info: *mut libc::siginfo_t) -> usize {
    unsafe { (*info).si_addr as usize }
}
