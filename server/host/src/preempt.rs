//! A deadline for Roc that never waits (D-057): a call with a time limit (a job's) that loops
//! without an effect is cut off all the same, as a crash would end it.
//!
//! An effect that waits checks its call's deadline itself (`hosted::within`). Roc that computes
//! without one never reaches the host, so the host interrupts it: each of Roc's threads has a slot
//! here saying the deadline of the call running on it now (none between calls, or while its call is
//! paused), which `hosted` keeps up to date. A thread of the host's own, the watchdog, looks at the
//! slots, and sends a thread whose call has run past its deadline a signal (SIGURG, which nothing
//! else here uses and whose default is to ignore it), again every few milliseconds until the call
//! has ended. The signal's handler, on that thread, looks at where the call was interrupted:
//!
//! - In Roc's own code (the compiled app, in a segment of its own: `__ROC_TEXT` on macOS, an
//!   executable segment apart from the host's on Linux): it makes the thread, once the handler
//!   returns, call `preempted` as if Roc had called it there. That ends the call as `roc_crashed`
//!   does, jumping back to its guard (`hosted::cut_off`), so the only frames it skips are Roc's,
//!   which hold nothing a crash at that instruction wouldn't: what the call allocated is in its list
//!   and freed, as for any crash.
//! - Anywhere else (the host's code, a hosted function, the C library: a lock may be held, a list
//!   half linked): it only notes that the call is to be cut off. The next allocation Roc asks for
//!   (`roc_alloc`, `roc_realloc`, `roc_dealloc`, called only by Roc's code) ends the call there,
//!   holding nothing, and the next signal finds it in Roc's code otherwise.
//!
//! Where the app's code can't be told from the host's, nothing is interrupted, and a time limit cuts
//! a call off only at an effect that waits, as before: an optimized build (`--opt=speed`: LLVM, and
//! the system's linker, which puts Roc's code in the host's `__TEXT`); only the fork's fast dev link
//! (`--opt=dev`, as `rocx dev` and the tests build) gives it a segment of its own. The log says so
//! once, the first time a call with a deadline runs.

use std::cell::Cell;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
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
}

/// Every Roc thread's slot (they live as long as the process).
static SLOTS: Mutex<Vec<&'static Slot>> = Mutex::new(Vec::new());

/// Where Roc's compiled code is: [low, high). (0, 0) until `start` finds it, and if it can't.
static ROC_LOW: AtomicUsize = AtomicUsize::new(0);
static ROC_HIGH: AtomicUsize = AtomicUsize::new(0);

static WATCHDOG: OnceLock<Thread> = OnceLock::new();
/// Whether calls past their deadline are interrupted (`start` found Roc's code).
static AVAILABLE: AtomicBool = AtomicBool::new(false);
/// Whether the log has said they aren't, in this build.
static SAID: AtomicBool = AtomicBool::new(false);
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

/// Finds Roc's code, handles the signal, and starts the watchdog: once, before Roc's threads start.
/// Without Roc's code found, nothing: deadlines are checked by effects that wait alone.
pub fn start() {
    let _ = epoch();
    let Some((low, high)) = roc_code() else { return };
    ROC_LOW.store(low, Ordering::Relaxed);
    ROC_HIGH.store(high, Ordering::Relaxed);
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = interrupted as *const () as usize;
        action.sa_flags = libc::SA_SIGINFO | libc::SA_ONSTACK | libc::SA_RESTART;
        libc::sigemptyset(&mut action.sa_mask);
        if libc::sigaction(libc::SIGURG, &action, std::ptr::null_mut()) != 0 {
            ROC_HIGH.store(0, Ordering::Relaxed);
            return;
        }
    }
    if let Ok(started) = std::thread::Builder::new().name("rocx-deadlines".into()).spawn(watch) {
        let _ = WATCHDOG.set(started.thread().clone());
        AVAILABLE.store(true, Ordering::Release);
    }
}

/// Whether a call past its deadline is interrupted in this build (see above).
pub fn available() -> bool {
    AVAILABLE.load(Ordering::Acquire)
}

/// Gives this thread (one of Roc's, starting) its slot.
pub fn register() {
    let slot: &'static Slot = Box::leak(Box::new(Slot { deadline: AtomicU64::new(0), pending: AtomicBool::new(false), thread: unsafe { libc::pthread_self() } as usize }));
    SLOT.with(|this| this.set(slot));
    SLOTS.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).push(slot);
}

fn slot() -> Option<&'static Slot> {
    let slot = SLOT.with(Cell::get);
    (!slot.is_null()).then(|| unsafe { &*slot })
}

