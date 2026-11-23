//! A deadline for Roc that never waits (D-057): a call with a time limit (a job's) that loops
//! without an effect is cut off all the same, as a crash would end it, in every build.
//!
//! An effect that waits checks its call's deadline itself (`hosted::within`). Roc that computes
//! without one never reaches the host, so the host interrupts it: each of Roc's threads has a slot
//! here saying the deadline of the call running on it now (none between calls, or while its call is
//! paused), which `hosted` keeps up to date. A thread of the host's own, the watchdog, looks at the
//! slots, and sends a thread whose call has run past its deadline a signal (SIGURG, which nothing
//! else here uses and whose default is to ignore it), with `pthread_kill`, to that thread alone,
//! again every few milliseconds until the call has ended. The signal's handler, on that thread,
//! looks at where the call was interrupted:
//!
//! - In Roc's code: the thread's flag says Roc is running (`in Roc`), and it was interrupted in the
//!   executable's own code, not a library's. The flag is set by the trampoline of the call's guard
//!   (`roc::guarded`, once its jump target is set) while it runs Roc, and cleared by every function
//!   Roc calls in the host (`host()`, the first line of each: `roc_alloc` and its kin, every
//!   hosted function, the glue's callbacks), until it returns; a call that pauses takes it out
//!   with the rest of its state (`stash`). So with the flag set, the thread is in Roc's compiled
//!   code, or in code that holds nothing a crash there wouldn't (the guard's trampoline preparing
//!   its arguments, the glue's code between Roc and an allocation, the C library's `memcpy` called
//!   by Roc). The handler makes the thread, once it returns, call `preempted` as if Roc had called
//!   it there, which ends the call as `roc_crashed` does, jumping back to its guard
//!   (`hosted::cut_off`): what the call allocated is in its list and freed, as for any crash.
//! - Anywhere else (a hosted function, the allocator, a library's code: a lock may be held, a list
//!   half linked): it only notes that the call is to be cut off. The next allocation Roc asks for
//!   (`roc_alloc`, `roc_realloc`, `roc_dealloc`, which only Roc's code calls) ends the call there,
//!   holding nothing, and the next signal finds it in Roc's code otherwise.
//!
//! `server/test/host-entries.test.mjs` fails on a function Roc can call (the glue's runtime and
//! hosted symbols, every function the host exports, `RocHost`'s callbacks) whose first line isn't
//! `let _host = preempt::host();`: a missed one would let an interrupt land in the host's code.

use std::cell::Cell;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering, compiler_fence};
use std::sync::{Mutex, OnceLock};
use std::thread::Thread;
use std::time::{Duration, Instant};

/// How soon the watchdog signals a call again that its last signal didn't end.
const AGAIN: Duration = Duration::from_millis(2);

/// The longest the watchdog sleeps while any call has a deadline: a deadline set while it sleeps
/// is seen this late at the most.
const MOST_ASLEEP: Duration = Duration::from_millis(20);

/// A Roc thread's slot: the deadline of the call running on it (nanoseconds after `epoch`; 0 for
/// none), whether that call is to be cut off at its next allocation, and the thread, to signal it
/// (its `pthread_t`, as a number: musl's is a pointer).
struct Slot {
    deadline: AtomicU64,
    pending: AtomicBool,
    thread: usize,
}

thread_local! {
    /// This thread's slot, if it is one of Roc's.
    static SLOT: Cell<*const Slot> = const { Cell::new(std::ptr::null()) };
    /// Whether this thread is running Roc now (see above).
    static IN_ROC: Cell<bool> = const { Cell::new(false) };
}

/// Every Roc thread's slot (they live as long as the process).
static SLOTS: Mutex<Vec<&'static Slot>> = Mutex::new(Vec::new());

/// The executable's own code: its executable segments, [low, high) each ((0, 0) for none).
static CODE: [(AtomicUsize, AtomicUsize); 4] = [const { (AtomicUsize::new(0), AtomicUsize::new(0)) }; 4];

static WATCHDOG: OnceLock<Thread> = OnceLock::new();
/// Whether the watchdog sleeps until a deadline is set (none was, the last time it looked).
static IDLE: AtomicBool = AtomicBool::new(false);

