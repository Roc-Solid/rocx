//! Roc's memory for the web platform's two hosts: the browser's (web/host, in the page's wasm) and
//! the phone's (native/core, D-063). Each allocation has a header of the host's, and what a call
//! into Roc that ends early (a read that waits or fails, D-027's browser twin) held is freed.
//!
//! Before what Roc gets, a header (8 bytes on wasm32, 16 on a 64-bit machine, or its alignment's,
//! if more): the allocation's number, if a frame was open when it was made (`note`; 0 if not, or
//! once the host holds it), then its length, in the header's last word. Its number says which frame
//! made it without a lookup: a frame's are those numbered since it began.
//!
//! A read that waits (or fails) ends the run that made it early: a JS throw in a browser, a jump
//! back to the guard on a phone, through the Roc frames above it, which never get to let go of
//! what they hold. Whatever the run had allocated and still held (a URL it built, a value it was
//! computing) would stay allocated for good, a few allocations every time a memo or a hole waits.
//! So the host opens a frame around each call into Roc (`frame_begin`), and notes every allocation
//! made while one is open, and every box handed to the engine meanwhile (`hand`). A call that
//! returns closes its frame (`frame_end`): what it made is Roc's to let go of, as ever, and its
//! notes are the frame's around it, if any (a run inside a run: a memo made by a component). One
//! that unwinds (`frame_unwound`) keeps its notes until the engine has let go of everything the run
//! handed it (the computations, signals, cleanups and boxes it made; `reclaim`). What the run made
//! that is still allocated is then held by nothing but the frames that unwound, and is freed. Roc's
//! values are immutable, and a value the engine gives Roc comes with a reference of the engine's
//! own, so nothing made before the run points at what the run made, and only the boxes it handed
//! over could. Should one of those still be allocated (the engine keeps it, or a frame that unwound
//! held it too), nothing is freed and the notes are the frame's around it: a leak, never a use
//! after free. What the unwound frames held of older values (a reference counted once more) stays
//! counted.
//!
//! The notes are one log (`notes`, `handed`) while frames are open: a frame's are those from where
//! it began, so one inside another that returns gives its notes to the frame around it by doing
//! nothing, and the outermost's are forgotten by emptying the log. An allocation's number (in its
//! header) says whether it is a frame's own: numbered since the frame began. Which addresses are
//! allocations a frame noted, still allocated, is a set (`Marks`: a bitmap on wasm32, a hash set
//! on a 64-bit machine), so a note of one since freed (or of an address allocated again since,
//! with another number) is passed over, exactly.
//!
//! Memory comes from the program's global allocator: in a browser, `brk` (Zig's allocator for
//! wasm, ported), which the host makes its global allocator; on a phone, the system's. Calls into
//! Roc are one at a time, on one thread: the state's lock only keeps it whole should another
//! thread allocate.

#![cfg_attr(not(test), no_std)]

extern crate alloc;

pub mod brk;
mod marks;

use alloc::alloc::{Layout, alloc, dealloc, realloc as grow};
use alloc::vec::Vec;
use core::cell::UnsafeCell;
use core::sync::atomic::AtomicBool;
#[cfg(not(target_arch = "wasm32"))]
use core::sync::atomic::Ordering;
use marks::Marks;

const WORD: usize = size_of::<usize>();
/// The least header: room for the number (a u32) and the length (a word), and the least alignment
/// of what Roc gets.
const LEAST: usize = if WORD == 4 { 8 } else { 16 };

/// An allocation noted: its address with its alignment code in the low 3 bits, and its number.
#[derive(Clone, Copy)]
struct Note {
    at: usize,
    number: u32,
}

struct Frame {
    id: u32,
    /// The frame open around it when it began.
    parent: u32,
    /// The number the first allocation made while it was open got: those numbered since are its own.
    first: u32,
    /// Where its notes, and the boxes it handed to the engine, start in the log.
    notes_at: usize,
    handed_at: usize,
    /// Whether everything was noted (out of memory to note something: never reclaimed).
    noted: bool,
}

