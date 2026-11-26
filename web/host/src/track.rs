//! Roc's memory: each allocation with a header of the host's, and what a run that unwinds leaves.
//!
//! Before what Roc gets, 8 bytes (or its alignment's, if more): the allocation's number, if a frame
//! was open when it was made (`note`; 0 if not, or once the host holds it), then its length. Its
//! number says which frame made it without a lookup: a frame's are those numbered since it began.
//!
//! A read that waits (or fails) unwinds the run that made it with a JS throw, through the Roc frames
//! above it, which never get to let go of what they hold: whatever the run had allocated and still
//! held (a URL it built, a value it was computing) would stay allocated for good, a few allocations
//! every time a memo or a hole waits. So the runtime opens a frame around each call into Roc
//! (`frame_begin`), and the host notes every allocation made while one is open, and every box handed
//! to the runtime meanwhile (`hand`). A call that returns closes its frame (`frame_end`): what it
//! made is Roc's to let go of, as ever, and its notes are the frame's around it, if any (a run inside
//! a run: a memo made by a component). One that unwinds (`frame_unwound`) keeps its notes until the
//! runtime has let go of everything the run handed it (the computations, signals, cleanups and boxes
//! it made; `reclaim`). What the run made that is still allocated is then held by nothing but the
//! frames that unwound, and is freed. Roc's values are immutable, and a value the runtime gives Roc
//! comes with a reference of the runtime's own, so nothing made before the run points at what the run
//! made, and only the boxes it handed over could. Should one of those still be allocated (the
//! runtime keeps it, or a frame that unwound held it too), nothing is freed and the notes are the
//! frame's around it: a leak, never a use after free. What the unwound frames held of older values
//! (a reference counted once more) stays counted.
//!
//! The notes are one log (`notes`, `handed`) while frames are open: a frame's are those from where
//! it began, so one inside another that returns gives its notes to the frame around it by doing
//! nothing, and the outermost's are forgotten by emptying the log. An allocation's number (in its
//! header) says whether it is a frame's own: numbered since the frame began. Which addresses are
//! allocations a frame noted, still allocated, is a bitmap (`starts`), so a note of one since freed
//! (or of an address allocated again since, with another number) is passed over, exactly.
//!
//! Nothing here calls out of the wasm: the state is borrowed only for the length of a call.

use crate::{Global, brk};
use alloc::vec::Vec;

/// An allocation noted: its address with its alignment code in the low 3 bits, and its number.
#[derive(Clone, Copy)]
struct Note {
    at: u32,
    number: u32,
}

struct Frame {
    id: u32,
    /// The frame open around it when it began.
    parent: u32,
    /// The number the first allocation made while it was open got: those numbered since are its own.
    first: u32,
    /// Where its notes, and the boxes it handed to the runtime, start in the log.
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
    /// Allocations Roc holds now, and has made since the module started (for the tests).
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
    /// A bit per 8 bytes of memory: set where an allocation a frame noted starts, while it is
    /// allocated.
    starts: Vec<u32>,
}

static MEMORY: Global<Memory> = Global::new(Memory {
    live: 0,
    allocated: 0,
    notes: Vec::new(),
    handed: Vec::new(),
    frames: Vec::new(),
    unwound: Vec::new(),
    frame_ids: 0,
    next_number: 1,
    starts: Vec::new(),
});

/// The header's bytes for an alignment code (`align_code`): 8, 16, 32…
fn header_bytes(code: u32) -> usize {
    8 << code
}

/// An alignment as a code of 3 bits (one of 8 bytes or less: 0, 16: 1, 32: 2…), kept in a note's
/// address (an allocation's is a multiple of 8).
fn align_code(alignment: usize) -> u32 {
    alignment.max(8).ilog2() - 3
}

fn number_of(ptr: usize) -> *mut u32 {
    (ptr - 8) as *mut u32
}

fn length_of(ptr: usize) -> *mut usize {
    (ptr - size_of::<usize>()) as *mut usize
}

/// Whether `number` was given at or after `first` and before `end` (numbers wrap around).
fn within(number: u32, first: u32, end: u32) -> bool {
    number != 0 && number.wrapping_sub(first) < end.wrapping_sub(first)
}

fn out_of_memory() -> ! {
    crate::crashed(b"roc_alloc: out of memory")
}

