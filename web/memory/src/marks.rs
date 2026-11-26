//! Which addresses are allocations a frame noted, still allocated. On wasm32 a bit per 8 bytes of
//! memory (4 GiB at most, a few hundred KiB of bits for what a page uses); on a 64-bit machine,
//! where memory isn't one small range, a hash set of addresses (open addressing, linear probing).
//! `insert` answers false when there was no memory to grow.

use alloc::vec::Vec;

#[cfg(target_pointer_width = "32")]
pub struct Marks {
    words: Vec<u32>,
}

#[cfg(target_pointer_width = "32")]
impl Marks {
    pub const fn new() -> Marks {
        Marks { words: Vec::new() }
    }

    pub fn insert(&mut self, ptr: usize) -> bool {
        let index = ptr >> 3;
        let word = index >> 5;
        if word >= self.words.len() {
            let wanted = (word + 1).max(self.words.len() * 2);
            if self.words.try_reserve_exact(wanted - self.words.len()).is_err() {
                return false;
            }
            self.words.resize(wanted, 0);
        }
        self.words[word] |= 1 << (index & 31);
        true
    }

    pub fn remove(&mut self, ptr: usize) {
        let index = ptr >> 3;
        if let Some(word) = self.words.get_mut(index >> 5) {
            *word &= !(1 << (index & 31));
        }
    }

    pub fn contains(&self, ptr: usize) -> bool {
        if ptr & 7 != 0 {
            return false;
        }
        let index = ptr >> 3;
        self.words.get(index >> 5).is_some_and(|word| word & (1 << (index & 31)) != 0)
    }
}

/// A slot never used, and one whose address was removed (an allocation's address is a multiple of
/// 16, so neither is one).
#[cfg(not(target_pointer_width = "32"))]
const EMPTY: usize = 0;
#[cfg(not(target_pointer_width = "32"))]
const GONE: usize = 1;

#[cfg(not(target_pointer_width = "32"))]
pub struct Marks {
    /// A power of two of slots (none at first).
    slots: Vec<usize>,
    /// Slots holding an address, and those holding one or `GONE`.
    live: usize,
    used: usize,
}

#[cfg(not(target_pointer_width = "32"))]
impl Marks {
    pub const fn new() -> Marks {
        Marks { slots: Vec::new(), live: 0, used: 0 }
    }

    /// Where an address's probe starts: Fibonacci hashing of its 16-byte unit.
    fn start(&self, ptr: usize) -> usize {
        let bits = self.slots.len().trailing_zeros();
        ((ptr as u64 >> 4).wrapping_mul(0x9E37_79B9_7F4A_7C15) >> (64 - bits)) as usize
    }

    /// The slot holding `ptr`, if one does.
    fn find(&self, ptr: usize) -> Option<usize> {
        if self.slots.is_empty() {
            return None;
        }
        let mask = self.slots.len() - 1;
        let mut at = self.start(ptr);
        loop {
            match self.slots[at] {
                EMPTY => return None,
                slot if slot == ptr => return Some(at),
                _ => at = (at + 1) & mask,
            }
        }
    }

    pub fn insert(&mut self, ptr: usize) -> bool {
        if self.find(ptr).is_some() {
            return true;
        }
        if (self.used + 1) * 4 > self.slots.len() * 3 && !self.grow() {
            return false;
        }
        let mask = self.slots.len() - 1;
        let mut at = self.start(ptr);
        while self.slots[at] != EMPTY && self.slots[at] != GONE {
            at = (at + 1) & mask;
        }
        if self.slots[at] == EMPTY {
            self.used += 1;
        }
        self.slots[at] = ptr;
        self.live += 1;
        true
    }

    pub fn remove(&mut self, ptr: usize) {
        if let Some(at) = self.find(ptr) {
            self.slots[at] = GONE;
            self.live -= 1;
        }
    }

    pub fn contains(&self, ptr: usize) -> bool {
        ptr & 15 == 0 && self.find(ptr).is_some()
    }

    /// Room for more: twice the slots the addresses need (the removed ones dropped).
    fn grow(&mut self) -> bool {
        let size = ((self.live + 1) * 2).next_power_of_two().max(64);
        let mut slots = Vec::new();
        if slots.try_reserve_exact(size).is_err() {
            return false;
        }
        slots.resize(size, EMPTY);
        let old = core::mem::replace(&mut self.slots, slots);
        self.live = 0;
        self.used = 0;
        for ptr in old {
            if ptr != EMPTY && ptr != GONE {
                let mask = self.slots.len() - 1;
                let mut at = self.start(ptr);
                while self.slots[at] != EMPTY {
                    at = (at + 1) & mask;
                }
                self.slots[at] = ptr;
                self.live += 1;
                self.used += 1;
            }
        }
        true
    }
}

#[cfg(all(test, not(target_pointer_width = "32")))]
mod tests {
    use super::Marks;

    #[test]
    fn addresses_come_and_go() {
        let mut marks = Marks::new();
        let addresses: alloc::vec::Vec<usize> = (1..5000).map(|n| n * 48).collect();
        for &at in &addresses {
            assert!(marks.insert(at));
        }
        for &at in &addresses {
            assert!(marks.contains(at), "{at} is in");
        }
        for &at in addresses.iter().step_by(2) {
            marks.remove(at);
        }
        for (n, &at) in addresses.iter().enumerate() {
            assert_eq!(marks.contains(at), n % 2 == 1, "{at}");
        }
        // Removed slots are used again, and growing drops them.
        for &at in addresses.iter().step_by(2) {
            assert!(marks.insert(at));
        }
        assert!(addresses.iter().all(|&at| marks.contains(at)));
        assert!(!marks.contains(7 * 48 + 16));
    }
}
