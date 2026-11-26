# TODO

What still needs work, and where its details are, so nothing is lost between sessions. This file
only points; the details stay where they live:

- decisions, built or proposed, are in `DECISIONS.md`;
- each package's ideas and questions are in its `PROPOSALS.md`;
- each platform's known limits are in the "Not yet" sections of `web/README.md` and
  `server/README.md`.

When an item lands, delete its line here in the same commit.

## Waiting on a decision by the user

- **packages/ai (D-085): its fallback request, against the API.** On the models that take it
  (Opus 5.5 and the others in D-085) every request carries `"fallbacks": "default"` and
  `anthropic-beta: server-side-fallback-2026-07-01`; the stand-in checks that it is sent, but the API
  has never seen it, as development used `claude-haiku-5-5` (which has none). One call with
  `ANTHROPIC_MODEL=claude-opus-5-5` checks it, on the user's go. Then the package's next users:
  examples/notes' assistant on its MCP tools (`Ai.run!` over `Agents.server.tools`, one tool for both),
  and Plate's meal from words (`Ai.extract!`).
- **iOS and Android apps (D-063, Proposed).** Background work; the web stays primary. The Android
  spike is in master, as an experiment: one screen as native views, typed calls to the server, and
  a dev mode (`rocx dev --android [--lan]`, about a second from a save to the phone, each reload a
  fresh start) (`spike/native-apps/README.md`). Next (§13): phase 0's conformance suite (the engine
  on `web/test/app` against Chromium), freeing what a waiting run leaves behind, Taffy, CSS at build
  time, HTTPS and cookies, navigation, `rocx build --android`; then Plate on Android, then iOS (a
  fork target for Xcode's link). The fork's dev backend puts some `arm64mac` string literals where
  Roc's refcounting misreads them (README.md's gaps, 12). Open questions: 3 and 9 in DESIGN.md §15.
  Since examples/pomodoro (2026-11-24) the phone draws SVG, takes percentage sizes and `:where()`
  selectors, and has native halves for `audio.play` and `vibrate.pattern`. Its next gap, left for
  later by the user: **an alert while the app is in the background** (a session that ends with
  the screen off says nothing until the app is opened again): a time the system keeps
  (AlarmManager, or a notification scheduled for the deadline), a native half the page asks for
  when the timer starts and cancels when it stops.
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
- **Uploads straight to storage.** A file dropped or chosen (D-055) is kept through the app's
  server, as a field of an action's multipart form (D-054). A browser `PUT` to a signed URL
  (`Storage.signed_url!`, D-047's plugin route) would spare the server a large file's bytes, but it
  is a second way to keep a file, and needs packages/storage to have a browser half (a plugin
  script) and a way to tell the app the file landed. Left out of D-055 for one way per job; worth it
  once an app keeps files too big for a request's body.
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
- **VAPID keys without Node** (found landing D-080, 2026-11-25): packages/push's setup makes its
  key pair with `node packages/push/vapid-keys.mjs`, which a release leaves out (`release/pack.sh`
  drops every `*.mjs`), so an installed rocx has only `npx web-push generate-vapid-keys`. Ship the
  script, or add `P256.generate!` (one hosted function) and have the push plugin print a fresh pair
  when the keys are missing under `--dev`?

## Framework work, decided but not built

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
  (a decision, D-068 or the next free number).
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
  - D-057's job interrupt has x86_64 paths (macOS and Linux) written but never built or run here;
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

## The Roc compiler (the fork in `~/roc-fork`)

- **Reduced repros in `test/compiler-bugs/`** (`just compiler-bugs` runs them, on the nightly and
  on the fork). At the pin 4674b5973d all pass but these:
  - `two-formats-one-where`: a where clause asking for one method at two types (`Json` and D-038's
    `FormBody`) is a type error that `roc check` reports, but the dev backend and `roc test` crash
    in `boxy_lowering` instead of reporting it; rocx's form reader is made where the arg's type is
    known (`Endpoint.local`). The user reports it upstream.
  - `huge-frame-opt-speed`: mostly fixed at 4674b5973d (slots given to builtin calls get lifetime
    markers): specialized, the docs site's largest frame is 264 KiB (12.4 MB before) and its pages
    render; plate 164 KiB (848), journal 64 (372). What's left still grows with a lambda set's
    closures (about 24 bytes each in their dispatcher; the README says where, and that LLVM 23 gives
    the same dispatcher 608 bytes). Every app's optimized server is still built `--specialize=no`
    (D-064, `ROCX_SPECIALIZE=yes` opts back in): whether specialization becomes the default again
    is D-064's to decide, with those numbers.
- **Not reduced yet:** a rigid `..others` beside an app's own error tag in one body doesn't
  type-check (examples/uptime names `JobErr` instead).
- **Fixes prepared on the fork wait for the user to open them as PRs** (boxy, `List.map` reuse,
  and the slot lifetimes of branch `rocx-fixes-2`, 0eb36c9c3b and 4674b5973d; its Try commits are
  upstream's). Nothing is pushed from here. Its compiler is, as a binary (D-069): a release of this
  repository per pin, for CI and `just setup` without the fork, so a pin bump runs `just
  publish-roc-fork` and puts the SHA-256 it prints in the Justfile before it lands.

## Tooling and distribution

- **`rocx dev` doesn't read `.env`.** A key kept beside the checkout (`ANTHROPIC_API_KEY`,
  `STRIPE_SECRET_KEY`) reaches the server only when the shell exports it. Rails and Next read `.env`
  in development; `rocx dev` could too (and never a release's server). `.env` is gitignored since
  D-085.
- **The first release (D-078), waiting on the user:** a `LICENSE` at the repository's root (its
  text is the user's call: the repository states none, and `just release-pack` refuses a real
  release without the file); the x86_64 Linux fork compiler published and pinned (`just roc-fork-linux
  x86_64`, then `just publish-roc-fork`, from the Mac with the fork); then a `v<date>` tag, which
  runs `.github/workflows/release.yml` (hosts, packs, smoke on macOS and Alpine arm64/x86_64,
  publish). Once it is out: drop "the first release isn't out yet" from README.md's Getting
  started and the front page, and redeploy the docs site.
- **The examples' READMEs build with `node server/build.mjs`**: `rocx build <dir> --release <out>`
  does it now (D-078).
- **rocx on Linux** (D-062, D-069, D-078): on arm64 it runs (CI's), its watching polls (inotify is
  the next step). x86_64: the release builds its host and rocx (cross-built by Zig on the Mac); its
  fork compiler is built (`just roc-fork-linux x86_64`) but not yet published (above).
- **What is still Node** (D-062): the tests, `just site`'s full build (it measures the wasm with
  `web/runtime.js`; its static copy is `rocx build --static` since D-073), and the measuring
  scripts. All of `just site` in Roc would need a way to run the wasm, or to drop the measured
  rendering times.
