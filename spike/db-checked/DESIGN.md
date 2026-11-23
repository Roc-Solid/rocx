# Design: `Db`'s queries checked at build (D-058, Proposed)

> A design spike, 2026-11-23, on master at c36dc93. Nothing here is built. The numbers come from
> the spike beside this file (`describe/`, a Rust program, and `run.mjs`, which runs it over every
> example app). The appendix says how to run them.

## 0. In short

An app's SQL is checked by the database it runs on, and its rows are checked by the Roc compiler.
Nothing in the app changes.

1. **Find the statements.** rocx reads the app's sources. Each `Db.all!` and `Db.run!` whose SQL
   is a string literal at the call is a statement to check. That covers 89% of the repo's 270
   calls. rocx also records where each one is, how many parameters the call gives (when they are a
   list literal), and the type its rows are annotated with.
2. **Describe them.** The app's own server describes each statement (`--describe-sql`). It
   applies the program's migrations (the platform's, the plugins' and the app's) to a scratch
   database of the app's kind: SQLite or Turso in a temporary file, or Postgres in a database made
   beside `DATABASE_URL`. The engine then prepares each statement. Its answer is the engine's own
   error, or the statement's parameters and its columns. For each column that comes straight from
   a table, the answer also gives its declared type and whether it is `not null`.
3. **Check SQL and parameters in rocx.** rocx reports an engine error at the call's line
   (`no such column: kcals`). It also reports a parameter count that differs from what the call
   gives (`$1` to `$3` used, 2 given). This is the rule the host already enforces at run time.
4. **Check rows with the compiler.** rocx writes a small check app. For each call whose row type
   it found, the app has one line that names that type, copied from the call's annotation as
   D-037 copies handlers' types into `Generated/Api`. The line's string is the engine's
   description.

   ```roc
   ## examples/plate/Store.roc:122
   q122 : DbCheck.Rows(List({ id : I64, fiber : Dec, … }))
   q122 = "{\"at\":\"examples/plate/Store.roc:122\",\"columns\":[…]}"
   ```

   `DbCheck.Rows(rows).from_quote` runs at compile time, as roc-pg's `Sql` does. It reads the
   row type's shape through its parser, with a format that reads nothing, as `OpenApi.Schema`
   already does. Then it compares the shape with the columns: each field must be a column, of a
   type its decoder reads, and `Db.Nullable` wherever the column may be null. A mismatch is a
   compile error that names the call:

   ```
   examples/plate/Store.roc:122: fiber : Dec, but foods.fiber may be null (it has no `not null`):
   read it as Db.Nullable(Dec)
   ```

5. **When it runs.** `rocx dev` runs the check after each rebuild and prints what it finds,
   without holding back the restart. `rocx check --sql <app>` fails on any finding, and
   `just examples` runs it for every example. `roc check main.roc` and the app's build don't
   change.

The platform's part is one host flag (`--describe-sql`, about 200 lines of Rust over the three
backends). `Db.all!` and `Db.run!` keep their signatures. The checker is a pure Roc package
(`packages/dbcheck`); the scan and the check app belong to rocx.

```
rocx dev / rocx check --sql
   │
   ├─ rocx: scan .roc/.rocx ──► build/sql/statements.json   (SQL, file:line, params given, row type text)
   │
   ├─ the app's server --describe-sql ──► build/sql/described.json
   │     migrations → scratch db (SQLite/Turso file, Postgres db) → prepare each → columns, params, errors
   │
   ├─ rocx: SQL errors, parameter counts ──► reported at file:line
   │
   └─ rocx: build/sql/main.roc (a check app: one DbCheck.Rows line per call) ──► roc check
         from_quote at compile time: row shape (probe format) vs columns ──► reported at file:line
```

## 1. Where things stand

- `Db.all! : Str, List(Value) => Try(List(row), [DbErr(Str), BadRow(Str), ..])`, with
  `where [row.Json.Parseable(…)]`. The host sends the SQL with its parameters as JSON, and each
  row comes back as JSON. `Json.parse` then decodes the rows into the record the caller
  annotated (D-022). Nothing about the statement is known until it runs:
  - A typo in a column is a `DbErr` the first time the call runs.
  - A column the record reads but the statement lacks is a `BadRow` then too.
  - A nullable column read as a plain value is a `BadRow` only on the first row that is actually
    null, possibly in production, months later.
- server/README.md, "Not yet": "`Db`'s queries aren't checked at build (rows are decoded by the
  record each caller annotates); roc-pg's are." D-016 (2026-11-21) sketched "a command that
  describes each query against the dev database … and checks the annotated record, as sqlc does".
- The platform has three backends: Postgres, SQLite and Turso (D-045, D-046, D-049). An app picks
  one and writes its SQL in that one's flavor. A package may carry SQL for both and pick it with
  `Db.backend!` (packages/jobs, packages/push).
