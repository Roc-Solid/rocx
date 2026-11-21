# Design: drop islands (pages are Solid components, `program` is generated)

> A design spike, 2026-11-20, branch `native-server`. Line numbers refer to the working tree as of
> that day. It assumes the change being made alongside it has landed: `program.actors` is gone
> (`Host.isolated!` takes a boxed closure), and so is `stream!` (`respond!`'s feed is a closure
> `{ send! : Str => Bool, sleep! : U64 => {} } => {}`).

Today rocx has two worlds. **Pages and layouts** are html's static `Html`, rendered to a string by
`Routes.html` (src/routes.mjs:234-235). **Islands** are Solid-style components under one root
(site/Islands.rocx:23-50). The host renders them into the `<rocx-island data-island>` placeholders it
finds by scanning the page (server/host/src/signals.rs:141-171, 457-483; http.rs:251-258), and
the browser hydrates them (web/runtime.js:1374; site/static/site.js:7-37). After this change there
is one world, SolidStart's model:

- A route returns a page, and the page is a component tree: layouts, then the page, then components.
- The host renders the whole tree reactively, and the browser hydrates the whole document.
- A server function is a route that `respond!` answers.
- `rocx build` writes `program`.

## 1. Answer and host flow

The platform requires:

```roc
program : {
	respond! : Str, Str, Str, Str, Str => Server.Response,
	jobs : List({ name : Str, run! : Str => Try({}, Str) }),
	crons : List({ name : Str, schedule : Str, job : Str, input : Str }),
	migrations : List({ name : Str, sql : Str }),
}

# in the shared `Server` module (§2)
Response : { status : U16, headers : List({ name : Str, value : Str }), body : Body }
Body : [Text(Str), Page(() => Html), Events(Events(Str))]
```

All three bodies have a status and headers: a 404 page, a `set-cookie` on a page, an event
stream's `cache-control`. So the variant is the body, not the whole answer, and middleware keeps
working on one record (Q8). `respond_for_host!` flattens the answer for the glue, as it does today
(server/platform/main.roc:153-157):
`{ status, headers : Str, kind : U8, text : Str, page : Box(() => Str), feed : Box(Loop) }`. A page's
box is `|| Html.serialize!(view!())`: the mount `roc_signals_mount` does today (main.roc:254-255),
made once per answer. Each answer fills in only the boxes its kind uses. The others get a no-op box,
which the host releases (as `roc_drop_feed` does now, main.roc:169-170).

| body | what the host does |
|---|---|
| `Text` | What it does today (http.rs:275-314). |
| `Events` | Whatever the other change makes it: the feed closure runs on a thread of its own. |
| `Page`, GET | 1. Begin a `Render` with the request's target, headers and start context.<br>2. Run `page` with `roc_run` in a guarded frame at the root scope.<br>3. Walk the JSON with `html()`. signals.rs:297-441 is unchanged: every hole runs once, a memo is computed when it is made, `<Loading>` renders what is inside it, and a failure renders the nearest `<Errored>` as `<!--errored:failed-->`.<br>4. Write `<!doctype html>` and the HTML. Before `</body>`, add the answers script (signals.rs:443-447) and `<script type="module" data-rocx src="/rocx/start.js">`.<br>5. Release everything the render made (`release_all`, signals.rs:108-115). |
| `Page`, HEAD | No render; the box is released. |
| `Page` that crashes | A 500, with the message under `--dev`. Islands could fall back to "the browser renders it" (signals.rs:149-152); a whole page can't. The page's box stays in the ring that `respond` allocated, which is freed if the render crashes, as a feed's ring is (roc.rs:347-369). |

A failure that nothing in the page catches reaches the generated root's `<Errored>` (§3). The page
is then `+error.rocx` with status 500.

When a component calls a server function during a render (`echo!(draft!())`), the function's own
route answers it in-process, synchronously (§5). The answer is recorded (`roc_record`,
signals.rs:670-674) and seeded into the browser. Nothing on the server waits, so `<Loading>` never
shows its fallback in SSR. Streaming SSR, which sends the shell and then each boundary as it
resolves, is a follow-up.

**Entry points:**

| today | after |
|---|---|
| `roc_respond` | Stays. Its answer gains `kind`, `text` and `page`. |
| `roc_stream`, `roc_drop_feed` | Whatever the other change makes them. |
| `roc_signals_mount` (main.roc:254) | **Removed.** The mount is the `page` box in the answer. |
| `roc_signals_run` (main.roc:258) | **Stays**, renamed `roc_run`. It runs any `Box(() => Str)`: a page's mount, holes, memos, fallbacks. |
| `roc_signals_answer` (main.roc:265) | **Removed**, because a server function is a route (§5). The host's fallback after a 404 (http.rs:233-250) and `signals::answer` (signals.rs:174-179) go with it. |
| `roc_init`, `roc_background*`, isolated | Unchanged. |

Hosted functions, new or changed:

