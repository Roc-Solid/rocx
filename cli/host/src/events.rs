//! One queue of what happened while Roc waits: files changed (`watch`), a child ended (lib.rs), a
//! signal came. `next` waits on it; files changed back to back are given as one event.

use std::collections::VecDeque;
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

pub enum Event {
    Changed(Vec<String>),
    Exited { child: u64, code: i32 },
    Signal(i32),
}

static QUEUE: Mutex<VecDeque<Event>> = Mutex::new(VecDeque::new());
static READY: Condvar = Condvar::new();

pub fn push(event: Event) {
    QUEUE.lock().unwrap().push_back(event);
    READY.notify_all();
}

/// The next event, or None after `timeout_ms` (0: no limit). The paths of changes queued one after
/// another are given together, each once.
pub fn next(timeout_ms: u64) -> Option<Event> {
    let deadline = (timeout_ms > 0).then(|| Instant::now() + Duration::from_millis(timeout_ms));
    let mut queue = QUEUE.lock().unwrap();
    loop {
        if let Some(event) = queue.pop_front() {
            if let Event::Changed(mut paths) = event {
                while let Some(Event::Changed(more)) = queue.front() {
                    paths.extend(more.iter().cloned());
                    queue.pop_front();
                }
                let mut seen = std::collections::HashSet::new();
                paths.retain(|path| seen.insert(path.clone()));
                return Some(Event::Changed(paths));
            }
            return Some(event);
        }
        match deadline {
            None => queue = READY.wait(queue).unwrap(),
            Some(deadline) => {
                let now = Instant::now();
                if now >= deadline {
                    return None;
                }
                queue = READY.wait_timeout(queue, deadline - now).unwrap().0;
            }
        }
    }
}

// ---- Signals ----

static mut PIPE_WRITE: i32 = -1;

extern "C" fn on_signal(signal: i32) {
    // Only what a signal handler may do: one write to a pipe, read by the thread below.
    let byte = signal as u8;
    unsafe { libc::write(PIPE_WRITE, &byte as *const u8 as *const libc::c_void, 1) };
}

/// SIGINT, SIGTERM and SIGHUP become events: the app decides what to do (stop its children, exit).
pub fn catch_signals() {
    let mut fds = [0i32; 2];
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return;
    }
    unsafe { PIPE_WRITE = fds[1] };
    for signal in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP] {
        unsafe {
            let mut action: libc::sigaction = std::mem::zeroed();
            action.sa_sigaction = on_signal as extern "C" fn(i32) as usize;
            action.sa_flags = libc::SA_RESTART;
            libc::sigemptyset(&mut action.sa_mask);
            libc::sigaction(signal, &action, std::ptr::null_mut());
        }
    }
    let read = fds[0];
    std::thread::spawn(move || {
        let mut byte = 0u8;
        while unsafe { libc::read(read, &mut byte as *mut u8 as *mut libc::c_void, 1) } == 1 {
            push(Event::Signal(byte as i32));
        }
    });
}