/// Deadlines are kept as nanoseconds since this.
fn epoch() -> Instant {
    static EPOCH: OnceLock<Instant> = OnceLock::new();
    *EPOCH.get_or_init(Instant::now)
}

fn nanos(at: Instant) -> u64 {
    // Never 0, which says "none".
    (at.saturating_duration_since(epoch()).as_nanos() as u64).max(1)
}

/// Finds the executable's code, handles the signal, and starts the watchdog: once, before Roc's
/// threads start. Where the executable's code can't be found, nothing: deadlines are checked by
/// effects that wait alone, and the log says so.
pub fn start() {
    let _ = epoch();
    let found = executable_code();
    if found.is_empty() {
        crate::logging::warn("rocx server: the executable's code wasn't found: a time limit cuts a call off only at an effect that waits", &[]);
        return;
    }
    for ((low, high), (into_low, into_high)) in found.iter().zip(CODE.iter()) {
        into_low.store(*low, Ordering::Relaxed);
        into_high.store(*high, Ordering::Relaxed);
    }
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = interrupted as *const () as usize;
        action.sa_flags = libc::SA_SIGINFO | libc::SA_ONSTACK | libc::SA_RESTART;
        libc::sigemptyset(&mut action.sa_mask);
        if libc::sigaction(libc::SIGURG, &action, std::ptr::null_mut()) != 0 {
            return;
        }
    }
    if let Ok(started) = std::thread::Builder::new().name("rocx-deadlines".into()).spawn(watch) {
        let _ = WATCHDOG.set(started.thread().clone());
    }
}

/// Gives this thread (one of Roc's, starting) its slot.
pub fn register() {
    let slot: &'static Slot = Box::leak(Box::new(Slot { deadline: AtomicU64::new(0), pending: AtomicBool::new(false), thread: unsafe { libc::pthread_self() } as usize }));
    SLOT.with(|this| this.set(slot));
    IN_ROC.with(|in_roc| in_roc.set(false));
    SLOTS.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).push(slot);
}

// ---- Whether Roc is running ----

/// The host's code is running, from here until this is dropped (the first line of every function
/// Roc calls: `let _host = preempt::host();`). A function that never returns (a crash's jump) never
/// drops it: the call's guard puts the flag back (`roc::guarded`).
pub struct Host {
    was: bool,
}

pub fn host() -> Host {
    let was = IN_ROC.with(|in_roc| in_roc.replace(false));
    // The handler reads the flag on this thread: nothing here moves across these.
    compiler_fence(Ordering::SeqCst);
    Host { was }
}

impl Drop for Host {
    fn drop(&mut self) {
        compiler_fence(Ordering::SeqCst);
        IN_ROC.with(|in_roc| in_roc.set(self.was));
    }
}

/// Roc runs from here (a guard's trampoline, its jump target set): the flag as it was before.
pub fn enter_roc() -> bool {
    compiler_fence(Ordering::SeqCst);
    let was = IN_ROC.with(|in_roc| in_roc.replace(true));
    compiler_fence(Ordering::SeqCst);
    was
}

/// Puts the flag back as it was (`enter_roc`'s answer, or `in_roc`'s).
pub fn restore(was: bool) {
    compiler_fence(Ordering::SeqCst);
    IN_ROC.with(|in_roc| in_roc.set(was));
    compiler_fence(Ordering::SeqCst);
}

/// The flag now: for a guard to put back after its call, however the call ended.
pub fn in_roc() -> bool {
    IN_ROC.with(Cell::get)
}

fn slot() -> Option<&'static Slot> {
    let slot = SLOT.with(Cell::get);
    (!slot.is_null()).then(|| unsafe { &*slot })
}

/// The call running on this thread now has `deadline` (none: a call without one, or none running).
/// Whatever was noted for the call before is forgotten.
pub fn set_deadline(deadline: Option<Instant>) {
    let Some(slot) = slot() else { return };
    let at = deadline.map_or(0, nanos);
    slot.pending.store(false, Ordering::Relaxed);
    slot.deadline.store(at, Ordering::SeqCst);
    if at != 0 && IDLE.load(Ordering::SeqCst) {
        if let Some(watchdog) = WATCHDOG.get() {
            watchdog.unpark();
        }
    }
}

