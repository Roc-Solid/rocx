# TODO

What still needs work, and where its details are, so nothing is lost between sessions. This file
only points; the details stay where they live:

- decisions, built or proposed, are in `DECISIONS.md`;
- each package's ideas and questions are in its `PROPOSALS.md`;
- each platform's known limits are in the "Not yet" sections of `web/README.md` and
  `server/README.md`.

When an item lands, delete its line here in the same commit.

## Waiting on a decision by the user

- **One Rust engine for every target** (`spike/one-engine/REPORT.md`, 2026-11-26): the phone's engine
  for the server (signals.rs replaced) and then the browser (runtime.js retired, hydration by the
  engine, JavaScript kept to the DOM, hydrating and browser APIs). Feasible; in five phases, the first
  (one core for the server and the phone) changing nothing in the browser. Its open questions wait
  on the user.
- **The page's wasm and runtime aren't cached** (found in that investigation): only files named by
  their content are served `immutable` (the stylesheet), and `app.wasm`, `runtime.js` and
  `start.js` have fixed names and no `ETag` or `Last-Modified`, so every visit downloads them again.
  Named by their content as the stylesheet is, they would be kept for a year.

- **Packages apps reach for, discussed 2026-11-27** (no UI components for now, the user's call):
  - **packages/teams:** teams, memberships with roles, invitations (auth's `then` already has room
    for an invite's page), team-owned API keys. Open: the team from the URL or the session; fixed
    roles or the app's own; a personal team each; whether stripe's customer can be a team's.
  - **packages/search:** SQLite's FTS5 and Postgres's full-text search behind one index (weights,
    ranking, snippets, escaped queries, prefix matching), kept by triggers. Open: refusing Turso
    (no FTS5) or a `LIKE` fallback; the plugin making the index's tables or the app's migration;
    stemming off by default.
  - **packages/posthog, analytics:** `PostHog.event!` beside errors, page views from the page
    script (on load and on each `rocx:navigated`; not from middleware, which prefetches would
    count), anonymous ids joined to the user at sign-in. Open: cookieless by default or a cookie;
    our small script or posthog-js.
- **packages/ai's next users (D-085).** examples/notes' assistant on its MCP tools (`Ai.run!` over
  `Agents.server.tools`, one tool for both), and Plate's meal from words (`Ai.extract!`).
- **iOS and Android apps (D-063, Proposed).** Background work; the web stays primary. On Android
  a large app's pages run as native views (`spike/native-apps/README.md`): CSS laid out by Taffy
  with text measured by the platform (D-137), navigation, guards, redirects, sessions in a cookie
  jar and form posts as the browser's (D-138), images, video, form controls, file uploads and an
  app's own Kotlin halves of its custom elements (D-139), live updates and channels (D-140), page
  halves for its page scripts and touches on what is drawn (D-141, also in the dev client); a dev
  mode (`rocx dev --android [--lan]`). Next: phase 0's conformance suite (the engine on
  `web/test/app` against Chromium), CSS at build time (it's parsed on the phone: about 15 ms for
  1,500 rules on the emulator), HTTPS (plain http only) and gzip, `rocx build --android` (signing,
  other ABIs, an icon), an app link for providers' sign-in to come back, `popover` with light
  dismiss, inline boxes in a line of text (an approximation now), `@font-face`, dark mode,
  `@keyframes`, Roc's `transition:` directives and `on:frame`, a hardware keyboard's keys outside
  fields; then iOS (a fork target for Xcode's link). The fork's dev backend puts some
  `arm64mac` string literals where Roc's refcounting misreads them (README.md's gaps). Open
  questions: 3 and 9 in DESIGN.md §15. examples/pomodoro's next gap, left for later by the user:
  **an alert while the app is in the background** (a session that ends with the screen off says
  nothing until the app is opened again): a time the system keeps (AlarmManager, or a
  notification scheduled for the deadline), a native half the page asks for when the timer starts
  and cancels when it stops.
- **packages/markdown:** open questions 1, 2, 4 and 5 in its `PROPOSALS.md`:
  - trusted HTML;
  - `<Markdown>` server-only by default;
  - heading ids;
  - whether the CommonMark/GFM spec examples (CC BY-SA 4.0) stay in a public repo.
- **packages/guard:** a question in its `PROPOSALS.md`: the rate-limit headers.
- **packages/auth:** two-factor sign-in's next steps (D-081), in its `PROPOSALS.md` §5: a user's
  wrong codes counted across sign-ins (today five a sign-in, and a provider's sign-in can start
  again uncounted), trusting a browser for a while, a session that says it passed a code. Passwords
  (§1) and passkeys (§2) wait there too.
- **packages/presence:** the questions at the end of its `PROPOSALS.md` (a room by the page's path,
  the timeout).
- **packages/charts:** a line chart's ticks along the bottom fall on round numbers of its `x` (days
  since 1970 in steps of 1, 2, 5, 10 or 20; hours in fives), not each Monday or the first of a
  month. Ticks that know days, hours and months wait for an app that needs them.