- How the repo calls `Db` today (`spike/db-checked/run.mjs`, plus a count over every directory):

  | | calls | SQL a literal at the call | interpolated (`${…}`) | in a variable |
  |---|---|---|---|---|
  | whole repo (examples, packages, site, server) | 270 | 241 (89%) | 21 | 8 |
  | the examples on SQLite | 163 | 141 | 19 | 3 |

  Of the examples' 97 `Db.all!` calls with literal SQL, the spike's crude text reading found a
  row type for 92:
  - most have an annotation on the binding (`rows : List({ … })`);
  - some use the function's result type (`=> Try(List(Row), Problem)`);
  - inline records outnumber named aliases about three to one.
- **The Roc fork can check a literal at compile time.** A type with
  `from_quote : Str -> Try(T, [BadQuotedBytes(Str)])` receives every string literal used where a
  `T` is wanted. It runs at compile time, and an `Err` is a compile error at the literal. `roc
  check` reports it as well. roc-pg's `Sql(schema, params, row)` uses this mechanism, and
  `server/examples/roc-pg` builds with it on this platform.
- **A type's shape can be read through its parser.** A format whose `parse_*` methods read
  nothing, and only note what they are asked for, recovers the shape: the field names, each
  field's kind, and whether `parse_null` is tried first (as `Db.Nullable`'s parser does).
  `OpenApi.Schema` writes JSON Schemas this way for `Api.openapi`. roc-pg's `RowFormat` does the
  same at compile time. The compiler supplies the type, whether written down or inferred.

## 2. What is checked

### 2.1 SQL: by the engine

**SQL: what is checked.** The app's own engine prepares each statement on a schema built from
its migrations. Each engine has its own grammar, functions and extensions, so the engine is the
only exact judge. Preparing it catches:

- syntax;
- tables, columns and functions that don't exist;
- an ambiguous column;
- `group by` errors;
- Postgres's type errors (`operator does not exist: text = json`);
- what Turso doesn't support (in the spike, it refused examples/board's
  `json_group_array(value order by key)`);
- FTS5 tables, which Turso lacks.

The message is the engine's, given at the call's line.

**SQL: what isn't checked.** What only running the statement would show:

- a constraint that would fail;
- a cast that fails on some value;
- a `json_each` of text that isn't JSON.

### 2.2 Parameters

**Count.** A statement's parameters are `$1` to `$n` on every backend. The host refuses "a
parameter given and unused, or used and not given". The check applies the same rule ahead of
time: the statement's parameters (Postgres's described parameters; SQLite's and Turso's
parameter names) must be exactly `$1` to `$k`, where `k` is the number of items in the call's
list literal. When the list isn't a literal (`params`, `base.concat(…)`), only the gaps are
checked (`$1` and `$3` without `$2`).

**Types: later, and on Postgres only** (phase 5). Postgres describes each parameter's type. The
call's items are often tags written at the call (`Int(id)`, `Text(name)`, `Bool(on)`, `Null`,
`Db.array(…)`). The host sends every value as text, and Postgres reads text as the type its
place wants, so `Text("7")` into an integer place is fine. The check would therefore refuse only
mixes that can never work, such as a `Bool` into an integer, or an `Int` into a `bool` or
`uuid`. SQLite and Turso bind each value as it is, so there is nothing to check there.

### 2.3 Rows: by the compiler, against the engine's columns

For a `Db.all!` whose row type rocx can name (§5), the record must fit the columns. The rules
follow what `Db.all!` decodes today, since the check predicts `BadRow`:

1. **Names.** Every field is a column of the statement, matched by name (the column's alias if
   it has one). A field the statement doesn't return is an error that lists what it does return.
   A column no field reads is fine, as it is at run time.
