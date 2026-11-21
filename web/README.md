# Roc Solid's browser platform

An app's page, Solid 2.0-style components, compiled to one wasm module, which `runtime.js` runs.
A component runs once, where it is rendered. Its markup's holes are computations the runtime runs
again when what they read changes, patching only their own node. An async value (a server
function's answer, a memo waiting for one) is read as a plain value: until it is in, the read aborts
its computation, which runs again once it is. The nearest `<Loading>` shows its fallback until
everything inside has its first values; a failure shows the nearest `<Errored>`. A context gives a
value to everything under its provider. An effect runs once the markup is on the page, and again
when what it read changes, after its cleanup; a timer ticks until its component goes. A form posting
to an endpoint a component reads the submission of is sent with `fetch`, and the page stays. An app
whose root renders a whole document hydrates the page
the server sent, from `<html>` down (`start.js`). The server's platform (`server/`) renders the
same components natively; this one hydrates them.

    just setup                                             # the toolchain, once
    node --test --test-concurrency=1 web/test/platform.test.mjs

## The parts

- `platform/main.roc`, the header: an app provides `main!`, its root: a whole document (`rocx build
  --client` writes it: the app's `Root`). The host provides `roc_mount` and `roc_run` (run a kept
  box). The browser answers no calls of server functions: the server platform does.
- `platform/*.roc`, what components are written with: `Html` (markup whose holes are closures,
  escaping, safe URLs), `Solid` (`create_signal!`, `create_memo!`, `create_effect!`,
  `on_cleanup!`, `on_settled!`, `refresh!`, `use_context!`, and the browser's timers, `set_interval!` and
  `set_timeout!`, each owned by the run that started it), `Audio` (`play!`, `play_with!`: a sound
  file, from a handler), `Browser` (`call!`: the page's own JavaScript function, from a handler),
  `Show`, `For`, `Loading`, `Errored`, `Context`, `Call` (`server!`, `fetch!`,
  `listen!`), `Router` (`location!`: the page's path and query; `use_submission!`: the latest
  submission of a form to an endpoint), `Submission` (its `pending!`, `input!`, `field!`,
  `result!`, `error!`, `clear!`), `Title` (`<Title>`: the document's title, from anywhere in the
  page) and `HttpStatusCode` (the status a page is answered with); and HTTP's: `Server` (a request,
  its body the bytes as they came, which `text_of` reads as text, and its answer: text, bytes, a
  page, events, or a body the server fetches from elsewhere and sends on, `forward`, with what of
  the request it passes on, `passed_on`; cookies and redirects; the flash a plain form's post comes
  back with, `flash!`, `flash_back`, `clear_flash`;
  server functions' `local`, `remote`, `serve!`, and `context!`, what a function's middleware handed
  on, read in its body only: anywhere else, the browser among them, it crashes), `Endpoint`,
  `Events`, `Middleware` and `OpenApi`. The server platform's build copies them into `server/platform`, so the same code
  compiles on both.
- `host/host.zig`, inside the wasm: Roc's memory (its allocator, and a count of live allocations),
  and every hosted function passed through to JavaScript.
- `runtime.js`: keeps Roc's closures as boxes by id; signals, memos, effects and computations, and
  which reads which, and who owns what; builds, hydrates and patches the DOM; asks the server
  (server functions, `fetch`, streams of events, forms); renders as a server would too
  (`renderToString`, from the answers a page recorded).
- `start.js`, the bootstrap the server platform puts before a page's `</body>`
  (`<script type="module" data-rocx src="/rocx/start.js">`): it loads `runtime.js` and the app's
  `app.wasm` from beside itself, calls `runtime.hydrateDocument(document)`, and dispatches
  `rocx:ready` on the document, its detail `{ runtime, ms }`. Beside itself, so a site may be served
  under a path of its own: at `example.github.io/rocx/` it is `/rocx/rocx/start.js`, and the base
  it gives `Runtime.load(…, { base })` is the directory above, `/rocx/`. The app's build serves the
  three files.

## How

- **Markup is JSON.** A component returns markup whose holes are closures; Roc serializes it
  (`Html.serialize!`), each closure kept by the runtime as a box (`["x",id]` a text hole, `["vo",…]`
  a computed attribute, `["on",event,id]` a handler…). Running a hole is `roc_run(box)`; its answer
  is JSON again.
- **Static holes.** A hole or attribute that calls nothing named with `!` reads nothing that
  changes, so rocx writes it as a page's: `Html.text(e)`, `Html.attr`, `Html.class_if` (`["ci",…]`),
  `Html.optional` (`["o",…]`)…, with no closure, and the server puts no comments around it. A
  `<script>`'s or `<style>`'s text, as the `.rocx` file has it, is `{"t":"raw"}` (`Html.source_text`),
  and `<!doctype html>` is `{"t":"doctype"}`. Hydrating takes raw text without comparing it; a
  `<script>` the runtime builds doesn't run, as in Solid (the server's ran as the page was read).
  `Html.to_str` renders markup with nothing to run in it (an email's HTML, an `expect`).
- **Tracking.** A computation runs with the runtime noting what it reads (`signal_get`,
  `memo_get`); a write (`signal_set`, in a handler) schedules what read it, run in a microtask, an
  owner before what it made. A value a node already has isn't a patch. A setter can't compare Roc
  values, so every write runs its readers; state nothing shows goes in a signal nothing reads.
- **Waiting.** A read whose value isn't in throws, in JavaScript, through Roc's frames; the runtime
  restores Roc's stack pointer and runs the computation again when the value comes. A handler that
  waits drops its writes and runs again; its calls' answers are kept, so a command is sent once.
- **Components run where they are rendered:** rocx writes `<Picks />` as
  `Html.component(|| Picks.view!({}))`, and the runtime runs it as it builds that place, once, its
  reads untracked, so it sees the contexts provided above it. A signal belongs to the run that made
  it, and is let go of with it: a `<Show>` switching, a row going.
- **Props.** A prop named as an effect (`label!={word!()}`) is an accessor, `|| word!()`: Solid's
  getter, read in the child's own holes, which track it and are patched, the child kept. A prop that
  is a value read from what changes (`label={word!()}`) has Roc's type, so it can't be a getter:
  rocx writes `Html.component_with(|| { label: word!() }, Shows.view!)`, and the props are read by
  what serializes the markup the call is in (`ComponentWith`), before the component runs. In a hole
  that is the hole's run, which tracks them: when they change it runs again and renders the
  component anew (its signals made anew), as a pure component's call in a hole renders anew.
  Outside a hole they are read once, as before. A context a prop reads is the place's where the
  call is written, not the component's.
- **Effects** are Solid 2.0's split ones: `create_effect!(compute, apply)`. The runtime makes a
  computation of `compute` (tracked, owned by the component or computation running), and its answer
  is the id of a box `apply` is in, its value inside. `apply` runs after the flush, once nothing is
  dirty, oldest first: the markup is on the page by then. It runs as a handler (untracked; its
  writes applied when it is done), and before it, the last apply's cleanups. A `compute` that waits
  runs again when its value is in, holding no `<Loading>`; one that fails shows the nearest
  `<Errored>`. Solid's apply returns its cleanup; here it calls `on_cleanup!`, since Roc has no
  "nothing" a function may return. Neither half is given the previous value. `on_settled!(f)` is
  `create_effect!(|| {}, |_| f())`: a `compute` that reads nothing never runs again, so `f` runs
  once, after the flush that put the component on the page, and never on the server.
- **Ownership** is Solid's (RFC 02): what a run makes (child computations, effects, cleanups,
  timers, listens, the endpoints whose forms it sends) is its, and goes with it, in unwind order:
  the last child first, then its cleanups, the last first. A computation's cleanups run before it
  runs again; an effect's apply's before the next apply. `on_cleanup!` in an event handler fails,
  since nothing would run it. A listen (`Call.listen!`) started in an owner is aborted when that
  owner is cleaned up; from a handler it runs to the stream's end.
