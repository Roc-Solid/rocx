//! The browser's host for an app's components: Roc's memory, strings in and out, and the hosted
//! functions, each passed through to the JS runtime (web/runtime.js), which
//! keeps the boxes Roc gives it (computations, handlers, values) by their pointers. A JS import
//! may throw (an async read that isn't in yet): the wasm frames above it unwind.
const std = @import("std");
const abi = @import("roc_platform_abi.zig");

const RocStr = abi.RocStr;
const Callable = abi.RocErasedCallable;
const memory = std.heap.wasm_allocator;

const js = struct {
    extern "env" fn js_log(ptr: [*]const u8, len: usize) void;
    extern "env" fn js_crashed(ptr: [*]const u8, len: usize) void;
    /// The bytes of the text the last import answered with, its length then: `js_take`.
    extern "env" fn js_take(dest: [*]u8) void;
    extern "env" fn js_keep(callable: usize) u32;
    extern "env" fn js_signal_new(value: usize) u32;
    extern "env" fn js_signal_get(id: u32) usize;
    extern "env" fn js_signal_set(id: u32, value: usize) void;
    extern "env" fn js_memo_new(run: usize) u32;
    extern "env" fn js_memo_done(value: usize, same: u32) void;
    extern "env" fn js_memo_get(id: u32) usize;
    extern "env" fn js_selector_new(run: usize) u32;
    extern "env" fn js_selector_is(id: u32, ptr: [*]const u8, len: usize) u32;
    extern "env" fn js_refresh(probe: usize) void;
    extern "env" fn js_is_pending(probe: usize) u32;
    extern "env" fn js_fail(ptr: [*]const u8, len: usize) void;
    extern "env" fn js_event_value() usize;
    extern "env" fn js_boundary() u32;
    extern "env" fn js_problem() usize;
    extern "env" fn js_retry(id: u32) void;
    extern "env" fn js_request() usize;
    extern "env" fn js_for_new() u32;
    extern "env" fn js_row_index(id: u32, key_ptr: [*]const u8, key_len: usize) u32;
    extern "env" fn js_row_set(id: u32, key_ptr: [*]const u8, key_len: usize, value: usize, same: u32) void;
    extern "env" fn js_row_last(id: u32, key_ptr: [*]const u8, key_len: usize) usize;
    extern "env" fn js_row_get(id: u32, key_ptr: [*]const u8, key_len: usize) usize;
    extern "env" fn js_context_value(value: usize) u32;
    extern "env" fn js_context_find(name_ptr: [*]const u8, name_len: usize) u32;
    extern "env" fn js_context_get(id: u32) usize;
    extern "env" fn js_fetch(method_ptr: [*]const u8, method_len: usize, url_ptr: [*]const u8, url_len: usize, headers_ptr: [*]const u8, headers_len: usize, body_ptr: [*]const u8, body_len: usize) usize;
    /// Throws what the last `js_fetch` that answered `waits` would have: its caller waits, or fails.
    extern "env" fn js_waits() void;
    extern "env" fn js_listen(url_ptr: [*]const u8, url_len: usize, handler: usize) void;
    extern "env" fn js_subscribe(url_ptr: [*]const u8, url_len: usize, handler: usize) void;
    extern "env" fn js_say(url_ptr: [*]const u8, url_len: usize, said_ptr: [*]const u8, said_len: usize) void;
    extern "env" fn js_resync(url_ptr: [*]const u8, url_len: usize) void;
    extern "env" fn js_live_publish(topic_ptr: [*]const u8, topic_len: usize, message_ptr: [*]const u8, message_len: usize) void;
    extern "env" fn js_timer(ms: u32, repeat: u32, handler: usize) u32;
    extern "env" fn js_clear_timer(id: u32) void;
    extern "env" fn js_browser_call(name_ptr: [*]const u8, name_len: usize, arg_ptr: [*]const u8, arg_len: usize) void;
    extern "env" fn js_location() usize;
    extern "env" fn js_app(build_ptr: [*]const u8, build_len: usize, dev: u32, routes_ptr: [*]const u8, routes_len: usize) void;
    extern "env" fn js_navigate(to_ptr: [*]const u8, to_len: usize, replace: u32, scroll: u32) void;
    extern "env" fn js_is_routing() u32;
    extern "env" fn js_before_leave(callable: usize) void;
    extern "env" fn js_leave_prevent(id: u32) void;
    extern "env" fn js_leave_retry(id: u32, force: u32) void;
    extern "env" fn js_status(code: u32) void;
    extern "env" fn js_effect_new(callable: usize) void;
    extern "env" fn js_cleanup(callable: usize) void;
    extern "env" fn js_flash(ptr: [*]const u8, len: usize) usize;
    extern "env" fn js_action(ptr: [*]const u8, len: usize) void;
    extern "env" fn js_submission(ptr: [*]const u8, len: usize) usize;
    extern "env" fn js_submission_clear(ptr: [*]const u8, len: usize) void;
    extern "env" fn js_submissions(ptr: [*]const u8, len: usize) usize;
    extern "env" fn js_submit(method_ptr: [*]const u8, method_len: usize, url_ptr: [*]const u8, url_len: usize, body_ptr: [*]const u8, body_len: usize, input_ptr: [*]const u8, input_len: usize) void;
    extern "env" fn js_submission_drop(ptr: [*]const u8, len: usize, id: u32) void;
    extern "env" fn js_title(ptr: [*]const u8, len: usize) void;
    extern "env" fn js_head(key_ptr: [*]const u8, key_len: usize, markup_ptr: [*]const u8, markup_len: usize) void;
    extern "env" fn js_revalidate(ptr: [*]const u8, len: usize) void;
    extern "env" fn js_submission_retry(ptr: [*]const u8, len: usize, id: u32) void;
    extern "env" fn js_optimistic_set(id: u32, value: usize) void;
    extern "env" fn js_untrack(on: u32) void;
    extern "env" fn js_effect_options(render: u32, error_box: u32) void;
    extern "env" fn js_read_at(ptr: [*]const u8, len: usize) usize;
    extern "env" fn js_tracking() u32;
    extern "env" fn js_memo_last() usize;
    extern "env" fn js_signal_latest(id: u32) usize;
    /// `Date.now()`, and `performance.timeOrigin + performance.now()`: milliseconds, as JS has them.
    extern "env" fn js_now_millis() f64;
    extern "env" fn js_now_precise() f64;
};