2. **Types.** The column's type must be one the field's decoder reads:

   | column | read as |
   |---|---|
   | integer: SQLite/Turso declared `INT…` (affinity INTEGER); Postgres `int2`/`int4`/`int8` | any integer type, `Dec`, `F32`/`F64` |
   | real: SQLite `REAL`/`FLOA…`/`DOUB…`; Postgres `float4`/`float8` | `Dec`, `F32`/`F64` |
   | text: SQLite `…CHAR…`/`CLOB`/`TEXT`; Postgres `text`, `varchar`, `bpchar`, `name`, `uuid`, `timestamp(tz)`, `date` | `Str`, or a type whose parser reads a string (a nominal, a tag union of tags without payloads) |
   | boolean: SQLite/Turso declared `boolean` (the host's rule); Postgres `bool` | `Bool` |
   | json: SQLite/Turso declared `json`; Postgres `json`/`jsonb` | anything |
   | SQLite NUMERIC affinity (`decimal`, `date`, no recognised type) | anything: SQLite stores whatever was written |
   | blob; Postgres `numeric`, arrays, `interval`, enums, others the host can't read | an error: "cast it (`hex(…)`, `::text`)". The host refuses these today at run time. |
   | an expression (`count(*)`, `coalesce(…)`, `cast(…)`) | not checked: SQLite doesn't type expressions when it prepares |

   Postgres does type every expression (`count(*)` is `int8`, `coalesce(cast(x as text), '')` is
   `text`), so on Postgres expressions are checked as well. On SQLite, Turso's
   `get_column_inferred_type` could fill the gap (phase 5).
3. **Nullability.** A field read as a plain value (not `Db.Nullable`) from a column that comes
   straight from a table column without `not null` is an error that names the column and says
   how to read it. A primary key counts as `not null`. Over a column that is `not null`,
   `Db.Nullable` is allowed and not reported. Expressions aren't checked here either, except
   where Postgres says.

   **False positives.** A column filtered with `where note is not null` is still declared
   nullable, so the check would flag it. The ways out are `coalesce(note, '')`, a cast (which
   makes it an expression), or `Db.Nullable` and a match. D-022 refused column names such as
   `note!`, which sqlx uses for this. Question 3 asks whether this rule is an error or a warning.

   **False negatives.** In an outer join (`left join recipes r … r.food_id`), the column's origin
   is `not null` and both engines report it so, but the joined row may be missing. The spike
   confirms this (§7). That case is still caught only at run time by `BadRow`, as today. Phase 5
   would read the plan to mark such columns nullable, as sqlx does: SQLite's `EXPLAIN` has a
   `NullRow` for the outer side, and Postgres's `EXPLAIN (VERBOSE)` gives the join kind.

### 2.4 What isn't checked, and says so

`rocx check --sql` ends with a count, so nothing unchecked passes silently:

```
SQL: 141 statements checked on SQLite: 92 rows checked against their records,
5 rows unchecked (no row type rocx can name), 19 interpolated statements and 3 in variables not
checked (--verbose lists them)
```

Unchecked:

- interpolated SQL (`"select ${columns} from tokens"`);
- SQL in a variable or a parameter (helpers such as examples/notes' `listed!(sql, params)`);
- a row type rocx can't name;
- statements marked `Db.unchecked` (question 4);
- anything that only fails when run.

## 3. Describe on the engine, or parse in Roc

The question is how to get a statement's columns and parameters. There are two ways:

- **Prepare it against a real database** built from the migrations. sqlx, PgTyped, Squirrel and
  sqlc's database-backed analysis do this.
- **Parse it**, with the schema read from the migrations' DDL. roc-pg (in Roc, at compile time),
  sqlc's default mode and Hasql-th do this.

**Choice: prepare.**

- **It's exact.** The engine that will run the statement is the judge. Its SQL, functions,
  extensions (FTS5, `json_each`), version and errors are all the real ones, and so are Turso's
  gaps. A parser in Roc would have to track three engines.
- **It's cheap.** In the spike, describing an app's 5 to 38 statements took under a millisecond
  on SQLite and Turso, and 10 to 20 ms for 21 statements on a local Postgres (§7).
- **It needs no new Roc grammar.** roc-pg's Postgres checker is about 2.5 MB of Roc (`Grammar`,
  `Actions`, `Check`, `Builtins`). SQLite has none, and writing one, with its rules for result
  types and nulls, is a project of its own.
- **Its weak spot is outer joins and expressions on SQLite** (§2.3). sqlx works around both by
  reading the plan. That is possible later without changing the design.

### 3.1 Who describes: the app's own server

`--describe-sql <file>` on the app's server binary. The host reads a JSON list of statements. It
opens a scratch database of the app's kind:

- **SQLite or Turso:** a fresh file in the temporary directory, removed afterwards. Turso refuses
  an in-memory database, and SQLite's connections don't share one.
- **Postgres:** a database named `rocx_check_<random>`, made with `create database` on the
  server `--database-url` (or `DATABASE_URL`) points at, and dropped afterwards. This needs
  `CREATEDB`; see question 8.

Then it runs the platform's start as it does now (`roc::init`), so the program's migrations are
applied: the platform's, the plugins' (filtered by `on:`) and the app's, in order. Then it
prepares each statement on one connection and prints a JSON answer for each, and exits. It
doesn't bind a port or start background loops.

```json
[{ "error": "no such column: kcals" },
 { "params": ["$1"], "columns": [
     { "name": "id", "type": "INTEGER", "table": "foods", "column": "id", "not_null": true },
     { "name": "fiber", "type": "REAL", "table": "foods", "column": "fiber", "not_null": false },
     { "name": "recipe", "type": null } ] }]
```

Per backend:

| | prepare | columns | origin and `not null` |
|---|---|---|---|
| SQLite (rusqlite) | `Connection::prepare` | `column_name`, `column_decltype` (feature on today) | `column_table_name`/`column_origin_name` + `sqlite3_table_column_metadata` (rusqlite's `column_metadata` feature: one more flag on the host's dependency) |
| Turso (`turso_core` 0.8.4) | `Connection::prepare` | `get_column_name`, `get_column_decltype`, `get_column_inferred_type` | `get_column_table_name`, but not the origin column's name: the same statement on SQLite gives it (both are SQLite's SQL), or `pragma table_info` when the column isn't aliased |
| Postgres (tokio-postgres 0.7.18) | `Client::prepare` (Parse/Describe, parameters untyped, as the host sends them) | `Column::name`, `type_()` | `table_oid()`/`column_id()` + `pg_attribute.attnotnull`, one query per table column, kept for the run |