/// Whether the call running on this thread is to be cut off (its deadline passed while the host's
/// code ran): Roc's next allocation ends it.
pub fn pending() -> bool {
    slot().is_some_and(|slot| slot.pending.load(Ordering::Relaxed))
}

/// The watchdog: signals each thread whose call is past its deadline, then sleeps until the next
/// deadline (or `AGAIN`, while a call it signalled runs on), or, with none, until one is set.
fn watch() {
    loop {
        let now = nanos(Instant::now());
        let mut next: Option<u64> = None;
        for slot in SLOTS.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).iter() {
            let deadline = slot.deadline.load(Ordering::SeqCst);
            if deadline == 0 {
                continue;
            }
            let wake = if deadline <= now {
                unsafe { libc::pthread_kill(slot.thread as libc::pthread_t, libc::SIGURG) };
                now + AGAIN.as_nanos() as u64
            } else {
                deadline
            };
            next = Some(next.map_or(wake, |next| next.min(wake)));
        }
        match next {
            Some(wake) => std::thread::park_timeout(Duration::from_nanos(wake.saturating_sub(now)).min(MOST_ASLEEP)),
            None => {
                IDLE.store(true, Ordering::SeqCst);
                // A deadline set since the look above, before IDLE was: it didn't wake this.
                let set = SLOTS.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).iter().any(|slot| slot.deadline.load(Ordering::SeqCst) != 0);
                if !set {
                    std::thread::park();
                }
                IDLE.store(false, Ordering::SeqCst);
            }
        }
    }
}

/// SIGURG, on a Roc thread: if its call is past its deadline, the call is cut off, at once if the
/// thread is running Roc in the executable's code (it calls `preempted` when the handler returns),
/// else at its next allocation. Only atomics, this thread's flag and the interrupted context are
/// touched here.
extern "C" fn interrupted(_: libc::c_int, _: *mut libc::siginfo_t, context: *mut libc::c_void) {
    let Some(slot) = slot() else { return };
    let deadline = slot.deadline.load(Ordering::SeqCst);
    if deadline == 0 || nanos(Instant::now()) < deadline {
        return;
    }
    let context = context as *mut libc::ucontext_t;
    if in_roc() && in_executable(unsafe { pc_of(context) }) {
        unsafe { redirect(context) };
        return;
    }
    slot.pending.store(true, Ordering::Relaxed);
}

/// Where the thread goes from Roc's code: it never returns, ending the call (`hosted::preempted`).
/// The host's code runs from here: the call's guard puts the flag back.
extern "C" fn preempted() -> ! {
    let _host = host();
    crate::hosted::preempted()
}

/// Whether `pc` is in the executable's own code (not a library's).
fn in_executable(pc: usize) -> bool {
    CODE.iter().any(|(low, high)| {
        let (low, high) = (low.load(Ordering::Relaxed), high.load(Ordering::Relaxed));
        pc >= low && pc < high
    })
}