/// A frame that unwound, waiting for `reclaim`: its notes, copied out of the log.
struct Unwound {
    id: u32,
    parent: u32,
    first: u32,
    /// The number after its last allocation: its own are numbered from `first` to before this.
    end: u32,
    /// The last frame id given out before it unwound: the frames inside it are those after its own
    /// id, to this one.
    last: u32,
    notes: Vec<Note>,
    handed: Vec<usize>,
    noted: bool,
}

struct Memory {
    /// Allocations Roc holds now, and has made since the program started (for the tests).
    live: i64,
    allocated: i64,
    notes: Vec<Note>,
    handed: Vec<usize>,
    /// The frames open, innermost last, and the unwound ones waiting for `reclaim`.
    frames: Vec<Frame>,
    unwound: Vec<Unwound>,
    frame_ids: u32,
    /// The next allocation's number (never 0, which is none).
    next_number: u32,
    /// Where an allocation a frame noted starts, while it is allocated.
    marks: Marks,
}

/// The state, locked while it is used.
struct Locked {
    #[cfg_attr(target_arch = "wasm32", allow(dead_code))]
    busy: AtomicBool,
    memory: UnsafeCell<Memory>,
}

unsafe impl Sync for Locked {}

static MEMORY: Locked = Locked {
    busy: AtomicBool::new(false),
    memory: UnsafeCell::new(Memory {
        live: 0,
        allocated: 0,
        notes: Vec::new(),
        handed: Vec::new(),
        frames: Vec::new(),
        unwound: Vec::new(),
        frame_ids: 0,
        next_number: 1,
        marks: Marks::new(),
    }),
};

/// Runs `f` with the state. Nothing in here calls out (but the global allocator, which isn't this),
/// so the lock is never wanted twice. A browser's wasm has one thread: no lock there.
fn with<R>(f: impl FnOnce(&mut Memory) -> R) -> R {
    #[cfg(not(target_arch = "wasm32"))]
    while MEMORY.busy.compare_exchange_weak(false, true, Ordering::Acquire, Ordering::Relaxed).is_err() {
        core::hint::spin_loop();
    }
    let answer = f(unsafe { &mut *MEMORY.memory.get() });
    #[cfg(not(target_arch = "wasm32"))]
    MEMORY.busy.store(false, Ordering::Release);
    answer
}

/// The header's bytes for an alignment code (`align_code`): the least, twice it, four times…
fn header_bytes(code: usize) -> usize {
    LEAST << code
}

/// An alignment as a code of 3 bits (one of the least or less: 0, twice it: 1…), kept in a note's
/// address (an allocation's is a multiple of the least).
fn align_code(alignment: usize) -> usize {
    (alignment.max(LEAST).ilog2() - LEAST.ilog2()) as usize
}

fn layout(length: usize, header: usize) -> Layout {
    unsafe { Layout::from_size_align_unchecked(length + header, header) }
}

fn number_of(ptr: usize) -> *mut u32 {
    (ptr - WORD - 4) as *mut u32
}

fn length_of(ptr: usize) -> *mut usize {
    (ptr - WORD) as *mut usize
}

/// Whether `number` was given at or after `first` and before `end` (numbers wrap around).
fn within(number: u32, first: u32, end: u32) -> bool {
    number != 0 && number.wrapping_sub(first) < end.wrapping_sub(first)
}

/// `length` bytes for Roc, aligned to `alignment`: null when there is no memory (the host stops).
pub fn alloc_for_roc(length: usize, alignment: usize) -> *mut u8 {
    let code = align_code(alignment);
    let header = header_bytes(code);
    let base = unsafe { alloc(layout(length, header)) };
    if base.is_null() {
        return base;
    }
    let ptr = base as usize + header;
    unsafe {
        *length_of(ptr) = length;
        *number_of(ptr) = 0;
    }
    with(|memory| {
        memory.live += 1;
        memory.allocated += 1;
        if !memory.frames.is_empty() {
            memory.note(ptr, code);
        }
    });
    ptr as *mut u8
}

pub fn dealloc_for_roc(ptr: *mut u8, alignment: usize) {
    let ptr = ptr as usize;
    with(|memory| {
        memory.live -= 1;
        memory.marks.remove(ptr);
    });
    free_allocation(ptr, align_code(alignment));
}