**Why the binary and not a separate tool:**

- Only the compiled program knows the exact migrations. The platform's own are Roc strings in
  `Migrations.roc`, and the plugins' are filtered by `on:` and ordered by their needs.
- It already contains all three engines.
- `rocx dev` and the tests build it anyway.

A standalone describer would need the migrations collected again outside the program. That
breaks as soon as a plugin adds a table an app's SQL reads.

A hosted `Db.describe!` effect for Roc isn't needed for this. It could come later if
packages/admin's SQL page wants column types.

## 4. How the statements are found

**Choice: literals at the call, read by rocx. No `Sql` type.**

The scan, in rocx-cli (Roc, beside `Routes`'s reading of handler annotations), looks at every
`.roc` and `.rocx` file of the app outside `Generated/`, `build/` and `test/`, and finds
`Db.all!(` and `Db.run!(`:

- It skips a `##` doc comment's lines.
- If the first argument is a string literal (`\"`, `\\`, `\n` unescaped; a `"""` block too),
  that literal is the statement. An interpolated one is counted as unchecked.
- If the second argument is a list literal, its top-level items are counted.
- For `Db.all!`, it records the row type (§5).

Its output is `build/sql/statements.json`: each statement with its file, line and column.

**An alternative: a `Db.Sql(row)` type.** `Db.all!`'s first argument would become `Db.Sql(row)`,
whose `from_quote` checks the literal at compile time, as roc-pg does. That is the most direct
form of the check. It fails on three counts:

- **The platform can't see the app's schema.** A platform module can't import an app's module,
  and `Db.all!` takes nothing that carries a type from the app (roc-pg's `Client(_, schema)` does
  this through the client value). The required types a platform can ask of an app
  (`requires { [Schema : schema] for program … }`) reach `main.roc` only. A per-app generated
  `Db` module would work, but every module would then have to `import Generated/Db` instead of
  `pf.Db`.
- **Every helper that passes SQL on** would change from `Str` to `Db.Sql(row)`: notes' `listed!`,
  the bench's runner, packages/jobs and packages/push.
- **Its check would run before the engine describes anything**, so the descriptions would have to
  exist before the build (a cache to keep fresh, as sqlx's offline `.sqlx/` is). Otherwise
  `from_quote` would need a SQL parser in Roc after all (§3).

Literals at the call keep `Db` as it is, and every existing call already is one.

## 5. How rows are checked: the compiler names the type

The row type is known exactly only to the compiler, and it may be an alias, a nominal, a
package's type, or inferred. Rather than parse Roc types in rocx, rocx copies the annotation's
text into a generated module and lets the compiler resolve it. D-037 already does this for
`Generated/Api`, which copies each handler's types with the route file's imports and their paths
rewritten.

### 5.1 Where the row type comes from

rocx reads only the text of the annotation, never its meaning. In order:

1. **A binding's annotation.** The call is `name = Db.all!(…)` (with or without `?`, `.map_err`
   and the like after it), and `name : T` appears earlier in the same block. For example,
   `rows : List({ timezone : Str })` or `entries : List(Plate.Entry)`. The row type is `T` with
   its `List(…)` (or `Try(List(…), …)`) removed.
2. **The function's result.** The call is the last expression of a function whose annotation
   ends in `=> Try(List(R), E)` (or `-> …`).
3. **Otherwise**, nothing is recorded: the call's SQL and parameters are still checked, but not
   its rows. This happens when the type is inferred, is a type variable (`row`), or is an alias
   local to a function body.

Names in `T` that are the module's own (`Row` inside `Store := [].{ … }`) are qualified
(`Store.Row`). Names from imports stay as written, and the module's imports are copied with their
paths rewritten for the check app. If a type is defined in the call's own module at the top
level, the module itself is imported. Nothing imports the check app, so unlike `Generated/Api`
it may import any of the app's modules without a cycle.

### 5.2 The check app

rocx writes `build/sql/main.roc`, beside the browser's copy (`build/client/`), with the same
packages as the app's `main.roc`. Paths are rewritten, plus `dbcheck`. The app is a minimal
`program` (the platform requires one), plus one constant per row check:

```roc
app [program] { pf: platform "../../../../server/platform/main.roc", dbcheck: "…/packages/dbcheck/main.roc", forms: "…" }

import pf.Db
import dbcheck.DbCheck
import ../../Plate
import ../../Store

## examples/plate/Store.roc:71
q71 : DbCheck.Rows(List(Plate.Entry))
q71 = "{\"at\":\"examples/plate/Store.roc:71\",\"engine\":\"sqlite\",\"columns\":[…]}"

## examples/plate/Store.roc:122
q122 : DbCheck.Rows(List({ id : I64, name : Str, fiber : Db.Nullable(Dec), sodium : Db.Nullable(Dec), recipe : Str }))
q122 = "{\"at\":\"examples/plate/Store.roc:122\",\"engine\":\"sqlite\",\"columns\":[…]}"

# The platform requires a program; this one answers nothing and names every check, so each is
# reachable however the compiler treats a constant nothing uses.
program = DbCheck.program([DbCheck.at(q71), DbCheck.at(q122)])
```

`roc check build/sql/main.roc` then evaluates each `from_quote`. rocx prints the messages, which
already start with the call's `file:line`. They don't need the remapping `.rocx` files get, so
the check app's own line numbers never appear.

**If the check app doesn't compile.** That would mean an annotation rocx copied doesn't resolve
there, or a row type's parser is written for `Json` alone rather than for any format. rocx then
reports the compiler's message as "row checks skipped" with the cause, and fails
`rocx check --sql`. The app itself is never affected: nothing it builds imports the check app.

### 5.3 `packages/dbcheck`

The package is pure Roc on no platform, as packages/crypto is. D-025's rule applies: it needs no
host. It contains:

- **`Rows(rows)`**, whose `from_quote` parses the description (JSON, a fixed record) and reads
  the shape of `rows` with `rows.parser_for(Probe)`. It applies §2.3's rules and returns
  `Err(BadQuotedBytes(message))` on the first mismatch, or on all of them in one message.
- **`Probe`**, the format. It is two passes, as roc-pg's `RowFormat` is:
  - `Nulls` answers `parse_null` with "null", to find the fields that try it;
  - `Kinds` answers "not null", so the inner type's scalar parser is reached.

  A record or list inside a field is read as "JSON" (any value), not refused as roc-pg refuses
  it. A tag union without payloads reads as text (Json writes it as a string).
- **`program`**, the check app's minimal program.

`Db.Nullable`'s parser already tries `parse_null` first, so it needs no change. Neither does the
platform.

## 6. When it runs, and what it costs a developer

| | what runs | on a finding |
|---|---|---|
| `rocx dev` | after each rebuild and restart, in the background: describe (the binary just built), the scan, the check app's `roc check` | printed in the terminal (and the dev overlay, if the page has one), like a warning; the server is already restarted |
| `rocx check --sql <app> [-- server options]` | the server built as `rocx dev` builds it (dev backend), then the same | exit 1, each finding at its `file:line` |
| `just examples` | `rocx check --sql` for each example, before its tests | the example fails |
| `just check`, `roc check main.roc`, `roc build`, `rocx build` | unchanged | — |

**Not in `rocx build`.** `rocx build` only generates code: it runs no server and opens no
database, so it can't describe. Folding the row checks into the app's own compile (with
`Generated/App` importing the check module, so `roc build` fails on a mismatch) is possible once
descriptions are cached, but a stale cache or a check line that doesn't compile would then break
the app's build. See question 2.

**No separate test helper.** `rocx check --sql` is what `just examples` and CI call. An app's own
`node --test` doesn't need a call of its own.

**Cost per run.** Describing costs milliseconds (§7). The rest is the server's start (process,
runtime, migrations) and the check app's `roc check`. That takes about as long as `roc check` of
the modules it imports, with Roc's cache warm in `rocx dev`. Phase 3 measures it; the target is
under a second for the largest example.