- **Timers**: `set_interval!(ms, tick!)` is `setInterval`, `set_timeout!(ms, done!)` `setTimeout`
  (`Host.interval!`, `Host.timeout!`), their handlers run as a click's; each answers its `clear!`
  (`Host.clear_timer!`). A timer started in a component or a computation (an effect's compute too),
  or in an effect's apply, stops with that run's cleanups, as if it had called
  `on_cleanup!(clear!)`: before the computation runs again, before the effect's next apply, when
  what made it goes. One started in an event handler belongs to the run that made the handler's
  element. `runtime.timers` holds the ones running; on the server none starts (the id is 0).
- **Forms**: `use_submission!(endpoint)` registers the endpoint's URL with the runtime, by
  its path without the site's base, while its component is there. A `submit` on the page (the
  runtime listens once) of a `method="post"` form to that URL, on this site, not multipart, that no
  handler prevented, is sent with `fetch`: its fields URL-encoded, `accept: application/json`,
  `x-rocx-submission: 1`. The latest submission to each URL is a source computations read
  (`Host.submission!`): pending, then the answer's status and body (status 0 and why with none).
  `x-rocx-redirect` (an endpoint's own redirect, which `Endpoint.respond!` gives the runtime as
  200), or a redirect fetch followed, sends the browser there. An answer to a submission that isn't
  the latest is dropped. Without a submission in the browser, `Submission` reads the flash.