/// Where the interrupted context was, and setting it to call `preempted` there (its return address
/// the instruction it was at, for a backtrace's sake).
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
unsafe fn pc_of(context: *mut libc::ucontext_t) -> usize {
    unsafe { (*(*context).uc_mcontext).__ss.__pc as usize }
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
unsafe fn redirect(context: *mut libc::ucontext_t) {
    let state = unsafe { &mut (*(*context).uc_mcontext).__ss };
    state.__lr = state.__pc;
    state.__pc = preempted as *const () as u64;
}

#[cfg(all(target_os = "macos", target_arch = "x86_64"))]
unsafe fn pc_of(context: *mut libc::ucontext_t) -> usize {
    unsafe { (*(*context).uc_mcontext).__ss.__rip as usize }
}

#[cfg(all(target_os = "macos", target_arch = "x86_64"))]
unsafe fn redirect(context: *mut libc::ucontext_t) {
    let state = unsafe { &mut (*(*context).uc_mcontext).__ss };
    // A call's frame: below the red zone, aligned as a call leaves it, the return address pushed.
    let sp = ((state.__rsp - 128) & !15) - 8;
    unsafe { *(sp as *mut u64) = state.__rip };
    state.__rsp = sp;
    state.__rip = preempted as *const () as u64;
}

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
unsafe fn pc_of(context: *mut libc::ucontext_t) -> usize {
    unsafe { (*context).uc_mcontext.pc as usize }
}

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
unsafe fn redirect(context: *mut libc::ucontext_t) {
    let state = unsafe { &mut (*context).uc_mcontext };
    state.regs[30] = state.pc;
    state.pc = preempted as *const () as u64;
}

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
unsafe fn pc_of(context: *mut libc::ucontext_t) -> usize {
    unsafe { (*context).uc_mcontext.gregs[libc::REG_RIP as usize] as usize }
}

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
unsafe fn redirect(context: *mut libc::ucontext_t) {
    let registers = unsafe { &mut (*context).uc_mcontext.gregs };
    let sp = ((registers[libc::REG_RSP as usize] as u64 - 128) & !15) - 8;
    unsafe { *(sp as *mut u64) = registers[libc::REG_RIP as usize] as u64 };
    registers[libc::REG_RSP as usize] = sp as i64;
    registers[libc::REG_RIP as usize] = preempted as *const () as i64;
}

/// The executable's own code, as it is loaded: each of its executable segments (`__TEXT`, and the
/// fast dev link's `__ROC_TEXT`), from its load commands.
#[cfg(target_os = "macos")]
#[allow(deprecated)] // libc's Mach-O types: the `mach2` crate has them too, for one read here.
fn executable_code() -> Vec<(usize, usize)> {
    let mut found = Vec::new();
    unsafe {
        let header = libc::_dyld_get_image_header(0) as *const libc::mach_header_64;
        if header.is_null() || (*header).magic != libc::MH_MAGIC_64 {
            return found;
        }
        let slide = libc::_dyld_get_image_vmaddr_slide(0) as usize;
        let mut command = header.add(1) as *const libc::load_command;
        for _ in 0..(*header).ncmds {
            if (*command).cmd == libc::LC_SEGMENT_64 {
                let segment = &*(command as *const libc::segment_command_64);
                if segment.initprot & libc::VM_PROT_EXECUTE != 0 && segment.vmsize > 0 {
                    let low = segment.vmaddr as usize + slide;
                    found.push((low, low + segment.vmsize as usize));
                }
            }
            command = (command as *const u8).add((*command).cmdsize as usize) as *const libc::load_command;
        }
    }
    found.truncate(CODE.len());
    found
}

/// The executable's own code, as it is loaded: each of its executable segments (the host's
/// `.text`, and the fast dev link's `.text.roc`; a static executable's C library is among them).
#[cfg(target_os = "linux")]
fn executable_code() -> Vec<(usize, usize)> {
    struct Found {
        code: Vec<(usize, usize)>,
        seen: bool,
    }
    unsafe extern "C" fn each(info: *mut libc::dl_phdr_info, _: libc::size_t, data: *mut libc::c_void) -> libc::c_int {
        let found = unsafe { &mut *(data as *mut Found) };
        // The executable is the first object listed.
        if found.seen {
            return 1;
        }
        found.seen = true;
        let info = unsafe { &*info };
        for index in 0..info.dlpi_phnum as usize {
            let header = unsafe { &*info.dlpi_phdr.add(index) };
            if header.p_type == libc::PT_LOAD && header.p_flags & libc::PF_X != 0 && header.p_memsz > 0 {
                let low = info.dlpi_addr as usize + header.p_vaddr as usize;
                found.code.push((low, low + header.p_memsz as usize));
            }
        }
        1
    }
    let mut found = Found { code: Vec::new(), seen: false };
    unsafe { libc::dl_iterate_phdr(Some(each), &mut found as *mut Found as *mut libc::c_void) };
    found.code.truncate(CODE.len());
    found.code
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn executable_code() -> Vec<(usize, usize)> {
    Vec::new()
}
