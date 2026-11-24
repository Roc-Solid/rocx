# Roc Solid

A small web framework for [Roc](https://www.roc-lang.org): one app, from the database to the
browser, in three parts.

- **rocx**, the markup. A `.rocx` file is Roc in which markup may stand wherever an expression can;
  `rocx build` turns it into the plain `.roc` file beside it, line for line, so the compiler checks
  every value put in a page, and reports at your lines. `rocx` is the command-line tool, too: Roc
  itself, on a small command-line platform of the repo's own (`cli/`), one native executable.
- **The platform**, what an app runs on: on the server, Roc compiled to native code in a Rust host
  (`server/`), with a database (Postgres, or SQLite in the server's process, on SQLite's engine or
  Turso's), channels and live
  rooms, a key-value store, actors and plugins;
  in the browser, the components, compiled to WebAssembly (`web/`).
- **The ecosystem**: packages of plain Roc, components and plugins that any app can use, in
  `packages/`: charts, forms, Markdown, intl, an admin, guards, jobs and cron, email, MCP, presence,
  Web Push, OpenTelemetry, storage (S3, files, memory), crypto, QR codes, testing and virtual lists.

Pages are components, after Solid 2.0: a component runs once and makes signals; each hole in its
markup that calls something named with `!` (a signal, a memo) is a computation that runs again when
what it read changes, and patches its own node, and the others are written once. The server renders
the whole page, and in the browser the same Roc, compiled to WebAssembly, hydrates it.

```roc
import pf.Html
import pf.Solid exposing [create_signal!]

Counter := [].{
	view! : { start_value : I64 } => Html
	view! = |{ start_value }| {
		(count!, set_count!) = create_signal!(start_value)
		<p class="counter" class:negative={count!() < 0}>
			<button on:click={|| set_count!(count!() - 1)}>−</button>
			<output>{count!().to_str()}</output>
			<button on:click={|| set_count!(count!() + 1)}>+</button>
		</p>
	}
}
```

An app is two programs, one on each platform, talking over HTTP. The docs site in `site/` is one:
written in rocx, with a front page for Roc Solid and a part for each of rocx, the platform and the
ecosystem. `just dev`, then http://localhost:8080.

## Getting started

```sh
git clone https://github.com/Roc-Solid/rocx && cd rocx
just setup                     # the toolchain into .tools/, then bin/rocx
export PATH="$PWD/bin:$PATH"
# an app is a folder of its own, anywhere, with routes/ in it: a page in
# my-app/routes/+page.rocx, or an endpoint in my-app/routes/hello/+server.roc
cd ../my-app
rocx dev                       # http://localhost:8080, built again on each save
```

The first run writes `main.roc` at the app's root, beside `routes/`, and builds the server's host
(a few minutes, once). `rocx dev <dir>` serves the app in another folder.
[`examples/hello`](examples/hello) is that app: a page with a button that counts, and `GET /hello`.

## Quick start

Zig 0.17.1 and Rust ≥1.85 from your system (e.g. Nix), or `just setup` downloads them. Roc is a
fork of the pinned nightly with the compiler fixes rocx needs, which `just setup` builds into
.tools/ from the fork, or, without the fork, downloads prebuilt from this repository's release of
it (for macOS on Apple silicon and Linux on arm64; the Justfile says why); never the `roc` on your
PATH.

```sh
just setup   # the Roc fork rocx builds with, the pinned nightly, Zig and Rust if need be, into .tools/; then bin/rocx
just compiler-bugs   # each Roc bug rocx has met, with the nightly and with the fork
just test    # the transpiler, both platforms, every package, the site in Chromium
just dev     # the docs site, its server (native) answering each page, rebuilt on save
just db      # a Postgres in Docker for the server platform (prints its DATABASE_URL); SQLite apps need none
just site    # the docs site as static files in site/dist, every page as its server answers it
just deploy-pages  # build that and publish it to roc-solid.github.io (site/dist, one commit)
just check   # type-check the site's two programs (reports at .rocx lines) and the packages' server modules, and lint it
```

| Where | What |
|---|---|
| `cli/` | the command-line platform rocx is built on (D-062): its Roc modules (`cli/platform`: output, files, commands run to their end or beside it, a directory tree watched, signals, and `Events.next!`, the one wait for whichever comes first) and its Rust host on the C library alone (`cli/host`; on macOS, FSEvents loaded at run time); see its README |
| `rocx-cli/` | rocx, in Roc on the CLI platform (`cli/`): `rocx dev` (`Dev.roc`; `rocx site dev`, `SiteDev.roc`, is `just dev`), `rocx check --sql` (`CheckSql.roc`), the docs site's generated modules (`rocx site prepare`: `Site.roc`, `SiteSources.roc`, `SiteReference.roc`), the transpiler (`Transpile.roc`), scoped styles (`Styles.roc`), routing (`Routes.roc`), stories, error remapping, `rocx fmt`, the build (`Build.roc`) and its warning where the browser's copy reaches what only the server has (`ServerOnly.roc`), the command (`main.roc`); built into `bin/rocx` whenever its Roc changed (`server/build.mjs`'s `rocxBinary` for the JavaScript, `rocx self-build` for the Justfile; `just rocx-bootstrap` makes the first one, without Node). `rocx-cli/rocx.mjs` calls its functions from the repo's JavaScript tests by name (`rocx internal`) |
| `packages/charts` | bar, stacked bar, line, sparkline, donut, scatter and heatmap charts, styled by custom properties: their arithmetic a Roc package (scales, round ticks, SVG paths, in `Dec`), their components copied into each app by `rocx build`; see its README |
| `packages/crypto` | SHA-256, HMAC, HKDF, Base64 and hex in plain Roc, on no platform, each checked against its RFC's vectors; see its README |
| `packages/storage` | files in a bucket whose URL says where (D-047): any S3, a directory beside the server, or memory for tests; objects, multipart uploads, signed URLs (a plugin answers a directory's), and objects served without passing through Roc; see its README |
| `packages/jobs` | jobs and cron as a plugin (D-034): work queued in the app's database (Postgres or SQLite) and run by workers, again if it fails, and schedules; `Job.plugin({ jobs: App.jobs, crons })`; see its README |
| `packages/email` | email as a plugin (D-035): over SMTP (`SMTP_URL`, `MAIL_FROM`), or kept for the dev mailbox at `/__rocx/mail` under `--dev`; `Email.plugin({})`, `Email.send!`; see its README |
| `packages/push` | Web Push as a plugin (D-051): `Push.plugin({})` brings its endpoints, the subscriptions' table, the job that sends (on the jobs plugin), the service worker at the site's root and the page's script; `<PushButton>`, `Push.notify!`; see its README |
| `packages/audio` | sound files from a handler, as a plugin (D-051): `Audio.play!` in either half, and `AudioPlayer.plugin({})`, the player, a script every page loads; see its README |
| `packages/vibrate` | the phone's vibration motor from a handler, as a plugin: `Vibrate.once!(ms)` and `Vibrate.pattern!([on, off, on…])` in either half, and `Vibrator.plugin({})`, the browser's half (`navigator.vibrate`); an Android app on the native host (D-063) buzzes with no script; see its README |
| `packages/*` | the other packages: `admin` (a Django-style admin for Postgres tables, and the jobs page), `forms`, `guard` (rate limits, feature flags, request guards), `intl`, `markdown`, `mcp`, `otel` (OpenTelemetry metrics and logs), `presence`, `qr` (QR codes in plain Roc, and `<QrCode>`), `testing` and `virtual` (lists of any length that render only the rows that show); each has a README, a PROPOSALS.md of what it waits on, and a page on the docs site. A package whose modules use the server platform names it in its `main.roc`, with a `browser.roc` beside it for what the browser's half sees (D-033); mcp's and otel's server modules are a package of their own, `server/main.roc` |
| `web/` | the browser's platform: the modules components are written with (`Html`, `Solid`, `Store`, …) and HTTP's (`Server`, requests and answers; `Endpoint`, `Channel`, `Events`, `Middleware`, `OpenApi`), which the server's platform has too; its Zig host, `runtime.js`; see `web/README.md` |
| `server/` | the server's platform: native Roc in a Rust host (tokio, hyper, Postgres or SQLite, plugins, channels, actors, `Kv`), rendering pages of components; see `server/README.md` |
| `site/` | the docs site: pages in `routes/`, the demos on them in `Demos/`, its program in `main.roc`, real examples in `examples/` |
| `test/`, `web/test/`, `site/test/`, `server/test/`, `packages/testing/test/` | the transpiler and routes; the browser's platform; the site in a browser; the server's platform; the testing package's helpers |
| `examples/` | whole apps, each small enough to read end to end, with its README and its tests (below) |
| `spike/suspense` | an experiment: how a read that has to wait can stop a computation in wasm |

## Examples

Each is a whole app in `examples/<name>`, with a README that tours it, maps each feature to the
file that shows it, and says what it asked of the platform. `just examples` builds, checks and
tests them all (`just examples tasks` one); `just check` type-checks them. The docs' examples page
(`/examples`) shows each with what its browser half weighs and what it is made of, and the
server's benchmark, and each has a page of its own with screenshots: `just example-apps` measures
them into `site/example-apps.json` (`--bench` runs echo under bombardier too), and
`just example-shots` takes the screenshots into `site/static/shots/`.

Every example with a database is on SQLite (D-045): a file beside its server, so each runs with
nothing else.

- [`hello`](examples/hello): the app Getting started makes, a page with a button that counts and
  `GET /hello`; its `main.roc` is the one `rocx dev` writes.
- [`tasks`](examples/tasks): Tasks, a small team's task lists. Start here: file routing, a
  middleware, a database (SQLite), pages that read endpoints, forms that work without JavaScript, and
  optimistic actions, in the plainest way, with comments throughout.
- [`echo`](examples/echo): the smallest app on the server platform, two endpoints (a JSON string,
  and an order that nests), for measuring the server and what reading and writing JSON adds
  (`bench.sh`).
- [`sqlite-vs-turso`](examples/sqlite-vs-turso): the same database work timed in Roc on SQLite and
  on Turso (MVCC, and WAL): writes, reads, scans, JSON, a recursive query, and eight actors writing
  at once; `just db-bench` puts its numbers on its docs page.
- [`journal`](examples/journal): Journal, a small publication in English and Polish: Markdown
  posts with typed frontmatter, intl, feeds, and two islands on pages the server renders.
- [`board`](examples/board): Board, a live kanban board several people move cards on at once:
  drag and drop, optimistic moves, channels, presence and an edit lease in Kv.
- [`quiz`](examples/quiz): Pinwheel, a live quiz for a room full of phones: an actor per room with
  its own timers, a channel to every phone, and charts of how the room answered.
- [`uptime`](examples/uptime): Status, an uptime monitor and its status page: checks run by
  jobs and cron, incidents that open and close themselves, email alerts, metrics, the admin's
  tables, and a page that follows it all live over a channel.
- [`notes`](examples/notes): Notes, personal notes in Markdown that AI agents use over MCP:
  sign-in by a mailed link, a signed session cookie, personal access tokens kept as hashes,
  full-text search (SQLite's FTS5), a live preview, and a JSON API with its OpenAPI page.
- [`pomodoro`](examples/pomodoro): Pomodoro, a focus timer, the same page in a browser and as an
  Android phone's native views (`rocx dev --android`): a timer kept by a deadline, a ring in SVG,
  a chime and a buzz from its end (packages/audio and packages/vibrate, each with a phone half), and
  today's sessions in SQLite.
- [`plate`](examples/plate): Plate, a food diary for a phone: the USDA's 7,500 foods seeded
  into its SQLite file, packets looked up by barcode in Open Food Facts, recipes that log like foods,
  targets worked out from a profile, trends charted, and a search that follows the typing.
- [`checkboxes`](examples/checkboxes): Million, a million checkboxes that everyone with the page
  open shares, live: a virtual list (packages/virtual) that renders only the rows that show, the
  boxes in the server's memory (`Kv`), and a channel that sends each chunk that changes.

## Pages and components

Every `.rocx` file is components, written with the platform's `Html` (`import pf.Html`): its holes
are computations, its handlers effects, and it runs on the server and in the browser. Pages,
layouts and the error page are components too, so a page puts a component where it wants it, as
`<Todos first={…} />`, under the contexts it provides.

A component's view is pure or effectful, and Roc checks which. `view!` may make signals, read a
context or read an endpoint, so it runs once, where it is rendered
(`Html.component(|| Counter.view!({ start_value: || 3 }))`), and its props are getters, as Solid's
are (D-039): written `start_value : U64` and `|{ start_value }|`, read where its code reads them, so a
hole that reads one is patched and the component kept. `view`, without the `!`, can't: it makes
markup from its props, values, so it is called where it is written (`Heading.view({ id: "why",
children: […] })`), and given a value read from what changes, its call is a hole of its own. Its
holes may still read accessors it was given; those are computations, as anywhere. `rocx build`
writes whichever call fits, so callers don't change when a component does.

## Styles

A `<style>` in a component's block, beside its definitions, styles that component's markup and
nothing else, as Svelte's does: rocx gives each element written in the block a class named after
the component (`rx-49lxy6`), and adds it to each selector, so `.card .title` is
`.card.rx-49lxy6 .title:where(.rx-49lxy6)`, one class more specific than written. Two components'
`.card` never meet, even in one file, and a component's styles don't reach into the components it
renders. A page or a layout has no block: its `<style>` goes at the file's top level, for the whole
file. `:global(…)`, `.a :global .b` and `:global { … }` are left as written; a component's
`@keyframes` are its own (`-global-name` for everyone's). `rocx build` puts every `<style>` in one
stylesheet, `Generated/Styles.roc`, which the root layout puts in its `<head>` with
`{Styles.style}`: a `<link rel="stylesheet" href="/rocx/styles-<hash>.css">` to a file the build
writes beside `start.js` (`--client <out>`: `<out>/static/rocx/`), named by its content's hash, so
the browser keeps it once for every page and every navigation, and the server says it may keep it
for good (`cache-control: public, max-age=31536000, immutable`); a change to any `<style>` is a new
name (D-040). A build without a browser's copy has nowhere to put the file and keeps the stylesheet
inline, in a `<style>`. A file may define several components (`Stepper := [].{ … }`), and
`<Stepper />` calls the file's own.

```roc
Counter := [].{
	view! = |{ start_value }| <div class="counter">…</div>

	<style>
		.counter { display: flex }
		.counter.negative output { color: crimson }
	</style>
}
```

## Stories

A component's stories are the ways it looks, written beside it, as Storybook's are: a
`<story name="Tip">…</story>` in its block, among its definitions. Each becomes a definition in
its place, so every build checks it against the component, and only a dev build calls it:
`rocx build --dev` (`just dev`) adds a catalog at `/__rocx/stories`, with each story down the side
(which folds away), the one picked in a frame that can fill the window, and a component's stories
side by side. A story is `story_tip! = |{}| …`, the app's page at its path, which `Root` renders in the root
layout and the browser hydrates; it can tell it is a story by its path (`/__rocx/stories/…`). An app's
`stories/` directory holds modules of stories alone, drafts side by side, each a component with its
own `<style>`; only a dev build has it, so nothing in it, its styles neither, is published
(`site/stories/Landing.rocx`: the front page as it is, and drafts of it in six themes).

```roc
Callout := [].{
	view = |{ kind, title, children }| <aside class={"callout callout-${kind}"}>…</aside>

	<story name="Tip">
		<Callout kind="tip" title="Name holes by what they hold"><p>…</p></Callout>
	</story>
}
```

## Packages with components

A Roc package can't hold components for a rocx app. The compiler lets a package name a platform,
but only the very one the app names, and an app is two apps on two platforms. So a package may
keep components in a `components/` directory beside its `main.roc`, and when an app's header names
the package (`charts: "../packages/charts/main.roc"`), `rocx build` copies each one into the app
(`Generated/charts/BarChart.roc`), where `pf` is each half's own platform. In a `.rocx` file,
`import charts.BarChart` imports that copy. Its `<style>` joins the app's stylesheet, and the
compiler's reports point at the package's file. `packages/charts` is one: its `Scale`, `Ticks`,
`Path` and `Format` are plain Roc, and `<BarChart>`, `<StackedBarChart>`, `<LineChart>`,
`<Sparkline>`, `<DonutChart>`, `<ScatterChart>` and `<Heatmap>` are its components.

```roc
import charts.BarChart
import charts.Format

<BarChart data!={rain!()} label="Rain each month" format={|mm| Format.num(mm, 0)} />
```

## Syntax

| Write | Means |
|---|---|
| `<tag attr="text" other={expr}>…</tag>` | an element; `{expr}` must be a `Str` |
| `<input type="checkbox" checked?={bool} required />` | `?=` sets a boolean attribute when true; a bare name is always on |
| `<a rel??={str}>` | `??=` sets an attribute unless the string is empty (Svelte leaves out an undefined one) |
| `<li class="row" class:active={bool}>` | `class:name` adds a class when true; all of them end up in one `class` |
| `<span style:--size={str}>` | sets a CSS custom property; joins any static `style`; a value with characters that could end the declaration, or a function that loads something (`url(…)`), is left out |
| `<h1 style:color={str}>` | sets one property of the style the same way, its name letters and dashes, computed if it reads a signal; in `Html.to_str` too (an email's colours) |
| `<a href={Paths.lists_id({ id })}>`, `<a href={…} replace noscroll>` | a link to one of the app's pages is rendered in place, without a load (D-040); `replace` replaces the history entry instead of pushing one, `noscroll` keeps the scroll where it is; `rel="external"`, a `target`, `download` or a modifier key leave the link to the browser |
| `{expr}` among children | a hole: text (a `Str`, escaped), a number (its digits) or markup (`Html`), by `expr`'s type (D-070; `{=expr}`, the old way of saying markup, is the same hole) |
| `{if (ready!()) <Panel /> else <p>Waiting</p>}`, `{if c { … } else if d { … } else { … }}`, `{if open!() { <Panel /> }}` | in a component, the part its branch makes: made when the branch holds, kept while it does, made anew only when another branch does (Solid's `<Show>`); each branch reads what it reads itself; text in every branch is a text hole; with no `else`, nothing shows otherwise (D-070) |
| `{match card!() { Ok(card) => <Card card={card} />, Err(_) => <p>None</p> }}` | the part the arm that holds makes, kept while it holds: its names (`card`) read the newest value where the arm reads them (Solid's `<Switch>`/`<Match>`, a `<Show>` narrowing a `Try`); a guard (`Ok(n) if n > 3 =>`) too |
| `{...expr}` | a `List(Html)`, joined |
| `{# a comment }`, `<!-- a comment -->` | nothing |
| `<StatusPill status={s} />` | a component: `StatusPill.view({ status: s })` when the file imports a module `StatusPill`, otherwise the local `status_pill(…)`; in a component's file `StatusPill.view!`, run where it is rendered; children become a `children : List(Html)` prop |
| `<>…</>`, `<!doctype html>` | a fragment; the doctype |
| `<script>…</script>`, `<style>…</style>` in markup | their text as written (braces too), never with values in it |
| `<style>…</style>` beside a component's definitions | CSS for that component's markup only, scoped as Svelte scopes it (above); a page's or a layout's goes at the file's top level |
| `<story name="Tip">…</story>` beside a component's definitions | one way it looks, for a dev build's catalog at `/__rocx/stories` (above) |
| `&amp;`, `&middot;`, `&#x2014;` | the character |

In a component only:

| Write | Means |
|---|---|
| `(count!, set_count!) = create_signal!(0)` | a signal: an accessor and a setter (`import pf.Solid exposing [create_signal!, create_memo!, create_effect!, on_cleanup!, on_settled!, set_interval!, set_timeout!, refresh!, is_pending!, use_context!]`) |
| `total! = create_memo!(\|\| …)` | a value computed from others, again when they change; one that asks the server is async, read as a plain value |
| `<ul class:dim={is_pending!(plans!)}>` | whether a memo read again (`refresh!(plans!)`, or after an action's result) is waiting for its new value, the last one still shown (Solid 2.0's `isPending`); false on the server |
| `untrack!(\|\| base!())` | a read that isn't tracked (Solid's `untrack`): what reads it doesn't run again when `base!` changes. In a component's body, where every read is made once, it says that is meant (a start value, `create_signal!(untrack!(\|\| start))`): a dev build (`rocx dev`) warns in the console of a read there that isn't, once a place (Solid 2.0's dev warning). `latest!(plans!)` is Solid 2.0's `latest`, the last settled value, which every read already is |
| `create_effect!(\|\| room!(), \|room\| …)` | Solid 2.0's split effect: the first half tracked, the second run once the page shows it, and again on a change (never on the server) |
| `on_cleanup!(\|\| …)` | run before what is running runs again (an effect's next run), and when it goes |
| `create_render_effect!(\|\| query!(), \|_\| set_page!(1))` | a render effect (Solid 2.0's `createRenderEffect`): its `apply` runs as soon as `compute` has, in the render (before the component's markup is built; in an update, before the effects'), not after the flush |
| `create_effect_with!(\|\| room!(), { apply, error })` | an effect whose failed `compute` calls `error` with why, after the flush, instead of the nearest `<Errored>` (Solid 2.0's `createEffect(compute, { effect, error })`) |
| `on_settled!(\|\| …)` | once, in the browser, once the component is on the page (Solid 2.0's `onSettled`, `onMount` before it); never on the server |
| `stop! = set_interval!(1000, \|\| set_seconds!(seconds!() + 1))` | the browser's timer, run as a handler; `set_timeout!(ms, done!)` runs once. Each answers its `clear!`, and stops with the cleanups of what started it (its component going, its effect's next apply) |
| `<button on:click={\|\| set_count!(1)}>` | a handler: an effect, run when the event reaches the element |
| `<input on:input.value={set_draft!}>` | the handler is given the value (`Str => {}`); `.checked` whether it is ticked, `.key` the key's name, `.keys` the key and the modifier keys held (`Html.Keys`: `key`, `shift`, `ctrl`, `alt`, `meta`, `mod`) |
| `<div on:keydown.ArrowUp={up!}>` | for that key only (`.Space`, `.w`), with no modifier key held, keeping it from scrolling the page |
| `<Document on:keydown.Mod+K={open!} />` | handlers on the whole document, written as an element's, while what renders it is there (an `if` around it to stop them); renders nothing. `<Window on:resize={…} />`, the window's |
| `<input on:keydown.Shift+Enter={send!}>` | for that key with exactly those modifier keys held (`Shift`, `Ctrl`, `Alt`, `Meta`, and `Mod`: ⌘ on macOS, Ctrl elsewhere): `Mod+K`, `Ctrl+Alt+Delete`; Shift+Enter isn't Enter |
| `<a href="/next" on:click.prevent={go!}>` | the event's default prevented before the handler runs (a link's click taken over) |
| `navigate!(Paths.tasks_id({ id: task!().id }))` | in a handler: to one of the app's pages, rendered in place, once the handler is done (Solid Router's `useNavigate`); `navigate_with!(to, { replace: Bool.True, scroll: Bool.True })`; another site, or a path no page has, the browser loads (`import pf.Router exposing [navigate!, navigate_with!]`) |
| `<div class="progress" class:on={Router.is_routing!({})}>` | whether a navigation in place is on its way: true from the click until the new page is on screen, the old page staying meanwhile (Solid Router's `useIsRouting`); false on the server |
| `use_before_leave!(\|leave\| if (dirty!()) leave.prevent!() else {})` | in a component: asked before each navigation away from the page (a link, `navigate!`, back and forward), which it may stop, and let go later from another handler (`leave.retry!(Bool.True)`, a dialog's "Discard"); a load (leaving the site, a reload) the browser asks about while one would stop it (Solid Router's `useBeforeLeave`; `import pf.Router exposing [use_before_leave!]`) |
| `<li draggable="true" on:dragstart={…}>`, `<ul on:drop={…}>` | drag and drop: an element with a drop handler takes drops (`on:drop.value`: the text dropped), and its `on:dragenter` and `on:dragleave` run as the drag comes over it and leaves it, not once per child. By mouse, the browser's own; by touch or a pen, the runtime's (held a quarter second, then dragged), in the same events (D-055) |
| `<li drag:data={[("text/uri-list", url)]} drag:image="ghost">` | what a drag of it carries for other pages and programs, by type, and what it shows (a copy of the element with that id); `on:drop.data` gives a drop every piece by type (`Html.DragItem`), `on:drop.files` its files (`Html.File`: name, type, size and a `blob:` URL; `on:paste.files`, a file field's `on:change.files`) |
| `<div on:pointermove.point={moved!}>` | where the pointer is over the element, shares of its box (`Html.Point`, 0 to 1), at most once a frame; `<Document on:visibilitychange.visible={shown!} />`, whether the page shows |
| `<i on:frame.ms={tick!}>` | every animation frame while the element is on the page, given the milliseconds since the last (`F64 => {}`) |
| `<li transition={Transition.fade}>` | an animation the element plays as its `.map` row or the part an `if` or `match` makes comes and goes (`transition:in`, `transition:out`: one way); one that goes stays until it has (`import pf.Transition`: `fade`, `fly`, `scale`, `grow`, `style`) |
| `<li key={card!().id} transition:move={Transition.glide}>` | glides to where a change puts it (FLIP), and to its new size; one that leaves a place as one with the same `key` comes in another glides from there |
| `Audio.play!("/sounds/eat.wav")` | in a handler: plays a sound file, any the browser can, once the handler is done (`Audio.play_with!(url, { volume, rate })`; packages/audio, a plugin: `import audio.Audio`, and `AudioPlayer.plugin({})` in the app's plugins) |
| `Vibrate.pattern!([300, 150, 300])` | in a handler: buzzes the phone, milliseconds on, off, on…, once the handler is done (`Vibrate.once!(ms)`; packages/vibrate, a plugin: `import vibrate.Vibrate`, and `Vibrator.plugin({})` in the app's plugins); on Android's native host, the phone's own handler |
| `Browser.call!("vibrate", { ms: 50 })` | in a handler: the page's own function `vibrate` (given to the runtime: `Runtime.load(wasm, { effects })`), with the argument as JSON, called once the handler is done and the page patched (`import pf.Browser`) |
| `Browser.focus!("card-title")` | in a handler or an effect's apply (`on_settled!`): moves the keyboard's focus to the element with that id once the page is patched; nothing if there is none (`import pf.Browser`) |
| `Time.now_millis!({})` | in a handler, an effect or a timer: the clock, the browser's in the browser (the server platform's names: `Time.now_nanos!` too); never while rendering, since markup made from it wouldn't hydrate (`import pf.Time`) |
| `<Shows label={word!()} />` | a prop is a getter, as Solid's are (D-039): rocx passes `label: \|\| word!()`, and the child, written with `label : Str` and `\|{ label }\|`, reads it where its code says `label`: tracked in a hole, a memo or an effect (only that part patched, the child kept), current in a handler, once in its body |
| `<Heading text!={user!().name} />` | a prop named as an effect is an accessor: the same getter, which the child types (`text! : () => Str`) and calls (`text!()`) itself |
| `view! = \|{ kind, ..rest }\| <Base {...rest} size={3} />` | props passed on (D-052): `..rest` keeps the props the pattern doesn't name (Solid's `omit`), and `{...rest}` gives them to a component as they are, getters still, the last of a name winning (JSX's spread, Solid's `merge`) |
| `<Title>{post!().title} · Notes</Title>` | the document's title, from anywhere in the page: the last one rendered that is still there, put first in `<head>` by the server, kept by the browser (`import pf.Title`) |
| `<Meta name="description" content={post!().summary} />`, `<Link rel="canonical" href={…} />`, `<Style>…</Style>` | the head's other elements (@solidjs/meta's), from anywhere in the page: put before `</head>` by the server, kept by the browser, a later `<Meta>` with the same name in an earlier's place; nothing to import |
| `(todos, set_todos!) = create_store!(init)` | a store (Solid 2.0's `createStore`): `todos.get!(\|s\| s.filter)` reads a part, its reader run again only when that part changes (`==`); `set_todos!(\|s\| { ..s, filter: Done })` writes; a `.map`'s rows are told only when their item changed (`==`), so one changed item patches one row |
| `{...rows!().map(\|row\| <li key={row.id}>{row.title}</li>)}` | a list that changes, a row per key (D-071, Solid's `<For>`), kept and moved; `.map_with_index(\|row, i\| <li key={i}>…)` a row per position. The row's name reads its item now (a getter, as a match arm's names); the row runs where its part is made, once and untracked (Solid's `mapArray`), so it may hold another `.map` or an `if`, and its holes follow the item. A component's `key` is the row's. A part made anew for each value (Solid's keyed `<Show>`) is a `.map` over a list of one, keyed by the value |
| `<Loading fallback={…}>`, `<Errored fallback={\|problem, retry\| …}>` | while answers are on their way; when something inside failed |
| `picks_context = create_context()`, `<PicksContext value={…}>` | Solid's context, named by rocx after its module and definition |
| `Endpoint.get!(Api.get_api_shelf({}))` | a GET endpoint's answer, as a plain value: the server answers it as it renders the page, and the page carries it to the browser (`Endpoint.read!`: a refusal as a value; `import pf.Endpoint`) |
| `submission = use_submission!(Api.post_join({}))` | the latest submission of a form to an endpoint: `pending!()`, `input!()`, `field!(name)`, `result!()`, `error!()` (`import pf.Router exposing [use_submission!]`) |
| `move! = use_action!(Api.post_move({}))`, `moves = use_submissions!(Api.post_move({}))` | an action: `move!(arg)`, in a handler, sends the endpoint without a form or waiting; `moves` is every submission to it (`all!()`, `pending!()`, `pending_inputs!()`, `clear!(id)`, `retry!(id)`), for an optimistic value: the server's data with `pending_inputs!()` applied |
| `(cards!, set_cards!) = create_optimistic!(\|\| Endpoint.get!(board))` | Solid 2.0's optimistic value: the server's until a handler writes it, the write held until the submissions that handler sent are done |
| `search = use_search_params!({})`, `search.get!("days") ?? "7"`, `search.set!([("days", "30")])` | the page's query (Solid Router's `useSearchParams`, D-040): `get!` and `all!` read it, tracked; `set!` merges into it from a handler (a value of `""` takes a name out) and navigates in place, the page kept, only what read the query reading again (`import pf.Router exposing [use_search_params!]`) |
| `<A href={Paths.lists_id({ id })} active_class="current">…</A>`, `<A href={Paths.root} end>` | a link with Solid Router's active state: `aria-current="page"` and the class (`active` by default) while the location is at its path (`end`) or under it, following navigations; `replace`, `noscroll`, `preload={Bool.False}` (`import pf.A`). A plain `<a>` navigates in place too |
| `{if signed_in!() { … } else { <Navigate href={Paths.sign_in} /> }}` | sends the visitor elsewhere as the page renders: the server answers a 303 to `href`, the browser navigates there replacing the entry (`import pf.Navigate`). A handler calls `Router.navigate!` |

Whitespace in text follows HTML, as Svelte has it, not JSX: each run of spaces, tabs and line breaks
is one space. Whitespace with a line break next to an element's own opening or closing tag goes, and a
space on the tag's line stays (`<b>Note: </b>`). Inside `<pre>` and `<textarea>` text stays as
written. Write a literal `<`, `>`, `{` or `}` in text as an entity or
`{"<"}`. `<` starts markup only where an expression can begin (after `=`, `(`, `[`, `,`, `=>`, a
lambda's `|…|`, an `if (…)` condition, `else`, `return`, or first on its line) and only when a
letter or `>` follows; after a value on the same line (`a < b`) it is the comparison.

A hole is one kind for text, numbers and markup: rocx writes `Html.hole(x)`, and the compiler picks
what to show from `x`'s type through Roc's encoding, so a value it can't show (a record, a `Bool`) is
an error at its line. An `if` or `match` in a hole is the part its branch makes because rocx reads the
branches before the compiler does, as Svelte reads `{#if}` (D-070); `<Show>`, `<Switch>` and
`<Match>` are gone. Markup inside a `<NoHydration>` has no
handlers, keys or transitions (rocx refuses them at their line: the browser never runs it), and a
name only it used (a page's `params`, a local) is rewritten in the browser's copy where it is bound
(`{ params: _ }`, `_lang = …`), so the compiler doesn't warn of it there (D-044); a
component's names end in `!` where Roc's effects do (`count!()`, `Picks.view!`). The docs' Syntax
and Components pages have it all, with every example a real file the build compiles.

## Routing

Under an app's `routes/`, a `+page.rocx` is a page at the path its directory names, each
`+layout.rocx` above it wraps it, a `+server.roc` answers HTTP methods there (endpoints), and
`+error.rocx` is what a path nothing answers shows (404), as in SvelteKit:

```
routes/+layout.rocx              view = |{ meta, children, .. }| <html>…{...children}…</html>
routes/+page.rocx                /
routes/blog/[slug]/+page.rocx    /blog/:slug, its view given params : { slug : Str }
routes/blog/[slug]/+server.roc   get! = |{ params, .. }| …, put! = |{ params, body, .. }| …
routes/sitemap.xml/+server.roc   /sitemap.xml (a directory may name a file)
routes/+error.rocx               where nothing is
```

A directory is a path's part in lower case (`blog`, `getting-started`), with dots between letters or
digits for a file's name (`sitemap.xml`, `feed.xml`: its names in `Api` and `Paths` are
`sitemap_xml`), or a param in brackets (`[slug]`).

rocx writes each route file as a module under `Generated/` (its lines kept), and
`Generated/Routes.roc`, whose `Routes.respond!(request, context)` answers a request: a page in its
layouts for a GET a browser sends, the endpoint for the method otherwise, a 405 with `Allow`, or
the error page; `Generated/Paths.roc`, a path for every page (`Paths.blog_slug({ slug })`, so a
link to a page that isn't there doesn't compile; a name Roc keeps gets a `_`: `Paths.platform_`);
`Generated/Api.roc`, the app's contract: a function for every endpoint and channel, its method, URL and
the types its handler's annotation gives (`get_blog_slug : { slug : Str } -> Endpoint(context, {},
Post)`), the same in the browser's copy, importing no route file, so any module may import it (a
store, a job, an actor that publishes on a channel); and `Generated/Handlers.roc`, the server's
alone, each of them bound to its handler (`Endpoint.bind`), which the router answers with and
`Endpoint.run!` runs (D-037). So every handler is annotated, as `get! : { request : Server.Request,
params : { slug : Str }, context : c } => Try(Post, Endpoint.Refusal)`: `rocx build` refuses one
that isn't. `main.roc`, which may import Handlers, is where to mount what runs handlers in front of
the routes (an MCP server). Middleware (the platform's `Middleware`) runs around answers:
the app's default around every request, and the one a route file names around its own (its page
and endpoints).

A route file may define components of its own (`Board := [].{ view! = … }`) before its
definitions or after them, not between: rocx writes them as types beside its module, where their
`view` isn't the page's, and `<Board />` calls the file's own. They see the file's definitions as
the page does: rocx names each one a component uses on the component's line (`Board := [].{ shown =
LocalPage.shown`), unless the component binds that name itself.

A route file that imports the platform's `Html` (`import pf.Html`) is a component: a page
`view! = |{ params }| …`, a layout `view! = |{ meta, children, params }| …`, the error page
`view! = |{ status, problem }| …` (Roc's record patterns are closed: write `..` for what a view
doesn't read). Its page is a document the server renders and the browser hydrates, and rocx build
writes more for it:

- `Generated/Root.roc`, in both copies: `Root.view!` tells the runtime the app (`Router.app!`: the
  build's id, `Root.build`, a hash of what the app is built from, which the server writes on each
  page's bootstrap as `data-build`; and the route table, `Root.routes`), matches `Router.location!`
  as `Routes` does, in a memo (`Root.route`: a tag for each page, with its params), and renders the
  page in its layouts. The root layout is the document (with none, a default one), given the page's `meta`.
  Below it, each other layout above the page, then the page, is a level: a keyed part (`Html.switched`,
  as an `if`'s part is), keyed by its file and its own params (`routes/lists/[id]/+page.rocx id=7`),
  so a navigation in place keeps every level whose key is the same, its state with it, and makes the
  others anew (D-040). Inside the root layout, around the levels, an `<Errored>`: a failure nothing
  else catches is the error page with `<HttpStatusCode code={500}/>`, or the status a read was
  refused with, when it is a 4xx (`Endpoint.get!` of a note that isn't there is the page's 404:
  `Errored.status_of`). A path no page has is the error page with `<HttpStatusCode code={404}/>`.
- A layout is given its own params, the ones its directory names (`routes/[lang]/+layout.rocx`'s
  `lang`; the root layout's are `{}`), not the page's, and the page's `meta`, a getter that follows
  the page while the layout is kept. Every page under a layout that takes `meta` gives it one type:
  rocx build says so at a page whose `meta` has other fields, or none (and at an app whose root
  layout takes it with no `+error.rocx` to give one for a path no page has).
- A layout is kept unless something it read once, in its body, changed: the runtime sees a read of
  `Router.location!` in a component's body (once, untracked) and notes it on the level it is in,
  which a navigation then makes anew, so it never shows what the last page knew (a dev build says so
  in the console). Read where you are is (in markup, a memo, `<A>`) and the layout is kept, a
  sidebar's scroll, an open menu and its signals with it. A change of the query alone keeps the
  page too (`use_search_params!`).
- In `Routes`, a component page's GET runs its route file's middleware, then answers `Root`'s page
  (`Routes.page(200)`); a path nothing has is `Routes.page(404)` for a browser, text otherwise.
- With `--client <out>`, `<out>/main.roc`, the browser's app (`Root.view!`), and
  `<out>/static/rocx/start.js`, `runtime.js` and the app's stylesheet (`styles-<hash>.css`, when it
  has a `<style>`). Build the wasm beside them
  (`roc build --target=wasm32 --opt=size --output=<out>/static/rocx/app.wasm <out>/main.roc`) and
  serve the directory (`--static <out>/static`): the page's `/rocx/start.js` loads the other two,
  and its `<head>` links the stylesheet.
  A module the browser's app reaches that imports what only the server has (`pf.Db`, directly or
  through another module) is a warning, at the import a page or component of the app's makes:
  the browser's build couldn't compile it. The copy leaves out an app on the server platform (the
  app's own `main.roc`: the server's program); an app of endpoints alone has no `<out>/main.roc`,
  and the build says the browser has nothing to build.

**Navigating in place** (D-040, Solid Router's model): in the browser, a click on a link to one of
the app's own pages (this origin, under the site's base, a path the route table has a page for), a
handler's `navigate!`, and back and forward don't load a document. The runtime fetches the page's
document as the server answers a load (behind its middleware, its reads answered in-process, a
redirect followed; or the file `just site` wrote), with `x-rocx-navigate: 1` for a middleware that
tells the two apart, and renders the page from the wasm with that document's answers and
`<NoHydration>` regions: nothing else is asked. The old page stays until it is in
(`Router.is_routing!`); then the address is pushed, `Router.location!` (a tracked source now) is the
new page's, the page is made anew (phase 1: the layouts too), `<head>` is reconciled with the
document's (an element equal to one there, a stylesheet, is kept), `<html>`'s and `<body>`'s
attributes are the document's, the scroll is at the top (or the hash's element; back and forward
restore it), the focus at `<body>`'s start, and a live region says the new title for a screen reader.
The documents fetched in the last 10 s are used again. Whatever isn't an app document of this build
(a text 401, a crash, a page of a new deploy: `data-build`, no network) the browser loads, as it does
a link with `rel="external"`, a `target`, `download` or a modifier key, a path no page has, and a
place on the same page. The document dispatches `rocx:navigate` and `rocx:navigated` (`{ url, ms }`):
page JavaScript that set itself up on `rocx:ready` does so again on `rocx:navigated`, since a
`<script>` a page renders runs on a load only. `<html data-rocx-navigation="off">` turns it off. Apps
change nothing to have it.

**Prefetch and View Transitions** (D-040, phase 3). A link to one of the app's pages that the pointer
rests on (65 ms), that the keyboard focuses, or that a finger touches is prefetched: what its page
needs (its document, `x-rocx-navigate: preload`, at a low priority; and its code), in the same cache
a navigation takes it from, so the click asks nothing more. `data-rocx-preload="off"` on a link, or
above it (`<html>` for the app), turns it off there; `"viewport"` prefetches links as they come into
sight. A prefetch is a page render on the server: a middleware that counts views leaves
`x-rocx-navigate: preload` out, and an app whose pages are costly sets `off`. `<html data-rocx-transitions>`
makes each navigation a View Transition (the browser's cross-fade, `view-transition-name` pairing
elements across pages), where the browser has them and less motion isn't asked for.

**Leaving the page** (D-040, Solid Router's `useBeforeLeave`). A component that holds unsaved work
registers a listener, `Router.use_before_leave!(|leave| …)`, which the runtime runs as a handler
before each navigation in place (a link, `navigate!`, `<Navigate>`, a GET form, a submission's
redirect, a change of the query alone, back and forward), in the order they came. It is given the
leave (`Leave`: `to`, `from`, `options`, `delta` for back and forward, `default_prevented`), may
stop it (`leave.prevent!()`: the page and its address stay; back and forward, whose address had
changed, go back where they were, as Solid Router does), and may keep it to let it go later from
another handler, an app's own "Discard your changes?" dialog: `leave.retry!(Bool.True)` goes without
asking the listeners again, `retry!(Bool.False)` asks them again. It goes with the component. A
listener decides from what the page has: one that waits for the server can't hold the navigation.
A load (leaving the site, reloading, closing the tab) the page can't hold, so the runtime asks each
listener ahead of time (`to` is "", its writes dropped), again whenever what it read changes, and
listens for `beforeunload` only while one would stop a load: the browser then asks, in its own
words. On the server, `use_before_leave!` does nothing.

```roc
(leaving!, set_leaving!) = create_signal!(Err(Staying))
use_before_leave!(|leave|
	if unsaved!() {
		leave.prevent!()
		set_leaving!(Ok(leave))
	})
# The dialog's button: <button on:click={discard!}>Leave without saving</button>
discard! = || match leaving!() {
	Ok(leave) => leave.retry!(Bool.True)
	Err(_) => {}
}
```

Any app with routes, of components or not (endpoints alone too), gets its program:

- `Generated/App.roc`: `App.program({ init!, middleware, plugins })` is the platform's `program`.
  `init!` makes the app's context once, when the server starts (after the migrations, so it may
  read the database; given `--context-file`'s text; its `Err` stops the server): settings read
  once, handles, anything. The host keeps it for as long as the server runs, shared by every call
  that runs the app's code: `middleware` is given it for each request, a job's run and an actor's
  methods are given it, and so are a plugin's calls, loops, starts and checks. Every request is
  answered by a plugin's route or `Routes.respond!` behind `middleware`, and a page a browser asks
  for lets a plain form's flash go (`Server.clear_flash`). `App.jobs` is the jobs the app's modules define, for the jobs
  plugin (packages/jobs), each at the top of its module's block (`\twelcome = Job.define("welcome",
  |context, input| …)`, or `Job.define_with`; one outside it, or two with one name, fail the build, and so do jobs
  with no jobs package in the header). The migrations are `migrations/*.sql`, embedded, in the order of
  their names. The log's format is `Auto` (`ROCX_LOG`, `pretty` or `json`, if it is set; or else
  pretty on a terminal and JSON elsewhere); `program = { ..App.program({ … }), logs: { format: Json } }`
  (or `Pretty`) says otherwise. The server's lines and the app's (`Log.info!("gate failed", { path:
  request.path, error: why })`, and `debug!`, `warn!`, `error!`) are events with fields, written in
  that format (server/README.md, "The log").

A pure component, one whose `view` has no `!` (`Heading.view`), is called where it is written,
not put off as a component that may read a context. What the author writes besides the route files
and their modules is main.roc:

```roc
app [program] { jobs: "../packages/jobs/main.roc", pf: platform "../server/platform/main.roc" }

import jobs.Cron
import jobs.Job
import Generated/App
import Middlewares
import Jobs

program = App.program({
	init!: |started| Ok({ facts: started }),
	middleware: Middlewares.default,
	plugins: [Job.plugin({ jobs: App.jobs, crons: [Cron.every("0 3 * * *", Jobs.nightly, {})] })],
})
```

## Talking to the server

A route's `+server.roc` is the one way an app talks to its server: endpoints, a method at a path,
typed at both ends, which anything else that speaks HTTP may ask too.

- **Reads.** A component reads a GET endpoint as a plain value:
  `Endpoint.get!(Api.get_api_shelf({}))`, which fails its computation on an answer that isn't 200
  (the nearest `<Errored>` shows why), or `Endpoint.read!(…)`, a `Try(result, Server.Problem)`.
  `Endpoint.with_query(endpoint, query)` adds a query (the page's own, `Router.location!({}).query`,
  which the handler reads as `request.query`). What the route's middleware handed on is the
  handler's `context` (`get! = |{ params, context, .. }| Ok(…)`). A page's own data is best at the
  page's own URL (`routes/members/+server.roc` answers `GET /members` for JSON, behind the same
  middleware as the page there); a layout, which many pages share, reads an endpoint at a path of
  its own (the docs site's footer reads `GET /api/facts`). A handler runs only on the server, so it
  may use what only the server has (`Db`, `Job`); the browser's copy of `Api` is the same contract,
  each endpoint's method, URL and types, so a type a route's annotation names must compile in the
  browser (`rocx build` refuses one from a module that imports `pf.Db`, naming the route, the type
  and the module), and a wrong body or answer doesn't compile in either copy. What goes and comes is JSON: an `F64` as a number (one JSON can't write, NaN or an
  infinity, is a 500 that says so). The builtin `Try` has no JSON encoder or parser on this Roc, so a
  result can't hold one: write the tag union instead (`[Ok(Str), Err([NotFound])]`, which a `match`
  reads as it reads a `Try`); `rocx check` says so under the compiler's report.
- **As the server renders.** While the server renders a page, each GET a component reads is answered
  in-process, through the endpoint's route, as the browser's GET would be:
  `accept: application/json`, the page's cookies and headers, behind the route's middleware. Each URL
  is asked once a render, and its answer (any status) is noted in the page's answers script under
  `GET <url>` (not from inside a `<NoHydration>`), so hydrating, the browser reads it there and asks
  nothing; strict hydration (the tests') fails a page that asks again. A later read
  (`refresh!(memo!)`, a URL built from a signal) GETs the endpoint's URL for JSON. A read its
  middleware answers with a redirect (a signed-out visitor sent to sign in) makes the page that
  redirect.
- **From handlers.** A component sends any endpoint from a handler with
  `Endpoint.send!(Api.post_api_shout({}), draft!(), Call.fetch!)`.
- **Forms.** A `<form method="post" action={Endpoint.url_of(join)}>` posts to an endpoint, which reads
  its fields by its body's types (D-038): a number from its text, a box left unticked `Bool.False`,
  the values a name has as a `List`; one missing or wrong is a 400 naming the field. So an action's
  JSON and a plain form post one typed record. `submission = use_submission!(join)` is its latest submission,
  as Solid Router's `useSubmission`: `submission.pending!()`, `input!()` (what was typed, as the
  endpoint reads it), `field!("name")`, `result!()`, `error!()`, `clear!()`. With the runtime the
  form is sent with `fetch` and the page stays; without it (before it loads, or with no JavaScript)
  it posts, and the endpoint sends the browser back to the page with a flash: what was typed and the
  result or refusal, kept on the server for a minute (a cookie holds its id) and read once, which
  the submission is then (`Server.flash!({})` reads it as it came). A password typed is never sent
  back. A redirect of the endpoint's own is followed either way.
  A result has the page's reads read again (Solid Router's revalidation), and the submission stays
  pending until they are in.
- **Actions.** `move! = use_action!(endpoint)` is a function a handler calls with the endpoint's arg:
  a submission of its own, sent without a form or waiting (Solid Router's `useAction`).
  `use_submissions!(endpoint)` lists every submission to it (`all!()`, `pending!()`,
  `pending_inputs!()`, `clear!(id)`). An optimistic value is a memo of the server's data with
  `pending_inputs!()` applied: shown at once, it gives way to the server's data, read again, with no
  frame of the old, and a refusal puts it back. Or, as Solid 2.0 writes it, `create_optimistic!(||
  Endpoint.get!(board))`, a value a handler writes ahead of the server, held until what it sent is
  done. A handler on the server says which reads a result reads again (`Router.revalidate!(keys)`,
  Solid Router's revalidate keys); `retry!()` sends a submission again; `Endpoint.with_fields`
  gives a form's fields ahead of time (`action.with`); a form with files, or an action given a
  dropped or picked file, goes as multipart, read with `Server.file` (D-054).
- **Events.** An endpoint's `events!` streams server-sent events: a loop that sends and sleeps,
  a call of its own on the server, ended by `?` when the client goes. A component listens with
  `Endpoint.listen!(Api.events_…(params), Call.listen!, |event| …)`: each event runs the handler.
  Started in an effect (`create_effect!(|| org!(), |org| Endpoint.listen!(…))`), it listens while
  its component is there, again when what the effect read changes, and stops when it goes.
- **Channels.** For live data a page follows, a route's `channel!` checks who may subscribe (behind
  the route's middleware, again every 15 s) and types what is published on it and what pages may
  say. A component subscribes from an effect, `Endpoint.subscribe!(Api.channel_…(params), heard!)`,
  and hears `Resync` (read your data again), then each `Message`; the server publishes with
  `Endpoint.publish!` from a request, a job or an actor. Every channel a tab subscribes to shares one
  stream, `/rocx/live` (DECISIONS.md, D-020; server/README.md).
- **OpenAPI.** An app can serve its endpoints' OpenAPI 3.2 document, which rocx writes
  (`Api.openapi`): each path and its params, each method and its handler's comment, and the JSON
  Schemas of what it is sent and answers, from the handlers' types, written down or inferred. It is
  off unless `App.program` says: `openapi: Document` serves `GET /openapi.json`; `Page(Swagger)` or
  `Page(Scalar)` serves that and `GET /openapi.html`, the document in Swagger UI or Scalar (pinned on
  jsDelivr, checked against its hash, told not to call home). Roc has no reflection, but a type's
  parser works with any format: the platform's `OpenApi` is a format that reads nothing and writes
  the schema of each shape it's asked to read. A tag union's tags are whichever names in the app's
  code the union turns out to have. A body a form can send (a record of text, numbers, yes-or-no,
  choices and lists of them) is listed as a form's too, URL-encoded and multipart, beside JSON
  (D-054).
- **No server functions.** `server!` is gone (DECISIONS.md, D-023), and `rocx build` refuses it at
  its line. What one did is a `get!` in a route's `+server.roc`, its input the path's params or the
  query and its middleware's context the handler's `context`, read with
  `Endpoint.get!(Api.get_…(params))` where it was called.

## Safety

`Html` is opaque: nothing outside it can wrap a string as markup. Text and attribute values are
escaped; `href`, `src`, `action`, `formaction`, `poster` and `cite` take only relative URLs or
http, https, mailto and tel ones (`java\tscript:` included), anything else becomes
`about:invalid#rocx-unsafe-url`, except that an image's (`<img src>`, `<link href>`, `<source src>`,
`<video poster>`) may also be a `data:image/…` URL, SVG too: the browser shows it as a picture,
its scripts off, where an `<iframe>` or a link someone opens would run them; inline handlers (`onclick=`), a computed `style` and unquoted
values are refused when building; handlers are Roc functions, never text in the page. The browser's
runtime builds elements with `createElement` and sets text and attributes as such. `rocx lint`
refuses `Html.source_text` in hand-written `.roc` files. The site's default middleware refuses a
change another site's page sends (`Middleware.same_origin`).

## Commands

```sh
rocx dev [dir]           # build the app (a directory with routes/) and serve it at :8080 under --dev,
                         # built again and restarted on each save, its open pages reloaded; a mistake
                         # shown at its .rocx line; writes the smallest main.roc if there is none
  --port 8080            # where (PORT); after `--`, the server's own options (--database-url URL)
rocx build <dir>…        # each .rocx under the directories becomes the .roc beside it;
                         # an app's routes/ become Generated/Routes.roc, Paths.roc, Api.roc and
                         # App.roc (its program), and, for component route files, Root.roc;
                         # each folder under content/, Generated/Content/<Name>.roc (its Markdown
                         # files; with a type beside them, read: packages/markdown's README)
  --client <out>         # and the browser's copy of the app: an endpoint only its method and URL, a
                         # route file without its middleware, the imports only they used gone;
                         # for component route files, its main.roc and static/rocx/ (endpoints
                         # alone: none, said); a warning where it reaches a module that imports
                         # what only the server has (pf.Db)
  --dev                  # and the stories (`<story>`): their catalog at /__rocx/stories
rocx check [dir]         # the app (here, or in dir) checked from its sources: rocx build as rocx dev
                         # builds it, then the compiler on its server's program and its browser's,
                         # every problem at its .rocx line, never what an older build left; exit 1
                         # on an error, 2 on warnings alone
rocx check -- <command>  # run a command, its reports pointed into .rocx files
rocx check --sql [dir]   # the app's SQL checked by its own database engine, and its rows by the
                         # compiler (D-058): each literal statement at a Db.all!/Db.run! prepared on
                         # a scratch database built from the app's migrations; what the engine
                         # refuses, parameters that don't match the call's, and a row record that
                         # doesn't fit the columns (a field missing, a type, a nullable column read
                         # as a plain value), at their lines; exit 1 if any. rocx dev runs it too
  --engine turso         # on Turso (a SQLite app), or SQLite (a Turso app), instead
  --verbose              # and list the calls it can't check (interpolated SQL, SQL in a variable,
                         # Db.unchecked)
  -- <server options>    # given to the app's server (--database-url, --sql-database for Postgres)
rocx lint <dir>…         # refuse Html.source_text in hand-written .roc files
rocx routes <dir>        # list an app's routes: method, path, file, middleware
rocx fmt <path>…         # format the Roc in .rocx files and hand-written .roc files with roc fmt
  --check                # only say which files aren't formatted
```

`rocx` is `bin/rocx` in this repo, a native executable built from its Roc (`rocx-cli/`) the first time a
script asks for it, and again whenever `rocx-cli/` changes (D-032). From outside the repo, run
`<repo>/bin/rocx …` where you ran `node <repo>/bin/rocx.mjs …`; a Node script gets its path from
`rocxBinary()` (`import { rocxBinary } from "<repo>/server/build.mjs"`), which builds it if it is
missing or stale, and calls rocx's functions by their old names from `<repo>/rocx-cli/rocx.mjs`.

`build` writes a file only when its content changes, deletes `.roc` files it wrote whose `.rocx`
is gone, and stops at the first markup problem with its line and column. Because the lines match,
the compiler's reports are already at the right line; `check` rewrites `Page.roc:22:48` to the
`.rocx` file and column, quotes the `.rocx` line, and moves the caret onto the same code there.
`fmt` runs `roc fmt` (`$ROC`, or roc on the PATH) on each `.rocx` file under the paths and each
`.roc` file rocx didn't write. Markup, and the Roc in its holes, are left as written: each piece of
markup moves only with the code around it, and the text of a `<pre>` or `<textarea>` never moves.
`just fmt` formats this repository, and `just check` fails on a file that isn't formatted.

**In an editor** (`editors/`, its README): one TextMate grammar for `.rocx` files (Roc, markup,
Roc again in holes, CSS in `<style>`), in `editors/grammars`, which two packages take.
`just vscode-extension` installs the VS Code extension: the highlighting, and a `rocx` task type
(`dev <dir>` for each app in the workspace, or any command, `just dev`) whose output becomes problems
at their `.rocx` lines on each build. There is no language server yet: what the editor shows is
what the build says. `just orca-plugin` installs the [Orca](https://github.com/stablyai/orca)
plugin, which highlights `.rocx` and `.roc` files. `just grammar-check` tokenizes every `.rocx` file
and fails on one whose markup the grammar leaves open, then runs the extension's tests.

## The platform

**The server** (`server/`): an app gives it a record (`respond!`, whose answer may be a page of
components or a stream, `migrations`, `actors`, `logs`, `plugins` and `routes`; `App.program` writes
it). Each call into Roc is a coroutine on one of a few threads of Roc's own, paused while an effect
waits, so a call that waits holds up nothing else and holds no thread (D-027); a crash ends only
its call (a 500, a stream ended, a job run again), its memory freed and its transaction rolled
back. It renders a page of components, byte for byte as the browser's runtime would. A database,
Postgres or SQLite in the server's process (on SQLite's engine or Turso's), as the app's program says
(`Db`, migrations, transactions, notifications: D-045, D-046), plugins (what a package adds to an app: routes, tables, loops,
paths for development, checked when the server starts: D-033), requests to
other servers (`Http.fetch!(url, init)`, as JavaScript's `fetch`), bodies as bytes and from elsewhere
(`Server.forward`), cookies, settings (`Env`), encryption (`AesGcm`) and random bytes, values in
memory by key (`Kv`: TTLs, atomic counters, an LRU limit), live topics and rooms, channels (typed
live updates, one stream per tab, told whether a subscription was dropped or its tab went), and
actors (typed asks, tells and timers, one message at a time, their state and timers kept in the
database when there is one). Files (in S3, a directory or memory) and the
crypto written in Roc are packages (`packages/storage`, `packages/crypto`), and so are jobs and cron (`packages/jobs`, a plugin:
options, keys, listing, and a jobs page in `packages/admin`, a plugin behind the app's guard) and
email (`packages/email`, a plugin: SMTP, or a dev mailbox at `/__rocx/mail`). The Rust host gives general things (HTTP, database connections, TCP and TLS,
background loops, isolated calls, the key-value store, channels' streams, actors' mailboxes and
timers); migrations, plugins and actors' state and timers are the platform's Roc, written on them, and so are
the jobs and email packages, and
[roc-pg](https://github.com/niclas-ahden/roc-pg), whose queries are checked at build, which runs on
the platform's `Tcp`. `--target=arm64musl` cross-compiles one static Linux executable.
`server/README.md` has every module's API.

**The browser** (`web/`): the app's page, one wasm module, with a Zig host that passes each of
Roc's effects to `web/runtime.js`, which keeps the graph of signals, memos and computations,
hydrates the document from the server's nodes and answers, runs holes again when what they read
changes, and sends requests. `web/README.md` has how.

## The docs site

`site/` is written in rocx and uses all of the above; its pages are `site/routes`: Roc Solid's
front page (`/`), then three parts, rocx (`/rocx`, `/syntax`, `/routing`, `/components`, `/calls`,
…), the platform (`/platform`, …) and the ecosystem (`/ecosystem`, and a page for each package:
`/ecosystem/charts`, `/ecosystem/forms`, …).
Its pages are components, and `site/main.roc` is its program (`App.program`, which rocx build
writes). Its look is a design system: `site/static/site.css` is the tokens (`:root`: neon on near
black, always dark; colours, one type scale and one space scale, radii, glow) and the base (elements
only, no classes); the components in `site/Ui` (`PageHero`, `Button`, `Feature`, `Demo`, `Specimen`,
`Topbar`, `Sidebar`, …) and the demos in `site/Demos` each have their own scoped `<style>`, and the
components their stories, which `just dev` shows at `/__rocx/stories` (`Ui/Tokens.rocx` shows the
tokens). A page is written with them, not with classes of the site's; what only one page has is in
a `<style>` at the top of its file. Its demos are `site/Demos`, each in the page that shows it (a
counter, a to-do list, a shelf and a bag sharing a store, a planner whose plans are dragged between
days, Snake and a flock of birds, frame by frame, with sounds: their handlers play the files in
`site/static/sounds`, which `site/sounds.mjs` makes, with `Audio.play!`, packages/audio's); the docs' prose and listings are `<NoHydration>`. `site/build.mjs` builds it: `.rocx`
to `.roc` and `site/Generated/Sources.roc`, the sources the pages show (both rocx's: `rocx site prepare`); the browser's wasm, `app.wasm`
(from the copy in `site/build/client`, beside the `start.js` and `runtime.js` a page loads); the
server, native; then measures the wasm (sizes, rendering a page, and with `just site` the same
wasm built other ways). `just site` starts the server and writes every page it answers into
`site/dist`, with what the demos ask for besides pages (the shout's words, `/openapi.json` and
`/openapi.html`) as files: a copy of the site that is only files, and works as one. Most of its
demos need no server (the echo's answers came with the page, the server rendered them as the site
was built); the count, which streams, is code only, and a demo that sends or follows something (the
planner's moves, the lobby's channel) says that no server answers.
`node site/build.mjs --base=/rocx/` builds it for a host that serves it under a path (`/rocx/`, as
a GitHub project site would): every URL in a page begins with it, and the runtime asks under it. `just deploy-pages` publishes `just site`'s copy to
https://roc-solid.github.io/, from this machine only: site/dist alone, no source, as the one commit
of the `main` branch of Roc-Solid/roc-solid.github.io, force-pushed. `just dev` (`rocx site dev`)
builds with Roc's dev backend on each save and restarts the server; open pages reload. An edit to
rocx itself builds rocx again, and the loop goes on in the new one.

## Tests

```sh
just test
```

`test/transpile.test.mjs` covers the syntax; `test/routes.test.mjs` the
routing; `test/e2e.test.mjs` builds an app with routes and checks where a type error is reported.
`roc test site/main.roc` runs every Roc module's `expect`s: `Html`, `Server`, the demos' rules
(the snake, the flock's physics), the highlighter. `web/test/platform.test.mjs` builds components on
the browser's platform, renders them as a server would in Node, and hydrates and uses them in
Chromium (signals, `if`, `match` and `.map` in holes, boundaries, contexts, documents, memory).
`site/test/site.test.mjs` builds the docs site, starts its server, and hydrates every page strictly
and uses every demo in Chromium, the game with real keys; it compares every page the server renders
with the browser's build's own render, byte for byte outside its `<NoHydration>`s, natively and as
the files GitHub Pages serves. `server/test/server.test.mjs` asks a small app on the server's
platform over HTTP: crashes and memory, streams, pages of components, and, with `DATABASE_URL` set (`just db`),
Postgres, transactions, migrations, jobs, cron, email over SMTP, live rooms, actors across a
restart, and a graceful stop; `server/test/sqlite.test.mjs` asks an app on SQLite, and its copy on
Turso, which need no database server, the same of their database, jobs and cron. `roc test packages/<name>/main.roc` runs each package's `expect`s,
and `packages/testing/test/` tests that package's helpers against an app it builds. The browser
tests drive Chromium's headless shell over the DevTools protocol with no dependencies: `$CHROME`,
or Playwright's cached one; without it they are skipped. packages/testing's (and the board
example's) drive Gecko too when there is one, headless over WebDriver BiDi: `$GECKO`, Zen, Firefox,
or Playwright's Firefox (`web/test/browser.mjs`, `launchGecko`).

CI (`.github/workflows/ci.yml`) runs `just check`, `just site`, `just test` (as two jobs: `just
test-rocx` and `just test-web`, with Chromium and Firefox; `just test-server`, with a Postgres too)
and `just examples`, five jobs side by side, on every push to master and every pull request, on
GitHub's Linux runners on arm64, with the fork's compiler prebuilt for them. After `just check` it
times checking (`just check-times`: each example's and the site's `rocx build` and `rocx check` of
both programs, with no cache) into the job's summary, against the last green master run, and warns
when a check got slower by half. A change to `roc_fork_commit` needs its compilers published first,
on the machine with the fork: `just setup` (this Mac's), `just roc-fork-linux` (Linux's, cross-built
by Zig), `just publish-roc-fork`, then the SHA-256s it prints in `roc_fork_sha256_<platform>`.