## 7. What it costs per backend (measured)

The spike's describer, release build, on a busy Apple M5. Migrations are each app's own
`migrations/*.sql`. Describe covers every literal statement found in the app.

| | scratch database | migrations | describe |
|---|---|---|---|
| **SQLite** (in memory for the spike; a temporary file in the design) | — | 0.2–1.2 ms; examples/plate, whose second migration holds 1.4 MB of food rows: 55–74 ms | 0.1–0.6 ms for 5–38 statements |
| **Turso** (temporary file, WAL) | — | 1.6–8.2 ms; notes and plate refused (`no such module: fts5`: Turso has no FTS5, so neither app can run on Turso) | 0.3–0.9 ms for 5–28 statements |
| **Postgres** 18 in Docker, local | `create database` 89–226 ms; `drop database` 37–40 ms (1.1 s on the first run) | 24 ms (packages/jobs' table) | 10–20 ms for 21 statements, with one catalog query per origin column |

**What the spike found on the examples, all on SQLite:**

- **All clean.** No unknown table or column outside the cases below, no parameter count off, no
  field the statement lacks, no type mismatch, and no nullable column read as a plain value. 173
  fields had a declared type to compare; 70 came from expressions. The apps are tested, and
  `BadRow` already catches mismatches when a test runs the call.
- **8 statements in examples/sqlite-vs-turso read tables its run makes with `Db.script!`**
  (`orders`, `customers`), not with a migration. The check would report "no such table" for
  each. These are the reason for `Db.unchecked` (question 4).
- **Turso refuses one statement of examples/board:** `json_group_array(value order by key)`
  ("ORDER BY clause is not supported yet in aggregate functions"). board runs on SQLite, so this
  is not a bug. It would become one if board were started on a `turso:` URL, which the server
  allows. See question 6.
- **A left join is a false negative, as expected.** In
  `select …, r.food_id from foods f left join recipes r on …`, both engines report `r.food_id`
  as `not null` (from `recipes.food_id`).

**Postgres needs the statements of its own flavor.** The spike also described packages/jobs'
statements on Postgres. The four it refused are its SQLite flavor (`json_each`, two-argument
`max`), which the package runs only on SQLite. A package's SQL therefore can't be checked against
one backend alone (question 7).

## 8. Prior art

- **roc-pg** (Roc, Postgres; runs on this platform: `server/examples/roc-pg`). `Client.query!`
  takes a `Sql(schema, params, row)`, whose `from_quote` checks the literal at compile time:
  - a Postgres grammar, catalog and type checker, all in Roc, against a `schema.sql` that the
    app's `Schema` type names;
  - parameters named `$name`, from a record;
  - the row type's shape read through `RowFormat`, the parser protocol with a format that reads
    nothing;
  - fields whose column type the build couldn't determine are checked against the result
    description at run time.

  From it we take `from_quote` and the probe format. We don't take the grammar: we have three
  engines, and the database itself is exact (§3).
- **sqlx** (Rust). The `query!`/`query_as!` macros describe each literal at compile time,
  against `DATABASE_URL` or the offline data `cargo sqlx prepare` writes to `.sqlx/`.
  - Postgres: Parse/Describe, with nullability from `attnotnull`, and `EXPLAIN` to find outer
    joins.
  - SQLite: it steps through the statement's `EXPLAIN` program to infer types and nulls.
  - Columns named `"x!"`, `"x?"` and `"x: T"` override what it infers.

  From it we take preparing against a real database, and nullability from the origin column.
  Reading the plan is our phase 5. We don't take the names (D-022). A committed offline cache is
  question 9.
- **sqlc** (Go). Queries live in `.sql` files with `-- name:` comments, and sqlc generates typed
  functions. It parses with each engine's parser (Postgres's own, `pg_query`), against a catalog
  read from the schema files. Since v1.23 (2023) it can also use a managed, running database to
  analyse queries, and its `sqlc/db-prepare` rule prepares each query against it. That analysis
  supports Postgres only; MySQL and SQLite are planned. We don't take its separate query files
  and generated functions, since moving the SQL out of Roc is a change to every app.
