# Proposals: what the admin would like next

The admin works today without any of these: every page, form and check in the README runs on the
server platform as it is. Each proposal below makes it simpler to use.

## `AdminPage` taking `Db` itself

**Status (2026-11-28).** Open, and small now. A package may name the server platform since D-033,
and list the modules the browser can compile in `browser.roc`. This one does, for the jobs page
(D-034). `AdminPage` stays on no platform, its effects handed in, so a page in the browser can still
show the tables admin (the docs site does).

**Problem.** Every route hands the same record in:

```roc
respond! = |{ request, context, .. }| AdminPage.respond!(request, context, admin, { all!: Db.all!, run!: Db.run!, random!: Random.bytes!, backend!: Db.backend! })
```

It is checked by the compiler, but every app writes it, and `AdminPage` can't use what only the
server has (`Log`, to note who changed what).

**Proposal.** A server-only module beside `JobsPage` (in `main.roc`, not in `browser.roc`), say
`AdminRoute.respond!(request, context, config)`, which calls `AdminPage.respond!` with the server's
effects. `AdminPage` keeps its four arguments for a page that shows the admin without a server.
Nothing outside this package changes.

**What depends on it.** The README's route file, and the docs site's admin page.

## Rows of any shape from `Db`

**Problem.** `Db.all!` decodes each row into a record the caller names, which an admin can't: its
tables are known when the request comes. The admin wraps every statement's columns in
`array_to_json(array[coalesce(x::text, ''), …]) as "cells", array_to_json(array[x is null, …]) as
"nulls"`, which works for every type (each is cast to text), but every statement it builds has to
be written that way.

**Options.**

1. Keep the wrapping (today's).
2. `Db.texts! : Str, List(Value) => Try(List(List([Null, Text(Str)])), [DbErr(Str)])`: each row's
   columns in order, as Postgres's text output (the host asks for the text format, so any type is
   read, with no cast).
3. `Db.all!` with a `Dict(Str, …)` row: the compiler's `Json` decoding would need a dynamic value
   type first.

**Recommended: 2**, in `server/platform/Db.roc` beside `all!`, and in the host
(`server/host/src/db/`: Postgres, SQLite and Turso): a `query_texts` that answers a JSON array of
arrays of strings and nulls, as `query` answers objects. On Postgres, `tokio_postgres` asks for
binary results, so the host
either asks for text results at the protocol level, or does what the admin does now, in one place:
wraps the statement (`select array_to_json(array[…::text]) from (<statement>) as row`) once it
knows its columns from `prepare`. Any package that runs SQL it builds (a CSV export, an MCP tool
that queries) would use it.

**What depends on it.** `Sql.cells` and `Catalog.Row`: the statements would select the columns
themselves, and `Sql.text_of` would keep only its formatting of moments.

**Undoing it.** Remove `texts!`; the wrapping still works.

## Settled

- **One admin look** (D-033, D-034): the jobs page and its look moved into this package. `Look`
  holds the rules every admin page shares and the helpers; `AdminHtml` (the jobs page, the dev
  mailbox) builds on it. The copy and the guard that kept two looks in step are gone.
- **A package, not a platform feature** (D-034): nothing in the admin needs the host, most of it is
  pure Roc with `expect`s, and an app that doesn't use it doesn't build it. The jobs page moved here,
  not the admin into the platform.

## Open questions

- **Which tables by default.** `include` is `Listed` unless the app says `All`, so a table of
  passwords or tokens never shows by accident. Django's admin is the same (only registered models).
  Should `All` be the default instead, for a quicker start?
- **Counting rows.** A list counts its rows exactly (`count(*)`) and pages with `offset`. For very
  large tables, keyset paging and Postgres's estimate would be faster but say "about 1.2M rows" and
  only offer next and previous. Wanted now, or when an app needs it?
- **A foreign key in a list.** It shows the value (`author_id` 1, a link to the author), not the
  author's name; showing names costs a join for each foreign key. Worth it by default?
- **History.** Django's admin keeps a log of who changed what. The admin could write one through
  `Log.info!` (with `AdminPage` taking `Db` itself, above), or to a table of its own (a migration of the package's,
  which a plugin can bring now, as packages/jobs does; the admin would have to become one). Which,
  if any?
- **URLs.** Its pages are one path and a query (`/admin/db?table=books&k.id=7`), so an app needs one
  route file. With a rest param in routes (`routes/admin/db/[...rest]/+server.roc`), they could be
  `/admin/db/books/7`. Is that worth a routing feature?