var roc_env: abi.RocEnv = .{ .allocator = memory, .roc_io = abi.RocIo.freestanding() };
var roc_host: abi.RocHost = undefined;
var host_made = false;
var live: i64 = 0;
/// Every allocation Roc has made, for the tests: what a change costs.
var allocated: i64 = 0;

fn host() *abi.RocHost {
    if (!host_made) {
        roc_host = abi.makeRocHost(&roc_env);
        roc_host.roc_alloc = &countedAlloc;
        roc_host.roc_dealloc = &countedDealloc;
        roc_host.roc_realloc = &trackedRealloc;
        host_made = true;
    }
    return &roc_host;
}

// ---- Roc's memory: each allocation with a header of the host's ----
//
// Before what Roc gets, 8 bytes (or its alignment's, if more): the allocation's number, if a frame
// was open when it was made (`note`; 0 if not, or once the host holds it), then its length. Its
// number says which frame made it without a lookup: a frame's are those numbered since it began.

/// The header's bytes for an alignment code (`alignCode`): 8, 16, 32…
fn headerBytes(code: u32) usize {
    return @as(usize, 8) << @intCast(code);
}

/// An alignment as a code of 3 bits (one of 8 bytes or less: 0, 16: 1, 32: 2…), kept in a note's
/// address (an allocation's is a multiple of 8).
fn alignCode(alignment: usize) u32 {
    return std.math.log2_int(usize, @max(alignment, 8)) - 3;
}

fn numberOf(ptr: usize) *u32 {
    return @ptrFromInt(ptr - 8);
}

fn lengthOf(ptr: usize) *usize {
    return @ptrFromInt(ptr - 4);
}

fn outOfMemory() noreturn {
    roc_env.roc_io.writeStderr("roc_alloc: out of memory\n");
    roc_env.roc_io.onFatal();
}

fn countedAlloc(_: *abi.RocHost, length: usize, alignment: usize) callconv(.c) *anyopaque {
    live += 1;
    allocated += 1;
    const code = alignCode(alignment);
    const header = headerBytes(code);
    const base = memory.rawAlloc(length + header, std.mem.Alignment.fromByteUnits(header), @returnAddress()) orelse outOfMemory();
    const ptr = @intFromPtr(base) + header;
    lengthOf(ptr).* = length;
    numberOf(ptr).* = 0;
    if (innermost()) |frame| note(frame, ptr, code);
    return @ptrFromInt(ptr);
}

fn countedDealloc(_: *abi.RocHost, ptr: *anyopaque, alignment: usize) callconv(.c) void {
    live -= 1;
    unmark(@intFromPtr(ptr));
    freeAllocation(@intFromPtr(ptr), alignCode(alignment));
}

fn freeAllocation(ptr: usize, code: u32) void {
    const header = headerBytes(code);
    const base: [*]u8 = @ptrFromInt(ptr - header);
    memory.rawFree(base[0 .. lengthOf(ptr).* + header], std.mem.Alignment.fromByteUnits(header), @returnAddress());
}

/// Grown where it is if the allocator can (the same size of slot), else moved: still the frame's
/// that made it, if one open or unwound did (`renote`).
fn trackedRealloc(_: *abi.RocHost, ptr_any: *anyopaque, new_length: usize, alignment: usize) callconv(.c) *anyopaque {
    const ptr = @intFromPtr(ptr_any);
    const code = alignCode(alignment);
    const header = headerBytes(code);
    const aligned = std.mem.Alignment.fromByteUnits(header);
    const old_length = lengthOf(ptr).*;
    const base: [*]u8 = @ptrFromInt(ptr - header);
    if (memory.rawResize(base[0 .. old_length + header], aligned, new_length + header, @returnAddress())) {
        lengthOf(ptr).* = new_length;
        return ptr_any;
    }
    const new_base = memory.rawAlloc(new_length + header, aligned, @returnAddress()) orelse outOfMemory();
    const moved = @intFromPtr(new_base) + header;
    const kept = @min(old_length, new_length);
    @memcpy(new_base[header..][0..kept], base[header..][0..kept]);
    lengthOf(moved).* = new_length;
    numberOf(moved).* = 0;
    if (marked(ptr) and numberOf(ptr).* != 0) renote(moved, code, numberOf(ptr).*);
    unmark(ptr);
    memory.rawFree(base[0 .. old_length + header], aligned, @returnAddress());
    return @ptrFromInt(moved);
}

// ---- Runs, and what one that unwinds leaves ----
//
// A read that waits (or fails) unwinds the run that made it with a JS throw, through the Roc frames
// above it, which never get to let go of what they hold: whatever the run had allocated and still
// held (a URL it built, a value it was computing) would stay allocated for good, a few allocations
// every time a memo or a hole waits. So the runtime opens a frame around each call into Roc
// (`frame_begin`), and the host notes every allocation made while one is open, and every box handed
// to the runtime meanwhile (`address`). A call that returns closes its frame (`frame_end`): what it
// made is Roc's to let go of, as ever, and its notes are the frame's around it, if any (a run inside
// a run: a memo made by a component). One that unwinds (`frame_unwound`) keeps its notes until the
// runtime has let go of everything the run handed it (the computations, signals, cleanups and boxes
// it made; `reclaim`). What the run made that is still allocated is then held by nothing but the
// frames that unwound, and is freed. Roc's values are immutable, and a value the runtime gives Roc
// comes with a reference of the runtime's own, so nothing made before the run points at what the run
// made, and only the boxes it handed over could. Should one of those still be allocated (the
// runtime keeps it, or a frame that unwound held it too), nothing is freed and the notes are the
// frame's around it: a leak, never a use after free. What the unwound frames held of older values
// (a reference counted once more) stays counted.
//
// The notes are one log (`notes`, `handed`) while frames are open: a frame's are those from where
// it began, so one inside another that returns gives its notes to the frame around it by doing
// nothing, and the outermost's are forgotten by emptying the log. An allocation's number (in its
// header) says whether it is a frame's own: numbered since the frame began. Which addresses are
// allocations a frame noted, still allocated, is a bitmap (`starts`), so a note of one since freed
// (or of an address allocated again since, with another number) is passed over, exactly.

