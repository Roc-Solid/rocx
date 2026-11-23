# Design: client-side navigation (D-040, Proposed)

> A design spike, 2026-11-22, on master at 2ca6936. Nothing here is built. It assumes D-037 (the
> typed `Api` contract) has landed, and phase 2 needs D-039 (value props patched in place). The
> one measurement it rests on is in `README.md` beside it (`measure.mjs`).

## 0. In short

A click on a link to one of the app's own pages, or a handler's `navigate!`, no longer loads a
document. The runtime fetches the new page's HTML, as the server answers it (behind the same
middleware, with the same in-process endpoint reads, or the file `just site` wrote), and doesn't
show it: it reads the answers, the `<NoHydration>` regions and the head out of it, pushes the
address, and renders the new page itself, from the wasm, which already holds every page's code.
The old page stays until then (`Router.is_routing!` says one is on its way). Layouts stay mounted,
with their state, unless something they read once has changed. A change of the query alone
(`?days=30`) is made in place, and only what read the query reads again. Back and forward,
scroll, focus, the page's title and an announcement for screen readers are the runtime's. Plain
`<a href>` navigates in place, as Solid Router's do; `rel="external"`, a `target`, `download` and
modifier keys keep the browser's own. Anything the runtime can't render as the app's page (a
plugin's page, a file, a text 401, another build, a network failure) the browser loads, as today.
An app changes nothing to have it, and links get faster.

```
click / navigate! / back
   │
   ▼
same app? ── no ──► the browser's navigation (as today)
   │ yes
   ▼
only the query changed, ── yes ──► commit the address; what read the query reads again (§7)
and no level read it once?
   │ no
   ▼
fetch the page's document  (GET <url>, accept: text/html, x-rocx-navigate: 1; the server
   │                         answers it as a load: middleware, reads in-process, a redirect)
   ▼
an app document of this build? ── no ──► location.assign(url)
   │ yes
   ▼
seed its answers and regions; push or replace the address; commit the location
   ▼
one flush: kept layouts patched, the rest made from the answers (nothing is asked)
   ▼
<head> reconciled · <Title> · scroll · focus · announce · effects after the flush
```

## 1. Where things stand

Every link is a full page load: a document, then `start.js`, the wasm compiled and instantiated
again, and the whole document hydrated again. Three things already make client-side navigation
mostly a matter of the runtime:

- **One wasm holds every page** (`spike/no-islands/DESIGN.md` §4): `Generated/Root.roc` is in both
  copies of the app, matches `Router.location!` and renders the page in its layouts. Nothing has to
  be downloaded to render another page.
- **A page's data is its endpoint reads** (D-023), answered in-process while the server renders and
  carried in the page's answers script, which the runtime already knows how to read (`seed`).
- **The runtime can render a document anew** from answers and regions: it does so when hydration
  finds a mismatch (`settleDocument` with `rebuild`, `keepHead`, `renderBody`, `keepingRegions`),
  and `renderToString({ answers, regions })` renders the browser's build byte for byte as the server
  did, which the site's tests check on every page.

And ownership (D-017), the hub (D-020), titles, transitions and submissions already go with the
component that made them, so a page's subscriptions, timers and effects end with it.

The example apps worked around the lack:

- `examples/board` opens a card with `?card=12`: a click takes it over (`on:click.prevent`, D-029)
  and opens the card without changing the address, so Back doesn't close it; a new tab or a
  shared link loads the page with the card open.
- An app couldn't switch a query parameter (`?days=7` to `?days=30`) in place: either a full load,
  or a signal the address never shows.

And `Router.location!` isn't a source anything tracks: it never changes without a load, so a hole
that reads it runs once.

## 2. Decisions at a glance

| Question | Proposed | Section |
|---|---|---|
| What navigates in place | a same-origin link under the base, to a path the app's route table has a page for, with none of the opt-outs | §3 |
| `<a>` or `<A>` | both: a plain `<a>` navigates in place; `<A>` adds the active state | §3.3 |
| How the browser gets a page's data | the page's own HTML document, fetched; not a new data endpoint | §4.1 |
| Middleware and guards | unchanged: the fetch is a page load to the server; a redirect is followed in place | §4.4 |
| What stays mounted | each route level (a layout, the page) is kept while its file and its own params are the same and nothing it read once changed | §4.3 |
| Loading | the old page stays until the new one's document is in (`Router.is_routing!`) | §5 |
| Query changes | in place, no document fetched; only what read the query reads again | §7 |
| Server and build | no new server route; one hosted call (the route table and the build), `data-build` on the bootstrap | §12 |
| Static sites | work as they are: the prerendered page is the document | §12.3 |

## 3. What navigates in place

### 3.1 Same-app links

The runtime listens for clicks on the document, once (as it listens for submits). A click
navigates in place when all of these hold, else the browser has it:

- it is the main button, with no modifier key (Meta, Ctrl, Shift, Alt): those open a tab, a
  window or a download, as the user asked;
