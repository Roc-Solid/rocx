# Roc Solid's browser platform

An app's page, Solid 2.0-style components, compiled to one wasm module, which `runtime.js` runs.
A component runs once, where it is rendered. Its markup's holes are computations the runtime runs
again when what they read changes, patching only their own node. An async value (an endpoint's
answer, a memo waiting for one) is read as a plain value: until it is in, the read aborts
its computation, which runs again once it is. The nearest `<Loading>` shows its fallback until
everything inside has its first values; a memo read again keeps its last value meanwhile, and
`is_pending!` says it is waiting; a failure shows the nearest `<Errored>`. A context gives a
value to everything under its provider. An effect runs once the markup is on the page, and again
when what it read changes, after its cleanup; a timer ticks until its component goes. A form posting
to an endpoint a component reads the submission of is sent with `fetch`, and the page stays; a
handler sends one without a form or waiting (an action), and the page shows it before the server
answers (an optimistic value), then the server's data, read again. Elements are dragged and dropped
with the browser's events, and glide when a change moves them. An app
whose root renders a whole document hydrates the page
the server sent, from `<html>` down (`start.js`). The server's platform (`server/`) renders the
same components natively; this one hydrates them.

    just setup                                             # the toolchain, once
    node --test --test-concurrency=1 web/test/platform.test.mjs

## The parts

- `platform/main.roc`, the header: an app provides `main!`, its root: a whole document (`rocx build
  --client` writes it: the app's `Root`). The platform gives the host `roc_mount` and `roc_run` (run
  a kept box). The browser answers no requests: the server platform answers every endpoint, the
  GETs a page reads as it renders among them.
