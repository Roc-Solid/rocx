//! Spike host: Roc's memory, strings in and out, async reads that may abort the caller (the JS
//! import throws), and cells holding any Roc value.
const std = @import("std");
const abi = @import("roc_platform_abi.zig");

const RocStr = abi.RocStr;
const memory = std.heap.wasm_allocator;

const js = struct {
    extern "env" fn js_log(ptr: [*]const u8, len: usize) void;
    extern "env" fn js_crashed(ptr: [*]const u8, len: usize) void;
    /// The value under the key, its length; the bytes then come with `js_take`. Throws (in JS)
    /// when the value isn't there yet, or failed: the wasm frames above unwind.
    extern "env" fn js_async_read(ptr: [*]const u8, len: usize) usize;
    extern "env" fn js_take(dest: [*]u8) void;
    extern "env" fn js_async_start(ptr: [*]const u8, len: usize) void;
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

fn take(ptr: [*]u8, len: usize) RocStr {
    const text = RocStr.fromSlice(ptr[0..len], host());
    memory.free(ptr[0..len]);
    return text;
}

export fn alloc_bytes(len: usize) [*]u8 {
    const bytes = memory.alloc(u8, len) catch @trap();
    return bytes.ptr;
}

export fn render(input_ptr: [*]u8, input_len: usize) void {
    setResult(abi.roc_render(take(input_ptr, input_len)));
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

// ---- Hosted ----

fn hostedAsyncRead(key: RocStr) callconv(.c) RocStr {
    defer key.decref(host());
    const text = key.asSlice();
    const len = js.js_async_read(text.ptr, text.len);
    const bytes = memory.alloc(u8, len) catch @trap();
    defer memory.free(bytes);
    if (len > 0) js.js_take(bytes.ptr);
    return RocStr.fromSlice(bytes, host());
}

fn hostedAsyncStart(key: RocStr) callconv(.c) void {
    defer key.decref(host());
    const text = key.asSlice();
    js.js_async_start(text.ptr, text.len);
}

/// The cells: boxes the host keeps a reference to, forever (a spike).
var cells: [1024]abi.RocBox = @splat(null);
var cell_count: u64 = 0;

fn hostedCellNew(boxed: abi.RocBox) callconv(.c) u64 {
    const id = cell_count;
    cells[@intCast(id)] = boxed; // the reference Roc gave us
    cell_count += 1;
    return id;
}

fn hostedCellGet(id: u64) callconv(.c) abi.RocBox {
    const boxed = cells[@intCast(id)];
    abi.increfBox(boxed, 1); // Roc gets its own reference
    return boxed;
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
    @export(&hostedAsyncRead, .{ .name = "roc_async_read", .visibility = hidden });
    @export(&hostedCellNew, .{ .name = "roc_cell_new", .visibility = hidden });
    @export(&hostedAsyncStart, .{ .name = "roc_async_start", .visibility = hidden });
    @export(&hostedCellGet, .{ .name = "roc_cell_get", .visibility = hidden });
}
