# dbcheck

An app's rows checked against what its database says of each statement, when the app is compiled
(D-058). `rocx check --sql` uses it; an app doesn't import it. Plain Roc, on no platform.

## How it is used

`rocx check --sql <app>` (and `rocx dev`, after each build) has the app's own server describe each
`Db.all!` and `Db.run!` whose SQL is a string literal, on a scratch database built from its
migrations. Then it writes a small app of its own, `build/sql/check/main.roc`, beside a copy of the
app's sources. For each `Db.all!` whose row type rocx can read from its annotation, that app has a
line like this:

```roc
## examples/plate/Store.roc:122:11
q1 : DbCheck.Rows({ id : I64, fiber : Db.Nullable(Dec) }, Tags)
q1 = "examples/plate/Store.roc:122:11\tsqlite\nid\tinteger\tINTEGER\tfoods.id\tyes\nfiber\treal\tREAL\tfoods.fiber\tno"
```

`roc check` compiles that app. The compiler runs `DbCheck.Rows.from_quote` on each string, at
compile time:

- The row type's shape is read through its parser, with `Probe`, a format that reads nothing. It
  gives each field's name, what its type reads (an integer, a number, text, a `Bool`, a tag union,
  or a record or list), and whether it tries null first, as `Db.Nullable(a)` does.
- That shape is compared with the columns the engine described.
- A mismatch is the string's compile error. rocx reads it and reports it at the call.

The row type is named by the compiler, as written or behind an alias, so the check needs no Roc
type reader of its own. The engine names the columns, so it needs no SQL parser either.

## What it refuses

- **A field the statement doesn't return.** The message lists the columns it does return.
- **A type the column's values can't decode into**, as the host reads each column into JSON:
  - integers decode into any integer type, `Dec`, `F32` or `F64`;
  - reals decode into `Dec`, `F32` or `F64`;
  - text decodes into `Str` or a tag union;
  - booleans decode into `Bool`;
  - JSON decodes into anything.

  A SQLite column of no recognised affinity (`numeric`, `date`) stores whatever was written, so
  anything goes. A blob, or a Postgres type the host can't read (`numeric`, arrays), is refused
  with the cast that reads it.
- **A plain field over a column that may be null**: a table's column without `not null`. Such a
  field is read as `Db.Nullable(a)`, or its column is made an expression (`coalesce(note, '')`).
  `Db.Nullable` over a `not null` column is fine.

## What it can't see

- An expression's type, on SQLite (Postgres types every expression).
- Whether a column from the outer side of a `left join` may be null: the engine reports the
  table column's `not null`.
- A row type behind a tag union none of the app's capitalized words is a tag of. Such a row isn't
  checked.

The other gaps are rocx's, listed in `server/README.md`: interpolated SQL, SQL in a variable, a row
type it can't read from the annotation.

## Modules

- `DbCheck`:
  - `Rows(rows, tags)`, the check, whose `from_quote` the compiler runs;
  - `description`, which reads rocx's text;
  - `problems`, the rules (with `fits`, `reads`, `holds`).
- `Probe`: the format, in two passes. `Nulls` answers every `parse_null` with "null" and `Kinds`
  with "not null", as roc-pg's `RowFormat` does. Its `State` carries the names a tag union is tried
  with.

`roc test packages/dbcheck/main.roc` runs the rules' expects; `test/check-sql.test.mjs` runs the
whole check on an app wrong on purpose (`test/sql-check`).
