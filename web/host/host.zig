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
    extern "env" fn js_call(name_ptr: [*]const u8, name_len: usize, input_ptr: [*]const u8, input_len: usize) usize;
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
    extern "env" fn js_record(name_ptr: [*]const u8, name_len: usize, input_ptr: [*]const u8, input_len: usize, answer_ptr: [*]const u8, answer_len: usize) void;
    extern "env" fn js_fetch(method_ptr: [*]const u8, method_len: usize, url_ptr: [*]const u8, url_len: usize, headers_ptr: [*]const u8, headers_len: usize, body_ptr: [*]const u8, body_len: usize) usize;
    extern "env" fn js_listen(url_ptr: [*]const u8, url_len: usize, handler: usize) void;
    extern "env" fn js_timer(ms: u32, repeat: u32, handler: usize) u32;
    extern "env" fn js_clear_timer(id: u32) void;
    extern "env" fn js_browser_call(name_ptr: [*]const u8, name_len: usize, arg_ptr: [*]const u8, arg_len: usize) void;
    extern "env" fn js_serve(name_ptr: [*]const u8, name_len: usize, context_ptr: [*]const u8, context_len: usize) void;
    extern "env" fn js_serving() usize;
    extern "env" fn js_context() usize;
    extern "env" fn js_location() usize;
    extern "env" fn js_status(code: u32) void;
    extern "env" fn js_effect_new(callable: usize) void;
    extern "env" fn js_cleanup(callable: usize) void;
    extern "env" fn js_flash(ptr: [*]const u8, len: usize) usize;
    extern "env" fn js_action(ptr: [*]const u8, len: usize) void;
    extern "env" fn js_submission(ptr: [*]const u8, len: usize) usize;
    extern "env" fn js_submission_clear(ptr: [*]const u8, len: usize) void;
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
        host_made = true;
    }
    return &roc_host;
}

fn countedAlloc(roc_host_ptr: *abi.RocHost, length: usize, alignment: usize) callconv(.c) *anyopaque {
    live += 1;
    return abi.DefaultAllocators.rocAlloc(roc_host_ptr, length, alignment);
}

fn countedDealloc(roc_host_ptr: *abi.RocHost, ptr: *anyopaque, alignment: usize) callconv(.c) void {
    live -= 1;
    abi.DefaultAllocators.rocDealloc(roc_host_ptr, ptr, alignment);
}

var result: RocStr = undefined;
var has_result = false;

fn setResult(text: RocStr) void {
    if (has_result) result.decref(host());
    result = text;
    has_result = true;
}

/// The text the last import answered with, `len` bytes, as a Roc string.
fn taken(len: usize) RocStr {
    const bytes = memory.alloc(u8, len) catch @trap();
    defer memory.free(bytes);
    if (len > 0) js.js_take(bytes.ptr);
    return RocStr.fromSlice(bytes, host());
}