- **Uploads straight to storage.** A file dropped or chosen (D-055) is kept through the app's
  server, as a field of an action's multipart form (D-054). A browser `PUT` to a signed URL
  (`Storage.signed_url!`, D-047; the app's `/_storage` route, D-116) would spare the server a large
  file's bytes, but it is a second way to keep a file, and needs packages/storage to have a browser
  half (a plugin script) and a way to tell the app the file landed. Left out of D-055 for one way
  per job; worth it once an app keeps files too big for a request's body.
- **packages/jobs:** a job's log in the jobs page, parked with its options in its `PROPOSALS.md`.
- **packages/stripe (D-082):** the questions at the end of its `PROPOSALS.md` (whether `past_due`
  counts as paying; `rocx new` offering it), and one run of its example against Stripe's own test
  mode (test keys, `stripe listen`, the prices its README names): its tests met only a stand-in
  written from Stripe's reference, so an object Stripe writes otherwise would show there first. Its
  proposals (fulfilling from the page Checkout goes back to, Stripe Tax, metered billing, plan
  changes from the app, Connect, embedded Checkout) wait for an app that needs them.
- **The other packages' `PROPOSALS.md`** (admin, forms, intl, mcp, otel, push, testing) have more
  ideas and questions waiting.
- **The examples' and tests' wasm, specialized?** It is built `--opt=size` alone (packages/testing's
  `buildForTests`, `just example-apps`, test/e2e, web/test, README's build line), which is boxy by
  the compiler's default, while the site's is `--specialize=yes` (D-064). Specialized, journal's is
  24% smaller with brotli (144.0 to 109.4 KB) and board's 8%, and both render faster; their builds
  take twice as long (board 5 to 11 s). Switching means measuring `just example-apps` again.
- **echo's benchmark again:** the examples page's numbers (8f7abc5) are of its server built
  specialized; since D-064 it ships boxy, so `just example-apps --bench` (a run on the user's go, on
  a quiet machine) would measure what ships.

- **Who signs in when `Auth.user_for!` can't make a row (D-134):** a returning user known by an
  app's own id from before, with no address or one another user has, gets no row, so
  `Auth.user!` answers `NotFound` and the example's middleware signs them out right after they sign
  in (packages/auth's README says so). Sign them in anyway, or refuse at sign-in?
- **A form with `use_action!` alone (D-118):** the decision counts such a form as read, but
  web/runtime.js registers an endpoint only through `use_submission!`/`use_submissions!`, so the
  form goes as a plain form. The docs describe the code; change the code or the decision's wording?
- **packages/testing's JS half in a release:** `release/pack.sh` ships no `.mjs`, so an installed
  Roc Solid has no `buildForTests`/`startServer` (open question 3 in its PROPOSALS.md).
- **Two small example choices:** examples/journal could use the platform's `PUBLIC_URL`
  (`Env.public_url!`) in place of its own `ORIGIN`; examples/quiz's reveal could colour each bar as
  its choice (`color`, D-130).

## Framework work, decided but not built

- **packages/video's next steps (D-126):** a player that rests on its poster under
  `prefers-reduced-motion` (one host function reading the runtime's `reducedMotion()`; a gap for
  any app today); one that starts as it scrolls into view (an event for an element coming into view); real input
  scripted at frames (a demo's clicks dispatched, replayed when scrubbed back); `rocx render`
  feeding ffmpeg as it films, not after (D-128: the CLI platform can't write to a child's stdin
  yet); an audio track mixed in by ffmpeg; rendering on the server
  with an app's data (a plugin with Chromium and ffmpeg beside it: a video per post), which the user
  hasn't decided on.
- **enhanced:src's next steps (D-125):** colours (a photo with an ICC profile, a phone's Display P3,
  is copied as if sRGB: convert it, qcms or lcms2, or keep the profile in the WebP); AVIF beside WebP
  (a `<picture>`, slow to encode); photos of listed other hosts (Open Food Facts' in Plate); a
  `rocx build` that makes the copies of the paths it can see ahead of a deploy; packages/markdown's
  `<Markdown>` writing its images with it (the journal's own renderer does), and presence's
  avatars; a photo in the journal (its pictures are SVGs, which have no copies); uploads resized as
  they come (a `Storage.put!` of a photo, by the same code); a route that refuses a signed-out GET
  (a private photo) is asked again every 5 minutes a page shows it: remembered longer.

- **Found by the docs audit of 2026-11-26, to check:**
  - The tools page's "the same tools, twice" example types an AI tool list `Tool({})`, but McpHttp
    serves only an `Mcp.Server(McpHttp.Caller(c))`: such a list may not be servable over MCP without
    HTTP code of the app's own (packages/ai's example's notes claim the same). Tools generic in their
    context, or an adapter that changes a tool's context, would make the claim true.
  - A checked body sent as JSON (D-093) may not read back through a `Form.choice` field whose
    option's text differs from its tag (`"lunch"` read as `Lunch`): worth a test in examples/plate.

- **A `+middleware.roc` that guards nothing (D-103):** one in a directory with no route file below
  it (a group emptied by a move) is written as a module nothing imports; `rocx build` could say so.
- **The engine in the browser (spike/wasm-engine/REPORT.md, "Round 2").** native/core's engine is
  within 0 to 5% of today's runtime on the benchmark's page (clear about 1.6x), but its wasm is
  119 KB with brotli at opt-level s (markup read without serde_json since round 3) against today's
  67 KB for wasm and runtime.js together. Neither wasm-opt (0.4% at best, measured) nor dropping
  `format!` (kept: std's panics hold most of core::fmt anyway) would; what is left is the engine's
  own code (41% of it) and opt-level z (about 13% smaller, 5 to 10% slower). Its nodes are freed only
  when a list's row goes (a hole's replaced markup stays), and it lacks what the browser needs of
  runtime.js (hydration, navigation, drags, transitions, actions, channels, head tags, SVG).
- **More of the web platform's hosts shared (after D-091's rocx-memory).** The browser's host and
  the phone's share Roc's memory now; the hosted functions themselves would be next if the
  reactive graph moves into the wasm (`spike/wasm-engine/REPORT.md`): then web/host's would be the
  engine's.
- **D-079's names on the phone.** native/core's engine builds what hand-built markup names as it is.
  It runs no script and hides `<script>`, so nothing runs from a name there, but for parity with the
  web it could leave out the same names (and say so on its log).

- **D-070's leftovers.** `{=x}` is the same hole as `{x}`, kept for old files: `rocx fmt` could drop
  the `=` and rocx then refuse it. `{...x}` is still a list's own hole: a `List` encodes through a
  container protocol (`encode_list`) that a hole's format could join, which would make it `{x}` too.
  An attribute (`value={count}`) still takes a `Str`. A hole's error for a value it can't show names
  `encode`; `rocx check` could add a hint there, as it does for `{...record}`. A match arm's name
  getter ends in `_ => Html.unmatched!(…)`, which a one-variant type would call redundant.
- **The private app on D-070.** The app in its own repository under examples/ writes four `<Show>`s,
  which rocx refuses now: each an `if` (a function child, a `match`). Its `{=x}` holes still work.
- **Wasm splitting: parked until after Roc 0.1** (the user, 2026-11-24). A page downloads only its
  own code: route levels as entries, chunks by the set of pages that reach them, at most four files a
  page, the browser's build boxy. Re-measured on a1cd824 (`spike/wasm-split/REPORT.md`, the
  2026-11-24 section): the median page's first load 174 KB brotli against 310 today, but data stays
  in main (72 KB) until the fork keeps relocations through the final link. To pick up: the fork's
  `--keep-temp` fix and kept relocations, then rocx's build step, manifest, loader and render check
  (a decision, D-068 or the next free number). Its parked copy (`spike/wasm-split/parked`) builds
  the browser's host from Zig, which D-090 made Rust.
- **packages/presence's stores could compose (D-094).** Each store writes its signal from a read
  (`set_typing!(typing!().started(…))`), so its README says to call a store once per handler: two
  calls in one lose the first. Written with `Solid.update!` they compose, and that rule goes.
- **The rest of Solid 2.0 and Solid Router's actions:** see `web/README.md`, "Not yet".
- **D-052's dev warning has blind spots:** a reactive read inside a helper call that takes
  arguments, and one at the top of a `.map`'s row or a function child, aren't marked, so they don't
  warn. The proposal: wrap any `!` call with arguments too, closing the extra `)` through the
  transpiler's open-bracket stack, and mark function children's top level as view bodies are.
- **An effect's `error` handler can't pass the error on** to the nearest `<Errored>` (D-052's
  `create_effect_with!`). Leaving `error` out keeps the boundary; a rethrow would let a handler
  log and still show the boundary.
- **The server's other limits** are in `server/README.md`, "Not yet":
  - actors' timers are all set again at start, a task each in memory;
  - x64 hosts, D-057's x86_64 interrupt paths among them, are built for a release but have never run here;
  - D-057's interrupt tells Roc's code by a flag every function Roc calls clears: Roc's code in a
    section of its own from the fork's LLVM backend, with start and end symbols the host reads, would
    tell it by address, the cleaner answer, but a compiler change and a PR the user opens.
- **`rocx check --sql`'s blind spots** (D-058, built; `spike/db-checked/DESIGN.md`, §12, phase 5;
  `server/README.md`, "Not yet"):
  - a column of an outer join's other side read as nullable, from the statement's plan (SQLite's
    `EXPLAIN`, Postgres's `EXPLAIN (VERBOSE)`), as sqlx does;
  - SQLite's expressions typed (Turso's `get_column_inferred_type`), where SQLite gives none;
  - interpolated SQL checked when each piece is a string constant of its module;
  - a description cache (sqlx's `.sqlx/`), for a Postgres app's CI without a database;
  - Postgres parameter types; packages' SQL checked per backend (packages/jobs, packages/push,
    packages/admin: their SQL is in no app's sources); the checks in the app's own compile; a check
    at run time (blocked by `test/compiler-bugs/two-formats-one-where`).

- **Apps still keeping their own users (D-134):** `rocx new`'s template (templates/app: its users
  table and `made!`), examples/notes (`Store.person_for!`) and packages/stripe's example
  (`Accounts.made!`) onto `Auth.user_for!`; drop `crypto` from packages/auth/example's header if it
  builds without it.
- **LiveForm after a successful send (probable bug, D-122):** `Runtime.emptied` resets a form's
  inputs to the page's first values, but `LiveForm` keeps its typed values until `reset!`, so the
  inputs and `live.value!`/`fields!` disagree on a form that stays on its page with neither
  `reset!` nor `data-rocx-keep` (examples/plate's goals page, `recipes/[id]`, the trends weigh
  form). Check in a browser; fix by LiveForm resetting itself on success, or `data-rocx-keep` there.
- **Signals don't compare:** a memo computed again to the same value tells no one (D-109), but a
  signal's setter runs its readers whatever it is given (Solid's `createSignal` compares by
  default); examples/checkboxes writes only on a change by hand.
- **`Kv.swap!` can starve a writer under contention:** examples/checkboxes waits 1 ms after three
  lost tries and gives up after a thousand (`Store.written!`).
- **packages/headless `Tab.press!("a")`** sends `code: "a"` (not `KeyA`) and no text, so a letter
  types nothing (Tab.roc's `key_of`); documented, not fixed.

## The Roc compiler (the fork in `~/roc-fork`)

- **The pin is `rocx-fixes-5`** (2dd60e319d, D-115): upstream's main at bec95b9f4a, not a nightly
  (the fixes go upstream as PRs against main), with the fork's fixes, each a two-commit branch (a
  failing test, then the fix) with a repro and a plain-words README in `test/compiler-bugs/` (the
  index is its README.md). Basing on main brought upstream PR #13549's polymorphic constants, and
  six regressions of it that rocx's tests met (servers built `--opt=dev`, the push example, the
  testing app, `--specialize=yes`); each is fixed in the fork, repro and README beside the others.
  Upstream's main still has fifteen of the nineteen bugs the folder keeps. `nested-site-evidence-scope`
  matters most: before it, a component call that leaves out a closure-defaulted prop, inside a local
  function that captures something and is generalized, crashed a `--specialize=yes` build or **built
  a wrong program without a word**, and the browser's wasm is built `--specialize=yes` (D-064).
  `Static.browser_build!`'s fallback to a boxy wasm can be reconsidered
  (`lambda-solve-specialize-wasm`, fixed upstream, was what it caught).