/// An allocation noted: its address with its alignment code in the low 3 bits, and its number.
const Note = struct { at: u32, number: u32 };

const Frame = struct {
    id: u32,
    /// The frame open around it when it began.
    parent: u32 = 0,
    /// The number the first allocation made while it was open got: those numbered since are its own.
    first: u32,
    /// Where its notes, and the boxes it handed to the runtime, start in the log.
    notes_at: usize,
    handed_at: usize,
    /// Whether everything was noted (out of memory to note something: never reclaimed).
    noted: bool = true,
};

/// A frame that unwound, waiting for `reclaim`: its notes, copied out of the log.
const Unwound = struct {
    id: u32,
    parent: u32,
    first: u32,
    /// The number after its last allocation: its own are numbered from `first` to before this.
    end: u32,
    /// The last frame id given out before it unwound: the frames inside it are those after its own
    /// id, to this one.
    last: u32,
    notes: std.ArrayListUnmanaged(Note) = .empty,
    handed: std.ArrayListUnmanaged(usize) = .empty,
    noted: bool,

    fn drop(self: *Unwound) void {
        self.notes.deinit(memory);
        self.handed.deinit(memory);
    }
};

var notes: std.ArrayListUnmanaged(Note) = .empty;
var handed: std.ArrayListUnmanaged(usize) = .empty;
/// The frames open, innermost last, and the unwound ones waiting for `reclaim`.
var frames: std.ArrayListUnmanaged(Frame) = .empty;
var unwound: std.ArrayListUnmanaged(Unwound) = .empty;
var frame_ids: u32 = 0;
/// The next allocation's number (never 0, which is none).
var next_number: u32 = 1;
/// A bit per 8 bytes of memory: set where an allocation a frame noted starts, while it is allocated.
var starts: std.ArrayListUnmanaged(u32) = .empty;

fn innermost() ?*Frame {
    if (frames.items.len == 0) return null;
    return &frames.items[frames.items.len - 1];
}

/// Whether `number` was given at or after `first` and before `end` (numbers wrap around).
fn within(number: u32, first: u32, end: u32) bool {
    return number != 0 and number -% first < end -% first;
}

fn mark(ptr: usize) bool {
    const index = ptr >> 3;
    const word = index >> 5;
    if (word >= starts.items.len) {
        const wanted = @max(word + 1, starts.items.len * 2);
        starts.appendNTimes(memory, 0, wanted - starts.items.len) catch return false;
    }
    starts.items[word] |= @as(u32, 1) << @intCast(index & 31);
    return true;
}

fn unmark(ptr: usize) void {
    const index = ptr >> 3;
    const word = index >> 5;
    if (word < starts.items.len) starts.items[word] &= ~(@as(u32, 1) << @intCast(index & 31));
}

/// Whether an allocation a frame noted starts at `ptr`, still allocated.
fn marked(ptr: usize) bool {
    if (ptr & 7 != 0) return false;
    const index = ptr >> 3;
    const word = index >> 5;
    return word < starts.items.len and starts.items[word] & (@as(u32, 1) << @intCast(index & 31)) != 0;
}

/// An allocation made while `frame` is the innermost open: numbered, and noted in the log.
fn note(frame: *Frame, ptr: usize, code: u32) void {
    const number = next_number;
    next_number +%= 1;
    if (next_number == 0) next_number = 1;
    if (!mark(ptr)) {
        frame.noted = false;
        return;
    }
    notes.append(memory, .{ .at = @intCast(ptr | code), .number = number }) catch {
        unmark(ptr);
        frame.noted = false;
        return;
    };
    numberOf(ptr).* = number;
}

/// An allocation moved (`trackedRealloc`), numbered `number`: noted again where it is now, for the
/// open frame or the unwound one whose it is.
fn renote(ptr: usize, code: u32, number: u32) void {
    const entry: Note = .{ .at = @intCast(ptr | code), .number = number };
    var kept = false;
    if (frames.items.len > 0 and within(number, frames.items[0].first, next_number)) {
        if (mark(ptr)) {
            if (notes.append(memory, entry)) |_| {
                kept = true;
            } else |_| innermost().?.noted = false;
        } else innermost().?.noted = false;
    }
    for (unwound.items) |*frame| {
        if (!within(number, frame.first, frame.end)) continue;
        if (!mark(ptr)) {
            frame.noted = false;
            continue;
        }
        frame.notes.append(memory, entry) catch {
            frame.noted = false;
            continue;
        };
        kept = true;
    }
    if (kept) numberOf(ptr).* = number else unmark(ptr);
}

/// The unwound frames inside frame `id` (begun after it, to frame `last`; frames nest), still
/// waiting: theirs are its notes now (they are among its own), so they go; whether all of them were
/// noted.
fn takeWaiting(id: u32, last: u32, noted: bool) bool {
    var all = noted;
    var at: usize = 0;
    while (at < unwound.items.len) {
        const frame = &unwound.items[at];
        if (frame.id -% id -% 1 < last -% id) {
            all = all and frame.noted;
            frame.drop();
            _ = unwound.swapRemove(at);
        } else at += 1;
    }
    return all;
}

/// The log emptied: the outermost frame is done. A big run's room is given back.
fn forgetNotes() void {
    if (notes.capacity > 1 << 14) notes.clearAndFree(memory) else notes.clearRetainingCapacity();
    if (handed.capacity > 1 << 12) handed.clearAndFree(memory) else handed.clearRetainingCapacity();
}

