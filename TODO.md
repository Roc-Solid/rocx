# TODO

What still needs work, and where its details are, so nothing is lost between sessions. This file
only points; the details stay where they live:

- decisions, built or proposed, are in `DECISIONS.md`;
- each package's ideas and questions are in its `PROPOSALS.md`;
- each platform's known limits are in the "Not yet" sections of `web/README.md` and
  `server/README.md`.

When an item lands, delete its line here in the same commit.

## Waiting on a decision by the user

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

## Framework work, decided but not built

- **`use_before_leave!`** (D-040; Solid Router's `useBeforeLeave`, which phases 1 to 3 left): a
  leave handler an unsaved form registers, given an event it can stop and retry later, and
  `beforeunload` for a load: a hosted call and its event's type.
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

- **Reduced repros in `test/compiler-bugs/`, each worked around in the repo** (`just compiler-bugs`
  runs them):
  - `json-to-str-try-nominal`: `Json.to_str_try` of a record holding a nominal type with a derived
    encoder crashes `boxy_lowering`;
  - `two-formats-one-where`: a where clause naming two formats (`Json` and D-038's `FormBody`)
    crashes `boxy_lowering`;
  - `list-map-reuse-opt-speed`: `List.map` writes past its items under `--opt=speed` when the
    closures' captures come from elsewhere;
  - `middleware-skipped-opt-speed`: a chain of three effectful closures skips its last step under
    `--opt=speed`;
  - `two-guarded-routes-opt-speed`: two routes guarded by a capturing middleware crash an
    `--opt=speed` server at start.
  - `try-json-codec`: the builtin `Try` has no JSON encoder or parser, though Builtin.roc declares
    them derived (an app's own `[Ok(ok), Err(err)]` nominal type has both): a tag union stands in for
    a `Try` across the wire (D-054).
  - `huge-frame-opt-speed`: `--opt=speed` inlines every closure of a lambda set into one function,
    whose stack frame grows with the program; the docs site's server, with D-040's route levels,
    passed the 8 MiB a render has (12.4 MB), so it is built `--specialize=no`. Any large app built
    `--opt=speed` can meet it; the cure is the compiler's (shared stack slots for a switch's cases,
    or closure bodies kept out of line past a size).
- **Not reduced yet:** a rigid `..others` beside an app's own error tag in one body doesn't
  type-check (examples/uptime names `JobErr` instead).
- **Fixes prepared on the fork wait for the user to open them as PRs** (boxy, `List.map` reuse).
  Nothing is pushed from here.

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
- **The live docs site** (roc-solid.github.io) was last deployed on 2026-11-21. Everything since,
  the examples pages and D-036 to D-049 among it, isn't live. `just deploy-pages` waits for the
  user's go.

## Tests

- **The site's dev-rebuild timing test flakes under load** (`site/test`, "rebuilds fast"): it
  fails on most full runs while other builds run (2,015–3,600 ms against a limit of 2 s, scaled
  ×1.5 by the load average) and passes alone (about 740 ms). The load average lags a burst of
  builds. A sturdier check: the median of three rebuilds, or a ratio to a no-op rebuild measured in
  the same run.

## Housekeeping

- **Old branches kept on purpose until about 2026-11-28:** `native-server`, `solid-signals` and
  `refs/scrub-backup/native-server`. Delete them then, with the user's OK.
