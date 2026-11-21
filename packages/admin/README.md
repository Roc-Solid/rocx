# admin

A Django-style admin for a Roc Solid app's Postgres tables: an index of tables, each table's rows
with search, filters, sorting and pages, a form for each row, adding and deleting rows. It reads
the tables from Postgres's catalog when a page is asked for, so there is nothing to generate and
nothing to keep in step with the schema. It looks like the platform's jobs page and dev mailbox,
and is mounted the same way: one route file, behind the app's own middleware.

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
respond! = |{ request, context, .. }| AdminPage.respond!(request, context, admin, { all!: Db.all!, run!: Db.run!, random!: Random.bytes! })

admin : Admin.Config({ user : Str, staff : Bool })
admin = {
    mount: "/admin/db",
    access: |context| if (context.staff) Edit else Refused,
    tables: [
        { name: "books", list: ["id", "title", "author_id", "state", "price"], search: ["title"], filters: ["state", "author_id"], ordering: ["-published_at"] },
        { name: "authors", title: "name", hidden: ["password_hash"] },
        { name: "tags" },
    ],
}
```

## Setting it up

1. Name the package in the app's server header (`main.roc`), by its directory's name:

   ```roc
   app [program] { admin: "../packages/admin/main.roc", pf: platform "…/server/platform/main.roc" }
   ```

   The browser's half names it too (`rocx build --client` copies the header's packages), and never
   compiles the admin: the browser's routes don't import a `+server.roc`.

2. Add a route file at the path the admin is to have (`routes/admin/db/+server.roc` is
   `/admin/db`), with a `respond!` that hands the request to `AdminPage.respond!`, as above. Its
   `mount` is that path. Its pages are that path and a query (`/admin/db?table=books&k.id=7`), so one
   route file is all it takes.

3. Hand it the three effects it runs on: `{ all!: Db.all!, run!: Db.run!, random!: Random.bytes! }`.
   A Roc package can't import a platform's modules (the compiler lets a package name a platform
   only if it is the app's own, and a Roc Solid app is two apps), so the app passes them in.

## Who may use it

The route's middleware runs first, as it does for any route: it can send a stranger to sign in. Then
`access` decides from the context the middleware handed on:

| `access` says | |
|---|---|
| `Edit` | sees every page, and adds, changes and deletes rows |
| `ReadOnly` | sees the tables, rows and values; no forms |
| `Refused` | a 403, and nothing is read |

A form's POST must come from a page of the same site (its `Origin`) and send back the token the page
was given, which the admin keeps in a cookie (`rocx_admin_csrf`: for the admin's path only,
`HttpOnly`, `SameSite=Lax`). Anything else is refused with a 403, before a table is looked at.

## Pages

| Query | Page |
|---|---|
| (none) | the tables, each with about how many rows it has (Postgres's estimate), its comment, and a link to add a row |
| `?table=books` | its rows, 50 a page (`page=2`), counted and paged in Postgres (`limit`, `offset`); a search box (`q=`), filters beside the list (`f.state=draft`, `is.mood=null`, `is.mood=set`), and a click on a column's heading sorts by it (`sort=title`, `sort=-title`) |
| `?table=books&k.id=7` | a row's form; `k.<column>` for each column of its primary key, so a table whose key is two columns works too |
| `?table=books&new` | a new row's form, its constant defaults filled in (`true`, `'draft'`, `0`) |
| `?table=books&k.id=7&delete` | the question before a row is deleted |

A form sent adds, changes or deletes the row, then goes on to its page, which says so ("Saved.").
An update writes only the columns that changed. When Postgres refuses (a value that isn't a number,
a foreign key a row still needs), the form comes back with what was sent and Postgres's reason.

A table without a primary key is listed, not opened.

## Options

`Admin.Config(context)`: only `mount` and `access` are needed.

| Field | |
|---|---|
| `mount : Str` | the route's path |
| `access : context -> [Edit, ReadOnly, Refused]` | what someone may do, from the middleware's context |
| `tables : List(Admin.Table)` | the tables it shows, in order, with their options |
| `include : [Listed, All]` | `Listed` (the default): only those; `All`: every other table of the schema too, with no options, but the platform's own (`rocx_…`) |
| `schema : Str` | `"public"` |
| `title : Str` | what its pages call it: `"Database"` |

`Admin.Table`: only `name` is needed. Columns are named as the table names them; a name it doesn't
have is ignored.

| Field | Default | |
|---|---|---|
| `name : Str` | | the table |
| `label : Str` | its name, readable (`book_tags`: "Book tags") | what the pages call it |
| `list : List(Str)` | its first seven columns | the columns of its list of rows |
| `search : List(Str)` | none: no search box | where the search looks, for the text anywhere in any case (`ilike`) |
| `filters : List(Str)` | none | a filter for each: a boolean's yes and no, an enum's or a check's values, or the values the column has (the first 50); null and not null for a column that may be null |
| `ordering : List(Str)` | its key, newest first | the list's order: `["-published_at", "title"]` |
| `read_only : List(Str)` | | shown on the form, never written |
| `hidden : List(Str)` | | never read, shown or written: a password's hash |
| `labels : List((Str, Str))` | each column's name, readable | `[("email", "Email address")]` |
| `title : Str` | its first text column that isn't its key | the column that names a row: its page's heading, and its name in a foreign key's select |
| `per_page : U64` | 50 | |
| `widgets : List((Str, Widget.Kind))` | from the column's type | `[("body", LongText)]` |
| `create`, `delete : Bool` | `Bool.True` | whether rows may be added or deleted here |

## Widgets

Chosen from the column's type, as the catalog says it (a domain's, its base type's):

| Column | Widget |
|---|---|
| a foreign key to a table the admin shows | a select of that table's rows, by their `title` (an input, when it has more than 200), and a link to the row |
| an enum; a check that it is one of a few values (`check (state in ('draft', 'sent'))`) | a select of them |
| `boolean` | a checkbox; a select of yes, no and null when it may be null |
| `smallint`, `integer`, `bigint` | a number |
| `numeric`, `real`, `double precision` | a decimal's input |
| `date`, `timestamp`, `timestamptz`, `time` | the browser's pickers; a `timestamptz` in UTC |
| `json`, `jsonb` | a text area, in a monospace font |
| `uuid` | an input |
| `text`, `varchar(n)` and anything else | an input (`maxlength` for a `varchar(n)`), a text area for a value of several lines; Postgres reads what is typed as the column's type |
| generated columns, `bytea` | shown, never written |

An empty input is null for a column that may be null, an empty text for a text that may not, and,
in a new row, the column's default for a column that has one.

## Safe by construction

- A table or a column a request names is looked up in the catalog, among the tables and columns
  the app lets the admin show; only the catalog's names are written into SQL, double-quoted.
- Every value is a parameter (`$1`); a search's `%` and `_` are matched as themselves.
- A hidden column is never selected.
- Pages are sent with `Content-Security-Policy: default-src 'none'` (no script, nothing loaded from
  elsewhere, forms only to this site), `X-Frame-Options: DENY` and `Cache-Control: no-store`, and
  every value is escaped.

## Modules

`AdminPage` is the one with effects. The others are plain Roc, and `roc test
packages/admin/main.roc` runs their `expect`s.

| Module | What it does |
|---|---|
| `Admin` | the options (`Config`, `Table`, `Access`), and what they mean for a table: `showing`, `listed`, `searchable`, `filterable`, `writable`, `title`, `ordering`, `widget` |
| `AdminPage` | `respond!(request, context, config, effects)`: the access check, the token, the catalog, then the page or the form |
| `Catalog` | the statements that read the schema from `pg_catalog`, and `Catalog.read`, their rows as tables, columns, keys, foreign keys, enums and a check's values |
| `Sql` | `ident` (a quoted name), `contains` (a search's pattern), and the statements: `rows`, `count`, `one`, `insert`, `update`, `delete`, `distinct`, `titles` |
| `Widget` | a column's widget from its type (`of`), its input (`input`), what a form's text writes (`param`), whether it changed (`same`), a new row's value (`initial`) |
| `Listing` | a list's search, filters, sort and page from the query, and back (`read`, `params`, `conditions`, `order`) |
| `Paging` | `of(total, size, asked)`, `offset`, `shows`, `links` (Django's: the first two, three each side, the last two) |
| `View` | each page's HTML |
| `Look` | the page around it: the jobs page's stylesheet, and the headers |
| `Form` | a query's or a form's fields, decoded; links, encoded |

Every statement answers with rows of one shape (each cell as text, and which were null), so one
`Db.all!` reads them all, whatever the table.

## Status

Works today, without any change to the platform: everything above, proved in a scratch app against
Postgres 18 (`/tmp/rocx-pkg-admin`: a schema with an enum, a check, foreign keys, a composite key,
generated and identity columns, and 137 rows; an end-to-end test of every page and form).

Waits on a proposal (PROPOSALS.md):

- **Server-only modules in packages**: then `AdminPage` moves to the package's `server/`, imports
  `Db` and `Random` itself, and the route's `respond!` is
  `AdminPage.respond!(request, context, admin)`.
- **The platform's admin look for apps** (`AdminHtml`): `Look` is a copy of its stylesheet today.

## Limits, for now

- A list counts its rows (`count(*)`) and pages with `offset`: fine for thousands of rows, slow for
  millions.
- A foreign key shows its value in a list, not the row's title; its filter lists values.
- A foreign key or a check over several columns gives no widget; each column is edited alone.
- No actions on several rows at once, and no history of changes.
- The catalog is read for each request (four small statements).