- **Squirrel** (Gleam, Postgres 16+). It generates typed functions from `src/**/sql/*.sql`,
  describing each query on a live database. Postgres says nothing about whether a parameter may
  be null, and Squirrel lists that as a limit. That gap doesn't affect us: a `Db.Value` says
  `Null` itself.
- **PgTyped** (TypeScript) and **Prisma's TypedSQL** (`prisma/sql/*.sql`) describe `.sql` files
  against a database and generate types. They put SQL in files, as sqlc does.
- **doobie** (Scala) checks queries in a test. `check(query)` prepares it on a real database and
  compares JDBC's metadata (types, nullability) with the Scala types the query value carries.
  This is the closest to §5: the compiler supplies the program's types, the database supplies the
  statement's, and a separate run compares them.
- **postgresql-typed** (Haskell, Template Haskell) and **F#'s SqlClient type provider** describe
  queries on a database while compiling. **Hasql-th** parses SQL at compile time and has no
  database.

## 9. What apps change

**Nothing.** Every call stays as written. Optional changes:

- **`Db.unchecked(sql)`** (question 4) marks a statement the check should skip: tables made at
  run time, or SQL the engine only accepts in a later state.
- **A row type rocx couldn't name** can be annotated, so it gets checked. `--verbose` lists such
  calls.
