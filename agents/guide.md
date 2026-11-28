# Working on a Roc Solid app

A guide for coding agents (and people) working on an app built with Roc Solid and its command,
`rocx`. It ships with each version, so it describes the one at `.rocx/`, which the app builds
with. It says how an app is laid out, the rules that keep it working, and where the details are:

- `.rocx/web/README.md`: components, reactivity, forms, navigation, the browser's runtime;
- `.rocx/server/README.md`: endpoints, the database, settings, plugins, live data, running;
- `.rocx/packages/<name>/README.md`: each package (auth, jobs, email, storage, ai, testing…);
- the platform's modules, `.rocx/server/platform/*.roc`: every function's comment says what it does;
- the guide online, https://roc-solid.github.io/, for the latest version (this file is the app's).

`rocx agents` writes a short block of these rules into the app's AGENTS.md, and rewrites it when
rocx changes. Write the app's own notes outside that block.

## What's where

| Path | What it is |
| --- | --- |
| `main.roc` | The program: `App.program({ init!, plugins, … })`; the database it names (SQLite's `data/app.db` unless it says otherwise) |
| `routes/` | Pages (`+page.rocx`), endpoints (`+server.roc`), layouts (`+layout.rocx`), the error page (`+error.rocx`), middleware (`+middleware.roc`) |
| `components/`, other folders | `.rocx` components and plain `.roc` modules, imported by relative path |
| `migrations/*.sql` | The app's tables, run in order at start, each once |
| `static/` | Files served as they are |
| `Generated/` | Written by rocx (routes, `Api`, `Paths`, `App`, styles): never edit, never commit |
| `components/*.roc` beside a `.rocx` | Written by rocx from the `.rocx`: edit the `.rocx` |
| `.rocx/`, `.rocx-version` | The rocx the app builds with (a link, not committed), and its version (committed) |

## Commands

- `rocx dev`: serves the app at http://localhost:8080 under `--dev`, rebuilt and reloaded as you
  save, its SQL checked after each start. It passes the folder's `.env` to the server.
- `rocx check`: rocx's own checks, then the compiler on the server's program and the browser's;
  each problem is reported at its `.rocx` line. Exit 1 on an error, 2 on warnings alone. Run it
  before saying a change is done. `rocx check --sql` checks the SQL against the app's engine
  (`rocx check --sql -- --env-file .env` for the settings in `.env`).
- `rocx test`: the app's `expect`s. HTTP and browser tests use packages/testing.
- `rocx fmt <paths>`: formats `.roc` and `.rocx` files; `--check` only reports.
- `rocx routes`: every route with its methods and the middleware around it; `--server` lists only
  the endpoints, `--client` only the pages.
- `rocx build`: the release in `dist/`; `--image` a container image; `--static` plain files.
- `rocx generate`: writes `Generated/` and the browser's copy without building, for editors.
- `rocx agents`: rewrites the rocx block in AGENTS.md (this guide's summary).

## Routes

- A folder is a path part; `[id]` is a param; `(name)` is a group, which adds nothing to the path
  and gives its files a `+middleware.roc` and a `+layout.rocx` of their own.
- **A path is a page or an endpoint, not both.** A page's data and its forms' actions live at the
  same path under `routes/api/`: the page `routes/lists/[id]/+page.rocx` reads
  `routes/api/lists/[id]/+server.roc` (`Api.get_api_lists_id`) and its forms post there.
  Endpoints whose URL is fixed by someone else (a webhook, an OAuth callback, `/.well-known/…`)
  stay where their URL must be.
- Params are `Str` unless a type says otherwise: a handler's `params : { id : I64 }`, and a page's
  own `Params : { id : I64 }` alias. Nothing is read across folders, so a page and its endpoint
  under `api/` each say the type. A path part that doesn't read as its type is a 404 before
  anything runs.
- Links use `Paths` (`Paths.lists_id({ id })`), which rocx writes from the routes: a wrong param
  doesn't compile.

## Endpoints

A `+server.roc` has a handler per method: `get!`, `post!`, `put!`, `patch!`, `delete!`; `events!`
for a stream of events; `channel!` for a live channel. Every handler is annotated; rocx copies the
types into `Generated/Api`, the contract both programs use, so an annotation it can't read, or a
type defined in the route file itself, is refused (put the type in a module of its own).

```roc
get! : { request : Server.Request, params : { id : I64 }, context : Gate.Member } => Try(Report, Endpoint.Refusal)
post! : { request : Server.Request, params : {}, context : Gate.Member, body : { name : Str } } => Try(Str, Endpoint.Refusal)
```

- `Ok(value)` is sent as JSON. A refusal is `BadRequest(why)`, `Unauthorized`, `Forbidden`,
  `NotFound`, `Conflict(why)`, `Status(code, why)` or `Json(code, json)` (a form's issues).
- **An answer of its own**: a handler whose every success is a response it makes (a file, a
  redirect that sets a cookie, text a service fetches) is annotated
  `=> Try(Server.Response, Endpoint.Refusal)` and answers `Ok(Server.redirect(…))`. Its typed
  client reads nothing: pages link to it or post forms to it. A handler that answers JSON but
  sometimes a response of its own (a result with a cookie) keeps its type and answers those with
  `Err(Answer(response))`.
- `body` is read from JSON or from a form's fields by its type; `post_body = …` in the route file
  names rules that check it (packages/forms), refused with the issues before the handler runs.
- The `##` comment above a handler is its OpenAPI description, and its first sentence its summary:
  start it with what the endpoint does, `## POST /notes: a new note.`
- `respond!` answers every method by hand (an MCP server, a proxy): reach for it only when the
  methods above can't say it, since it gives up the contract and rocx's 405.
- Code that calls an endpoint on the server (a job, an MCP tool, another route) sends its contract,
  `Api.post_x(params).send!(arg)`: it goes through the endpoint's middleware, in-process.

## Middleware

- `routes/+middleware.roc` is the app's, around every request. A `+middleware.roc` in a folder
  wraps the pages, endpoints and channels in that folder and below it, outermost first, each given
  what the one around it handed on. A handler's `context` type says what it needs, and only
  compiles behind middleware that provides it.
- Put a guard on a group: `routes/(members)/+middleware.roc`, with the members' pages and their
  `api/` endpoints inside `(members)/`, and public pages outside.
- A route file never names middleware; rocx refuses one that does.
- `Middleware.make(|request, context, next!| …)` makes one; `a.then(b)` chains two.

## Pages and components

- A `.rocx` file is a Roc module with markup in it. A page has `view! = |{ params, .. }| …` and
  may have `meta = { title: … }`. A component has `view` (pure: markup from its props), or `view!`
  when it makes signals or memos, reads a context or reads an endpoint. A `Props := { … }` type is
  optional, for defaults (`title : Str ?? ""`).
- Holes: `{x}` shows text, a number or markup, by its type (older code writes `{=x}`: the same).
  `{...items.map(|item| <li key={item.id}>…</li>)}` shows a list. `{if …}` and `{match …}` in a
  hole make a part that's made again only when the branch changes.
- **Key every row of a list that changes by a stable id** (`key={post.id}`; `key={i}` with
  `map_with_index` for rows by position). A changing list without keys is refused.
- Attributes: `name={expr}`, `name?={bool}`, `name??={str}` (left out when empty),
  `class:name={bool}`, `style:--var={str}`, `on:click={handler!}`. No inline `onclick="…"`, no
  `style={…}` computed whole.
- A `view!`'s props are getters: it reads the newest value where it uses one. A pure `view`'s are
  values, and its call is made again when one changes (pass `name!={…}`, an accessor, to keep its
  elements). Components run once; holes and effects run again as what they read changes.
- `<style>` in a component is scoped to it. `transition={Transition.fade}` (`import pf.Transition`)
  animates a row or a part as it comes and goes.

## Data and reactivity

- `create_signal!`, `create_memo!`, `create_effect!(compute, apply)`, `untrack!`: Solid 2.0's,
  in Roc (`import pf.Solid exposing [create_signal!, create_memo!, …]`). A read (`count!()`) is
  tracked in a hole, an attribute, a memo or an effect's first function. In a component's body it
  is read once (`untrack!` says that is meant); in a handler it is the current value.
- A memo compares its new value with its last by `==`, and an equal one tells no one, so its value
  must be data: no functions, no markup (compute those in a plain function).
- A page reads its data with `Api.get_x(params).read!()` inside a memo. While the server renders,
  the read is answered in-process and the answer travels with the page, so hydrating fetches
  nothing. A refusal fails the read for the nearest `<Errored>`; use `.send!({})` to get it as a
  value instead.
- **Data that changes**: hand components the memo's accessor (`data!`) and read it where it's
  shown. `refresh!(data!)` asks the server again and keeps the old value showing until the new one
  is in (`is_pending!` says it's waiting). Rows keyed by id then update in place, and a memo of the
  part a view shows (`title! = create_memo!(|| data!().title)`) stays quiet when that part is the
  same. Don't wrap a view in `[data].map(|d| <View key={d} …/>)` to show a new answer: every
  refresh would remount the whole view.
- Live updates: an endpoint's `events!` streams values; a page listens with
  `Endpoint.listen!(Api.events_api_x({}), |heard| …)` inside an effect (it stops when the page
  goes) and `refresh!`es what the news is about, not everything. A channel (`channel!`) is
  subscribed to the same way: `Endpoint.subscribe!(Api.channel_api_x(params), heard!)`.

## Forms and actions

- A form posts to an endpoint: `<form method="post" action={Endpoint.url_of(Api.post_x({}))}>`.
  It works before the runtime loads and without JavaScript: the server sends the browser back to
  the page with a flash. With the runtime, a form a component reads (`use_submission!`) goes by
  `fetch` for that component; one nothing reads is answered as a plain form, in place. Either way
  the page's reads are read again, and an endpoint's own redirect is followed.
- `use_submission!(endpoint)` gives the latest submission: `input!()` (what was sent, as the
  endpoint reads it), `field!(name)` (a field as typed), `result!()`, `error!()` (a refusal),
  `pending!()`, `clear!()` and `retry!()`. Show refusals where the form is: one nobody reads shows
  nothing. A form nothing reads that fails (a 500) shows it in the nearest `<Errored>`.
- A form that succeeded is reset (`data-rocx-keep` on it keeps what was typed); `field!` is ""
  after a success and what was typed after a refusal, so `value={submission.field!("name")}` puts
  it back.
- `use_action!(endpoint)` sends from code (a drag, a toggle); `create_optimistic!` shows the
  change before the server answers.

## Navigation

- Links to the app's own pages navigate in place: the next page is fetched as a document and
  swapped in, its layouts kept when they're the same.
- `<html data-rocx-transitions>` in the root layout makes each one a View Transition; give lasting
  parts (a header) a `view-transition-name` so they stay put. While one runs the browser takes no
  clicks, so keep them short.
- `Router.location!({})` reads the path and query; read it where it's used, not once at the top
  of a layout (a layout that does is made again on every navigation, and a dev build says so).
- `data-rocx-reload` on a link or a form (or around it) leaves it to the browser: a whole load,
  for a sign-out that must drop every state.

## The database

- `Db.all!`, `Db.one!` (a row or `NotFound`), `Db.run!` and `Db.transaction!`, with `$1`, `$2`
  parameters, each `Text(…)`, `Int(…)`, `Bool(…)` or `Null`, never strings joined into SQL.
- Write SQL for the engine `main.roc` names (SQLite by default): nothing is translated.
- Tables come from `migrations/*.sql`, each run once in order. Add a migration; never edit one
  that has run anywhere.
- `rocx check --sql` prepares every statement on a scratch database built from the migrations.

## Settings and secrets

- `Env.var!("NAME")` reads the server's environment, in a request, a job or a schedule alike.
  `Env.dev!` says whether it runs under `--dev`.
- A `.env` file is read only when the server is started with `--env-file` (`rocx dev` passes the
  folder's own). Tests, CI and production get exactly the environment they're given. Never commit
  `.env`.
- Outside `--dev` the platform and its plugins refuse to start without what they need (email
  without `SMTP_URL`, AI help without its key) rather than run half-working. Don't work around it
  with a default: give the setting.

## Plugins and packages

`main.roc` lists plugins: jobs and schedules (packages/jobs), email (packages/email), sign-in and
sessions (packages/auth), AI (packages/ai) and more. A plugin adds no routes (D-116): every URL is a
file under `routes/`, and a package that answers requests (auth's sign-in steps, the jobs page,
storage's signed links) offers handlers a route file calls with a one-line `respond!`. Each
package's README says what it adds, the settings it reads and the route files it wants. Import a
package's module by its name (`import auth.Auth`); never copy a package's code into the app.

packages/auth can keep the app's users (`Auth.user_for!` in the app's `admit!`, `Auth.user!`;
`rocx new`'s template still keeps a `users` table of its own) and their roles (`Roles.current!`).
What a user may do is the app's own pure function of what the request knows
(`Policy.can(context, Edit(post))`, and `Policy.need(context, Edit(post))?` in a route), never a
stored list: auth's README, "What a user may do".

## Deploying

`rocx build` makes `dist/server` and `dist/static`; run `dist/server --static dist/static` behind
a TLS proxy, with the environment the app needs. `rocx build --image` writes a container image
(`<name>.tar`, for `docker load -i`): it runs on PORT 8080 as a non-root user, with `/app/data`
for a volume (a SQLite database lives there).

## Mistakes to avoid

- Editing `Generated/`, a component's generated `.roc`, or `.rocx/`: rocx overwrites them.
- A page and an endpoint in one folder; middleware named in a route file.
- A list that changes without `key`s, or keyed by position when items move.
- Remounting a view on each new answer (`key={data}`) instead of passing an accessor.
- Answering a success as `Err(Answer(…))` when every success is a response of its own: annotate
  `Try(Server.Response, Endpoint.Refusal)` and answer `Ok`.
- A form's refusal that nothing on the page reads.
- Strings joined into SQL; a migration edited after it ran.
- Reading secrets from a file the server finds by itself, or defaulting a required setting.
- Saying a change works without `rocx check` (and `rocx test`, where there are tests).