- `roc_call` on the server stops failing (signals.rs:632-637) and calls the function's route in-process.
- `Host.serve!`, `Host.serving!` and `Host.context!` are new (§5).
- `Host.location!` is new (§4).
- `Host.status!` is new, for `<HttpStatusCode>` (SolidStart's name).

These parts of signals.rs are deleted: `Scope.outside`, the `island` node, `fill`, `placeholders`,
and `wanted`/`rendered` (signals.rs:33-34, 79-80, 141-171, 365-374, 449-483). `render` becomes
`render_page(page, request)`.

## 2. One Html, and where the HTTP types live

A Roc package can't import a platform, and `Server.Response` now holds the platform's `Html`. So the
`html` package can't keep `Response`, and with it go `Middleware` and `Endpoint`, which mention it.
**Decision: the `html` package is deleted.** Its modules become modules that both platforms share,
as `Html`, `Solid` and the others are today: their source is in web/platform, and `syncSignals`
copies them into server/platform (server/build.mjs:78-90, to be renamed `SHARED_MODULES`). Roc
compiles only what a program reaches, so a shared module that only the server uses (`Middleware`)
costs the browser's wasm nothing.

| type | where it lives | why |
|---|---|---|
| `Html` | the shared `Html`, extended (below) | One markup type for pages and components. |
| `Server.Request` | the shared `Server` | html's full record (method, path, query, headers, body; html/Server.roc:10) replaces the platform's `{ path, headers }` (web/platform/Server.roc:16). A server function's `Event` mentions it, and components compile on both platforms. |
| `Server.Response`, `Problem`, helpers (`redirect`, `cookie`, `with_cookie`, `form_json`, `encode_segment`…) | the shared `Server`: html/Server.roc merged into web/platform/Server.roc | `Middleware` and `Endpoint` need them. The browser never builds a `Response`. |
| `Middleware` (html/Middleware.roc:17) | a shared module | Only the server uses it. |
| `Endpoint` (html/Endpoint.roc:14) | a shared module | Both sides use it: `remote`/`send!`/`listen!` in the browser; `local`/`run!`/`respond!`/`stream!` on the server. |
| `Events` (html/Events.roc:21) | a shared module | The browser's copy of `Api` types `Endpoint.listen!` against `Events(event)`. |
| `Router` (new) | a shared module | Location and params, on both sides (§4). |
| `Signals`, `Island` | removed (step 7) | |
| `Db`, `Job`, `Cron`, `Email`, `Live`, `Log`, `Random`, `Tcp`, `Time` | the server platform only | A page that imports one fails to compile in the browser's copy, which is the point. Only a server function's body may use them, and rocx drops that body and its imports from the browser's copy (transpile.mjs:762-780). |

**Merging the two `Html`s.** The platform's `Html` lacks what pages use:

- raw text for `<script>` and `<style>` (`Source`, html/Html.roc:13, 41-44);
- `<!doctype html>`;
- static `attr_unless_empty` and `class_if` (html/Html.roc:17).

The plan:

- Add `Raw(Str)` (`Html.source_text`; `rocx lint` still refuses it in hand-written code, bin/rocx.mjs:269-285), `Doctype`, a static `Optional(Str, Str)` and a static `ClassIf(Str, Bool)`.
- Serialize raw text as `{"t":"raw"}` and the doctype as `{"t":"doctype"}`. Teach the native walker and runtime.js to render, build and adopt them. Adopting a raw node takes the element's text without comparing it.
- Keep a pure `Html.to_str : Html -> Str` for static trees (an email's HTML, `expect`s). A computation inside the tree is an error.
- Remove `Html.island` (html/Html.roc:70-74).

## 3. Composition

Route files are component modules: they have `import pf.Html` and define `view!`.

```roc
# routes/+layout.rocx: the document
view! = |{ meta, children }| {
	path = Router.location!({}).path
	<>
		<!doctype html>
		<html lang="en"><head><title>{meta.title}</title>…</head><body>…<main>{...children}</main></body></html>
	</>
}
# routes/blog/[slug]/+page.rocx
meta = { title: "…", description: "…", toc: [] }
middleware = Middlewares.member              # optional: guards the GET, its endpoints, its server functions
view! = |{ params }| <Post slug={params.slug} />
# routes/+error.rocx
view! = |{ status, problem }| …
```

`Generated/Root.roc` belongs to both copies. Its `view!`:

1. reads `Router.location!` and matches its segments, with the code `Routes` has today (routes.mjs:181-201);
2. renders `Html.component(|| RootLayout.view!({ params, meta: BlogSlugPage.meta, children: [Html.component(|| BlogSlugPage.view!({ params }))] }))`, inside an `<Errored>` whose fallback is the error page with `<HttpStatusCode code={500}/>`;
3. renders the error page with `<HttpStatusCode code={404}/>` when no page matches.

An app with no root layout gets a default document: SolidStart's default `document`.

**How the inputs reach components:**

- **Params** are props (`{ params }`), decoded from the location the same way on both sides. Layouts get the page's params as well. A layout that reads none stays polymorphic, because Roc's records are open.
- **The location** is `Router.location!() : { path : Str, query : Str }` (Solid Router's `useLocation`).
- **The request and the middleware's context** stay on the server. A component reads them through a server function, `server!(|{ request, context }, input| …)` (§5), whose answer is serialized into the page. SolidStart has the same rule for `getRequestEvent()`/`locals`. Page props never carry them, because whatever a page's body computes also runs in the browser.
- **Middleware**: a route file's `middleware` runs before the page renders, so redirects and refusals happen there, never inside a component. It also guards the file's endpoints and its server functions (§5).
- **Errors**: `+error.rocx` renders inside the root layout for a path no page has (404) and for a failure nothing caught (500).
- **`meta`** is the page module's value, which the generated code passes to the layouts, as it does today (routes.mjs:169-178).

What this means for the site:

- The layout's `request.path` becomes `Router.location!({}).path`.
- The footer's facts (`context.facts`, +layout.rocx:9, 40, 83-84) come from a server function, `Facts.facts!`.
- The members page reads `context.member` through a server function in its own route file.
- On /calls, the page calls `Endpoint.respond!` and `Endpoint.run!` while it renders (calls/+page.rocx:27-37). Those calls move into a server function; otherwise they would run in the browser when the page hydrates.

## 4. Hydration

**What the browser receives:**

- the document: a doctype, then `<html>`;
- comment markers around computed holes only (static holes are plain text, §7);
- the answers script and `/rocx/start.js`, both marked `data-rocx`.

`start.js` loads the runtime with `Runtime.load(fetch("/rocx/app.wasm"))`, calls
`runtime.hydrateDocument(document)`, and dispatches `rocx:ready` with the runtime. The site's
inspectors hook in there instead of searching the page for islands.

**Finding the root.** `hydrateDocument` reads and removes the answers, as `hydrate` does today
(runtime.js:1126-1129). It then runs the wasm's root, `main!`, which is the generated `Root.view!`,
and adopts its markup against `document.childNodes`:

- `doctype` adopts the DocumentType node, and `<html>` adopts `documentElement`.
- The cursor skips `[data-rocx]` elements: the host's scripts and the dev reload script (http.rs:139, 307-312).
- There is no `<!--app-->` range, because comments outside `<html>` are fragile.

**Matching the route.** `Root` reads `Router.location!`. In the browser, `Host.location!` gives
`location.pathname` plus `location.search`, with a trailing slash dropped, as the host does
(http.rs:327-337). The same generated matcher then picks the component.

**When the DOM doesn't match.** A browser extension may add a node, or the HTML parser may repair
the markup (a `<p>` inside a `<p>`). The runtime then warns and renders `<body>`'s children again. It
leaves `<head>` alone, because re-rendering it would run its scripts again and flash its styles. In
`strict` mode, which the tests use, it throws instead. Today a mismatch re-renders only the island
(runtime.js:1440-1446), so this is coarser. Per-component ranges can narrow it later.

**Answers** keep the format they have today: `[[name, input, answer]]` in
`<script type="application/json" class="rocx-answers">`, with `<` escaped (signals.rs:443-447).

- An answer is the function route's 200 body, byte for byte what the browser would get by asking.
- A failed call is not recorded. The browser runs the inside of a failed `<Errored>` again
  (runtime.js:1102-1110).

**Code size.** One wasm holds every route: pages, layouts, all components, the docs' listings
(site/Generated/Sources.roc, 114 KB of text) and the highlighter (site/Ui/Highlight.roc).

- Today the islands' wasm is 287 KB, or 72 KB with brotli (site/build/facts.txt).
- The pages add about 150 KB of `.rocx` source, and Roc's code for markup is larger than its text.
  Expect 2–4×, and measure it first (step 6a).
- Hydrating also runs every component again in the browser, including the highlighter over every
  listing. Measure per-page hydration time alongside the size.

One wasm per route is rejected:

- Roc can't link wasm modules over one heap, so each module would carry its own copy of the shared components and the glue.
- Client navigation would have to swap modules, losing state.

Mitigations, in order:

1. static holes (§7);
2. a fully static subtree as one constant node;
3. `<NoHydration>` (Solid's name). Its children are compiled only into the server's copy, as `server!` bodies are. The browser's copy holds a placeholder that hydration skips, which keeps prose and listings out of the wasm (Q3).

**Client-side navigation (a follow-up):**

- `Router.location!` becomes a signal.
- Same-origin link clicks are intercepted and use `pushState`.
- `Root` matches again in one hole per layout level, so layouts stay mounted.
- The new page's server functions are asked over HTTP, so its `<Loading>`s show.
- `<Title>`, and scroll restoration.

Nothing new is downloaded, because all the code is already in the wasm. A `<NoHydration>` subtree
would be fetched from the server.

## 5. Server functions as generated routes

**URL:** `POST /rocx/call/<module>.<name>`, as today, for example `Demos/Echo.echo`. A function in a
route file is named after the file's module, for example `Generated/MembersPage.who`. The generated
`Routes.respond!` answers it, using the generated `ServerFunctions` module (now under Generated/,
server copy only):

- a method other than POST gets a 405;
- an unknown name, a 404;
- input it can't read, a 400;
- the answer is JSON, with status 200.

`rocx routes` lists each function:
`POST  /rocx/call/Demos/Echo.echo  site/Demos/Echo.rocx  -`.

**Middleware.** The app's default runs around everything, as `with_default_middleware!` does today
(site/server.roc:38-40). A function defined in a route file then runs behind that file's
`middleware` as well: the same rule as the file's page and endpoints, so one place says what guards
a route. A function defined elsewhere, such as in site/Demos, runs behind the default only.

**Arguments:** `server!(|{ request, context }, input| …)`, where
`Server.Event(c) : { request : Server.Request, context : c }` and `context` is what the middleware
handed on. Today the arguments are `|request, input|` (web/platform/Server.roc:35-41).

**A direct call during SSR versus HTTP from the browser.** The transpiler still writes
`Server.local("Demos/Echo.echo", impl)` in the server's copy and `Server.remote(…)` in the browser's
(transpile.mjs:290-309, 228-231). The function that `Server.local` returns does one of two things:

- **The host is answering this function's route** (`Host.serving!() == name`, set by the generated
  route with `Server.serve!(name, context, run!)`): it runs
  `impl({ request: Server.request!({}), context: Json.parse(Host.context!({})) }, arg)`.
- **Anywhere else**, such as a component calling it while a page renders: it calls
  `Host.call!(name, Json.to_str(arg))`.
  - On the server, `roc_call` enters `roc_respond` again, in-process. The request is
    `POST /rocx/call/<name>`, with the page's headers (cookies included), the start context, and an
    `origin` header set to the host. A 200 body is recorded and returned. Any other answer fails
    the computation, and `<Errored>` shows the status and text (for example `401: …`).
  - In the browser it is the request it is today (runtime.js:34-39).

So a call during SSR is the HTTP call, made in-process: the same middleware, the same context and
the same answer bytes. The cost is the middleware running once more per call. That is nothing for a
cookie check, but a Postgres query if the middleware looks up a session (Q2).

**Why the context crosses the host as JSON.** Roc can't safely carry a value of a type the platform
doesn't know through the host:

- A box read back at another type corrupts memory.
- A function that ignores its context leaves that type unconstrained.

JSON is what inputs and answers already use. The generated route encodes the context (it must be
`Json.Encodable`), and the implementation parses it into the type it annotates. A mismatch is a 500
that names the function, not undefined behaviour. Contexts are small: facts, a member's name.

## 6. The generated program

`rocx build <app>` writes these under Generated/:

- **Route modules, `Paths` and `Api`**, as today (routes.mjs:129-150, 252-306). `Api` has a server copy and a browser copy.
- **`ServerFunctions`**, server copy only. It now carries middleware.
- **`Root`**, both copies (§3).
- **`Routes`**, server copy:
  - A page's GET runs the route's middleware, then answers `Server.page(200, Root.view!)`.
  - Endpoints are as today.
  - `/rocx/call/*` goes to the server functions.
  - A path nothing answers is `Server.page(404, Root.view!)` for a browser, and text otherwise.
- **`App`**, server copy:

```roc
App := [].{
	program = |config| {
		respond!: |method, target, headers, body, started|
			Middleware.run!(config.middleware, Server.from_http(method, target, headers, body), (config.context)(started), Routes.respond!),
		jobs: [Job.handler(Jobs.welcome), Job.handler(Jobs.nightly)],   # found by rocx build
		crons: config.crons,
		migrations: [{ name: "0001_notes.sql", sql: m0001_notes }],      # migrations/*.sql, embedded
	}
}
```

With `--client <out>`, rocx build also writes:

- the browser's copy, as today (bin/rocx.mjs:96-113);
- its `main.roc`: `app [main!, answer!] { pf: platform "<web>" }`, with `main! = |{}| Root.view!({})` and `answer!` a stub answering 404;
- `reference.roc`: the server's copy of `Root`, with its server functions, built on the web platform for the byte-for-byte test (§8).

**Jobs** are found the way `server!` and contexts are (bin/rocx.mjs:136-139):

- It scans every `.roc` and `.rocx` under the app, except Generated/, build/ and dist/, for `^\t([a-z_][a-z0-9_]*)\s*=\s*Job\.define\(\s*"([^"]+)"`.
- A job must be defined inside its module's block (indented), so that `App` can name it (`Jobs.welcome`). If it isn't, the build fails and says so.
- Two jobs with the same name fail the build.

**Migrations:** `migrations/*.sql`, in the order of their names (Q5).

**Crons** stay in config: a schedule and an input are the author's choices, not something rocx can
find.

**What the author writes:** route files, components, `migrations/`, and:

```roc
app [program] { pf: platform "../server/platform/main.roc" }

import pf.Cron
import Generated/App
import Middlewares
import Jobs

program = App.program({
	context: |started| { facts: started },     # what --context-file gives the default middleware
	middleware: Middlewares.default,           # or Middleware.none({})
	crons: [Cron.every("0 3 * * *", Jobs.nightly, {})],
})
```

Roc records have no optional fields, so all three are always written; the simplest values are
`|s| s`, `Middleware.none({})` and `[]` (Q6).

## 7. Transpiler changes

- **One kind of markup module.** Every `.rocx` file with markup is a component and needs
  `import pf.Html`; `import html.…` is an error that points here.
  - The static mode and its refusals go, so `on:` and `key=` are allowed in pages and layouts
    (transpile.mjs:523-535).
  - `isComponent` (bin/rocx.mjs:129) goes.
  - Route files define `view!`.
- **Static holes.** A hole or attribute whose expression calls nothing named with `!` is static. It
  becomes what the page mode writes today (transpile.mjs:561-571, 721-724): `Html.text(e)`,
  `Html.attr`, `Html.flag`, `Html.class_if`, `Html.optional`, `Html.style_var`, `Html.join(e)`, or
  `(e)`. There is no closure and no `<!--x-->`.
  - This is sound in Roc. Reading a signal, a memo, an accessor prop or a context calls an effect,
    effects are named with `!`, and the compiler warns otherwise.
  - A pure expression can't change after the component has run. Solid is the same: a value read in
    a component's body isn't tracked.
  - Props named with `!` stay accessors (transpile.mjs:56-67).
  - The runtime already splits static text that the parser joined (runtime.js:1028-1035).
- **Doctype and raw text in components.** `<!doctype html>` becomes `Html.doctype({})`, and
  `<script>`/`<style>` become `Html.source_text`, using `rawText` (transpile.mjs:727-743).
- **Pure components.** A module whose `view` has no `!` (Ui/Code, Ui/Heading) is called directly,
  not deferred in `Html.component`: it can't use a context, because that is an effect. rocx build
  tells the transpiler which modules define `view` and which `view!`, as it already does for
  contexts.
- **`server!`.** The code it writes is unchanged, and it is now allowed in route files. rocx build
  records whether the defining module is a route file, for its middleware.
- **Islands.** `<Island>` and `Html.island` are errors.

## 8. Migration

### The site

- **site/Islands.rocx is deleted.**
  - Each island's props move into the page that renders that demo. For example,
    `<Todos first={[…]} />` goes where `{=Html.island("todos")}` was (components/+page.rocx:91).
  - Shared stores get their providers on the pages that share them: `<BagContext>` around the shelf
    and the bag on /components, and the picks and the tally likewise.
  - Placeholders with `data-flash` (calls/+page.rocx:64; components/+page.rocx:186, 279) become
    wrapper elements.
- **site/Demos** stay as they are, except for the new `server!` signature. The site.js and test
  selectors `rocx-island[data-island=…]` become each demo's own class.
- **Pages, the layout, the error page and Ui/\*** move to `pf.Html` and `view!` (`view` for the pure
  Ui components), and the layout follows §3. EscapeLab compares `html.Html` with `pf.Html`
  (EscapeLab.rocx:3, 48); it will compare escaping in text with escaping in an attribute instead.
- **site/server.roc becomes site/main.roc** (§6). site/client.roc and site/reference.roc become
  generated.
- **build.mjs:**
  - One `app.wasm`.
  - `measureClient` times `renderToString` of a page; the `ALONE` list (build.mjs:421) goes.
  - `sourcesModule`'s picks of Islands.rocx and server.roc (build.mjs:255-356) are updated.
- **site.js** stops finding islands and starts from `rocx:ready`.
- **Docs**, every page that mentions islands (the user asked to keep all docs current):
  - /components: "Islands: one app, many places" (components/+page.rocx:260-322) becomes "Pages are components".
  - /calls: server functions as routes, their middleware, SSR in-process, the `signals:` field (calls/+page.rocx:277).
  - /platform (platform/+page.rocx:106-176) and /platform/browser.
  - /routing: `view!`, the error page, middleware on server functions.
  - /tooling: what rocx build writes. /syntax: `on:` anywhere.
  - The layout's "islands" stat (+layout.rocx:38-41, 81-84).
  - README.md; web/README.md (lines 79-86: "Props for an island" goes); server/README.md (lines 136-153).

### The tests

- **test/transpile.test.mjs:** the page refusals of `on:` and `key=` become acceptances. New cases:
  static holes, doctype and raw text in components, and the `html` import error.
- **test/routes.test.mjs:** `Routes` (page answers, the `/rocx/call` branch, the 404 page), `Root`,
  `App` (jobs found, a job outside its module's block refused), and `rocx routes` with server
  functions.
- **test/e2e:** the fixture and the routes package import `html` (e2e.test.mjs:15; routes/main.roc:1).
  They become apps run with `roc test`, as `just test` already runs it on site/server.roc.
  **Decided in step 1:** test/e2e/routes is an app on the *server* platform, not the web one,
  because Routes is server code. e2e.test.mjs syncs the shared modules into server/platform first.
- **web/test:** the island tests (the docs' islands sharing a store, a tampered island,
  `renderIslands`) become document tests:
  - `hydrateDocument` hydrates without asking the server;
  - a tampered document is rendered again, with a warning;
  - strict mode throws.

  The Profile, Picks and Echo tests stay.
- **server/test:** the islands tests (server.test.mjs:530-556; `/islands-page`, `/islands-crash`)
  become page tests:
  - `<Loading>` and `<Errored>` in a page answer;
  - a server function behind middleware, called during SSR, with its answer recorded;
  - a crash is a 500;
  - HEAD isn't rendered;
  - nothing is left allocated after 50 rounds.
- **site/test:**
  - "Every page renders and its islands wake up" (55-73) becomes: every page hydrates in strict mode and fetches app.wasm. The assertion that only a page with islands fetches wasm is reversed.
  - The demo tests select by class.
  - **The byte-for-byte test (511-526) stays, extended to whole pages.** For every route, it compares the native page with `runtime.renderToString({ path })` of the generated `reference.roc`. Strict hydration checks the structure but not the text of computed holes: adopting an `x` node binds it without comparing (runtime.js:1036). Only the byte-for-byte test catches the native walker and the JS walker drifting apart.

## 9. Implementation steps

Each step is one worker's task and leaves `just test` green. **∥** marks steps that can run in
parallel because they touch no common file. Step 0 is the change already under way (actors and
`stream!` removed); it must land first, since steps 1 and 4 edit the same platform header and
roc.rs.

| # | step | files it touches | checkpoint |
|---|---|---|---|
| 1 ∥ 2 | **The HTTP modules join the platforms.**<br>• Move html's `Server`, `Endpoint`, `Middleware` and `Events` into the shared set, merging the two `Server` modules (one `Request`).<br>• `Response.body` becomes `Text`/`Page`/`Events`. A `Page` gets a 500 until step 4.<br>• `requires.respond!` returns `Server.Response`.<br>• html/main.roc exposes only `Html`. | html/, web/platform/{Server,Endpoint,Middleware,Events}.roc, server/platform/main.roc, server/build.mjs, src/routes.mjs (`pkg`), site/{server.roc, Middlewares.roc, routes/\*\*/+server.roc, Demos/Count.rocx, Demos/Shout.rocx}, server/test/app, web/test/app, test/routes.test.mjs | The site renders byte-identical; all tests pass. |
| 2 ∥ 1 | **The platform's `Html` can write pages.**<br>• Add `Raw`, `Doctype` and static `Optional`/`ClassIf` to the platform's `Html`, the walker and the runtime.<br>• The transpiler writes static holes, doctype and raw text in components. | web/platform/Html.roc, web/runtime.js, server/host/src/signals.rs, src/transpile.mjs, test/transpile.test.mjs, web/test/platform.test.mjs | Islands render with fewer markers on both sides; the byte-for-byte test passes. |
| 3 | **Server functions become routes.**<br>• `Server.Event`; `Server.local` checks `serving!`; `roc_call` makes the in-process call.<br>• Add `Host.serve!`/`serving!`/`context!`/`location!`/`status!` to both hosts (stubs in the web host), plus `Router` and `HttpStatusCode`.<br>• `Generated/ServerFunctions` with middleware; `Routes` answers `/rocx/call/*`; `rocx routes` lists the functions.<br>• Remove the host's fallback after a 404, `roc_signals_answer` and `signals.answer!`.<br>• Update the demos' `server!` signatures. | web/platform/{Server,Host,Router,main}.roc, web/host/host.zig, web/runtime.js (imports), server/platform/{main,Host}.roc, server/host/src/{signals,http,roc,hosted}.rs, src/routes.mjs, bin/rocx.mjs, site/Demos/{Echo,Shelf,Bag,…}.rocx, site/server.roc, tests | Islands' calls go through the route; the echo still hydrates without asking; a server test has a function behind middleware. |
| 4 ∥ 5 | **The host renders a page.** Page answers, `<!doctype html>`, the scripts, HEAD, a crash as a 500, the page box in the ring. Islands stay as they are until step 7. | server/platform/main.roc, server/host/src/{signals,http,roc}.rs, server/test/\*\* | The server test app's `Page` routes pass, with no leaks. |
| 5 ∥ 4 | **The browser hydrates a document.**<br>• `hydrateDocument` skips `data-rocx` nodes; a mismatch re-renders `<body>`; strict mode.<br>• Add `web/start.js` and `rocx:ready`. `renderToString` renders whole documents. | web/runtime.js, web/start.js, web/test/\*\*, web/README.md | In Chromium, a document app hydrates without asking; a tampered one is re-rendered. |
| 6a | **rocx build writes the app.**<br>• For component route files: `Root`, the page answers in `Routes`, `App` (jobs, migrations), `--client` `main.roc` and `reference.roc`.<br>• Routes that are static `Html` keep today's path until 6b.<br>• Measure a whole-site wasm with the docs as components (a throwaway build). | src/routes.mjs, bin/rocx.mjs, src/transpile.mjs (pure `view`), test/routes.test.mjs, test/e2e/\*\* | e2e: a generated app is served natively and hydrated. |
| 6b | **The site's pages become components.** Pages, the layout, the error page and Ui; Islands.rocx deleted; main.roc; site.js; build.mjs; site/test, including the byte-for-byte test over whole pages. The docs' prose is untouched. | site/\*\* | `just test` and `just site` pass; every page hydrates in strict mode. |
| 6c ∥ 7 | **The docs are rewritten** for one world (§8). | site/routes/\*\*/+page.rocx (prose), README.md, server/README.md | The site tests pass. |
| 7 ∥ 6c | **Islands and the `html` package are deleted.**<br>• Remove `Island`, `Signals`, `program.signals`, `roc_signals_mount`, `fill`/`placeholders`/`outside`, `renderIslands`/`hydrateIslands`/`mountIslands`, and the transpiler's static mode and `pkg`.<br>• The test app drops its islands. | html/, web/platform/{Island,main}.roc, web/runtime.js, server/platform/{Signals,Island,main}.roc, server/host/src/{signals,http,roc}.rs, src/\*.mjs, bin/rocx.mjs, server/test/\*\*, web/test/\*\* | `just test` passes; `grep -r island` finds only history. |

Two possible conflicts in the step 7 row:

- If 6c's README edits reach web/README.md, move web/README.md out of step 7's files.
- Step 3 gives `Router`'s server half to the server host before steps 4 and 5 split the work by
  directory, so that 4 owns server/ and 5 owns web/.

Follow-ups, not in this plan:

- client-side navigation;
- `<NoHydration>`;
- streaming SSR;
- GET server functions with caching (SolidStart's `query`);
- per-component mismatch ranges.

## 10. Open questions

**Changed in step 3 (the user's choice): Q1.** A context parameter can't work: a function that
ignores `context` leaves its type free, and parsing JSON into that type compiles but crashes on
every call. So `server!` keeps `|request, input|`, and a function reads its middleware's context
with the effect `Server.context!({})`, only where it needs it (SolidStart's `getRequestEvent()`).
A mismatch crashes, which is a 500 naming the function. Reading it outside a server function's body
crashes with a message that says so.

**Decided (2026-11-21):** the user took every recommendation below. For Q3 that means one wasm,
measured in step 6a, with `<NoHydration>` only if it is too big. Step 0 has landed: `program` has no
`actors` or `stream!`.

**Changed since this was written, to fold into step 1:**

- rocx-b2 added `html/OpenApi.roc`, which imports `Endpoint` and `Events`. It moves with them into
  the shared modules, together with its 36 expects. Nothing in it depends on html being a package.
  Moving it also touches:
  - src/routes.mjs: the server's `Api.roc` writes `import ${pkg}.OpenApi`, where `pkg` is the
    prefix the route files import `Server`/`Endpoint` with (`routePkg` in bin/rocx.mjs). Under
    `pf.`, the detection and the generated import must agree. test/routes.test.mjs asserts
    `import html.OpenApi`.
  - bin/rocx.mjs `rocCode(dir)`: it scans for tag names in the app's code and in the packages and
    platforms its header names. If the shared modules live in a directory no header names, add it,
    or a union such as `Server.Problem` can't be described.
  - site/build.mjs: `pick("openapi_format", "html/OpenApi.roc", …)`.
  - Docs: site/routes/routing/+page.rocx#openapi and README.md say "the html package's `OpenApi`".
- **The docs site must keep working as static files on GitHub Pages** (nxy7.github.io/rocx; the
  user's requirement, done by session rocx-ff, formerly rocx-9c). Every page and demo must work with
  no server behind it. Keep these working:
  - `Runtime.load(source, { base })` and the runtime's `under(url)`, which resolve fetch, listen
    and call URLs under the base;
  - site.js resolving the runtime and the wasm against its own URL;
  - `prerender(dir, { base })` in site/build.mjs, with `underBase` and `STATIC_GETS`.

  What that means for this design:
  - §4: `Root`'s matcher in the browser must strip the base from `location.pathname` (`/rocx/syntax`
    is the route `/syntax`). `start.js` and `app.wasm` must load from under the base, not from
    `/rocx/…` at the root.
  - §5: the docs' demos can't depend on a server function. Echo and Shout already work without one.
    A server function's answer recorded at prerender time still works, because it's in the page.
  - §4, client navigation (a follow-up): a `<NoHydration>` subtree fetched from the server needs a
    prerendered copy on a static host.
  - §8: the byte-for-byte test and "every page hydrates" should also run against the prerendered,
    base-pathed output.
  - The test that covers all this already exists: "the static build for GitHub Pages: files alone,
    under /rocx/…" in site/test/site.test.mjs. Keep it green at every step.
- **The demos changed for the static site** (rocx-ff). Step 6b carries these over:
  - Echo picks among three messages. One memo asks `echo!` for all of them as the page renders, so
    a click reads an answer the page came with.
  - Shout's buttons GET `/api/shout/{word}` for the words in `STATIC_GETS`.
  - Count is on no page, but stays registered in Islands.rocx so its quoted code compiles. When
    Islands.rocx is deleted, it still needs a module that compiles it.
- **Scoped styles** (rocx-59): a file's top-level `<style>` is lifted out by `stylesheet()` in
  src/transpile.mjs (with src/styles.mjs), and elements get the scope class in `attributes()`. Step 2's
  raw text for `<style>` in components must not break that. A top-level `<style>` is still lifted
  and scoped. Only a `<style>` inside markup becomes `Html.source_text`. Pages and layouts become
  components, so they keep going through the same path. test/styles.test.mjs covers it. Generated
  code now includes a `Styles` module, written with the same `pkg` prefix as Routes and Paths
  (bin/rocx.mjs:288). rocx-59 then changed this. How it works now:
  - **Where a `<style>` belongs.**
    - First on its line inside a type's block (`Counter := [].{`), at the block's item indentation:
      that component's stylesheet.
    - At column 0, at depth 0: the whole file's, for pages and layouts.
    - Anywhere else, deeper in a definition or inside markup: an ordinary element (`rawText`), as
      before.
    - The code path is `code()` → `stylesheetHere(depth, parens, blocks)` → `stylesheet(block)`.
      `blocks` is a stack, one entry per `{`. A type block opens when `Name :=` set `declared` and
      the next `{` follows a `.`.
  - **Classes.**
    - The scope class is `scopeClass("Module.Type")`, or `scopeClass("Module")` for the whole file.
    - `transpileModule` runs twice when a file has styles. The first run collects `styles` with
      their offset ranges. The second passes `scopes`, and `attributes(tag, component, at)` adds the
      class of every range that contains the element's `<`.
    - A static class is merged with it, and `class={e}` becomes `Str.concat(e, " rx-…")`.
      `UNSCOPED_ELEMENTS` (the ones that belong in `<head>`) are skipped.
  - **Output.** `transpileModule` returns `styles: [{ css, line, component }]`. bin/rocx.mjs's
    `stylesModule` writes Generated/Styles.roc, and the site's layout puts `{=Styles.style}` in
    `<head>`.
  - **Several components in one file.** `typeBlocks(source)` adds every `Name := ….{` type in the
    file to `this.modules`, so `<Stepper />` becomes `Stepper.view!(…)`.
  - A page's top-level `<style>` keeps working as a whole-file style once pages are components.
- **Step 1 landed (2026-11-21).** html's `Server`, `Endpoint`, `Middleware`, `Events` and `OpenApi`
  now live in web/platform, copied to server/platform by `SHARED_MODULES`/`syncShared()` in
  server/build.mjs. `html` exposes only `Html`. There is one `Server.Request`, `Response.body` is
  `Text | Page | Events` (a `Page` answers 500 until step 4), and `requires.respond!` returns
  `Server.Response` directly. bin/rocx.mjs detects two prefixes, `html` for `Html` and `http`
  (default `pf`) for the HTTP modules. The full report is /tmp/rocx-s1/REPORT.md.
- **Step 2 landed (2026-11-21).** The platform's `Html` has `Raw`/`Doctype` and the static
  attributes `Optional`/`ClassIf`, plus `source_text`, `doctype`, `optional`, `class_if` and a pure
  `to_str`. Both walkers render, build and adopt them. The transpiler writes a hole or attribute as
  static when reading it added no `!` name and no component tag (`this.effects`). On the site that
  took the markers from 120 to 110. The report is /tmp/rocx-s2/REPORT.md.
  - **Decided:** a `<script>` the runtime *builds* is inert, as in Solid, so a re-render never runs
    a script twice. Server-rendered scripts run once, as the browser loads the page.
  - **Owed:** a permanent server test for the native walker's `raw`/`doctype`/`o`/`ci` branches.
    Step 3 adds it to server/test/app (a probe island with a doctype, a `<style>` with `class_if`,
    and an `<a>` with `optional`).
  - Known edge, not handled: static text that starts with `\\n` first inside `<pre>`/`<textarea>`
    (the parser drops that newline).
- **Step 3 landed (2026-11-21).** Server functions are routes:
  - `Generated/ServerFunctions` (each function behind its route file's middleware) answers
    `POST /rocx/call/<name>` through `Generated/Routes`, with 405, 404 and 400, and `rocx routes`
    lists the functions.
  - On the server, `roc_call` answers a component's call in-process through that route and
    records the 200.
  - Both hosts have `serve!`/`serving!`/`context!`/`location!`/`status!`. `Router` and
    `HttpStatusCode` are shared modules.
  - The host's fallback after a 404, `roc_signals_answer` and `program.signals.answer!` are gone.
    `program.signals` is `{ main! }`.
  - The web platform's `answer!` stays until step 7. A JS runtime rendering on a server (the
    reference build, web/test's servers, `measureClient`) answers calls with it.
    site/reference.roc's is `ServerFunctions.respond!(called, Server.request!({}), { facts: "" })`.
  - Server functions stay out of `/openapi.json`.
  - Not tested natively yet: `Host.status!` (step 4), and `Router.location!` in the browser
    (step 5).

  The report is /tmp/rocx-s3/REPORT.md.
- **Charts (rocx-9c, after step 3).** Later steps must carry these over:
  - web/runtime.js: `within(node, scope)` sets `scope.svg` under an `<svg>`. `element()` uses
    `createElementNS` when `node.tag === "svg" || scope.svg`, and `adopt()` passes the scope to
    children. Keep that flag flowing through whatever builds and adopts elements (steps 5, 7).
  - bin/rocx.mjs: `componentPackages(dir)` finds packages with `components/` in the app's
    headers. `linkComponents()` rewrites `import charts.X` to `Generated/charts/X` path imports
    and copies the components into the app (marker lines point at the package source). The
    contexts scan includes them. Keep this in 6a.
  - site: `charts:` in the client/server/reference headers; site/Demos/Rainfall.rocx and
    Ticker.rocx with `<Island name="rainfall">`/`"ticker"` in Islands.rocx; a #charts section on
    the showcase. Step 6b moves them like every other island.
- **Step 4 landed (2026-11-21, rocx-39).** The host renders a page:
  - `respond_for_host!` returns `{ status, headers, kind : U8, text, page : Box(() => Str), feed : Box(Feed) }`.
    `Server.for_host` gives `kind` 0 text, 1 page, 2 stream, and adds `text/html` to a page that has
    no content-type.
  - `roc_signals_run` is renamed `roc_run` (`roc::run`).
  - The host renders a `Page` inside the request's call (`signals::render_page`): the doctype, the
    walk, then the answers script and `<script type="module" data-rocx src="/rocx/start.js">` before
    `</body>`.
  - `Host.status!` sets the status. HEAD isn't rendered. A crash is a 500.
  - With `--opt=speed`, every computation that fails or crashes leaks the box it ran, because
    Roc's optimized code lets go of it only on return. A page frees everything its render made
    (`roc::Page`, `KEEPING`), so pages leak nothing. The islands path still leaks there, as it did
    before; step 7 removes it. The tests build with `--opt=dev`, which doesn't leak.

  The report is /tmp/rocx-s4/REPORT.md.
- **Step 5 landed (2026-11-21, run by rocx-7d's subagent from rocx-97's brief).** The browser
  hydrates a document.
  - web/start.js loads the runtime and wasm relative to its own URL, works under a base, and
    dispatches `rocx:ready` with `{ runtime, ms }`.
  - `runtime.hydrateDocument(document)` adopts the doctype and `<html>`. Its cursor skips
    `[data-rocx]` and the doctype the host adds.
  - A mismatch warns and re-renders `<body>`, keeping `<head>`. Strict mode
    (`window.rocxStrict = true` before start.js) throws instead.
  - `Router.location!` strips the base. `renderToString` renders whole documents.
    `Runtime.documentOf` mirrors signals.rs `document()`.
  - It also fixed a leak in `run()`: after a mismatch, the first attempt's allocations weren't
    released. That affected the old `hydrate` too.
  - The report is /tmp/rocx-s5/REPORT.md.
  - **For 6a/6b:**
    - The dev reload script (`RELOAD` in server/host/src/http.rs) lacks `data-rocx`, so under
      `--dev` every page re-renders `<body>` and strict pages throw. That's a one-line fix (6a).
    - The app build must serve /rocx/start.js, runtime.js and app.wasm side by side.
    - **The root `<Errored>`** (§3) can't wrap the whole document. Its fallback would add a second
      doctype, and in the browser a fallback can't replace a document. So it goes *inside* the
      root layout, around the page, and a failure in the root layout itself is the server's 500.
- **Decided in 6a: the reference render reuses recorded answers.** §6's generated `reference.roc`
  (a server copy of `Root` with its server functions, on the web platform) can't know the app's
  default middleware and context, which live in the author's main.roc. Instead, the byte-for-byte
  test and `measureClient` GET the native page, read its answers script, and run
  `renderToString({ path, answers })` on the *browser* build, as hydration does. A call that isn't
  recorded is a test failure, because it means the two sides drifted. So no reference.roc for
  component apps, and the web platform's `answer!` can go in step 7.
- **The project is now "Roc Solid"** (rocx-83's prose-only rebrand, applied after 6a). Steps 6b
  and 6c must write prose by this rule:
  - **"Roc Solid"** is the project as a whole: the framework and ecosystem, page titles, the
    site's brand, "a Roc Solid app", "What Roc Solid is".
  - **"rocx"** stays for:
    - the markup and file format (".rocx file", "written in rocx");
    - the CLI and transpiler ("`rocx build` writes…", "rocx refuses…");
    - every name in code, on the wire, in HTML or in the database (`/rocx/call`, `rocx-island`,
      `data-rocx`, `rocx:ready`, `rocx_jobs`, `RocxError`, `/__rocx/mail`).
  - The docs' sidebar part named "rocx" (markup, pages, components, calls, tools) keeps that name.
    It's the rocx part of Roc Solid, next to Platform.
- **Keep the "Pure and effectful components" docs section** (site/routes/components, toc id `kinds`,
  plus a README paragraph; rocx-83 writes it after 6a). The user loves the pure `view` vs
  effectful `view!` split. 6b and 6c may reword the section to fit the model, but must keep it
  and these four points:
  1. `view` is pure. The compiler refuses a signal or a context in it, so it's called where it's
     written (`Heading.view({…})`).
  2. `view!` may make signals, read contexts and call the server. It runs once, where it's
     rendered (`Html.component(|| Counter.view!({…}))`).
  3. A pure component's holes may still read accessors passed to it. Those holes are
     computations: a pure function may build an effectful closure, but not call one.
  4. Call sites aren't marked: rocx build writes the call that fits.
- **6c is folded into rocx-83's newcomer docs pass** (2026-11-21). The order is now 6a, then
  rocx-83's landing-page window, then rocx-7d's platform patch, then 6b, then 7, then rocx-83's
  docs pass. That pass rewrites the docs once: accurate to the final model and readable for
  newcomers ("not verbose, but detailed", the user's bar). It uses §8's list of docs pages and
  §10. Between 6b and that pass, the prose may still mention islands.
- **Step 6a landed (2026-11-21).**
  - **What rocx build writes** for route files with `import pf.Html`:
    - `Generated/Root` (both copies);
    - Routes' page answers and 404 (`Server.page(…, Root.view!)`);
    - `Generated/App`, where `App.program({ context, middleware, crons })` gets the jobs (scanned
      `Job.define`) and the migrations (`migrations/*.sql`, embedded);
    - with `--client <out>`: main.roc and static/rocx/{start.js, runtime.js} next to the wasm.
  - **Pure components:** `viewsDefined` reads each type block. A module (or local block) that
    defines only `view` is called directly, `Heading.view({…})`, and counts as no effect.
  - The root `<Errored>` sits inside the layout. RELOAD has `data-rocx`.
  - The byte-for-byte check (decision D above) works in the e2e: native pages equal
    `renderToString` of the browser build seeded with the recorded answers.
  - The report is /tmp/rocx-s6a/REPORT.md.
  - **Q3 measured:** the whole docs site as one wasm is 1320.6 KB raw, 363.8 KB gzip, **268.8 KB
    brotli**, against the 150 KB budget. Today's islands are 106.6 KB brotli. The listings' text is
    only ~25 KB of it: the bulk is prose compiled as markup code. Hydration is fast (/showcase, the
    heaviest page, 37 ms). **Per the user's rule (only fix it if it's too big), `<NoHydration>`
    comes in** (§4 mitigation 3), as its own step before 6b, so 6b can wrap prose and listings as
    it converts pages.
  - **Left for 6b:**
    - a `renderToString({ answers })` option in runtime.js (the e2e overrides the instance's
      answer instead);
    - `Middleware.none`, which is missing from the platform;
    - local snake_case pure function components (`card` is still called `card!`);
    - `Html.to_str` crashes on a component or computation, and Ui/Example uses it.
- **Step 6b landed (2026-11-21): the docs site is one component app.**
  - Pages, the layout, the error page, Ui, examples and stories are on `pf.Html`. Islands.rocx and
    server/client/reference.roc are gone, and site/main.roc calls `App.program` with
    `openapi: Page(Swagger)`.
  - Each demo is inline in its page, in a `data-demo` wrapper, with providers on /components.
    Facts, members and /calls come from server functions.
  - 52 `<NoHydration>` regions. site.js starts from `rocx:ready`. One app.wasm, and
    `measureClient` uses `renderToString`.
  - site/test: strict hydration, byte-for-byte over whole pages (native and on Pages files), and an
    `--opt=speed` middleware test.
  - It fixed a generator bug: a local pure function component (`card`) was being called `card!`.
  - **Size:** app.wasm is 563.7 KB raw, 181.3 KB gzip, **143.0 KB brotli** (under 150).
    /showcase hydrates in 15.7 ms.
  - The report is /tmp/rocx-s6b/REPORT.md.
- **Step 7 landed (2026-11-21): islands and the html package are gone.** That completes the
  redesign's code.
  - **Deleted:** `Island`, `Signals`, `program.signals`, `roc_signals_mount`,
    `fill`/`placeholders`/`outside`, `renderIslands`/`hydrateIslands`/`mountIslands`, the web
    platform's `answer!`, html/, and the transpiler's static page mode.
  - **Converted:** the e2e fixtures, server/test/app, web/test and EscapeLab.
  - **Fixed:** the fresh-checkout build order (Sources.roc is now written before the client copy).
    Also a pre-existing leak, under `--opt=speed`, when an actor's `receive!` crashed:
    `isolated_call` now releases the box once, on the crash path only. That leak was hidden by the
    islands leak.
  - All green, including the server tests with `ROCX_TEST_OPT=speed` and nothing skipped.
    app.wasm is 141.8 KB brotli.
  - The report is /tmp/rocx-s7/REPORT.md.
  - **Still to come:** the fork-compiler switch and removing the workarounds, rocx-89's neon look
    and design system, and the newcomer docs pass.
- **The neon look and docs design system landed (2026-11-21),** finishing rocx-89's work.
  - All 32 site/Ui components and every demo have scoped styles; the listed components have
    stories. Pages use components or a page-level style.
  - site.css is tokens plus base: 50.2 KB down to 6.0 KB, with 0 class selectors.
  - app.wasm is 143.9 KB brotli.
  - **Follow-up:** the scoped CSS is inlined in every page (the front page went from 6.1 to
    15.0 KB gzip). The real fix is rocx build writing the styles as a cached file.
  - The report is /tmp/rocx-ds/REPORT.md.
- **No wasm size budget for now** (the user, 2026-11-21: "drop the limits completely. We first want
  to provide functionality and worry about bundle size later"). Earlier the same day it was raised
  from 150 KB to 250 KB brotli for more live chart demos. Size is still reported, and wasm
  splitting is being built behind a flag. After rocx-9a's charts rework (Donut, Scatter, and Bar/Line demos with
  Randomize/Auto), the site is 158.3 KB.
- **The fork-compiler switch landed (2026-11-21).**
  - rocx builds with `.tools/roc-active`, the fork at 3cf64982c7. Failing that it uses `ROC`, and
    otherwise stops with an error: it never uses the `roc` on PATH.
  - Zig and Rust come from the system when they match (Zig 0.17.1, Rust 1.85 or newer), and from
    .tools/ otherwise.
  - `just compiler-bugs` runs the repros.
  - `kinds_of!` and the `Json.Encodable([Infinity, NaN, NegativeInfinity, ..])` where clauses are
    gone (Browser, Call, Endpoint, Server, Log).
  - The report is /tmp/rocx-ec/REPORT.md.
- **The repo will build with a forked Roc compiler** (the user's decision, 2026-11-21) until the
  fixes are upstream. The fork carries the minimal fixes for the `boxy_lowering`, `lambda_solve` and
  skipped-middleware bugs.
  - After step 7, the Justfile builds the fork's integration commit into .tools/roc-fork/, and
    .github/workflows/pages.yml becomes manual.
  - The workarounds are out (2026-11-21), each once its repro passed on the fork build:
    `kinds_of!` and the `Json.Encodable([Infinity, NaN, NegativeInfinity, ..])` where clauses
    (rocx-ec, on 3cf64982c7); OpenAPI answered inside respond!, and the two-step middleware rule
    (rocx-72, on 3f66e242ea).
- **A silent miscompile under `--opt=speed` and `--opt=size`, fixed in the fork** (found by
  rocx-ac). A chain of three or more closures composed by `then` (`a.then(b).then(c)`, e.g.
  Middleware) skipped its last step, with no error. SpecConstr bound an inlined closure's captures
  before copying the call's arguments. Upstream fixed it in 55d1a82983 (PR #13202); the fork has it
  as 3f66e242ea, pinned since 2026-11-21. The two-step rule is gone, and `App.program` chains
  `OpenApi.middleware` after the app's middleware again. Repro, kept:
  test/compiler-bugs/middleware-skipped-opt-speed/.
- **Step 6n landed (2026-11-21): `<NoHydration>`.**
  - **Browser copy:** the transpiler drops its children, and the imports only they use. It refuses
    `on:`, `key=` or `transition` written inside.
  - **Rendering:** natively and in the JS walker, the region is
    `<!--nohydration-->…<!--/nohydration-->`, with no inner markers. Calls inside it aren't
    recorded.
  - **Hydration** skips the region, and a `<body>` re-render keeps the server's regions.
  - **The byte-for-byte check** is `renderToString({ answers, regions })`.
  - **Measured with the pages' prose and listings wrapped:** the whole site is 524.1 KB raw,
    164.1 KB gzip, **126.5 KB brotli** (under the 150 KB budget; 273.4 KB unwrapped). /showcase
    hydrates in 14.2 ms (38.1 before).
  - **For 6b:**
    - a local read only inside a region becomes an unused-variable warning in the browser copy,
      and roc exits 2, so compute such values inside the region;
    - a region the browser must build anew (inside a `<Show>` branch) is empty, with a warning.
  - The report is /tmp/rocx-s6n/REPORT.md.
- **Who drives the redesign.** The driving session restarted several times (rocx-97, rocx-0c,
  rocx-72, rocx-9a). While it was down, another session (rocx-7d, which does platform work) ran
  step 5 from the brief as a stopgap.
- **Platform additions landed after 6a** (rocx-7d, two windows). Steps 6n, 6b and 7 must keep
  them working:
  - binary request bodies, `Forward`/`Storage.serve!`, `Http`, `Env`, crypto, `Storage` (S3),
    cookie options;
  - jobs (`define_with`, `enqueue_keyed!`, cancel/move/list, a jobs page) and a dev mailbox;
  - `.well-known` and `respond!` route files;
  - effects (`create_effect!`, `on_cleanup!`, `on_settled!`), timers, `Browser.call!`;
  - form actions (`use_submission!`, `Server.flash!`);
  - a server function redirected by middleware during render makes the page that redirect;
  - F64 in server functions;
  - `Html.component_with`, so value props read from a signal are read by the hole;
  - route-file components as types beside the module;
  - `<Title>` (`pf.Title`, `Host.title!`);
  - no markers in `<title>`/`<textarea>`.

  rocx-7d's notes for each window are outside the repo; the step briefs give their paths.
- **A compiler crash (`boxy_lowering`), found and worked around.**
  - **Trigger:** `Json.to_str_try` with `where [e.Json.Encodable(e)]` segfaults the pinned Roc,
    even at `--opt=dev`, when the value is a record or tuple holding a nominal type with a derived
    `encoder_for` next to another field.
  - **Why it hit apps:** `Server.serve!` encodes every server function's context, argument and
    result, so any app with that shape crashed.
  - **Workaround:** write the where clauses as
    `Json.Encodable([Infinity, NaN, NegativeInfinity, ..])`, in Browser, Call, Endpoint and Server.
  - **Repro:** test/compiler-bugs/json-to-str-try-nominal/.
  - It's a compiler bug, not generated code. rocx-7d's diff lands after 6n, so 6b is safe.
- **`Job.enqueue!(kind, input, { when: Now })`** (rocx-48): `Job.Opts : { when : When }`,
  `Job.When : [Now, At(U64)]` (milliseconds since the epoch). `Job.enqueue_in!` is gone.
- **`rocx fmt`** (rocx-fd), now run regularly. Every step runs `just fmt` on what it touches, and
  `just check` includes `fmt --check`. Details: in `code()`, the Transpiler records where each outermost markup span and
  `<style>` starts and ends (`this.spans`), for src/format.mjs. Step 2's transpiler changes must
  keep those spans right. Run the fmt tests too.

1. **What a server function sees.** Recommended: `{ request, context }`, with the context sent as
   JSON from its route's middleware (§5), which keeps typed middleware for server functions. The
   simpler alternative is the request only, with guards in middleware and the session read from
   cookies; it would drop the typed context the user built.
2. **Calls during SSR.** Recommended: in-process through the function's own route, as in §5, so a
   call means exactly what the browser's request means. The alternative calls the implementation
   directly with the page's context. It is faster, but wrong whenever the function's middleware
   differs from the page's.
3. **Code size.** Recommended: ship everything in one wasm, measure in 6a, and add `<NoHydration>`
   only if the site exceeds a budget (propose 150 KB brotli). One wasm per route is rejected (§4).
4. **Where the shared modules live.** Recommended for now: web/platform, copied into server (no
   churn). Later, a neutral `shared/` directory that both builds copy, since `Middleware` and
   `Response` aren't the browser's.
5. **Migrations.** Recommended: found in `migrations/*.sql`, so the author writes nothing.
   Alternatively, `config.migrations`, as the brief sketched.
6. **main.roc.** Recommended: the author writes the few lines in §6, so the platform path and the
   config stay visible Roc. Alternatively, rocx writes main.roc too, from an optional `config.roc`.
7. **The byte-for-byte test.** Recommended: keep it over whole pages, and add strict hydration
   (§8). The alternative is strict hydration alone: cheaper, but blind to text drift in holes.
8. **The `Answer` shape.** Recommended: a record whose body is `Text`/`Page`/`Events` (§1). The
   alternative, a bare `[Body, Page, Events]`, puts status and headers in each variant.
9. **The bootstrap.** Recommended: the host adds it before `</body>`, marked `data-rocx`. The
   alternative is a `<Scripts />` that the root layout places, as SolidStart's document does: more
   explicit, but one more thing to forget.
10. **What a hydration mismatch does.** Recommended: warn and re-render `<body>`, with strict mode
    for tests. The alternative throws, which breaks the page for anyone whose browser extension
    adds a node.