/// A frame closed (its call returned, or one inside it unwound past it): its notes are the frame's
/// around it (they are in the log, where that one's are), or forgotten if it was the outermost.
fn ended(frame: Frame) void {
    const noted = takeWaiting(frame.id, frame_ids, frame.noted);
    if (innermost()) |around| {
        around.noted = around.noted and noted;
    } else forgetNotes();
}

/// An unwound frame's notes, given up on: the frame's around it, if that is open (they are in the
/// log, where its are), else forgotten.
fn handOn(frame: *Unwound) void {
    for (frames.items) |*open| {
        if (open.id == frame.parent) {
            open.noted = open.noted and frame.noted;
            break;
        }
    }
    frame.drop();
}

/// The frame's own allocation, still allocated, that holds the address `at`, if one does.
fn ownAllocationHolding(frame: *const Unwound, at: usize) ?usize {
    for (frame.notes.items) |entry| {
        const ptr: usize = entry.at & ~@as(u32, 7);
        if (!marked(ptr) or numberOf(ptr).* != entry.number or !within(entry.number, frame.first, frame.end)) continue;
        if (at >= ptr and at < ptr + lengthOf(ptr).*) return ptr;
    }
    return null;
}

/// A call into Roc starts: what it allocates is noted until it ends.
export fn frame_begin() u32 {
    frame_ids +%= 1;
    if (frame_ids == 0) frame_ids = 1;
    const parent = if (innermost()) |frame| frame.id else 0;
    frames.append(memory, .{ .id = frame_ids, .parent = parent, .first = next_number, .notes_at = notes.items.len, .handed_at = handed.items.len }) catch return 0;
    return frame_ids;
}

/// It returned: what it made is Roc's (and the runtime's) to let go of.
export fn frame_end(id: u32) void {
    if (id == 0) return;
    while (frames.pop()) |frame| {
        ended(frame);
        if (frame.id == id) break;
    }
}

/// It unwound (a JS throw): its notes wait for `reclaim`.
export fn frame_unwound(id: u32) void {
    if (id == 0) return;
    while (frames.pop()) |frame| {
        if (frame.id != id) {
            ended(frame);
            continue;
        }
        var waiting: Unwound = .{ .id = frame.id, .parent = frame.parent, .first = frame.first, .end = next_number, .last = frame_ids, .noted = takeWaiting(frame.id, frame_ids, frame.noted) };
        waiting.notes.appendSlice(memory, notes.items[frame.notes_at..]) catch {
            waiting.noted = false;
        };
        waiting.handed.appendSlice(memory, handed.items[frame.handed_at..]) catch {
            waiting.noted = false;
        };
        if (innermost() == null) forgetNotes();
        // Never reclaimed, from a run outside any other: let go of the oldest notes.
        if (unwound.items.len >= 64) {
            var oldest = unwound.orderedRemove(0);
            handOn(&oldest);
        }
        unwound.append(memory, waiting) catch handOn(&waiting);
        return;
    }
}

/// The runtime has let go of everything the unwound run handed it: what the run made that is still
/// allocated is freed, unless a box it handed over is still allocated.
export fn reclaim(id: u32) void {
    var at: usize = 0;
    while (at < unwound.items.len and unwound.items[at].id != id) at += 1;
    if (at == unwound.items.len) return;
    var frame = unwound.swapRemove(at);
    frame.noted = takeWaiting(frame.id, frame.last, frame.noted);
    var held = !frame.noted;
    for (frame.handed.items) |box| {
        if (held) break;
        held = ownAllocationHolding(&frame, box) != null;
    }
    if (held) return handOn(&frame);
    for (frame.notes.items) |entry| {
        const ptr: usize = entry.at & ~@as(u32, 7);
        if (!marked(ptr) or numberOf(ptr).* != entry.number or !within(entry.number, frame.first, frame.end)) continue;
        unmark(ptr);
        live -= 1;
        freeAllocation(ptr, entry.at & 7);
    }
    frame.drop();
}

var result: RocStr = undefined;
var has_result = false;

fn setResult(text: RocStr) void {
    if (has_result) result.decref(host());
    result = text;
    has_result = true;
    // The host holds it: never freed with the frame it was made in (its number taken off, so no
    // note of it is its).
    if (!text.isSmallStr()) {
        if (innermost()) |frame| {
            const ptr = stringAllocation(text);
            if (marked(ptr) and within(numberOf(ptr).*, frame.first, next_number)) numberOf(ptr).* = 0;
        }
    }
}

/// Where a (big) string's allocation starts, if it has one: Roc puts a string's bytes a word after
/// its allocation's start (the reference count is between), and a seamless slice names the bytes
/// of the allocation it is in. A string in the module's data has none (`marked` says no).
fn stringAllocation(text: RocStr) usize {
    const bytes: usize = if (text.isSeamlessSlice()) text.capacity_or_alloc_ptr & ~@as(usize, 1) else @intFromPtr(text.bytes);
    return bytes -% @sizeOf(usize);
}

/// The text the last import answered with, `len` bytes, as a Roc string.
fn taken(len: usize) RocStr {
    const bytes = memory.alloc(u8, len) catch @trap();
    defer memory.free(bytes);
    if (len > 0) js.js_take(bytes.ptr);
    return RocStr.fromSlice(bytes, host());
}

/// A box handed to the runtime: noted in the innermost frame open (see `reclaim`).
fn address(boxed: Callable) usize {
    const at = @intFromPtr(boxed orelse return 0);
    if (innermost()) |frame| handed.append(memory, at) catch {
        frame.noted = false;
    };
    return at;
}

fn callable(at: usize) Callable {
    return @ptrFromInt(at);
}

/// The app's markup, as JSON: the result.
export fn mount() void {
    setResult(abi.roc_mount());
}

/// Runs a box the runtime keeps (it keeps its own reference); the answer is the result.
export fn run(at: usize) void {
    abi.increfErasedCallable(callable(at), 1);
    setResult(abi.roc_run(callable(at)));
}

/// The runtime lets go of a box: Roc releases what it holds when nothing else does.
export fn release(at: usize) void {
    abi.decrefErasedCallable(callable(at), host());
}