/// The call running on this thread now has `deadline` (none: a call without one, or none running).
/// Whatever was noted for the call before is forgotten.
pub fn set_deadline(deadline: Option<Instant>) {
    let Some(slot) = slot() else { return };
    if deadline.is_some() && !available() && !SAID.swap(true, Ordering::Relaxed) {
        crate::logging::info("rocx server: a time limit cuts a call off at an effect that waits, not in Roc that never waits: this build's Roc code can't be told from the host's (an optimized build)", &[]);
    }
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
/// thread is in Roc's code (it calls `preempted` when the handler returns), else at its next
/// allocation. Only atomics and the interrupted context are touched here.
extern "C" fn interrupted(_: libc::c_int, _: *mut libc::siginfo_t, context: *mut libc::c_void) {
    let Some(slot) = slot() else { return };
    let deadline = slot.deadline.load(Ordering::SeqCst);
    if deadline == 0 || nanos(Instant::now()) < deadline {
        return;
    }
    let (low, high) = (ROC_LOW.load(Ordering::Relaxed), ROC_HIGH.load(Ordering::Relaxed));
    if unsafe { redirect(context as *mut libc::ucontext_t, low, high) } {
        return;
    }
    slot.pending.store(true, Ordering::Relaxed);
}

/// Where the thread goes from Roc's code: it never returns, ending the call (`hosted::preempted`).
extern "C" fn preempted() -> ! {
    crate::hosted::preempted()
}

/// If the interrupted context is in Roc's code, sets it to call `preempted` there (its return
/// address the instruction it was at, for a backtrace's sake): true. Else leaves it: false.
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
unsafe fn redirect(context: *mut libc::ucontext_t, low: usize, high: usize) -> bool {
    let state = unsafe { &mut (*(*context).uc_mcontext).__ss };
    let pc = state.__pc as usize;
    if pc < low || pc >= high {
        return false;
    }
    state.__lr = state.__pc;
    state.__pc = preempted as *const () as u64;
    true
}

#[cfg(all(target_os = "macos", target_arch = "x86_64"))]
unsafe fn redirect(context: *mut libc::ucontext_t, low: usize, high: usize) -> bool {
    let state = unsafe { &mut (*(*context).uc_mcontext).__ss };
    let pc = state.__rip as usize;
    if pc < low || pc >= high {
        return false;
    }
    // A call's frame: below the red zone, aligned as a call leaves it, the return address pushed.
    let sp = ((state.__rsp - 128) & !15) - 8;
    unsafe { *(sp as *mut u64) = state.__rip };
    state.__rsp = sp;
    state.__rip = preempted as *const () as u64;
    true
}

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
unsafe fn redirect(context: *mut libc::ucontext_t, low: usize, high: usize) -> bool {
    let state = unsafe { &mut (*context).uc_mcontext };
    let pc = state.pc as usize;
    if pc < low || pc >= high {
        return false;
    }
    state.regs[30] = state.pc;
    state.pc = preempted as *const () as u64;
    true
}

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
unsafe fn redirect(context: *mut libc::ucontext_t, low: usize, high: usize) -> bool {
    let registers = unsafe { &mut (*context).uc_mcontext.gregs };
    let pc = registers[libc::REG_RIP as usize] as usize;
    if pc < low || pc >= high {
        return false;
    }
    let sp = ((registers[libc::REG_RSP as usize] as u64 - 128) & !15) - 8;
    unsafe { *(sp as *mut u64) = registers[libc::REG_RIP as usize] as u64 };
    registers[libc::REG_RSP as usize] = sp as i64;
    registers[libc::REG_RIP as usize] = preempted as *const () as i64;
    true
}

/// The host's own code, an address in it: Roc's must be elsewhere.
fn host_code() -> usize {
    set_deadline as *const () as usize
}

/// Roc's compiled code, as the executable has it loaded: the `__ROC_TEXT` segment.
#[cfg(target_os = "macos")]
#[allow(deprecated)] // libc's Mach-O types: the `mach2` crate has them too, for one read here.
fn roc_code() -> Option<(usize, usize)> {
    unsafe {
        let header = libc::_dyld_get_image_header(0) as *const libc::mach_header_64;
        if header.is_null() || (*header).magic != libc::MH_MAGIC_64 {
            return None;
        }
        let slide = libc::_dyld_get_image_vmaddr_slide(0) as usize;
        let mut command = header.add(1) as *const libc::load_command;
        for _ in 0..(*header).ncmds {
            if (*command).cmd == libc::LC_SEGMENT_64 {
                let segment = &*(command as *const libc::segment_command_64);
                let name: Vec<u8> = segment.segname.iter().take_while(|byte| **byte != 0).map(|byte| *byte as u8).collect();
                if name == b"__ROC_TEXT" {
                    let low = segment.vmaddr as usize + slide;
                    let high = low + segment.vmsize as usize;
                    return (low < high && !(low..high).contains(&host_code())).then_some((low, high));
                }
            }
            command = (command as *const u8).add((*command).cmdsize as usize) as *const libc::load_command;
        }
        None
    }
}

/// Roc's compiled code, as the executable has it loaded: its one executable segment that isn't
/// the host's (Roc's linker puts it apart, `.text.roc`).
#[cfg(target_os = "linux")]
fn roc_code() -> Option<(usize, usize)> {
    struct Found {
        host: usize,
        others: Vec<(usize, usize)>,
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
            if header.p_type == libc::PT_LOAD && header.p_flags & libc::PF_X != 0 {
                let low = info.dlpi_addr as usize + header.p_vaddr as usize;
                let high = low + header.p_memsz as usize;
                if !(low..high).contains(&found.host) {
                    found.others.push((low, high));
                }
            }
        }
        1
    }
    let mut found = Found { host: host_code(), others: Vec::new(), seen: false };
    unsafe { libc::dl_iterate_phdr(Some(each), &mut found as *mut Found as *mut libc::c_void) };
    match found.others.as_slice() {
        [only] if only.0 < only.1 => Some(*only),
        _ => None,
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn roc_code() -> Option<(usize, usize)> {
    None
}
