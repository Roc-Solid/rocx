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
with the browser's events, by mouse, touch or a pen, and glide when a change moves them. An app
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
  escaping, safe URLs), `Solid` (`create_signal!`, `create_memo!`, `create_optimistic!`, `create_store!`, `create_effect!`,
  `create_render_effect!`, `create_effect_with!`, `on_cleanup!`, `on_settled!`, `refresh!`, `is_pending!`, `latest!`, `untrack!`, `use_context!`, and the browser's timers, `set_interval!` and
  `set_timeout!`, each owned by the run that started it), `Browser` (`call!`: the page's own
  JavaScript function, or a plugin's script's, from a handler; sound files are packages/audio's,
  D-051), `Store` (a store's `get!`, a part of it tracked by its value; `of`, any accessor read by
  parts),
  `Show` (keyed too), `Switch` and `Match`, `For`, `Loading`, `Errored`, `Context`, `Call` (`fetch!`, `listen!`), `Router` (`location!`: the page's path and query, tracked; `navigate!` and `navigate_with!`: to
  another page, in place, from a handler; `is_routing!`: whether a navigation is on its way;
  `app!`: what `Generated/Root` tells the runtime of the app, D-040; `use_submission!`: the latest
  submission to an endpoint; `use_submissions!`: all of them; `use_action!`: one a handler sends
  without a form; `revalidate!`: which reads a result reads again), `Submission` (its `pending!`, `input!`, `field!`, `result!`, `error!`,
  `clear!`, `retry!`), `Submissions` (`all!`, as records, `pending!`, `pending_inputs!`, `clear!`, `retry!`),
  `Transition` (what `transition`, `transition:in`, `transition:out` and `transition:move` play:
  `fade`, `fly`, `scale`, `grow`, `glide`, `style`; `ms`, `delay`, `easing`, `origin`, `plus`),
  `Title` (`<Title>`: the document's title, from anywhere in the page; `<Meta>`, `<Link>` and
  `<Style>`, the head's other elements, are rocx's tags, D-054) and `HttpStatusCode` (the status a
  page is answered with); and HTTP's: `Server` (a request, its body the bytes as they came, which `text_of` reads as text, and its answer: text, bytes, a
  page, events, or a body the server fetches from elsewhere and sends on, `forward`, with what of
  the request it passes on, `passed_on`; cookies and redirects; the flash a plain form's post comes
  back with, `flash!`, `flash_back!`, `clear_flash`; the files a form sent, `file`, `files`,
  `multipart`, each an `Upload`), `Endpoint` (a
  GET endpoint read as a plain value, `get!` or `read!`, with a query, `with_query`; any endpoint
  sent from a handler, `send!`, or listened to, `listen!`; a form's `action`, `url_of`, with fields
  given ahead of time, `with_fields`; a channel
  subscribed to, `subscribe!`, said to, `say!`, or resynced, `resync!`, and, on the server,
  published on, `publish!` and `publish_latest!`, or an endpoint run there and then, `run!`, given
  its handler with `bind`: `Generated/Api` is the app's contract, each endpoint's method, URL and
  types, the same in the browser's copy as on the server, D-037; who sent a request, `posted_by`),
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
  around it. A hole the transpiler can't tell (one that calls a getter, D-039) is static too when its
  run reads and makes nothing that changes (D-052): no tracked read (a signal, a memo, a row, a
  submission, an endpoint, `is_pending!`; one inside `untrack!` isn't tracked) and no signal, memo,
  effect, cleanup, timer, listen, subscription or title made (`inert`). The server notes the same
  calls (signals.rs's `touched`) and writes such a text hole (`<Shows label="Go" />`'s `{label}`), or
  markup hole, without its comments; hydrating runs it, finds it static too, and takes its text as a
  static text's (split off the text the parser joined), or its markup in place, under strict
  hydration as well. Its computation isn't kept (a markup hole's stays, as the owner of what is
  inside, never run again), and neither is a computed attribute's that read nothing. A
  `<script>`'s or `<style>`'s text, as the `.rocx` file has it, is `{"t":"raw"}` (`Html.source_text`),
  and `<!doctype html>` is `{"t":"doctype"}`. Hydrating takes raw text without comparing it; a
  `<script>` the runtime builds doesn't run, as in Solid (the server's ran as the page was read).
  `Html.to_str` renders markup with nothing to run in it (an email's HTML, an `expect`).
- **Tracking.** A computation runs with the runtime noting what it reads (`signal_get`,
  `memo_get`); a write (`signal_set`, in a handler) schedules what read it, run in a microtask, an
  owner before what it made. A value a node already has isn't a patch. A setter can't compare Roc
  values, so every write runs its readers; state nothing shows goes in a signal nothing reads.
  `untrack!(read!)` (Solid's `untrack`, `Host.untrack!` on and off around it) runs `read!` with the
  running computation's reads not noted: a memo made inside tracks its own, and a read that waits
  still waits. `latest!(read!)` (Solid 2.0's `latest`) is `read!()`: a memo read again already shows
  the value it last settled at, since nothing holds a write back until a change is done, as Solid
  2.0's transitions do; it would differ only if they did.
- **Stores** (D-053, Solid 2.0's `createStore`; the design, and what was weighed, in
  `spike/stores/DESIGN.md`). `(todos, set_todos!) = create_store!({ items: [], filter: All })` is a
  signal of the whole value and a `Store(s)` over it. Roc has no proxies, so a read can't see which
  field it touched: a read selects, `todos.get!(|s| s.filter)`, and is tracked by what it selected.
  In a computation that tracks (`Host.tracking!`: a hole, an attribute, a memo, an effect's compute;
  not a handler, a component's body, a part's first run, `untrack!`, nor the server), it makes a
  *selection*: a memo of the part, owned by the reader's run, that compares its new value with the
  one it had (`Host.memo_last!`) by Roc's `==` and says so (`Host.memo_done!`'s `same`); the
  runtime then doesn't tell its readers. So a write runs every live selection of the store once
  (a pure function and a comparison each), and only the readers whose part changed run again;
  anywhere else, `get!` is `select` of the value, once, and nothing is made. A part must compare
  (`where [a.is_eq : …]`): records, tags, lists, text and numbers do, a type of one's own needs its
  `is_eq`, a function or markup can't be selected, which keeps selections to data. The setter takes
  a function of the state, Solid 2.0's draft setter: `set_todos!(|s| { ..s, filter: Done })`; it
  starts from the running handler's own write if it made one (`Host.signal_latest!`), so two in one
  handler compose. `Store.of(accessor)` reads any accessor by parts (an endpoint's answer, a memo,
  a prop's getter), with no setter. A store's list given to a `<For compared>` patches only the
  rows whose item changed. A selection is its reader run's, made anew when the reader runs again;
  `runtime.stats.selections` counts the runs of selections (the tests read it).
- **A read made once, said in a dev build** (D-052, Solid 2.0's dev warning, STRICT_READ_UNTRACKED).
  A component's body runs once, so a read there doesn't follow what it read. A dev build (`rocx
  build --dev`, `rocx dev`) writes each accessor a component's body calls (`goal!()`, a prop's
  getter `label!()`, a pure helper's read) as `Html.read_at!("Ui/Chart.rocx:44:39", goal!)`, which
  tells the runtime the place while it runs (`Host.read_at!`). A tracked read there, while a component
  runs, is warned of in the console, once a place: `rocx: Ui/Chart.rocx:44:39 reads a value that
  changes (a signal, a memo or a prop) in a component's body, once, as the component runs: what it
  shows won't follow it…`. `untrack!` says the one read is meant (`create_signal!(untrack!(goal!))`,
  the charts' start), and silences it. A prop given a constant reads nothing, so it is never warned
  of; neither is a read the transpiler doesn't see as a call of an accessor (`helper!(x)`). Any other
  build writes no `read_at!`, and warns of nothing; the server warns of nothing.
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
- **A `<For>`'s items.** Each time its list is read again, every row's item is set again
  (`Host.row_set!`), and, since the host can't compare Roc values, every row is told: the holes that
  read the item run again (a value a node has already is no patch). `compared` (D-053) compares in
  Roc instead: `<For each!={…} keyed={…} compared>` hands each item with whether it is `==` the one
  the row had (`Host.row_last!`), and only a row whose item changed is told, so one changed item in
  a thousand runs one row's holes (3 runs where 2,001 ran; measured in D-053). Its items must
  compare, as a store's parts do; a list of records holding functions or markup can't be compared,
  so it is a flag, not the default. Keys are made unique (`#1`, `#2` for a key seen before) with a
  `Dict` of how many of each came before: a count over every key seen made ten thousand rows take
  fifty million comparisons (1.9 s a change; 66 ms since).
- **`<Repeat>`** (Solid 2.0's) is a `<For>` with no list behind it: `count!` rows from `from!`
  (0 unless it says), each keyed by its index (`Html.each`, the same node a `<For>` is, so the server
  renders it and hydrating adopts it as one). When the range moves, only the rows that come into it
  are made and only those that leave it go; the child is given its index, which doesn't change, so a
  kept row has nothing to re-run. It is what a virtual list renders the rows that show with
  (packages/virtual).
- **Parts are made as they show**, as Solid makes them. What a `<Show>` shows, and a fallback (a
  `<Show>`'s, a `<For>`'s, a `<Loading>`'s), is serialized as a component node
  (`{"t":"c"}`, `Html.serialize!`'s `made!`): its box is run where the part is rendered, once, its
  reads untracked, owned by the part, and again each time the part shows again. So the holes inside
  aren't kept until then. A `<For>`'s row (`"r"`) and a `<Show>`'s function child (`"with"`) are made
  as they come too, by computations of their own, run untracked as above (D-039): a value prop read
  there (`<PlannerDay day={day!()} />` in a row) is a getter the component reads, so the row is kept.
- **Keyed `<Show>`, `<Switch>` and `<Match>`** (D-053, Solid 2.0's). A `<Show>` switches when whether
  `when!` holds changes; keyed (`<Show when!={card!()} keyed>`), also when the value inside changes,
  and a function child is given that value itself, not an accessor (`{|card| <Editor card={card} />}`,
  a new `<Editor>`, its signals new, per card). Roc's values have no identity: two are the same value
  when `Str.inspect` says the same of them (a function inside prints as `<function>`). A `<Switch>`
  shows the first of its `<Match>`es whose `when!` holds, reading them in order up to that one, and its
  fallback while none does; a `<Match>` has `<Show>`'s four forms (a Bool; a Try narrowed to an
  accessor, the part staying while the value changes; keyed, made anew per value, with plain children
  or a function given the value). All of them are a `<Show>`'s node (`Html.switched`: `"r"` answers
  the case's name, `"#…"`, or `false`, and a new name makes the part anew; `"with"` makes it), so the
  server renders, and hydrating adopts, them as it does a `<Show>`, strictly too. rocx refuses a
  `<Match>` that isn't a `<Switch>`'s child, anything else in a `<Switch>`, and a key function on
  either (`keyed` is a flag: the value itself is the key).
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
  component that names its whole record (`|props|`) reads `(props.label)()`, and so does one that
  names the rest of it (`|{ kind, ..rest }|`: Solid 2.0's `omit`, D-052). A record of them is passed
  on with a spread, `<Base {...rest} size={3} />` (JSX's, and Solid 2.0's `merge`: the last of a
  name wins): its fields as they are, getters still, written out one by one where the view's props
  are annotated (`label: rest.label, size: || 3`), so attributes may add some, or else Roc's record
  update (`{ ..rest, size: || 3 }`), which needs the component's props to be the record's type
  (`rocx check` adds a hint under the compiler's report there). A spread goes to a component written
  in rocx alone (a `view!`): the platform's take their own types, and a pure one values. Not getters: a prop
  named as an effect (`label!={word!()}`, an accessor, `|| word!()`, which the child types and calls
  itself), `children` (markup, whose holes are already live), and the props of the platform's own
  components (`<Show>`, `<For>`…). A pure component's (`view`) props are values, its call made where
  it is written; given one read from what changes, the call is a hole of its own
  (`Html.html_of(|| Heading.view({…}))`), made anew when it changes. That is a choice (D-053): patched
  in place, as Solid patches a component, it would take getters read in its holes, which a pure
  function can't call and `Html.to_str` can't run, so every call of it from Roc (an `expect`'s
  `Html.to_str(Avatar.view({ name }))`, an email's HTML) would break; and one that reads a prop in its
  body (examples/journal's do) would be made anew anyway. Solid's way is there: a `view!` is kept and
  patched (D-039), and a pure one may take an accessor (`left! : () => U64`) that its holes read,
  which keeps it (examples/quiz's `Countdown`). Made anew, it loses no state (it has none), only what
  the browser keeps in its elements: the focus, a field's text, where it is scrolled. A prop's expression runs where the
  child reads it: a context it reads is that place's, an async read in it waits in the child's hole
  (and, read in the child's body, is refused, as the component's own would be), and each read
  computes it again, as a Solid getter does (a memo shares it). A `.roc` component written by hand
  types its value props as getters (`label : () => Str`).
- **A flush runs what is dirty oldest first** (a memo before what reads it, an owner before what it
  made), then the effects whose apply is due, oldest first. Both wait in a set with a heap beside
  it (`Pending`), so taking the next of D waiting is log D: a grid whose thousand boxes read one
  signal puts a thousand in the flush at once (sorting them all for each, as it did, made a scroll
  step of 2,560 boxes 170 ms; it is 8 ms).
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
  Two more of Solid 2.0's (D-052), each an effect whose `compute` first tells the runtime its options
  (`Host.effect_options!`): `create_render_effect!(compute, apply)` (`createRenderEffect`) runs
  `apply` as soon as `compute` has answered, as the render does (made in a component, before its
  markup is built; in a flush, in the run, before the effects' applies), not after the flush; and
  `create_effect_with!(compute, { apply, error })` (`createEffect(compute, { effect, error })`)
  keeps a box for `error`: a `compute` that fails calls it with why (`Host.event_value!`), in the
  apply's place (after the flush, a handler, the last apply's cleanups first), and no `<Errored>`
  shows; if `compute` answers again before then, `apply` runs instead. On the server neither half of
  either runs (Solid's server runs a render effect's both): what a render effect's first apply
  writes is patched in as the page hydrates.
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
  stream, `GET /rocx/live?tab=…&c=<url>…`; two subscribers to one channel share it. The stream says
  its id first (`event: hello`). When the set of channels changes, once the render that changed it
  is done, the hub tells the stream what it subscribes to now and what it dropped, in one post
  naming the stream (`subscribe`, `unsubscribe`: D-057), so the stream stays open and the route's
  `on_close!` hears `Dropped`; a change made before the stream has said hello is told once it has,
  and with nothing left to subscribe to, the hub tells the stream, then closes it. A stream that
  never says hello (an older server), or a change refused because the stream has gone, is opened
  again with the set as it is. When the stream drops, it opens it again after 0.5 s, doubled each
  time up to 30 s, starting over once a stream has stayed up 10 s. A new subscriber to a channel
  the stream has open asks the server for its resync. `Endpoint.say!(channel, said)` (from a handler) goes, with the frame's other
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
  `text/plain`, that no handler prevented, is sent with `fetch`: its fields URL-encoded,
  `accept: application/json`, `x-rocx-submission: 1`. A form with files (`enctype="multipart/form-data"`, D-054) is sent as the
  browser's `FormData`, its files and all; its input is its fields URL-encoded, a file's its name. A
  form whose URL is a known endpoint's with fields after it (`Endpoint.with_fields(endpoint, { id
  })`, Solid Router's `action.with`: `/todos/toggle?id=7`) is that endpoint's: the URL's fields come
  first in its input, as the server reads them, before the body's, with JavaScript or without. The
  submissions to each URL are a list, a
  source computations read (`Host.submission!`, the latest; `Host.submissions!`, all): each pending,
  then the answer's status and body (status 0 and why with none). `x-rocx-redirect` (an endpoint's
  own redirect, which `Endpoint.respond!` gives the runtime as 200), or a redirect fetch followed,
  sends the browser there. The latest one forgotten (`clear!`), there is none until the next, nor
  the flash. Without a submission in the browser, `Submission` reads the flash. A form's fields are
  read by the endpoint's body's types (D-038, `FormBody`), in the browser as on the server: the
  contract's reader (`Endpoint.remote` makes it, `Endpoint.form_of` gives it) goes with the
  submissions `use_submission!` and `use_submissions!` make, so `input!` and `pending_inputs!` of a
  form the runtime sent are the arg the endpoint reads.
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
  cleared and runs again, its last value shown meanwhile; or, when the answer says which in
  `x-rocx-revalidate`, which its handler's `Router.revalidate!(keys)` writes, only those whose URL is
  a key or begins with one and a `/` or a `?`, Solid Router's revalidate keys; `[]`, none, and the
  submission is done at once), and marks it done in the run of the last
  one to have its answer (or fail, or go), so what reads both sees the server's new data and the
  submission's end in one flush: the optimistic value gives way with no frame of the old data
  (meanwhile `is_pending!` of the memos read again is true). A
  refusal (any other status, or none) is done at once: the input isn't applied any more, and the
  value is the server's again, the refusal in `error`. Several may be on their way, each answered on
  its own; an input still on its way is applied to the data read again, so applying one should be
  idempotent (a card's day, not one more). On the server, there are no submissions: `all!` is the
  flash or none, and nothing is applied, so the page hydrates as rendered. The endpoint's contract
  (`Generated/Api`, D-037) types its submissions in both copies of the app: `use_submissions!(Api.post_move({}))`
  is a `Submissions(Move, Str)`, with nothing for a component to say. `retry!` (Solid's) sends one
  again, by its id or the latest, with what it sent: the same submission, pending again. In a
  handler, `Router.revalidate!(keys)` reads those reads again itself. An action whose arg has a
  top-level field holding the URL of a file the page has (`fileOf(url)`: one `on:drop.files`,
  `on:paste.files` or `on:change.files` gave), or a list of them, is sent as a form with files: each
  file a part of its field's name, the other fields as a form's; its input stays the JSON, so a
  pending input's file is its URL, which an `<img>` shows while it is on its way.
- **`create_optimistic!`** (Solid 2.0's `createOptimistic`, D-054): a signal whose value is a
  memo's (`|| Endpoint.get!(board)`) until a handler writes it. The write is held by a transition
  the runtime opens as the handler's writes apply, and keeps open for the rest of that task, so the
  submissions sent meanwhile join it (its actions, the form its `submit` sends); once they are all
  done (a result after its reads are read again, a refusal at once), the transition's writes are
  undone in that same flush, so the server's data takes the value's place with no frame of the old;
  with none sent, undone at once. Several held: the latest still held shows. The D-030 memo over
  `pending_inputs!` stays the way for many submissions on their way at once, each applied to the
  server's latest data; `create_optimistic!` for a value a handler knows.
- **The flash**: on the server, `Server.flash!` takes the flash a plain form's post came back with
  from the server's memory, by the id in the `rocx-flash` cookie, and the host notes what the page
  read (`Host.flash!`), leaving out the fields the page has as `<input type="password">`. The page
  carries it in `<script type="application/json" class="rocx-flash">`, before the answers, which
  hydration reads and takes out, so the browser's first render is the server's. Each platform has
  its own `FlashStore` (the module `Server` keeps and reads flashes through); renderToString's
  (the tests') reads the flash from the cookie itself. `Html` never writes a `value` into an
  `<input type="password">`.
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
- **The head's other elements** (`<Meta>`, `<Link>`, `<Style>`, @solidjs/meta's, D-054): rocx's
  tags, as `<Document>` is (no import; a module of that name is a component instead), written as a
  `<meta>`'s, a `<link>`'s and a `<style>`'s are (holes and all; `<Style>`'s CSS static, as written).
  Each is `Html.document_head(element)`: a hole that renders nothing where it is, whose run computes
  the element's attributes and tells the runtime its markup, `data-rocx` on it, and its key
  (`Host.head!`): a `<Meta>`'s `name` (or `property`), `http-equiv`, `charset` or `itemprop`, with its
  `media`. They are in `<head>` in the order of their first runs (a layout's before its page's), a
  later one with an earlier's key in its place (a page's description over its layout's), while
  their holes are there. Rendering as a server would, they go before `</head>` (`Runtime.headed`,
  signals.rs's `headed`), after the title; in the browser, after a flush in which one changed, the
  head's `[data-rocx]` elements (but `<title>`) are made to match, one equal to what is there kept
  (`isEqualNode`: hydrating, the server's; a stylesheet isn't loaded again), one that differs
  replaced, one more added at the end, one fewer taken out. The plugins' scripts go before
  `</body>`, so nothing else of the host's is in `<head>`. A `<meta>` written in the layout's own
  `<head>` isn't one of them: give a default with a `<Meta>` in the layout, and a page's takes its
  place.
- **JSON.** What crosses as JSON (an endpoint's body, result and events, `Browser.call!`'s
  argument) is written with `Json.to_str_try`, so
  an `F64` goes as a number; one JSON can't write (NaN, an infinity) fails the call (an endpoint's
  result is a 500 that says so). Their where clauses read `Json.Encodable(e)`. The builtin `Try`
  has no `encoder_for` or `parser_for` on this Roc, and nothing outside the builtins can give it
  one: `rocx check` adds a hint under the compiler's report, naming the tag union to write instead
  (`[Ok(a), Err(e)]`, read by a `match` as a `Try` is). The compiler declares both for `Try`, but
  doesn't find them (an app's own `Outcome(ok, err) := [Ok(ok), Err(err)]` with derived codecs
  writes `{"Ok":5}`): reduced in `test/compiler-bugs/try-json-codec` (D-054).
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
    so they are in every prerendered page. **Navigation in place** (D-040) has no copy of a region
    in the wasm either: a navigation fetches the page's document, as the server answers it or as
    the export wrote it, and takes its regions from there (`keepingRegions` over the fetched
    `<body>`).
- **RCDATA**: inside `<title>` and `<textarea>` the HTML parser reads everything as text, comments
  too, so the server writes their holes without comments, and hydrating builds the element's
  text anew from the markup (its holes bound to the text nodes it makes; not a patch), the server's
  text checked against it.
- **Under a base** (`Runtime.load(source, { base })`, `/rocx/` for a copy at
  `example.github.io/rocx/`), a URL Roc gives that begins with `/` (an endpoint's read, a fetch's,
  a stream's) is asked for under it, and `Router.location!` takes it off the page's path, so the
  browser sees `/rocx/syntax` as the server sees `/syntax`.
- **Navigation in place** (D-040, phase 1; `spike/client-nav/DESIGN.md` has the design and its
  phases). `Generated/Root` calls `Router.app!` first: the build's id (on every page's bootstrap,
  `data-build`, which the host writes) and the route table, JSON (each page's path and its levels'
  code, root layout first: §18's ids, for wasm splitting later). As it hydrates the document, the
  runtime notes where the page is (`committed`: `Router.location!` reads it, a source, so what read
  it runs again when a navigation commits another), gives the history entry a key, takes the scroll
  over (`scrollRestoration` manual, each entry's kept in `sessionStorage`, a reload's put back), and
  listens on the document for clicks (`clicked`) and on the window for `popstate`. A click navigates
  in place when it is the main button with no modifier key, nothing prevented it, on an `<a>` (an
  SVG one too) with an `href` and no `download`, no `rel` with `external`, no `target` but `_self`,
  to this origin, under the base, at a path the table has a page for (`routeOf`), and not only to
  another hash on this page; `<html data-rocx-navigation="off">` turns it off (`"explicit"`: only a
  link with `data-rocx-link`). `navigate(url, { replace, scroll, pop })`, which a handler's
  `navigate!` queues with its writes and a submission's redirect calls (unless the visitor navigated
  since it was sent): `is_routing!` true; the levels' code reached (`pageCode(level)`: at once, while
  one wasm holds every page) as the document is fetched (`documentFor`: `accept: text/html`,
  `x-rocx-navigate: 1`; the last 8 kept, one under 10 s old used again, a submission's result
  emptying them); a redirect's address is where it ended (one that adds only a trailing slash is the
  link's); a document that isn't HTML, has no bootstrap or another build's (`appDocument`), or a
  fetch that failed (offline, a redirect to another site), is loaded instead (`location.assign`, or
  `reload` for back and forward). Then `commit`: its answers and flash seeded, the address pushed
  (or replaced, or, for back and forward, left), the location committed and the root run again in
  one flush, the document rendered anew (`settleDocument` with `arriving`): `<head>` reconciled
  with the document's (`reconcileHead`: a node equal to one there kept in place, others imported, a
  script inert, a stylesheet that goes removed once the ones that come have loaded, the host's
  elements left), `<body>` made anew with the document's regions, `<html>`'s and `<body>`'s
  attributes the app writes set to the document's (`attributesFrom`; one a page script set, as
  site.js's `data-hydrated`, stays). Nothing is asked of the server meanwhile (strictly, asking
  throws), and effects' applies wait: the scroll (the top, the hash's element, or the entry's
  kept), the focus (an `autofocus` element, the hash's target, or `<body>`'s start, taken with a
  `tabindex` it gives back), a live region of the host's that says the title, `rocx:navigated`
  (`{ url, ms }`; `rocx:navigate` as it started), then the effects. A newer navigation aborts one
  on its way. Phase 2's hooks: `readOnce` (a location read in a component's body), `inPlace` (a
  change of the query alone), `remakeRoot`, `afterNavigate`. **Under a base**, the URLs the
  runtime writes into the page (an `href`, `src` or `action` it builds or patches, `written`) get
  the base, as the static export gives the server's.
- **The page's own functions** (`Runtime.load(source, { effects: { vibrate(arg) {…} } })`, or
  `window.rocxEffects` for a page start.js wakes up) are what a handler's `Browser.call!(name, arg)`
  calls: queued with the handler's writes, so a handler that waits for the server and runs again
  calls once, and called once the flush after it has patched the page, given the argument parsed
  from JSON and `{ under }` (`under(url)`: a URL that begins with `/` under the site's base). A
  plugin's script (D-050: every page the server renders loads it before start.js) registers its
  effects on `window.rocxEffects`, named `<plugin>.<effect>`. An effect's apply is a handler too: what it calls runs at the end of the flush it is
  part of, once the page shows what it wrote. One that isn't there, or throws, is told on the
  console; a call while computing (an effect's compute among it) fails. Names beginning with
  `rocx:` are the runtime's own: `rocx:focus` moves the
  keyboard's focus to the element with that id (`Browser.focus!(id)`, nothing if there is none),
  once the page shows what the handler wrote: from an effect's apply, `on_settled!(|| Browser.focus!(…))`
  focuses a field as its part shows.
- **`renderToString`** renders markup with `<html>` at its top as the server platform answers a page:
  `<!doctype html>` first unless the markup has one, then the flash the page read, if it did, the
  answers script, the plugins' scripts (`renderToString({ scripts })`, by URL) and the bootstrap
  just before `</body>` (`Runtime.documentOf`). Any other markup is an app's range,
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
  its element is on the page. `on:viewport` (`Html.on_viewport`, `["view","viewport",id]`) gives it
  what of the element's content shows, `Html.Viewport` (`top`, `left`: how far it is scrolled;
  `width`, `height`: what shows inside its borders; whole pixels), once the element is on the page,
  then each time it scrolls or changes size (a scroll listener and a ResizeObserver, taken off with
  the owner's cleanups), at most once an animation frame and only when one of the four changed. The
  server measures nothing, so a component renders a first view both agree on, and the measure
  replaces it.
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
- **Drags by touch and a pen** (D-055, `pointerDrag`): many browsers start no drag from a touch,
  so the runtime makes one: a pointer that isn't a mouse, pressed on an element that starts drags
  (a dragstart handler, `drag:data` or `drag:image`; and `draggable`, as the browser asks), held
  still a quarter second (it may move 8 px: a swipe scrolls, a tap clicks; `POINTER_DRAG`), starts a
  drag in the browser's own events, so D-029's drop targets and the app's handlers take it as one:
  dragstart on the element (which may call it off), then each animation frame drag, dragenter on what
  `elementFromPoint` finds under the finger (and dragleave on the one it left, after), dragover; on
  the lift, drop where a dragover's default was prevented (else dragleave), and dragend. They are
  `DragEvent`s carrying one `DataTransfer` (its `effectAllowed` and `dropEffect` the runtime's, as
  Chromium's made one ignores both; one of its own where the browser can't make one), bubbling and
  untrusted. A copy of the element (or of `drag:image`'s) follows the finger in the top layer, held
  where the element was taken; near the edge of a box that scrolls, or the page's, it scrolls,
  faster nearer. While it is held and drags, the element has no long-press callout and selects no
  text; while it drags, the touch scrolls nothing (a non-passive `touchmove` on the element, there
  before the touch starts); the browser's own drag, should a long press start one, is called off; and
  the lift's click doesn't come. A mouse keeps the browser's drag, which carries data and files to
  other windows.
- **What a drag carries and shows** (D-055): `drag:data={[(type, value), …]}` (`Html.drag_data`,
  `["dd","data",json]`; computed, `drag_data_of`, `["ddo",…]`) is put on the drag as dragstart
  ends, each by its type (a drag with none still carries `application/x-rocx`); `drag:image={id}`
  (`Html.drag_image`, `["dd","image",id]`) is what it shows: a copy of the element with that id
  (hidden or not, its ids taken off, `data-rocx-drag-image` for the app's CSS), put just after it so
  what styles it there styles the copy, held at the share of it the element was taken at:
  `setDragImage` for the browser's drag, and under the finger for the runtime's. `on:drop.data`
  (`Html.on_data`, `["on","drop",id,".data"]`) gives every piece a drop or a paste carries but its
  files (`Html.DragItem`: `type`, `value`); `on:drop.files`, `on:paste.files` and a file input's
  `on:change.files` (`Html.on_files`) give its files (`Html.File`: `name`, `type`, `size`, `url`),
  each read by a `blob:` URL the runtime keeps (`runtime.fileOf(url)`, which an action posting a form
  field with that URL sends as the file: D-054) until the element's owner goes, when it is revoked.
- **Where the pointer is, whether the page shows** (D-055): `on:pointermove.point` (`Html.on_point`,
  `["pt",event,id]`) gives `Html.Point`, shares of the element's box (`x`, `y`, 0 to 1, to
  thousandths, sent as whole thousandths); a move (`pointermove`, `mousemove`, `touchmove`) runs it
  at most once an animation frame, with the latest place; on `<Document>` and `<Window>`, shares of
  the viewport. `on:visibilitychange.visible` (`Html.on_visible`, an `.checked`'s handler) gives
  whether the page shows (`document.visibilityState` isn't `hidden`).
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
  moved plays the difference back with `translate`, at the transition's pace (FLIP), and one whose
  size changed with it `scale` too (`glideFrames`), from its old size, about its own
  `transform-origin`, so its old box is exactly where it starts (what is inside is scaled with it as
  it glides: a card into a narrower column has its text squeezed for the glide, rather than laid out
  again each frame). An element with
  a key (`["k",…]`, or `["ko",…]` computed) that appears in the flush as one with the same key went
  (taken away, or on its way out) is that one moved: it glides from the other's box, its transition
  in doesn't play, and the other, if leaving, goes at once. An element inside another that glides
  moves with it; a glide playing is stopped and the next starts from where the element is seen.
  One that glides out of a box that scrolls or clips (`overflow` other than `visible`, `contain:
  paint`) into another (a card into another column's scrolling list), where what clips it now would
  hide where it was, is lifted for its glide (`lift`): fixed where it lands, above the page, a
  hidden stand-in of its size keeping its place, so nothing cuts it off on its way; it stays where
  it is in the document, so its styles and handlers are its own, and is put back, its own style as
  it was, when the glide ends or another starts. A lifted one is clipped as the boxes it leaves and
  lands in clip it (`clip-path`, from what showed of it where it was to what will show where it
  lands), so one whose new place is scrolled out of sight slides under its box's edge. Inside a box
  that makes fixed elements its own (a `transform`, a `filter`, `contain`, a container's box:
  `holdsFixed`), it is lifted into the top layer (a manual popover, its own look kept over the
  popover's), which no box holds or clips; where the browser has no popovers, it is placed where it
  is seen to be, inside that box. A glide within one box, or one whose old place the
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
(`Nested.rocx`: a `<For>` in a `<For>`'s row and in a `<Show>`'s child); the scroller
(`Scroller.rocx`: ten thousand rows in a box, `<Repeat>` rendering those `on:viewport` says show,
rendered on the server, hydrated, then scrolled and made taller, the rows still in range kept); the fades (`Fades.rocx`:
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
(`Form.rocx`); value props, getters (D-039), given in a hole, outside one, in a `<Show>` and in a row, read every way a component may, an accessor, and props passed on (`{...rest}`, D-052) (`Props.rocx`); `<Title>`s
(`Titles.rocx`); D-054's (`Actions.rocx`: `<Meta>`, `<Link>` and `<Style>`, revalidate keys, a
form's fields given ahead of time, `retry!`, `create_optimistic!`, a form with a file and an action
given a file's URL); channels (`Channels.rocx`: two feeds on one org's news, a third on another's); a
planner (`Planner.rocx`: cards dragged between days, moved optimistically with `use_action!` and
`use_submissions!`, gliding); the drags (`Drags.rocx`, D-055: a card with `drag:data` and
`drag:image`, lists that take it, one that reads what a drop carries, one that takes files, an area
that says where the pointer is, a box that scrolls, and whether the page shows); and D-052's (`Untracked.rocx`: `untrack!` in a hole, a memo and a
body, `latest!`, a component given constants beside one given what changes, and, built with `--dev`
from a copy, the warning of a read in a body, once for two runs of its place; `RenderEffects.rocx`:
an effect, a render effect and an effect with an error handler noting their applies, mounted); and
D-053's (`Control.rocx`: a `<Show>` each way, keyed and not, and a `<Switch>` of a Bool's, a
narrowed and a keyed `<Match>`, each part with a counter of its own, rendered as the server would
from four queries and hydrated strictly: an equal value keeps every part, a new one makes the keyed
parts anew, a `<Switch>` changes part when another `<Match>` holds first); stores (`Stores.rocx`: a filter, a count and a list
of todos in one store, each part a hole of its own, a `<For compared>` of the list, two writes in one
handler, a handler reading it, `Store.of` over a memo, and a grid of four hundred selections of one
store: which holes each write patches, how many selections it runs, and nothing left allocated); and
a thousand rows twice (`Rows.rocx`: a plain `<For>` and a compared one, one item changed and every
item: runs, patches and allocations).
In Chromium, against a scripted server (a scripted `/rocx/live` too): what shows while answers come, what a click
patches, failures and retries, rows kept and moved, rows and parts that stay until their
transitions are over (and none with less motion asked for), hydration without a request, a tampered document's `<body>` rendered again (and strictly, a throw), the
host's `data-rocx` elements passed over, `start.js` under `/rocx/` asking for nothing outside it,
an effect run after hydration and again after its cleanup (none on the server), a timer and a
listen stopping with their component, a flash hydrated as the server rendered it, a form sent with
`fetch` (pending, refused, answered, redirected), a component given a value prop (in a
hole, outside one, in a `<Show>`, in a row) kept, its signals with it, and only what reads the
prop patched (in its body, once; in a pure lambda, by its hole; in an effect and a handler, as they
run), props passed on with `{...rest}` kept live, static holes (a hole whose reads are untracked, a
component's holes and attribute given constants) written without comments and taken as text,
strictly, and never patched, a dev build's one warning, said where, rows made once, the document's title kept to the last `<Title>` there (hydrated strictly, the
server's `<title data-rocx>` first in `<head>`), a `<NoHydration>` the browser's wasm hasn't (its
nodes kept, strictly and after `<body>` is rendered again; the browser's build rendered against
the page's answers and regions, byte for byte), one channel stream for three subscriptions (one
refused), messages in order, a frame's sayings in one post, a late subscriber resynced without a
reconnect, one reconnect for a change, waits that double after drops, a host with no server asked
once, a card dragged to another day (a real drag, CDP's `Input.dispatchDragEvent`) shown there before
the slow endpoint answers and kept while the board is read again, never shown where it was; two on
their way at once, the refused one back with its refusal; a list with no drop handler taking no drop;
glides (none with less motion asked for), one into a narrower box in a transformed one scaling from
its old size, in the top layer, under its new box's edge; a drag by touch in Chromium and in Gecko
(real touch input: held, it starts, its image under the finger above the page, the page still; it
comes to, leaves and drops on a list, carrying `drag:data`; a swipe starts none; a box scrolls under a
finger at its edge), a tap's click, a mouse's drag carrying `drag:data` and showing `drag:image`, files
dropped and read by their URLs, `.point` and `.visible`; a link's click taken over; and no allocation left behind,
after many runs that waited (refreshes, new pages, memos made again: `Upstream.rocx`) too; an
`<Errored>`'s retry reading again the failed read a memo it shows reads; and D-054's: the head
elements rendered before `</head>`, kept hydrating strictly, following their holes and gone with
their part; a result reading again only the reads its answer names (or none), a handler's
`revalidate!` its own; a form's fields given in its URL; a refused submission tried again; an
optimistic count shown at once, held while its action is on its way, then the server's with no
frame of the old, back at once when refused or with nothing sent; a form with a file and an action
given a file's URL sent as multipart.

`test/navigation.test.mjs` (D-040): `test/nav`, an app of routes (a layout with links of every
kind; home, A with a `<Title>`, a timer, an effect and a channel; an item; a guarded page), its
server half rendering each document by `renderToString` and a scripted server serving them, slowly,
redirected, refused or crashed when told to. In Chromium, strictly: a click renders the next page
without a load (a value on `window` survives), its document fetched once as a navigation and
nothing else asked, its title, `<Title>`, head, regions and attributes the document's, the
stylesheet kept (and one that differs swapped, the new one in before the old one goes), announced,
the focus at `<body>`'s start, the page a load renders (byte for byte outside the host's elements); every opt-out left to the browser (modifier keys, `target`, `download`,
`rel="external"`, another origin, a path no page has, a file, a place on this page, `off`,
`explicit`); `navigate!` from a handler that waits for the server, once; `navigate_with!`'s replace;
back and forward with the scroll restored and the document used again within 10 s and fetched
after; a hash, `noscroll`, a reload's scroll; `is_routing!` while a slow document is on its way, and
after one overtaken; a middleware's redirect landing with its address; a text 401, a crash, a refused
fetch, another build and a redirect to another site each loaded; the old page's effects, timer and
channel stopping, the new page's starting, no stream opened again for the same channels; 200
navigations leaving no allocation behind; and all of it under `/rocx/`, the URLs the runtime writes
under the base.

## Not yet

- **Navigation in place, phase 1** (D-040): the whole page is made anew on each navigation, its
  layouts too (a sidebar's scroll, an open menu, a layout's signals); a change of the query alone
  fetches the page's document like any navigation; no `<A>`, `<Navigate>`, prefetch or View
  Transitions yet (phases 2 and 3).
- **The rest of Solid 2.0's stores** (D-053): derived stores (`createStore(fn, seed)`,
  `createProjection`: a memo is the derived read), `createOptimisticStore` (D-030's optimistic memos
  cover actions), `reconcile` and `storePath` (a new list written whole, and Roc's record update, do
  their work). A write runs every live selection of its store, where Solid's touches only the paths
  written: four hundred take about half a millisecond a write (measured in D-053). Within a
  row, a changed item runs all of the row's holes; a row that wants finer reads its item by parts
  (`Store.of(todo!).get!(|t| t.done)`).
- **The dev warning sees calls of accessors** in a component's body (`count!()`, a prop's getter):
  one a helper makes (`total!(items)`) isn't said, nor one at a `<For>`'s row's top (made once too).
- **The rest of Solid Router's actions and Solid 2.0's optimistic values:** `createOptimisticStore`
  (D-053's stores have no optimistic kind yet); `.with` binds a form's fields (`Endpoint.with_fields`), and an action's
  values are bound by a closure; a revalidate key is a URL or a URL's beginning, not a query's name
  and arguments; an optimistic write is a value, not a function applied again to the source's new
  value; a file is read whole with the request's body (`--max-body`), not streamed as it comes.
- **Drags by touch:** a keyboard's drag (a sensor that moves a thing with the arrow keys) isn't
  the platform's: an app gives keyboard users another way, as the docs' planner's menus do. The
  runtime's drag by touch stays in its page: another window or program can't take it (a drag into
  the page from elsewhere is the browser's own, and comes as one).
- **Moves that resize:** what is inside an element that glides to another size is scaled with it
  for the glide (its text squeezed or stretched, FLIP's way), not laid out again each frame;
  counter-scaling its children (as Framer Motion's layout animations do) would cost a pass a frame
  over everything inside. Where the browser has no popovers (Chrome before 114, Safari before 17,
  Firefox before 125), one lifted inside a box that makes fixed elements its own stays clipped by
  that box.
- **`Try` across the wire:** the builtin has no JSON encoder or parser on this Roc, though it declares
  them (`test/compiler-bugs/try-json-codec`, D-054); a tag union stands in.
- **The rules a component must keep:** read async values in holes, not in its body, and write
  signals only in handlers (an effect's apply, a cleanup and a timer's tick are handlers); the
  runtime refuses the first.