- no handler prevented its default (an `on:click.prevent` of the app's own takes the link over, as
  board's does today);
- it is on an `<a>` (or an SVG `<a>`) with an `href`, no `download`, no `rel` containing
  `external`, and no `target` other than `_self`;
- its URL is this origin's, under the site's base (`/rocx/` on a project's GitHub Pages);
- its path, without the base, is one of the app's pages (the route table, §3.2);
- it isn't a link to a place on this page: when only the hash differs, the browser scrolls to it
  and pushes the entry itself, and the runtime leaves it alone.

These are Solid Router's rules for the anchors it intercepts, with one more: the route table.
Without it a link to `/admin` (a plugin's page), `/feed.xml`, `/openapi.html` or `/__rocx/mail`
would be rendered by the app's `Root` as its 404.

A link inside a `<NoHydration>` (the docs' prose) navigates in place too: the listener is the
document's.

### 3.2 The route table

The browser decides which paths are pages from the same table `Routes` and `Root` are written
from. rocx build writes it into `Generated/Root.roc`, and `Root.view!` hands it to the runtime as
it starts, with the build's id (§10.3):

```roc
Router.app!({ build: "7f3a91c2", dev: Bool.False, pages: ["/", "/me", "/lists/[id]", "/tasks/[id]"] })
```

`Router.app!` is a hosted call, generated only (`dev` is whether rocx built with `--dev`). In the
browser the runtime keeps the table and matches a path against it segment by segment (a `[param]`
is any one segment, as `Root`'s matcher does; routes have no rest segments). On the server the
host keeps the build for the bootstrap's `data-build` (§12.1). So the table is in the wasm, there
is no file to fetch, and it can't disagree with the matcher.

A dev build's stories (`/__rocx/stories/…`) are in the table under `--dev`.

### 3.3 `<a>` and `<A>`

A plain `<a href={Paths.lists_id({ id })}>` navigates in place: every app's links get faster with
no change, and a link written in a `<NoHydration>` or in Markdown works as well as one in a
component. Solid Router does the same (unless its `explicitLinks` is set). Two attributes Solid
Router reads on plain anchors are read here too:

```rocx
<a href={"?card=${card.id}"} noscroll>…</a>        # keeps the scroll where it is
<a href={Paths.root} replace>Back to the lists</a>  # replaces the entry instead of pushing one
```

`<A>` (`import pf.A`) is the same link with Solid Router's active state, which apps write by hand
today (examples/tasks' `aria-current??={if (path == …) "page" else ""}`):

```rocx
import pf.A

<A href={Paths.lists_id({ id: list!().id })} class="list" active_class="current">{list!().name}</A>
<A href={Paths.root} end>Home</A>      # active only at / itself, not under it
```

It renders an `<a>` with `aria-current="page"` and `active_class` (default `active`) while
`Router.location!` is at its path (with `end`) or under it (without), tracked, so it follows
navigations. `replace`, `noscroll` and `preload` (§11) are its props too.

An app that wants only `<A>` to navigate in place (Solid Router's `explicitLinks`) writes
`data-rocx-navigation="explicit"` on its root layout's `<html>`; `"off"` turns navigation in place
off for the app (question 2). A `data-rocx-…` attribute is the app's, read by the runtime; it is
not the host's own `data-rocx`, which hydration passes over.

### 3.4 `navigate!`

Solid Router's `useNavigate`. A function of `pf.Router`, called from a handler (an effect's apply
is one):

```roc
import pf.Router exposing [navigate!, navigate_with!]

Router.navigate! : Str => {}
Router.navigate_with! : Str, { replace : Bool, scroll : Bool } => {}
```

```rocx
<button on:click={|| navigate!(Paths.tasks_id({ id: task!().id }))}>Open</button>

create_effect!(|| made.result!(), |result| match result {
	Ok(list) => navigate_with!(Paths.lists_id({ id: list.id }), { replace: Bool.True, scroll: Bool.True })
	Err(_) => {}
})
```

- It is queued with the handler's writes, as `use_action!` and `Browser.call!` are, so a handler
  that waits for the server and runs again navigates once, after its writes are applied.
- `to` is a path (`Paths` makes them), a path with a query, or a query alone (`?days=30`, on the
  page's own path). A `to` that isn't one of the app's pages, or is another site's URL, is
  `location.assign(to)`.
- Called while computing it fails, as `Browser.call!` does: rendering mustn't navigate. A
  component that has to send the visitor elsewhere as it renders renders `<Navigate>` (§3.5).
- On the server no handler runs.

### 3.5 Redirects

Every redirect an app can make today keeps working, and lands in place when it can:

| Who redirects | Today | With navigation in place |
|---|---|---|
| A page's middleware (a guard sending a signed-out visitor to `/login`) | a 303 for the page's load | the document's fetch follows it; the address becomes where it ended (§4.4) |
| An endpoint read while the server renders (D-019) | the page is that redirect | the same: the fetch follows it |
| An endpoint's own redirect answering a form or an action (`x-rocx-redirect`) | `location.assign` | `navigate!` to it, in place when it is a page, unless the visitor navigated since it was sent (§9.2) |
| A component as it renders | not possible | `<Navigate href={Paths.login} />` (below) |

`<Navigate>` is Solid Router's: `import pf.Navigate`, `<Navigate href={…} />`. On the server,
rendering one makes the page a 303 to `href`, as a redirect met while rendering already does
(D-019: the host's `render.redirect`). In the browser it navigates there, replacing the entry,
after the flush that rendered it. So a guard of the page's own reads as Solid's do:

```rocx
<Show when!={signed_in!()} fallback={<Navigate href={Paths.sign_in} />}>…</Show>
```

The server's middleware stays the place for a guard that must hold: `<Navigate>` is for what the
page itself decides.

## 4. What a navigation does

### 4.1 It fetches the page's document

To render another page, the browser needs what only the server has: the page's endpoint reads,
answered behind their middleware, the `<NoHydration>` regions (whose code isn't in the wasm), and
whether the page's middleware lets the visitor in at all. The server already answers all of that
in one request, the page's own GET, as the HTML document it sends a load. So a navigation fetches
it:

```
GET /lists/7?days=30
accept: text/html
x-rocx-navigate: 1          (preload, for a prefetch: §11)
```

and reads it with `DOMParser` (no script in it runs) instead of showing it:

- the answers script (`script.rocx-answers`) seeds the runtime's answers, as hydration's does;
- the flash script, likewise;
- the `<NoHydration>` regions, in order, are what the new page's placeholders are filled with
  (`keepingRegions`, as rendering `<body>` again after a mismatch does);
- its `<head>` is what the page's head is reconciled with (§8);
- the response's status (a 404 page, a 500 page) is nothing to act on: the page renders what the
  server rendered;
- the bootstrap's `data-build` is checked against the wasm's (§10.3).

Why the document, and not a data endpoint (SvelteKit's `__data.json`, Remix's single fetch,
Next.js's `/_next/data/<build>/…`):

- **Nothing new on the server.** The page's GET already runs the app's middleware and the route's,
  answers its reads in-process (one request, no waterfall of reads discovered as components
  render), follows the page's redirects, sets its status, and renders its regions. A data endpoint
  would be a second way to answer the same thing.
- **Static hosts work.** The file `just site` wrote for a page is that document. A data endpoint
  would need a second file per page, at a second URL.
- **It costs little.** Measured on the docs site (`README.md`): the document is 2–16% larger with
  brotli than a JSON of the answers, regions and title alone, 1–2.6 KB a page. What dominates both
  is what the browser can't make: the regions, and above all the app's stylesheet (11.7 KB, §8).
- **One code path.** Hydration and navigation both read a document the server rendered.

A JSON payload stays possible later, behind the same runtime code, if a measurement ever asks for
it (phase 4).

### 4.2 It matches and renders in the browser

The runtime has the page's answers before it changes anything. Then, in one go:

1. It pushes the address (`history.pushState`, or `replaceState` for `replace` and redirects).
2. It commits the location: `Router.location!` becomes a tracked read, a source like a signal's,
   and the runtime writes it. (`Router.location!` returns the committed location, the one the page
   on screen was rendered for, not `window.location`: they differ only while a back or forward
   navigation's document is on its way, and nothing should render half of each.)
3. One flush: what read the location runs again. `Root` matches the new path, keeps the levels it
   can (§4.3) and makes the rest. Every read the new page makes is answered from the seeded answers,
   so the page is whole in that flush, with no `<Loading>` fallback and no request.
4. Afterwards: the leftover answers are dropped (as after hydrating), the head reconciled, titles,
   scroll, focus and the announcement done (§6, §8), then effects' applies run, as on any flush.

With `strict` (the tests', as for hydration), a navigation that asks the server for something the
document didn't carry throws.

### 4.3 Kept layouts and pages

`Root` renders route levels: the root layout, each layout below it, then the page. Each level is
a keyed part (Solid 2.0's keyed `<Show>`, which `web/README.md` lists as not there yet: a part made
anew, with a new owner, when its key changes):

- **A layout's key** is its file and its own params (the ones its directory names:
  `routes/[lang]/+layout.rocx`'s `lang`). The root layout's is its file alone, so it is kept for
  every page.
- **A page's key** is its file and its params. `/lists/1` to `/lists/2` makes the page anew; `?days=`
  doesn't (§7).
- **What changed and was read once.** A component's body runs once, untracked, as in Solid; a value
  it read there doesn't follow. The runtime sees `Router.location!` read untracked and notes it on
  the level the read is in: a level that read the location in its body is made anew whenever the
  location changes, as if the location were part of its key. If D-039 makes props a source the
  runtime sees read (its proposed `props!()`), the same holds for a prop (`meta`) a layout read in
  its body. So a layout written as the site's is today
  (`path = Router.location!({}).path` at its top, and the sidebar, the pager and the contents
  computed from it) is made anew on each navigation and is never stale. Read in holes and memos, the
  same values let it be kept, with the scroll of its sidebar, its open menus and its signals. In a
  dev build (`rocx build --dev`, which `Router.app!` tells the runtime) the console says which
  levels were made anew and why.

So kept is the default, as in Solid Router and SvelteKit, but only where it can't show what the
last page knew.

Where Solid differs, and why:

- **A page with new params is made anew.** Solid Router keeps the component and makes `useParams()`
  reactive. Here a page's `params` is a plain record, and the rule "name the endpoint outside the
  computation" (`web/README.md`, "Waiting") has every page build its endpoints from `params` in its
  body: kept, it would read the old item.
- **A layout is given its own params**, not the page's. Its props must have one type for every
  page under it, and only its own params are the same for all of them; today's layouts read none
  (the root layout couldn't read a param one of its pages lacks anyway). Likewise every page under
  a layout gives it a `meta` of one type, which each app's pages already do (rocx build says so at a
  page whose `meta` differs).
- **The layout's `meta` changes while it is kept.** That is a value prop, which D-039 patches in
  place: a layout's `<title>{meta.title} · Acme Tasks</title>` follows. Until D-039, phase 1 makes
  every level anew (§15), so `meta` never goes stale.

Kept levels' `<NoHydration>` regions are the server's for the page that was loaded. Since the
fetched document has every region, a kept level's regions that the new document renders
differently are replaced, and the others are left as they are. examples/journal's masthead (a
region in its layout, with the language switcher for this post) follows the page so.

### 4.4 Middleware and guards

What the server decides still decides, because the document's fetch is a page load to the server:
the app's middleware and the route's run around it, its reads go through their own, and a cookie
it sets is set.

- **A redirect** (a guard's 303, or one met while rendering) is followed by `fetch`. The response
  says where it ended (`response.redirected`, `response.url`); the runtime pushes that address, not
  the link's, and renders that page if it is one of the app's, or loads it if not. A redirect to
  another site (an OAuth sign-in) makes `fetch` fail on CORS, and the runtime loads the link's URL
  for the browser to follow.
- **A refusal** that isn't a page (a 401 or a 403 as text, a JSON error) isn't an app document: the
  runtime loads the URL, and the browser shows what the server says, as on a load.
- **A guard's decision changing** between navigations (the session expired) is met by the next
  fetch: no page is rendered from what the visitor may no longer see.

The browser never decides on the server's behalf, and nothing in the browser can skip a guard:
there is no data request that a guard on the page's GET doesn't see.

A middleware can tell a navigation's fetch from a load by its `x-rocx-navigate: 1` (`preload` on a
prefetch), so one that counts page views can count navigations and leave prefetches out.

## 5. Loading states and transitions

### 5.1 The old page stays until the new one is ready

Solid Router runs a navigation in a transition: the page stays until the next one's data is in,
and `useIsRouting()` says one is on its way. The same here, and simpler, since the data comes in
one document:

```rocx
import pf.Router

<div class="progress" class:on={Router.is_routing!({})} aria-hidden="true"></div>
<main class:dim={Router.is_routing!({})}>{...children}</main>
```

`Router.is_routing! : {} => Bool` is a tracked read: true from the click until the new page is on
screen (or the navigation fails or is overtaken), false on the server and at hydration. A newer
navigation aborts the one on its way (its fetch's `AbortController`): the last click wins.

### 5.2 `<Loading>` and `is_pending!`

Solid 2.0's model is unchanged: a `<Loading>` shows its fallback until what is inside has its
first values, and a memo read again keeps its last value while `is_pending!` says it is waiting.
A navigation adds nothing to it:

- The new page renders from the seeded answers, so its `<Loading>`s are already satisfied: no
  fallback flashes.
- A read the document didn't carry (a URL built from a signal later, a `refresh!`) waits as it does
  after hydration: the nearest `<Loading>` the first time, `is_pending!` after.
- A kept layout's memo that reads the location (a query read again, §7) shows its last value with
  `is_pending!` true until its answer is in.

Showing the new page at once, with its `<Loading>` fallbacks while its data comes, is possible on
the same machinery (each read waiting on the document's promise, as a read waits on a fetch now),
but the old page staying is the better default: it is what a load looks like to the visitor, with
no skeleton to design, and what Solid Router and SvelteKit do (question 3).

### 5.3 View Transitions

A navigation's flush is synchronous once the document is in, so it fits
`document.startViewTransition(() => commit())`: the browser snapshots the old page, the flush makes
the new one, and it cross-fades, with `view-transition-name` pairing elements across pages. D-031
chose FLIP over the View Transitions API for elements moving within a page (it freezes the page,
names must be unique, and a row coming and another going can't each keep their own transitions);
none of that weighs against it for a whole page changing, which is what it was made for.

It is opt-in, app-wide, with `data-rocx-transitions` on the root layout's `<html>`, and used only
where the browser has it (Firefox only in its newest releases) and `prefers-reduced-motion` isn't
`reduce`. A link or `navigate_with!` can't ask for one alone in the first version (question 10).

## 6. History, scroll, focus, announcements

### 6.1 History

- A navigation pushes an entry (`pushState`); `replace`, a redirect and `<Navigate>` replace the
  current one. Each entry's state is the runtime's: `{ rocx: { key } }`, a random key.
- Back and forward (`popstate`) navigate as a click does, to the entry's URL, without pushing.
  A hash-only change (the browser's own, §3.1) is passed over.
- Solid Router's `state` option (a value stored with the entry) isn't offered: Roc has no value
  of any type to store, and nothing in the examples wants it.

### 6.2 Back and forward: data and scroll

- **Data.** The runtime keeps the last few documents it fetched (eight), by URL, with when they came.
  One at most 10 seconds old is used again, by any navigation (back, forward, a click, a hover's
  prefetch, §11), so going back and forth quickly asks nothing; an older one is fetched again, so
  the page shows the server's data, as a load would. A submission's result empties it, since the data
  changed (question 7).
- **Scroll.** `history.scrollRestoration` is `manual` once the runtime runs. Before leaving an
  entry, the runtime keeps its scroll position by the entry's key, in `sessionStorage` (so a reload
  keeps it too, and the runtime restores it after hydrating). A new entry starts at the top, or at
  the element its hash names; back and forward restore the entry's position after the flush that
  rendered the page. `noscroll` and `navigate_with!(…, { scroll: Bool.False })` leave the scroll
  where it is; a query change (§7) does by default.

### 6.3 Focus

A load puts the focus at the start of the document; an in-place navigation would leave it on the
link, now gone or on another page. So after a navigation the runtime moves the focus to the start
of `<body>` (focused with a `tabindex="-1"` it takes away again), and the next Tab reaches the
page's skip link (the site's `<SkipLink />`, tasks' "Skip to the page"), as after a load. An
element with `autofocus` in the new page takes it instead, and a hash's target if it can be
focused. A query change (§7) leaves the focus where it is. This is SvelteKit's choice (question 8).

### 6.4 Announcements

A screen reader announces a load; an in-place navigation it can't see. The runtime keeps one
visually hidden element, `<div data-rocx aria-live="assertive" aria-atomic="true">` at the end of
`<body>` (a host element: hydration and rendering `<body>` again pass over it), and after each
navigation writes the new `document.title` into it ("Groceries · Acme Tasks"), or the path when
there is no title. Its hiding is set through `element.style` (the CSSOM), which a
`style-src` without `'unsafe-inline'` (packages/guard's CSP) allows. A query change isn't
announced.

## 7. Query and search params

Solid Router's `useSearchParams`, in `pf.Router`:

```roc
Router.use_search_params! : {} => Search
Search.get! : Search, Str => Try(Str, [Missing])           # tracked: the first value of the name
Search.all! : Search => List((Str, Str))                    # tracked: every pair, in order
Search.set! : Search, List((Str, Str)) => {}                # from a handler: merged, "" takes one out
Search.set_with! : Search, List((Str, Str)), { replace : Bool, scroll : Bool } => {}
```

The private app's `?days=`, in place:

```rocx
import pf.Router exposing [use_search_params!]

view! = |_| {
	search = use_search_params!({})
	days! = || search.get!("days") ?? "7"
	stats = Api.get_stats({})
	report! = create_memo!(|| Endpoint.get!(stats.with_query("days=${Server.encode_segment(days!())}")))
	<>
		<nav class:dim={is_pending!(report!)}>
			<button aria-pressed={if (days!() == "7") "true" else "false"} on:click={|| search.set!([("days", "7")])}>7 days</button>
			<button aria-pressed={if (days!() == "30") "true" else "false"} on:click={|| search.set!([("days", "30")])}>30 days</button>
		</nav>
		<ReportTable rows!={report!().rows} />
	</>
}
```

and board's open card, with Back closing it:

```rocx
open! = || Board.card_in_query(Router.location!({}).query)      # tracked, not a signal set once
<a href={"?card=${card!().id}"} noscroll>{card!().title}</a>   # in place; Back closes it
```

- `set!` merges into the query and navigates to the page's own path with it, as Solid Router's
  `setSearchParams` does: an entry pushed, the scroll left where it is (`set_with!` to replace, or
  scroll). A value of `""` takes the name out. Pairs keep the query's order; a name `set!` gives
  replaces every pair of that name.
- `get!` and `all!` read `Router.location!` underneath: a hole or a memo that reads them runs again
  when the query changes, and only those.
- **A change of the query alone is in place** (a link to `?days=30`, `set!`, `navigate!("?days=30")`,
  back and forward between such entries): the runtime pushes the address and commits the location,
  and fetches no document. The page and its layouts are kept (unless one read the location in its
  body, §4.3, which is then made anew, and fetched for); what read the query runs again, and a read
  whose URL changed GETs its endpoint, behind that endpoint's middleware, as `refresh!` does today,
  its last value shown meanwhile. The page's own middleware isn't asked again: it let this page in
  already, and a guard that depends on the query is the endpoint's to keep.
- What is server-rendered and depends on the query (a `<NoHydration>` listing results) doesn't
  follow an in-place change: the browser has no code for it, so nothing in it read the query. Such
  a listing stays out of `<NoHydration>`. (A page-wide "fetch my document on every query change"
  can come later if an app needs one.)

## 8. Head and styles

- **`<Title>`** works as it does: the old page's `<Title>`s go with their computations, the new
  page's register, and after the flush the runtime's `<title data-rocx>` is the last one's.
- **The layout's own head.** Phase 1 renders the root layout anew, `<head>` included, and reconciles
  it: an element the new page renders exactly as the old (a stylesheet's `<link>`, a `<script>`,
  the app's `<style>`) is kept, so nothing loads, runs or flashes again; the others (the layout's
  `<title>`, a description) are replaced; the host's (`data-rocx`) stay. `<html>`'s and `<body>`'s
  attributes are set to the new page's (journal's `<html lang={lang}>`). From phase 2 the root layout
  is kept, and its head's holes patch themselves (D-039 for `meta`); its regions are refreshed from
  the document (§4.3).
- **Scoped styles of pages not yet seen** are already there: rocx build puts every component's and
  page's `<style>` in one stylesheet (`Generated/Styles.roc`), which the root layout puts in every
  page's `<head>`. No CSS has to arrive with a navigation.
- **The cost of that**: on the docs site the stylesheet is 77 KB, 11.7 KB brotli, the largest part of
  every page, sent inline with each load and so with each navigation's document. Writing it as a
  file with its hash in its name (`/rocx/styles-<hash>.css`), which `{=Styles.style}` would link,
  would have the browser keep it once. That is a change of its own, good for loads too (question 9).
  **Built** (2026-11-23, D-040's "As built"): `/rocx/styles-<hash>.css` in the browser's copy beside
  `start.js`, cached `immutable`; inline only in a build with no browser's copy.
- **Per-page assets** in the build: none. The wasm and the stylesheet are the app's, and a page's
  images load as its markup is built.

## 9. Forms, actions and channels across a navigation

### 9.1 Plain forms

- A `method="post"` form to an endpoint a component reads the submission of is sent with `fetch`,
  as now (D-018), on whatever page it is.
- Any other post form is the browser's, as now: it posts, the endpoint answers a flash and a 303,
  and the page loads. It stays so: an endpoint that answers a form without the runtime is already
  written for it, and a page that wants the submission reads it.
- **A GET form** (`<form action="/search">`, the browser's query from its fields) is a navigation
  to that URL, in place by §3's rules (phase 2), as SvelteKit's are: a search box needs nothing of
  the app's.

### 9.2 Submissions and actions

- Submissions are kept by the endpoint's URL in the runtime, not by the page, so one on its way
  when the visitor navigates goes on. Its result revalidates the reads of the page on screen then,
  which is what is shown.
- Its redirect (`x-rocx-redirect`) is followed only if no navigation has happened since it was
  sent: a form sent from one page mustn't move the visitor off the page they went to meanwhile.
- When a navigation is done, the finished submissions of endpoints no component on the new page
  asks for are forgotten, so an old error doesn't show on another page that reads the same
  endpoint later; pending ones stay until answered.

### 9.3 Channels, presence, effects and timers

They are owned (D-017, D-020), and the owner of what a page made is its level:

- **Leaving a page** disposes its level: its effects' cleanups run, its timers stop, its listens
  (`Call.listen!`) are aborted, its channel subscriptions end, its `<Title>`s go. Presence (still a
  listen per tab in packages/presence) leaves when the page's listen ends.
- **The new page** subscribes from its effects after the flush, as on a load.
- **The hub** reconciles once the flush is done: it opens the tab's one stream again only if the set
  of channels changed (a kept layout's subscription and the new page's, the old page's gone), and
  never for a navigation that keeps the set. A reconnect re-subscribes every channel, and each
  hears `Resync`. The tab's id stays (sessionStorage), so hooks see one tab. D-020's fallback (a
  connection id with subscribe and unsubscribe posts, so the stream stays) would spare the
  reconnect; it waits for a measurement.
- **Kept layouts** keep theirs untouched: their effects didn't run again unless what they read
  changed.

## 10. Errors

### 10.1 404 and 500

- **A path no page has** isn't navigated to in place (§3.1): the browser loads it, and whoever
  answers it does (a plugin, a file, the app's 404 page).
- **A page that says 404 itself** (`<HttpStatusCode code={404}/>` for an item that isn't there)
  answers a document with status 404, which is an app document: it renders in place, as the server
  rendered it.
- **A page that fails** answers the error page with status 500 (`Root`'s `<Errored>`, inside the
  root layout): an app document, rendered in place, where the browser's render fails the same way
  from the same answers and shows the same `+error.rocx`.
- **A crash** (Roc crashed: a text 500) isn't an app document: the browser loads the URL and shows
  it, as on a load.

### 10.2 Network failure

A fetch that fails (offline, the server down) falls back to `location.assign(url)`: the browser
shows its own error page, and its reload button retries. A page that stays with nothing said would
leave the visitor clicking a dead link. A prefetch that fails is dropped quietly.

### 10.3 A stale build

When the server is deployed with a new wasm, a tab still running the old one must not render the
new server's documents: their answers may have shapes the old wasm can't parse, and the route table
may have changed.

- rocx build gives each build an id: a hash of the app's sources it builds from (its `.rocx` and
  `.roc` files, the packages' it copies), the same in both copies.
- The server writes it on the bootstrap, `<script type="module" data-rocx data-build="7f3a91c2"
  src="/rocx/start.js">`; the browser's wasm hands it to the runtime with the route table (§3.2).
- A fetched document whose `data-build` isn't the wasm's (or that has none) is loaded instead:
  `location.assign(url)`, which brings the new wasm. A prefetched one is dropped.

The id changes with any source change, server-only ones too; the only cost is a load on the next
navigation after a deploy. A later read (`refresh!`) of a new server from an old tab is a separate
question (an answer header `x-rocx-build` the runtime could check), not this design's.

## 11. Prefetch

- **On hover, focus or touch.** A link the runtime would navigate to in place is prefetched when
  the pointer has rested on it for 65 ms, when it is focused, or at once on `touchstart`: the same
  fetch as a navigation's, with `x-rocx-navigate: preload` and `priority: "low"`. Solid Router
  preloads on hover by default too.
- **On sight**, opt-in: `data-rocx-preload="viewport"` on a link or an ancestor prefetches links as
  they scroll into view. `data-rocx-preload="off"` turns prefetching off for a link or a subtree,
  `"hover"` is the default, and the nearest ancestor's value wins, so the root layout's `<html>`
  sets it for the app. `<A preload={Bool.False}>` writes it.
- **The cache** is the one back and forward use (§6.2): eight documents by URL, each used for 10 s,
  dropped by a submission's result (the data changed) and by a build mismatch. A click on a link
  whose prefetch is still on its way waits for that fetch rather than asking again.
- **The server's side**: a prefetch is a page render. That is what Solid Router's and SvelteKit's
  preloads cost too; a middleware that counts views can leave out `x-rocx-navigate: preload`, and an
  app whose pages are costly to render sets `data-rocx-preload="off"`.

Prefetching code isn't needed while the wasm holds every page. If wasm splitting comes back
(`spike/wasm-split`, parked), a prefetch fetches the page's chunks too, which is where splitting
pays off.

## 12. What the server and the build add

### 12.1 The server

No route, no data endpoint, no new kind of answer:

- the page's GET is answered as now, for a load and for a navigation alike;
- `Router.app!` (generated, §3.2) is a hosted call on both platforms: on the server, the host keeps
  the build's id for the render and writes it on the bootstrap (`data-build`, beside
  `signals.rs`'s `START`);
- that is the whole of it. `x-rocx-navigate` is the browser's header, passed on like any other.

### 12.2 The build

- `Generated/Root.roc` calls `Router.app!` with the route table and the build's id, and from phase 2
  renders each route level as a keyed part (§14).
- `rocx build` computes the build's id.
- Under `--dev`, the stories' paths join the table.
- From phase 2, a layout is given its own params, and every page under a layout must give it a
  `meta` of one type (both hold in every app in the repo).

### 12.3 Static sites

`just site` writes every page as the server answers it, so navigation works on GitHub Pages with
nothing added:

- the document a navigation fetches is the page's `index.html` (GitHub Pages answers `/syntax` with
  a 301 to `/syntax/`, which `fetch` follows; a redirect that only adds the trailing slash is the
  same page, and the address stays the link's);
- a path that wasn't prerendered (a page with params) gets GitHub Pages' `404.html`, with status
  404: an app document, the site's error page, rendered in place, as the load would have shown it;
- channels and actions answer as they do on a static copy now (`Refused(404, …)`, no server).

One fix is needed first, independent of navigation: under a base (`--base=/rocx/`), a URL the
runtime writes into the page (an `href`, `src` or `action` it builds or patches) must get the base,
as `underBase` gives the server's at export. Today an element the wasm builds under a base has
`href="/syntax"`, and a computed `href` is patched to it as the page hydrates. Navigation would
make every link the wasm's, so the runtime puts the base on the URLs it writes, as it already does
on those it fetches (`under`).

### 12.4 Wasm size and the runtime

- **The wasm doesn't grow**: every page's code is in it already. Phase 1 adds `Router.app!`,
  `navigate!` and the table to `Root` (a few hundred bytes); phase 2's levels make `Root` a little
  larger, as each page gets a branch for its key beside the one it has; `<A>`, `<Navigate>` and
  `Search` are small, and only the apps that use them pay for them.
- **`runtime.js` grows** by what §3–§11 describe: clicks and opt-outs, the table, the fetch and its
  fallbacks, the commit, the head's reconciliation, history, scroll, focus, the announcer and the
  cache. Roughly 400 lines; a few KB brotli, measured with the site's facts when built.
- **Splitting** stays parked; navigation is where it would pay off (§11).

## 13. The API, beside Solid Router's

| Solid Router | Roc Solid | Notes |
|---|---|---|
| plain `<a>` intercepted | the same (§3.1) | opt-outs as Solid Router's, plus the route table |
| `<a replace noscroll>`, `rel="external"` | the same | |
| `explicitLinks` | `data-rocx-navigation="explicit"` (or `"off"`) on `<html>` | |
| `<A href end activeClass inactiveClass replace noScroll>` | `<A href end active_class replace noscroll preload>` | `aria-current="page"` when active |
| `useNavigate()(to, { replace, scroll, state })` | `navigate!(to)`, `navigate_with!(to, { replace, scroll })` | from handlers; no `state` |
| `<Navigate href>` | `<Navigate href>` | a 303 on the server |
| `redirect()` | middleware's 303, an endpoint's `Server.redirect` | followed in place |
| `useLocation()` | `Router.location!({})` | now tracked; `{ path, query }`, no `hash` |
| `useParams()` | the `params` prop | a page with new params is made anew |
| `useSearchParams()` → `[params, set]` | `use_search_params!({})` → `get!`, `all!`, `set!`, `set_with!` | in place |
| `useIsRouting()` | `Router.is_routing!({})` | |
| `useMatch(path)` | `<A>`'s active state | a `matches!` later, if an app wants it |
| `useBeforeLeave()` | `use_before_leave!(|leave| …)` (built after phase 2: D-040's As built) | `leave.prevent!()`, `leave.retry!(force)`; back and forward put the address back; a load, `beforeunload` while one would stop it |
| route `preload` + `query` cache | the page's document (its reads, in-process) and the prefetch cache | no wrapper to write |
| preload on hover | the same, `data-rocx-preload` | |
| navigation in a transition | the old page stays until the document is in | |
| `<Router base>` | `Runtime.load(…, { base })`, as now | |

**Moving to it.** Apps change nothing to have navigation in place. What they may want to change,
to get more from it:

- Read the location where it changes: `Router.location!` in a hole or a memo, not at the top of a
  layout's body, so the layout is kept (§4.3). The site's layout, tasks' and journal's read it at
  their top today; they work as they are, made anew on each navigation, and are kept once moved.
- Turn query workarounds into the query: board's `?card=` read with `Router.location!` in a memo
  rather than a signal set once, so Back closes the card; links to `?days=30` or `set!`.
- `<A>` where a layout computes `aria-current` by hand.
- Page JavaScript that set itself up once per load (`site/static/site.js`, an analytics snippet)
  listens for `rocx:navigated` on the document too, as it does for `rocx:ready`; a `<script>` a page
  renders runs on a load and not after a navigation in place (a script the runtime builds never
  runs, as in Solid).

## 14. Generated code

Today (`examples/tasks`, abridged): `Root.view!` reads the location once, as the root computation,
and renders the page in its layouts.

```roc
view! = |{}| {
	path = Router.location!({}).path
	segments = path.split_on("/").keep_if(|segment| !segment.is_empty()).map(Server.decode_segment)
	if (segments == ["me"]) {
		params = {}
		Html.component(|| RootLayout.view!({ params: params, meta: MePage.meta, children: [Root.guarded!([Html.component(|| MePage.view!({ params: params }))])] }))
	} else if (segments.len() == 2 and segments.get(0) == Ok("lists")) {
		params = { id: segments.get(1) ?? "" }
		Html.component(|| RootLayout.view!({ params: params, meta: ListsIdPage.meta, children: [Root.guarded!([Html.component(|| ListsIdPage.view!({ params: params }))])] }))
	} else { … }
}
```

**Phase 1** leaves the matcher as it is and adds one call: the location is tracked, so the root
computation runs again when a navigation commits, and renders the document anew from the seeded answers (the path
hydration takes after a mismatch, with the head reconciled instead of kept).

```roc
view! = |{}| {
	Router.app!({ build: Root.build, dev: Bool.False, pages: Root.pages })
	path = Router.location!({}).path          # tracked now: runs again on each navigation
	…                                          # as today
}

build = "7f3a91c2"
pages = ["/", "/me", "/lists/[id]", "/tasks/[id]"]
```

**Phase 2**: a level per layout and the page, each a keyed part (`Html.keyed!(key!, make!)`: a hole
whose part is made anew, with a new owner, when the `Str` its key gives changes; the runtime adds
the location to a level's key when the level read it untracked, §4.3).

```roc
Route : [Home, Me, ListsId({ id : Str }), TasksId({ id : Str }), Missing(Str)]

view! = |{}| {
	Router.app!({ build: Root.build, dev: Bool.False, pages: Root.pages })
	route! = create_memo!(|| Root.route(Router.location!({}).path))
	# The root layout: one key, so kept for every page; its meta a value prop (D-039).
	Html.keyed!(|| "routes/+layout.rocx", || Html.component_with(|| { params: {}, meta: Root.meta(route!()), children: [Root.page!(route!)] }, RootLayout.view!))
}

## The page: made anew when its route or its params change, not its query.
page! = |route!| Html.keyed!(|| Root.key(route!()), || match route!() {
	Home => Root.guarded!([Html.component(|| RootPage.view!({ params: {} }))])
	Me => Root.guarded!([Html.component(|| MePage.view!({ params: {} }))])
	ListsId(params) => Root.guarded!([Html.component(|| ListsIdPage.view!({ params }))])
	TasksId(params) => Root.guarded!([Html.component(|| TasksIdPage.view!({ params }))])
	Missing(path) => Root.failed(404, "nothing at ${path}")
})

route : Str -> Route                  # the matcher Root has today, answering a tag
key : Route -> Str                    # "routes/lists/[id]/+page.rocx id=7"
meta : Route -> { title : Str }       # each page's meta; one type for the layout
```

A nested layout (`routes/lists/[id]/+layout.rocx`) is one more keyed level between the two, keyed
by its file and `id`, given `{ id }`, its children the page's level. The server renders the same
code: each keyed part runs once, and its comments mark the level's range, which is where the
runtime finds a level's regions in a fetched document.

## 15. A phased plan

Each phase lands on its own, with its tests and its docs (README's Routing and Syntax,
`web/README.md`, the docs' routing and components pages, the platform reference for every new
function's `##` comment), and leaves every app working unchanged.

### Phase 1: links and `navigate!`, the page made anew

The smallest useful step: no document loads between the app's pages, and no app changes.

- **Runtime**: the location as a tracked source, committed by navigations; the click listener and
  its opt-outs (§3.1); the route table; `navigate!`, `navigate_with!`, queued with a handler's
  writes; `popstate`; the document's fetch, with its fallbacks (not an app document, a crash, another
  build, a failure: `location.assign`) and redirects followed; the root computation run again with
  the fetched answers, flash and regions, `<body>` made anew and `<head>` reconciled; the documents' cache
  (§6.2); `Router.is_routing!`; scroll (top, hash, restored), focus, the announcer; `rocx:navigate` and `rocx:navigated` events with
  `{ url, ms }`; the base on URLs the runtime writes (§12.3); submissions' redirects in place (§9.2).
- **Platform**: `Router.navigate!`, `navigate_with!`, `Router.is_routing!`, `Router.app!` (hosted,
  both platforms); the host's `data-build`.
- **Build**: `Root` calls `Router.app!` with the table and the build's id.
- **Tests** (`web/test`, a small app with a layout and three pages): a click renders the next page
  without a load (a value set on `window` survives), its answers read from the document and nothing
  asked (strict); each opt-out keeps the browser's navigation (modifier keys, `target`, `download`,
  `rel="external"`, another origin, a path no page has, a hash on the same page); `navigate!` from a
  handler that waits and runs again navigates once; back and forward with the scroll restored and
  the document reused within 10 s; `is_routing!` true while a slow document is on its way, and
  false after it and after one overtaken; a middleware's redirect lands on its page with its address; a
  text 401, a crash, a refused fetch and another build each load the URL; the layout's `<title>`,
  a `<Title>` and the announcement follow; the focus is at `<body>`'s start; effects, timers and a
  channel of the old page stop and the new page's start, with one stream reconnect; 200 navigations
  leave no allocation behind. `site/test`: every page of the site reached by navigating in place is
  the page a load renders, byte for byte outside the host's elements, natively and as the files
  GitHub Pages serves under `/rocx/`. `server/test`: the bootstrap carries `data-build`.
- **Costs**: about 400 lines of runtime, 100 of platform and build; a few KB brotli of runtime; no
  wasm growth to speak of. What it gives up: layouts aren't kept yet (a sidebar's scroll, an open
  menu, a layout's signals are made anew), so it is a faster load, not yet an app shell. Hub
  subscriptions are re-made with the page; the stream reconnects only if their set changed.

### Phase 2: kept layouts, the query in place

Depends on D-039 (value props patched in place, for a layout's `meta`).

- **Runtime**: keyed parts; levels; untracked location reads noted per level, and a level that has
  one made anew (with a console line in a dev build); a query change in place (§7); a kept level's
  regions refreshed from the document; GET forms as navigations; finished submissions forgotten.
- **Platform**: `Html.keyed!` (Solid 2.0's keyed `<Show>`, usable by apps too); `use_search_params!`
  and `Search`; `<A>`; `<Navigate>`, with the server's 303.
- **Build**: `Root` as levels; a layout given its own params; one `meta` type per layout, checked.
- **Apps**: the site's, tasks' and journal's layouts read the location in holes and memos, so
  they are kept; board's card is `?card=` read in a memo, so Back closes it; tasks' list links are
  `<A>`.
- **Tests**: a kept layout's signal and an input's text survive a navigation; a layout that read
  the location in its body is made anew (and says so in a dev build); a page is made anew when its
  params change and kept when only its query does; a query change re-reads only what read it (the
  observer's fetches counted) and asks for no document; `set!` merges and `""` takes out; a kept
  layout's region changes with the page (journal's masthead); `<A>`'s active state follows;
  `<Navigate>` is a 303 on the server and a replace in the browser; a GET form navigates; the
  byte-for-byte test of phase 1 with layouts kept.
- **Costs**: about 300 lines of runtime, the levels in `Root`, `Html.keyed!` on both platforms
  (the server's keyed part is a hole that runs once). The three layouts' migration is small and
  optional. The risk is the untracked-read rule (§16).

### Phase 3: prefetch and transitions

- Prefetch on hover, focus and touch, and `data-rocx-preload`; View
  Transitions behind `data-rocx-transitions`; `use_before_leave!` (Solid Router's, for an unsaved
  form) if an app asks.
- **Tests**: a hovered link's click asks nothing more (one request); a prefetch older than 10 s is
  fetched again, and a submission's result empties the cache; `preload="off"` and `viewport` honoured;
  a View Transition only when asked for and available, never with less motion asked for.
- **Costs**: about 150 lines of runtime. Prefetch makes the server render pages that may never be
  shown.

### Phase 4, only if measured

- The stylesheet as a cached file (§8), which pays for loads too, and could come first on its own.
- A JSON payload instead of the document, if a page's markup ever outweighs its regions.
- Wasm splitting with prefetched chunks (`spike/wasm-split`).
- The hub keeping its stream across a change of channels (D-020's connection id).

## 16. Risks

- **The untracked-read rule** (§4.3) attributes a read to the level it happened in. A read in a
  helper module called from a body is attributed correctly (it is the same run); a read in a
  handler or an effect's apply isn't counted: those run when they run, against the committed
  location, so they never show an old one. If a case slips through, the fallback is rocx's warning at a layout's
  top-level `Router.location!`.
- **D-039's shape.** Phase 2 needs a layout's `meta` to patch in place. If D-039 lands otherwise,
  layouts get `meta` as an accessor (`meta!`), which is a change to every layout, or keep phase 1's
  rule for the root layout.
- **Leaks.** An aborted run leaks a few allocations (the JavaScript throw skips Roc's drops,
  `web/README.md`); navigation renders from seeded answers, so its runs rarely abort, but long-lived
  tabs make more of them. Phase 1's test of 200 navigations watches `live_allocations`.
- **Scripts.** A `<script>` a page renders runs on a load and not after a navigation in place. Page
  JavaScript moves to `rocx:navigated`.
- **Third parties.** Analytics that count loads see one load per visit; `rocx:navigated` is their
  hook. Extensions that changed the page are rendered over on the next navigation, which is fine.
- **Static hosts** other than GitHub Pages may answer `/syntax` differently (no redirect, a
  `syntax.html`); the runtime asks for the URL the link has, and takes what `fetch` ends at.

## 17. Open questions for the user

**Answered (2026-11-23): every recommendation below, as written** (2 is plain `<a>`, 10 is the app-wide
opt-in). Each has a recommendation; the design above assumes it.

1. **What a navigation fetches.** (a) The page's own HTML document, as the server answers a load
   (no server change; static sites work; 2–16% larger than (b), measured); (b) a JSON data endpoint
   per page (SvelteKit's `__data.json`): a little smaller, a second way to answer every page, and a
   second file per page on a static host. **Recommend (a)**, with (b) as a later optimisation if a
   measurement asks.
2. **Plain `<a>` or only `<A>`.** (a) Every same-app `<a>` navigates in place (Solid Router's
   default), opt-outs per link, and an app-wide `data-rocx-navigation="explicit"` or `"off"`; (b)
   only `<A>`. **Recommend (a)**: apps and Markdown get it with no change.
3. **While the next page's data comes.** (a) The old page stays until the document is in, with
   `Router.is_routing!` for a progress bar (Solid Router, SvelteKit); (b) the new page at once, with
   its `<Loading>` fallbacks. **Recommend (a)**; (b) can come later per link if an app wants
   skeletons.
4. **A page whose params change.** (a) Made anew (its `params` is a plain value, read in its body to
   build its endpoints); (b) kept, as Solid Router keeps it, with params as accessors (a change to
   every page). **Recommend (a)**.
5. **Which layouts stay mounted.** (a) Kept while their file and own params are the same, unless
   they read the location (or, with D-039, a prop) once in their body and it changed, which the
   runtime detects; (b) always kept, as in Solid, stale where a body read once; (c) never kept.
   **Recommend (a)**: kept where it is safe, and no app breaks.
6. **A change of the query alone.** (a) In place: no document, the page kept, only what read the
   query reads again (its endpoints' middleware still runs); (b) a document fetched like any
   navigation (the page's middleware runs again, regions follow). **Recommend (a)**: it is what
   `?days=` and `?card=` want, and it is Solid Router's model; a part that depends on the query stays
   out of `<NoHydration>`.
7. **Back and forward.** (a) A document fetched within 10 s is used again, any older one fetched
   anew, the scroll restored either way; (b) always fetched (always fresh, slower); (c) every
   history entry keeps its document (instant, possibly stale). **Recommend (a)**.
8. **Focus after a navigation.** (a) The start of `<body>`, so the next Tab reaches the skip link,
   `autofocus` and a hash's target winning, and the title announced (SvelteKit's); (b) the page's
   `<h1>` or `<main>`, which needs every app to have one. **Recommend (a)**.
9. **The app's stylesheet.** Today it is inline in every page's `<head>` (11.7 KB brotli on the
   site, the largest part of each page and of each navigation). (a) A file with its hash in its name,
   linked by `{=Styles.style}`, cached by the browser; (b) inline, as now. **Recommend (a)**, as its
   own small change, before or beside phase 1.
10. **View Transitions.** (a) App-wide opt-in (`data-rocx-transitions` on `<html>`), where the
    browser has them and motion isn't reduced; (b) on by default; (c) per link. **Recommend (a)**,
    with (c) later if an app wants a page to change differently.
11. **Prefetch.** (a) On hover, focus and touch by default (Solid Router's default), off per link or
    subtree, `viewport` opt-in; (b) off unless asked (SvelteKit's). **Recommend (a)**: the server
    renders a page a hover may not open, which is the price of a click that asks nothing.
12. **Order of work.** Phase 1 doesn't need D-039 and changes no app; phase 2 does. **Recommend**
    phase 1 now (with question 9's stylesheet file if you agree), phase 2 once D-039 has landed,
    phase 3 after.

## 18. Ready for wasm splitting (not built now)

The user wants wasm splitting later (`spike/wasm-split`, parked on a compiler fix: Roc's wasm linker
keeps no relocations). Navigation is where it pays: the first load would download the main module
and the page's own chunk, and later pages their chunks. So the phases above keep to four rules,
which cost nothing while the wasm holds every page:

1. **One step reaches a page's code.** Rendering a matched level goes through one runtime function
   (`pageCode(level)`, say), which answers at once today. With splitting it loads the level's chunks
   (in parallel with the document) and the render waits on it, as it waits on the document.
2. **The route table names each level's code.** `Router.app!`'s table gives every page and layout an
   id the build chose (its module), not only a path. Splitting maps an id to its chunks; nothing
   in the runtime assumes every id's code is already there.
3. **Prefetch is about a page, not a document.** Phase 3's prefetch asks for "what page X needs",
   which is its document today and its document plus chunks later, under one cache entry with one
   age (§6.2).
4. **The build id guards code too.** §10.3's check (a document of another build is loaded by the
   browser) is also what keeps an old tab from asking for chunks a new deploy replaced: chunk names
   carry the build's hash.

What stays as it is: hydration and `<NoHydration>` regions (their code is never in the wasm), and
the server, which renders every page whole either way.