fn free_allocation(ptr: usize, code: usize) {
    let header = header_bytes(code);
    unsafe { dealloc((ptr - header) as *mut u8, layout(*length_of(ptr), header)) };
}

/// Grown where it is if the allocator can, else moved: still the frame's that made it, if one open
/// or unwound did (`renote`). Null when there is no memory (the host stops).
pub fn realloc_for_roc(ptr: *mut u8, new_length: usize, alignment: usize) -> *mut u8 {
    let ptr = ptr as usize;
    let code = align_code(alignment);
    let header = header_bytes(code);
    let old_length = unsafe { *length_of(ptr) };
    let (number, noted) = with(|memory| (unsafe { *number_of(ptr) }, memory.marks.contains(ptr)));
    let base = (ptr - header) as *mut u8;
    let moved_base = unsafe { grow(base, layout(old_length, header), new_length + header) };
    if moved_base.is_null() {
        return moved_base;
    }
    let moved = moved_base as usize + header;
    unsafe { *length_of(moved) = new_length };
    if moved == ptr {
        return moved as *mut u8;
    }
    // Moved: the old allocation is gone, and the new one is the frame's that made the old one.
    unsafe { *number_of(moved) = 0 };
    with(|memory| {
        memory.marks.remove(ptr);
        if noted && number != 0 {
            memory.renote(moved, code, number);
        }
    });
    moved as *mut u8
}

impl Memory {
    fn innermost_unnoted(&mut self) {
        if let Some(frame) = self.frames.last_mut() {
            frame.noted = false;
        }
    }

    /// An allocation made while a frame is open: numbered, and noted in the log.
    fn note(&mut self, ptr: usize, code: usize) {
        let number = self.next_number;
        self.next_number = self.next_number.wrapping_add(1).max(1);
        if !self.marks.insert(ptr) {
            return self.innermost_unnoted();
        }
        if self.notes.try_reserve(1).is_err() {
            self.marks.remove(ptr);
            return self.innermost_unnoted();
        }
        self.notes.push(Note { at: ptr | code, number });
        unsafe { *number_of(ptr) = number };
    }

    /// An allocation moved (`realloc_for_roc`), numbered `number`: noted again where it is now, for
    /// the open frame or the unwound one whose it is.
    fn renote(&mut self, ptr: usize, code: usize, number: u32) {
        let entry = Note { at: ptr | code, number };
        let mut kept = false;
        if self.frames.first().is_some_and(|outermost| within(number, outermost.first, self.next_number)) {
            if self.marks.insert(ptr) && self.notes.try_reserve(1).is_ok() {
                self.notes.push(entry);
                kept = true;
            } else {
                self.innermost_unnoted();
            }
        }
        for at in 0..self.unwound.len() {
            if !within(number, self.unwound[at].first, self.unwound[at].end) {
                continue;
            }
            if !self.marks.insert(ptr) || self.unwound[at].notes.try_reserve(1).is_err() {
                self.unwound[at].noted = false;
                continue;
            }
            self.unwound[at].notes.push(entry);
            kept = true;
        }
        if kept {
            unsafe { *number_of(ptr) = number };
        } else {
            self.marks.remove(ptr);
        }
    }

    /// The unwound frames inside frame `id` (begun after it, to frame `last`; frames nest), still
    /// waiting: theirs are its notes now (they are among its own), so they go; whether all of them
    /// were noted.
    fn take_waiting(&mut self, id: u32, last: u32, noted: bool) -> bool {
        let mut all = noted;
        let mut at = 0;
        while at < self.unwound.len() {
            let frame = &self.unwound[at];
            if frame.id.wrapping_sub(id).wrapping_sub(1) < last.wrapping_sub(id) {
                all = all && frame.noted;
                self.unwound.swap_remove(at);
            } else {
                at += 1;
            }
        }
        all
    }

    /// The log emptied: the outermost frame is done. A big run's room is given back.
    fn forget_notes(&mut self) {
        if self.notes.capacity() > 1 << 14 {
            self.notes = Vec::new();
        } else {
            self.notes.clear();
        }
        if self.handed.capacity() > 1 << 12 {
            self.handed = Vec::new();
        } else {
            self.handed.clear();
        }
    }

