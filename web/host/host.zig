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
    extern "env" fn js_memo_done(value: usize) void;
    extern "env" fn js_memo_get(id: u32) usize;
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
    extern "env" fn js_row_set(id: u32, key_ptr: [*]const u8, key_len: usize, value: usize) void;
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
};

var roc_env: abi.RocEnv = .{ .allocator = memory, .roc_io = abi.RocIo.freestanding() };
var roc_host: abi.RocHost = undefined;
var host_made = false;
var live: i64 = 0;

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

fn countedAlloc(roc_host_ptr: *abi.RocHost, length: usize, alignment: usize) callconv(.c) *anyopaque {
    live += 1;
    const ptr = abi.DefaultAllocators.rocAlloc(roc_host_ptr, length, alignment);
    track(@intFromPtr(ptr), alignment);
    return ptr;
}

fn countedDealloc(roc_host_ptr: *abi.RocHost, ptr: *anyopaque, alignment: usize) callconv(.c) void {
    live -= 1;
    _ = made.remove(@intFromPtr(ptr));
    abi.DefaultAllocators.rocDealloc(roc_host_ptr, ptr, alignment);
}

fn trackedRealloc(roc_host_ptr: *abi.RocHost, ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) *anyopaque {
    const moved = abi.DefaultAllocators.rocRealloc(roc_host_ptr, ptr, new_length, alignment);
    // Grown from one a frame made: still that frame's.
    if (made.fetchRemove(@intFromPtr(ptr))) |entry| {
        if (frameNamed(entry.value.frame)) |frame| keepIn(frame, @intFromPtr(moved), entry.value.alignment);
    }
    return moved;
}

// ---- Runs, and what one that unwinds leaves ----
//
// A read that waits (or fails) unwinds the run that made it with a JS throw, through the Roc frames
// above it, which never get to let go of what they hold: whatever the run had allocated and still
// held (a URL it built, a value it was computing) would stay allocated for good, a few allocations
// every time a memo or a hole waits. So the runtime opens a frame around each call into Roc
// (`frame_begin`), and the host notes in it every allocation made while it is open, and every box
// handed to the runtime meanwhile (`address`). A call that returns closes its frame (`frame_end`):
// what it made is Roc's to let go of, as ever, and its notes go to the frame around it, if any (a
// run inside a run: a memo made by a component). One that unwinds (`frame_unwound`) keeps its notes
// until the runtime has let go of everything the run handed it (the computations, signals, cleanups
// and boxes it made; `reclaim`). What the run made that is still allocated is then held by nothing
// but the frames that unwound, and is freed. Roc's values are immutable, and a value the runtime
// gives Roc comes with a reference of the runtime's own, so nothing made before the run points at
// what the run made, and only the boxes it handed over could. Should one of those still be
// allocated (the runtime keeps it, or a frame that unwound held it too), nothing is freed and the
// notes go to the frame around it: a leak, never a use after free. What the unwound frames held of
// older values (a reference counted once more) stays counted.

const Made = struct { frame: u32, alignment: u32 };
const Frame = struct {
    id: u32,
    /// The frame open around it when it began.
    parent: u32 = 0,
    /// What was allocated while it was open (some since freed: `made` says which are its own still).
    allocated: std.ArrayListUnmanaged(usize) = .empty,
    /// The boxes handed to the runtime meanwhile.
    handed: std.ArrayListUnmanaged(usize) = .empty,
    /// Whether everything was noted (out of memory to note something: never reclaimed).
    noted: bool = true,
};

/// Every allocation a frame open (or unwound, not yet reclaimed) made that is still allocated.
var made: std.AutoHashMapUnmanaged(usize, Made) = .empty;
/// The frames open, innermost last, and the unwound ones waiting for `reclaim`.
var frames: std.ArrayListUnmanaged(Frame) = .empty;
var unwound: std.ArrayListUnmanaged(Frame) = .empty;
var frame_ids: u32 = 0;

fn innermost() ?*Frame {
    if (frames.items.len == 0) return null;
    return &frames.items[frames.items.len - 1];
}

fn track(ptr: usize, alignment: usize) void {
    if (innermost()) |frame| keepIn(frame, ptr, alignment);
}

fn keepIn(frame: *Frame, ptr: usize, alignment: usize) void {
    made.put(memory, ptr, .{ .frame = frame.id, .alignment = @intCast(alignment) }) catch {
        frame.noted = false;
        return;
    };
    frame.allocated.append(memory, ptr) catch {
        _ = made.remove(ptr);
        frame.noted = false;
    };
}

fn frameNamed(id: u32) ?*Frame {
    for (frames.items) |*frame| if (frame.id == id) return frame;
    for (unwound.items) |*frame| if (frame.id == id) return frame;
    return null;
}

/// Whether the allocation at `ptr` (as `roc_alloc` gave it) holds the address `at`.
fn holds(ptr: usize, alignment: u32, at: usize) bool {
    const total: usize = @as(*const usize, @ptrFromInt(ptr - @sizeOf(usize))).*;
    const header: usize = @max(alignment, @alignOf(usize));
    return at >= ptr and at < ptr + (total - header);
}

