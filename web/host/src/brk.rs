//! The host's memory: Zig's allocator for wasm (std.heap.BrkAllocator, which the Zig host used),
//! ported. Slots of a power of two in size, each size's from 64 KiB pages of its own, a freed slot
//! kept on its size's list (the list's link in the slot's last word); bigger ones, whole pages a
//! power of two in number, from `memory.grow`. Fast and small; memory is never given back to the
//! browser, but a freed slot is used again by the next of its size.

use core::alloc::{GlobalAlloc, Layout};
use core::cell::UnsafeCell;

const WORD: usize = size_of::<usize>();
const BIGPAGE: usize = 64 * 1024;
/// The smallest slot: 8 bytes (room for the free list's link and one byte), class 0.
const MIN_CLASS: u32 = 3;
/// Slots of 8 bytes to 32 KiB.
const SIZE_CLASSES: usize = (BIGPAGE.ilog2() - MIN_CLASS) as usize;
/// Runs of 1, 2, 4… big pages, to all of memory.
const BIG_CLASSES: usize = (usize::MAX / BIGPAGE).ilog2() as usize + 1;

struct Brk {
    /// Each size's next slot never used (at a page's end: a new page).
    next_addrs: [usize; SIZE_CLASSES],
    /// Each size's freed slots, the last freed first.
    frees: [usize; SIZE_CLASSES],
    big_frees: [usize; BIG_CLASSES],
}

/// The allocator's state: one, the wasm being single-threaded. Self-contained, so another crate can
/// use this file as it is (native/core's engine in a browser, spike/wasm-engine).
struct State(UnsafeCell<Brk>);

unsafe impl Sync for State {}

static BRK: State = State(UnsafeCell::new(Brk {
    next_addrs: [0; SIZE_CLASSES],
    frees: [0; SIZE_CLASSES],
    big_frees: [0; BIG_CLASSES],
}));

fn state() -> &'static mut Brk {
    unsafe { &mut *BRK.0.get() }
}

/// A slot's size class: log2 of its size, less the smallest's.
fn class_of(slot: usize) -> usize {
    (slot.max(1 << MIN_CLASS).ilog2() - MIN_CLASS) as usize
}

fn big_pages_needed(bytes: usize) -> usize {
    (bytes + (BIGPAGE + (WORD - 1))) / BIGPAGE
}

/// The link to the next free slot, in a slot's last word.
fn link(addr: usize, slot: usize) -> *mut usize {
    (addr + slot - WORD) as *mut usize
}

/// `len` bytes aligned to `alignment` (a power of two), or null when memory can't grow.
pub fn alloc(len: usize, alignment: usize) -> *mut u8 {
    let brk = state();
    // Room for the free list's link.
    let actual = len.saturating_add(WORD).max(alignment);
    let Some(slot) = actual.checked_next_power_of_two() else { return core::ptr::null_mut() };
    let class = class_of(slot);
    if class < SIZE_CLASSES {
        let top = brk.frees[class];
        if top != 0 {
            brk.frees[class] = unsafe { *link(top, slot) };
            return top as *mut u8;
        }
        let next = brk.next_addrs[class];
        if next % BIGPAGE == 0 {
            let addr = big_pages(brk, 1);
            if addr == 0 {
                return core::ptr::null_mut();
            }
            brk.next_addrs[class] = addr + slot;
            return addr as *mut u8;
        }
        brk.next_addrs[class] = next + slot;
        return next as *mut u8;
    }
    big_pages(brk, big_pages_needed(actual)) as *mut u8
}

/// Whether `len` bytes at `addr` can become `new_len` where they are: their slot's size the same.
pub fn resize(len: usize, alignment: usize, new_len: usize) -> bool {
    let old_actual = (len + WORD).max(alignment);
    let new_actual = new_len.saturating_add(WORD).max(alignment);
    let old_slot = old_actual.next_power_of_two();
    if class_of(old_slot) < SIZE_CLASSES {
        new_actual.checked_next_power_of_two() == Some(old_slot)
    } else {
        let old_pages = big_pages_needed(old_actual).next_power_of_two();
        big_pages_needed(new_actual).checked_next_power_of_two() == Some(old_pages)
    }
}

/// `len` bytes at `addr` (as allocated, or resized to), freed: its slot on its size's list.
pub fn free(addr: *mut u8, len: usize, alignment: usize) {
    let brk = state();
    let addr = addr as usize;
    let actual = (len + WORD).max(alignment);
    let slot = actual.next_power_of_two();
    let class = class_of(slot);
    if class < SIZE_CLASSES {
        unsafe { *link(addr, slot) = brk.frees[class] };
        brk.frees[class] = addr;
    } else {
        let pages = big_pages_needed(actual).next_power_of_two();
        let big_class = pages.ilog2() as usize;
        unsafe { *link(addr, pages * BIGPAGE) = brk.big_frees[big_class] };
        brk.big_frees[big_class] = addr;
    }
}

/// `n` big pages (a power of two of them): a freed run, or memory grown. 0 if it can't grow.
fn big_pages(brk: &mut Brk, n: usize) -> usize {
    let pages = n.next_power_of_two();
    let class = pages.ilog2() as usize;
    let top = brk.big_frees[class];
    if top != 0 {
        brk.big_frees[class] = unsafe { *link(top, pages * BIGPAGE) };
        return top;
    }
    grow(pages * (BIGPAGE / 65536))
}

#[cfg(target_arch = "wasm32")]
fn grow(pages: usize) -> usize {
    match core::arch::wasm32::memory_grow(0, pages) {
        usize::MAX => 0,
        page => page * 65536,
    }
}

// Elsewhere (`cargo check` on the machine's own target) there is nothing to grow.
#[cfg(not(target_arch = "wasm32"))]
fn grow(_pages: usize) -> usize {
    0
}

/// The host's own allocations (its logs and lists) come from the same memory.
pub struct Memory;

unsafe impl GlobalAlloc for Memory {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        alloc(layout.size(), layout.align())
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        free(ptr, layout.size(), layout.align())
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        if resize(layout.size(), layout.align(), new_size) {
            return ptr;
        }
        let moved = alloc(new_size, layout.align());
        if !moved.is_null() {
            unsafe { core::ptr::copy_nonoverlapping(ptr, moved, layout.size().min(new_size)) };
            free(ptr, layout.size(), layout.align());
        }
        moved
    }
}
