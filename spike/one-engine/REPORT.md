# Investigation: one Rust engine for every target (2026-11-26)

The question (the user's): can the browser, the phone and the server all run one front-end engine
in Rust, with the browser's JavaScript kept to what only a browser can do: applying changes to the
DOM, hydrating the server's HTML, and calling browser APIs? Hydration must stay.

**Answer: yes, nothing blocks it.** Hydration included. It is a large port, in phases each useful
on its own, the first of which changes nothing in the browser.

## What there is today: three implementations of one set of rules

| | Language | Lines | What it does |
|---|---|---|---|
| `web/runtime.js` | JavaScript | 6,385 | The browser: hydrating, signals and holes, lists, navigation, forms, drags, transitions, channels; and a renderer to HTML in Node, which the tests use |
| `native/core` (engine.rs, dom.rs, hosted.rs, roc.rs, json.rs) | Rust | about 5,400 shareable, 2,250 phone-only | The phone (D-063), and the browser in `spike/wasm-engine`: the reactive side complete, at the browser's speed since round 2 |
| `server/host/src/signals.rs` | Rust | 1,561 | The server: each page rendered to HTML once, with the markers the browser hydrates |

The server and runtime.js already disagree on details that should match: `aria-current` detection
(a name's case), numbers and arrays as text, the field a password is taken from, `<title` matching,
the kinds refused inside `<NoHydration>`. Rendered by one engine, they couldn't.

## runtime.js, by what it would take to move

About 4,500 of its lines are decisions and state, about 1,800 are close to the browser. By area
(approximate lines):

- **The reactive core and running** (records, calling Roc, running and settling, parts and rows,
  head tags' state, about 2,300): engine.rs has its equivalent already, but for parts' `readOnce`,
  the page-level answers cache, and head tags.
- **Hydration** (5,084 to 5,459, plus `Cursor`, `seed`, `adopt`): missing in the engine.
- **Navigation in place** (pages, navigating, prefetch, View Transitions, leaving, kept levels,
  about 1,400): missing. Half of it is browser work (history, scroll, focus, `DOMParser`, the
  announcer), half decisions (route matching, levels kept, caches).
- **Forms** (234): mostly in the engine; redirects, file forms and flash are missing.
- **Channels** (the `Hub`, 335): missing; a stream reader and back-off in JavaScript, the rest
  decisions.
- **Transitions, moves (FLIP) and drags** (125, 272, 211, and part of The DOM's 1,093): missing.
  These are mostly browser work: they read layout in the middle of a flush, animate, and make
  synthetic drag events. They stay JavaScript modules: the engine says what enters, leaves, glides
  or is dragged, and JavaScript measures and animates.
- **On the server** (362): runtime.js's Node renderer, used only by the tests (48 calls in
  web/test/platform.test.mjs; navigation.test.mjs; byte-for-byte checks against the native server in
  site/test and test/e2e). The real server never runs it.

## The three hard parts, and how each is done

### 1. The server: one pass, reads answered on the spot, renders interleaved

The server renders a page in one pass and never runs a hole again: nothing is tracked, a memo is
computed as it is made, templates answer 0, and effects, timers and cleanups are let go of. It never
waits inside the renderer either. A read of an endpoint calls it in the process (`in_process`), and
if that touches the database or the network, the whole request (a coroutine) pauses and resumes
with the answer (`hosted::wait` → `coroutine::pause`). Several renders interleave on one thread
whenever one pauses, and there are a few such threads.

So the engine needs:

- **A server mode:** run each hole once, track nothing, no effects, timers or cleanups, no templates.
- **Reads answered synchronously:** the engine asks its platform for a read's answer and gets it
  back at once, called outside the engine's borrow (the in-process call re-enters Roc and may pause
  the coroutine). On the phone and in the browser the same call answers "not yet", as now.
- **An engine per render, swappable:** the engine's state (one `thread_local` today) taken out and
  put back at every pause, as signals.rs does with `stash`/`unstash`, its inbox, outbox and
  platform its own (messages carry an engine id, not a generation), and rocx-memory's frames per
  coroutine. `Engine` is `!Send` (it holds `Rc`s and Roc pointers): a render never moves threads,
  which the coroutines already guarantee.
- **The HTML written exactly as now:** the document's comments get their labels (`x`, `html`,
  `list`, `show`, `for`, `row`, `fallback`, `loading`, `errored`, `errored:failed…`, `nohydration`;
  dom.rs keeps none today), a live text hole its `x` range, static holes and `show`s none (D-052),
  classes and styles in the markup's order (dom.rs appends a toggled class and moves a changed
  style last), no comments inside RCDATA or `<NoHydration>`, void elements, escaping, D-079's
  refused names, D-086's `aria-current`, and the document around it (the title, head tags, the
  answers, flash and plugin scripts, `data-build`, redirects). The parity tests check it byte for
  byte.