- **The flash**: on the server, `Server.flash!` reads the `rocx-flash` cookie a plain form's post came
  back with, and the runtime notes what the page read (`Host.flash!`). The page carries it in
  `<script type="application/json" class="rocx-flash">`, before the answers, which hydration reads
  and takes out, so the browser's first render is the server's.
- **Contexts** are named by rocx (`Context.required("Demos/Picks.picks_context")`), since Roc's
  values have no identity; the runtime carries provided values down as it builds.
- **The document's title** (`<Title>`, `Title.view!`, `import pf.Title`), decided as @solidjs/meta
  does it: the last `<Title>` rendered that is still there is the title, wherever it is. It is
  `Html.document_title(children)`: a text hole of its own that renders nothing (`<!--x--><!--/x-->`),
  whose run computes the children's text (their holes run, so it tracks what they read) and tells
  the runtime (`Host.title!`). In the browser the runtime keeps each `<Title>`'s text by its hole's
  computation, in the order of their first runs (a page's after its layouts'; one shown again by a
  `<Show>` is new, so last), taken back with that computation's cleanups (running again, or going);
  after a flush in which one changed, the highest's text is put in a `<title data-rocx>` first in
  `<head>` (made if the server didn't), which is what `document.title` reads; with none left, that
  element goes and the root layout's own `<title>` stands. Rendering as a server would, the last
  title told is the page's: `Runtime.documentOf` (and the native host, `signals.rs`'s `titled`) puts
  `<title data-rocx>…</title>` before the `<head>`'s first `<title>`, or before `</head>`. Why not
  the layout's own `<title>`: writing the page's title into it would make the layout's `<head>`
  differ from what the layout renders, and strict hydration would refuse it; a separate element the
  host owns (`data-rocx`, which hydration passes over, as it does the bootstrap script) keeps the
  layout's markup exactly as rendered, needs no context or provider, and leaves the layout's
  `<title>` as the fallback, holes and all. The cost: with a `<Title>`, a page's `<head>` has two
  `<title>`s, the first the one browsers and crawlers use.
- **JSON.** What crosses as JSON (a server function's input and answer, an endpoint's body, result
  and events, `Browser.call!`'s argument) is written with `Json.to_str_try`, so an `F64` goes as a
  number; one JSON can't write (NaN, an infinity) fails the call (a server function's answer is a
  500 that says so). Their where clauses read
  `Json.Encodable([Infinity, NaN, NegativeInfinity, ..])`, not `Encodable(e)`: on this Roc,
  `Json.to_str_try` of a record holding a type with a derived `encoder_for` beside another field
  crashes the compiler unless the error type is named
  (`test/compiler-bugs/json-to-str-try-nominal`). The builtin `Try` has no `encoder_for` or
  `parser_for` on this Roc, and nothing outside the builtins can give it one: rocx refuses a
  server function whose annotation takes or answers one, at its line, naming the tag union to
  write instead (`[Ok(a), Err(e)]`, read by a `match` as a `Try` is), and `rocx check` adds that
  hint under the compiler's report for one without an annotation.
- **On a server**, nothing waits: every hole runs once, no effect or timer runs and no cleanup is
  kept, a server function's call is answered from the answers given (`renderToString({ answers })`,
  a page's answers script; one not there fails with 599), and the HTML
  has comments where computed holes, rows and `<Show>`s are (`<!--x-->…<!--/x-->`), with the answers
  in a script beside it.
- **Hydrating**, the runtime reads the answers, walks the server's nodes beside the markup Roc made,
  and binds each computation to its own node: nothing is asked again or made again.