export fn result_ptr() u32 {
    if (!has_result) return 0;
    const text = result.asSlice();
    return if (text.len == 0) 0 else @intCast(@intFromPtr(text.ptr));
}

export fn result_len() u32 {
    if (!has_result) return 0;
    return @intCast(result.asSlice().len);
}

export fn live_allocations() i64 {
    // The last run's answer, which the host holds until the next run replaces it, isn't one: what a
    // run answers is JSON, small or not as what it shows is (an `if`'s part's markup, D-070), and a
    // count of what is left over shouldn't change with which run came last.
    const held: i64 = if (has_result and !result.isSmallStr()) 1 else 0;
    return live - held;
}

/// For the tests: the host's notes of what runs allocate, as counts that don't vary with the
/// machine: how many it keeps (0 between runs, unless an unwound run waits for `reclaim`), and the
/// room it keeps for them (a big run's given back when it is done).
export fn notes_kept() u32 {
    var n = notes.items.len + handed.items.len;
    for (unwound.items) |frame| n += frame.notes.items.len + frame.handed.items.len;
    return @intCast(n);
}

export fn notes_room() u32 {
    return @intCast(notes.capacity + handed.capacity);
}

/// How many allocations Roc has made since the module started: the tests' measure of what a change
/// allocates.
export fn allocations() i64 {
    return allocated;
}

// ---- Hosted: each passes to the runtime. A box given to the runtime is the runtime's reference;
// a box given back to Roc is a new one. ----

fn hostedKeep(run_it: Callable) callconv(.c) u64 {
    return js.js_keep(address(run_it));
}

fn hostedSignalNew(value: Callable) callconv(.c) u64 {
    return js.js_signal_new(address(value));
}

fn hostedSignalGet(id: u64) callconv(.c) Callable {
    const value = callable(js.js_signal_get(@intCast(id)));
    abi.increfErasedCallable(value, 1);
    return value;
}

fn hostedSignalSet(id: u64, value: Callable) callconv(.c) void {
    js.js_signal_set(@intCast(id), address(value));
}

fn hostedMemoNew(run_it: Callable) callconv(.c) u64 {
    return js.js_memo_new(address(run_it));
}

fn hostedMemoDone(value: Callable, same: bool) callconv(.c) void {
    js.js_memo_done(address(value), @intFromBool(same));
}

fn hostedMemoGet(id: u64) callconv(.c) Callable {
    const value = callable(js.js_memo_get(@intCast(id)));
    abi.increfErasedCallable(value, 1);
    return value;
}

fn hostedSelectorNew(run_it: Callable) callconv(.c) u64 {
    return js.js_selector_new(address(run_it));
}

fn hostedSelectorIs(id: u64, key: RocStr) callconv(.c) bool {
    defer key.decref(host());
    const text = key.asSlice();
    return js.js_selector_is(@intCast(id), text.ptr, text.len) != 0;
}

fn hostedRefresh(probe: Callable) callconv(.c) void {
    js.js_refresh(address(probe));
}

fn hostedIsPending(probe: Callable) callconv(.c) bool {
    return js.js_is_pending(address(probe)) != 0;
}

fn hostedFail(why: RocStr) callconv(.c) void {
    const text = why.asSlice();
    js.js_fail(text.ptr, text.len);
}

fn hostedEventValue() callconv(.c) RocStr {
    return taken(js.js_event_value());
}

fn hostedBoundary() callconv(.c) u64 {
    return js.js_boundary();
}

fn hostedProblem() callconv(.c) RocStr {
    return taken(js.js_problem());
}

fn hostedRetry(id: u64) callconv(.c) void {
    js.js_retry(@intCast(id));
}

fn hostedRequest() callconv(.c) RocStr {
    return taken(js.js_request());
}

fn hostedForNew() callconv(.c) u64 {
    return js.js_for_new();
}

fn hostedRowIndex(id: u64, key: RocStr) callconv(.c) u64 {
    defer key.decref(host());
    const text = key.asSlice();
    return js.js_row_index(@intCast(id), text.ptr, text.len);
}

fn hostedRowSet(id: u64, key: RocStr, value: Callable, same: bool) callconv(.c) void {
    defer key.decref(host());
    const text = key.asSlice();
    js.js_row_set(@intCast(id), text.ptr, text.len, address(value), @intFromBool(same));
}

// A row's item, a new reference, or `fallback` (given back) for a row not there yet (D-053).
fn hostedRowLast(id: u64, key: RocStr, fallback: Callable) callconv(.c) Callable {
    defer key.decref(host());
    const text = key.asSlice();
    const at = js.js_row_last(@intCast(id), text.ptr, text.len);
    if (at == 0) return fallback;
    abi.decrefErasedCallable(fallback, host());
    const value = callable(at);
    abi.increfErasedCallable(value, 1);
    return value;
}

fn hostedRowGet(id: u64, key: RocStr) callconv(.c) Callable {
    defer key.decref(host());
    const text = key.asSlice();
    const value = callable(js.js_row_get(@intCast(id), text.ptr, text.len));
    abi.increfErasedCallable(value, 1);
    return value;
}

fn hostedContextValue(value: Callable) callconv(.c) u64 {
    return js.js_context_value(address(value));
}

fn hostedContextFind(name: RocStr) callconv(.c) u64 {
    defer name.decref(host());
    const text = name.asSlice();
    return js.js_context_find(text.ptr, text.len);
}

fn hostedContextGet(id: u64) callconv(.c) Callable {
    const value = callable(js.js_context_get(@intCast(id)));
    abi.increfErasedCallable(value, 1);
    return value;
}

// A request's answer. One that isn't in yet (or failed) unwinds the caller, by a JS throw: the
// runtime answers `waits`, and throws (`js_waits`) only once the arguments are let go of, since a
// throw skips this function's defers.
fn hostedFetch(method: RocStr, url: RocStr, headers: RocStr, body: RocStr) callconv(.c) RocStr {
    const length = asked: {
        defer method.decref(host());
        defer url.decref(host());
        defer headers.decref(host());
        defer body.decref(host());
        const m = method.asSlice();
        const u = url.asSlice();
        const h = headers.asSlice();
        const b = body.asSlice();
        break :asked js.js_fetch(m.ptr, m.len, u.ptr, u.len, h.ptr, h.len, b.ptr, b.len);
    };
    if (length == waits) js.js_waits();
    return taken(length);
}

