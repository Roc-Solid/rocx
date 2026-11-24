# TODO

What still needs work, and where its details are, so nothing is lost between sessions. This file
only points; the details stay where they live:

- decisions, built or proposed, are in `DECISIONS.md`;
- each package's ideas and questions are in its `PROPOSALS.md`;
- each platform's known limits are in the "Not yet" sections of `web/README.md` and
  `server/README.md`.

When an item lands, delete its line here in the same commit.

## Waiting on a decision by the user

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
- **packages/presence:** the questions at the end of its `PROPOSALS.md` (a room by the page's path,
  the timeout).
- **Uploads straight to storage.** A file dropped or chosen (D-055) is kept through the app's
  server, as a field of an action's multipart form (D-054). A browser `PUT` to a signed URL
  (`Storage.signed_url!`, D-047's plugin route) would spare the server a large file's bytes, but it
  is a second way to keep a file, and needs packages/storage to have a browser half (a plugin
  script) and a way to tell the app the file landed. Left out of D-055 for one way per job; worth it
  once an app keeps files too big for a request's body.
- **packages/jobs:** a job's log in the jobs page, parked with its options in its `PROPOSALS.md`.
- **The other packages' `PROPOSALS.md`** (admin, forms, intl, mcp, otel, push, testing) have more
  ideas and questions waiting.
- **`rocx new`** asks which database (Postgres, SQLite, Turso); the question is open in D-045.
- **The examples' and tests' wasm, specialized?** It is built `--opt=size` alone (packages/testing's
  `buildForTests`, `just example-apps`, test/e2e, web/test, README's build line), which is boxy by
  the compiler's default, while the site's is `--specialize=yes` (D-064). Specialized, journal's is
  24% smaller with brotli (144.0 to 109.4 KB) and board's 8%, and both render faster; their builds
  take twice as long (board 5 to 11 s). Switching means measuring `just example-apps` again.
- **echo's benchmark again:** the examples page's numbers (8f7abc5) are of its server built
  specialized; since D-064 it ships boxy, so `just example-apps --bench` (a run on the user's go, on
  a quiet machine) would measure what ships.

## Framework work, decided but not built

- **Wasm splitting: parked until after Roc 0.1** (the user, 2026-11-24). A page downloads only its
  own code: route levels as entries, chunks by the set of pages that reach them, at most four files a
  page, the browser's build boxy. Re-measured on a1cd824 (`spike/wasm-split/REPORT.md`, the
  2026-11-24 section): the median page's first load 174 KB brotli against 310 today, but data stays
  in main (72 KB) until the fork keeps relocations through the final link. To pick up: the fork's
  `--keep-temp` fix and kept relocations, then rocx's build step, manifest, loader and render check
  (a decision, D-068 or the next free number).
- **The rest of Solid 2.0 and Solid Router's actions:** see `web/README.md`, "Not yet".
- **D-052's dev warning has blind spots:** a reactive read inside a helper call that takes
  arguments, and one at the top of a `<For>` row or a function child, aren't marked, so they don't
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
  upstream's). Nothing is pushed from here.

## Tooling and distribution

- **`rocx new`:** not built (`rocx --help` has `dev`, `build`, `check`, `lint`, `routes`, `fmt`).
  examples/tasks was written to be its template, and D-045 adds the database question above.
- **rocx on Linux** (D-062): the CLI platform's musl targets are named and `just rocx-bootstrap`
  builds for them, but neither has run; its watching polls there (inotify is the next step).
- **What is still Node** (D-062): the tests, `just site`'s full build (it measures the wasm with
  `web/runtime.js` and prerenders through the server), and the measuring scripts. A static site
  in Roc would need a way to run the wasm, or to drop the measured rendering times.
- **Prebuilt, stripped platform bundles for every target** (`roc bundle`), so a newcomer needs only
  `roc` and `rocx`: no Node, Rust or Zig.
- **Errors in an editor, beyond a build's** (the user, 2026-11-24: `rocx check` is enough for now;
  the VS Code extension shows a `rocx dev` task's on each build): `rocx lsp`, checking on save
  without serving (an app has no `rocx check <dir>` yet: `rocx check -- roc check main.roc` needs the
  compiler named), for every editor with a language-server client; then hover and completion by
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
  the same run.
- **The channels "a tab has one stream" test flakes under load** (`server/test/server.test.mjs`):
  it waits for the old stream's `channel closed` log event, then reads the log at once, and the
  new stream's `channel opened` (the async writer's) can be later: `['channel opened', 'channel
  closed']` against three (seen once in a full run with Postgres on 2026-11-24; passes alone). Wait
  for the second `channel opened` too.
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

- **Old branches kept on purpose until about 2026-11-28:** `native-server`, `solid-signals` and
  `refs/scrub-backup/native-server`. Delete them then, with the user's OK.
