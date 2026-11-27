# Roc Solid's browser platform (`web/`)

The browser platform runs a Roc Solid app's components in the browser. An app's `.rocx` files
compile to one WebAssembly module. Inside that module, a small host written in Rust manages Roc's
memory and passes every platform call out to JavaScript. A JavaScript runtime, `runtime.js`, keeps
the signals, runs the computations, and builds and patches the DOM.

The server platform (`server/`) renders the same components to HTML. This platform then
**hydrates** that HTML: it takes over the nodes the server sent, without building them again, and
keeps the page live from then on. The two platforms share most of their Roc modules. Those
modules are written here, in `web/platform`, and `server/build.mjs` copies them into
`server/platform`, so the same component code compiles on both.

Read this before you change `web/platform/*.roc`, `runtime.js`, `start.js` or `host/`. It
explains how the pieces fit, how each feature works inside, and which tests cover it. For how to
*use* the features, see the docs site (`site/routes/`: the components, syntax and platform pages)
and the platform reference (`/platform/reference`, generated from the modules' `##` comments).
Decision numbers (D-0xx) point into `DECISIONS.md`, which records why things are the way they are.

## Contents

- [Terms used here](#terms-used-here)
- [Quick start](#quick-start)
- [The big picture](#the-big-picture): the pieces, how a page comes alive, the modules, the runtime an app ships
- [Markup: what Roc hands the runtime](#markup-what-roc-hands-the-runtime)
- [Reactivity](#reactivity): tracking, the flush, waiting, `is_pending!`, effects, ownership, timers, stores, selectors
- [Components, props and control flow](#components-props-and-control-flow): props as getters, `if` and `match`, `.map`'s rows, `<Repeat>`, contexts
- [Talking to the server](#talking-to-the-server): reads, forms, actions, optimistic values, the flash, channels
- [Rendering on the server, and hydrating](#rendering-on-the-server-and-hydrating): documents, `<NoHydration>`, titles and the head
- [Navigation in place (D-040)](#navigation-in-place-d-040): which clicks, links that say where the page is, kept levels, prefetch, leaving
- [Events and the DOM](#events-and-the-dom): keys, `<Document>`, the page's own functions, drags, transitions, glides
- [The native engine (`native/`)](#the-native-engine-native)
- [Tests](#tests)
- [Not yet](#not-yet)

## Terms used here

- **Box**: a Roc closure handed to the runtime. JavaScript can't look inside it. The runtime keeps
  it under an id and asks Roc to run it (`roc_run`).
- **Computation**: a box the runtime runs again when something it read changes. Holes, computed
  attributes, memos, an effect's `compute`, the makers of parts and rows, and the root are all
  computations.
- **Hole**: `{x}` in markup. A **static** hole reads nothing that changes and is written once. A
  hole that reads a signal, a memo or a getter is a computation.
- **Handler**: a box run for an event, a timer's tick or an effect's apply. Its signal writes are
  queued and applied together when it is done.
- **Flush**: one pass, in a microtask, that runs every dirty computation and then the effects whose
  apply is due.
- **Owner**: the run that made something (a component, a computation, a handler's element). What a
  run makes goes when the run goes.
- **Part**: the markup one branch of a hole's `if` or `match` makes, or a boundary's fallback.
  **Row**: the markup one item of a `.map` makes.
- **Region**: what is inside a `<NoHydration>`, which only the server renders.
- **Answers**: the results of the GET endpoints a page read while the server rendered it. The page
  carries them, so hydrating asks the server for nothing again.

## Quick start

```sh
just setup        # the toolchain: the Roc fork, Zig, Rust (with its wasm32 target), Node. Once.
just web-host     # host/ (Rust) -> platform/targets/wasm32/host.wasm (the tests build it too)
just test-web     # web/memory's cargo tests, then this platform's tests and the docs site's, in Chromium

# One suite, or the tests whose name matches:
node --test --test-concurrency=1 web/test/platform.test.mjs
node --test --test-concurrency=1 --test-name-pattern="stores" web/test/platform.test.mjs
```

## The big picture

### The pieces

| Piece | Where | What it does |
| --- | --- | --- |
| Platform header | `platform/main.roc` | Says what an app provides (`main! : {} => Html`, its root), what the platform exposes, and which Roc function each hosted symbol is (`"roc_fetch": Host.fetch!`, …). Gives the host two entry points: `roc_mount` (the root's markup, as JSON) and `roc_run` (run a kept box). Its targets: `wasm32` for the browser, and `arm64musl` and `arm64mac` archives for the native engine (below). |
| Platform modules | `platform/*.roc` | What components are written with: `Html`, `Solid`, `Router`, `Endpoint`… ([the modules](#the-modules)). |
| Host interface | `platform/Host.roc` | Every hosted function, each a call into the runtime: signals, memos, rows, contexts, fetches, timers, submissions, navigation. Its `##` comments say what each does. |
| Host | `host/` | Rust with no std, inside the wasm (D-090). Strings in and out, and one small wrapper per hosted function that calls a `js_*` import (`host/src/lib.rs`). Roc's memory is rocx-memory's, the next row's. `just web-host` builds it with cargo for wasm32 and makes the relocatable object Roc links (`zig wasm-ld -r`): `platform/targets/wasm32/host.wasm`. Its glue, `host/src/roc_platform_abi.rs`, is `just glue`'s, the same as `native/core`'s. |
| Memory | `memory/` | rocx-memory (D-091), a Rust crate with no std that this host and the phone's (`native/core`) both use: the allocator (`memory/src/brk.rs`, slots of a power of two, as Zig's allocator for wasm has them), and each run's allocations noted, so a run that unwinds can be freed (`memory/src/lib.rs`; [Waiting](#waiting-reads-that-arent-in-yet)). `just test-web` runs its `cargo test`. |
| Runtime | `runtime.js` | The engine. Keeps boxes, signals, memos and computations; tracks what reads what; schedules and flushes; builds, hydrates and patches the DOM; talks to the server (reads, event streams, forms, the channel hub); navigates in place; and renders to a string as the server would. |
| Bootstrap | `start.js` | The script the server puts before `</body>`. Loads `runtime.js` and `app.wasm` from beside itself and hydrates the document. |
| Tests | `test/` | Two test apps (`test/app`, `test/nav`), a scripted server (`serve.mjs`), a browser driver (`browser.mjs`) and two suites ([Tests](#tests)). |

### How a page comes alive

1. **Build.** `rocx build --client` writes the browser's copy of the app (`build/client`): the
   `.rocx` files as Roc, a `main.roc` whose `main!` is `Generated/Root`, and every `<NoHydration>`
   emptied. It copies `start.js` and `runtime.js` into `build/client/static/rocx/` (the runtime
   minified, but in a dev build). Then `roc build --target=wasm32` links the copy with `host.wasm`
   into `app.wasm` beside them. `rocx dev` and `site/build.mjs` run both steps. A static copy and
   a release ship a runtime with only what the app uses ([The runtime an app
   ships](#the-runtime-an-app-ships-d-087)).
2. **Server render.** The server platform renders the page (`server/host/src/signals.rs`). Every
   hole runs once. Comments mark where each computed hole, part and row is (`<!--x-->…<!--/x-->`).
   Before `</body>` it writes the flash (if the page read one), the answers, the plugins' scripts
   and `<script type="module" data-rocx src="/rocx/start.js">`.
3. **Bootstrap.** `start.js` fetches `app.wasm` and imports `runtime.js`, both from beside itself,
   and calls `Runtime.load(wasm, { base })`. The base is the directory above `start.js`, so a site
   served under a path of its own works: at `example.github.io/rocx/`, `start.js` is
   `/rocx/rocx/start.js` and the base is `/rocx/`. Then it calls
   `runtime.hydrateDocument(document)` and dispatches `rocx:ready` on the document, with
   `{ runtime, ms }`.
4. **Mount.** The runtime calls the wasm's `mount`. Roc runs `main!` and serializes its markup
   (`Html.serialize!`). Each closure in the markup is handed to the runtime as a box, and the JSON
   names it by id.
5. **Hydrate.** The runtime walks that JSON beside the server's DOM and binds each computation to
   its node. A read the server answered is answered from the page's answers script. Nothing is
   built or asked for again.
6. **Interact.** A click runs its handler's box (`roc_run`). The handler's signal writes apply when
   it is done; each schedules the computations that read the signal. A flush runs them, in a
   microtask. Each answers JSON again, and the runtime patches only its own node.
7. **Wait.** A read whose answer isn't in yet (`Endpoint.read!` of a new URL) throws through the
   Roc frames. The runtime runs the computation again once the answer is in. Meanwhile the
   nearest `<Loading>` shows its fallback (the first time) or the old value stays (after that).

### The modules

Most modules are **shared**: written here and copied into `server/platform` by
`server/build.mjs` (`SHARED_MODULES`). A few are each platform's own, under the same name.

| Module | Shared | What it is for |
| --- | --- | --- |
| `Html` | yes | Markup: elements, holes, attributes, handlers, parts, rows, boundaries. Its serializer, its escaping, and the safe-URL and safe-CSS checks. |
| `Solid` | yes | `create_signal!`, `update!`, `create_memo!`, `create_selector!`, `create_store!`, `create_optimistic!`, `create_effect!`, `create_render_effect!`, `create_effect_with!`, `on_cleanup!`, `on_settled!`, `refresh!`, `is_pending!`, `latest!`, `untrack!`, `use_context!`, `set_interval!`, `set_timeout!`. |
| `Store` | yes | A store's reads by part (`get!`) and `Store.of(accessor)`. |
| `Repeat` | yes | `<Repeat>`: rows for a range of indexes. |
| `Loading`, `Errored` | yes | The boundaries: a fallback while values come in, and one for a failure (`Errored.status_of`). |
| `Context` | yes | Contexts and their providers. |
| `Transition` | yes | What `transition`, `transition:in`, `transition:out` and `transition:move` play: `fade`, `fly`, `scale`, `grow`, `glide`, `style`, adjusted with `ms`, `delay`, `easing`, `origin`, `plus`. |
| `Title` | yes | `<Title>`. (`<Meta>`, `<Link>` and `<Style>` are rocx's own tags, D-054.) |
| `HttpStatusCode` | yes | `<HttpStatusCode code={404} />`: the status the server answers the page with. |
| `Browser` | yes | `call!`: the page's own JavaScript, from a handler; `focus!`. |
| `Router` | yes | `location!`, `navigate!`, `navigate_with!`, `is_routing!`, `use_search_params!`, `use_before_leave!`, `use_submission!`, `use_submissions!`, `use_action!`, `revalidate!`, and `app!` (what `Generated/Root` tells the runtime about the app). |
| `Search`, `Leave` | yes | The query (`get!`, `all!`, `set!`, `set_with!`); a navigation about to leave (`to`, `from`, `options`, `delta`, `default_prevented`, `prevent!`, `retry!`). |
| `Navigate` | no | `<Navigate href>`: here, a navigation that replaces the history entry; the server's is a 303. |
| `Call` | yes | `fetch!` (a request) and `listen!` (a stream of server-sent events). |
| `Endpoint` | yes | An endpoint as a typed value: read it (`get!`, `read!`, `with_query`), send it (`send!`), listen to it, subscribe to a channel (`subscribe!`, `say!`, `resync!`, and on the server `publish!`, `publish_latest!`), bind a form (`url_of`, `with_fields`), check its body by the app's rules (`checked`, D-093), and, on the server, run and answer it (`bind`, `run!`, `respond!`, `posted_by`). |
| `Submission`, `Submissions` | yes | A form's or an action's submissions: `pending!`, `input!`, `field!`, `result!`, `error!`, `clear!`, `retry!`; `all!`, `pending_inputs!`. |
| `FormBody` | yes | Reads a form's fields as the endpoint's body type (D-038). |
| `Channel` | yes | What a route's `channel!` answers (`Channel.allow(who)`) and what a subscriber hears. |
| `Server`, `Middleware`, `Events`, `OpenApi` | yes | HTTP's: requests and responses, cookies, the flash, uploads; middleware; event streams; the OpenAPI document. Only the server runs most of them; Roc compiles only what a program reaches, so they cost the wasm nothing. |
| `FlashStore` | no | Where `Server` keeps and reads flashes. The browser reads the flash the page carried. |
| `Time` | no | The clock: `now_millis!`, `now_nanos!`, under the server's names. |
| `Host` | no | The hosted functions (above). |

`Generated/Api` (written by `rocx build`) is the app's contract: each endpoint's method, URL and
types, the same in the browser's copy as on the server (D-037). The browser answers no requests:
the server platform answers every endpoint, the GETs a page reads among them.

### The runtime an app ships (D-087)

`runtime.js` answers every host function any app's wasm may call, and has the code each needs.
`rocx build --static` and `--release`, once the app's wasm is built, ship it **shaken**
(`rocx-cli/Shake.roc`), then minified:

- the entries of `makeImports` the wasm doesn't import go (its import section says which);
- then every member of `Runtime` that no kept code names (`.name`), starting from what is outside
  the class, the constructor, the fields, the imports kept, and what `start.js`, the tests and
  pages' scripts call (`Shake.kept`);
- a line tagged with a feature (`… //#nav`, `//#drag`, `//#point`, `//#moves`) goes where the app
  doesn't use it (`Static.features!`): navigating in place when the app has one page and its wasm
  calls nothing that navigates; drags, a pointer's point and `transition:move`'s glides when the
  browser's copy of its code doesn't write them.

Shake reads the runtime by its lines, as it is written: a member starts at one tab and ends at the
next line that is one tab and `}`, and the imports are the entries at three tabs. Keep that shape,
and put a feature's tag on a whole statement. A runtime written another way ships whole, with a
warning. A member reached only by a name built at run time (`this[name]`) would be left out: the
runtime has none. `rocx build --client`, `rocx dev` and the tests that load `runtime.js` use it
whole.

## Markup: what Roc hands the runtime

### Markup is JSON

A component returns `Html`. `Html.serialize!` turns it into JSON for the runtime. Every closure in
it is handed over as a box (`Host.keep!`), and the JSON holds the box's id (`"r": id`). Running a
hole means `roc_run(box)`, and its answer is JSON again: a string for text, or markup.

| Node `t` | Written by | What it is |
| --- | --- | --- |
| `e` | `Html.element`, `Html.void` | An element: its `tag`, attributes `a`, children `c`. |
| `s` | `Html.text`, a static hole's text | Static text. |
| `raw` | `Html.source_text` | A `<script>`'s or `<style>`'s text, as the `.rocx` file has it. |
| `doctype` | `Html.doctype` | `<!doctype html>`. |
| `f` | `Html.join`, `<>…</>` | A fragment. |
| `hx` | `Html.hole_of` | A hole that reads what changes (D-070). Its run answers a JSON string while it shows text alone, and markup's JSON otherwise. |
| `x`, `h` | `Html.text_of`, `Html.html_of` | A hole that always shows text, or always markup. rocx writes `h` for a pure component's call that reads what changes; `x` is for hand-written Roc. |
| `l` | `Html.list_of` | A list hole (`{...xs}`) whose list changes but isn't a `.map`'s rows: remade whole each time. |
| `show` | `Html.branched` (`"b": 1`), `Html.switched` | A part. `r` answers the name of the branch that holds (`"#0"`), or `false`; `with` makes the part. |
| `for` | `Html.each` (`Html.rows!`, `Html.rows_at!`, `<Repeat>`) | Rows. `r` answers `[{k, r}]`: each row's key and the box that makes it. |
| `tpl` | `Html.template` | A `.map`'s row as a template (D-084): its site's id `s`, its skeleton `k` the first time, and its parts `p` ([below](#a-maps-rows-d-071)). |
| `c` | `Html.component` | A component, run where it is rendered. |
| `loading`, `errored` | `<Loading>`, `<Errored>` | Boundaries: `<Loading>`'s fallback, and a box that makes `<Errored>`'s. |
| `ctx` | `Context.provide!` | A context's value for what is inside. |
| `nh` | `Html.no_hydration` | A `<NoHydration>` region. |
| `listen` | `Html.on_document`, `Html.on_window` | Handlers on the document or the window. |

Attributes are arrays, their kind first:

| Kind | Written by |
| --- | --- |
| `v`, `vo` | `Html.attr` (and `Html.attr_literal`, a value written in the file), `Html.attr_of` (computed: a box) |
| `o`, `oo` | `Html.optional`, `Html.optional_of`: there only while not empty (`name??={…}`) |
| `sv`, `so` | `Html.style_var`, `Html.style_of`: `style:color`, `style:--size` |
| `f`, `fo` | `Html.flag`, `Html.flag_of`: a boolean attribute |
| `ci`, `co` | `Html.class_if`, `Html.class_of`: `class:name={…}` |
| `on` | `Html.on`, `on_value`, `on_checked`, `on_named_key` (a fourth item: the key, `"Shift+Enter"`), `on_data` (`".data"`), `on_files` (`".files"`) |
| `onk` | `Html.on_key`, `Html.on_keys` (a fourth item, `"keys"`) |
| `onp` | `Html.on_prevent`: `on:click.prevent` |
| `frame`, `view`, `pt` | `Html.on_frame`, `Html.on_viewport`, `Html.on_point` |
| `dd`, `ddo` | `Html.drag_data`, `Html.drag_image`, and their computed forms |
| `k`, `ko` | `Html.key`, `Html.key_of` |
| `tr`, `tro` | `Html.transition`, `Html.transition_of` |

An element's own `class` (`v`, `o`, `vo`, `oo`) and its `class:name`s (`ci`, `co`) are one `class`
attribute, in the markup's order, wherever it is written (signals.rs, `renderToString`,
`Html.to_str`) and as the runtime builds and patches it: a computed class's new value keeps the
`class:name`s that are on, and a `class:name` keeps the computed value (D-112). The same for
`style` and its `style:name`s (`sv`, `so`).

Data can't write code into a page. Text and attribute values are escaped wherever markup is
written as HTML (the server, `Html.to_str`, `renderToString`), and the runtime sets them as text.
A URL attribute (`href`, `src`, `action`…) whose scheme isn't `http`, `https`, `mailto` or `tel`
becomes `about:invalid#rocx-unsafe-url` (an image's `data:image/…` is allowed; `safe_value`). A
style's value goes through `safe_css`, which drops anything that could end the declaration and any
CSS function except those that compute a value (`rgb(…)`, `calc(…)`, `var(…)`; never `url(…)`).
`Html` never writes a `value` into an `<input type="password">`, whatever a component gives it.
Names are checked wherever markup is written or built (D-079: signals.rs, `Html.to_str`, the
runtime's `writable`): an element whose tag isn't a plain name (an ASCII letter, then letters,
digits and `-`), or a `<script>` whose children aren't all `raw` (a `.rocx` file's text), is left
out, and so is an attribute (`v`, `vo`, `o`, `oo`, `f`, `fo`) whose name isn't one (letters,
digits, `-`, `_`, `.`, `:`, starting with a letter) or starts with `on`. The server logs each
page's, the runtime warns once a name.

### Static holes and computed holes

rocx decides how to write a hole from what it calls:

- A hole that calls nothing named with `!` reads nothing that changes. rocx writes it as
  `Html.shown(x)` (what `Html.hole(x)` shows, marked as a value, for templates: D-084), and such
  an attribute as `Html.attr`, `Html.class_if`, `Html.style_var`…; an attribute's value written
  in the file is `Html.attr_literal`. No box is kept, and the server writes no comments around it.
- A hole that calls something named with `!` is a computation: `Html.hole_of(|| Html.hole(x))`.
  `Html.hole` shows text, a number or markup, picked by `x`'s type through Roc's encoding
  (`Html.Hole`). A value of any other type, a record or a `Bool`, is a compile error at the hole.

The transpiler can't always tell. A hole that calls a getter (a prop, D-039) is a computation,
even when the prop was given a constant. So the runtime checks after the first run (D-052): a run
that made no tracked read and made nothing is **inert** (`inert` in `runtime.js`). A tracked read
is one of a signal, a memo, a row's item, a submission, an endpoint or `is_pending!`, outside
`untrack!`. Making something means a signal, memo, effect, cleanup, timer, listen, subscription or
title. An inert hole is static after all:

- The server notes the same calls (`touched` in `signals.rs`) and writes such a hole without its
  comments.
- Hydrating runs it, finds it inert, and takes the server's text as static text (splitting it off
  the text the HTML parser joined it to), or its markup in place. Strict hydration accepts this.
- Its computation isn't kept. A markup hole's stays as the owner of what is inside, but never runs
  again. A computed attribute whose run read nothing isn't kept either.

### Raw text, the doctype, and `Html.to_str`

A `<script>`'s or `<style>`'s text is `{"t":"raw"}`. Hydrating takes it without comparing it. A
`<script>` the runtime builds doesn't run, as in Solid; the server's ran when the browser read the
page. `Html.to_str` renders markup that has nothing to run (an email's HTML, an `expect`'s
markup). A computation, a part, rows or a component in it is an error.

## Reactivity

### Tracking and the flush

A computation runs with the runtime noting what it reads (`js_signal_get`, `js_memo_get`, a row's
item, the location…). A signal's setter, called in a handler, queues the write. When the handler
is done, the writes apply, and each schedules the computations that read the signal. The
flush runs in a microtask. A value a node already has isn't patched again.

A read in the handler still gives the value before its writes, as Solid 2.0's does. `Solid.update!`
(D-094) is the setter's function form: it reads through the accessor with `Host.own_writes!` on,
and while it is, `js_signal_get` gives the handler's latest queued write to that signal (a plain
write or an optimistic one), else its value. So two updates in one handler compose, and nothing
else sees a write before it applies. A handler run again after a wait starts with no writes and
`own_writes!` off.

A setter can't compare Roc values, so every write runs the signal's readers. (Memos and store
selections do compare, below.) Keep state that nothing shows in a signal nothing reads.

The flush runs what is dirty **oldest first**: a memo before what reads it, and an owner before
what it made. Then, with nothing dirty, it runs the effects whose apply is due, oldest first.
Both wait in a set with a heap beside it (`Pending`), so taking the next of D waiting costs
log D. That matters when one signal has many readers: a grid whose thousand boxes read one signal
puts a thousand computations in the flush at once.

`untrack!(read!)` (Solid's `untrack`) runs `read!` with the running computation's reads not
noted (`Host.untrack!` on, then off). A memo made inside it tracks its own reads, and a read that
waits still waits. `latest!(read!)` (Solid 2.0's `latest`) is just `read!()`. A memo read again
already shows the value it last settled at, because nothing holds writes back until a change is
done, as Solid 2.0's transitions do. It would differ only if writes were held back.

### Waiting: reads that aren't in yet

A read whose value isn't in (an endpoint's answer, a memo waiting for one) throws, in JavaScript,
through Roc's frames (`NotReady`). The runtime restores Roc's stack pointer and runs the
computation again when the value comes. A handler that waits drops its writes and runs again
later. The answers its calls already got are kept, so a command is sent once.

The throw skips the drops Roc would run on the way out, so the host keeps count of memory:

1. The runtime opens a host **frame** around each call into Roc (`frame_begin`). While it is
   open, the host notes every allocation made and every box handed to the runtime.
2. A call that returns closes its frame (`frame_end`). Its notes go to the frame around it, if
   any (a memo made inside a component's run, say).
3. A run that unwinds keeps its notes (`frame_unwound`) until the runtime has let go of what the
   run made: its computations, signals, cleanups and boxes.
4. Then whatever the run allocated and still holds is held only by the unwound frames, and the
   host frees it (`reclaim`).

This is safe because Roc's values are immutable, and a value the runtime gives Roc comes with a
reference of the runtime's own: nothing older can point at what the run made. If a box the run
handed over is still allocated, nothing is freed. That would be a leak, never a use after free.
A run that fails, and a probe or a handler that waits, is reclaimed the same way. What the
unwound frames held of older values (a value read, counted once more) stays counted. That is why
`js_fetch` answers "waits" and the host's `js_waits` throws only after the host has let go of the
request's text.

The nearest `<Loading>` shows its fallback until everything inside has its first values. After
that, a memo read again keeps showing its last value while it waits, and `is_pending!` says so. A
failure shows the nearest `<Errored>`.

A memo computed again compares its value with the last by Roc's `==` (D-109), as a store's
selection does (`Host.memo_last!`, then `memo_done!`'s `same`): an equal one tells no one, so its
readers run only when it changed. `create_memo!` asks for `a.is_eq`: a memo holds data.

### `is_pending!`

`is_pending!(read!)` is Solid 2.0's `isPending`: whether what `read!` reads is waiting for a new
value while it shows an old one.

- A memo whose run waits while it has a value (and hasn't failed) is **refreshing**, from the flush
  that started that run until it settles or fails.
- A memo is **stale** if it is refreshing, or a memo it reads is stale. This is set again after
  each run and passed down to the memos that read it.
- `is_pending!(read!)` runs `read!` once as a probe, as `refresh!` does: its reads untracked, a wait
  or a failure only stopping it. It answers whether a memo it read is stale.
- The caller tracks each such memo's `pending` node, not its value, and keeps the probe. When one
  flips, settles or fails, the caller goes in the flush as a **recheck**: the probe runs again, and
  the caller runs only if the answer, or the memos read, changed.

So a reader runs again when its answer changes, and only then. A memo that becomes pending again
before the reader's turn (one that reads another that just settled) doesn't make it flicker. On
the server, `is_pending!` answers false.

### Effects

Effects are Solid 2.0's split ones: `create_effect!(compute, apply)`.

- The runtime makes a computation of `compute`, tracked and owned by the component or computation
  running. Its answer is the id of a box holding `apply` with `compute`'s value inside.
- `apply` runs after the flush, once nothing is dirty, oldest first: the markup is on the page by
  then. It runs as a handler (untracked, its writes applied when it is done), after the last
  apply's cleanups.
- A `compute` that waits runs again when its value is in. It holds no `<Loading>`. One that fails
  shows the nearest `<Errored>`.
- Solid's apply returns its cleanup. Here it calls `on_cleanup!`, since a Roc function can't return
  "nothing". Neither half is given the previous value.
- `on_settled!(f)` is `create_effect!(|| {}, |_| f())`. A `compute` that reads nothing never runs
  again, so `f` runs once, after the flush that put the component on the page, and never on the
  server.

Two more of Solid 2.0's (D-052). Each is an effect whose `compute` first tells the runtime its
options (`Host.effect_options!`):

- `create_render_effect!(compute, apply)` (`createRenderEffect`) runs `apply` as soon as `compute`
  has answered, as the render does, not after the flush. Made in a component, it runs before the
  component's markup is built; run again in a flush, it runs before the effects' applies.
- `create_effect_with!(compute, { apply, error })` (`createEffect(compute, { effect, error })`)
  keeps a box for `error`. A `compute` that fails calls `error` with why (`Host.event_value!`),
  in the apply's place (after the flush, as a handler, the last apply's cleanups first), and no
  `<Errored>` shows. If `compute` answers again before then, `apply` runs instead.

On the server, neither half of any effect runs. (Solid's server runs both halves of a render
effect.) What a render effect's first apply writes is patched in as the page hydrates.

### Ownership and cleanups

Ownership is Solid's (RFC 02). What a run makes is its own: child computations, effects, cleanups,
timers, listens, and the endpoints whose forms it sends. It goes with the run, in unwind order: the
last child first, then its cleanups, the last first.

- A computation's cleanups run before it runs again. An effect's apply's cleanups run before the
  next apply.
- `on_cleanup!` in an event handler fails, since nothing would run it.
- A listen (`Call.listen!`) started in an owner is aborted when that owner is cleaned up. One
  started from a handler runs to the stream's end.

### Timers and the clock

`set_interval!(ms, tick!)` is `setInterval`, and `set_timeout!(ms, done!)` is `setTimeout`
(`Host.interval!`, `Host.timeout!`). Their handlers run as a click's do. Each answers its
`clear!` (`Host.clear_timer!`).

A timer belongs to what started it, and stops with that run's cleanups, as if it had called
`on_cleanup!(clear!)`:

- started in a component or a computation (an effect's `compute` too): when the computation runs
  again, or the component goes;
- started in an effect's apply: before the next apply;
- started in an event handler: when the element whose handler it is goes.

`runtime.timers` holds the running ones. On the server none starts, and the id is 0.

`Time.now_millis!({})` is `Date.now()`. `Time.now_nanos!({})` is
`performance.timeOrigin + performance.now()` in nanoseconds, which doesn't go back while the page
is open. The host turns JavaScript's floats into whole numbers. Use the clock in handlers,
effects' applies and timers, not while rendering: markup made from the time would differ from the
server's, and hydration would refuse it. A date that decides what a page shows comes from the
server, and so does a deadline (a countdown counts to it by this clock). There is no
`Time.sleep!` here: `set_timeout!` waits.

### Stores (D-053)

A store is Solid 2.0's `createStore`. The design, and what was weighed, is in
`spike/stores/DESIGN.md`.

```roc
(todos, set_todos!) = create_store!({ items: [], filter: All })
<p>{Filter.name(todos.get!(|s| s.filter))}</p>
<button on:click={|| set_todos!(|s| { ..s, filter: Done })}>Done</button>
```

`create_store!` makes a signal of the whole value and a `Store(s)` over it. Roc has no proxies, so
a read can't see which field it touched. Instead, a read **selects** (`todos.get!(|s| s.filter)`)
and is tracked by what it selected:

- In a computation that tracks (a hole, an attribute, a memo, an effect's `compute`), `get!` makes
  a **selection**: a memo of the part, owned by the reader's run. When the store changes, the
  selection computes its part again and compares it with the last one by Roc's `==`
  (`Host.memo_last!`). If equal, it says so (`Host.memo_done!`'s `same`), and the runtime doesn't
  tell its readers. So a write runs every live selection of the store once (a pure function and a
  comparison each), and only the readers whose part changed run again.
- Anywhere else (a handler, a component's body, a part's first run, inside `untrack!`, or on the
  server: whatever `Host.tracking!` says isn't tracking), `get!` applies the selector once, and
  nothing is made.
- A part must compare (`where [a.is_eq : …]`). Records, tags, lists, text and numbers do; a type of
  your own needs its `is_eq`. A function or markup can't be selected, which keeps selections to
  data.
- The setter takes a function of the state, Solid 2.0's draft setter. It starts from the running
  handler's own pending write, if it made one (`Host.signal_latest!`), so two writes in one
  handler compose.
- `Store.of(accessor)` reads any accessor by parts (an endpoint's answer, a memo, a prop's getter),
  with no setter.

A selection belongs to its reader's run and is made anew when the reader runs again.
`runtime.stats.selections` counts the selections' runs; the tests read it.

### Selectors: `create_selector!` (D-083)

`is_picked! = create_selector!(picked!)` is Solid's `createSelector`, for a list where one row is
picked: `class:picked={is_picked!(row.id)}` runs, when the pick moves, only the rows it leaves and
comes to.

- `Host.selector_new!` makes a computation of kind `selector` that answers its source's key, as
  `Str.inspect` writes it, run now and again when what it reads changes.
- `is_picked!(key)` (`Host.selector_is!`) answers whether `key`, inspected the same way, is it,
  and is tracked by a source of that key alone (`selector.keys`).
- When the key changes (`settle`), the readers of the key it was and of the key it is are
  scheduled, and no other. A key no reader reads any more goes as its last reader goes, and the
  keys are swept once there are twice as many as the last sweep left, so a pick costs the same
  however many rows there are.
- On the server it is computed once; the native engine has the same (`CompKind::Selector`).

Keys compare as text: a key is inspected once per read.

### A read made once, said in a dev build (D-052)

A component's body runs once, so a read there doesn't follow what it read. This is Solid 2.0's
`STRICT_READ_UNTRACKED` dev warning:

- A dev build (`rocx build --dev`, `rocx dev`) writes each accessor a component's body calls
  (`goal!()`, a prop's getter `label!()`) as `Html.read_at!("Ui/Chart.rocx:44:39", goal!)`, which
  tells the runtime where the read is while it runs (`Host.read_at!`).
- A tracked read there, while a component runs, is a console warning, once per place:
  `rocx: Ui/Chart.rocx:44:39 reads a value that changes (a signal, a memo or a prop) in a
  component's body, once, as the component runs: what it shows won't follow it…`.
- `untrack!` says the one read is meant, and silences it:
  `create_signal!(untrack!(|| goal))`, as the charts start.
- A prop given a constant reads nothing, so it is never warned of. Neither is a read the
  transpiler doesn't see as a call of an accessor (`helper!(x)`).
- Other builds write no `read_at!` and warn of nothing; the server never warns.

`rocx build` also warns, at build time, when a match arm's value or a `.map` row's item is given
to a component that reads it once in its body. `rocx check` counts that warning (exit 2).

## Components, props and control flow

### Components run where they are rendered

rocx writes `<Picks />` as `Html.component(|| Picks.view!({}))`. The runtime runs that box as it
builds that place, once, its reads untracked, so the component sees the contexts provided above
it. A signal belongs to the run that made it, and goes with it: when an `if`'s branch switches,
or a row goes.

Two rules follow, and the runtime enforces both:

- **Read async values in holes, not in a component's body.** A body that reads a value that isn't
  in yet is an error ("read it in a hole ({…}), which waits"), since running the body again would
  make its memos again and ask the server again, forever.
- **Write signals only in handlers.** An effect's apply, a cleanup and a timer's tick are
  handlers. A write while computing fails ("a signal is written in a handler, not while
  computing").

### Props are getters (D-039)

Props are getters, as Solid's are. rocx writes `<Shows label={word!()} />` as
`Html.component(|| Shows.view!({ label: || word!() }))`. Every value prop is a function that
computes it (a constant too: `size: || 2`). rocx also rewrites the component, as its author wrote
it (`view! : { label : Str } => Html`, `|{ label }|`), to take them:

- its type becomes `{ label : () => Str }`; a default `max : U64 ?? 5` becomes
  `(() => U64) ?? (|| 5)`;
- its pattern becomes `|{ label: label! }|`;
- each read of `label` in its definition becomes `label!()`, where it is written.

So the read runs where the code is:

- in a hole, a computed attribute, a memo or an effect's `compute`: tracked there, and only that is
  patched; the component and its signals are kept;
- in a handler, an effect's apply or a timer: the current value, when it runs;
- in the component's body: once, as it runs (`first = label` keeps the first), as `props.label`
  at a Solid component's top.

A few cases need care:

- **A lambda that may be pure** (given to `.map` or `.keep_if`, or bound to a name without `!`)
  can't call a getter. rocx reads the prop where that lambda is made,
  `(|label| |x| … label …)(label!())`, so in a hole the hole tracks it. A lambda known to run as
  an effect reads the prop when it runs: `|| …`, a handler, a function child, one given to a `!`
  function (`create_effect!(…, |r| …)`), or one bound to a `!` name.
- **A component that names its whole record** (`|props|`) reads `(props.label)()`. So does one that
  names the rest of it (`|{ kind, ..rest }|`: Solid 2.0's `omit`, D-052).
- **Passing props on.** `<Base {...rest} size={3} />` is JSX's spread (Solid 2.0's `merge`: the last
  of a name wins). The fields stay getters. Where the view's props are annotated, rocx writes them
  out one by one (`label: rest.label, size: || 3`), so attributes may add more. Otherwise it uses
  Roc's record update (`{ ..rest, size: || 3 }`), which needs the component's props to be the
  record's type; `rocx check` adds a hint under the compiler's report there. A spread goes only
  to a component written in rocx (a `view!`): the platform's components take their own types, and
  a pure one takes values.
- **Not getters:** a prop named as an effect (`label!={word!()}`: an accessor, `|| word!()`, which
  the child types and calls itself), `children` (markup, whose holes are already live), and the
  props of the platform's own components (`<Loading>`, `<Errored>`…).
- **Where a prop's expression runs.** It runs where the child reads it. A context it reads is that
  place's. An async read in it waits in the child's hole (and, read in the child's body, is
  refused, as the component's own would be). Each read computes it again, as a Solid getter does;
  a memo shares the work.
- **A `.roc` component written by hand** types its value props as getters (`label : () => Str`).

### Pure components

A pure component's (`view`, no `!`) props are values, and its call runs where it is written. Given
a value read from what changes, the call becomes a hole of its own
(`Html.html_of(|| Heading.view({…}))`), made anew when the value changes.

That is a choice (D-053). To be patched in place, as Solid patches a component, a pure component
would have to take getters and read them in its holes. A pure function can't call them, and
`Html.to_str` can't run them, so every call from plain Roc (an `expect`'s
`Html.to_str(Avatar.view({ name }))`, an email's HTML) would break. A pure component that reads a
prop in its body (examples/journal's do) would be made anew anyway. Solid's way is still there:
a `view!` is kept and patched, and a pure component may take an accessor (`left! : () => U64`)
that its holes read, which keeps it (examples/quiz's `Countdown`). Made anew, a pure component
loses no state, since it has none. It loses only what the browser keeps in its elements: the
focus, a field's text, the scroll.

### A hole's `if` and `match` (D-070)

```roc
{if (count!() > 3) <Timer /> else <></>}
{match card!() { Ok(card) => <Card card={card} />, Err(_) => <p>No card</p> }}
```

A hole whose code is an `if` (with any `else if`s) or a `match`, and whose conditions or value
read what changes, is the **part** its branch makes, as Solid's `<Show>` and `<Switch>` make
theirs. rocx writes it as `Html.branched(case!, made!)`:

- `case!` names the branch that holds (`"0"`, `"1"`…), and `made!` makes that branch's part.
- The runtime makes the part anew only when the name changes. So the `<Timer>` above, and its
  signals, stays as the count goes from 4 to 5.
- Each branch is a hole of its own, so what a branch reads itself still follows.
- A match arm's names are getters (D-039's): `Ok(card) => <Card card={card} />` keeps the arm while
  the card changes, and `card` reads the newest value (the getter matches the value again). Read
  after its arm stopped holding, it calls `Html.unmatched!`, a failure. That shouldn't happen: the
  arm is made anew first.
- An `if` in a hole needs no `else` (`{if open!() { <Panel /> }}`): rocx gives it `Html.empty({})`.
- Text in every branch (`{if (busy!()) "Saving…" else "Save"}`) stays a text hole, with no part.
- A part whose case read nothing that changes is static: the server writes it without comments,
  and hydrating adopts it as it is.
- For a part made anew for each value, use a `.map` over a list of one, keyed by the value
  ([rows](#a-maps-rows-d-071)).

The node is `{"t":"show","b":1}`: its `r` answers the case's name (`"#0"`…) or `false`, and
`with` makes the part (`settleShow`). The part is made by a computation of its own, run once and
untracked, as a component is. Routes' **levels** (D-040) use the same node through
`Html.switched`. The difference: a level's part is made with `scope.level` set to itself, while an
`if`'s or `match`'s part belongs to the level around it. The run that picks the branch reads the
condition again, and that read doesn't count as a read of the location made once (`choosing`).

### A `.map`'s rows (D-071)

```roc
{...todos!().map(|todo| <li key={todo.id}>{todo.title}</li>)}
{...steps!().map_with_index(|step, i| <li key={i}>{step}</li>)}
```

A list hole whose `.map` reads a list that changes is a list of **rows**, kept as Solid 2.0's
`<For>` keeps them: made once per key, moved when the list reorders, dropped when the key goes.

- **A row per key.** rocx writes `Html.rows!(|| todos!(), |todo| todo.id, make)`. The key is the
  `key={…}` on the row's root: an element or a component (on a component, `key` is the row's key,
  never a prop). In a row that is an `if`, each branch's root gives one; the first key on the
  row's outermost markup is the row's. A key may be any value: `Html.key_text` writes a string as
  it is and any other value as `Str.inspect` does (`7`, `Done`).
- **A row per position.** `.map_with_index(|step, i| … key={i})` is `Html.rows_at!`, Solid's old
  `<Index>`. A key made from the index any other way (`key={"r${i}"}`) is refused: write `key={i}`.
- **No key, no rows.** A changing list whose row's root has no `key` is refused at the row, with a
  message saying what to write. A `.map` whose list reads nothing that changes isn't rows: it is
  made once, as plain markup. So is any `.map` inside a `<NoHydration>`.
- **Names are getters.** In the row, the item's name reads the item held under the row's key now.
  In a row per key, the index is a getter too (`Host.row_index!`, tracked: it changes as the row
  moves). In a row per position, the index is a plain value.
- **Equal keys.** A key seen before gets a suffix (`#1`, `#2`…), so it is another row. The counts
  are kept in a `Dict`: ten thousand rows take ten thousand lookups.

How it runs. The rows node is `{"t":"for"}`. Each time the list is read again, every row's item
is set again (`Host.row_set!`) with whether it is `==` the item the row had (`Host.row_last!`).
Only a row whose item changed is told. So one changed item in a thousand runs that row's holes
alone: the tests count 3 runs (the list and the row's two holes) against 2,001 when every item
changes. Items must compare, as a store's parts do: a list of records holding functions or markup
can't be rows.

`settleFor` keeps a row whose key is still there, and moves its nodes if its place changed. A new
key gets a row made by a computation of its own, run once and untracked (Solid's `mapArray` and
`untrack`), so a change of what it read at its top doesn't remake it. (A read that waits does run
it again, once its value is in.) Its holes, and the getters it gives its components, follow the
item. A row may hold another `.map` or an `if`, owned by the row (D-036). A key that is gone drops
its row, after the row's transitions out.

**A row is a template (D-084).** rocx writes a row's markup as `Html.template(site, …)`, `site`
naming the module and how many `.map`s come before it there. It also marks what was written in the
file: an attribute's literal value is `Html.attr_literal`, and a hole that reads nothing that
changes is `Html.shown` (a value, even when it is text). Once the page is up, the first row made at
a site sends the runtime its skeleton: its elements with their literal attributes, its literal
text, and a slot for everything else (`{"t":"tpl","s":id,"k":…,"p":[…]}`). Each row after that
sends only its parts (`"p"`: its holes, handlers, keys, attributes from values, components),
in its slots' order. The runtime keeps the skeleton as nodes, copies it for each row
(`cloneNode`), finds each slot by its path, and puts the parts in with the code `element` and
`build` use (`fill`, `instantiate`). So a row costs Roc a walk and a short JSON, not its whole
markup, and the browser one copy, not an element at a time: creating 1,000 js-framework-benchmark
rows went from 110 allocations a row to 39, and from about 30 ms to 24. On the server, in the
native engine and while hydrating (the nodes there must be the server's, node for node)
`Host.template!` answers 0, and a row is its markup, as before; so is a row whose root isn't an
element, or that holds a `<script>`, `<style>`, `<title>` or `<textarea>` or a name markup can't
have (D-079).

### `<Repeat>`

`<Repeat count!={n!()} from!={first!()}>{|index| …}</Repeat>` is Solid 2.0's: rows with no list
behind them, one per index from `from!` (0 by default) up to `from! + count!`. Each is keyed by its
index (`Html.each`, the node `.map`'s rows use, so the server renders it and hydrating adopts it as
one). When the range moves, only the rows that enter it are made and only those that leave it go.
The child is given its index, which doesn't change, so a kept row has nothing to run again. Virtual
lists render the rows that show with it (packages/virtual).

### Fallbacks are made as they show

A fallback (a `<Loading>`'s) is serialized as a component node (`{"t":"c"}`, `Html.serialize!`'s
`made!`). Its box runs where the fallback is rendered: once, untracked, owned by the part, and
again each time the fallback shows again. So the holes inside it aren't kept until then.

### Contexts

rocx names each context after its module's path and its definition
(`Context.required("Demos/Picks.picks_context")`), since Roc's values have no identity to tell two
contexts apart. `create_context(…)` needs `import pf.Context` in the file. A
provider's value is kept by the runtime under an id (`Host.context_value!`), and the runtime
carries provided values down the tree as it builds. `use_context!` finds the nearest provider
(`Host.context_find!`). A context with no default, provided by nothing above, fails, and the
nearest `<Errored>` says why.

## Talking to the server

### Endpoint reads

`endpoint.read!()` reads a GET endpoint as a plain value (`endpoint.send!({})` gives a refusal
as a value; `endpoint.with_query(query)` adds a query). Both go through `Host.fetch!`:

- In the browser, the runtime's `fetchFor` asks the server (`accept: application/json`). Until the
  answer is in, the read waits ([Waiting](#waiting-reads-that-arent-in-yet)). An answer that isn't
  200 fails the reader, and the nearest `<Errored>` shows why.
- A computation's answers are kept by method, URL and body, so a run again reads them without
  asking. The answers a run didn't ask for are dropped.
- While hydrating, a read the page's answers script has is answered from it.
- Every computation that read a GET is remembered (`readers`), for revalidation after a
  submission (below).

Under a base (`Runtime.load(source, { base: "/rocx/" })`), a URL Roc gives that begins with `/` (an
endpoint's read, a fetch, a stream) is asked for under the base, and `Router.location!` takes the
base off the page's path. So the browser sees `/rocx/syntax` as the server sees `/syntax`.

### Forms and submissions

The route table rocx build writes (`Router.app!`, D-040) lists the paths of the app's endpoints
that take a POST (`posts`: each `+server.roc` with a `post!`, `/lists/[id]` matching any one
segment). `use_submission!(endpoint)` (or `use_submissions!`) registers the endpoint's URL with the
runtime too, by its path without the site's base, for as long as its component is there. Once the
app is told (or something registers), the runtime listens for `submit` on the page, once. It sends
a form with `fetch` when the form (D-095):

- posts (`method="post"`) to one of the app's endpoints, or to a registered URL, on this site
  under its base, and isn't `text/plain`;
- goes into this tab (no `target`, or `_self`);
- wasn't prevented by a handler (an `on:submit` handler prevents it).

So whether a form goes with `fetch` doesn't depend on whether a component reads its submissions,
but how it goes does (D-118). One a component reads (`use_submission!`, `use_submissions!`,
`use_action!` of its endpoint) goes as the runtime's, for its result or refusal, as below. One nothing
reads goes as the browser would post it (`accept: text/html`, no `x-rocx-submission`), with
`x-rocx-in-place: 1`: the endpoint answers it as a plain form (its result or refusal flashed back to
the page it came from, or its own redirect), the server gives the runtime that redirect, and the
runtime follows it in place. So the page shows what a plain post would show (a refusal the page
reads from the flash among it), and only the page changes: the same page again is made anew from
its document. A submission is kept under its endpoint's path (its query is fields,
`with_fields`'). A refusal, or no answer, of a runtime's submission that no component asks for
shows nothing on the page, so the console says so (`unread`), in every build. Any other form is the browser's: another site's, a path no endpoint
has a `post!` for (a `+server.roc` that answers with `respond!`, such as the one that calls
packages/auth's `Auth.sign_out_route!` at `/auth/sign-out`), or one posted before the runtime is
there.

It sends the fields URL-encoded, with `accept: application/json` and `x-rocx-submission: 1`. A form
with files (`enctype="multipart/form-data"`, D-054) goes as the browser's `FormData`; its input is
its fields URL-encoded, a file's field being the file's name. A form whose URL is a known
endpoint's with fields after it (`Endpoint.with_fields(endpoint, { id })`, Solid Router's
`action.with`: `/todos/toggle?id=7`) belongs to that endpoint. The URL's fields come first in its
input, as the server reads them, with or without JavaScript.

The submissions to each URL are a list that computations read (`Host.submission!`, the latest;
`Host.submissions!`, all). Each is pending, then has the answer's status and body (status 0, and
why, when there was no answer). Then:

- `x-rocx-redirect` (an endpoint's own redirect, which `Endpoint.respond!` gives the runtime as a
  200), or a redirect that `fetch` followed, sends the browser there, in place when it is one of
  the app's pages. What the navigation keeps (a layout the two pages share) then reads again what it
  read (D-117), as a result's page does: every read, or those the answer names
  (`Router.revalidate!`). So a form that signs someone in, switches the org they act in, or adds
  what a layout lists, shows it in the layout too, whether its endpoint is a `post!` or a
  `respond!`.
- `clear!` forgets the latest: there is none until the next, nor the flash.
- With no submission in the browser, `Submission` reads the flash.

A form's fields are read by the endpoint's body type (D-038, `FormBody`), in the browser as on the
server. `Endpoint.remote` makes the reader and `Endpoint.form_of` gives it, and it goes with the
submissions `use_submission!` and `use_submissions!` make. So `input!` and `pending_inputs!` of a
form the runtime sent are the arg the endpoint reads. An endpoint whose body is checked by rules
(`post_body = Signup.form`, `Endpoint.checked`, D-093) reads them with those rules here too: a
submission that doesn't pass them has no input (`Err(NoInput)`; `pending_inputs!` leaves it out),
as the server refuses it (422, the issues as JSON).

### Actions and optimistic values (D-030)

`use_action!(endpoint)` gives a function a handler calls with the endpoint's arg (`Host.submit!`).
The call is queued with the handler's writes, so a handler that waits and runs again sends it once.
It is sent as `Endpoint.send!` sends it (JSON, with `x-rocx-submission: 1`), as a new submission in
the endpoint's list. Nothing waits for it.

`use_submissions!(endpoint)` reads that list: `all!` (records with `id`, `pending`, `input`,
`result`, `error`), `pending!`, `pending_inputs!` (what those still on their way sent, parsed as the
endpoint reads it) and `clear!(id)`. An **optimistic value** is a memo of the server's data with
the inputs on their way applied:

```roc
create_memo!(|| moves.pending_inputs!().fold(board.read!(), moved))
```

How a submission ends:

- **Answered 200.** It isn't done at once. First the runtime reads the page's reads again
  (`revalidate`): every computation that read a GET has its answers cleared and runs again,
  showing its last value meanwhile (`is_pending!` is true for those memos). If the answer names
  what to read again in `x-rocx-revalidate` (its handler's `Router.revalidate!(keys)`, Solid
  Router's revalidate keys), only the reads whose URL is a key, or begins with a key followed by
  `/` or `?`, run again; `[]` means none, and the submission is done at once.
- Then it is marked done in the run of the last read to get its answer (or fail, or go). So what
  reads both sees the server's new data and the submission's end in one flush, and the optimistic
  value gives way with no frame of the old data.
- **Refused** (any other status, or no answer). It is done at once: its input isn't applied any
  more, the value is the server's again, and the refusal is in `error`.

Several may be on their way at once, each answered on its own. An input still on its way is applied
to the data read again, so applying one should be idempotent (set a card's day, rather than add
one more). `retry!` (Solid's) sends one again, by its id or the latest, with what it sent: the
same submission, pending again. In a handler, `Router.revalidate!(keys)` reads those reads again
itself.

An action whose arg has a top-level field holding the URL of a file the page has (`fileOf(url)`:
one that `on:drop.files`, `on:paste.files` or `on:change.files` gave), or a list of them, is sent
as a form with files. Each file is a part named after its field; the other fields go as a form's.
Its input stays the JSON, so a pending input's file is its URL, which an `<img>` can show while it
is on its way.

On the server there are no submissions: `all!` is the flash or nothing, and nothing is applied,
so the page hydrates as rendered. The contract (`Generated/Api`, D-037) types the submissions in
both copies of the app: `use_submissions!(Api.post_move({}))` is a `Submissions(Move, Str)`.

### `create_optimistic!` (D-054)

`create_optimistic!` is Solid 2.0's `createOptimistic`: a signal whose value is a memo's
(`|| board.read!()`) until a handler writes it.

- The write is held by a **transition** the runtime opens as the handler's writes apply. The
  transition stays open for the rest of that task, so submissions sent meanwhile join it (the
  handler's actions, and the form its `submit` sends).
- When they are all done (a result after its reads are read again; a refusal at once), the
  transition's writes are undone in that same flush. The server's data takes the value's place with
  no frame of the old. With no submission sent, the write is undone at once.
- With several held, the latest still held shows.

Use the D-030 memo over `pending_inputs!` for many submissions on their way at once, each applied
to the server's latest data. Use `create_optimistic!` for a value a handler knows.

### The flash

A plain form's post (no runtime) comes back as a redirect with a **flash**: what was typed, and
the result or the refusal (server/README.md, "Plain forms and the flash").

- On the server, `Server.flash!` takes the flash from the server's memory, by the id in the
  `rocx-flash` cookie. The host notes what the page read (`Host.flash!`), leaving out the fields
  the page has as `<input type="password">`.
- The page carries it in `<script type="application/json" class="rocx-flash">`, before the
  answers. Hydrating reads it and takes it out, so the browser's first render is the server's.
- Each platform has its own `FlashStore`, which `Server` keeps and reads flashes through.
  `renderToString` (the tests') reads the flash from the cookie itself.

### Channels (D-020)

```roc
create_effect!(|| org!(), |org| Endpoint.subscribe!(Api.channel_org_org_news({ org }), heard!))
```

`Endpoint.subscribe!` subscribes to a route's `channel!` (server/README.md, "Channels") until the
effect runs again or its component goes. Subscribing from a handler fails, since nothing would
end it. `heard!` is given, one at a time and in order (the next once its handler is done, waiting
or not):

- `Resync`: read your data again. Sent on each connect and reconnect, when the server saw the
  subscriber fall behind, on `Endpoint.resync!`, and in place of a message it can't read as the
  channel's `message` type;
- `Message(message)`;
- `Refused(status, why)` or `Ended(why)`.

The runtime's hub (`Hub` in `runtime.js`) keeps every subscription in the tab on **one stream**,
`GET /rocx/live?tab=…&c=<url>…`. Two subscribers to one channel share it.

- The stream says its id first (`event: hello`).
- When the set of channels changes, once the render that changed it is done, the hub tells the
  stream what it subscribes to now and what it dropped, in one post naming the stream (D-057).
  The stream stays open, and the route's `on_close!` hears `Dropped`. A change made before the
  stream said hello is told once it has. With nothing left to subscribe to, the hub tells the
  stream, then closes it.
- A stream that never says hello (an older server), or a change refused because the stream has
  gone, is opened again with the set as it is.
- When the stream drops, the hub opens it again after 0.5 s, doubling each time up to 30 s (plus up
  to a quarter more, at random), and starting over once a stream has stayed up 10 s.
- A new subscriber to a channel the stream already has asks the server for its resync.
- `Endpoint.say!(channel, said)`, from a handler, goes with the frame's other sayings in one
  `POST /rocx/live/send`. A refusal is a warning in the console.
- The tab's id is random and kept in `sessionStorage` (a reload keeps it; a duplicated tab copies
  it). A tab has one stream: the server ends a tab's old stream when a new one comes, telling it
  `event: replaced`. A page that hears that is a duplicated tab, and takes an id of its own before
  it connects again.
- Where no server answers (a static copy: a 404, a 405, or no stream), every subscriber hears
  `Refused(404, …)`, and the hub asks for nothing more.

On the server, nothing is subscribed to. `Endpoint.publish!` is the server's: in the browser it
fails.

### JSON across the boundary

What crosses as JSON (an endpoint's body, result and events, `Browser.call!`'s argument) is
written with `Json.to_str_try`, so an `F64` goes as a number. A value JSON can't write (NaN, an
infinity) fails the call; an endpoint's result is then a 500 that says so. The where clauses read
`Json.Encodable(e)`. A `Try` goes as its tag: `{"Ok":5}`, `{"Err":"Empty"}` (D-054). Two shapes
are JSON's own instead: `Try(a, [Null])` is a value that may be `null`, and a record field's
`Try(a, [Missing])` is a field that may be left out.

## Rendering on the server, and hydrating

### Rendering as a server would

The real server render is native (`server/host/src/signals.rs`). The runtime renders the same way
in Node (`renderToString`), for the tests and for the site's byte-for-byte check of the two. On a
server, nothing waits:

- every hole runs once; no effect or timer runs, and no cleanup is kept;
- an endpoint's read is answered from the answers given (`renderToString({ answers })`, a page's
  answers script) and noted under `GET <url>`; one not there fails with 599;
- the HTML has a pair of comments around each computed hole, part and list, named by its kind,
  with the answers in a script beside it. The markers are the same, byte for byte, in
  `signals.rs`: `<!--x-->…<!--/x-->` around a text hole, `<!--html-->` a markup hole,
  `<!--list-->`, `<!--show-->` a part, `<!--for-->` with a `<!--row-->` per row or a
  `<!--fallback-->`, `<!--loading-->`, `<!--errored-->` (`<!--errored:failed-->` once it has
  failed), and `<!--app-->` around an app that isn't a whole document.

`renderToString({ path, headers, answers, regions, scripts })` returns `{ html, answers }`. Markup
with `<html>` at its top is rendered as the server platform answers a page (`Runtime.documentOf`):

1. `<!doctype html>` first, unless the markup has one;
2. the `<Title>`'s `<title data-rocx>` and the `<Meta>`/`<Link>`/`<Style>` elements in `<head>`
   (below);
3. just before `</body>`: the flash the page read (if it did), the answers script, the plugins'
   scripts (`scripts`, by URL) and the bootstrap, with the build's id (`data-build`).

Any other markup is an app's range, `<!--app-->…<!--/app-->`, for `hydrate(container)`.
`mount(container)` builds an app from nothing (the tests' profile app).

### Hydrating

Hydrating, the runtime reads the answers, walks the server's nodes beside the markup Roc made, and
binds each computation to its own node (`adopt`). Nothing is asked again or made again. A read
whose answer the page carries is answered from it. With `{ strict: true }` (the tests'),
hydrating that asks the server for anything the page didn't carry throws.

**A whole document** (`hydrateDocument(document)`): the root's markup is walked beside
`document.childNodes`. There is no `<!--app-->` range.

- The doctype takes the DocumentType node, and `<html>` takes `documentElement`. Where the markup
  doesn't take the DocumentType (the host writes a doctype when the markup begins without one, or
  with a hole's comment, as an `<Errored>` around the document does), it is passed over.
- The walk passes over the host's elements, marked `data-rocx` (the bootstrap, the dev reload
  script). It also passes over the whitespace the HTML parser drops before `<html>` and `<head>`
  or moves into `<body>` from after `</body>`, and over the empty `<head>` it makes for a document
  that has none.
- It passes over an element it doesn't expect straight in `<html>`, `<head>` or `<body>`, where a
  browser extension puts its own (a password manager's popup, a grammar checker's, a dark theme's
  style) before the runtime hydrates (D-112). The element stays where it is.
- A page that doesn't match otherwise (the parser repaired the markup; an extension's node inside
  the app's own elements) gets a warning, and `<body>`'s children are rendered again from the same
  answers. What isn't the app's stays: the host's elements, the elements hydrating passed over,
  and any element after the host's last (the bootstrap, the last the server writes). `<head>` is
  left alone, since rendering it again would run its scripts again and flash its styles; its
  computations are bound to it if it matches, or to an unseen copy if not.
- A mismatch says what it found and where: `expected <circle>, found <rect> in body > svg.dot`.
  The warning gives the console the node itself, to inspect, and the document gets a
  `rocx:mismatch` event (`detail: { message, node }`) for an app's error reporting
  (packages/posthog's page script sends it).
- With `{ strict: true }` a mismatch throws instead, and nothing is passed over. `start.js` passes it
  when the page set `window.rocxStrict = true` before it ran (the tests do), or when the browser's
  `localStorage` has `rocx:strict` set to `"1"`: `localStorage.setItem("rocx:strict", "1")` in
  the console, then a reload, to look into a page in one's own browser.

**RCDATA.** Inside `<title>` and `<textarea>` the HTML parser reads everything as text, comments
too. So the server writes their holes without comments. Hydrating builds the element's text anew
from the markup (its holes bound to the text nodes it makes, not patched), and checks the server's
text against it.

### `<NoHydration>`

`<NoHydration>` (Solid's name; `Html.no_hydration`) is markup only the server renders: prose,
listings, anything that never changes in the browser.

- **On the server**, what is inside renders as anywhere else, every hole run once, but as static
  markup between `<!--nohydration-->` and `<!--/nohydration-->`, with no comments of its own
  inside. (One region inside another is just part of it.) An endpoint read inside isn't noted in
  the answers, since the browser never reads it.
- **In the browser's copy** of a `.rocx` file (`rocx build --client`), it has no children. An
  import only those children used is dropped, as is one only a route file's `middleware` used:
  none of it is in the wasm. A name only they used is rewritten where it is bound (a record
  pattern's field as `params: _`, a parameter or a local as `_lang`), so the browser's build has
  no warning of it (D-044). What is left is a placeholder.
- **Hydrating** passes over the server's nodes between the markers, and never builds, adopts or
  patches them. A `<body>` rendered again after a mismatch keeps the server's regions, in order.
  One the browser builds where the server rendered none (an `if` switching to a part that has one)
  is empty, with a warning.
- **What may go inside:** anything the server can render. Elements, text, holes (computed ones run
  once), pure and `view!` components (run once, never hydrated, as Solid's), parts, rows,
  `<Loading>`, `<Errored>` and endpoint reads all render once. Nothing inside runs in the
  browser, so rocx refuses a handler (`on:…`), a `key` or a transition written inside, at its
  line. The server refuses to render a handler a component put there: a 500 naming the element,
  rather than a dead button. A `<Title>` inside sets the page's title on the server only.
- **`renderToString({ answers, regions })`** renders the browser's build against a page the server
  rendered, for the byte-for-byte check. `answers` are the page's answers script: each read is
  answered from it and recorded as the page has it (one the server didn't make fails, 599).
  `regions` are what the page has inside each `<NoHydration>`, in order
  (`Runtime.regionsOf(html)`), written as they are there. Outside the regions the output matches
  byte for byte. Without `regions`, a placeholder renders empty.
- **Static exports and navigation.** The static export (GitHub Pages) GETs each page from the
  native server, regions and all. A navigation in place has no copy of a region in the wasm
  either: it fetches the page's document and takes its regions from there (`keepingRegions` over
  the fetched `<body>`).

### The document's title: `<Title>`

`<Title>` (`Title.view!`, `import pf.Title`) works as @solidjs/meta's does: the last `<Title>`
rendered that is still there is the title, wherever it is.

- It is `Html.document_title(children)`: a text hole of its own that renders nothing
  (`<!--x--><!--/x-->`). Its run computes the children's text (their holes run, so it tracks what
  they read) and tells the runtime (`Host.title!`).
- In the browser, the runtime keeps each `<Title>`'s text by its hole's computation, in the order
  of their first runs (a page's after its layouts'; one shown again by an `if`'s part is new, so
  last). Each is taken back with that computation's cleanups.
- After a flush in which one changed, the latest's text goes in a `<title data-rocx>` first in
  `<head>` (made if the server didn't), which `document.title` reads. With none left, that element
  goes and the root layout's own `<title>` stands.
- Rendering as a server would, the last title told is the page's: `Runtime.documentOf` (and the
  native host's `titled` in `signals.rs`) puts `<title data-rocx>…</title>` before the `<head>`'s
  first `<title>`, or before `</head>`.

Why a separate element rather than the layout's own `<title>`: writing the page's title into it
would make the layout's `<head>` differ from what the layout renders, and strict hydration would
refuse it. An element the host owns (`data-rocx`, which hydration passes over, as it does the
bootstrap) keeps the layout's markup exactly as rendered, needs no context or provider, and leaves
the layout's `<title>` as the fallback, holes and all. The cost: with a `<Title>`, a page's
`<head>` has two `<title>`s; the first is the one browsers and crawlers use.

### The head's other elements: `<Meta>`, `<Link>`, `<Style>` (D-054)

These are @solidjs/meta's, written as rocx's own tags, as `<Document>` is (no import; a module of
that name is a component instead). They are written as a `<meta>`, `<link>` or `<style>` would
be, holes and all; `<Style>`'s CSS is static, as written.

- Each is `Html.document_head(element)`: a hole that renders nothing where it is. Its run computes
  the element's attributes and tells the runtime its markup, with `data-rocx` on it, and its key
  (`Host.head!`). A `<Meta>`'s key is its `name` (or `property`), `http-equiv`, `charset` or
  `itemprop`, with its `media`. `<Link>` and `<Style>` have none.
- They go in `<head>` in the order of their first runs (a layout's before its page's). A later one
  with an earlier one's key takes its place (a page's description over its layout's), while their
  holes are there.
- Rendering as a server would, they go before `</head>`, after the title (`Runtime.headed`,
  `signals.rs`'s `headed`).
- In the browser, after a flush in which one changed, the head's `[data-rocx]` elements (except
  `<title>`) are made to match: one equal to what is there is kept (`isEqualNode`; hydrating, the
  server's, so a stylesheet isn't loaded again), one that differs is replaced, an extra one is
  added at the end, a missing one is removed.
- The plugins' scripts go before `</body>`, so nothing else of the host's is in `<head>`. A
  `<meta>` written in the layout's own `<head>` isn't one of these: give a default with a
  `<Meta>` in the layout, and a page's takes its place.

## Navigation in place (D-040)

A click on a link to another page of the app renders that page without a load: the runtime
fetches the page's document, as the server answers it, and renders it from the answers and
regions in it. `spike/client-nav/DESIGN.md` has the design and its phases (§ numbers below are its
sections).

### Setting up

`Generated/Root` calls `Router.app!` first, with the build's id, whether it is a dev build, and the
route table (JSON: each page's path and its levels' code, root layout first; §18's ids, kept for
wasm splitting later; and `posts`, the paths of the endpoints that take a POST, for
[forms](#forms-and-submissions), D-095). The build's id is also on every page's bootstrap, as
`data-build`.

As it hydrates the document, the runtime (`listenForNavigation`):

- notes where the page is (`committed`). `Router.location!` reads it as a source, so what read it
  runs again when a navigation commits another location;
- gives the history entry a key and an index (`{ rocx: { key, index } }` in its state);
- takes over scrolling (`scrollRestoration` manual, each entry's scroll kept in `sessionStorage`, a
  reload's put back);
- listens on the document for clicks, `pointerover`/`pointerout`, keyboard focus, `touchstart` and
  `submit`, and on the window for `popstate` and `pagehide`.

### Which clicks navigate in place

A click navigates in place (`clicked`, `linkOf`) when all of these hold:

- the main button, with no modifier key, and nothing prevented it;
- on an `<a>` (an SVG one too) with an `href` and no `download`;
- no `rel` containing `external`, and no `target` other than `_self`;
- to this origin, under the base, at a path the route table has a page for (`routeOf`);
- not just to another hash on this page.

`<html data-rocx-navigation="off">` turns it off. `"explicit"` limits it to links with
`data-rocx-link`. A GET form to one of the app's pages (`gotForm`) is a navigation to its URL with
its fields as the query, by a link's rules.

### Links say where the page is (D-086)

There is no `<A>`: every `<a>` whose `href` is one of the app's own paths (`/…`, not `//…`), and
whose markup writes no `aria-current` of its own (`ownsCurrent`), is marked (`linkMark`):

- `aria-current="page"` where the page is: its path, and its query too if the link has one;
- `aria-current="true"` at a path the page is under (`/lists` while at `/lists/7`; never `/`);
- nothing otherwise. A relative `href` or another origin's is never marked.

The server writes the mark last on the element (`current` in `signals.rs`; `renderToString` the
same). The runtime marks a link it makes (`element`, a template's copy) or adopts, again when its
`href` changes, and every link it keeps (`links`) when a navigation in place commits a location
(`markLinks`). Styling is CSS: `a[aria-current="page"]` for a link to the page alone,
`a[aria-current]` for one above it too.

### What a navigation does

`navigate(url, { replace, scroll, pop })` is what a click, a handler's `navigate!` (queued with its
writes) and a submission's redirect (unless the visitor navigated since it was sent) call:

1. **Ask to leave** (`mayLeave`), unless forced: the `use_before_leave!` listeners (below).
2. **The query in place.** A navigation to the page's own path with another query is made in place
   (`inPlace`) when no level read the location once and no `<Errored>` on the page shows its
   fallback. (Otherwise those would be made anew from the page's document, so it is fetched.) No
   document is fetched: the address is pushed (or replaced; back and forward leave it), the
   location is committed, and what read it runs again in one flush. A read whose URL changed asks
   its endpoint, showing its last value meanwhile. The scroll goes as told; the focus stays.
3. **Fetch.** `is_routing!` turns true. `pageFor(url)` fetches the document (`accept: text/html`,
   `x-rocx-navigate: 1`) and reaches the levels' code (`codeOf`; at once, while one wasm holds
   every page). The last 8 pages are cached, and one fetched under 10 s ago is used again
   (`Runtime.CACHE`, `Runtime.FRESH`). A submission's result, or its redirect, empties the cache. A newer
   navigation aborts this one's fetch if it was its own and for another page.
4. **Check.** A redirect's address is where the navigation ends (one that only adds a trailing
   slash is the link's). The runtime loads the URL the ordinary way instead (`location.assign`, or
   `reload` for back and forward) when the answer isn't HTML, has no bootstrap or another build's
   (`appDocument`), or the fetch failed (offline, a redirect to another site).
5. **Commit** (`commit`): the document's answers and flash seeded; the address pushed (or replaced,
   or, for back and forward, left); the location committed and the root run again, in one flush.
   The document is rendered anew (`settleDocument` while `arriving`):
   - `<head>` is reconciled with the document's (`reconcileHead`): a node equal to one there is
     kept in place, others are imported, a script is made inert, a stylesheet that goes is removed
     once the new ones have loaded, and the host's elements are left alone;
   - `<body>` is made anew, with the document's regions;
   - `<html>`'s and `<body>`'s attributes the app writes are set to the document's
     (`attributesFrom`). One a page script set (site.js's `data-hydrated`) stays.

   Nothing is asked of the server meanwhile (strictly, asking throws), and the effects' applies
   wait (`holdingEffects`).
6. **After the flush** (`afterNavigate`): the page's `<NoHydration>` regions are matched one for one
   with the document's (`regionRanges`). One that differs gets the document's content (a script
   inert), so a kept level's region follows the page and a new level's (made empty while
   `arriving`) is filled. The finished submissions of endpoints no component on the page asks for
   are forgotten (`forgetSubmissions`).
7. **Settle.** The scroll (the top, the hash's element, or the entry's kept scroll); the focus (an
   `autofocus` element, the hash's target, or the start of `<body>`, given a `tabindex` it later
   gives back); a live region of the host's announces the title; `rocx:navigated` is dispatched
   (`{ url, ms }`; `rocx:navigate` was dispatched as it started); then the effects run.

**View Transitions.** With `<html data-rocx-transitions>`, where `document.startViewTransition`
exists and reduced motion isn't asked for (`transitionsWanted`), the commit, `afterNavigate` and
the scroll run in the transition's update; the focus, the announcement and `rocx:navigated` come
once it is done.

### Kept levels (phase 2)

`Generated/Root` renders the root layout (the root computation: the document) around the levels
below it. Each layout and the page is a **level**: a keyed part (`Html.switched`, the
`{"t":"show"}` node), keyed by its file and its own params, on a memo of the location. A
navigation makes anew the levels whose key changed and keeps the rest. The root runs again only
when the root layout read the location once, or the same page is navigated to again
(`remakeRoot`).

A read of the location that won't follow it (`readOnce`: in a component's body, or in a part made
once; not inside `untrack!`) notes the level it is in, or the root. A navigation makes a noted
level anew as if its key had changed (`remakeLevels`). A dev build says which in the console, and
the observer hears `remade`. A boundary showing its fallback before the navigation is tried again
once the levels are there, with the document's answers.

### Prefetch (phase 3)

What a page needs is one cache entry with one age (`pageFor`, §18: its document and its levels'
code, which wasm splitting will fill), so a navigation and a prefetch share it. `prefetch(url)`
asks with `x-rocx-navigate: preload` and a low priority, quietly: one that fails, or is of another
build, is dropped. A link (by `linkOf`, the click's own rules) is prefetched when:

- the pointer rests on it for `Runtime.REST` ms (65; `hovered`, `unhovered`);
- the keyboard focuses it (`:focus-visible`; a click focuses its link too);
- it is touched;
- it comes into sight, where `data-rocx-preload="viewport"` is on it or above it (`watchSight`: an
  `IntersectionObserver`, plus a `MutationObserver` for links added later, only while the page has
  such a link).

`preloadOf` reads the nearest `data-rocx-preload`; `off` means never.

### Leaving: `use_before_leave!`

`use_before_leave!` is Solid Router's `useBeforeLeave`.

- `js_before_leave` makes the listener a computation of kind `leave`, owned by what is running (a
  component's run: it is disposed with it, and `leaveListeners` forgets it). Its box is kept by id.
- `navigate` asks first (`mayLeave`) unless the navigation is forced (a retry's) or already asked
  (back and forward's). Each listener runs in the order they came, as a handler with
  `again: false`: one that waits for the server isn't run again, and the navigation is decided at
  once (a dev build warns). Its event is the leave, as lines (`leaveEvent`): its id, `to` as
  `Router.location!` writes it, the path and query it leaves, `replace`, `scroll`, `delta`, and
  whether one before stopped it.
- `js_leave_prevent(id)` stops the leave being asked (`leaveAsked`).
- The leaves asked lately are kept (`Runtime.LEAVES`, 64, by id) for
  `js_leave_retry(id, force)`, a write applied when its handler is done (`retryLeave`, in a
  microtask, after the navigation it stopped has been decided): a navigation to its URL with its
  options and `force`.

**Back and forward.** Each history entry's state is `{ rocx: { key, index } }`, the index one more
for each entry pushed (and for the browser's own entry for a hash). So `popped` knows how far it
went (`delta`). The address has changed already, so a leave stopped there has the browser go back
the other way (`history.go(-delta)`; the `popstate` that makes, `restoring`, is passed over), as
Solid Router does; the page never changed. Its retry goes `history.go(delta)` again with the
listeners passed over (`forcing`) while the page is on the entry it was left from, and otherwise
navigates to its URL. An entry the runtime didn't index isn't asked about.

**A load** (leaving the site, a reload, closing the tab) can't be held. So each listener is asked
ahead of time (`probeLeave`): the `leave` computation runs as a handler with its own tracking, so
it runs again when what it read changes. Its event's id is 0 and `to` is `""`; its writes are
dropped, and a memo or timer it made is let go of. `guardUnload` listens for `beforeunload` only
while some listener would stop a load (`prevents`), and cancels the event, so the browser asks in
its own words. (A page with such a listener may be kept out of the back-forward cache.) A load the
runtime starts after the listeners let a navigation go (`load`'s `asked`) isn't asked again for
`Runtime.ASKED` ms.

**Under a base**, the URLs the runtime writes into the page (an `href`, `src` or `action` it builds
or patches, `written`) get the base, as the static export gives the server's.

## Events and the DOM

### Event handlers and keys

- `on:click` runs a handler. `.value`, `.checked` and `.key` give it what the event says.
- A key's name (`on:keydown.ArrowUp`) runs it for that key only, with no modifier key held, and
  prevents the key's default. So does a combination (`on:keydown.Shift+Enter`, `Mod+K`,
  `Ctrl+Alt+Delete`), with exactly those modifier keys held, so Shift+Enter isn't Enter
  (`keyCombo`). `Mod` is ⌘ on macOS and iOS, Ctrl elsewhere. A letter or digit matches in either
  case, and by its place on the keyboard (`event.code`) when the layout types something else there
  (Alt+K on macOS types ˚). Nothing matches while an input method is composing.
- `.keys` (`Html.on_keys`) gives the handler an `Html.Keys` record: `key`, `shift`, `ctrl`, `alt`,
  `meta`, `mod`.
- `.prevent` prevents the default first (a link's click taken over).
- `on:frame.ms` runs every animation frame while its element is on the page, given the
  milliseconds since the last (at most 100).
- `on:viewport` (`Html.on_viewport`) gives an `Html.Viewport` (`top`, `left`: how far it is
  scrolled; `width`, `height`: what shows inside its borders; whole pixels): once the element is on
  the page, then each time it scrolls or changes size, at most once an animation frame and only
  when one of the four changed (a scroll listener and a `ResizeObserver`, taken off with the
  owner's cleanups). The server measures nothing, so render a first view both agree on, and let
  the measure replace it.
- `on:pointermove.point` (`Html.on_point`) gives an `Html.Point`: shares of the element's box (`x`,
  `y`, 0 to 1, to thousandths). A move (`pointermove`, `mousemove`, `touchmove`) runs it at most
  once an animation frame, with the latest place. On `<Document>` and `<Window>`, shares of the
  viewport.
- `on:visibilitychange.visible` (`Html.on_visible`) gives whether the page shows
  (`document.visibilityState` isn't `hidden`).

### `<Document>` and `<Window>`

`<Document on:keydown.Mod+K={open!} />` puts handlers on the whole document; `<Window on:resize={…}
/>` on the window. They are written as an element's are, any but `on:frame.ms`. rocx writes
`Html.on_document([…])` (`{"t":"listen","to":"document"}`), unless the file has a module of that
name, which is then a component. It renders nothing, on the server or in the browser, and
hydrating takes no node for it. The runtime adds its listeners where it is built or adopted
(`listenOn`), with an element's handler code (`listener`), and takes them off with its owner's
cleanups (when it runs again, or goes: an `if` hiding it), as solid-primitives'
`makeEventListener` does. Svelte's `<svelte:document>` and `<svelte:window>` are the same idea.

### The page's own functions: `Browser.call!`

`Browser.call!(name, arg)` calls a JavaScript function the page gave the runtime:
`Runtime.load(source, { effects: { vibrate(arg) {…} } })`, or `window.rocxEffects` for a page that
`start.js` wakes up.

- The call is queued with the handler's writes, so a handler that waits for the server and runs
  again calls once.
- It is made once the flush after the handler has patched the page, with the argument parsed from
  JSON and `{ under }` (`under(url)`: a URL that begins with `/`, put under the site's base).
- An effect's apply is a handler too: what it calls runs at the end of the flush it is part of,
  once the page shows what it wrote.
- A function that isn't there, or throws, is reported on the console. A call while computing (an
  effect's `compute` among it) fails.
- A plugin's script (D-050: every page the server renders loads it before `start.js`) registers
  its functions on `window.rocxEffects`, named `<plugin>.<effect>` (`audio.play`).
- Names beginning with `rocx:` are the runtime's own. `rocx:focus` (`Browser.focus!(id)`) moves the
  keyboard's focus to the element with that id, once the page shows what the handler wrote; from
  an effect's apply, `on_settled!(|| Browser.focus!(…))` focuses a field as its part shows.

### Drag and drop (D-029)

Drag and drop are events too (`dragAndDrop`):

- An element with a drop handler is a drop target. Its dragenter's and dragover's default is
  prevented, its `dropEffect` is a move (unless the drag allows only a copy or a link), and its
  drop's default is prevented (a dropped link or file doesn't open). `on:drop.value` is the dropped
  text (`text/plain`).
- An element's dragenter and dragleave handlers run when a drag comes over it from outside and
  leaves it for outside, as mouseenter and mouseleave do (the runtime counts the browser's enters
  and leaves). Dragleave's also runs when a drop or the drag's end (one page listener) leaves it.
- An element with a dragstart handler puts data on its drag (`application/x-rocx`), which Firefox
  needs to start one.
- What is dragged is the app's business: a signal its handlers set. A source removed by the drop
  (its row moved elsewhere) gets no dragend handler run, since its box went with its row. Clear
  what dragstart set in the drop handler too.

### Drags by touch and pen (D-055)

Many browsers start no drag from a touch, so the runtime makes one (`pointerDown`,
`pointerDragStart`; `POINTER_DRAG` holds the numbers):

- A pointer that isn't a mouse, pressed on an element that starts drags (a dragstart handler,
  `drag:data` or `drag:image`; and `draggable`, as the browser asks), held still a quarter second
  (it may move 8 px; a swipe scrolls and a tap clicks), starts a drag.
- The drag is made of the browser's own events, so D-029's drop targets and the app's handlers
  take it as one: dragstart on the element (which may call it off), then each animation frame
  drag, dragenter on what `elementFromPoint` finds under the finger (and dragleave on the one it
  left), dragover; on the lift, drop where a dragover's default was prevented (else dragleave), and
  dragend.
- They are `DragEvent`s carrying one `DataTransfer` (its `effectAllowed` and `dropEffect` the
  runtime's, since Chromium's made-up one ignores both; one of the runtime's own where the browser
  can't make one), bubbling and untrusted.
- A copy of the element (or of `drag:image`'s) follows the finger in the top layer, held where the
  element was taken. Near the edge of a box that scrolls, or of the page, it scrolls, faster
  nearer the edge.
- While it is held and drags, the element has no long-press callout and selects no text. While it
  drags, the touch scrolls nothing (a non-passive `touchmove` on the element, there before the
  touch starts), the browser's own drag is called off if a long press started one, and the lift's
  click doesn't come.

A mouse keeps the browser's own drag, which carries data and files to other windows.

### What a drag carries and shows (D-055)

- `drag:data={[(type, value), …]}` (`Html.drag_data`, or computed) is put on the drag as dragstart
  ends, each by its type. A drag with none still carries `application/x-rocx`.
- `drag:image={id}` (`Html.drag_image`) is what the drag shows: a copy of the element with that id
  (hidden or not, its ids taken off, `data-rocx-drag-image` on it for the app's CSS), put just
  after it so what styles it there styles the copy, held at the point the element was taken. The
  browser's drag uses `setDragImage`; the runtime's puts it under the finger.
- `on:drop.data` (`Html.on_data`) gives every piece a drop or a paste carries except its files
  (`Html.DragItem`: `type`, `value`).
- `on:drop.files`, `on:paste.files` and a file input's `on:change.files` (`Html.on_files`) give its
  files (`Html.File`: `name`, `type`, `size`, `url`). Each is read by a `blob:` URL the runtime
  keeps (`runtime.fileOf(url)`, which an action posting that URL sends as the file: D-054) until
  the element's owner goes, when it is revoked.

### Transitions

`transition`, `transition:in` and `transition:out` take a `Transition` (`Transition.roc`).

- A new row, or a new part of an `if` or `match`, plays its own elements' transitions in once the
  flush that made it is on the page. Nothing plays the first time a list or a part settles: those
  come with the page.
- A row whose key is gone, or a part switched away, stays where it was, inert and `aria-hidden`,
  its computations disposed at once, while its elements' transitions out play
  (`element.animate`, backwards, holding the hidden style). Then it is removed.
- Rows being put in order pass over the rows leaving. Rows inside a part that is leaving stay until
  it goes.
- With `prefers-reduced-motion: reduce`, nothing plays.

### Moves: `transition:move` (D-031)

An element with a move transition glides to its new place (FLIP):

- It is measured (`getBoundingClientRect`) before a flush first changes the page's structure (a
  row comes, goes or moves, a part switches, a hole's markup is made anew: `measure`), and after
  it (`glide`). One that moved plays the difference back with `translate`, at the transition's
  pace. One whose size changed also scales (`glideFrames`) from its old size about its own
  `transform-origin`, so it starts exactly in its old box. What is inside is scaled with it: a
  card gliding into a narrower column has its text squeezed for the glide, rather than laid out
  again each frame.
- An element with a key (`["k",…]`, or `["ko",…]` computed) that appears in the flush as one with
  the same key went (taken away, or on its way out) is that one, moved. It glides from the other's
  box, its transition in doesn't play, and the other, if leaving, goes at once.
- An element inside another that glides moves with it. A glide playing is stopped, and the next
  starts from where the element is seen.
- **Lifting.** One that glides out of a box that scrolls or clips (`overflow` other than `visible`,
  `contain: paint`) into another (a card into another column's scrolling list), where the clipping
  would hide where it was, is lifted for its glide (`lift`): fixed where it lands, above the page,
  a hidden stand-in of its size keeping its place. It stays where it is in the document, so its
  styles and handlers are its own, and is put back, its style as it was, when the glide ends or
  another starts. It is clipped as the boxes it leaves and lands in clip it (`clip-path`, from
  what showed of it where it was to what will show where it lands), so one whose new place is
  scrolled out of sight slides under its box's edge.
- Inside a box that makes fixed elements its own (a `transform`, a `filter`, `contain`, a
  container's box: `holdsFixed`), it is lifted into the top layer instead (a manual popover, its
  own look kept over the popover's), which no box holds or clips. Where the browser has no
  popovers, it is placed where it is seen to be, inside that box.
- A glide within one box, or one whose old place the box shows, isn't lifted. What lifting costs
  is a walk up from the element, each box's style read once a flush.

Hydrating and mounting measure nothing. With `prefers-reduced-motion: reduce`, nothing glides.
The server writes nothing for moves.

### Watching the runtime: `runtime.observer`

Set `runtime.observer` to an object with any of these methods, and the runtime calls them as it
works (`notify`). The docs' inspectors and the showcase's frame meter use it. Hydrating isn't a
patch.

| Kind | When |
| --- | --- |
| `seeded` | a read answered from the page's answers, not asked of the server |
| `fetch`, `fetched` | a request went out, and its answer came |
| `listen`, `heard`, `unlisten` | an event stream |
| `patch`, `row`, `show` | a node patched; a row made, moved or dropped; a part switched |
| `frame`, `effect`, `apply` | an element's `on:frame` handler ran; a call of the page's own function; an effect's apply |
| `submit`, `submitted`, `revalidate` | a submission sent and answered; a result reading the page's reads again |
| `glide` | an element moving |
| `subscribe`, `unsubscribe`, `connect`, `hello`, `replaced`, `dropped` | the channel hub |
| `navigate`, `navigated`, `transition`, `leave`, `remade` | navigation in place |
| `warn` | a dev build's read-made-once warning |

## The native engine (`native/`)

The same platform also runs on a phone (D-063's spike, opt-in with `rocx dev --android`).
`main.roc` builds the app as an `arm64musl` archive (Roc has no Android target; its static Linux
objects link as Android's), and `native/` links it with a Rust host:

- `native/core`: `web/platform`'s hosted functions done natively, and the reactive engine
  (`engine.rs`) ported from `runtime.js`, building a document of its own (`dom.rs`) instead of the
  DOM. After each flush it projects that document onto native views and sends what changed as one
  batch of ops (`native.rs`). Where the engine and `runtime.js` differ, the browser is right.
- `native/android`: the phone's half. Kotlin applies each batch of ops to Android views in one JNI
  call, and sends the views' events back. `native/android-dev` is the dev client, which loads the
  app's library at run time (`rocx dev --android`).
- `native/mac`: runs an app as a phone would, on the Mac, with a recording renderer in place of
  the phone's views, printing the screen after each step. No suite in `just test` runs the native
  engine yet.

The engine doesn't have everything yet: hydration (a phone mounts from nothing), transitions and
glides, drag and drop, `on:frame`, `on:viewport`, `<Document>`/`<Window>` handlers, `listen!` and
channels, `Browser.call!`'s native handlers, and keyed elements are missing (`engine.rs`'s header,
`spike/native-apps/`). A change to a hosted function in `Host.roc` needs its twin in
`native/core/src/hosted.rs`, and `just glue` regenerates the native host's ABI along with the
others.

## Tests

Both suites need the toolchain (`just setup`) and Chromium (`CHROME` to name one); a few tests
also need Gecko (Zen or Firefox). Without a browser its tests skip, said once on the console; in CI
(`CI` set), or with `ROCX_BROWSERS=required`, they fail instead (`browser.mjs`'s
`browsersRequired`). Before the tests run, `platform.test.mjs` builds what it needs:
the test app through rocx, the browser's copy of it, a dev build of one component, the host, and
each app's wasm.

### `test/platform.test.mjs`

The test app (`test/app`, in rocx) is built several ways: the profile from the dev backend and
optimized (`--opt=size`), mounted from nothing (`main.roc`); the others as each test needs. Each
`*_app.roc` is an app whose root is one of the `.rocx` files. Most tests render a page as the server would (from the answers a
scripted server gave), hydrate it strictly in Chromium, then click and type. What they cover, by
area:

- **Loading and failures** (`Profile.rocx`: five answers, one spinner, regions that fail on their
  own, a rename that waits for the server): what shows while answers come, what a click patches,
  failures and retries. `Upstream.rocx`: an `<Errored>`'s retry reads again the failed read a memo
  it shows reads.
- **Control flow and rows.** `Picks.rocx` (a `.map` by key and by position, an `if` and a
  `match`), rendered on the server and hydrated, the server's rows kept. `Nested.rocx`: a `.map`
  in a row and in a `match` arm. `Control.rocx` (D-070): an `if` with an `else`, a `match` on a
  `Try` and one on a mode's kind, and a one-row `.map` keyed by the value, each part with a counter
  of its own, rendered from four queries. An equal value keeps every part; a renamed card keeps the
  `if`'s and the `match`'s parts (the arm's name following) and makes the keyed row anew; a
  `match` changes part when another arm holds. `Rows.rocx` (D-071): a thousand rows; one changed
  item runs one row's holes (3 runs), every item changed runs every row's (2,001), with patches and
  allocations counted; a selector (D-083) runs only the rows a pick leaves and comes to; rows made
  once the page is up come from one skeleton, the same nodes `element` makes (D-084).
- **Names markup can't have** (`names_app.roc`, D-079): a tag that isn't a plain name, an inline
  handler, an attribute name that would end the tag and a `<script>` of data are never written,
  rendered, hydrated or built, each said once on the console, and what is around them works.
- **`<Repeat>` and `on:viewport`** (`Scroller.rocx`): ten thousand rows in a box, those that show
  rendered on the server, hydrated, then scrolled and made taller, the rows still in range kept.
- **Props** (`Props.rocx`, D-039): value props given in a hole, outside one, in an `if` and in a
  row, read every way a component may (in its body, once; in a pure lambda, by its hole; in an
  effect and a handler, as they run), an accessor, and props passed on with `{...rest}` (D-052).
  The component is kept with its signals, and only what reads the prop is patched.
- **Static holes and untracked reads** (`Untracked.rocx`, D-052): `untrack!` in a hole, a memo and a
  body, `latest!`, a component given constants beside one given what changes, written without
  comments and taken as text, strictly, and never patched. Built with `--dev` from a copy: the
  warning of a read in a body, once for two runs of its place.
- **Effects and timers.** `Effects.rocx`: an effect run after hydration and again after its
  cleanup (none on the server), a timer and a listen stopping with their component.
  `RenderEffects.rocx`: an effect, a render effect and an effect with an error handler, noting
  their applies. `Timers.rocx`: none started on the server; timers run as handlers, stop with
  their `clear!` and go with what started them; a handler reads the clock; a handler calls the
  page's own function once the page is patched, given `{ under }`, and one the page hasn't is
  reported.
- **Stores** (`Stores.rocx`, D-053): a filter, a count and a list of todos in one store, each part a
  hole of its own, a `.map` of the list, two writes in one handler, a handler reading it,
  `Store.of` over a memo, and a grid of four hundred selections of one store: which holes each
  write patches, how many selections it runs, and nothing left allocated. A signal's `update!`s
  (D-094): two in one handler adding two, a read after them the value before, a write then an
  update.
- **Server reads.** `Echo.rocx`: a GET read with what is typed, rendered from the server's answer,
  hydrated without asking again, and asked again as one types. `Reads.rocx`: a GET read with the
  page's query, hydrated strictly, read again when its events say so. `Pending.rocx`:
  `is_pending!` false on the first load, true while a refresh is on its way, false on the server.
- **Documents** (`Document.rocx`; inside an `<Errored>`, `Wrapped.rocx`): rendered in Node as the
  server platform answers a page and hydrated by `start.js`; a tampered document's `<body>`
  rendered again (strictly, a throw); the host's `data-rocx` elements passed over; `start.js`
  under `/rocx/` asking for nothing outside it; a `<NoHydration>` the browser's wasm hasn't (its
  nodes kept, strictly and after `<body>` is rendered again; the browser's build rendered against
  the page's answers and regions, byte for byte). `RawText.rocx`: raw text and a doctype.
- **The docs' demos** (`Docs.rocx`: one document, its parts far apart, the picks and the tally
  sharing a store through a context). `Alone.rocx`: the tally with nothing to provide its store,
  whose context has no default, fails, and `<Errored>` says why.
- **Titles and the head.** `Titles.rocx`: the document's title kept to the last `<Title>` there,
  hydrated strictly, the server's `<title data-rocx>` first in `<head>`. `Actions.rocx` (D-054):
  `<Meta>`, `<Link>` and `<Style>` rendered before `</head>`, kept hydrating strictly, following
  their holes and gone with their part.
- **Forms, actions and optimistic values.** `Form.rocx`: a flash hydrated as the server rendered
  it, a form sent with `fetch` (pending, refused, answered, redirected). `Actions.rocx`: revalidate
  keys (a result reading again only the reads its answer names, or none; a handler's own
  `revalidate!`), a form's fields given in its URL, `retry!` of a refused submission,
  `create_optimistic!` (shown at once, held while its action is on its way, then the server's with
  no frame of the old; back at once when refused or with nothing sent; two `update!`s of it in one
  handler composing), a form with a file and an action given a file's URL, sent as multipart.
- **Channels** (`Channels.rocx`: two feeds on one org's news, a third on another's, against a
  scripted `/rocx/live`): one stream for three subscriptions (one refused), messages in order, a
  frame's sayings in one post, a late subscriber resynced without a reconnect, one reconnect for a
  change, waits that double after drops, a server with nothing left closed, an older server's
  stream, and a host with no server asked once.
- **Drags and glides.** `Planner.rocx`: a card dragged to another day (a real drag, CDP's
  `Input.dispatchDragEvent`), shown there before the slow endpoint answers and kept while the
  board is read again, never shown where it was; two on their way at once, the refused one back;
  a list with no drop handler taking no drop; a link's click taken over (`on:click.prevent`).
  `Glides.rocx`: glides (none with less motion asked for), one into a narrower box in a
  transformed one scaling from its old size, in the top layer, under its new box's edge.
  `Drags.rocx` (D-055): a drag by touch in Chromium and in Gecko (held, it starts; its image under
  the finger; the page still; a swipe starts none; a box scrolls under a finger at its edge), a
  tap's click, a mouse's drag carrying `drag:data` and showing `drag:image`, files dropped and
  read by their URLs, `.point` and `.visible`.
- **Transitions** (`Fades.rocx`): rows and a part with transitions, a computed one, a list inside
  the part; rows and parts that stay until their transitions are over, and none with less motion
  asked for.
- **Keys** (`Shortcuts.rocx`): a key's handler and a combination's, each preventing the default;
  `.keys`; `Browser.focus!` once the handler is done, or as a part shows; `<Document>` and
  `<Window>`.
- **Memory.** No allocation left behind after many runs that waited (refreshes, new pages, memos
  made again: `Upstream.rocx`), and after rendering the docs' demos again and again.

### `test/navigation.test.mjs` (D-040)

`test/nav` is an app of routes: a layout with links of every kind; home; A with a `<Title>`, a
timer, an effect and a channel; an item; a guarded page; and, for phase 2, a shop (a layout below
the root keyed by its own `cat`, a page per item reading the query), a layout that reads the
location in its body, and a page that renders `<Navigate>`; and notes, a page of forms whose
submissions nothing reads, to its own endpoint and an item's (D-095). Its server half renders each document
with `renderToString`, and a scripted server serves them (slowly, redirected, refused or crashed
when told to). In Chromium, strictly, the tests check:

- **A click renders the next page without a load** (a value on `window` survives): its document
  fetched once as a navigation and nothing else asked; its title, `<Title>`, head, regions and
  attributes the document's; the stylesheet kept (one that differs swapped, the new one in before
  the old one goes); the page announced; the focus at `<body>`'s start; the page the same as a load
  renders, byte for byte outside the host's elements.
- **Every opt-out is left to the browser:** modifier keys, `target`, `download`,
  `rel="external"`, another origin, a path no page has, a file, a place on this page, `off`,
  `explicit`.
- **Prefetch** on a rest of the pointer (not a pass), keyboard focus and touch; a click then asking
  nothing more; one older than 10 s fetched again; a submission's result emptying the cache; `off`
  on a link and on `<html>`; `viewport` once in sight.
- **View Transitions** only when asked for and the browser has them, never with less motion asked
  for.
- **Navigating from code:** `navigate!` from a handler that waits for the server, once;
  `navigate_with!`'s replace; `<Navigate>` replacing its entry; a GET form navigating in place.
- **History:** back and forward with the scroll restored and the document used again within 10 s
  and fetched after; a hash, `noscroll`, a reload's scroll.
- **`is_routing!`** while a slow document is on its way, and after one overtaken.
- **Falling back to a load:** a middleware's redirect landing with its address; a text 401, a
  crash, a refused fetch, another build and a redirect to another site each loaded.
- **`use_before_leave!`** on an editor page (a draft's listener and a strict guard of its own): a
  link and `navigate!` stopped, the page, its address and its history as they were, nothing
  fetched; each listener told where it goes and whether one before stopped it; a retry from the
  dialog forced past the second listener, or asking again; back stopped with the address put back
  (its index unchanged), retried back with force; forward from a page with none not asked; forward
  stopped and staying; a listener gone with its component and with its page; `beforeunload`
  listened for only while the draft is unsaved, a synthetic one cancelled then, a reload asking
  with the browser's dialog and staying, nothing told and no dialog from the asking ahead.
- **Lifecycles:** the old page's effects, timer and channel stopping, the new page's starting, no
  stream opened again for the same channels; 200 navigations leaving no allocation behind.
- **Under `/rocx/`:** all of the above, the URLs the runtime writes under the base.
- **Kept levels** (phase 2): a kept layout's signal, a field's text and its region survive a
  navigation within it, and a new `cat` makes it anew; a page with new params is made anew; the links'
  `aria-current` follows (D-086); the page with its layouts kept is the page a load renders,
  byte for byte.
- **The query in place:** `set!` merges, `""` takes a name out, `set_with!`'s replace, back between
  queries, and a plain link to a query, all in place, no document fetched and only the read whose
  URL changed asked again; the layout that read the location once made anew and named (`remade`),
  and a query change under it fetching the document.
- **Forms to the app's endpoints** (D-095, D-118): which form URLs the route table makes an
  endpoint's (in Node); in Chromium, forms nothing asks about posted as the browser would
  (`x-rocx-in-place`), answered as plain forms and followed in place, no load: a result and a refusal
  back to the page, made anew from its document, a path with a param and fields in its query, a
  redirect of the endpoint's own; a form into a frame and one to a path no endpoint has left to the
  browser.

The docs site's own tests (`site/test/`) run the site on the native server and compare each page
with the browser runtime's render of it, byte for byte outside its `<NoHydration>`s.

## Not yet

- **Navigation in place** (D-040): a query that only server-rendered markup reads (a
  `<NoHydration>` listing results) doesn't follow a change of the query in place, since the
  browser has no code for it. (A page-wide "fetch my document on every query change" can come if
  an app needs one.) `use_before_leave!` can't hold a navigation while it waits for the server: a
  listener decides from what the page has. Solid Router's `state` option isn't kept with an entry
  (§6.1).
- **The rest of Solid 2.0's stores** (D-053): derived stores (`createStore(fn, seed)`,
  `createProjection`; a memo is the derived read), `createOptimisticStore` (D-030's optimistic
  memos cover actions), `reconcile` and `storePath` (a new list written whole, and Roc's record
  update, do their work). A write runs every live selection of its store, where Solid's touches
  only the paths written: four hundred take about half a millisecond a write (measured in D-053).
  Within a row, a changed item runs all of the row's holes that read it; a row that wants finer
  reads its item by parts (`Store.of(todo!).get!(|t| t.done)`).
- **The dev warning sees only calls of accessors** in a component's body (`count!()`, a prop's
  getter). One a helper makes (`total!(items)`) isn't reported, nor one at the top of a `.map`'s row
  (made once too).
- **The rest of Solid Router's actions and Solid 2.0's optimistic values:** `createOptimisticStore`;
  `.with` binds a form's fields (`Endpoint.with_fields`), and an action's values are bound by a
  closure instead; a revalidate key is a URL or the start of one, not a query's name and
  arguments; an optimistic write is a value, not a function applied again to the source's new
  value; a file is read whole with the request's body (`--max-body`), not streamed as it comes.
- **Drags:** a keyboard drag (a sensor that moves a thing with the arrow keys) isn't the
  platform's: an app gives keyboard users another way, as the docs' planner's menus do. The
  runtime's drag by touch stays in its page: another window or program can't take it. (A drag into
  the page from elsewhere is the browser's own, and arrives as one.)
- **Moves that resize:** what is inside an element that glides to another size is scaled with it
  for the glide (its text squeezed or stretched, FLIP's way), not laid out again each frame.
  Counter-scaling its children, as Framer Motion's layout animations do, would cost a pass a frame
  over everything inside. Where the browser has no popovers (Chrome before 114, Safari before 17,
  Firefox before 125), an element lifted inside a box that makes fixed elements its own stays
  clipped by that box.