/// What `js_fetch` answers for a request that unwinds its caller (`js_waits` throws why).
const waits: usize = std.math.maxInt(usize);

fn hostedListen(url: RocStr, handler: Callable) callconv(.c) void {
    defer url.decref(host());
    const u = url.asSlice();
    js.js_listen(u.ptr, u.len, address(handler));
}

// Channels: the runtime's hub, one stream for the tab (`/rocx/live`), keeps each subscription's
// handler until its owner is cleaned up; what is said goes with the frame's other sayings.
// Publishing is the server's: the runtime fails it.

fn hostedSubscribe(url: RocStr, handler: Callable) callconv(.c) void {
    defer url.decref(host());
    const u = url.asSlice();
    js.js_subscribe(u.ptr, u.len, address(handler));
}

fn hostedSay(url: RocStr, said: RocStr) callconv(.c) void {
    defer url.decref(host());
    defer said.decref(host());
    const u = url.asSlice();
    const s = said.asSlice();
    js.js_say(u.ptr, u.len, s.ptr, s.len);
}

fn hostedResync(url: RocStr) callconv(.c) void {
    defer url.decref(host());
    const u = url.asSlice();
    js.js_resync(u.ptr, u.len);
}

fn hostedLivePublish(topic: RocStr, message: RocStr) callconv(.c) void {
    defer topic.decref(host());
    defer message.decref(host());
    const t = topic.asSlice();
    const m = message.asSlice();
    js.js_live_publish(t.ptr, t.len, m.ptr, m.len);
}

// A component's timers: the browser's (setTimeout, setInterval), its handler kept by the runtime
// until it is cleared, done, or what made it goes. A wait longer than the browser's (2^31 - 1 ms,
// some 24 days) is that long.

fn timerMs(ms: u64) u32 {
    return @intCast(@min(ms, std.math.maxInt(i32)));
}

fn hostedTimeout(ms: u64, handler: Callable) callconv(.c) u64 {
    return js.js_timer(timerMs(ms), 0, address(handler));
}

fn hostedInterval(ms: u64, handler: Callable) callconv(.c) u64 {
    return js.js_timer(timerMs(ms), 1, address(handler));
}

fn hostedClearTimer(id: u64) callconv(.c) void {
    js.js_clear_timer(@intCast(id));
}

// A call of the page's own function (`Browser.call!`): the runtime queues it on the handler running,
// and calls it once the page is patched; anywhere else it throws, and the frames above unwind.
fn hostedBrowserCall(name: RocStr, arg: RocStr) callconv(.c) void {
    defer name.decref(host());
    defer arg.decref(host());
    const n = name.asSlice();
    const a = arg.asSlice();
    js.js_browser_call(n.ptr, n.len, a.ptr, a.len);
}

// The page's location and status: the runtime's, which keeps them while it renders as a server would
// (in Node), and gives the browser's location.

fn hostedLocation() callconv(.c) RocStr {
    return taken(js.js_location());
}

// The app, as its root renders (`Router.app!`, D-040): its build's id, whether it is a dev build,
// and its route table, the runtime's to keep.
fn hostedApp(build: RocStr, dev: bool, routes: RocStr) callconv(.c) void {
    defer build.decref(host());
    defer routes.decref(host());
    const b = build.asSlice();
    const r = routes.asSlice();
    js.js_app(b.ptr, b.len, @intFromBool(dev), r.ptr, r.len);
}

// `Router.navigate!`: queued on the handler running, as a `Browser.call!` is; anywhere else it
// throws, and the frames above unwind.
fn hostedNavigate(to: RocStr, replace: bool, scroll: bool) callconv(.c) void {
    defer to.decref(host());
    const text = to.asSlice();
    js.js_navigate(text.ptr, text.len, @intFromBool(replace), @intFromBool(scroll));
}

// `Router.is_routing!`: whether a navigation in place is on its way (tracked).
fn hostedIsRouting() callconv(.c) bool {
    return js.js_is_routing() != 0;
}

// `Router.use_before_leave!`: the runtime keeps the listener, owned by what is running; a leave
// stopped while its listeners are asked, or navigated to after all, by its id.
fn hostedBeforeLeave(listener: Callable) callconv(.c) void {
    js.js_before_leave(address(listener));
}

fn hostedLeavePrevent(id: u64) callconv(.c) void {
    js.js_leave_prevent(@intCast(id));
}

fn hostedLeaveRetry(id: u64, force: bool) callconv(.c) void {
    js.js_leave_retry(@intCast(id), @intFromBool(force));
}

fn hostedStatus(code: u16) callconv(.c) void {
    js.js_status(code);
}

// Effects and cleanups: the runtime keeps their boxes, owned by what is running.

fn hostedEffectNew(run_it: Callable) callconv(.c) void {
    js.js_effect_new(address(run_it));
}

fn hostedCleanup(run_it: Callable) callconv(.c) void {
    js.js_cleanup(address(run_it));
}

// A plain form's flash, and the runtime's form submissions.

fn hostedFlash(found: RocStr) callconv(.c) RocStr {
    defer found.decref(host());
    const text = found.asSlice();
    return taken(js.js_flash(text.ptr, text.len));
}

fn hostedAction(url: RocStr) callconv(.c) void {
    defer url.decref(host());
    const text = url.asSlice();
    js.js_action(text.ptr, text.len);
}

fn hostedSubmission(url: RocStr) callconv(.c) RocStr {
    defer url.decref(host());
    const text = url.asSlice();
    return taken(js.js_submission(text.ptr, text.len));
}

fn hostedSubmissionClear(url: RocStr) callconv(.c) void {
    defer url.decref(host());
    const text = url.asSlice();
    js.js_submission_clear(text.ptr, text.len);
}