fn address(boxed: Callable) usize {
    return @intFromPtr(boxed orelse return 0);
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

fn hostedCall(name: RocStr, input: RocStr) callconv(.c) RocStr {
    defer name.decref(host());
    defer input.decref(host());
    const n = name.asSlice();
    const i = input.asSlice();
    return taken(js.js_call(n.ptr, n.len, i.ptr, i.len));
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

fn hostedRecord(name: RocStr, input: RocStr, answered: RocStr) callconv(.c) void {
    defer name.decref(host());
    defer input.decref(host());
    defer answered.decref(host());
    const n = name.asSlice();
    const i = input.asSlice();
    const a = answered.asSlice();
    js.js_record(n.ptr, n.len, i.ptr, i.len, a.ptr, a.len);
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

fn hostedFetch(method: RocStr, url: RocStr, headers: RocStr, body: RocStr) callconv(.c) RocStr {
    defer method.decref(host());
    defer url.decref(host());
    defer headers.decref(host());
    defer body.decref(host());
    const m = method.asSlice();
    const u = url.asSlice();
    const h = headers.asSlice();
    const b = body.asSlice();
    return taken(js.js_fetch(m.ptr, m.len, u.ptr, u.len, h.ptr, h.len, b.ptr, b.len));
}

fn hostedListen(url: RocStr, handler: Callable) callconv(.c) void {
    defer url.decref(host());
    const u = url.asSlice();
    js.js_listen(u.ptr, u.len, address(handler));
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

// Serving a server function's call, and the page's location and status: the runtime's, which keeps
// them while it renders as a server would (in Node), and gives the browser's location.

fn hostedServe(name: RocStr, context: RocStr) callconv(.c) void {
    defer name.decref(host());
    defer context.decref(host());
    const n = name.asSlice();
    const c = context.asSlice();
    js.js_serve(n.ptr, n.len, c.ptr, c.len);
}

fn hostedServing() callconv(.c) RocStr {
    return taken(js.js_serving());
}

fn hostedContext() callconv(.c) RocStr {
    return taken(js.js_context());
}

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
    @export(&hostedCall, .{ .name = "roc_call", .visibility = hidden });
    @export(&hostedFail, .{ .name = "roc_fail", .visibility = hidden });
    @export(&hostedEventValue, .{ .name = "roc_event_value", .visibility = hidden });
    @export(&hostedBoundary, .{ .name = "roc_boundary", .visibility = hidden });
    @export(&hostedProblem, .{ .name = "roc_problem", .visibility = hidden });
    @export(&hostedRetry, .{ .name = "roc_retry", .visibility = hidden });
    @export(&hostedRequest, .{ .name = "roc_request", .visibility = hidden });
    @export(&hostedRecord, .{ .name = "roc_record", .visibility = hidden });
    @export(&hostedForNew, .{ .name = "roc_for_new", .visibility = hidden });
    @export(&hostedRowIndex, .{ .name = "roc_row_index", .visibility = hidden });
    @export(&hostedRowSet, .{ .name = "roc_row_set", .visibility = hidden });
    @export(&hostedRowGet, .{ .name = "roc_row_get", .visibility = hidden });
    @export(&hostedContextValue, .{ .name = "roc_context_value", .visibility = hidden });
    @export(&hostedContextFind, .{ .name = "roc_context_find", .visibility = hidden });
    @export(&hostedContextGet, .{ .name = "roc_context_get", .visibility = hidden });
    @export(&hostedFetch, .{ .name = "roc_fetch", .visibility = hidden });
    @export(&hostedListen, .{ .name = "roc_listen", .visibility = hidden });
    @export(&hostedTimeout, .{ .name = "roc_timeout", .visibility = hidden });
    @export(&hostedInterval, .{ .name = "roc_interval", .visibility = hidden });
    @export(&hostedClearTimer, .{ .name = "roc_clear_timer", .visibility = hidden });
    @export(&hostedBrowserCall, .{ .name = "roc_browser_call", .visibility = hidden });
    @export(&hostedServe, .{ .name = "roc_serve", .visibility = hidden });
    @export(&hostedServing, .{ .name = "roc_serving", .visibility = hidden });
    @export(&hostedContext, .{ .name = "roc_context", .visibility = hidden });
    @export(&hostedLocation, .{ .name = "roc_location", .visibility = hidden });
    @export(&hostedStatus, .{ .name = "roc_status", .visibility = hidden });
    @export(&hostedEffectNew, .{ .name = "roc_effect_new", .visibility = hidden });
    @export(&hostedCleanup, .{ .name = "roc_cleanup", .visibility = hidden });
    @export(&hostedFlash, .{ .name = "roc_flash", .visibility = hidden });
    @export(&hostedAction, .{ .name = "roc_action", .visibility = hidden });
    @export(&hostedSubmission, .{ .name = "roc_submission", .visibility = hidden });
    @export(&hostedSubmissionClear, .{ .name = "roc_submission_clear", .visibility = hidden });
    @export(&hostedTitle, .{ .name = "roc_title", .visibility = hidden });
}
