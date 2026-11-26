# Roc Solid

Roc Solid is a web framework for [Roc](https://www.roc-lang.org). You write a whole web app in Roc,
from the database queries to the buttons in the browser, and the Roc compiler checks all of it. The
docs are at https://roc-solid.github.io, built from `site/` in this repository.

Roc Solid has three parts:

- **rocx**, the markup and the tool. A `.rocx` file is Roc in which HTML-like markup may stand
  wherever an expression can. `rocx build` turns each `.rocx` file into a plain `.roc` file, line
  for line, so the compiler type-checks every value you put in a page and reports errors at your
  own lines. `rocx` is also the command-line tool (`rocx dev`, `rocx build`, `rocx check`). It is
  written in Roc too, on a small command-line platform in `cli/`.
- **The platforms** an app runs on. On the **server platform** (`server/`), your Roc is compiled to
  native code inside a Rust host. It serves HTTP and gives the app a database (Postgres, or SQLite
  inside the server's process, on SQLite's engine or Turso's), live channels, a key-value store,
  actors and plugins. On the **browser platform** (`web/`), the same components are compiled to
  WebAssembly and run by a small JavaScript runtime.
- **The ecosystem**: packages any app can use, in `packages/`. Sign-in (mailed links, Google,
  GitHub, OpenID Connect), payments and subscriptions through Stripe, Claude from the server (streamed
  answers, typed answers, the app's functions as tools, agents as tools), charts, forms, Markdown, intl, an admin, guards (rate limits, feature
  flags), jobs and cron, email, MCP, presence, Web Push, OpenTelemetry, PostHog error tracking,
  storage (S3, files, memory), crypto, QR codes, audio, vibration, testing helpers and virtual
  lists.

## How it works

Components work as in [SolidJS](https://www.solidjs.com) 2.0. A component is a function that runs
**once** and returns markup. It may make **signals**: values that change, read through an
**accessor** such as `count!()` (Roc marks effectful functions with `!`). In markup, `{…}` is a
**hole**. A hole that reads a signal is a small computation of its own: when the signal changes, the
runtime runs that hole again and patches its own DOM node. Nothing else renders again.

The server renders each page to HTML first. Then the browser loads the same components, compiled to
WebAssembly, and **hydrates** the page: it takes over the HTML the server sent and attaches the
handlers and signals, without building the page again.

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

`Counter.view!` runs once. It makes a signal (`count!` reads it, `set_count!` writes it) and returns
a `<p>`. Two parts of that markup read the signal: the `<output>`'s text and the `negative` class.
When a button sets the count, only those two run again.

An app is two programs built from one set of files: the server's (native code) and the browser's
(WebAssembly). They talk over HTTP, through typed **endpoints**.

## Getting started

### Install

One command puts rocx, the Roc compiler it builds with, and both platforms prebuilt into
`~/.rocx` (macOS on Apple silicon, Linux on arm64 or x86_64), with no Rust, Zig or Node:

```sh
curl -fsSL https://github.com/Roc-Solid/rocx/releases/latest/download/install.sh | sh
```

It checks each download's SHA-256, adds `~/.rocx/bin` to your shell's PATH (`sh -s --
--no-modify-path` doesn't), and says how to remove it all (`rm -rf ~/.rocx`). With Nix: `nix profile install
github:Roc-Solid/rocx`, or `nix run github:Roc-Solid/rocx -- new my-app`. The first release isn't
out yet: until it is, set up from a clone (below).

### A new app

```sh
rocx new my-app          # asks which database: SQLite (the default), Postgres or Turso (--db to say)
cd my-app
rocx dev                 # http://localhost:8080, rebuilt and reloaded as you save
```

The app signs people in from the start (packages/auth: a link by email, Google and GitHub once
their keys are set, and under `rocx dev` any address at once; two-factor sign-in for those who turn
it on), keeps its users in its own table,
refuses other sites' posts, sends guard's security headers, and limits the sign-in mail. Its
`README.md` says what to change first, and how to test it (`rocx test`), deploy it (`rocx build .
--release dist`, behind a TLS proxy) and upgrade it (`rocx upgrade`). It names its version of rocx
in `.rocx-version` (commit it) and reaches the platform through `.rocx`, a link rocx makes
(gitignore it).

### From a clone

To work on Roc Solid itself, or before the first release:

- macOS or Linux, with `git`, `curl` and [`just`](https://github.com/casey/just).
- Zig 0.17.1 and Rust 1.85 or newer, with Rust's `wasm32-unknown-unknown` target. If the ones on
  your PATH (from Nix, say) match, they are used; otherwise `just setup` downloads them into
  `.tools/`.
- Roc: Roc Solid builds with a fork of Roc's pinned nightly that carries the compiler fixes rocx
  needs. `just setup` builds it from a local clone of the fork (`~/roc-fork`, or `$ROC_FORK`), or,
  without one, downloads it prebuilt from this repository's releases (macOS on Apple silicon,
  Linux on arm64; elsewhere you need the fork's source). A `roc` on your PATH is never used.
- Node.js only for this repository's tests and build scripts. Docker only for `just db`.

```sh
git clone https://github.com/Roc-Solid/rocx && cd rocx
just setup                     # the toolchain into .tools/, then bin/rocx
export PATH="$PWD/bin:$PATH"   # so `rocx` runs from anywhere
rocx new ../my-app             # an app linked to this clone
```

### An app by hand

An app is a directory with a `routes/` directory in it, anywhere on disk. Without `rocx new`, make
one page:

```sh
mkdir -p ../my-app/routes && cd ../my-app
```

Put this in `routes/+page.rocx`, the page at `/`:

```roc
import pf.Html
import pf.Solid exposing [create_signal!]

## The page at /: rendered by the server, then live in the browser.
view! = |_| {
	(count!, set_count!) = create_signal!(0.I64)
	<main>
		<h1>Hello, Roc Solid</h1>
		<button on:click={|| set_count!(count!() + 1)}>
			Clicked {count!().to_str()} times
		</button>
	</main>
}
```

Then run it:

```sh
rocx dev                       # http://localhost:8080, built again on each save
```

The first run writes `main.roc` beside `routes/`. That is the app's server program, the smallest
one, and yours to change from then on. It also builds the server platform's host, which takes a few
minutes, once. `rocx dev <dir>` serves an app in another directory.

[`examples/hello`](examples/hello) is this app, plus an endpoint at `GET /hello`. Next, read
[`examples/tasks`](examples/tasks), the example written to be read first, and the docs site's
[components](https://roc-solid.github.io/components) and
[routing](https://roc-solid.github.io/routing) pages.

## Working on this repository

| Command | What it does |
|---|---|
| `just setup` | The toolchain into `.tools/` (Zig and Rust if need be, the pinned Roc nightly, the Roc fork), then `bin/rocx` |
| `just dev [port]` | The docs site at http://localhost:8080: its native server answers each page; it is rebuilt, restarted and reloaded on save |
| `just check` | Checks formatting, then type-checks the site's two programs (errors at `.rocx` lines), each package's server modules and every example (`just examples-check`), and lints them |
| `just test` | Everything, in three parts: `just test-rocx` (the transpiler, routing, every Roc module's `expect`s), `just test-web` (the browser platform in Node and Chromium, and the docs site in Chromium), `just test-server` (the server platform, and the packages' own test suites) |
| `just examples [name…]` | Builds, checks and tests every example app, or the ones named |
| `just fmt` | Formats the Roc in every `.rocx` file and hand-written `.roc` file |
| `just db` | A Postgres in Docker for the server platform's Postgres tests; prints its `DATABASE_URL`. SQLite apps need none |
| `just site` | The docs site as static files in `site/dist`, every page as its server renders it |
| `just deploy-pages` | Builds that and publishes it to roc-solid.github.io (maintainers) |
| `just compiler-bugs` | Runs each Roc compiler bug rocx has met, with the nightly and with the fork |
| `just grammar-check`, `just vscode-extension`, `just orca-plugin` | Editor support (see [In an editor](#in-an-editor)) |
| `just example-apps`, `just example-shots`, `just db-bench` | Measure the example apps, take their screenshots and run the SQLite-against-Turso benchmark, for the docs' examples pages |
| `just rocx-bootstrap` | Builds `bin/rocx` from nothing, without Node (`just setup` runs it when needed) |
| `just glue` | Regenerates the platforms' glue after a change to a platform's header |

## Examples

Each example is a whole app in `examples/<name>`, small enough to read end to end. Each has a
README that tours it, maps each feature to the file that shows it, and says what it asked of the
platform. Each has its tests. `just examples` builds, checks and tests them all, and
`just examples tasks` does one. The docs site's [examples page](https://roc-solid.github.io/examples)
shows what each one's browser half weighs and what it is made of, with screenshots.

Every example with a database uses SQLite: a file beside its server, so each one runs with nothing
else installed.

- [`hello`](examples/hello): the app from [Your first app](#your-first-app), a counting button and
  `GET /hello`. Its `main.roc` is the one `rocx dev` writes.
- [`tasks`](examples/tasks): Tasks, a small team's task lists. **Start here.** File routing, a
  middleware, a database, pages that read endpoints, forms that work without JavaScript, and
  optimistic actions, written the plain way, with comments throughout.
- [`journal`](examples/journal): Journal, a small publication in English and Polish. Markdown
  posts with typed frontmatter, compiled into the server, the intl package, feeds, and a search that
  follows the typing. No database.
- [`board`](examples/board): Board, a live kanban board several people use at once. Drag and drop,
  optimistic moves, channels, presence, and an edit lease kept in `Kv`.
- [`quiz`](examples/quiz): Pinwheel, a live quiz for a room full of phones. An actor per room with
  its own timers, a channel to every phone, and charts of how the room answered.
- [`uptime`](examples/uptime): Status, an uptime monitor and its status page. Checks run by jobs
  and cron, incidents that open and close themselves, email alerts, metrics, the admin's tables, and
  a page that follows it all live over a channel.
- [`notes`](examples/notes): Notes, personal notes in Markdown that AI agents use over MCP. Sign-in
  by a mailed link (packages/auth), personal access tokens kept as hashes, full-text search, a live
  preview, and a JSON API with its OpenAPI page.
- [`pomodoro`](examples/pomodoro): Pomodoro, a focus timer. The same page runs in a browser and as
  an Android phone's native views (`rocx dev --android`), with a chime and a buzz when a session
  ends.
- [`plate`](examples/plate): Plate, a food diary for a phone. The USDA's 7,500 foods seeded into
  SQLite, packets looked up by barcode in Open Food Facts, recipes, targets worked out from a
  profile, and trends charted.
- [`checkboxes`](examples/checkboxes): Million, a million checkboxes that everyone with the page
  open shares, live. A virtual list that renders only the rows that show, the boxes kept in the
  server's memory (`Kv`), and a channel that sends each chunk that changes.
- [`echo`](examples/echo): the smallest app on the server platform, two endpoints, for measuring the
  server and what reading and writing JSON adds (`bench.sh`).
- [`sqlite-vs-turso`](examples/sqlite-vs-turso): the same database work timed in Roc on SQLite and
  on Turso: writes, reads, scans, JSON, a recursive query, eight actors writing at once, and a
  million rows. `just db-bench` puts its numbers on its docs page.

## Components

Every `.rocx` file is made of components, written with the platform's `Html` module
(`import pf.Html`). A component is a function from props to `Html`. The same component runs on the
server, which renders it to HTML, and in the browser, which hydrates it. Pages, layouts and the
error page are components too. So a page can put a component wherever it wants one, as
`<Todos first={…} />`, and wrap it in the contexts it provides.

A component is **pure** or **effectful**, and Roc checks which:

- An **effectful component**, `view!`, may make signals, read a context or read an endpoint. It
  runs once, where it is rendered (rocx writes the call as
  `Html.component(|| Counter.view!({ start_value: || 3 }))`). Its props are **getters**, as Solid's
  props are: you write `start_value : I64` and `|{ start_value }|`, and each place that reads
  `start_value` reads the current value. A hole that reads a prop is patched when the prop changes,
  and the component itself is kept.
- A **pure component**, `view` (no `!`), can't do any of that. It makes markup from its props,
  which are plain values, and it is called where it is written
  (`Heading.view({ id: "why", children: […] })`). When it is given a value that changes, its call
  becomes a hole of its own and runs again. Its holes may still read accessors it was given.

`rocx build` writes whichever call fits, so a component's callers don't change when it changes
from one kind to the other. The docs site's
[components page](https://roc-solid.github.io/components) covers all of this with live demos.

### Styles

A `<style>` inside a component's block, beside its definitions, styles that component's markup and
nothing else, as in Svelte. rocx gives each element written in the block a class named after the
component (`rx-49lxy6`) and adds it to each selector: `.card .title` becomes
`.card.rx-49lxy6 .title:where(.rx-49lxy6)`, one class more specific than written. Two components'
`.card` rules never meet, even in one file, and a component's styles don't reach into the
components it renders.

```roc
Counter := [].{
	view! = |{ start_value }| <div class="counter">…</div>

	<style>
		.counter { display: flex }
		.counter.negative output { color: crimson }
	</style>
}
```

- A page or a layout has no block, so its `<style>` goes at the top level of its file and covers
  the whole file.
- `:global(…)`, `.a :global .b` and `:global { … }` are left as written. A component's
  `@keyframes` are its own; name one `-global-name` to share it.
- A file may define several components (`Stepper := [].{ … }`), and `<Stepper />` calls the file's
  own.

`rocx build` puts every `<style>` into one stylesheet, `Generated/Styles.roc`. The root layout puts
it in its `<head>` with `{Styles.style}`, which renders a
`<link rel="stylesheet" href="/rocx/styles-<hash>.css">`. The file is written beside `start.js`,
named by a hash of its content, so the browser downloads it once for every page, and the server
tells browsers to keep it for good (`cache-control: public, max-age=31536000, immutable`). A change
to any `<style>` gives it a new name. A build with no browser copy has nowhere to put the file, so
the stylesheet stays inline, in a `<style>`.

### Stories

A component's **stories** are the ways it looks, written beside it, as in Storybook: a
`<story name="Tip">…</story>` in its block, among its definitions.

```roc
Callout := [].{
	view = |{ kind, title, children }| <aside class={"callout callout-${kind}"}>…</aside>

	<story name="Tip">
		<Callout kind="tip" title="Name holes by what they hold"><p>…</p></Callout>
	</story>
}
```

Each story becomes a definition in its place (`story_tip! = |{}| …`), so every build type-checks it
against the component. Only a dev build (`rocx dev`, `rocx build --dev`, `just dev`) serves them: a
catalog at `/__rocx/stories`, with every story listed down the side and the one you pick in a frame
that can fill the window. A story is rendered as the app's own page at its path, inside the root
layout, and hydrated. It can tell it is a story by its path (`/__rocx/stories/…`).

An app's `stories/` directory holds modules of stories alone, such as drafts of a page side by side.
Only a dev build includes it, so nothing in it is published (`site/stories/Landing.rocx` holds the
front page and drafts of it in other themes).

### Packages with components

A Roc package can't hold components for a Roc Solid app directly. The compiler lets a package name
a platform only if it is the very one the app names, and a Roc Solid app is built for two
platforms. So a package keeps its components in a `components/` directory beside its `main.roc`.
When an app's header names the package (`charts: "../packages/charts/main.roc"`), `rocx build`
copies each component into the app (`Generated/charts/BarChart.roc`), where `pf` is whichever
platform that half is built for. In a `.rocx` file, `import charts.BarChart` imports that copy. Its
`<style>` joins the app's stylesheet, and the compiler's reports point at the package's own file.

```roc
import charts.BarChart
import charts.Format

<BarChart data!={rain!()} label="Rain each month" format={|mm| Format.num(mm, 0)} />
```

`packages/charts` is one: its `Scale`, `Ticks`, `Path` and `Format` modules are plain Roc, and
`<BarChart>`, `<StackedBarChart>`, `<LineChart>`, `<Sparkline>`, `<DonutChart>`, `<ScatterChart>`
and `<Heatmap>` are its components.

## Syntax

A quick reference. The docs site's [syntax](https://roc-solid.github.io/syntax) and
[components](https://roc-solid.github.io/components) pages explain each item, and every example
there is a real file the build compiles.

### Markup

| You write | It means |
|---|---|
| `<tag attr="text" other={expr}>…</tag>` | An element. An attribute's `{expr}` must be a `Str` |
| `<input type="checkbox" checked?={bool} required />` | `?=` sets a boolean attribute when the value is true. A bare name (`required`) is always on |
| `<a rel??={str}>` | `??=` leaves the attribute out when the string is empty |
| `<li class="row" class:active={bool}>` | `class:name` adds the class when the value is true. All of them end up in one `class` |
| `<h1 style:color={str}>`, `<span style:--size={str}>` | Sets one CSS property, or a custom property, joined with any static `style`. A value that could end the declaration, or that loads something (`url(…)`), is left out. Works in `Html.to_str` too (an email's colours) |
| `{expr}` among children | A **hole**: text (a `Str`, escaped), a number (its digits) or markup (`Html`), chosen by the expression's type. A value it can't show (a record, a `Bool`) is a compile error at its line. `{=expr}` is an older spelling of the same hole |
| `{...expr}` | A **list hole**: a `List(Html)`, joined |
| `{# a comment }`, `<!-- a comment -->` | Nothing |
| `<StatusPill status={s} />` | A component: `StatusPill.view({ status: s })` if the file imports a module `StatusPill`, else the file's own `status_pill(…)`; `StatusPill.view!` when it is effectful. Children become a `children : List(Html)` prop |
| `<>…</>`, `<!doctype html>` | A fragment (`<></>` is empty markup); the doctype |
| `<script>…</script>`, `<style>…</style>` in markup | Their text as written, braces too, never with values in it |
| `<style>…</style>` beside a component's definitions | CSS for that component's markup only ([Styles](#styles)). A page's or a layout's goes at the top level of its file |
| `<story name="Tip">…</story>` beside a component's definitions | One way it looks, for a dev build's catalog ([Stories](#stories)) |
| `&amp;`, `&middot;`, `&#x2014;` | The character |

**Whitespace** follows HTML, as in Svelte, not JSX: each run of spaces, tabs and line breaks is one
space. Whitespace that includes a line break next to an element's own opening or closing tag is
dropped, while a space on the tag's line stays (`<b>Note: </b>`). Inside `<pre>` and `<textarea>`,
text stays as written. To write a literal `<`, `>`, `{` or `}` in text, use an entity or a string
(`{"<"}`).

**Where markup starts.** `<` starts markup only where an expression can begin (after `=`, `(`, `[`,
`,`, `=>`, a lambda's `|…|`, an `if (…)` condition, `else`, `return`, or first on its line), and
only when a letter or `>` follows. After a value on the same line (`a < b`), it is a comparison.

### Control flow in holes

In an effectful component, an `if`, a `match` or a `.map` in a hole is control flow: rocx reads its
branches before the compiler does, as Svelte reads `{#if}`. Each part it makes is made once and kept
while it holds, so the signals and the DOM inside it (focus, typing, a component's state) survive.

| You write | It means |
|---|---|
| `{if ready!() { <Panel /> } else { <p>Waiting</p> }}` | The part the true branch makes: made when the branch holds, kept while it does, and made again only when another branch takes over (Solid's `<Show>`). Each branch's own holes follow what they read. With no `else`, nothing shows otherwise. `else if` chains work, and text in every branch is a text hole |
| `{match card!() { Ok(card) => <Card card={card} />, Err(_) => <p>None</p> }}` | The part of the arm that matches, kept while it matches (Solid's `<Switch>`/`<Match>`). The arm's names (`card`) are getters: they read the newest value where the arm uses them. Guards (`Ok(n) if n > 3 =>`) work too |
| `{...rows!().map(\|row\| <li key={row.id}>{row.title}</li>)}` | A list's **rows**, one per `key` (Solid's `<For>`): each made once, moved with its key, dropped with it. The key goes on the row's root element and may be any value. It is required when the list changes (a row without one is refused at its line). The row's name reads its item's newest value, and a row is told its item changed only when the new one isn't `==` to the old, so one changed item of a thousand runs one row's holes |
| `{...rows!().map_with_index(\|row, i\| <li key={i}>…</li>)}` | A row per position: the row at index 3 stays, and its name reads whatever item is there now |
| `<Repeat count!={n!()} from!={first!()}>{\|index\| …}</Repeat>` | A row per index from `from!` (0 by default), with no list behind them. Only rows that come into the range are made. With `on:viewport`, a virtual list ([packages/virtual](packages/virtual)) |

A row runs once where it is made, untracked, as a component does (Solid's `mapArray`), so it may
hold another `.map` or an `if`. A component at a row's root takes the row's `key`, and the key is
never passed to it as a prop. To
make a part anew for each value (Solid's keyed `<Show>`), map over a list of one, keyed by the value:
`{...[card].map(|one| <Editor key={one} card={one} />)}`.

**A warning to know.** A component whose body reads a prop once, as it runs (`shown = card` at its
top), keeps what it read then. Given a match arm's name or a row's item, which change while the part
is kept, it would show stale data. `rocx build` warns at the call (and `rocx check` exits with 2),
and offers three ways out: read the prop where it is used (in markup, a memo or a handler), wrap the
read in `untrack!(|| card)` if one read is what you mean, or key the part by the value.

A list that reads nothing that changes, or one inside a `<NoHydration>`, is plain Roc: its rows are
made once and need no key.

### In a component

The names below come from `pf.Solid` unless the row says otherwise
(`import pf.Solid exposing [create_signal!, create_memo!, …]`).

**Signals and computations**

| You write | It means |
|---|---|
| `(count!, set_count!) = create_signal!(0)` | A **signal**: an accessor that reads it and a setter that writes it |
| `total! = create_memo!(\|\| …)` | A **memo**: a value computed from others, again when they change. One that reads an endpoint waits for it, and is read as a plain value |
| `(todos, set_todos!) = create_store!(init)` | A **store** (Solid 2.0's `createStore`): `todos.get!(\|s\| s.filter)` reads one part, and its reader runs again only when that part changes (by `==`); `set_todos!(\|s\| { ..s, filter: Done })` writes |
| `is_picked! = create_selector!(picked!)` | A **selector** (Solid's `createSelector`): `is_picked!(row.id)` is whether `row.id` is what `picked!` holds, tracked by that key alone, so a pick runs the holes of the row it leaves and the row it comes to, not every row's |
| `untrack!(\|\| base!())` | A read that isn't tracked: what reads it doesn't run again when `base!` changes. In a component's body, where every read happens once, it says that is meant (`create_signal!(untrack!(\|\| start))`). A dev build warns in the browser's console about a tracked read there, once per place |
| `<ul class:dim={is_pending!(plans!)}>` | Whether a memo that is being read again (after `refresh!(plans!)`, or an action's result) is waiting for its new value, while the last one still shows (Solid 2.0's `isPending`). Always false on the server. `latest!(plans!)` is Solid 2.0's `latest`, the last settled value, which every read already is |
| `picks_context = create_context()`, `<PicksContext value={…}>`, `use_context!(picks_context)` | A **context** (Solid's): rocx names the provider after the definition |

**Effects and timers.** An **effect** runs code with side effects after the page shows a change. None
of these run on the server.

| You write | It means |
|---|---|
| `create_effect!(\|\| room!(), \|room\| …)` | Solid 2.0's split effect: the first function is tracked, and the second runs with its result once the page shows it, and again after each change |
| `create_render_effect!(\|\| query!(), \|_\| set_page!(1))` | A render effect (Solid 2.0's `createRenderEffect`): its second function runs as soon as the first has, during rendering, not after the page is updated |
| `create_effect_with!(\|\| room!(), { apply, error })` | An effect whose failed first half calls `error` with why, instead of the nearest `<Errored>` |
| `on_cleanup!(\|\| …)` | Runs before the computation it is in runs again (an effect's next run), and when that computation or its component goes |
| `on_settled!(\|\| …)` | Runs once, in the browser, once the component is on the page (Solid 2.0's `onSettled`) |
| `stop! = set_interval!(1000, \|\| set_seconds!(seconds!() + 1))` | The browser's timer, run as a handler; `set_timeout!(ms, done!)` runs once. Each returns a function that stops it. It also stops by itself when what started it is cleaned up: its component goes, or its effect runs again |
| `Time.now_millis!({})` | The clock, in a handler, an effect or a timer; never while rendering, since markup made from it wouldn't hydrate (`import pf.Time`) |

**Handlers and events.** A **handler** is a Roc function the runtime calls when an event reaches the
element.

| You write | It means |
|---|---|
| `<button on:click={\|\| set_count!(1)}>` | A handler |
| `<input on:input.value={set_draft!}>` | The handler gets the value (`Str => {}`). `.checked`: whether it is ticked. `.key`: the key's name. `.keys`: the key and the modifier keys held (`Html.Keys`) |
| `<div on:keydown.ArrowUp={up!}>` | For that key only (`.Space`, `.w`), with no modifier key held; it keeps the key from scrolling the page |
| `<input on:keydown.Shift+Enter={send!}>` | For that key with exactly those modifier keys held: `Shift`, `Ctrl`, `Alt`, `Meta`, and `Mod` (⌘ on macOS, Ctrl elsewhere) |
| `<a href="/next" on:click.prevent={go!}>` | The event's default is prevented before the handler runs |
| `<Document on:keydown.Mod+K={open!} />`, `<Window on:resize={…} />` | Handlers on the whole document or window, while the component that renders them is on the page. They render nothing |
| `<li draggable="true" on:dragstart={…}>`, `<ul on:drop={…}>` | Drag and drop. An element with a drop handler takes drops (`on:drop.value`: the text dropped); its `on:dragenter` and `on:dragleave` run once as a drag comes over it and leaves, not once per child. Touch and pen drags work too (hold a quarter second, then drag), in the same events |
| `<li drag:data={[("text/uri-list", url)]} drag:image="ghost">` | What a drag of it carries for other pages and programs, by type, and the element it shows while dragged. `on:drop.data` gives a drop every piece (`Html.DragItem`); `on:drop.files`, `on:paste.files` and a file field's `on:change.files` give files (`Html.File`) |
| `<div on:pointermove.point={moved!}>` | Where the pointer is over the element, as shares of its box (`Html.Point`, 0 to 1), at most once a frame |
| `<Document on:visibilitychange.visible={shown!} />` | Whether the page is showing |
| `<i on:frame.ms={tick!}>` | Every animation frame while the element is on the page, given the milliseconds since the last |
| `<div on:viewport={\|view\| …}>` | When the element shows, scrolls or changes size, given what of it shows (`Html.Viewport`) |
| `Browser.focus!("card-title")` | Moves the keyboard focus to the element with that id once the page is patched (`import pf.Browser`) |
| `Browser.call!("vibrate", { ms: 50 })` | Calls the page's own JavaScript function `vibrate` (given to the runtime as `Runtime.load(wasm, { effects })`) with the argument as JSON, once the handler is done |
| `Audio.play!("/sounds/eat.wav")` | Plays a sound file once the handler is done (`packages/audio`, a plugin) |
| `Vibrate.pattern!([300, 150, 300])` | Buzzes the phone: milliseconds on, off, on (`packages/vibrate`, a plugin) |

**Animation**

| You write | It means |
|---|---|
| `<li transition={Transition.fade}>` | An animation the element plays as the part it is in (a `.map` row, an `if` or `match` branch) comes and goes; `transition:in` and `transition:out` for one direction. An element that leaves stays until its animation ends (`import pf.Transition`: `fade`, `fly`, `scale`, `grow`, `style`) |
| `<li key={card.id} transition:move={Transition.glide}>` | Glides to where a change puts it, and to its new size. An element that leaves one place as one with the same `key` comes in elsewhere glides from there |

**Props**

| You write | It means |
|---|---|
| `<Shows label={word!()} />` | A prop is a getter: rocx passes `label: \|\| word!()`. The child, written with `label : Str` and `\|{ label }\|`, reads it where its code says `label`: tracked in a hole, a memo or an effect (only that part is patched, the child kept), current in a handler, once in its body |
| `<Heading text!={user!().name} />` | A prop named with `!` is an accessor: the same getter, which the child types as `text! : () => Str` and calls as `text!()` |
| `view! = \|{ kind, ..rest }\| <Base {...rest} size={3} />` | Props passed on: `..rest` keeps the props the pattern doesn't name (Solid's `omit`), and `{...rest}` gives them to a component as they are, still getters, the last of a name winning (Solid's `merge`) |

**The document's head**

| You write | It means |
|---|---|
| `<Title>{post!().title} · Notes</Title>` | The document's title, from anywhere in the page: the last one rendered that is still there (`import pf.Title`) |
| `<Meta name="description" content={…} />`, `<Link rel="canonical" href={…} />`, `<Style>…</Style>` | The head's other elements (@solidjs/meta's), from anywhere in the page, put in `<head>`. A later `<Meta>` with the same name takes an earlier one's place. Nothing to import |

**Waiting, failing and server data.** [Talking to the server](#talking-to-the-server) explains these.

| You write | It means |
|---|---|
| `<Loading fallback={…}>`, `<Errored fallback={\|problem, retry\| …}>` | What shows while answers are on their way; what shows when something inside failed |
| `Endpoint.get!(Api.get_api_shelf({}))` | A GET endpoint's answer, as a plain value. The server answers it as it renders the page, and the page carries the answer to the browser. `Endpoint.read!` gives a refusal as a value (`import pf.Endpoint`) |
| `submission = use_submission!(Api.post_join({}))` | The latest submission of a form to an endpoint: `pending!()`, `input!()`, `field!(name)`, `result!()`, `error!()` (`import pf.Router exposing [use_submission!]`) |
| `move! = use_action!(Api.post_move({}))`, `moves = use_submissions!(Api.post_move({}))` | An **action**: `move!(arg)`, in a handler, sends to the endpoint without a form or waiting. `moves` is every submission to it (`all!()`, `pending!()`, `pending_inputs!()`, `clear!(id)`, `retry!(id)`), for an optimistic value: the server's data with `pending_inputs!()` applied |
| `(cards!, set_cards!) = create_optimistic!(\|\| Endpoint.get!(board))` | Solid 2.0's optimistic value: the server's, until a handler writes it; the write holds until what that handler sent is done |

**Navigation** (`import pf.Router exposing […]` unless the row says otherwise)

| You write | It means |
|---|---|
| `<a href={Paths.lists_id({ id })}>`, `<a href={…} replace noscroll>` | A link to one of the app's pages is rendered in place, without loading a document. `replace` replaces the history entry, `noscroll` keeps the scroll position. `rel="external"`, a `target`, `download` or a modifier key leave the link to the browser |
| `a[aria-current="page"]`, `a[aria-current="true"]` (CSS) | Every link to one of the app's pages says where the page is, as Solid Router's `<A>` did (D-086): `aria-current="page"` at its path (and its query, if it has one), `"true"` at a path under it (never `/`). The runtime keeps it right as you navigate; a link that writes its own `aria-current` is left alone. `data-rocx-preload="off"` stops its prefetch |
| `navigate!(Paths.tasks_id({ id: task!().id }))` | In a handler: goes to one of the app's pages, rendered in place, once the handler is done (Solid Router's `useNavigate`). `navigate_with!(to, { replace: Bool.True, scroll: Bool.True })`. Another site, or a path no page has, is loaded by the browser |
| `{if signed_in!() { … } else { <Navigate href={Paths.sign_in} /> }}` | Sends the visitor elsewhere as the page renders: the server answers a 303, the browser navigates there, replacing the entry (`import pf.Navigate`) |
| `<div class="progress" class:on={Router.is_routing!({})}>` | Whether a navigation in place is on its way: true from the click until the new page is on screen (Solid Router's `useIsRouting`). False on the server |
| `search = use_search_params!({})`, `search.get!("days") ?? "7"`, `search.set!([("days", "30")])` | The page's query string (Solid Router's `useSearchParams`). `get!` and `all!` read it, tracked; `set!` merges into it from a handler (`""` removes a name) and navigates in place, keeping the page |
| `use_before_leave!(\|leave\| if (dirty!()) leave.prevent!() else {})` | Asked before each navigation away from the page, which it may stop ([Leaving the page](#leaving-the-page)) |

## Routing

Under an app's `routes/` directory, as in SvelteKit:

- a `+page.rocx` is a **page** at the path its directory names;
- each `+layout.rocx` above it is a **layout** that wraps it;
- a `+server.roc` answers HTTP methods at that path: its **endpoints**;
- `+error.rocx` is the **error page**, shown for a path nothing answers (404) and for a page that
  failed.

```
routes/+layout.rocx              view! = |{ meta, children, .. }| <html>…{...children}…</html>
routes/+page.rocx                /
routes/blog/[slug]/+page.rocx    /blog/:slug; its view is given params : { slug : Str }
routes/blog/[slug]/+server.roc   get! = |{ params, .. }| …, put! = |{ params, body, .. }| …
routes/sitemap.xml/+server.roc   /sitemap.xml (a directory may name a file)
routes/+error.rocx               where nothing is
```

A directory is a part of the path in lower case (`blog`, `getting-started`), with dots between
letters or digits for a file's name (`sitemap.xml`, whose name in `Api` and `Paths` is
`sitemap_xml`), or a param in brackets (`[slug]`).

A route file that imports `pf.Html` is a component: a page is `view! = |{ params }| …`, a layout
`view! = |{ meta, children, params }| …`, the error page `view! = |{ status, problem }| …`. Roc's
record patterns are closed, so write `..` for the fields a view doesn't read. A route file may also
define components of its own (`Board := [].{ view! = … }`) before its other definitions or after
them, but not between. `<Board />` calls the file's own, and it can use the file's definitions as
the page does.

### What rocx generates

`rocx build` writes each route file as a module under `Generated/`, keeping its lines, and writes
these beside them:

- `Generated/Routes.roc`: `Routes.respond!(request, context)` answers a request. A GET from a
  browser gets the page inside its layouts; other requests get the endpoint for their method (a
  JSON GET too); a method the path doesn't have gets a 405 with `Allow`; a path nothing answers gets the error page (plain text
  for a client that isn't a browser).
- `Generated/Paths.roc`: a function for every page's path (`Paths.blog_slug({ slug })`), so a link
  to a page that doesn't exist doesn't compile. A name Roc reserves gets a `_` (`Paths.platform_`).
- `Generated/Api.roc`: the app's contract. A function for every endpoint and channel, with its
  method, its URL and the types its handler's annotation gives
  (`get_blog_slug : { slug : Str } -> Endpoint(context, {}, Post)`). The browser's copy has the same
  contract and imports no route file, so any module may import `Api`: a store, a job, an actor that
  publishes on a channel.
- `Generated/Handlers.roc`, on the server only: each endpoint bound to its handler, which the
  router answers with. `main.roc` may import it to mount handlers elsewhere too (an MCP server).
- `Generated/App.roc`: the app's server program ([The server's program](#the-servers-program)).
- For an app with pages, `Generated/Root.roc` ([How a page is put together](#how-a-page-is-put-together)).

Every handler must be annotated, for example
`get! : { request : Server.Request, params : { slug : Str }, context : c } => Try(Post, Endpoint.Refusal)`.
`rocx build` refuses one that isn't, since the annotation is where `Api` gets its types.

**Middleware** (the platform's `Middleware`) runs around answers: the app's default middleware
around every request, and a route file's own `middleware = …` around that file's page and
endpoints. A page that names none runs behind the one the `+server.roc` beside it names, so one line
guards a page and its data, and a page can't render for someone its data refuses (D-079); a page
that names its own keeps it. Only the page's own directory counts: a parent's `+server.roc` doesn't
guard the pages below it, and `rocx build` refuses a `middleware` in a layout or the error page,
which nothing would run. A middleware may answer by itself (a redirect to sign in) or pass the
request on, with a **context** for the handlers (who is signed in). A handler reads it as `context`.

### How a page is put together

`Generated/Root.roc` is in both programs. `Root.view!` tells the runtime about the app (its build's
id, a hash of what the app is built from, and its route table), matches the location against the
routes as `Routes` does, and renders the page inside its layouts.

- The root layout is the document (`<html>…`). Without one, rocx uses a default. It is given the
  page's `meta`.
- Below the root layout, each other layout above the page, and then the page, is a **level**. A
  level is keyed by its file and its own params (`routes/lists/[id]/+page.rocx id=7`). When you
  navigate in place, every level whose key stays the same is kept, with its state; the others are
  made anew.
- Around the levels, inside the root layout, is an `<Errored>`. A failure nothing else catches shows
  the error page with status 500, or with the status a read was refused with when it is a 4xx (so
  `Endpoint.get!` of a note that isn't there makes the page a 404). A path no page has shows the
  error page with a 404.
- A layout is given its own params (`routes/[lang]/+layout.rocx` gets `lang`; the root layout's
  are `{}`), not the page's, and the page's `meta` as a getter that follows the page while the
  layout is kept. Every page under a layout that takes `meta` must give it the same type; rocx build
  says so at a page whose `meta` differs.
- A layout is kept across navigations unless its body read the location once
  (`Router.location!({})` outside a hole or memo). Then the runtime makes that level anew on each
  navigation, so it never shows what the last page knew, and a dev build says so in the console.
  Read the location where you use it (in markup, a memo) and the layout is kept, with its
  sidebar's scroll, an open menu and its signals.

With `--client <out>`, `rocx build` also writes the browser's copy of the app: `<out>/main.roc` (the
browser's program, `Root.view!`) and `<out>/static/rocx/` with `start.js`, `runtime.js` (minified:
its comments and indentation gone, D-075; as it is written under `--dev`) and the stylesheet. Build the wasm beside them
(`roc build --target=wasm32 --opt=size --output=<out>/static/rocx/app.wasm <out>/main.roc`) and
serve the directory with the server's `--static <out>/static`. A page's `/rocx/start.js` loads the
other files. `rocx dev` does all of this for you.

With `--static <out>`, `rocx build <dir>` writes the app as static files, for a host with no server
(GitHub Pages, a CDN): it builds the app for production, starts its server on a free port, and asks
it for `/`, each page whose path has no params and every page those link to, each written as
`<path>/index.html`, then `404.html`, the plugins' files, `static/` and `rocx/` (D-073). A page carries
the answers to the reads it made while rendering. `--base /docs/` puts every URL under a path;
`--route <path>` asks for one no page links to (a page with params, `/feed.xml`); `--built <build>`
uses a build already made. What only a server answers (methods that write, events, channels, a page
with middleware of its own) isn't in the copy, and the build lists it. The docs site is built this
way. The copy's `runtime.js`, as `--release`'s, has only what the app uses (D-087): the host
functions its wasm imports and the runtime's code they and the page reach, navigating in place only
for an app of more than one page (or one that navigates), drags, a pointer's point and glides only
where its markup has them. The benchmark's page ships 124 KB of the runtime's 175.

The browser's copy keeps each endpoint's method, URL and types but not its handler, and each route
file without its middleware. If a page or component reaches a module that imports what only the
server has (`pf.Db`, directly or through another module), the build warns at that import: the
browser's program couldn't compile it. An app of endpoints alone has no browser's `main.roc`, and
the build says so.

### Navigating in place

In the browser, clicking a link to one of the app's own pages (same origin, under the site's base
path, a path the route table has a page for), calling `navigate!`, and going back or forward don't
load a new document. This works as in Solid Router, and apps change nothing to get it:

1. The runtime fetches the new page's document as the server would answer a full load (through its
   middleware, with its reads answered on the server), adding `x-rocx-navigate: 1` so a middleware
   can tell the two apart.
2. The old page stays on screen meanwhile (`Router.is_routing!` is true).
3. The runtime renders the new page from the wasm, using the answers that document carries. Nothing
   else is fetched.
4. It pushes the address, updates `Router.location!`, keeps the levels whose key is the same and
   makes the others anew, reconciles `<head>` with the new document's (an equal element, such as a
   stylesheet, is kept) and takes `<html>`'s and `<body>`'s attributes from it.
5. It scrolls to the top (or to the hash's element; back and forward restore the old position),
   moves the focus to the start of `<body>`, and announces the new title to screen readers.

Documents fetched in the last 10 seconds are used again. Anything that isn't an app document of
this build is loaded by the browser instead: a text answer, a crash, a page from a newer deploy. So
are links with `rel="external"`, a `target`, `download` or a modifier key, paths no page has, and a
place on the same page. The document dispatches `rocx:navigate` and `rocx:navigated` (`{ url, ms }`)
events. A `<script>` a page renders runs on a full load only, so page JavaScript that sets itself up
on `rocx:ready` should do so again on `rocx:navigated`. `<html data-rocx-navigation="off">` turns
navigation in place off.

**Prefetching.** A link to one of the app's pages is prefetched when the pointer rests on it for
65 ms, when the keyboard focuses it, or when a finger touches it: its document (with
`x-rocx-navigate: preload`, at a low priority) and its code go into the cache a navigation reads, so
the click asks for nothing more. `data-rocx-preload="off"` on a link, or on an element above it
(`<html>` for the whole app), turns it off; `"viewport"` prefetches links as they scroll into sight.
A prefetch renders a page on the server: a middleware that counts views should ignore
`x-rocx-navigate: preload`, and an app whose pages are costly can set `off`.

**View Transitions.** `<html data-rocx-transitions>` makes each navigation a
[View Transition](https://developer.mozilla.org/docs/Web/API/View_Transition_API) (the browser's
cross-fade, with `view-transition-name` pairing elements across pages), where the browser supports
them and the user hasn't asked for less motion.

### Leaving the page

A component that holds unsaved work registers a listener with `use_before_leave!(|leave| …)`
(Solid Router's `useBeforeLeave`). The runtime runs it as a handler before each navigation in place:
a link, `navigate!`, `<Navigate>`, a GET form, a submission's redirect, a change of the query alone,
back and forward.

The listener gets the leave (`Leave`: `to`, `from`, `options`, `delta` for back and forward,
`default_prevented`). It may stop it with `leave.prevent!()`: the page and its address stay (back
and forward, whose address had already changed, are undone). It may also keep the leave and let it
go later from another handler, such as your own "Discard your changes?" dialog:
`leave.retry!(Bool.True)` goes without asking the listeners again, `retry!(Bool.False)` asks them
again. The listener goes when its component goes.

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

A listener must decide from what the page already has: one that waits for the server can't hold a
navigation. A full load (leaving the site, reloading, closing the tab) can't be held by the page at
all. For those, the runtime asks each listener ahead of time (with `to` as `""`, its writes
dropped), again whenever what it read changes, and listens for `beforeunload` only while a listener
would stop a load; the browser then asks the user in its own words. On the server,
`use_before_leave!` does nothing.

### The server's program

Every app with routes gets its program in `Generated/App.roc`. What you write besides the route
files and their modules is `main.roc`, which says what only you can:

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

`App.program` takes:

- `init!`: makes the app's context once, when the server starts (after the migrations, so it may
  read the database), from the text of `--context-file`. Put settings read once, handles, anything
  in it. The host keeps it for as long as the server runs, and every call into the app's code is
  given it: each request's middleware, a job's run, an actor's methods, a plugin's routes and loops.
  An `Err` stops the server.
- `middleware`: runs around every request.
- `database`: `Postgres` (the default, at `--database-url` or `DATABASE_URL`), `Sqlite(path)` (a
  file in the server's process), or `Turso(path)` (the same SQL on Turso's engine).
  `--database-url sqlite:<path>` or `turso:<path>` overrides the path or the engine.
- `openapi`: whether to serve the endpoints' OpenAPI document (`Off` by default; see below).
- `plugins`: what packages add to the app (their routes answer behind the middleware, before the
  app's own).

Every request is answered by a plugin's route or by `Routes.respond!`, behind `middleware`.
`App.jobs` lists the jobs the app's modules define, for the jobs plugin (`packages/jobs`). Each is
defined at the top of its module's block (`welcome = Job.define("welcome", |context, input| …)`, or
`Job.define_with`); one defined elsewhere, two with one name, or jobs with no jobs package in the
header fail the build. The migrations are the app's `migrations/*.sql`, embedded, run in the order
of their names.

**Logs.** The server's log lines and the app's (`Log.info!("gate failed", { path: request.path,
error: why })`, and `debug!`, `warn!`, `error!`) are events with fields. The format is `Auto`:
`ROCX_LOG` (`pretty` or `json`) if it is set, else pretty on a terminal and JSON elsewhere. To fix
it in code, write `program = { ..App.program({ … }), logs: { format: Json } }` (or `Pretty`). See
`server/README.md`, "The log".

## Talking to the server

A route's `+server.roc` is the one way an app talks to its server. Its endpoints are a method at a
path, typed at both ends, and anything else that speaks HTTP can call them too. What goes and comes
is JSON. The docs site's [Talking to the server](https://roc-solid.github.io/calls) page has live
demos of each.

**Reads.** A component reads a GET endpoint as a plain value with
`Endpoint.get!(Api.get_api_shelf({}))`. An answer that isn't 200 fails the computation that read it,
and the nearest `<Errored>` shows why. `Endpoint.read!(…)` gives a `Try(result, Server.Problem)`
instead. `Endpoint.with_query(endpoint, query)` adds a query string, which the handler reads as
`request.query`. What the route's middleware handed on is the handler's `context`
(`get! = |{ params, context, .. }| Ok(…)`).

- A page's own data is best served at the page's own URL: `routes/members/+server.roc` answers
  `GET /members` for JSON, behind the same middleware as the page there. A layout, which many pages
  share, reads an endpoint at a path of its own (the docs site's footer reads `GET /api/facts`).
- A handler runs only on the server, so it may use what only the server has (`Db`, `Job`). The
  browser's copy of `Api` is the same contract, so a type a route's annotation names must compile
  in the browser too: `rocx build` refuses one from a module that imports `pf.Db`, naming the route,
  the type and the module. A wrong body or answer type doesn't compile in either program.
- An `F64` travels as a JSON number; one JSON can't write (NaN, an infinity) is a 500 that says so.
  A `Try` travels as its tag union (`{"Ok":3}`, `{"Err":"Empty"}`).

**Reads while the server renders.** While the server renders a page, each GET a component reads is
answered in the same process, through the endpoint's route, as the browser's request would be: with
`accept: application/json`, the page's cookies and headers, behind the route's middleware. Each URL
is asked once per render. Its answer (any status) goes into the page, so when the browser hydrates
it reads the answer there and asks the server nothing. (Reads inside a `<NoHydration>` aren't
carried, since the browser never runs that markup.) A later read (`refresh!(memo!)`, a URL built
from a signal) fetches the endpoint's URL. A read that its middleware answers with a redirect (a
signed-out visitor sent to sign in) makes the whole page that redirect.

**From handlers.** A handler sends to any endpoint with
`Endpoint.send!(Api.post_api_shout({}), draft!(), Call.fetch!)`.

**Forms.** `<form method="post" action={Endpoint.url_of(join)}>` posts to an endpoint. The endpoint
reads the form's fields by its body's type: a number from its text, an unticked box as `Bool.False`,
a name given several values as a `List`. A field that is missing or wrong is a 400 naming it. So an
action's JSON and a plain form post arrive as the same typed record.

`submission = use_submission!(join)` is the form's latest submission (Solid Router's
`useSubmission`): `submission.pending!()`, `input!()` (what was typed, as the endpoint reads it),
`field!("name")`, `result!()`, `error!()`, `clear!()`.

- With the runtime loaded, the form is sent with `fetch` and the page stays.
- Without it (before it loads, or with JavaScript off), the browser posts the form, and the
  endpoint sends it back to the page with a **flash**: what was typed and the result or refusal,
  kept on the server for a minute (a cookie holds its id) and read once. The submission reads it
  (`Server.flash!({})` reads it on the server). A password typed is never sent back.
- Either way, a redirect of the endpoint's own is followed.

A result makes the page's reads read again (Solid Router's revalidation), and the submission stays
pending until they are in. A handler on the server can say which reads to refresh with
`Router.revalidate!(keys)`.

**Actions.** `move! = use_action!(endpoint)` is a function a handler calls with the endpoint's
argument: a submission of its own, sent without a form and without waiting (Solid Router's
`useAction`). `use_submissions!(endpoint)` lists every submission to it (`all!()`, `pending!()`,
`pending_inputs!()`, `clear!(id)`, `retry!(id)`).

An **optimistic value** shows a change at once, before the server confirms it. Write it as a memo of
the server's data with `pending_inputs!()` applied: it gives way to the server's data, read again,
with no frame of the old in between, and a refusal puts it back. Or write it as Solid 2.0 does,
`create_optimistic!(|| Endpoint.get!(board))`: a value a handler writes ahead of the server, held
until what that handler sent is done.

`Endpoint.with_fields` gives a form's fields ahead of time (Solid Router's `action.with`). A form
with files, or an action given a dropped or picked file, is sent as multipart and read with
`Server.file`.

**Events.** An endpoint's `events!` streams server-sent events: a loop that sends and sleeps, a call
of its own on the server, ended by `?` when the client goes. A component listens with
`Endpoint.listen!(Api.events_…(params), Call.listen!, |event| …)`, and each event runs the handler.
Start it in an effect (`create_effect!(|| org!(), |org| Endpoint.listen!(…))`): it listens while
its component is on the page, starts again when what the effect read changes, and stops when the
component goes.

**Channels.** A **channel** carries live messages for pages that follow some data. A route's
`channel!` checks who may subscribe (behind the route's middleware, and again every 15 seconds) and
types what is published on it and what pages may say. A component subscribes from an effect with
`Endpoint.subscribe!(Api.channel_…(params), heard!)` and hears `Resync` (read your data again), then
each `Message`. The server publishes with `Endpoint.publish!` from a request, a job or an actor.
Every channel a tab subscribes to shares one stream, `/rocx/live`. See `server/README.md` and the
docs' [live page](https://roc-solid.github.io/platform/live).

**OpenAPI.** An app can serve its endpoints' OpenAPI 3.2 document, which rocx writes as
`Api.openapi`: each path and its params, each method with its handler's doc comment, and the JSON
Schemas of what it is sent and answers, from the handlers' types (written or inferred). It is off
unless `App.program` says otherwise: `openapi: Document` serves `GET /openapi.json`, and
`Page(Swagger)` or `Page(Scalar)` also serves `GET /openapi.html`, the document in Swagger UI or
Scalar (pinned on jsDelivr and checked against its hash). How, without reflection: a type's parser
works with any format, and the platform's `OpenApi` is a format that reads nothing and writes the
schema of each shape it is asked to read. A body a form can send is listed as a form's too
(URL-encoded and multipart), beside JSON.

**No server functions.** Roc Solid has no `server!` functions; `rocx build` refuses one at its line.
Write a `get!` in a route's `+server.roc` instead (its input is the path's params or the query) and
read it with `Endpoint.get!(Api.get_…(params))` where you would have called it.

## Safety

- `Html` is opaque: nothing outside the module can wrap a string as markup. Text and attribute
  values are escaped.
- `href`, `src`, `action`, `formaction`, `poster` and `cite` take only relative URLs or `http`,
  `https`, `mailto` and `tel` ones (`java\tscript:` is caught too). Anything else becomes
  `about:invalid#rocx-unsafe-url`. An image's URL (`<img src>`, `<link href>`, `<source src>`,
  `<video poster>`) may also be a `data:image/…` URL, SVG included, since the browser shows it as a
  picture with its scripts off.
- Inline handlers (`onclick=`), a computed `style` and unquoted values are refused when building.
  Handlers are Roc functions, never text in the page.
- Markup built by hand in Roc (`Html.element`, `Html.void`, `Html.attr`) has its names checked by
  every renderer (D-079): a tag is an ASCII letter, then letters, digits and `-`; an attribute's
  name may also have `_`, `.` and `:`, and never starts with `on` (an inline handler); a
  `<script>` is written only with its text as a `.rocx` file has it. What isn't is left out, never
  a failed page: the server logs the page's path and the names, and the browser warns on the
  console.
- The browser's runtime builds elements with `createElement` and sets text and attributes as such.
- `rocx lint` refuses `Html.source_text` (raw HTML) in hand-written `.roc` files.
- `Middleware.same_origin` refuses a change (a POST, a PUT…) that another site's page sends. The
  docs site's default middleware starts with it.

The docs site's [safety page](https://roc-solid.github.io/safety) shows each rule at work.

## Commands

```sh
rocx new <dir>           # a new app from rocx's template (sign-in, its users, security headers),
                         # its .rocx-version and .rocx link made
  --db sqlite            # its database: sqlite (the default), postgres or turso; asked at a terminal
rocx dev [dir]           # build the app (a directory with routes/) and serve it at :8080 with the
                         # server's --dev; rebuilt and restarted on each save, open pages reloaded;
                         # a mistake shown at its .rocx line; writes the smallest main.roc if there is
                         # none; checks the app's SQL after each start (as rocx check --sql)
  --port 8080            # where (or PORT)
  --android [--lan]      # each build for the Android dev client too (a phone or emulator over adb;
                         # --lan: phones on this Wi-Fi, a QR code shows the way); see examples/pomodoro
  -- <server options>    # given to the app's server (--database-url URL, …; below)
rocx build <dir>…        # each .rocx file under the directories becomes the .roc file beside it; an
                         # app's routes/ become Generated/ (Routes, Paths, Api, Handlers, App, and Root
                         # for an app with pages); each folder under content/ becomes
                         # Generated/Content/<Name>.roc (its Markdown files: packages/markdown's README)
  --client <out>         # and the browser's copy of the app in <out> (main.roc, static/rocx/)
  --dev                  # and the stories, served at /__rocx/stories
rocx build <dir> --release <out>  # the app built to deploy: <out>/server (optimized for speed) and
                         # <out>/static (the app's static/ and the browser's files, its wasm
                         # optimized for size); run <out>/server --static <out>/static behind a proxy
                         # that speaks TLS
  --target arm64musl     # for another machine (arm64mac, x64mac, arm64musl, x64musl: a musl one is
                         # a static Linux executable); this one's by default
rocx check [dir]         # the app (here, or in dir) checked from its sources: rocx build as rocx dev
                         # runs it, then the compiler on the server's program and the browser's, each
                         # problem at its .rocx line; exit 1 on an error, 2 on warnings alone
rocx check -- <command>  # run a command (roc check …), its reports pointed into .rocx files
rocx check --sql [dir]   # the app's SQL checked by its own database engine, and its rows by the
                         # compiler: each literal statement at a Db.all!/one!/run! is prepared on a
                         # scratch database built from the app's migrations; what the engine refuses,
                         # parameters that don't match the call, and a row record that doesn't fit the
                         # columns (a missing field, a type, a nullable column read as a plain value)
                         # are reported at their lines; exit 1 if any
  --engine turso         # on Turso (for a SQLite app), or sqlite (for a Turso app), instead
  --verbose              # also list the calls it can't check (interpolated SQL, SQL in a variable,
                         # Db.unchecked)
  -- <server options>    # given to the app's server (--database-url, or --sql-database for Postgres)
rocx test [dir]          # rocx build as rocx check runs it, then the app's expects (roc test main.roc,
                         # with the compiler rocx has), each failure at its .rocx line
rocx lint <dir>…         # refuse Html.source_text in hand-written .roc files
rocx routes <dir>        # list an app's routes: method, path, file, middleware
rocx fmt <path>…         # format the Roc in .rocx files and hand-written .roc files with roc fmt
  --check                # only say which files aren't formatted
rocx qr <text>           # the text as a QR code in the terminal (--pbm: as a PBM image)
rocx upgrade [<version>] # install a version of rocx (the latest by default) and make it the default;
                         # in an app, move the app onto it (.rocx-version, .rocx)
rocx --version           # which rocx this is (an installed version's VERSION; a clone's commit)
```

An app outside this repository names the version of rocx it is built with in `.rocx-version`
(committed), and reaches the platform and the packages through `.rocx`, a link to that version
(gitignored): its header says `pf: platform "./.rocx/server/platform/main.roc"`. Every command on an
app (`dev`, `build`, `check`, `test`, `routes`, `lint`) makes the link (and mends it), and when the
app wants another version than the one running, that version runs the command instead, installed
first if it isn't (into `ROCX_HOME`, `~/.rocx` by default). rocx from a clone links apps to the clone.

`rocx` is `bin/rocx`, a native executable built from its Roc (`rocx-cli/`). `just setup` builds it,
and any script in this repository builds it again when `rocx-cli/` has changed. From another
directory, run `<repo>/bin/rocx …`, or put `<repo>/bin` on your PATH. A Node script gets its path
from `rocxBinary()` (`import { rocxBinary } from "<repo>/server/build.mjs"`), which builds it if it is
missing or stale.

- `build` writes a file only when its content changes, deletes `.roc` files it wrote whose `.rocx`
  is gone, and stops at the first markup problem with its line and column.
- Because the lines match, the compiler's reports are already at the right line. `check` rewrites
  `Page.roc:22:48` to the `.rocx` file and column, quotes the `.rocx` line, and moves the caret onto
  the same code there.
- `fmt` runs `roc fmt` (the compiler rocx builds with: an installed version's, a clone's
  `.tools/roc-active`, else `$ROC` or the `roc` on the PATH) on
  each `.rocx` file under the paths and each `.roc` file rocx didn't write. Markup, and the Roc in its
  holes, are left as written: markup moves only with the code around it, and the text of a `<pre>`
  or `<textarea>` never moves. `just fmt` formats this repository, and `just check` fails on a file
  that isn't formatted.

**The server's options.** An app's server is one executable (`build/server` under `rocx dev`). Its
options, each also read from the environment variable in parentheses:

```sh
--port 8080 --host 127.0.0.1   # where to listen (PORT)
--static DIR                   # files served as they are (also --file /PATH=FILE)
--database-url URL             # postgres://…, or sqlite:<path> / turso:<path> (DATABASE_URL)
--context-file FILE            # the text init! is given
--public-url URL               # where the app is, for links it sends (PUBLIC_URL)
--max-body 16MiB               # the largest request body (MAX_BODY)
--kv-max-mb 64                 # the key-value store's limit (KV_MAX_MB)
--dev                          # reload pages on restart, show crashes in the page, plugins' dev pages
--debug                        # memory and plugin debug paths under /__rocx/
```

`--help` lists the rest (`--roc-threads`, `--actor-idle-ms`, `--live-beat-ms`).

### In an editor

`editors/` (see its README) has one TextMate grammar for `.rocx` files (Roc, markup, Roc again in
holes, CSS in `<style>`), which two editor packages use:

- `just vscode-extension` installs the VS Code extension: highlighting, and a `rocx` task type.
  Run Task lists `dev <dir>` and `check <dir>` for each app in the workspace (or any command, such
  as `just dev`), and each build's output becomes problems at their `.rocx` lines.
- `just orca-plugin` installs the [Orca](https://github.com/stablyai/orca) plugin, which highlights
  `.rocx` and `.roc` files.

There is no language server yet: what the editor shows is what the build says. `just grammar-check`
tokenizes every `.rocx` file, fails on one whose markup the grammar leaves open, and then runs the
extension's tests.

## The platforms

**The server platform** (`server/`). An app gives it a record (`App.program` writes it): `respond!`,
whose answer may be a page of components or a stream, and its database, migrations, actors, log
format, plugins and routes.

- Each call into Roc runs as a coroutine on one of a few threads of Roc's own. It pauses while an
  effect waits, so a call that waits holds up nothing else and holds no thread.
- A crash ends only its own call (a 500, a stream ended, a job run again); its memory is freed and
  its transaction rolled back.
- It renders a page of components natively, byte for byte as the browser's runtime would.
- It gives the app a database (Postgres, or SQLite in the server's process on SQLite's engine or
  Turso's: `Db`, migrations, transactions, notifications); plugins (what a package adds to an app:
  routes, tables, loops, paths for development, checked when the server starts); requests to other
  servers (`Http.fetch!(url, init)`, like JavaScript's `fetch`); bodies as bytes, and forwarded from
  elsewhere (`Server.forward`); cookies; settings (`Env`, `Setting`); encryption (`AesGcm`), P-256's
  key pairs, ES256 and ECDH (`P256`) and random bytes; values in memory by key (`Kv`: TTLs, atomic
  counters, a size limit); channels (typed live updates, one stream per tab, told when a
  subscription was dropped or its tab went); and actors (typed asks, tells and timers, one message
  at a time, their state and timers kept in the database when there is one).
- Some things are packages rather than platform features: files (`packages/storage`: S3, a
  directory or memory), crypto written in Roc (`packages/crypto`), jobs and cron (`packages/jobs`, a
  plugin, with a jobs page in `packages/admin`) and email (`packages/email`, a plugin: SMTP, or a
  dev mailbox at `/__rocx/mail`). The rule: something goes in the platform only if it needs the
  host or the transpiler; everything else is a package.
- The Rust host gives general things (HTTP, database connections, TCP and TLS, background loops,
  isolated calls, the key-value store, channels' streams, actors' mailboxes and timers). Migrations,
  plugins, and actors' state and timers are the platform's Roc, written on top of them.
  [roc-pg](https://github.com/niclas-ahden/roc-pg), a Postgres client whose queries are checked at
  build time, runs on the platform's `Tcp`.
- `rocx build <dir> --release <out> --target arm64musl` builds one static Linux executable (and what
  it serves), from a Mac too.

`server/README.md` has every module's API, and the docs' [platform pages](https://roc-solid.github.io/platform)
and [reference](https://roc-solid.github.io/platform/reference) cover each part.

**The browser platform** (`web/`). The app's page is one wasm module. A Rust host passes each of
Roc's effects to `web/runtime.js`, which keeps the graph of signals, memos and computations,
hydrates the document from the server's HTML and answers, runs holes again when what they read
changes, and sends requests. `web/README.md` explains how.

**A native host for phones** (`native/`, an experiment). `rocx dev --android` runs an app's pages
as Android's own views, with no WebView and no JavaScript: `native/core` is a Rust port of the
browser runtime's engine. See `spike/native-apps/README.md` and `examples/pomodoro`.

## Repository layout

| Where | What |
|---|---|
| `rocx-cli/` | rocx itself, in Roc on the CLI platform: the command (`main.roc`), the transpiler (`Transpile.roc`), scoped styles (`Styles.roc`), routing (`Routes.roc`), the build (`Build.roc`) and its warning when the browser's copy reaches server-only code (`ServerOnly.roc`), stories, error remapping (`Remap.roc`), `rocx fmt`, `rocx dev` (`Dev.roc`; `SiteDev.roc` for `just dev`), `rocx check --sql` (`CheckSql.roc`), and the docs site's generated modules (`Site.roc`, `SiteSources.roc`, `SiteReference.roc`). Built into `bin/rocx`. `rocx-cli/rocx.mjs` lets the JavaScript tests call its functions by name (`rocx internal`) |
| `cli/` | The command-line platform rocx runs on: its Roc modules (`cli/platform`: output, files, commands, a watched directory tree, signals, and `Events.next!`, the one wait) and its Rust host (`cli/host`); see its README |
| `server/` | The server platform: native Roc in a Rust host (tokio, hyper, Postgres or SQLite, plugins, channels, actors, `Kv`); see `server/README.md` |
| `web/` | The browser platform: the modules components are written with (`Html`, `Solid`, `Store`, `Router`, …) and HTTP's (`Server`, `Endpoint`, `Channel`, `Events`, `Middleware`, `OpenApi`), which the server platform shares; its Rust host; `runtime.js` and `start.js`; see `web/README.md` |
| `packages/` | The ecosystem. Each package has a README, a `PROPOSALS.md` of what it waits on, and a page on the docs site. A package whose modules use the server platform names it in its `main.roc`, with a `browser.roc` beside it for what the browser's half sees |
| `packages/charts` | Bar, stacked bar, line, sparkline, donut, scatter and heatmap charts, styled by custom properties: the arithmetic in plain Roc (scales, round ticks, SVG paths, in `Dec`), the components copied into each app |
| `packages/forms` | Zod-like schemas: one for the page and the endpoint, issues shown in place, `LiveForm` |
| `packages/auth`, `stripe`, `jobs`, `email`, `push`, `audio`, `vibrate` | Plugins: sign-in by mailed links and at providers, with sessions, middleware and two-factor sign-in (`Auth.plugin`), payments and subscriptions through Stripe's Checkout and Customer Portal, its webhook kept in step (`Stripe.plugin`), jobs and cron in the app's database (`Job.plugin`), email over SMTP or the dev mailbox (`Email.plugin`), Web Push (`Push.plugin`, `<PushButton>`), sound files from a handler (`AudioPlayer.plugin`), the phone's vibration (`Vibrator.plugin`) |
| `packages/ai` | Claude from the server, through Anthropic's Messages API: an answer whole (`Ai.ask!`), streamed to a page as it is written (`Ai.stream!`), read into a Roc type (`Ai.extract!`), a model that uses the app's functions as tools, packages/tools' `Tool`s (`Ai.run!`), and agents, each usable as another's tool (`Agent`); conversations kept exactly (`Message`), each turn's tokens on the log (`Ai.plugin`) |
| `packages/tools` | What a tool is, for a model to use (`Tool`, what it answers, `Content`, and any JSON, `JsonValue`), on no platform: packages/ai gives tools to Claude and packages/mcp serves the same tools over MCP |
| `packages/storage`, `crypto`, `qr` | Files in a bucket whose URL says where (S3, a directory, memory) with signed URLs; SHA-256, HMAC, HKDF, Base64 and hex in plain Roc (and SHA-1 and Base32, for authenticator codes); QR codes and `<QrCode>` |
| `packages/admin`, `guard`, `intl`, `markdown`, `mcp`, `otel`, `posthog`, `presence`, `testing`, `virtual` | A Django-style admin for the app's tables (and the jobs page); rate limits, feature flags and request guards; formatting and translations; Markdown with typed frontmatter; an MCP server; OpenTelemetry metrics and logs; PostHog error tracking; who is here; test helpers; virtual lists |
| `packages/dbcheck` | What `rocx check --sql` checks rows with; apps don't import it |
| `examples/` | Whole apps, each with its README and tests ([Examples](#examples)) |
| `site/` | The docs site: pages in `routes/`, components in `Ui/`, demos in `Demos/`, real examples in `examples/`, its program in `main.roc` ([The docs site](#the-docs-site)) |
| `editors/` | The `.rocx` grammar, the VS Code extension and the Orca plugin |
| `native/` | The native host for phones, an experiment: a Rust port of the browser runtime's engine (`core`), Android's views (`android`, `android-dev`), and a Mac test harness (`mac`) |
| `test/`, `web/test/`, `site/test/`, `server/test/` | Tests: the transpiler, routing and `rocx` commands; the browser platform; the docs site in a browser; the server platform |
| `spike/` | Experiments and designs, each with a `README.md` or `DESIGN.md` |
| `DECISIONS.md`, `TODO.md` | Why things are as they are (D-001 onward), and work still to do |

## The docs site

`site/` is a Roc Solid app and uses everything above. Its pages, in `site/routes`, are Roc Solid's
front page (`/`) and four parts: rocx (`/rocx`, `/syntax`, `/components`, `/routing`, `/calls`,
`/safety`, `/tooling`, `/showcase`), the platform (`/platform`, …), the ecosystem (`/ecosystem`, and a
page for each package: `/ecosystem/charts`, …), and the examples (`/examples`, and a page for each
app). `site/main.roc` is its program.

- **Design.** `site/static/site.css` holds the tokens (`:root`: neon on near black, always dark;
  colours, one type scale and one space scale, radii, glow) and the base styles (elements only, no
  classes). The components in `site/Ui` (`PageHero`, `Button`, `Feature`, `Demo`, `Topbar`,
  `Sidebar`, …) and the demos in `site/Demos` each have their own scoped `<style>`, and the
  components have stories, which `just dev` shows at `/__rocx/stories` (`Ui/Tokens.rocx` shows the
  tokens). Pages are written with these components, not with site-wide classes; what only one page
  needs is in a `<style>` at the top of its file.
- **Demos.** Each demo in `site/Demos` is on the page that shows it: a counter, a to-do list, a
  shelf and a bag sharing a store, a planner whose plans are dragged between days, Snake, and a flock
  of birds, frame by frame, with sounds (files in `site/static/sounds`, made by `site/sounds.mjs`,
  played with `Audio.play!`). The docs' prose and code listings are inside `<NoHydration>`, so the
  browser downloads no code for them.
- **Building.** `site/build.mjs` builds it: `.rocx` to `.roc`, and `site/Generated/Sources.roc`, the
  sources the pages show (both by `rocx site prepare`); the browser's wasm (`app.wasm`, from the copy
  in `site/build/client`); the server, native; then it measures the wasm. `just site` then starts
  the server and writes every page it answers into `site/dist`, with what the demos ask for besides
  pages (the shout's words, `/openapi.json`, `/openapi.html`) as files: a copy of the site that is
  only files and still works. Most demos need no server, because the server rendered their answers
  as the site was built. A demo that sends or follows something (the planner's moves, the lobby's
  channel) says that no server answers.
- **Under a path.** `node site/build.mjs --base=/rocx/` builds it for a host that serves it under a
  path, as a GitHub project site would: every URL in a page begins with it.
- **Publishing.** `just deploy-pages` publishes `just site`'s output to https://roc-solid.github.io/
  as the one commit of the `main` branch of Roc-Solid/roc-solid.github.io, force-pushed: `site/dist`
  alone, no source. It refuses a dev build, and any file that holds a private path.
- **Developing.** `just dev` (`rocx site dev`) builds with Roc's dev backend on each save and
  restarts the server, and open pages reload. An edit to rocx itself builds rocx again, and the loop
  goes on in the new one.

## Tests

```sh
just test
```

- `test/transpile.test.mjs` covers the syntax, `test/routes.test.mjs` routing, and
  `test/e2e.test.mjs` builds an app with routes and checks where a type error is reported. Other
  files in `test/` cover `rocx check`, `rocx check --sql`, `rocx dev`, stories, styles, formatting
  and content.
- `roc test` runs every Roc module's `expect`s: rocx's own (`rocx-cli/main.roc`), the site's
  (`site/main.roc` imports the platform's modules, the pages and their components, the demos' rules,
  the highlighter) and each package's (`packages/<name>/main.roc`).
- `web/test/platform.test.mjs` builds components on the browser platform, renders them as the server
  would in Node, then hydrates and uses them in Chromium: signals, `if`, `match` and `.map` in holes,
  boundaries, contexts, documents, memory. `web/test/navigation.test.mjs` covers navigation in place.
- `site/test/site.test.mjs` builds the docs site, starts its server, hydrates every page strictly and
  uses every demo in Chromium (the game with real keys). It compares every page the server renders
  with the browser's own render, byte for byte outside its `<NoHydration>`s, both natively and as the
  files GitHub Pages serves.
- `server/test/server.test.mjs` calls a small app on the server platform over HTTP: crashes and
  memory, streams, pages of components and, with `DATABASE_URL` set (`just db`), Postgres,
  transactions, migrations, jobs, cron, email over SMTP, live rooms, actors across a restart, and a
  graceful stop. `server/test/sqlite.test.mjs` does the same database, jobs and cron tests on SQLite
  and on Turso, which need no database server.
- `packages/testing/test/` tests that package's helpers against an app it builds; posthog, and the
  guard, push, auth, stripe and ai packages' examples, have tests of their own (stripe's against a
  stand-in for Stripe's API, ai's against one for Anthropic's Messages API).

The browser tests drive Chromium's headless shell over the DevTools protocol, with no npm
dependencies: `$CHROME`, or Playwright's cached one; without one they are skipped, and the run
says so once. In CI (`CI` set), or with `ROCX_BROWSERS=required`, a missing browser fails the tests
instead (`ROCX_BROWSERS=optional` lets them skip), so a browser install that broke can't leave CI
green. The tests of
`packages/testing` and of the board example drive Gecko too when there is one (headless over WebDriver
BiDi: `$GECKO`, Zen, Firefox, or Playwright's Firefox), which the same rule requires in CI.

**CI** (`.github/workflows/ci.yml`) runs five jobs side by side on every push to master and every
pull request, on GitHub's Linux runners on arm64, with the fork's compiler prebuilt for them:
`just check`; `just site`; `just test-rocx` and `just test-web` (with Chromium and Firefox);
`just test-server` (with a Postgres); and `just examples`. After `just check`, it times
checking (`just check-times`: each example's and the site's `rocx build` and `rocx check`, with no
cache) into the job's summary, against the last green master run, and warns when a check got slower
by half. A change to `roc_fork_commit` in the Justfile needs its compilers published first, on the machine
with the fork: `just setup` (the Mac's), `just roc-fork-linux` (Linux's, cross-built by Zig),
`just publish-roc-fork`, then the SHA-256s it prints in `roc_fork_sha256_<platform>`.