/// The frame's own allocation that holds the address `at`, if one does.
fn ownAllocationHolding(frame: *const Frame, at: usize) ?usize {
    for (frame.allocated.items) |ptr| {
        const entry = made.get(ptr) orelse continue;
        if (entry.frame == frame.id and holds(ptr, entry.alignment, at)) return ptr;
    }
    return null;
}

fn dropNotes(frame: *Frame) void {
    frame.allocated.deinit(memory);
    frame.handed.deinit(memory);
}

/// Its notes, no longer kept: what it made is Roc's alone.
fn forget(frame: *Frame) void {
    for (frame.allocated.items) |ptr| {
        if (made.get(ptr)) |entry| if (entry.frame == frame.id) {
            _ = made.remove(ptr);
        };
    }
    dropNotes(frame);
}

/// Its notes, given to the frame around it.
fn hand(frame: *Frame, to: *Frame) void {
    for (frame.allocated.items) |ptr| {
        const entry = made.getPtr(ptr) orelse continue;
        if (entry.frame != frame.id) continue;
        to.allocated.append(memory, ptr) catch {
            _ = made.remove(ptr);
            to.noted = false;
            continue;
        };
        entry.frame = to.id;
    }
    to.handed.appendSlice(memory, frame.handed.items) catch {
        to.noted = false;
    };
    to.noted = to.noted and frame.noted;
    dropNotes(frame);
}

/// Its notes, to the frame open around it if there is one, else forgotten.
fn handOn(frame: *Frame) void {
    if (frame.parent != 0) {
        for (frames.items) |*open| if (open.id == frame.parent) return hand(frame, open);
    }
    forget(frame);
}

/// The unwound frames inside it that are still waiting (never reclaimed): theirs are its notes now,
/// so what they handed over keeps it from being freed too.
fn takeWaiting(frame: *Frame) void {
    var at: usize = 0;
    while (at < unwound.items.len) {
        if (unwound.items[at].parent == frame.id) {
            var inside = unwound.swapRemove(at);
            hand(&inside, frame);
        } else at += 1;
    }
}

/// A call into Roc starts: what it allocates is noted until it ends.
export fn frame_begin() u32 {
    frame_ids +%= 1;
    if (frame_ids == 0) frame_ids = 1;
    const parent = if (innermost()) |frame| frame.id else 0;
    frames.append(memory, .{ .id = frame_ids, .parent = parent }) catch return 0;
    return frame_ids;
}

/// It returned: what it made is Roc's (and the runtime's) to let go of.
export fn frame_end(id: u32) void {
    if (id == 0) return;
    while (frames.pop()) |popped| {
        var frame = popped;
        takeWaiting(&frame);
        handOn(&frame);
        if (frame.id == id) return;
    }
}

/// It unwound (a JS throw): its notes wait for `reclaim`.
export fn frame_unwound(id: u32) void {
    if (id == 0) return;
    while (frames.pop()) |popped| {
        var frame = popped;
        takeWaiting(&frame);
        if (frame.id != id) {
            handOn(&frame);
            continue;
        }
        // Never reclaimed, from a run outside any other: let go of the oldest notes.
        if (unwound.items.len >= 64) {
            var oldest = unwound.orderedRemove(0);
            handOn(&oldest);
        }
        unwound.append(memory, frame) catch handOn(&frame);
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
    takeWaiting(&frame);
    var held = !frame.noted;
    for (frame.handed.items) |box| {
        if (held) break;
        held = ownAllocationHolding(&frame, box) != null;
    }
    if (held) return handOn(&frame);
    for (frame.allocated.items) |ptr| {
        const entry = made.get(ptr) orelse continue;
        if (entry.frame != frame.id) continue;
        _ = made.remove(ptr);
        live -= 1;
        abi.DefaultAllocators.rocDealloc(host(), @ptrFromInt(ptr), entry.alignment);
    }
    dropNotes(&frame);
}

var result: RocStr = undefined;
var has_result = false;

fn setResult(text: RocStr) void {
    if (has_result) result.decref(host());
    result = text;
    has_result = true;
    // The host holds it: never freed with the frame it was made in.
    if (!text.isSmallStr()) {
        if (innermost()) |frame| if (ownAllocationHolding(frame, @intFromPtr(text.asSlice().ptr))) |ptr| {
            _ = made.remove(ptr);
        };
    }
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
    if (innermost()) |frame| frame.handed.append(memory, at) catch {
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
    return live;
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

fn hostedMemoDone(value: Callable) callconv(.c) void {
    js.js_memo_done(address(value));
}

fn hostedMemoGet(id: u64) callconv(.c) Callable {
    const value = callable(js.js_memo_get(@intCast(id)));
    abi.increfErasedCallable(value, 1);
    return value;
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

fn hostedRowSet(id: u64, key: RocStr, value: Callable) callconv(.c) void {
    defer key.decref(host());
    const text = key.asSlice();
    js.js_row_set(@intCast(id), text.ptr, text.len, address(value));
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
    return abi.DefaultAllocators.rocRealloc(host(), ptr, new_length, alignment);
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
}