- **Still open in the compiler:**
  - A literal in a recursive group's constant at a type only a function member's type mentions
    (`holder = { run: |input| again(input, 0) }` with `again` doing `extra + extra`): "dispatch on a
    value that can never exist" at run time, on the nightly too (`recursive-constant-literal`'s
    README).
  - With `--specialize=yes`, a debug compiler stops in Monotype on a constant read in a function an
    app value holds when the platform passes the app's model unboxed (`weak-value-constant-instance`'s
    README); rocx's platforms box it.
  - `huge-frame-opt-speed`, what is left: a list literal's elements all hold a slot until the list
    is made (the site's 400 KB is a list of 161 `Html` values of 2,304 bytes each). Options in its
    README: build the elements in place, box large closure captures, or capture less.
  - Re-raising a rigid row's error by hand (`match … { Err(e) => Err(e) }`) is still refused
    (`rigid-others-row`'s README); `?` works.
- **`rocx check` checks the dev build**, whose `Html.read_at!` reads kept
  `effectful-closure-dec-default` from showing; a failure only the release program meets shows in
  `rocx build` alone. rocx could also check the release build's program.
- **Fixes prepared on the fork wait for the user to open them as PRs**: each two-commit branch of
  `rocx-fixes-4` (above), and `rocx-fixes-3`'s nested codec derivation (dc48e823c8) and `List.map`
  output item (159add67a5); the Try codecs, `List.map`'s in-place extraction, the inlined call's
  clone and the binding group's claim are upstream's now. Nothing is pushed from here. Its compiler is, as a binary (D-069): a release of this
  repository per pin, for CI and `just setup` without the fork, so a pin bump runs `just
  publish-roc-fork` and puts the SHA-256 it prints in the Justfile before it lands.

## Tooling and distribution

- **A lint for a page and an endpoint at one path (D-100)**, configurable: `rocx lint` warns of a
  folder with both `+page.rocx` and `+server.roc`, pointing at `routes/api/<the page's path>/`,
  off or an error as an app's settings say. D-100 is docs only for now.
- **The first release (D-078), waiting on the user:** (the `LICENSE` is MIT, 2026-11-27; every
  platform's fork compiler, x86_64 Linux too, published and pinned with D-115) a `v<date>` tag, which
  runs `.github/workflows/release.yml` (hosts, packs, smoke on macOS and Alpine arm64/x86_64,
  publish). Once it is out: drop "the first release isn't out yet" from README.md's Getting
  started and the front page, and redeploy the docs site.
- **Link-time optimization of the server's host (D-104)**, measured: `lto = "fat"`, one codegen unit:
  12 MB less on disk and 2.6 MB less to send on the full host, for minutes more per host build.
- **The examples' READMEs build with `node server/build.mjs`**: `rocx build <dir> --release <out>`
  does it now (D-078).
- **rocx on Linux** (D-062, D-069, D-078): on arm64 it runs (CI's), its watching polls (inotify is
  the next step). x86_64: the release builds its host and rocx (cross-built by Zig on the Mac), and its
  fork compiler is published (D-115); neither has run on x86_64 here.
- **What is still Node** (D-062): the tests, `just site`'s full build (it measures the wasm with
  `web/runtime.js`; its static copy is `rocx build --static` since D-073), and the measuring
  scripts. All of `just site` in Roc would need a way to run the wasm, or to drop the measured
  rendering times. The video renderer is Roc since D-128 (`rocx render`, packages/headless);
  `site/example-shots.mjs` (screenshots of the examples) could move onto packages/headless next, and
  packages/testing's browser after it (packages/headless/PROPOSALS.md: Gecko over BiDi, drags and
  touch, `Dom` queries in a tab, an app's tests in Roc).
- **js-framework-benchmark: what is still slower** (D-074; `just js-bench`, `benchmarks/jsframework/`).
  The five steps of 2026-11-25/26 are in: `create_selector!` (D-083), the host's allocation notes
  without a hash map, `.map` rows as templates (D-084), fewer calls per row (known rows
  make no box, the wasm's imports called directly), and the runtime shaken to
  what an app uses (D-087, with D-086's links). Then the browser's host in Rust (D-090, D-091), a
  list whose rows all go emptied at once, and a computation keeping less (its sources a short array,
  a run's lists and a finished run's record shared while empty). The runner's run of 2026-11-26 at
  505b0e7 (2 rounds of 15, mains): CPU 1.68× the fastest (1.83× at b84a0b8, 2.06× before; React
  1.70×), creating 1,000 rows 36.1 ms (39.3; vanillajs 18.5), 10,000 381 (448), selecting one 6.2
  (7.7), clearing 15.0 (19.8: the old regression gone), the download 67.7 KB (66.2), first paint
  30 ms (the best), run memory 4.5 MB (4.8), ready to use 262 ms (288; still the last, Leptos 230).
  A row's holes run in one call, and rows without their comments, were measured and not taken
  (about 4% and 3%, for their cost).
  What is left, measured: each hole is a computation of its own, run by a call into wasm (about 4
  calls a row, each with the runtime's bookkeeping: a computation, its sources' Sets, its frame);
  a row is still a range between two comments; a list read again runs Roc over every item (its key
  inspected, `row_last!` and `row_set!` with the key as text). Running a row's holes' first runs in
  the row's own call (as Joy runs one call an update) would take most of the per-hole cost, but a
  hole that waits would then make its row wait: not done. A binary command buffer in place of JSON
  was not built: templates already send only a row's parts, and the JSON parse is a small cost now.
  The wasm (133 KB raw, 40 with brotli) is the bigger half of what a page downloads.
  The entries go upstream once the repository is public and its compiler can be downloaded.
- **Errors in an editor, beyond a build's** (the user, 2026-11-24: `rocx check` is enough for now;
  the VS Code extension shows a `rocx dev` task's on each build, and a `rocx check` task's): `rocx
  lsp`, running `rocx check <dir>` on save, for every editor with a language-server client; then hover and completion by
  `roc experimental-lsp` on the transpiled buffer (lines map already, columns need a map from the
  transpiler). Orca has no language-server client.
- **Zed**: needs a tree-sitter grammar for rocx, over faldor20/tree-sitter-roc (Zed's Roc
  extension's). That grammar parsed 524 of this repository's 563 .roc files cleanly (2026-11-24);
  what it doesn't know yet: `where [a.Json.Encodable(e)]`, where aliases (`a.Readable : where
  […]`), `??` defaults in a record type, `"\$"`, negative numbers in a tuple, `{ run! } = …`.
- **The VS Code extension on the Marketplace**: needs a Marketplace account (the user's call); until
  then `just vscode-extension` installs it from a clone.
- **The live docs site** (roc-solid.github.io) was last deployed on 2026-11-21. Everything since,
  the examples pages and D-036 to D-049 among it, isn't live. `just deploy-pages` waits for the
  user's go.

## Tests

- **The site's dev-rebuild timing test flakes under load** (`site/test`, "rebuilds fast"): it
  fails on most full runs while other builds run (2,015–3,600 ms against a limit of 2 s, scaled
  ×1.5 by the load average) and passes alone (about 740 ms). The load average lags a burst of
  builds. A sturdier check: the median of three rebuilds, or a ratio to a no-op rebuild measured in
  the same run. CI's slower runners multiply its limit by `ROCX_TIME_SCALE` (3, D-069).
- **The channels "a tab has one stream" test flakes under load** (`server/test/server.test.mjs`):
  it waits for the old stream's `channel closed` log event, then reads the log at once, and the
  new stream's `channel opened` (the async writer's) can be later: `['channel opened', 'channel
  closed']` against three (seen once in a full run with Postgres on 2026-11-24; passes alone). Wait
  for the second `channel opened` too.
- **The multipart test's upload over the body's limit flakes** (`server/test/server.test.mjs`,
  "endpoints: a form with files"): the server answers 413 and closes while fetch is still writing
  the 17 MiB, and fetch fails with `EPIPE` instead of reading the 413 (1 run in 3 alone, on
  2026-11-27). The server could read (and drop) the rest of a body it refuses, up to a bound, before
  it closes; or the test could send its body in one write it can't lose, or accept either.
- **"calls taking turns on two Roc threads" flakes under load** (`server/test/server.test.mjs`):
  a fetch fails with `connect ECONNRESET` (1 run in 5 alone, on master as on a branch, with the
  load average about 20, on 2026-11-27): a burst of connections over the listen backlog, likely.
  Retry a connect that was reset, or open the connections in smaller bursts.
- **The channels "an open stream holds no thread" test hangs under load**
  (`server/test/server.test.mjs`, 40 streams on `--roc-threads 2`): twice on 2026-11-25 it never
  finished (12 minutes, the server idle), once in a full run just after `just check` (load 11 to
  14), once alone beside the site's tests (load about 4); alone on a quiet machine it passes in 1.5
  to 2.7 s, on master and on the perf branch. node's test runner has no timeout here, so the run
  waits for good. Find which `await` it waits at (a stream's `next()` that never comes, or a request
  a busy Roc thread never answers), and give the test a timeout so a hang fails it.
- **`test/check-sql.test.mjs`'s Postgres test writes in the server test app's counts**
  ("42 statements checked on Postgres (the rows of 21 against their records): 6 problems"): a
  statement added to `server/test/app` fails it until the numbers are changed. Its problems' lines
  are found by the calls' text already; the counts would need the scan's rules (literals, comments,
  `Db.unchecked`) repeated in the test, or rocx's `--verbose` list of what it checked to count.
- **The server platform's host is built without a lock** (`server/build.mjs`'s `buildHost`,
  `rocx-cli/Hosts.roc`'s `server_host!`): cargo, then a copy into `server/platform/targets`. Tests
  in several processes after a change to `server/host` (or in a fresh worktree) can each run cargo
  and copy the library while another's cargo writes it, as the CLI platform's host did before it
  was built holding `bin/.rocx-building`. Not seen failing yet; the same lock (one of its own, in
  `server/platform/targets`) would close it.

## Housekeeping

- **Bugs the docs pass found (2026-11-24):**
  - examples/notes: `DELETE /api/notes/<id>` deletes a note that isn't archived; the archive-first
    rule is only in the page's route (`routes/notes/[id]/+server.roc`), not in `Notebook.delete!`.
    `http.test.mjs` archives first, so it doesn't see it.
  - packages/posthog: `sent!` drops a batch that is `TooLarge` without a log line.
  - packages/storage: directory and memory buckets keep multipart parts under `.uploads/`, and an
    app's key starting with `.uploads` isn't refused.
- **packages/storage's signed links go to one fixed path** (D-116): its route is the app's file,
  `routes/_storage/+server.roc` calling `Storage.signed_route!`, but `Storage.signed_url!` builds
  its links to `/_storage` whatever the app does, so the file can't move. Making it movable needs
  the signer to know the path (an argument of `signed_url!`, or a setting kept at start, as auth
  keeps its `at`). Every other package's handlers go wherever the app puts their files.
- **Database errors sent to clients:** the package examples answer a failed query with its text
  (`Err(Status(503, why))`: packages/auth's, stripe's, push's and guard's examples, and
  sqlite-vs-turso's bench routes), which can name tables, columns and values. examples/tasks, plate
  and uptime log it and answer a plain 500 since the audit of 2026-11-26 (`Store.refusal!`). The
  platform has no refusal for this (a `Failed(why)` that logs `why` with the route and answers a
  plain 500); Endpoint.roc is shared with the browser's platform, which has no log, so it needs a
  decision.
- **Single rows read as lists** (`Db.one!`, D-096): tasks, plate, board and notes use it; uptime,
  pomodoro, quiz, sqlite-vs-turso, packages/auth's and packages/stripe's stores (and their
  examples) and `rocx new`'s template (`Accounts.roc`) still read one row with `Db.all!` and
  `.first()` or `.get(0)`.
- **Stale proposals:** `packages/testing/PROPOSALS.md` (`src/routes.mjs`, `outbox.rs`, `<For>`; item
  11 is done); `packages/forms/PROPOSALS.md` 1 and 5 speak of `bin/rocx.mjs` and a cookie flash.
- **sqlite-vs-turso's sale workloads aren't measured yet:** `sale`, `sale-job`, `concurrent-sale`
  and `concurrent-sale-job` (a sale in one transaction, with its receipt job and without) aren't in
  `site/sqlite-vs-turso.json`, so the docs page doesn't show them. `just db-bench`, when the user
  says, on a quiet machine.


- **Old branches kept on purpose until about 2026-11-28:** `native-server`, `solid-signals` and
  `refs/scrub-backup/native-server`. Delete them then, with the user's OK.
- packages/video's Player.rocx and Sequence.rocx still write the older `{=if …}` hole (D-070);
  packages/presence's `Wire.topic` is unused but for its own expect; packages/mcp's McpHttp calls
  `Endpoint.send!(api(params), arg)` rather than the method form (D-102).
- examples/echo's `bench.sh` (and its README's by-hand steps) start the server from the
  repository's root, so it writes `data/app.db` there (D-105).