fn hostedSubmissions(url: RocStr) callconv(.c) RocStr {
    defer url.decref(host());
    const text = url.asSlice();
    return taken(js.js_submissions(text.ptr, text.len));
}

// An action (`Router.use_action!`): its method, URL, body, and what it sent, as JSON.
fn hostedSubmit(method: RocStr, url: RocStr, body: RocStr, input: RocStr) callconv(.c) void {
    defer method.decref(host());
    defer url.decref(host());
    defer body.decref(host());
    defer input.decref(host());
    const m = method.asSlice();
    const u = url.asSlice();
    const b = body.asSlice();
    const i = input.asSlice();
    js.js_submit(m.ptr, m.len, u.ptr, u.len, b.ptr, b.len, i.ptr, i.len);
}

fn hostedSubmissionDrop(url: RocStr, id: u64) callconv(.c) void {
    defer url.decref(host());
    const text = url.asSlice();
    js.js_submission_drop(text.ptr, text.len, @intCast(id));
}

// The document's title, as a `<Title>`'s hole says it: the runtime's, which keeps the last one
// rendered that is still there as `document.title` (or, rendering as a server would, the page's).
fn hostedTitle(title: RocStr) callconv(.c) void {
    defer title.decref(host());
    const text = title.asSlice();
    js.js_title(text.ptr, text.len);
}

// A `<Meta>`, `<Link>` or `<Style>`'s hole: its key and markup, the runtime's to keep in `<head>`
// while the hole is there (or, rendering as a server would, the page's).
fn hostedHead(key: RocStr, markup: RocStr) callconv(.c) void {
    defer key.decref(host());
    defer markup.decref(host());
    const k = key.asSlice();
    const m = markup.asSlice();
    js.js_head(k.ptr, k.len, m.ptr, m.len);
}

// `Router.revalidate!`: the reads to read again (JSON), once the handler is done.
fn hostedRevalidate(keys: RocStr) callconv(.c) void {
    defer keys.decref(host());
    const text = keys.asSlice();
    js.js_revalidate(text.ptr, text.len);
}

// `Submission.retry!`, `Submissions.retry!`: a submission sent again, by its id (0, the latest).
fn hostedSubmissionRetry(url: RocStr, id: u64) callconv(.c) void {
    defer url.decref(host());
    const text = url.asSlice();
    js.js_submission_retry(text.ptr, text.len, @intCast(id));
}

// `create_optimistic!`'s write: a signal's, held until its handler's submissions are done.
fn hostedOptimisticSet(id: u64, value: Callable) callconv(.c) void {
    js.js_optimistic_set(@intCast(id), address(value));
}

// `Solid.untrack!`: the running computation's reads untracked from on to off.
fn hostedUntrack(on: bool) callconv(.c) void {
    js.js_untrack(@intFromBool(on));
}

// An effect's options (`create_render_effect!`, `create_effect_with!`), told by its compute.
fn hostedEffectOptions(render: bool, error_box: u64) callconv(.c) void {
    js.js_effect_options(@intFromBool(render), @intCast(error_box));
}

// Whether the running computation tracks its reads: a store's selection is made only then (D-053).
fn hostedTracking() callconv(.c) bool {
    return js.js_tracking() != 0;
}

// The running memo's value, a new reference, or `fallback` (given back) when it has none yet.
fn hostedMemoLast(fallback: Callable) callconv(.c) Callable {
    const at = js.js_memo_last();
    if (at == 0) return fallback;
    abi.decrefErasedCallable(fallback, host());
    const value = callable(at);
    abi.increfErasedCallable(value, 1);
    return value;
}

// A signal's value with the running handler's own write, not yet applied, if it made one.
fn hostedSignalLatest(id: u64) callconv(.c) Callable {
    const value = callable(js.js_signal_latest(@intCast(id)));
    abi.increfErasedCallable(value, 1);
    return value;
}

// A dev build's `Html.read_at!`: where a component's body reads, for the runtime's warning; the
// place before, to put back.
fn hostedReadAt(place: RocStr) callconv(.c) RocStr {
    defer place.decref(host());
    const text = place.asSlice();
    return taken(js.js_read_at(text.ptr, text.len));
}

// The browser's clock (`Time`): JS's milliseconds, a float, as Roc's whole numbers.
fn hostedNowMillis() callconv(.c) u64 {
    return @intFromFloat(@max(js.js_now_millis(), 0));
}

fn hostedNowNanos() callconv(.c) u64 {
    const ms = @max(js.js_now_precise(), 0);
    const whole = @floor(ms);
    return @as(u64, @intFromFloat(whole)) * 1_000_000 + @as(u64, @intFromFloat(@round((ms - whole) * 1_000_000)));
}

pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(message: []const u8, _: ?usize) noreturn {
    js.js_crashed(message.ptr, message.len);
    @trap();
}

fn rocAlloc(length: usize, alignment: usize) callconv(.c) *anyopaque {
    return countedAlloc(host(), length, alignment);
}
fn rocDealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    countedDealloc(host(), ptr, alignment);
}
fn rocRealloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) *anyopaque {
    return trackedRealloc(host(), ptr, new_length, alignment);
}
fn rocDbg(bytes: [*]const u8, len: usize) callconv(.c) void {
    js.js_log(bytes, len);
}
fn rocExpectFailed(bytes: [*]const u8, len: usize) callconv(.c) void {
    js.js_log(bytes, len);
}
fn rocCrashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    js.js_crashed(bytes, len);
    @trap();
}