- **js-framework-benchmark: what is still slower** (D-074; `just js-bench`, `benchmarks/jsframework/`).
  The five steps of 2026-11-25/26 are in: `create_selector!` (D-083), the host's allocation notes
  without a hash map, `.map` rows as templates (D-084), fewer calls per row (known rows
  make no box, the wasm's imports called directly), and the runtime shaken to
  what an app uses (D-087, with D-086's links). By hand (click to layout, median of
  15) creating 1,000 rows went from about 36 ms to 23, against vanillajs's 16 and Solid's 15; the
  benchmark page's runtime from 175 KB raw (37.5 with brotli) to 124 (27.5).
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
  - site/routes/members/join: the form doesn't use `use_submission!`, so a refusal (a blank name)
    shows nothing.
  - `--opt=speed`: is the three-step `Middleware.then` miscompile
    (`test/compiler-bugs/middleware-skipped-opt-speed`) still there? journal's and plate's chains
    have three steps.
- **Stale proposals:** `packages/testing/PROPOSALS.md` (`src/routes.mjs`, `outbox.rs`, `<For>`; item
  11 is done), `packages/mcp/PROPOSALS.md` #1, `packages/otel/PROPOSALS.md`,
  `packages/forms/PROPOSALS.md` ("Nothing here is built").
- **sqlite-vs-turso's sale workloads aren't measured yet:** `sale`, `sale-job`, `concurrent-sale`
  and `concurrent-sale-job` (a sale in one transaction, with its receipt job and without) aren't in
  `site/sqlite-vs-turso.json`, so the docs page doesn't show them. `just db-bench`, when the user
  says, on a quiet machine.


- **Old branches kept on purpose until about 2026-11-28:** `native-server`, `solid-signals` and
  `refs/scrub-backup/native-server`. Delete them then, with the user's OK.
