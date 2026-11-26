# Spike: native/core's engine as the browser's host (2026-11-26)

The question (the user's, after D-087): would the browser be faster, its JavaScript smaller, and
the hosts one language, if the reactive engine ran in the wasm (native/core's, the phone's) and
JavaScript only made the DOM changes, a batch a flush? And would a Rust host be better than
web/host/host.zig?

## What was built (branch spike/wasm-engine, not merged)

- `native/core/src/dom.rs`: on wasm32, each change to the engine's document is also an op
  (`Dom::ops`: create element, text, comment, fragment; insert, detach, set text, attribute,
  remove attribute, style). Android is as it was.
- `native/core/src/web.rs` (wasm32 only): `rocx_start`, `rocx_event`, `rocx_scratch` and
  `rocx_call` for the page; the crash guard is the page's (`js_guarded`: a `try` around the call,
  the shadow stack put back; `js_escape` throws), as web/runtime.js guards a call. `pump` sends
  `Dom::ops` instead of the phone's projection (lib.rs). build.rs builds guard.c only off wasm.
- `web/engine.js`: applies a batch of ops to the DOM, sends events (one listener per event type, the
  engine bubbles), and starts the engine. No hydration (it renders afresh), no SVG, requests or
  timers.
- The web platform's `exports` are the engine's (web/platform/main.roc).

Build: `cargo rustc -p rocx-native-core --target wasm32-unknown-unknown --release --crate-type
staticlib` in native/, then `zig wasm-ld -r --whole-archive
target/wasm32-unknown-unknown/release/librocx_native_core.a -o web/platform/targets/wasm32/host.wasm`,
then the app's `roc build --target=wasm32 --opt=size --specialize=yes`. Its imports are js_log,
js_apply, js_guarded and js_escape alone.

## What it showed

**A Rust host links.** Rust (the Nix toolchain has wasm32-unknown-unknown's std) builds the engine as
a static library, `zig wasm-ld -r` makes it the relocatable object Roc links, and the benchmark's
page runs: its table after create, select, update, swap, append and remove is byte for byte
today's (comments aside, which the engine writes unlabelled).

**As it is, the engine is slower** (the benchmark's keyed page, click to layout, median of 15, back
to back on one machine):

| | today (host.zig + runtime.js) | the engine in wasm |
|---|---|---|
| create 1,000 | 25.5 ms | 42.8 |
| update every 10th | 3.9 | 8.1 |
| swap two | 2.0 | 18.5 |
| append 1,000 | 26.2 | 58.2 |
| clear | 3.1 | 6.7 |

**And bigger:** 515 KB raw, 150 KB with brotli (wasm 510 KB, engine.js 5 KB), against today's 256 KB
and 66.8 KB (wasm 133, runtime.js 123).

## Why, and what it would take

The engine was written for the phone and never made fast. Its profile (create 1,000, symbols kept):
- `malloc`/`free` (dlmalloc) about 5 ms: a `String` for each tag and attribute, and serde_json's
  whole `Value` tree for each row's markup.
- Rust's default hasher (SipHash) for small integer keys; maps whose keys are filtered per row.
- `Dom::insert_before` and `next_sibling` look a child up in its parent's list: quadratic in a
  table of 1,000 rows.
- Rows are moved without the longest run kept in place (runtime.js's `steady`): a swap moves rows
  between the two.
- No templates (D-084): every row is parsed from its whole JSON and made node by node.
- The JavaScript side making the ops (createElement, insertBefore, decoding strings) is about 10 ms
  of create 1,000: today's runtime clones a template instead.

Each is a known fix, and each helps the phone too: a document with sibling links, a fast hasher,
markup read straight into nodes, LIS moves, templates (a CLONE op). Size: leave out native.rs,
css.rs and svg.rs on wasm32, `opt-level = "z"`, no serde_json, panics without messages, wasm-opt.
Whether that beats today's runtime, and by how much, this spike can't say: it would have to be
measured in the same harness.

And before the browser could run on it, the engine would need what runtime.js has and it hasn't:
hydration, navigating in place (D-040), drags (D-055), transitions and moves, actions and
submissions, channels, `<Meta>`/`<Link>`/`<Style>`, requests and timers through the page, and
the abort-leak frees (roc.rs says its waits leak).

## The Rust host on its own

Porting web/host/host.zig to Rust, the engine aside, is a separate and smaller step: the allocation
notes, the strings in and out, and the imports, about 1,000 lines. It would put every host in one
language (the server's, the phone's and the CLI's are Rust). The size to watch: today's
host.zig is 246 KB as an object but a small part of the linked wasm; a Rust host with std and
dlmalloc would add more, unless it is `no_std` with an allocator of its own.