- `platform/*.roc`, what components are written with: `Html` (markup whose holes are closures,
  escaping, safe URLs), `Solid` (`create_signal!`, `create_memo!`, `create_effect!`,
  `on_cleanup!`, `on_settled!`, `refresh!`, `is_pending!`, `use_context!`, and the browser's timers, `set_interval!` and
  `set_timeout!`, each owned by the run that started it), `Audio` (`play!`, `play_with!`: a sound
  file, from a handler), `Browser` (`call!`: the page's own JavaScript function, from a handler),
  `Show`, `For`, `Loading`, `Errored`, `Context`, `Call` (`fetch!`, `listen!`), `Router` (`location!`: the page's path and query; `use_submission!`: the latest
  submission to an endpoint; `use_submissions!`: all of them; `use_action!`: one a handler sends
  without a form), `Submission` (its `pending!`, `input!`, `field!`, `result!`, `error!`,
  `clear!`), `Submissions` (`all!`, as records, `pending!`, `pending_inputs!`, `clear!`),
  `Transition` (what `transition`, `transition:in`, `transition:out` and `transition:move` play:
  `fade`, `fly`, `scale`, `grow`, `glide`, `style`; `ms`, `delay`, `easing`, `origin`, `plus`),
  `Title` (`<Title>`: the document's title, from anywhere in the page) and `HttpStatusCode` (the status a
  page is answered with); and HTTP's: `Server` (a request, its body the bytes as they came, which `text_of` reads as text, and its answer: text, bytes, a
  page, events, or a body the server fetches from elsewhere and sends on, `forward`, with what of
  the request it passes on, `passed_on`; cookies and redirects; the flash a plain form's post comes
  back with, `flash!`, `flash_back`, `clear_flash`), `Endpoint` (a
  GET endpoint read as a plain value, `get!` or `read!`, with a query, `with_query`; any endpoint
  sent from a handler, `send!`, or listened to, `listen!`; a form's `action`, `url_of`; a channel
  subscribed to, `subscribe!`, said to, `say!`, or resynced, `resync!`, and, on the server,
  published on, `publish!` and `publish_latest!`, or an endpoint run there and then, `run!`, given
  its handler with `bind`: `Generated/Api` is the app's contract, each endpoint's method, URL and
  types, the same in the browser's copy as on the server, D-037),
  `Channel` (what a route's `channel!` answers, `Channel.allow(who)`, and what a subscriber hears),
  `Events`, `Middleware` and `OpenApi`. The server platform's build copies them into
  `server/platform`, so the same code compiles on both.
- `host/host.zig`, inside the wasm: Roc's memory (its allocator, a count of live allocations, and
  what each run allocated, freed when the run unwinds: see Waiting), and every hosted function
  passed through to JavaScript.
- `runtime.js`: keeps Roc's closures as boxes by id; signals, memos, effects and computations, and
  which reads which, and who owns what; builds, hydrates and patches the DOM; asks the server
  (`fetch`, an endpoint's read among them; streams of events; forms); renders as a server would too
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
  `Html.optional` (`["o",…]`), `Html.style_var` (`["sv",…]`: `style:color` or `style:--size`, the
  name plain, the value passed through `safe_css`, which drops what could end the declaration and
  any function but those that compute a value)…, with no closure, and the server puts no comments
  around it. A
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
  The throw skips Roc's drops, so the host keeps count: the runtime opens a frame of the host's
  around each call into Roc (`frame_begin`), in which the host notes every allocation made and every
  box handed to the runtime. A call that returns closes it (`frame_end`), its notes going to the
  frame around it, if any. A run that unwinds keeps them (`frame_unwound`) until the runtime has let
  go of what the run made (its computations, signals, cleanups and boxes); then what the run had
  allocated and still holds is held by nothing but the unwound frames, and is freed (`reclaim`):
  Roc's values are immutable, and a value the runtime gives Roc comes with a reference of the
  runtime's own, so nothing older points at it. If a box the run handed over is still allocated,
  nothing is freed (a leak, never a use after free). A run that fails, or a probe or a handler that
  waits, is reclaimed the same way. What the unwound frames held of older values (a value read,
  counted once more) stays counted, so the host's `js_fetch` still answers "waits" and has
  `js_waits` throw only once it has let go of the request's text.
- **Pending** (`is_pending!`, Solid 2.0's `isPending`). A memo whose run waits while it has a value
  (not failed) is `refreshing`, from the flush that started that run until it settles or fails; it
  is `stale` if it is refreshing or a memo it reads is, set again after each run and passed down to
  the memos that read it. `is_pending!(read!)` runs `read!` once as a probe (as `refresh!` does: its
  reads untracked, a wait or a failure only stopping it) and answers whether a memo it read is
  stale. The caller tracks each one's `pending` node, not its value, and keeps the probe: when one
  changes (it flips, settles or fails), the caller is put in the flush as a recheck, which runs the
  probe again and runs the caller only if the answer, or the memos read, changed. So a reader runs
  again when its answer changes, and only then, and a memo that becomes pending again before the
  reader's turn (one that reads another that just settled) doesn't make it flicker. The server
  answers false.
- **Components run where they are rendered:** rocx writes `<Picks />` as
  `Html.component(|| Picks.view!({}))`, and the runtime runs it as it builds that place, once, its
  reads untracked, so it sees the contexts provided above it. A signal belongs to the run that made
  it, and is let go of with it: a `<Show>` switching, a row going. A `<For>`'s row and a `<Show>`'s
  narrowed child are effectful functions run the same way, as their part is made (D-036), so they
  may hold another `<For>` or `<Show>`, owned by the row or the part; and, as a component, once and
  untracked (Solid's `mapArray` and `untrack`, D-039): a change of what one read at its top doesn't
  make it anew (a read that waits runs it again once its value is in). Its holes, and the getters it
  gives its components, follow the item.
- **Parts are made as they show**, as Solid makes them. What a `<Show>` shows, and a fallback (a
  `<Show>`'s, a `<For>`'s, a `<Loading>`'s), is serialized as a component node
  (`{"t":"c"}`, `Html.serialize!`'s `made!`): its box is run where the part is rendered, once, its
  reads untracked, owned by the part, and again each time the part shows again. So the holes inside
  aren't kept until then. A `<For>`'s row (`"r"`) and a `<Show>`'s function child (`"with"`) are made
  as they come too, by computations of their own, run untracked as above (D-039): a value prop read
  there (`<PlannerDay day={day!()} />` in a row) is a getter the component reads, so the row is kept.
- **Props are getters** (D-039), as Solid's are. rocx writes `<Shows label={word!()} />` as
  `Html.component(|| Shows.view!({ label: || word!() }))`, every value prop a function that computes
  it (a static one too: `size: || 2`), and writes the component, as its author wrote it with
  `view! : { label : Str } => Html` and `|{ label }|`, so that it takes them: its type
  `{ label : () => Str }` (a default `max : U64 ?? 5` is `(() => U64) ?? (|| 5)`), its pattern
  `|{ label: label! }|`, and each read of `label` in its definition `label!()`, where it is written.
  So the read runs where the code is: in a hole, a computed attribute, a memo or an effect's compute,
  tracked there, and only that is patched, the component and its signals kept; in a handler, an
  effect's apply or a timer, when it runs, the current value; in the component's body, once, as it
  runs (`first = label` keeps the first), as `props.label` at a Solid component's top. A lambda that
  may be pure (given to `.map`, `.keep_if`, bound to a name without `!`) can't call a getter: rocx
  reads the prop where that lambda is made, `(|label| |x| … label …)(label!())`, so in a hole the hole
  tracks it. One known to run as an effect reads it when it runs: `|| …`, a handler, a function
  child, one given to a `!` function (`create_effect!(…, |r| …)`) or bound to a `!` name. A
  component that names its whole record (`|props|`) reads `(props.label)()`. Not getters: a prop
  named as an effect (`label!={word!()}`, an accessor, `|| word!()`, which the child types and calls
  itself), `children` (markup, whose holes are already live), and the props of the platform's own
  components (`<Show>`, `<For>`…). A pure component's (`view`) props are values, its call made where
  it is written; given one read from what changes, the call is a hole of its own
  (`Html.html_of(|| Heading.view({…}))`), made anew when it changes. A prop's expression runs where the
  child reads it: a context it reads is that place's, an async read in it waits in the child's hole
  (and, read in the child's body, is refused, as the component's own would be), and each read
  computes it again, as a Solid getter does (a memo shares it). A `.roc` component written by hand
  types its value props as getters (`label : () => Str`).
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
- **Channels** (D-020): `Endpoint.subscribe!(Api.channel_org_org_news({ org }), heard!)`, from an
  effect, subscribes to a route's `channel!` (server/README.md) until the effect runs again or its
  component goes; `heard!` is given `Resync` (read your data again: on each connect and reconnect,
  when the server saw it fall behind, and on `Endpoint.resync!`), then `Message(message)`, in order,
  one at a time (the next once its handler is done, waiting or not), or `Refused(status, why)` /
  `Ended(why)`. The runtime's hub (`Hub` in `runtime.js`) keeps every subscription in the tab on one
  stream, `GET /rocx/live?tab=…&c=<url>…`; two subscribers to one channel share it. When the set of
  channels changes, it opens the stream again once the render that changed it is done, and only if
  the set did change; when the stream drops, after 0.5 s, doubled each time up to 30 s, starting
  over once a stream has stayed up 10 s. A new subscriber to a channel the stream has open asks the
  server for its resync. `Endpoint.say!(channel, said)` (from a handler) goes, with the frame's other
  sayings, in one `POST /rocx/live/send`; a refusal is a warning in the console. The tab's id is
  random, kept in `sessionStorage` (a reload keeps it; a duplicated tab copies it). A tab has one
  stream: the server ends a tab's old stream when a new one comes, telling it `event: replaced`, so
  a page that hears it is a duplicated tab, and takes an id of its own before it connects again. Where no server
  answers (a static copy: a 404, a 405, or no stream), every subscriber hears `Refused(404, …)`, and
  the hub asks for nothing more. Subscribing from a handler fails: nothing would end it. On the
  server, nothing is subscribed to. `Endpoint.publish!` is the server's: in the browser it fails.
- **Timers**: `set_interval!(ms, tick!)` is `setInterval`, `set_timeout!(ms, done!)` `setTimeout`
  (`Host.interval!`, `Host.timeout!`), their handlers run as a click's; each answers its `clear!`
  (`Host.clear_timer!`). A timer started in a component or a computation (an effect's compute too),
  or in an effect's apply, stops with that run's cleanups, as if it had called
  `on_cleanup!(clear!)`: before the computation runs again, before the effect's next apply, when
  what made it goes. One started in an event handler belongs to the run that made the handler's
  element. `runtime.timers` holds the ones running; on the server none starts (the id is 0).
- **The clock**: `Time.now_millis!({})` is `Date.now()`, and `Time.now_nanos!({})`
  `performance.timeOrigin + performance.now()` in nanoseconds (it doesn't go back while the page is
  open), the server platform's names and types (`Host.now_millis!`, `Host.now_nanos!`, floats from
  JS made whole numbers by the host). For handlers, effects' applies and timers: markup made from
  the time while rendering would differ from the server's, and hydration would refuse it, so a
  date that decides what a page shows comes from the server, and so does a deadline (a countdown
  counts to it by this clock). There is no `Time.sleep!` here: `set_timeout!` waits.
- **Forms**: `use_submission!(endpoint)` (or `use_submissions!`) registers the endpoint's URL with
  the runtime, by its path without the site's base, while its component is there. A `submit` on the
  page (the runtime listens once) of a `method="post"` form to that URL, on this site, not
  multipart, that no handler prevented, is sent with `fetch`: its fields URL-encoded,
  `accept: application/json`, `x-rocx-submission: 1`. The submissions to each URL are a list, a
  source computations read (`Host.submission!`, the latest; `Host.submissions!`, all): each pending,
  then the answer's status and body (status 0 and why with none). `x-rocx-redirect` (an endpoint's
  own redirect, which `Endpoint.respond!` gives the runtime as 200), or a redirect fetch followed,
  sends the browser there. The latest one forgotten (`clear!`), there is none until the next, nor
  the flash. Without a submission in the browser, `Submission` reads the flash.
- **Actions and optimistic values** (D-030): `use_action!(endpoint)` is a function a handler calls
  with the endpoint's arg (`Host.submit!`): queued with the handler's writes, so a handler that
  waits and runs again sends it once, then sent as `Endpoint.send!` sends it (JSON, with
  `x-rocx-submission: 1`), a new submission in the endpoint's list; nothing waits for it.
  `use_submissions!(endpoint)` reads the list: `all!` (records: `id`, `pending`, `input`, `result`,
  `error`), `pending!`, `pending_inputs!` (what those on their way sent, parsed as the endpoint
  reads it), and `clear!(id)`. An optimistic value is a memo of the server's data with the inputs on
  their way applied: `create_memo!(|| moves.pending_inputs!().fold(Endpoint.get!(board), moved))`.
  A submission answered 200 isn't done at once: the runtime reads the page's reads again
  (`revalidate`: every computation that read a GET, `Endpoint.get!` or `read!`, has its calls
  cleared and runs again, its last value shown meanwhile), and marks it done in the run of the last
  one to have its answer (or fail, or go), so what reads both sees the server's new data and the
  submission's end in one flush: the optimistic value gives way with no frame of the old data
  (meanwhile `is_pending!` of the memos read again is true). A
  refusal (any other status, or none) is done at once: the input isn't applied any more, and the
  value is the server's again, the refusal in `error`. Several may be on their way, each answered on
  its own; an input still on its way is applied to the data read again, so applying one should be
  idempotent (a card's day, not one more). On the server, there are no submissions: `all!` is the
  flash or none, and nothing is applied, so the page hydrates as rendered. The endpoint's contract
  (`Generated/Api`, D-037) types its submissions in both copies of the app: `use_submissions!(Api.post_move({}))`
  is a `Submissions(Move, Str)`, with nothing for a component to say.
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
- **JSON.** What crosses as JSON (an endpoint's body, result and events, `Browser.call!`'s
  argument) is written with `Json.to_str_try`, so
  an `F64` goes as a number; one JSON can't write (NaN, an infinity) fails the call (an endpoint's
  result is a 500 that says so). Their where clauses read `Json.Encodable(e)`. The builtin `Try`
  has no `encoder_for` or `parser_for` on this Roc, and nothing outside the builtins can give it
  one: `rocx check` adds a hint under the compiler's report, naming the tag union to write instead
  (`[Ok(a), Err(e)]`, read by a `match` as a `Try` is).
- **On a server**, nothing waits: every hole runs once, no effect or timer runs and no cleanup is
  kept, an endpoint's read (noted under `GET <url>`) is answered from the answers given
  (`renderToString({ answers })`, a page's answers script; one not there fails with 599), and the HTML
  has comments where computed holes, rows and `<Show>`s are (`<!--x-->…<!--/x-->`), with the answers
  in a script beside it.
- **Hydrating**, the runtime reads the answers, walks the server's nodes beside the markup Roc made,
  and binds each computation to its own node: nothing is asked again or made again. A read whose
  answer the page carries is answered from it; with `{ strict: true }` (the tests'), hydrating that
  asks the server for anything the page didn't carry throws.
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
    inside (one inside another is only its part). An endpoint read inside isn't noted in the
    answers script, since the browser never reads it.
  - **In the browser's copy** of a `.rocx` file (`rocx build --client`), it has no children, and an
    import only they used is gone, as one only a route file's `middleware` used is: none of it is in
    the wasm. A name only they used is rewritten where it is bound, a record pattern's field as
    `params: _`, a parameter or a local as `_lang`, so the browser's build has no warning of it
    (D-044). What is left is a placeholder. Hydrating passes over the server's nodes between the markers, and never builds,
    adopts or patches them. A `<body>` rendered again after a mismatch keeps the server's regions,
    in order. One the browser builds where the server rendered none (a
    `<Show>` switching to a part that has one) is empty, with a warning.
  - **What may go inside:** anything the server can render. Elements, text, holes (computed ones run
    once), pure and `view!` components (run once, never hydrated, as Solid's), `<Show>`, `<For>`,
    `<Loading>`, `<Errored>` and endpoint reads all render as they would, once. Nothing
    there changes afterwards, and nothing in it runs in the browser. So rocx refuses a handler
    (`on:…`), a `key` or a transition written inside, at its line, and the server refuses to render
    a handler a component put there: a 500 that says which element, rather than a dead button. A
    `<Title>` inside sets the page's title on the server only.
  - **`renderToString({ answers, regions })`** renders the browser's build against a page the server
    rendered (decision D's byte-for-byte check): `answers` are the page's answers script (each read
    answered from it and recorded as the page has it; one the server didn't make fails, 599), and
    `regions` what the page has inside each `<NoHydration>`, in order (`Runtime.regionsOf(html)`),
    written as they are there. Outside the regions it is byte for byte; inside them the server's
    output is taken as it is. Without `regions`, a placeholder renders empty.
  - **On GitHub Pages**, the static export GETs each page from the native server, regions and all,
    so they are in every prerendered page. **Client-side navigation** (D-040, proposed:
    `spike/client-nav/DESIGN.md`) has no copy of a region in the wasm: a navigation fetches the
    page's document, as the server answers it or as the export wrote it, and takes its regions
    from there.
- **RCDATA**: inside `<title>` and `<textarea>` the HTML parser reads everything as text, comments
  too, so the server writes their holes without comments, and hydrating builds the element's
  text anew from the markup (its holes bound to the text nodes it makes; not a patch), the server's
  text checked against it.
- **Under a base** (`Runtime.load(source, { base })`, `/rocx/` for a copy at
  `example.github.io/rocx/`), a URL Roc gives that begins with `/` (an endpoint's read, a fetch's,
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
  the runtime makes, at a volume and a rate (its pitch moving with it), and `rocx:focus` moves the
  keyboard's focus to the element with that id (`Browser.focus!(id)`, nothing if there is none),
  once the page shows what the handler wrote: from an effect's apply, `on_settled!(|| Browser.focus!(…))`
  focuses a field as its part shows.
- **`renderToString`** renders markup with `<html>` at its top as the server platform answers a page:
  `<!doctype html>` first unless the markup has one, then the flash the page read, if it did, the
  answers script and the bootstrap just before `</body>` (`Runtime.documentOf`). Any other markup is an app's range,
  `<!--app-->…<!--/app-->`, for `hydrate(container)`.
- **Events**: `on:click` runs a handler; `.value`, `.checked`, `.key` give it what the event says; a
  key's name (`on:keydown.ArrowUp`) runs it for that key only, with no modifier key held, and
  prevents its default; so does a combination (`on:keydown.Shift+Enter`, `Mod+K`,
  `Ctrl+Alt+Delete`: `["on",event,id,"Shift+Enter"]`), with exactly those modifier keys held, so
  Shift+Enter isn't Enter (`keyCombo`). `Mod` is ⌘ on macOS and iOS, Ctrl elsewhere. A letter or
  digit matches in either case, and by its place (`event.code`) when the layout types something
  else there (Alt+K on macOS types ˚); nothing matches while an input method composes. `.keys`
  (`Html.on_keys`, `["onk",event,id,"keys"]`) gives the handler the key and the modifier keys held,
  a record (`Html.Keys`: `key`, `shift`, `ctrl`, `alt`, `meta`, `mod`), as five flags and the key
  the host turns into one; `.key`'s handlers keep their `Str`. `.prevent` (`["onp",…]`) prevents
  its default first (a link's click taken over); `on:frame.ms` runs it every animation frame while
  its element is on the page.
- **`<Document>` and `<Window>`**: `<Document on:keydown.Mod+K={open!} />` puts handlers on the
  whole document (`<Window on:resize={…} />`, on the window), written as an element's are, any
  but `on:frame.ms`. rocx writes `Html.on_document([…])` (`{"t":"listen","to":"document","a":[…]}`),
  unless the file has a module of that name, which is then a component. It renders nothing, on the
  server or in the browser, and hydrating takes no node for it; the runtime adds its listeners
  where it is built or adopted (`listenOn`), with the element's handler code (`listener`), and
  takes them off with its owner's cleanups (it runs again, or goes: a `<Show>` hiding it), as
  solid-primitives' `makeEventListener` does. Svelte's `<svelte:document>` and `<svelte:window>`
  are the same idea.
- **Drag and drop** (D-029) are events too (`dragAndDrop`): an element with a drop handler is a drop
  target, its dragenter's and dragover's default prevented, `dropEffect` a move (unless the drag
  allows only a copy or a link), and its drop's (a dropped link or file doesn't open);
  `on:drop.value` is the dropped text (`text/plain`). An element's dragenter and dragleave handlers
  run when a drag comes over it from outside and leaves it for outside, as mouseenter and
  mouseleave do (a count of the browser's enters and leaves), and dragleave's when a drop or the
  drag's end (a listener on the page, once) leaves it. An element with a dragstart handler gets
  data on its drag (`application/x-rocx`), which Firefox needs to start one. What is dragged is the
  app's: a signal its handlers set. A source removed by the drop (its row moved elsewhere) gets no
  dragend handler run (its box went with its row): clear what dragstart set in the drop handler too.
- **Transitions** (`transition`, `transition:in`, `transition:out`, a `Transition` from
  `Transition.roc`): a `<For>`'s new row, or a `<Show>`'s new part, plays its own elements'
  transitions in once the flush that made it is on the page (none the first time a `<For>` or a
  `<Show>` settles: those come with the page). A row whose key is gone, or a part switched away,
  stays where it was, inert and `aria-hidden`, its computations disposed at once, while its own
  elements' transitions out play (`element.animate`, backwards, holding the hidden style); then it
  is removed. A `<For>` putting its rows in order passes over the rows leaving; `<For>`s inside a part
  that is leaving keep their rows until it goes. With `prefers-reduced-motion: reduce`, nothing
  plays.
- **Moves** (D-031; `transition:move`, `key`): an element with a move transition is measured
  (`getBoundingClientRect`) before a flush first changes the page's structure (a row comes, goes or
  moves, a part switches, a hole's markup is made anew: `measure`), and after it (`glide`): one that
  moved plays the difference back with `translate`, at the transition's pace (FLIP). An element with
  a key (`["k",…]`, or `["ko",…]` computed) that appears in the flush as one with the same key went
  (taken away, or on its way out) is that one moved: it glides from the other's box, its transition
  in doesn't play, and the other, if leaving, goes at once. An element inside another that glides
  moves with it; a glide playing is stopped and the next starts from where the element is seen.
  One that glides out of a box that scrolls or clips (`overflow` other than `visible`, `contain:
  paint`) into another (a card into another column's scrolling list), where what clips it now would
  hide where it was, is lifted for its glide (`lift`): fixed where it lands, above the page, a
  hidden stand-in of its size keeping its place, so nothing cuts it off on its way; it stays where
  it is in the document, so its styles and handlers are its own, and is put back, its own style as
  it was, when the glide ends or another starts. A glide within one box, or one whose old place the
  box shows, isn't lifted: what it costs is a walk up from the element, each box's style read once
  a flush. Hydrating and mounting measure nothing; with `prefers-reduced-motion: reduce`, nothing
  glides. The server writes nothing for them.
- **An observer** (`runtime.observer`: `seeded`, `fetch`, `fetched`, `listen`,
  `heard`, `unlisten`, `patch`, `row`, `show`, `frame`, `effect` (a call of the page's own
  function), `apply` (an effect's apply), `submit`, `submitted`, `revalidate` (a result reading the
  page's reads again), `glide` (an element moving), and the hub's `subscribe`, `unsubscribe`,
  `connect`, `dropped`) is told what the runtime does: the docs' inspectors and the showcase's frame
  meter. Hydrating isn't a patch.

## The tests (`test/platform.test.mjs`)

The test app (`test/app`, in rocx) is built several ways: the profile (`Profile.rocx`: five
answers, one spinner, regions that fail on their own, a rename that waits for the server) from the
dev backend and optimized; the picks (`<For>` by key and by position, `<Show>`); the nested
(`Nested.rocx`: a `<For>` in a `<For>`'s row and in a `<Show>`'s child); the fades (`Fades.rocx`:
rows and a part with transitions, a computed one, a list inside the part); the echo (`Echo.rocx`: a
GET endpoint read with what is typed, rendered in Node from the answer the server gave, hydrated
without asking again, and asked again as one types); the reads (`Reads.rocx`: a GET endpoint read
as the page renders, with the page's query, rendered from the answer the server noted, hydrated strictly without
asking again, and read from its URL again when its events say so); `is_pending!` (`Pending.rocx`:
false on the first load, true while a refresh is on its way, false on the server); the docs' demos
(`Docs.rocx`: one document, its parts far apart, the picks and the tally sharing a store through a
context); the tally with nothing to provide its store (`Alone.rocx`); and a whole document
(`Document.rocx`; inside an `<Errored>`, `Wrapped.rocx`), rendered in Node as the server platform answers a page and hydrated by
`start.js`; effects, a cleanup, a timer and a listen (`Effects.rocx`); a form's submission
(`Form.rocx`); value props, getters (D-039), given in a hole, outside one, in a `<Show>` and in a row, read every way a component may, and an accessor (`Props.rocx`); `<Title>`s
(`Titles.rocx`); channels (`Channels.rocx`: two feeds on one org's news, a third on another's); and a
planner (`Planner.rocx`: cards dragged between days, moved optimistically with `use_action!` and
`use_submissions!`, gliding).
In Chromium, against a scripted server (a scripted `/rocx/live` too): what shows while answers come, what a click
patches, failures and retries, rows kept and moved, rows and parts that stay until their
transitions are over (and none with less motion asked for), hydration without a request, a tampered document's `<body>` rendered again (and strictly, a throw), the
host's `data-rocx` elements passed over, `start.js` under `/rocx/` asking for nothing outside it,
an effect run after hydration and again after its cleanup (none on the server), a timer and a
listen stopping with their component, a flash hydrated as the server rendered it, a form sent with
`fetch` (pending, refused, answered, redirected), a component given a value prop (in a
hole, outside one, in a `<Show>`, in a row) kept, its signals with it, and only what reads the
prop patched (in its body, once; in a pure lambda, by its hole; in an effect and a handler, as they
run), rows made once, the document's title kept to the last `<Title>` there (hydrated strictly, the
server's `<title data-rocx>` first in `<head>`), a `<NoHydration>` the browser's wasm hasn't (its
nodes kept, strictly and after `<body>` is rendered again; the browser's build rendered against
the page's answers and regions, byte for byte), one channel stream for three subscriptions (one
refused), messages in order, a frame's sayings in one post, a late subscriber resynced without a
reconnect, one reconnect for a change, waits that double after drops, a host with no server asked
once, a card dragged to another day (a real drag, CDP's `Input.dispatchDragEvent`) shown there before
the slow endpoint answers and kept while the board is read again, never shown where it was; two on
their way at once, the refused one back with its refusal; a list with no drop handler taking no drop;
glides (none with less motion asked for); a link's click taken over; and no allocation left behind,
after many runs that waited (refreshes, new pages, memos made again: `Upstream.rocx`) too; and an
`<Errored>`'s retry reading again the failed read a memo it shows reads.

## Not yet

- **The rest of Solid 2.0:** keyed `<Show>`, `<Switch>`/`<Match>`, `<Repeat>`,
  `untrack`, `createRenderEffect`, an effect's `error` handler, stores as `createStore` makes them.
- **The rest of Solid Router's actions:** `.with`, a submission's `retry`, saying which reads a
  result reads again (Solid Router's `revalidate` keys: today every GET the page read), and
  multipart forms (sent as the browser sends them). Solid 2.0's `createOptimistic` (writes undone
  when their action's transition ends) isn't there: an optimistic value is the server's with the
  submissions on their way applied (D-030).
- **`latest`** (Solid 2.0's): a memo already shows its last value while it is read again, and
  `is_pending!` says it is.
- **Dragging by touch or pointer:** only the browser's drag and drop (a long press on Safari for
  iPad and iPhone; many other mobile browsers start none from a touch); files dropped (`dataTransfer.files`), a drag image of the app's, and data other
  than text for other pages to read.
- **Moves that resize:** a glide moves an element (`translate`), it doesn't scale it from its old
  size. One lifted out of a box that clips lands over its new box's edge when its place there is
  scrolled out of sight, then is clipped as it is put back; one inside a box that makes fixed
  elements its own (a `transform`, a `filter`, `contain: paint`) stays clipped by that box.
- **The rest of @solidjs/meta:** `<Meta>`, `<Link>`, `<Style>`; only `<Title>` is there.
- **`untrack`** (Solid's), and Solid 2.0's dev warning for a reactive read at a component's top
  (a prop's getter, a signal) that it would silence; and `merge`/`omit` for passing props on.
- **A pure component patched in place:** given a value read from what changes, its call is a hole
  made anew (it keeps no state); a `view!` is kept.
- **`Try` across the wire:** the builtin has no JSON encoder or parser on this Roc; a tag union
  stands in.
- **The rules a component must keep:** read async values in holes, not in its body, and write
  signals only in handlers (an effect's apply, a cleanup and a timer's tick are handlers); the
  runtime refuses the first.