    /// A frame closed (its call returned, or one inside it unwound past it): its notes are the
    /// frame's around it (they are in the log, where that one's are), or forgotten if it was the
    /// outermost.
    fn ended(&mut self, frame: Frame) {
        let noted = self.take_waiting(frame.id, self.frame_ids, frame.noted);
        match self.frames.last_mut() {
            Some(around) => around.noted = around.noted && noted,
            None => self.forget_notes(),
        }
    }

    /// An unwound frame's notes, given up on: the frame's around it, if that is open (they are in
    /// the log, where its are), else forgotten.
    fn hand_on(&mut self, frame: Unwound) {
        if let Some(open) = self.frames.iter_mut().find(|open| open.id == frame.parent) {
            open.noted = open.noted && frame.noted;
        }
    }

    /// Whether the frame's own allocation, still allocated, holds the address `at`.
    fn own_allocation_holds(&self, frame: &Unwound, at: usize) -> bool {
        frame.notes.iter().any(|entry| {
            let ptr = entry.at & !7;
            self.own(frame, entry, ptr) && at >= ptr && at < ptr + unsafe { *length_of(ptr) }
        })
    }

    /// Whether the note is of the frame's own allocation, still allocated.
    fn own(&self, frame: &Unwound, entry: &Note, ptr: usize) -> bool {
        self.marks.contains(ptr) && unsafe { *number_of(ptr) } == entry.number && within(entry.number, frame.first, frame.end)
    }
}

/// A call into Roc starts: what it allocates is noted until it ends. Its id (0: nothing noted).
pub fn frame_begin() -> u32 {
    with(|memory| {
        memory.frame_ids = memory.frame_ids.wrapping_add(1).max(1);
        let parent = memory.frames.last().map_or(0, |frame| frame.id);
        if memory.frames.try_reserve(1).is_err() {
            return 0;
        }
        memory.frames.push(Frame {
            id: memory.frame_ids,
            parent,
            first: memory.next_number,
            notes_at: memory.notes.len(),
            handed_at: memory.handed.len(),
            noted: true,
        });
        memory.frame_ids
    })
}

/// It returned: what it made is Roc's (and the engine's) to let go of.
pub fn frame_end(id: u32) {
    if id == 0 {
        return;
    }
    with(|memory| {
        while let Some(frame) = memory.frames.pop() {
            let done = frame.id == id;
            memory.ended(frame);
            if done {
                break;
            }
        }
    })
}

/// It unwound: its notes wait for `reclaim`.
pub fn frame_unwound(id: u32) {
    if id == 0 {
        return;
    }
    with(|memory| {
        while let Some(frame) = memory.frames.pop() {
            if frame.id != id {
                memory.ended(frame);
                continue;
            }
            let noted = memory.take_waiting(frame.id, memory.frame_ids, frame.noted);
            let mut waiting = Unwound {
                id: frame.id,
                parent: frame.parent,
                first: frame.first,
                end: memory.next_number,
                last: memory.frame_ids,
                notes: Vec::new(),
                handed: Vec::new(),
                noted,
            };
            let notes = memory.notes.get(frame.notes_at..).unwrap_or(&[]);
            if waiting.notes.try_reserve_exact(notes.len()).is_ok() {
                waiting.notes.extend_from_slice(notes);
            } else {
                waiting.noted = false;
            }
            let handed = memory.handed.get(frame.handed_at..).unwrap_or(&[]);
            if waiting.handed.try_reserve_exact(handed.len()).is_ok() {
                waiting.handed.extend_from_slice(handed);
            } else {
                waiting.noted = false;
            }
            if memory.frames.is_empty() {
                memory.forget_notes();
            }
            // Never reclaimed, from a run outside any other: let go of the oldest notes.
            if memory.unwound.len() >= 64 {
                let oldest = memory.unwound.remove(0);
                memory.hand_on(oldest);
            }
            if memory.unwound.try_reserve(1).is_ok() {
                memory.unwound.push(waiting);
            } else {
                memory.hand_on(waiting);
            }
            return;
        }
    })
}