/// `length` bytes for Roc, aligned to `alignment`.
pub fn alloc(length: usize, alignment: usize) -> *mut u8 {
    let memory = MEMORY.get();
    memory.live += 1;
    memory.allocated += 1;
    let code = align_code(alignment);
    let header = header_bytes(code);
    let base = brk::alloc(length + header, header);
    if base.is_null() {
        out_of_memory();
    }
    let ptr = base as usize + header;
    unsafe {
        *length_of(ptr) = length;
        *number_of(ptr) = 0;
    }
    if !memory.frames.is_empty() {
        memory.note(ptr, code);
    }
    ptr as *mut u8
}

pub fn dealloc(ptr: *mut u8, alignment: usize) {
    let memory = MEMORY.get();
    memory.live -= 1;
    memory.unmark(ptr as usize);
    free_allocation(ptr as usize, align_code(alignment));
}

fn free_allocation(ptr: usize, code: u32) {
    let header = header_bytes(code);
    brk::free((ptr - header) as *mut u8, unsafe { *length_of(ptr) } + header, header);
}

/// Grown where it is if the allocator can (the same size of slot), else moved: still the frame's
/// that made it, if one open or unwound did (`renote`).
pub fn realloc(ptr: *mut u8, new_length: usize, alignment: usize) -> *mut u8 {
    let memory = MEMORY.get();
    let ptr = ptr as usize;
    let code = align_code(alignment);
    let header = header_bytes(code);
    let old_length = unsafe { *length_of(ptr) };
    let base = (ptr - header) as *mut u8;
    if brk::resize(old_length + header, header, new_length + header) {
        unsafe { *length_of(ptr) = new_length };
        return ptr as *mut u8;
    }
    let new_base = brk::alloc(new_length + header, header);
    if new_base.is_null() {
        out_of_memory();
    }
    let moved = new_base as usize + header;
    unsafe {
        core::ptr::copy_nonoverlapping(ptr as *const u8, moved as *mut u8, old_length.min(new_length));
        *length_of(moved) = new_length;
        *number_of(moved) = 0;
    }
    let number = unsafe { *number_of(ptr) };
    if memory.marked(ptr) && number != 0 {
        memory.renote(moved, code, number);
    }
    memory.unmark(ptr);
    brk::free(base, old_length + header, header);
    moved as *mut u8
}

impl Memory {
    fn mark(&mut self, ptr: usize) -> bool {
        let index = ptr >> 3;
        let word = index >> 5;
        if word >= self.starts.len() {
            let wanted = (word + 1).max(self.starts.len() * 2);
            if self.starts.try_reserve_exact(wanted - self.starts.len()).is_err() {
                return false;
            }
            self.starts.resize(wanted, 0);
        }
        self.starts[word] |= 1 << (index & 31);
        true
    }

    fn unmark(&mut self, ptr: usize) {
        let index = ptr >> 3;
        if let Some(word) = self.starts.get_mut(index >> 5) {
            *word &= !(1 << (index & 31));
        }
    }

    /// Whether an allocation a frame noted starts at `ptr`, still allocated.
    fn marked(&self, ptr: usize) -> bool {
        if ptr & 7 != 0 {
            return false;
        }
        let index = ptr >> 3;
        self.starts.get(index >> 5).is_some_and(|word| word & (1 << (index & 31)) != 0)
    }

    fn innermost_unnoted(&mut self) {
        if let Some(frame) = self.frames.last_mut() {
            frame.noted = false;
        }
    }

    /// An allocation made while a frame is open: numbered, and noted in the log.
    fn note(&mut self, ptr: usize, code: u32) {
        let number = self.next_number;
        self.next_number = self.next_number.wrapping_add(1).max(1);
        if !self.mark(ptr) {
            return self.innermost_unnoted();
        }
        if self.notes.try_reserve(1).is_err() {
            self.unmark(ptr);
            return self.innermost_unnoted();
        }
        self.notes.push(Note { at: (ptr | code as usize) as u32, number });
        unsafe { *number_of(ptr) = number };
    }

