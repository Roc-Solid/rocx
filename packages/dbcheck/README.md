# dbcheck

dbcheck checks an app's row types against what its database says each SQL statement returns, at
compile time. `rocx check --sql` uses it, and so does `rocx dev` after each build. An app never
imports it. It is plain Roc on no platform.

For example, if a page reads `Db.all!("select id, note from notes", [])` into
`List({ id : I64, note : Str })` and `notes.note` has no `not null`, the check fails at that call:
the column may be null, so the field has to be `Db.Nullable(Str)`.

The design is D-058 in `DECISIONS.md`.

## How it is used

1. **rocx finds the statements.** `rocx check --sql <app>` finds each `Db.all!`, `Db.one!` and
   `Db.run!` whose SQL is a string literal at the call.
2. **The database describes them.** The app's own server, built as `rocx dev` builds it, prepares
   each statement on a scratch database migrated from the app's migrations, and reports its
   parameters and columns (`--describe-sql`). rocx reports a statement the engine refuses, or a call
   whose parameters don't match, itself; that part doesn't involve dbcheck.
3. **rocx writes a check app.** It writes `build/sql/check/main.roc` beside a copy of the app's
   sources. For each `Db.all!` or `Db.one!` whose row type rocx can read from its annotation
   (`rows : List(T)`; `row : T` or `Try(T, …)` for `one!`), that app has a constant like this:

   ```roc
   ## examples/plate/Store.roc:122:11
   q1 : DbCheck.Rows({ id : I64, fiber : Db.Nullable(Dec) }, Tags)
   q1 = "examples/plate/Store.roc:122:11\tsqlite\nid\tinteger\tINTEGER\tfoods.id\tyes\nfiber\treal\tREAL\tfoods.fiber\tno"
   ```

   The string is what the engine said: the call's place and the engine on the first line, then one
   line per column with its name, kind, declared type, table column, and whether that column is
   `not null`, separated by tabs.
4. **The compiler checks each row.** `roc check` compiles the check app, and the compiler runs
   `DbCheck.Rows.from_quote` on each string at compile time:
   - It reads the row type's shape through the type's own parser, using `Probe`, a format that
     reads nothing. That gives each field's name, what its type reads (an integer, a number, text,
     a `Bool`, a tag union, or a record or list), and whether it tries null first, as
     `Db.Nullable(a)` does.
   - It compares that shape with the columns the engine described.
   - A mismatch becomes that constant's compile error. rocx reads the error and reports it at the
     call, in the app's own file.

The compiler resolves the row type, as written or behind an alias, so the check needs no Roc type
reader of its own. The engine names the columns, so it needs no SQL parser either.

## What it refuses

- **A field the statement doesn't return.** The message lists the columns it does return.
- **A field type the column's values can't decode into.** The host reads each column into JSON, and
  the field's type has to decode that:
  - an integer column decodes into any integer type, `Dec`, `F32` or `F64`;
  - a real column decodes into `Dec`, `F32` or `F64`;
  - a text column decodes into `Str` or a tag union;
  - a boolean column decodes into `Bool`;
  - a JSON column decodes into anything.

  A SQLite column with no recognised affinity (`numeric`, `date`) stores whatever was written, so
  any field type passes. A blob, or a Postgres type the host can't read (`numeric`, arrays), is
  refused with the cast that makes it readable: `hex(…)` on SQLite, `::text` on Postgres.
- **A plain field over a column that may be null**, that is a table column without `not null`.
  Read such a field as `Db.Nullable(a)`, or turn the column into an expression that can't be null
  (`coalesce(note, '')`). `Db.Nullable` over a `not null` column is fine.

## What it can't see

- An expression's type on SQLite. Postgres types every expression; SQLite reports a type only for a
  column taken straight from a table, so an expression column passes.
- Whether a column from the outer side of a `left join` may be null. The engine reports the table
  column's `not null`, which doesn't account for the join.
- A row with a tag union whose tags aren't among the app's capitalized words. The probe tries those
  words as tag names; if none of them is one of the union's tags, the row isn't checked.

The other gaps are rocx's, listed in `server/README.md`: SQL built by interpolation (`${…}`), SQL
passed in a variable, and a row type rocx can't read from the annotation. `rocx check --sql` counts
what it couldn't check.

## Modules

`main.roc` exposes two modules.

- **`DbCheck`**
  - `Rows(rows, tags)`: the check. `from_quote : Str -> Try(Rows(rows, tags), [BadQuotedBytes(Str)])`
    is what the compiler runs; `at` is where the call is. `tags` supplies `names`, the words a tag
    union is tried with (the check app's `Tags`).
  - `Column` and `Description`: a column and a statement as the engine described them, and
    `description : Str -> Description`, which reads rocx's text.
  - `problems : List(Probe.Field), List(Column), Str -> List(Str)`: the rules, one message per
    problem. `fits` says whether a field kind decodes a column kind; `reads`, `holds` and `article`
    word the messages.
- **`Probe`**: the format. Roc has no reflection, but a derived parser works with any format and asks
  for what each field's type needs (`parse_i64`, `parse_str`, a record, a list). `Probe` answers
  every request with nothing and notes what was asked. It runs in two passes, as roc-pg's
  `RowFormat` does: `Nulls` answers every `parse_null` with "null", which finds the fields that try
  null first; `Kinds` answers "not null", so the parser goes on to the inner type. `State` carries
  the names a tag union is tried with; `Field` is what the probe learns about each field.

## Tests

- `roc test packages/dbcheck/main.roc` runs the rules' expects (`just test` runs every package's).
- `test/check-sql.test.mjs` runs the whole check on an app that is wrong on purpose
  (`test/sql-check`).