comptime {
    const hidden: std.builtin.SymbolVisibility = .hidden;
    @export(&rocAlloc, .{ .name = "roc_alloc", .visibility = hidden });
    @export(&rocDealloc, .{ .name = "roc_dealloc", .visibility = hidden });
    @export(&rocRealloc, .{ .name = "roc_realloc", .visibility = hidden });
    @export(&rocDbg, .{ .name = "roc_dbg", .visibility = hidden });
    @export(&rocExpectFailed, .{ .name = "roc_expect_failed", .visibility = hidden });
    @export(&rocCrashed, .{ .name = "roc_crashed", .visibility = hidden });
    @export(&hostedKeep, .{ .name = "roc_keep", .visibility = hidden });
    @export(&hostedSignalNew, .{ .name = "roc_signal_new", .visibility = hidden });
    @export(&hostedSignalGet, .{ .name = "roc_signal_get", .visibility = hidden });
    @export(&hostedSignalSet, .{ .name = "roc_signal_set", .visibility = hidden });
    @export(&hostedMemoNew, .{ .name = "roc_memo_new", .visibility = hidden });
    @export(&hostedMemoDone, .{ .name = "roc_memo_done", .visibility = hidden });
    @export(&hostedMemoGet, .{ .name = "roc_memo_get", .visibility = hidden });
    @export(&hostedSelectorNew, .{ .name = "roc_selector_new", .visibility = hidden });
    @export(&hostedSelectorIs, .{ .name = "roc_selector_is", .visibility = hidden });
    @export(&hostedRefresh, .{ .name = "roc_refresh", .visibility = hidden });
    @export(&hostedIsPending, .{ .name = "roc_is_pending", .visibility = hidden });
    @export(&hostedFail, .{ .name = "roc_fail", .visibility = hidden });
    @export(&hostedEventValue, .{ .name = "roc_event_value", .visibility = hidden });
    @export(&hostedBoundary, .{ .name = "roc_boundary", .visibility = hidden });
    @export(&hostedProblem, .{ .name = "roc_problem", .visibility = hidden });
    @export(&hostedRetry, .{ .name = "roc_retry", .visibility = hidden });
    @export(&hostedRequest, .{ .name = "roc_request", .visibility = hidden });
    @export(&hostedForNew, .{ .name = "roc_for_new", .visibility = hidden });
    @export(&hostedRowIndex, .{ .name = "roc_row_index", .visibility = hidden });
    @export(&hostedRowSet, .{ .name = "roc_row_set", .visibility = hidden });
    @export(&hostedRowGet, .{ .name = "roc_row_get", .visibility = hidden });
    @export(&hostedRowLast, .{ .name = "roc_row_last", .visibility = hidden });
    @export(&hostedContextValue, .{ .name = "roc_context_value", .visibility = hidden });
    @export(&hostedContextFind, .{ .name = "roc_context_find", .visibility = hidden });
    @export(&hostedContextGet, .{ .name = "roc_context_get", .visibility = hidden });
    @export(&hostedFetch, .{ .name = "roc_fetch", .visibility = hidden });
    @export(&hostedListen, .{ .name = "roc_listen", .visibility = hidden });
    @export(&hostedSubscribe, .{ .name = "roc_subscribe", .visibility = hidden });
    @export(&hostedSay, .{ .name = "roc_say", .visibility = hidden });
    @export(&hostedResync, .{ .name = "roc_resync", .visibility = hidden });
    @export(&hostedLivePublish, .{ .name = "roc_host_live_publish", .visibility = hidden });
    @export(&hostedTimeout, .{ .name = "roc_timeout", .visibility = hidden });
    @export(&hostedInterval, .{ .name = "roc_interval", .visibility = hidden });
    @export(&hostedClearTimer, .{ .name = "roc_clear_timer", .visibility = hidden });
    @export(&hostedBrowserCall, .{ .name = "roc_browser_call", .visibility = hidden });
    @export(&hostedLocation, .{ .name = "roc_location", .visibility = hidden });
    @export(&hostedApp, .{ .name = "roc_app", .visibility = hidden });
    @export(&hostedNavigate, .{ .name = "roc_navigate", .visibility = hidden });
    @export(&hostedIsRouting, .{ .name = "roc_is_routing", .visibility = hidden });
    @export(&hostedBeforeLeave, .{ .name = "roc_before_leave", .visibility = hidden });
    @export(&hostedLeavePrevent, .{ .name = "roc_leave_prevent", .visibility = hidden });
    @export(&hostedLeaveRetry, .{ .name = "roc_leave_retry", .visibility = hidden });
    @export(&hostedStatus, .{ .name = "roc_status", .visibility = hidden });
    @export(&hostedEffectNew, .{ .name = "roc_effect_new", .visibility = hidden });
    @export(&hostedCleanup, .{ .name = "roc_cleanup", .visibility = hidden });
    @export(&hostedFlash, .{ .name = "roc_flash", .visibility = hidden });
    @export(&hostedAction, .{ .name = "roc_action", .visibility = hidden });
    @export(&hostedSubmission, .{ .name = "roc_submission", .visibility = hidden });
    @export(&hostedSubmissionClear, .{ .name = "roc_submission_clear", .visibility = hidden });
    @export(&hostedSubmissions, .{ .name = "roc_submissions", .visibility = hidden });
    @export(&hostedSubmit, .{ .name = "roc_submit", .visibility = hidden });
    @export(&hostedSubmissionDrop, .{ .name = "roc_submission_drop", .visibility = hidden });
    @export(&hostedTitle, .{ .name = "roc_title", .visibility = hidden });
    @export(&hostedHead, .{ .name = "roc_head", .visibility = hidden });
    @export(&hostedRevalidate, .{ .name = "roc_revalidate", .visibility = hidden });
    @export(&hostedSubmissionRetry, .{ .name = "roc_submission_retry", .visibility = hidden });
    @export(&hostedOptimisticSet, .{ .name = "roc_optimistic_set", .visibility = hidden });
    @export(&hostedUntrack, .{ .name = "roc_untrack", .visibility = hidden });
    @export(&hostedEffectOptions, .{ .name = "roc_effect_options", .visibility = hidden });
    @export(&hostedReadAt, .{ .name = "roc_read_at", .visibility = hidden });
    @export(&hostedTracking, .{ .name = "roc_tracking", .visibility = hidden });
    @export(&hostedMemoLast, .{ .name = "roc_memo_last", .visibility = hidden });
    @export(&hostedSignalLatest, .{ .name = "roc_signal_latest", .visibility = hidden });
    @export(&hostedNowMillis, .{ .name = "roc_now_millis", .visibility = hidden });
    @export(&hostedNowNanos, .{ .name = "roc_now_nanos", .visibility = hidden });
}