- **A whole document** (`hydrateDocument(document)`): the root's markup is walked beside
  `document.childNodes`. The doctype takes the DocumentType node and `<html>` takes
  `documentElement`; there is no `<!--app-->` range. Where the markup doesn't take the DocumentType
  (the host writes a doctype when the markup begins without one, or with a hole's comment, as an
  `<Errored>` around the document does), it is passed over. The walk passes over the host's
  elements, marked `data-rocx` (the bootstrap; the dev reload script), and over the whitespace the
  HTML parser drops before `<html>` and `<head>` or moves into `<body>` from after `</body>`, and
  over the empty `<head>` it makes for a document that has none. A page that doesn't match (a
  browser extension added a node; the parser repaired the markup) gets a warning, and `<body>`'s
  children are rendered again from the same answers, the host's elements kept. `<head>` is left
  alone, because rendering it again would run its scripts again and flash its styles. Its
  computations are bound to it if it matches, and to a copy nobody sees if it doesn't. With
  `{ strict: true }`, which start.js passes when the page set `window.rocxStrict = true` before it
  ran (the tests do), a mismatch throws instead.
- **`<NoHydration>`** (Solid's name; `Html.no_hydration`) is markup the server alone renders:
  prose, listings, anything that never changes in the browser.
  - **On the server**, what is inside renders as anywhere else, every hole run once, but as static
    markup: between `<!--nohydration-->` and `<!--/nohydration-->`, with no comments of its own
    inside (one inside another is only its part). A server function called inside isn't recorded in
    the answers script, since the browser never calls it.
  - **In the browser's copy** of a `.rocx` file (`rocx build --client`), it has no children, and an
    import only they used is gone, as a `server!` body's are: none of it is in the wasm. What is left
    is a placeholder. Hydrating passes over the server's nodes between the markers, and never builds,
    adopts or patches them. A `<body>` rendered again after a mismatch keeps the server's regions,
    in order. One the browser builds where the server rendered none (a
    `<Show>` switching to a part that has one) is empty, with a warning.
  - **What may go inside:** anything the server can render. Elements, text, holes (computed ones run
    once), pure and `view!` components (run once, never hydrated, as Solid's), `<Show>`, `<For>`,
    `<Loading>`, `<Errored>` and server functions' calls all render as they would, once. Nothing
    there changes afterwards, and nothing in it runs in the browser. So rocx refuses a handler
    (`on:…`), a `key` or a transition written inside, at its line, and the server refuses to render
    a handler a component put there: a 500 that says which element, rather than a dead button. A
    `<Title>` inside sets the page's title on the server only.
  - **`renderToString({ answers, regions })`** renders the browser's build against a page the server
    rendered (decision D's byte-for-byte check): `answers` are the page's answers script (each call
    answered from it and recorded as the page has it; a call the server didn't make fails, 599), and
    `regions` what the page has inside each `<NoHydration>`, in order (`Runtime.regionsOf(html)`),
    written as they are there. Outside the regions it is byte for byte; inside them the server's
    output is taken as it is. Without `regions`, a placeholder renders empty.
  - **On GitHub Pages**, the static export GETs each page from the native server, regions and all,
    so they are in every prerendered page. **Client-side navigation** (a follow-up) has no copy of
    a region in the wasm: it would need it from the server, or, on a static host, from a
    prerendered copy (the region's HTML, written beside each page at export).
- **RCDATA**: inside `<title>` and `<textarea>` the HTML parser reads everything as text, comments
  too, so the server writes their holes without comments, and hydrating builds the element's
  text anew from the markup (its holes bound to the text nodes it makes; not a patch), the server's
  text checked against it.
- **Under a base** (`Runtime.load(source, { base })`, `/rocx/` for a copy at
  `example.github.io/rocx/`), a URL Roc gives that begins with `/` (a server function's, a fetch's,
  a stream's) is asked for under it, and `Router.location!` takes it off the page's path, so the
  browser sees `/rocx/syntax` as the server sees `/syntax`.
- **The page's own functions** (`Runtime.load(source, { effects: { vibrate(arg) {…} } })`, or
  `window.rocxEffects` for a page start.js wakes up) are what a handler's `Browser.call!(name, arg)`
  calls: queued with the handler's writes, so a handler that waits for the server and runs again
  calls once, and called once the flush after it has patched the page, given the argument parsed
  from JSON. An effect's apply is a handler too: what it calls runs at the end of the flush it is
  part of, once the page shows what it wrote. One that isn't there, or throws, is told on the
  console; a call while computing (an effect's compute among it) fails. Names beginning with
  `rocx:` are the runtime's own: `rocx:audio` plays a sound file (`Audio.play!`) with an `<audio>`
  the runtime makes, at a volume and a rate (its pitch moving with it).
- **`renderToString`** renders markup with `<html>` at its top as the server platform answers a page:
  `<!doctype html>` first unless the markup has one, then the flash the page read, if it did, the
  answers script and the bootstrap just before `</body>` (`Runtime.documentOf`). Any other markup is an app's range,
  `<!--app-->…<!--/app-->`, for `hydrate(container)`.
- **Events**: `on:click` runs a handler; `.value`, `.checked`, `.key` give it what the event says; a
  key's name (`on:keydown.ArrowUp`) runs it for that key only and prevents its default;
  `on:frame.ms` runs it every animation frame while its element is on the page.
- **Transitions** (`transition`, `transition:in`, `transition:out`, a `Transition` from
  `Transition.roc`): a `<For>`'s new row, or a `<Show>`'s new part, plays its own elements'
  transitions in once the flush that made it is on the page (none the first time a `<For>` or a
  `<Show>` settles: those come with the page). A row whose key is gone, or a part switched away,
  stays where it was, inert and `aria-hidden`, its computations disposed at once, while its own
  elements' transitions out play (`element.animate`, backwards, holding the hidden style); then it
  is removed. A `<For>` putting its rows in order passes over the rows leaving; `<For>`s inside a part
  that is leaving keep their rows until it goes. With `prefers-reduced-motion: reduce`, nothing
  plays.
- **An observer** (`runtime.observer`: `seeded`, `call`, `answer`, `fetch`, `fetched`, `listen`,
  `heard`, `unlisten`, `patch`, `row`, `show`, `frame`, `effect` (a call of the page's own
  function), `apply` (an effect's apply), `submit`, `submitted`) is told what the runtime does: the
  docs' inspectors and the showcase's frame meter. Hydrating isn't a patch.

## The tests (`test/platform.test.mjs`)

The test app (`test/app`, in rocx) is built several ways: the profile (`Profile.rocx`: five
answers, one spinner, regions that fail on their own, a rename that waits for the server) from the
dev backend and optimized; the picks (`<For>` by key and by position, `<Show>`); the fades (`Fades.rocx`:
rows and a part with transitions, a computed one, a list inside the part); the echo (a server
function, rendered in Node and hydrated); the docs' demos, a whole document, far apart, sharing a
store through a context; the tally
with nothing to provide its store; and a whole document (`Document.rocx`; inside an `<Errored>`,
`Wrapped.rocx`), rendered in Node as the server platform answers a page and hydrated by
`start.js`; effects, a cleanup, a timer and a listen (`Effects.rocx`); a form's submission
(`Form.rocx`); props read in a hole and outside one, and an accessor (`Props.rocx`); and `<Title>`s
(`Titles.rocx`). In Chromium, against a scripted server: what shows while answers come, what a click
patches, failures and retries, rows kept and moved, rows and parts that stay until their
transitions are over (and none with less motion asked for), hydration without a request, a tampered document's `<body>` rendered again (and strictly, a throw), the
host's `data-rocx` elements passed over, `start.js` under `/rocx/` asking for nothing outside it,
an effect run after hydration and again after its cleanup (none on the server), a timer and a
listen stopping with their component, a flash hydrated as the server rendered it, a form sent with
`fetch` (pending, refused, answered, redirected), a hole rendering a component anew when a value
prop it read changes, the document's title kept to the last `<Title>` there (hydrated strictly, the
server's `<title data-rocx>` first in `<head>`), a `<NoHydration>` the browser's wasm hasn't (its
nodes kept, strictly and after `<body>` is rendered again; the browser's build rendered against
the page's answers and regions, byte for byte), and no allocation left behind.

## Not yet

- **The rest of Solid 2.0:** keyed `<Show>`, `<Switch>`/`<Match>`, `<Repeat>`,
  `untrack`, `createRenderEffect`, an effect's `error` handler, stores as `createStore` makes them.
- **The rest of Solid Router's actions:** `useSubmissions`, `useAction`, `.with`, revalidating after
  one (call `refresh!` from an effect on `result!`), and multipart forms (sent as the browser sends
  them).
- **Pending state for later updates** (`isPending`, `latest`, optimistic writes).
- **The rest of @solidjs/meta:** `<Meta>`, `<Link>`, `<Style>`; only `<Title>` is there. And a
  value prop of an effectful component patched in place: Roc's types can't make it a getter, so it
  is an accessor (`label!={…}`) or rendered anew.
- **`Try` across the wire:** the builtin has no JSON encoder or parser on this Roc; a tag union
  stands in.
- **The rules a component must keep:** read async values in holes, not in its body, and write
  signals only in handlers (an effect's apply, a cleanup and a timer's tick are handlers); the
  runtime refuses the first.
