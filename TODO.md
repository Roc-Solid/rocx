# TODO

What still needs work, and where its details are, so nothing is lost between sessions. This file
only points; the details stay where they live:

- decisions, built or proposed, are in `DECISIONS.md`;
- each package's ideas and questions are in its `PROPOSALS.md`;
- each platform's known limits are in the "Not yet" sections of `web/README.md` and
  `server/README.md`.

When an item lands, delete its line here in the same commit.

## Waiting on a decision by the user

- **Client-side navigation (D-040, Proposed).** Twelve questions, each with a recommendation, are in
  `spike/client-nav/DESIGN.md` §17. The plan (§15) after the answers:
  1. Phase 1: same-app links and `Router.navigate!`, with the page's body made anew. This phase also
     fixes URLs the runtime builds without `--base` (a computed `href` patched to `/x` while
     hydrating).
  2. The app's stylesheet as a file with its hash in its name, rather than inline in every page
     (question 9).
  3. Phase 2: kept layouts, the query changed in place (`use_search_params!`), `<A>`, `<Navigate>`
     and GET forms.
  4. Phase 3: prefetch and View Transitions.

  D-039 gave route views getters, so question 4 (keep a page across a change of its params) no
  longer costs a change to every page, whichever way it is answered.
- **packages/markdown:** open questions 1, 2, 4 and 5 in its `PROPOSALS.md`:
  - trusted HTML;
  - `<Markdown>` server-only by default;
  - heading ids;
  - whether the CommonMark/GFM spec examples (CC BY-SA 4.0) stay in a public repo.
- **packages/guard:** a question in its `PROPOSALS.md`: the rate-limit headers.
- **packages/presence:** the questions at the end of its `PROPOSALS.md` (hidden tabs shown as away,
  the metadata shape).
- **packages/jobs:** a job's log in the jobs page, parked with its options in its `PROPOSALS.md`.
- **The other packages' `PROPOSALS.md`** (admin, forms, intl, mcp, otel, push, testing) have more
  ideas and questions waiting.
- **`rocx new`** asks which database (Postgres, SQLite, Turso); the question is open in D-045.

## Framework work, decided but not built

- **After D-039 (value props are getters)**, from `spike/reactive-props/DESIGN.md`, "Follow-ups":
  - `untrack`, and with it Solid 2.0's dev warning for a reactive read in a component's body;
  - a hole that reads nothing becomes static markup, on the server and while hydrating alike;
  - `merge` and `omit` for passing a props record on.
- **The rest of Solid 2.0 and Solid Router's actions:** see `web/README.md`, "Not yet".
- **packages/presence:** W1 (where the pointer is: `on:pointermove.point`), W3 (whether the page is
  visible: `<Document on:visibilitychange>` now exists) and R1 (a type variable's JSON through a
  structural type). W2, a browser clock, is done: `Time.now_millis!`. Details: its `PROPOSALS.md`.
- **OpenAPI:** an endpoint that a plain form also posts to is listed with a JSON body only, though
  it reads form fields as well (`server/README.md`, "Not yet").
- **The server's other limits** are in `server/README.md`, "Not yet":
  - actors' timers are all set again at start, a task each in memory;
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

## Housekeeping

- **Old branches kept on purpose until about 2026-11-28:** `native-server`, `solid-signals` and
  `refs/scrub-backup/native-server`. Delete them then, with the user's OK.
