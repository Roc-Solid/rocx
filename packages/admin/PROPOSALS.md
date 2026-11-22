# Proposals: what the admin would like from outside its folder

The admin works today without any of these: every page, form and check in the README runs in a
scratch app on the server platform as it is. Each proposal below makes it simpler to use, or
removes a copy.

## Server-only modules in packages

**Problem.** `AdminPage.respond!` runs Postgres statements and draws random bytes, which are the
server platform's (`Db.all!`, `Db.run!`, `Random.bytes!`). A Roc package can name a platform only
if it is the app's own, and a Roc Solid app is two apps (the browser's on `web/platform`, the
server's on `server/platform`), so a package can't `import pf.Db`. Today the app hands the effects
in:

```roc
respond! = |{ request, context, .. }| AdminPage.respond!(request, context, admin, { all!: Db.all!, run!: Db.run!, random!: Random.bytes! })
```

That works, and is checked by the compiler, but every app writes the same record, the package can't
use what only the platform has (`AdminHtml`, below; `Log`, to note who changed what), and
`AdminPage` must keep every row the same shape so that one `Db.all!` reads them all.

**Options.**

1. Keep handing effects in (today's). Nothing to build; the seam shows in every app.
2. `rocx build` copies a package's `server/` folder (`.roc` and `.rocx` files) into the server's
   half only, as it copies `components/` into both: `packages/admin/server/AdminPage.roc` becomes
   `Generated/admin/AdminPage.roc` in the app, where `pf` is the server's platform and
   `import admin.X` is rewritten to the app's name for the package, line for line, with the marker.
   The browser's copy (`--client`) leaves them out.
3. A second package for the server's half (`packages/admin-server`, naming the server platform):
   the compiler refuses it unless its platform path is exactly the app's, which differs from app to
   app.
4. Move the admin into the platform (the next proposal but one).

**Recommended: 2.** A sketch, in `bin/rocx.mjs`, next to the copy of `components/`:

```js
// The package's server modules: the server's half only.
const serverDir = join(packageDir, "server");
if (!client && existsSync(serverDir)) {
	for (const file of files(serverDir, ".roc")) copyModule(file, join(dir, GENERATED, alias, basename(file)), { alias, packageName });
	for (const file of files(serverDir, ".rocx")) transpileInto(file, join(dir, GENERATED, alias, basename(file, ".rocx") + ".roc"), { alias, packageName });
}
```

and the import rewrite that `.rocx` files get for a package's components (`import charts.BarChart`
→ `import ../Generated/plots/Bars`) applied to the plain `.roc` route files too (`+server.roc`),
since that is where a server module is used. Then the package has:

```roc
# packages/admin/server/AdminPage.roc
import pf.AdminHtml
import pf.Db
import pf.Random
import pf.Server
import admin.Admin
…
respond! : Server.Request, context, Admin.Config(context) => Server.Response
```

and an app's route is `AdminPage.respond!(request, context, admin)`.

**What depends on it.** `AdminPage`'s `effects` argument (it would go), the README's route file,
and `Catalog.Row` (every statement answering with text cells could become ordinary typed records
where the shape is known: the catalog's, the count's).

**Undoing it.** Remove the copy step: packages go back to handing effects in, and `AdminPage` can
keep a `respond_with!(request, context, config, effects)` for that until then.

## The admin look in one place (done)

Was: the jobs page and the dev mailbox were drawn with the platform's `AdminHtml`, which packages
couldn't import, so `Look` held a copy of it and `test/packages.test.mjs` kept the two from
drifting. **Done with the plugins (D-033, D-034):** the jobs page and its look moved into this
package, and there is one look. `Look` holds it: the rules every admin page shares, part by part
(`Look.shared`), and the helpers (`side`, `nav_link`, `header`, `panel`, `empty`, `icon`,
`button_with`, `escape`). It stays on no platform, so a page in the browser can still show the
tables admin. `AdminHtml` (the server's pages: the jobs page, the dev mailbox) builds its stylesheet
from `Look.shared` and its own rules, and uses the same helpers. The copy and the guard are gone.

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
(`server/host/src/db.rs`): a `query_texts` that answers a JSON array of arrays of strings and
nulls, as `query` answers objects. `tokio_postgres` asks Postgres for binary results, so the host
either asks for text results at the protocol level, or does what the admin does now, in one place:
wraps the statement (`select array_to_json(array[…::text]) from (<statement>) as row`) once it
knows its columns from `prepare`. Any package that runs SQL it builds (a CSV export, an MCP tool
that queries) would use it.

**What depends on it.** `Sql.cells` and `Catalog.Row`: the statements would select the columns
themselves, and `Sql.text_of` would keep only its formatting of moments.

**Undoing it.** Remove `texts!`; the wrapping still works.

## The admin as a platform feature, next to the jobs page?

The task asked whether the admin is better as a platform module (`TablesPage.respond!(request,
context, config)`, as `JobsPage.respond!` is) than as a package.

**For the platform:** it would be one product by construction (the look, the docs, mounting it
like the jobs page); it could use what the platform keeps to itself (`AdminHtml`, the host's store
to cache the catalog between requests, a stream of changes from `LISTEN` to refresh a list); and
the app's route would need no effects.

**For a package:** nothing in it needs the host: its only effects are two `Db` calls and random
bytes; most of it (the catalog, the SQL, the widgets, the paging, the pages) is pure Roc with
`expect`s, which other packages can reuse (an export, an API generator); it is opinionated UI that
will change more often than the platform should; and an app that doesn't use it doesn't build it.
A platform can't share a package with the app either (its `Admin.Config` would be another type than
the app's), so a platform version would have to hold all of it.

**Recommended: a package**, with the two platform changes above (server-only modules, and
`AdminHtml` shared: the plugins design brings both). If server-only modules are turned down, the
next best is to move `AdminPage` and the modules it needs into `server/platform` as `TablesPage`,
keeping the package for the pure parts only where the platform doesn't need them.

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
  `Log.info!` (with server-only modules), or to a table of its own (a migration of the package's:
  packages can't bring migrations yet). Which, if any?
- **URLs.** Its pages are one path and a query (`/admin/db?table=books&k.id=7`), so an app needs one
  route file. With a rest param in routes (`routes/admin/db/[...rest]/+server.roc`), they could be
  `/admin/db/books/7`. Is that worth a routing feature?