/// The engine has let go of everything the unwound run handed it: what the run made that is still
/// allocated is freed, unless a box it handed over is still allocated.
pub fn reclaim(id: u32) {
    let frees = with(|memory| {
        let at = memory.unwound.iter().position(|frame| frame.id == id)?;
        let mut frame = memory.unwound.swap_remove(at);
        frame.noted = memory.take_waiting(frame.id, frame.last, frame.noted);
        let held = !frame.noted || frame.handed.iter().any(|&boxed| memory.own_allocation_holds(&frame, boxed));
        if held {
            memory.hand_on(frame);
            return None;
        }
        let mut frees = Vec::new();
        for entry in &frame.notes {
            let ptr = entry.at & !7;
            if !memory.own(&frame, entry, ptr) {
                continue;
            }
            memory.marks.remove(ptr);
            memory.live -= 1;
            frees.push(*entry);
        }
        Some(frees)
    });
    for entry in frees.unwrap_or_default() {
        free_allocation(entry.at & !7, entry.at & 7);
    }
}

/// A box handed to the engine: noted in the innermost frame open (see `reclaim`).
pub fn hand(at: usize) {
    if at == 0 {
        return;
    }
    with(|memory| {
        if memory.frames.is_empty() {
            return;
        }
        if memory.handed.try_reserve(1).is_ok() {
            memory.handed.push(at);
        } else {
            memory.innermost_unnoted();
        }
    })
}

/// An allocation the host holds past the frame it was made in (the browser's last answer): never
/// freed with that frame (its number taken off, so no note of it is its). `allocation` is where
/// it starts.
pub fn held(allocation: usize) {
    with(|memory| {
        let Some(frame) = memory.frames.last() else { return };
        if memory.marks.contains(allocation) && within(unsafe { *number_of(allocation) }, frame.first, memory.next_number) {
            unsafe { *number_of(allocation) = 0 };
        }
    })
}

/// Allocations Roc holds now.
pub fn live() -> i64 {
    with(|memory| memory.live)
}

/// Allocations Roc has made since the program started.
pub fn allocated() -> i64 {
    with(|memory| memory.allocated)
}

/// The notes the host keeps (0 between runs, unless an unwound run waits for `reclaim`), and the
/// room it keeps for them.
pub fn notes_kept() -> u32 {
    with(|memory| {
        let unwound: usize = memory.unwound.iter().map(|frame| frame.notes.len() + frame.handed.len()).sum();
        (memory.notes.len() + memory.handed.len() + unwound) as u32
    })
}

pub fn notes_room() -> u32 {
    with(|memory| (memory.notes.capacity() + memory.handed.capacity()) as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    // One test: the state is the program's, and tests run on threads at once.
    #[test]
    fn a_run_that_unwinds_is_freed_unless_it_handed_something_over() {
        let before = live();
        // A run that returns: what it made is Roc's.
        let frame = frame_begin();
        let kept = alloc_for_roc(40, 8);
        frame_end(frame);
        assert_eq!(live(), before + 1);
        assert_eq!(notes_kept(), 0);

        // A run that unwinds, holding two allocations (one grown, so moved): both freed.
        let frame = frame_begin();
        let a = alloc_for_roc(24, 8);
        let b = alloc_for_roc(16, 16);
        let b = realloc_for_roc(b, 4096, 16);
        assert!(!a.is_null() && !b.is_null());
        frame_unwound(frame);
        assert_eq!(live(), before + 3);
        reclaim(frame);
        assert_eq!(live(), before + 1);
        assert_eq!(notes_kept(), 0);

        // One that handed a box over that is still allocated: nothing freed (a leak, never a use
        // after free).
        let frame = frame_begin();
        let boxed = alloc_for_roc(32, 8);
        hand(boxed as usize + 8);
        frame_unwound(frame);
        reclaim(frame);
        assert_eq!(live(), before + 2);
        dealloc_for_roc(boxed, 8);

        // Runs inside runs: the inner one unwinds, the outer returns: the inner's are the outer's,
        // Roc's to let go of.
        let outer = frame_begin();
        let inner = frame_begin();
        let c = alloc_for_roc(8, 8);
        frame_unwound(inner);
        frame_end(outer);
        assert_eq!(live(), before + 2);
        dealloc_for_roc(c, 8);
        dealloc_for_roc(kept, 8);
        assert_eq!(live(), before);
        assert_eq!(notes_kept(), 0);
    }
}