- **Memory:** the server's per-call allocation lists (a failed run freed whole, what a page holds
  freed at its end) or rocx-memory's frames (D-091), one of the two for both.

### 2. Hydration in the browser

runtime.js hydrates by walking the server's DOM in document order beside its own run, claiming each
node. The engine can't do it in a pass before running: whether a hole is static, and so whether it
has comments around it, is known only once its Roc has run. So the walk is the engine's, over the
server's DOM given as data:

1. JavaScript reads the body once into a compact description (each node's kind, tag, a comment's
   label, a text's length; regions and host elements marked) and hands it to the engine, with the
   answers script (`seed`).
2. The engine renders as it would afresh, but walks the description with a cursor (runtime.js's
   `Cursor` and `adopt`, ported): instead of "make this node" it emits "the node at this place is
   yours, id N", "split this text at offset K" (a static hole's text, which the HTML parser joined to
   its neighbours), and a patch where a value differs. CLONE's mechanism in engine.js (ids given to
   an existing subtree in order) is most of the JavaScript side.
3. A mismatch: strict mode throws; otherwise the engine renders the body afresh, keeping
   `<NoHydration>` regions and host elements, as runtime.js does.

### 3. Events and the browser's own work

- **Decisions that must be synchronous** (whether a click, a submit or a key is cancelled: the route
  table, actions, key combinations): the listener calls into the wasm and gets a verdict back
  before returning. Calls into wasm are synchronous; events can't be queued for later.
- **What exists only during an event** (a drag's `dataTransfer`, `FormData` with its submitter,
  `File`s): read by JavaScript in the listener; files stay in JavaScript, the engine holds their
  `blob:` URLs.
- **Layout reads in the middle of a flush** (FLIP glides, drag images, scrolling near an edge,
  `.point`): JavaScript modules driven by the engine, as above.
- **Live DOM state** (`.value` after typing, classes a page script added, `isEqualNode` diffs of the
  head): patches are "set if different", read on the JavaScript side.
- **Requests, timers, the clock** through the page: today the engine starts OS threads and reads
  `SystemTime`, which panic on wasm32 (lib.rs 169, http.rs 17, hosted.rs 283).

## What it costs

- **The port.** The engine grows by a few thousand lines (hydration, navigation, channels, head
  tags, complete events and forms), and JavaScript modules for transitions, glides and drags remain.
  runtime.js retires at the end.
- **The tests.** runtime.js's Node renderer feeds about fifty tests; they would render through the
  engine (the native server, or the engine's wasm in Node).
- **The server's speed, unknown.** signals.rs builds strings in one pass; the engine builds a
  document and then writes it out. To be measured first (`just site` times every page's render;
  the echo benchmark).
- **The download:** about 50 KB more with brotli (119 KB of wasm against 67 KB of wasm and
  runtime.js, D-087's page). Only on a first visit once the files are cached, which they aren't yet
  (below).

## Found along the way: the wasm and the runtime aren't cached

The server marks only files named by their content as `immutable` (`http::named_by_content`: the
stylesheet, `styles-<hash>.css`). `app.wasm`, `runtime.js` and `start.js` have fixed names and no
validator (no `ETag`, no `Last-Modified`), so a browser downloads them again on every visit. Named
by their content as the stylesheet is (the page's HTML names them; `start.js` is told the others'),
they would be kept for a year. Small, and worth doing whatever is decided here.

## The plan, in phases

1. **One Rust core for the server and the phone.** The engine's instance model (swappable, per-engine
   inbox and platform; fetch, timers and the clock through the platform), labelled comments and
   ordering in the document, an HTML writer, the server mode, and signals.rs replaced. The browser
   is unchanged: runtime.js still hydrates the server's HTML, and the parity tests hold it to the
   byte. First step inside it: measure a render by the engine against signals.rs on the site's
   pages.
2. **The conformance suite:** the web test app (`web/test/app`) run on the engine and compared with
   Chromium's DOM after each step (D-063's phase 0). The checklist for everything after.
3. **Hydration by the engine in the browser, behind a flag:** first the benchmark's page and simple
   apps.
4. **The browser's features, one at a time:** events with synchronous verdicts, requests, timers and
   the clock through the page, forms complete, head tags, navigation (with prefetch, leaving, kept
   levels, View Transitions), channels, and transitions, glides and drags as JavaScript modules.
5. **The switch:** the tests rendering through the engine, runtime.js retired.

## Open questions for the user

1. Phase 1 first, as above?
2. The server's memory: its per-call lists, or rocx-memory's frames for both?
3. The cache fix (files named by their content) now, separately?