- **What the check finds in the repo is fixed in the same branch.** On today's examples, that is
  the 8 statements in examples/sqlite-vs-turso.

## 10. What the platform changes

- **The host:** `--describe-sql <file>` (§3.1), about 200 lines over `db/mod.rs` and the three
  backends, plus rusqlite's `column_metadata` feature. Usage text and server/README.md say so.
- **`Db.unchecked : Str -> Str`**, the identity, documented (one function), if question 4 says
  so.
- **Nothing else.** `Db.all!`, `Db.run!`, `Db.Nullable`, the decoding, `BadRow` and the browser's
  platform stay as they are.

## 11. Options weighed

1. **The chosen design:** the engine describes, and rocx checks SQL and parameters. The compiler
   checks rows through a generated check app (`from_quote` and a probe). No app change. Exact
   where it checks, and silent nowhere (§2.4).
2. **As 1, with rocx reading the row types from the text** (parsing Roc type expressions,
   resolving aliases through imports and nominal blocks), so there is no check app and no
   compile step. Faster and simpler to run. But it means a second, partial Roc type reader inside
   rocx, and an alias resolved wrongly is a false error. The spike's crude reading got 92 of 97;
   the compiler gets every one rocx can name. This is the fallback if 1's check app proves
   fragile (§13).
3. **`Db.all!` takes a `Db.Sql(row)`** whose `from_quote` checks at the literal, as roc-pg does
   (§4). Best for the user, but the platform can't reach the app's schema without a generated
   `Db` that every module imports. Helpers change, and the descriptions must exist before
   compiling.
4. **Query files and generated functions** (sqlc, Squirrel, PgTyped). Exact, and types come from
   the database, not from annotations. But every app moves its SQL out of Roc.
5. **A SQL grammar and checker in Roc** for SQLite and Postgres (roc-pg's road), with no
   database at all. Months of work, and still less faithful than the engine.
6. **A check at run time:** `Db.all!` sends the row's shape (a probe) with the SQL, and the host
   compares it with the statement's description the first time it sees it, in `--dev` and
   tests. This catches interpolated SQL and inferred rows. But it only covers the calls tests
   reach, and `Db.all!`'s `where` would name two formats (`Json` and the probe), which crashes
   today's fork (`test/compiler-bugs/two-formats-one-where`). It could be a later addition to 1,
   once that bug is fixed.

## 12. Phased plan

Each phase lands on its own, with tests and docs.

1. **This design (Proposed).**
2. **SQL and parameters.**
   - The host's `--describe-sql` on all three engines, with server tests: a statement that
     prepares, one that doesn't, a parameter gap, a scratch database left behind by nothing, and
     a Postgres database dropped after the run.
   - rocx's scan, with tests: literals, escapes, interpolated, variables, list literals, `##`
     lines, `.rocx` files.
   - `rocx check --sql <app>`: build the server, describe, report.
   - `just examples` runs it.
   - examples/sqlite-vs-turso's run-made tables marked `Db.unchecked`.
   - Docs: server/README.md's `Db` section, the site's database page, rocx's usage.
3. **Rows.**
   - `packages/dbcheck`: `Rows`, `Probe`, the rules. `roc test` covers each rule on both engines'
     type names.
   - rocx writes `build/sql/main.roc` from the annotations.
   - `rocx check --sql` runs `roc check` on it and reports.
   - A fixture app in the tests with one deliberate mistake of each kind:
     - a typo in a column;
     - a field the statement lacks;
     - a `Str` over an integer;
     - a plain field over a nullable column;
     - a parameter missing;
     - a Postgres column of a type the host can't read.

     Every example stays clean.
   - The timing measured.
4. **`rocx dev`.** The check after each rebuild, in the background, printed. Then TODO.md's line
   and server/README.md's "Not yet" entry are deleted, and D-058 is marked Built.
5. **Later, each on its own and each optional:**
   - outer-join nullability from the plan;
   - Turso's inferred types for SQLite expressions;
   - interpolated SQL whose pieces are the module's own string constants (notes'
     `${token_columns}`, uptime's `${incident_columns}`);
   - Postgres parameter types;
   - packages checked per backend (question 7);
   - the checks in the app's own compile (question 2);
   - the run-time check (option 6).

## 13. Risks

- **Compiler bugs at compile time.** `from_quote` with a `where` on a format, evaluated at compile
  time, is what roc-pg relies on. So it works at the pin, but this fork has had `boxy_lowering`
  crashes around formats (two in `test/compiler-bugs/`). Phase 3 starts with a reduced check
  (one `Rows` over a record holding `Db.Nullable`, a nominal and a list) before anything else.
  If it fails, phase 3 falls back to option 2 (rocx reads the types) and phase 2 is unaffected.
- **Annotations that can't be named in the check app**, such as a local alias, a type from a
  `where`, or a module rocx can't import. rocx emits only what it can name, and says why it
  skipped the rest.
- **Parsers written for `Json` alone** (rather than `parser_for : _` or any format) would make
  the check app fail to compile. None of the repo's row types has one. The skip message names the
  type.
- **Postgres without `CREATEDB`** (a managed database): see question 8.
- **Statements whose validity depends on the run** (a temporary table, a table a script makes).
  These need `Db.unchecked`, or a migration.

## 14. Open questions, each with a recommendation

1. **Who reads the row types?**
   (a) The compiler, through the generated check app, as §5 describes.
   (b) rocx, from the text.
   (c) Neither: check SQL and parameters only.
   *Recommended: (a)*, with (b) as the fallback if phase 3's first step shows the compiler can't
   do it at the pin. (a) is exact and follows D-037's pattern (rocx copies types, the compiler
   checks them); (b) duplicates the compiler in rocx.