    /// An allocation moved (`realloc`), numbered `number`: noted again where it is now, for the open
    /// frame or the unwound one whose it is.
    fn renote(&mut self, ptr: usize, code: u32, number: u32) {
        let entry = Note { at: (ptr | code as usize) as u32, number };
        let mut kept = false;
        if self.frames.first().is_some_and(|outermost| within(number, outermost.first, self.next_number)) {
            if self.mark(ptr) && self.notes.try_reserve(1).is_ok() {
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
            if !self.mark(ptr) || self.unwound[at].notes.try_reserve(1).is_err() {
                self.unwound[at].noted = false;
                continue;
            }
            self.unwound[at].notes.push(entry);
            kept = true;
        }
        if kept {
            unsafe { *number_of(ptr) = number };
        } else {
            self.unmark(ptr);
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
            let ptr = (entry.at & !7) as usize;
            self.own(frame, entry, ptr) && at >= ptr && at < ptr + unsafe { *length_of(ptr) }
        })
    }

    /// Whether the note is of the frame's own allocation, still allocated.
    fn own(&self, frame: &Unwound, entry: &Note, ptr: usize) -> bool {
        self.marked(ptr) && unsafe { *number_of(ptr) } == entry.number && within(entry.number, frame.first, frame.end)
    }
}

/// A call into Roc starts: what it allocates is noted until it ends.
pub fn frame_begin() -> u32 {
    let memory = MEMORY.get();
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
}

/// It returned: what it made is Roc's (and the runtime's) to let go of.
pub fn frame_end(id: u32) {
    if id == 0 {
        return;
    }
    let memory = MEMORY.get();
    while let Some(frame) = memory.frames.pop() {
        let done = frame.id == id;
        memory.ended(frame);
        if done {
            break;
        }
    }
}

/// It unwound (a JS throw): its notes wait for `reclaim`.
pub fn frame_unwound(id: u32) {
    if id == 0 {
        return;
    }
    let memory = MEMORY.get();
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
}

/// The runtime has let go of everything the unwound run handed it: what the run made that is still
/// allocated is freed, unless a box it handed over is still allocated.
pub fn reclaim(id: u32) {
    let memory = MEMORY.get();
    let Some(at) = memory.unwound.iter().position(|frame| frame.id == id) else { return };
    let mut frame = memory.unwound.swap_remove(at);
    frame.noted = memory.take_waiting(frame.id, frame.last, frame.noted);
    let held = !frame.noted || frame.handed.iter().any(|&boxed| memory.own_allocation_holds(&frame, boxed));
    if held {
        return memory.hand_on(frame);
    }
    for entry in &frame.notes {
        let ptr = (entry.at & !7) as usize;
        if !memory.own(&frame, entry, ptr) {
            continue;
        }
        memory.unmark(ptr);
        memory.live -= 1;
        free_allocation(ptr, entry.at & 7);
    }
}

/// A box handed to the runtime: noted in the innermost frame open (see `reclaim`).
pub fn hand(at: usize) {
    let memory = MEMORY.get();
    if memory.frames.is_empty() {
        return;
    }
    if memory.handed.try_reserve(1).is_ok() {
        memory.handed.push(at);
    } else {
        memory.innermost_unnoted();
    }
}

/// A string the host holds (the last run's answer): never freed with the frame it was made in (its
/// number taken off, so no note of it is its). `allocation` is where its allocation starts.
pub fn held(allocation: usize) {
    let memory = MEMORY.get();
    let Some(frame) = memory.frames.last() else { return };
    if memory.marked(allocation) && within(unsafe { *number_of(allocation) }, frame.first, memory.next_number) {
        unsafe { *number_of(allocation) = 0 };
    }
}

/// Allocations Roc holds now.
pub fn live() -> i64 {
    MEMORY.get().live
}

/// Allocations Roc has made since the module started.
pub fn allocated() -> i64 {
    MEMORY.get().allocated
}

/// The notes the host keeps (0 between runs, unless an unwound run waits for `reclaim`), and the
/// room it keeps for them.
pub fn notes_kept() -> u32 {
    let memory = MEMORY.get();
    let unwound: usize = memory.unwound.iter().map(|frame| frame.notes.len() + frame.handed.len()).sum();
    (memory.notes.len() + memory.handed.len() + unwound) as u32
}

pub fn notes_room() -> u32 {
    let memory = MEMORY.get();
    (memory.notes.capacity() + memory.handed.capacity()) as u32
}
