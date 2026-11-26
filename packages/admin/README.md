# admin

A Django-style admin for a Roc Solid app's tables, on Postgres or SQLite: an index of tables, each
table's rows with a search, a filter in every column, sorting and pages, and a form for each row to
add, change or delete it. It reads the tables from the database's own catalog on each request, so
there is no code to generate and nothing to keep in step with the schema. You mount it with one
route file, behind your app's own middleware.

The package also draws the jobs page (`JobsPage`, [below](#the-jobs-page)), a plugin that shows the
queue of packages/jobs. The docs site's page, `/ecosystem/admin`, shows the admin's pages rendered
from made-up tables.

```roc
# routes/admin/db/+server.roc
import pf.Db
import pf.Random
import pf.Server
import admin.Admin
import admin.AdminPage
import ../../../Middlewares

middleware = Middlewares.staff

respond! : { request : Server.Request, params : {}, context : { user : Str, staff : Bool } } => Server.Response
respond! = |{ request, context, .. }| AdminPage.respond!(request, context, admin, { all!: Db.all!, run!: Db.run!, random!: Random.bytes!, backend!: Db.backend! })

admin : Admin.Config({ user : Str, staff : Bool })
admin = {
    mount: "/admin/db",
    access: |context| if (context.staff) Edit else Refused,
    tables: [
        { name: "books", list: ["id", "title", "author_id", "state", "price"], search: ["title"], ordering: ["-published_at"] },
        { name: "authors", title: "name", hidden: ["password_hash"] },
        { name: "tags" },
    ],
}
```

## Setting it up

1. Name the package in the app's header (`main.roc`), by its directory's name:

   ```roc
   app [program] { admin: "../packages/admin/main.roc", pf: platform "…/server/platform/main.roc" }
   ```

   The package names the server platform (for the jobs page), so its `pf` must be the same platform
   file the app names. The browser's half of the app sees `browser.roc` instead, which lists only
   the modules that use no platform. The browser never compiles the admin itself, since nothing in
   the browser imports a `+server.roc`.

2. Add a route file at the path the admin should have (`routes/admin/db/+server.roc` is
   `/admin/db`), with a `respond!` that hands the request to `AdminPage.respond!`, as above. Set
   `mount` to that path. Every page is that path plus a query (`/admin/db?table=books&k.id=7`), so
   one route file is enough.

3. Hand it the effects it runs on: `{ all!: Db.all!, run!: Db.run!, random!: Random.bytes!, backend!: Db.backend! }`.
   `backend!` tells it whether the database is Postgres or SQLite, so it writes its statements for
   that one.

**Why the effects are handed in.** `AdminPage` and the modules it uses are plain Roc, on no
platform, so a page in either half of an app can import them (the docs site renders the admin's
pages that way). A module on no platform can't call `Db`, so the route passes the server platform's
effects, and the compiler checks that they fit.

## Who may use it

The route's middleware runs first, as it does for any route, so it can send a stranger to sign in.
Then `access` decides, from the context the middleware handed on:

| `access` says | Then |
|---|---|
| `Edit` | every page, and adding, changing and deleting rows |
| `ReadOnly` | the tables, rows and values; no forms |
| `Refused` | a 403, and nothing is read |

A form's POST must come from a page of the same site (its `Origin` header) and send back the token
its page was given. The admin keeps that token in a cookie, `rocx_admin_csrf` (`Path` the admin's
path, `HttpOnly`, `SameSite=Lax`). Any other POST is refused with a 403 before a table is read. The
admin answers GET, HEAD and POST; any other method is a 405.

## Pages

| Query | Page |
|---|---|
| (none) | the tables, each with roughly how many rows it has (Postgres's estimate; none on SQLite), its comment, and a link to add a row |
| `?table=books` | its rows, 50 a page (`page=2`), counted and paged by the database (`limit`, `offset`); a search box (`q=`), a filter under each column's heading (`has.title=dune`, `from.price=10`, `f.state=draft`, `is.mood=null`: [Filters](#filters)), and a sort when you click a column's heading (`sort=title`, `sort=-title`) |
| `?table=books&k.id=7` | a row's form; `k.<column>` for each column of its primary key, so a table whose key is two columns works too |
| `?table=books&new` | a new row's form, with its constant defaults filled in (`true`, `'draft'`, `0`) |
| `?table=books&k.id=7&delete` | the question before a row is deleted |

Every page is drawn in the admin look (`Look`), which the jobs page and the dev mailbox share: the
tables in a sidebar (a row of links across the top on a phone), a header with the page's actions
(Add, Delete), panels, light or dark to match the reader's system, and no script.

Sending a form adds, changes or deletes the row, then goes on to the row's page, which says
"Saved.". An update writes only the columns that changed. When the database refuses (a value that
isn't a number, a row that another row's foreign key still needs), the form comes back with what was
sent and the database's reason.

A table without a primary key is listed, but its rows can't be opened.

## Filters

Each column a table's list shows has a filter, in a row under the column headings. A hidden column
never has one. The column's type (as the catalog reports it; a generated column's too) picks the
filter:

| Column | Filter | Query |
|---|---|---|
| `text`, `varchar`, `uuid`, `json` and any other type | the text it contains, in any case (`ilike`; `%`, `_` and `\` match themselves) | `has.title=dune` |
| `smallint`, `integer`, `bigint`, `numeric`, `real`, `double precision` | from, to, or both, inclusive | `from.price=10&to.price=20` |
| `date`, `timestamp`, `timestamptz` (in UTC, as the admin shows it), `time` | from, to, or both, inclusive, with the browser's pickers | `from.published_at=2026-11-01T00:00` |
| `boolean` | a select: any, yes, no | `f.in_print=true` |
| an enum, a check that it is one of a few values, or a column given the `Choice` widget | a select of its values | `f.state=draft` |
| a foreign key | the value it equals | `f.author_id=2` |
| any of these, if it may be null | also empty (null) and not empty: in its select, or in a small select under its inputs | `is.mood=null`, `is.mood=set` |

The filters are one GET form, with no JavaScript. Enter in any of them sends it, and so does the
Filter button beside the search. Filtering keeps the search and the sort and starts again at the
first page; Clear filters drops every filter. The page links, a heading's sort and the search keep
the filters.

The query's rules, for building links by hand:

- `f.<column>=<value>` (equal) works for any column the list shows, and wins over the column's other
  filters.
- `is.<column>` is `null`, `set`, or a value the column equals (a select with empty and not empty
  among its values sends `is.mood=happy`). `null` replaces the column's other filters; `set` goes
  with them.
- `has.<column>` (contains) applies to a text-like column, `from.<column>` and `to.<column>` to a
  range's.
- A column the list doesn't show, or a search on a table with none, is ignored.

Each filter's value is checked in Roc before it reaches SQL: a number for a number (a whole one, in
its type's range, for an integer), `2026-11-21` for a date (one that exists), `2026-11-21T14:05`
(seconds optional) for a moment, `14:05` for a time, `true` or `false` for a boolean, a UUID's 36
characters, one of an enum's labels. A value of the wrong kind is ignored, and its filter says so
("Ignored: not a number"), so the page is never an error. A range's value is cast to its column's
type (`"price" >= $1::numeric`).

There is no option for which columns have a filter: every column the list shows has one, since
filtering a column the list shows reveals nothing a visitor can't see. To filter by a column, list
it.

## Options

`Admin.Config(context)`: only `mount` and `access` are required.

| Field | Default | What it is |
|---|---|---|
| `mount : Str` | (required) | the route's path |
| `access : context -> [Edit, ReadOnly, Refused]` | (required) | what someone may do, from the middleware's context |
| `tables : List(Admin.Table)` | `[]` | the tables it shows, in order, with their options |
| `include : [Listed, All]` | `Listed` | `Listed`: only those tables; `All`: every other table of the schema too, with default options, except the platform's own (`rocx_…`) |
| `schema : Str` | `"public"` | the Postgres schema (on SQLite it is always `main`) |
| `title : Str` | `"Database"` | what its pages call it |
| `back : { label : Str, href : Str }` | none (`href` `""`) | a link back to the app's own pages, first in every page's sidebar (`{ label: "Status admin", href: "/admin" }`) |

`Admin.Table`: only `name` is required. Columns are named as the table names them. A table in
`tables` the schema doesn't have, or a column a table's options name that it doesn't have, stops
the admin: its pages say what is wrong (a 500) and show nothing else until it is mended, since a
misspelt `hidden` would show the column it was meant to hide (`Admin.problems`).

| Field | Default | What it is |
|---|---|---|
| `name : Str` | (required) | the table |
| `label : Str` | its name, made readable (`book_tags`: "Book tags") | what the pages call it |
| `list : List(Str)` | its first seven columns | the columns of its list of rows, each with a filter ([Filters](#filters)) |
| `search : List(Str)` | none: no search box | where the search looks, for the text anywhere, in any case (`ilike`) |
| `ordering : List(Str)` | its key, newest first | the list's order, `-` for descending: `["-published_at", "title"]`; a click on a heading sorts by that column instead |
| `read_only : List(Str)` | none | shown on the form, never written |
| `hidden : List(Str)` | none | never read, shown or written: a password's hash |
| `labels : List((Str, Str))` | each column's name, made readable | `[("email", "Email address")]` |
| `title : Str` | its first text column that isn't its key, else its key | the column that names a row: its page's heading, and its name in a foreign key's select |
| `per_page : U64` | 50 | rows a page |
| `widgets : List((Str, Widget.Kind))` | the column's type's | another widget for a column: `[("body", LongText)]` |
| `create`, `delete : Bool` | `Bool.True` | whether rows may be added or deleted here |

## Widgets

A widget is the input a column gets on a row's form. By default the column's type picks it, as the
catalog reports the type (for a domain, its base type):

| Column | Widget | `Widget.Kind` |
|---|---|---|
| a foreign key to a table the admin shows | a select of that table's rows, by their `title` (an input, when it has more than 200), and a link to the row | `Reference({ table, column })` |
| an enum, or a check that it is one of a few values (`check (state in ('draft', 'sent'))`) | a select of them | `Choice(values)` |
| `boolean` | a checkbox; a select of yes, no and null when it may be null | `Checkbox`, `MaybeBool` |
| `smallint`, `integer`, `bigint` | a number | `Integer` |
| `numeric`, `real`, `double precision` | a decimal's input | `Decimal` |
| `date`, `timestamp`, `timestamptz`, `time` | the browser's pickers; a `timestamptz` in UTC | `Day`, `Moment`, `MomentUtc`, `TimeOfDay` |
| `json`, `jsonb` | a text area, in a monospace font | `Json` |
| `uuid` | an input of 36 characters | `Uuid` |
| `text`, `varchar(n)` and anything else | an input (`maxlength` for a `varchar(n)`), or a text area for a value of several lines or over 160 bytes; the database reads what is typed as the column's type | `Text` |
| generated columns, `bytea` | shown, never written | `ReadOnly` |

`LongText` (always a text area) is chosen only by the app, in a table's `widgets`.

An empty input is null for a column that may be null, and an empty text for a text column that may
not. In a new row, an empty input for a column with a default leaves the default to the database.

## Safe by construction

- A table or a column a request names is looked up in the catalog, among the tables and columns
  the app lets the admin show. Only the catalog's names are written into SQL, double-quoted
  (`Sql.ident`).
- Every value is a parameter (`$1`). A search's or a filter's `%` and `_` match themselves. A
  filter's value is checked in Roc first, and a range's is cast to its column's type, whose name
  comes from a fixed list (`::numeric`, `::date`, …), never from the catalog or the request.
- A hidden column is never selected.
- Pages are sent with `Content-Security-Policy: default-src 'none'` (no script, nothing loaded from
  elsewhere, forms only to this site), `X-Frame-Options: DENY` and `Cache-Control: no-store`, and
  every value is escaped.

## How it works

On each request, `AdminPage.respond!` checks `access` and the form's token, reads the catalog, then
draws the page or runs the form.

- **The catalog.** On Postgres, four small statements over `pg_catalog`; on SQLite,
  `pragma_table_list`, `pragma_table_xinfo`, `pragma_foreign_key_list`, and each table's
  `create table` for its checks. `Catalog.read` (`Catalog.read_sqlite`) turns the answers into
  tables: columns and types, which may be null or have defaults, primary keys, foreign keys, enums,
  and the values a check allows.
- **On SQLite**, a column's declared type is read as Postgres would name it (`integer` as `int8`,
  `real` as `float8`, `boolean` as `bool`, `json`, `date`, `timestamp`), so it gets the same widget
  and filter. A boolean is written as 1 or 0, and tables have no row estimate and no comment.
- **One shape of row.** Every statement answers with rows of one shape (each cell as text, plus
  which were null: `Catalog.Row`), so one `Db.all!` reads them all, whatever the table.
- **A list** is two statements built by `Sql`: the count, then the page's rows. A cell in a list is
  cut to 81 characters by the database (so the page can tell it was cut); a key never is.

## The jobs page

`JobsPage` draws the queue of packages/jobs as a console: how many jobs are in each state, what
finished in the last hour, the latest failures, each kind, the schedules, and the jobs, each in a
drawer, with retry, cancel and run now as plain forms. packages/jobs's README and the docs site's
`/ecosystem/jobs#page` describe what it shows.

It is a plugin, behind a `guard` the app gives it: the middleware that decides who may see it.
`guard` has no default, so a jobs page is never public because an option was left out. Leaving it
out doesn't compile ("This record is missing these fields: … guard"; the compiler lists the fields
with a default too).

```roc
plugins: [
    Job.plugin({ jobs: App.jobs }),
    JobsPage.plugin({ at: "/admin/jobs", guard: Middlewares.admin }),   # at: "/admin/jobs" unless it says
]
```

| Option | Default | What it is |
|---|---|---|
| `at : Str` | `"/admin/jobs"` | where the page is |
| `guard : Middleware(ctx, out)` | (required) | runs after the app's middleware, and may refuse or send a stranger to sign in; what it hands on isn't used |
| `back : { label : Str, href : Str }` | none | a link back to the app's own pages, first in the page's sidebar |

```roc
JobsPage.plugin({ guard: Middlewares.admin, back: { label: "Status admin", href: "/admin" } })
```

The plugin adds a GET route (HEAD too) and a POST route at `at`. They are pages, not endpoints, so
they aren't in the app's `/openapi.json`. It needs the jobs plugin (`needs: [Plugin("jobs")]`): the
server refuses to start without it.

To mount the page yourself, answer a route with `JobsPage.respond!(request, { mount, back })`
(`back` is optional). It answers GET, HEAD and POST, and any other method with a 405:

```roc
# routes/admin/jobs/+server.roc
import admin.JobsPage
import ../../../Middlewares

middleware = Middlewares.admin

respond! = |{ request, .. }| JobsPage.respond!(request, { mount: "/admin/jobs" })   # and back, as above
```

## One look

The tables admin, the jobs page and the dev mailbox (packages/email) share one look. `Look` has it,
on no platform: the rules every admin page shares, part by part (`Look.shared`: tokens for light
and dark, the shell, the header, panels, tables, buttons, an empty panel, narrow screens), and the
helpers (`side`, `nav_link`, `back_link`, `nav_label`, `header`, `panel`, `empty`, `icon`, `button`,
`button_with`, `escape`). The tables admin's stylesheet is the shared rules plus its own. `AdminHtml`
(server only) draws the server's pages with the shared rules among theirs, plus a few lines of
script: a stream of changes that refreshes the page, times that count on, and Escape to close a
drawer. Without script the page is the same, with a button that refreshes it.

## Modules

`AdminPage` is the one module with effects, and they are the ones the route hands it. `JobsPage` and
`AdminHtml` run on the server platform. The others are plain Roc: `roc test packages/admin/main.roc`
runs their `expect`s.

| Module | What it does |
|---|---|
| `Admin` | the options (`Config`, `Table`, `Access`), and what they mean for a table: `showing`, `listed`, `searchable`, `writable`, `title`, `ordering`, `widget` |
| `AdminPage` | `respond!(request, context, config, effects)`: the access check, the token, the catalog, then the page or the form; `Effects`, what the route hands it |
| `Catalog` | the statements that read the schema from `pg_catalog` (or SQLite's pragmas), and `read` (`read_sqlite`): their rows as tables, columns, keys, foreign keys, enums and a check's values |
| `Sql` | `ident` (a quoted name), `contains` (a search's or a filter's pattern), the conditions (`Equals`, `IsNull`, `NotNull`, `Contains`, `AtLeast`, `AtMost`, `Search`), and the statements: `rows`, `count`, `one`, `insert`, `update`, `delete`, `titles` |
| `Widget` | `Kind`; a column's widget from its type (`of`), its input (`input`), what a form's text writes (`param`), whether it changed (`same`), a new row's value (`initial`) |
| `Listing` | a list's search, filters, sort and page, read from the query and written back (`read`, `params`, `conditions`, `order`); each column's filter (`kind`) and the check of its values (`check`) |
| `Paging` | `of(total, size, asked)`, `offset`, `shows`, `links` (Django's: the first two, three each side, the last two) |
| `View` | each page's HTML (`index_page`, `list_page`, `row_page`, `delete_page`, `problem_page`), a list's row of filters, and the sidebar of tables (`side`) |
| `Look` | the admin look (`shared`, the rules every admin page shares, and the helpers), the tables admin's own rules, its `document` and its `headers` |
| `Form` | a query's or a form's fields, decoded; links, encoded |
| `JobsPage` | the jobs page (server only): `plugin({ at, guard, back })`, or `respond!(request, { mount, back })` |
| `AdminHtml` | the server's admin pages (the jobs page, the dev mailbox), on `Look`: a page, a stream of changes, times, links (server only) |

## Tests

Besides the `expect`s, the server's tests drive the admin over HTTP on Postgres and on SQLite
(`server/test/admin-checks.mjs`): the index, a new row's form (a check's values and a foreign key's
rows as choices, a boolean as a checkbox), a row created, shown, found by a search and a filter,
changed and deleted, each form sent with its cookie's token. They test the jobs page's forms behind
a guard too.

## Limits, for now

- A list counts its rows (`count(*)`) and pages with `offset`: fine for thousands of rows, slow for
  millions.
- A foreign key shows its value in a list, not the row's title; its filter takes a value.
- A filter on the text a column contains reads every row (`ilike '%…%'` uses no index), as the
  search does.
- A foreign key or a check over several columns gives no widget; each column is edited alone.
- No actions on several rows at once, and no history of changes.
- The catalog is read on each request (four small statements on Postgres).
- Every route passes the effects. `AdminPage` could take `Db` itself in a server-only module, and a
  route would be `AdminPage.respond!(request, context, admin)`; PROPOSALS.md weighs it.
