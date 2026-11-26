# Spike: native/core's engine as the browser's host (2026-11-26)

The question (the user's, after D-087): would the browser be faster, its JavaScript smaller, and
the hosts one language, if the reactive engine ran in the wasm (native/core's, the phone's) and
JavaScript only made the DOM changes, a batch a flush? And would a Rust host be better than
web/host/host.zig?

**Since (the same day):** the Rust host on its own landed (D-090, web/host), and the engine was made
fast in six steps, now in master: see "Round 2" at the end. The harness is in master too
(`spike/wasm-engine/build.sh`, `time.mjs`, `profile.mjs`; the web platform's exports are swapped
only for the length of the engine's link).

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
the abort-leak frees (roc.rs says its waits leak; since D-091, rocx-memory frees them).

## The Rust host on its own (D-090 since)

Porting web/host/host.zig to Rust, the engine aside, is a separate and smaller step: the allocation
notes, the strings in and out, and the imports, about 1,000 lines. It would put every host in one
language (the server's, the phone's and the CLI's are Rust). The size to watch: today's
host.zig is 246 KB as an object but a small part of the linked wasm; a Rust host with std and
dlmalloc would add more, unless it is `no_std` with an allocator of its own.

## Round 2: the engine made fast (2026-11-26, the user's go)

Every fix of "Why, and what it would take" but size, each also the phone's, each measured on the
benchmark's page against today's (`build.sh`, then `time.mjs`: 2 rounds of 15, interleaved; the
machine at load 4 to 9, so the ratio to today's page in the same rounds is the measure):

| | the spike | step 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|---|
| create 1,000 | 1.8x | 1.75x | 1.28x | 1.19x | 1.05x | 1.08x | **1.01x** |
| create 10,000 | 2.8x | 1.6x | 1.25x | 1.18x | 1.16x | 1.10x | **1.08x** |
| append 1,000 | 2.1x | 1.6x | 1.38x | 1.2x | 1.21x | 1.05-1.28x | **1.16x** |
| update every 10th | 1.7x | 1.1x | 1.1x | 1.06x | 1.12x | 1.06x | **0.97x** |
| swap two | 9.8x | 1.4x | 1.4x | 1.19x | 1.10x | 1.05x | **1.17x** (noise; 0.3 ms) |
| clear | 2.3x | 1.55x | 1.5x | 1.9x | 2.0x | 1.87x | **1.55x** |

1. No quadratic work in a long list: the document's nodes linked to their siblings (insert, detach,
   next sibling in constant time), a list's keys in a set, and its rows moved as runtime.js's
   `steady` does (the longest run in order stays; a swap moves two rows).
2. Templates (D-084): `roc_template` answers as runtime.js does, so Roc writes a row's parts alone;
   the engine keeps each skeleton and copies it.
3. FxHash for the engine's maps; in a browser, web/host's allocator (Zig's for wasm, ported); a
   dropped row's nodes freed (their ids used again after the next render; FREE so engine.js lets go
   too: the document and engine.js had grown by every row ever made); a flush's strings decoded at
   once.
4. A template's copy is a CLONE on the page (its markup sent once: TEMPLATE), built quietly in the
   engine's document, then its slots filled.
5. No text allocated per tag and attribute: names shared (`Dom::name`), skeletons compiled once.
6. A list whose rows all go is emptied at once (CLEAR).

The same tables as today's page at every step. On the phone (native/mac against the apps' own
servers): phone-hello and examples/tasks show the same screens as master's engine, view ids aside
(a template makes a row's nodes in another order), with the same live allocations after.

**Size, still the gap:** the engine's page is 562 KB of wasm at the phone's opt-level 3 (155 KB with
brotli), 420 KB at `s` (128 KB; `build.sh`'s default now), 337 KB at `z` (112 KB), each about 5 to
10% slower than 3; today's page is 134 KB of wasm and 124 KB of runtime.js (67 KB with brotli
together). Of the engine's code at 3: engine.rs 43% (`run` alone 57 KB, everything inlined), Roc 25%,
serde_json 9%, formatting 3%. What would shrink it: markup read without serde_json (a reader of
Roc's JSON into the engine's own nodes, faster too), no formatted messages, and wasm-opt.

**Still to do before a browser could run on it** (as before): hydration, navigating in place,
drags, transitions and moves, actions and submissions, channels, `<Meta>`/`<Link>`/`<Style>`,
requests and timers through the page, SVG; and nodes freed beyond a list's rows (a hole's markup
replaced is still kept).

## Round 3: markup read without serde_json (2026-11-26, the user's go)

The engine reads Roc's JSON with a reader of its own (`native/core/src/json.rs`) instead of
serde_json: an object is its entries in order (a node has a handful), a key or a short value markup
always has (`"t"`, `"tag"`, `"e"`, `"class"`) is borrowed from a table instead of allocated, a
string with no escapes is copied in one go, and a number is an integer (Roc's ids; a fraction or
an exponent read roughly, which markup never has). No maps, float parsing or error messages. It
writes the two small answers it gives Roc (a request's, a submission's) itself.

At opt-level s: the engine's page 397,640 bytes of wasm, 118,520 with brotli (426,889 and 129,698
with serde_json: 29 KB and 11 KB less). On the benchmark's page (2 rounds of 15, the machine at load
13 to 15, the ratio to today's page in the same rounds): create 1,000 1.05x today's (1.08x with
serde_json), 10,000 1.04x (1.13x), append 1.02x (1.19x), update 1.00x (1.13x); swap and clear
within the noise of before. The same tables; the phone's screens (native/mac, phone-hello and
examples/tasks against their servers) the same as master's engine's, a submission's round trip
included.

Of the engine's code now (opt-level s, 374 KB): engine.rs 41%, Roc's 33%, formatting 4% (14 KB),
the maps' hashing and hashbrown's copies of it some 5%. What would shrink it next: no formatted
messages (`format!` in warnings and logs), and wasm-opt.