2. **Where does it fail?**
   (a) `rocx check --sql` and `just examples` fail; `rocx dev` prints; `roc check`/`roc build`
   unchanged.
   (b) As (a), and later the app's own compile includes the checks, so `roc build` fails too.
   *Recommended: (a) now*, with (b) revisited once (a) has run clean on every example for a while
   and descriptions are cached.
3. **A plain field over a nullable column: error or warning?** *Recommended: an error.* It is the
   `BadRow` that would otherwise appear on the first null row in production. The way out is
   `coalesce`, a cast, or `Db.Nullable`. No `x!` column names (D-022).
4. **How does a statement opt out?**
   (a) `Db.unchecked(sql)`, an identity the scan sees.
   (b) A SQL comment (`/* unchecked */`).
   (c) Nothing: put the SQL in a variable.
   *Recommended: (a).* It is typed, greppable, documented, and costs nothing at run time. (c)
   happens to work, but it reads like an accident.
5. **Interpolated SQL.** *Recommended:* count it and list it with `--verbose` now. In phase 5,
   check it when every interpolated piece is a string constant of the module (notes' columns,
   uptime's). Helpers such as uptime's `${iso("at")}` stay unchecked.
6. **Which engines?**
   (a) The app's own engine only.
   (b) A SQLite app on Turso too, as warnings, since a `turso:` URL may run it there.
   *Recommended: (a)*, with `rocx check --sql --engine turso` to ask for (b) when wanted. On
   today's examples, (b) would warn about board's `json_group_array(… order by …)` and about
   notes' and plate's FTS5 migrations.
7. **Packages' SQL.** An app's check covers its own sources. *Recommended:* packages are checked
   on their own, by `just check` running `rocx check --sql` on each package's test app for every
   backend its plugin's `needs` allow. A statement passes if one of them prepares it, because a
   package's SQL is chosen by `Db.backend!`. An app doesn't re-check its packages.
8. **Postgres's scratch database.**
   (a) Made beside `DATABASE_URL` and dropped; without a URL, the Postgres check is skipped with a
   note.
   (b) The `DATABASE_URL` database itself, migrated as the server would at start, then described
   (sqlx's way).
   *Recommended: (a)*, falling back to (b) with a message when `create database` is refused.
9. **A committed description cache** (sqlx's `.sqlx/`), so a Postgres app's CI needs no
   database? *Recommended: not now.* SQLite and Turso need nothing, and every example runs on
   SQLite. Revisit when a Postgres app's CI has no database.
10. **The package's name and home.** *Recommended:* `packages/dbcheck`, pure Roc on no platform
    (D-025: it needs no host), named in the check app's header by rocx. The alternative is a
    platform module that apps never import.
11. **Scope of this task.** *Recommended:* build phases 2 to 4 now, and leave phase 5's items
    listed in TODO.md as decided but not built.

## Appendix: the spike

`describe/` is a Rust program (rusqlite with `column_metadata`, turso_core 0.8.4, tokio-postgres
0.7). It reads `{ engine, url?, migrations, statements }` on stdin, builds a database from the
migrations, prepares each statement, and prints what the engine said, with timings. `run.mjs`
finds each example's literal statements, its migrations, and the row types the text gives. It
runs the describer on SQLite and Turso and prints what a checker would report.

```sh
CARGO_TARGET_DIR=/tmp/describe cargo build --release --manifest-path spike/db-checked/describe/Cargo.toml
node spike/db-checked/run.mjs /tmp/describe/release/rocx-describe-spike          # every example
node spike/db-checked/run.mjs /tmp/describe/release/rocx-describe-spike plate    # one
```

Postgres was measured by hand with packages/jobs' migration and statements (`engine: "postgres"`,
`url` a server's `postgres` database; the describer makes and drops a database of its own).
