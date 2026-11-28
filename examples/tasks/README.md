# Tasks

A small team's task lists, built with Roc Solid. Each list has tasks. A task has a title and notes,
maybe a day it is due and someone to do it, and is done or not. You add, edit, tick off, reorder
and delete tasks, filter a list (all, open, done, mine), and see how many are still open. There is
no sign-in: you say who you are, and a session remembers it (packages/auth).

Read this example first. It does the usual things the plain way, and the comments in its code say
why each piece is where it is.

## Run it

From the repository's root, after `just setup`:

```sh
cd examples/tasks
../../bin/rocx dev    # http://localhost:8080
```

`rocx dev` builds the app (its server, and its browser half as wasm), serves it under `--dev`, and
builds it again each time you save a file. The tasks are kept in a SQLite file, `data/tasks.db`
(`database: Sqlite("data/tasks.db")` in `main.roc`). The path is relative to the folder the server
starts in, which is why you start `rocx dev` in `examples/tasks`. `*.db` files are gitignored.

On its first start the server runs the migrations: they make the tables, and seed four people,
three lists and a dozen tasks. To keep the file elsewhere, pass the server an option after `--`:
`../../bin/rocx dev -- --database-url sqlite:/tmp/tasks.db`.

`rocx dev` makes a dev build, so the components' stories are at
http://localhost:8080/__rocx/stories.

### Build it by hand

To build each piece yourself, run these from the repository's root. The browser's wasm is
optimized for size here, as the docs' examples page measures it:

```sh
just web-host     # the browser platform's host, once (rocx dev builds it too)
bin/rocx generate examples/tasks --client examples/tasks/build/client
.tools/roc-active build --target=wasm32 --opt=size --output=examples/tasks/build/client/static/rocx/app.wasm examples/tasks/build/client/main.roc
node server/build.mjs examples/tasks/main.roc examples/tasks/build/tasks
cd examples/tasks && build/tasks --port 18110 --static build/client/static
```

Then open http://localhost:18110. Add `--dev` to the last command to see crashes in the page, and to
have open pages reload when the server restarts.

### Deploy it

```sh
cd examples/tasks
../../bin/rocx build              # dist/server and dist/static
dist/server --static dist/static
../../bin/rocx build --image      # or a container image, tasks.tar (docker load -i tasks.tar)
```

`rocx build` builds the server for speed, with SQLite alone in it, and the browser's wasm for size.
The server makes `data/tasks.db` where it starts; in the image that is `/app/data`, for a volume.

## A tour

1. **`/`**, the front page. Each list is a card, with how many of its tasks are open and done, and a
   bar for how far along it is. Below them are a form that makes a new list, and the team. On every
   page, the lists are down the side, each with its open count, and who you are is at the top.
2. **`/me`**, "Who are you?". Pick yourself from the four people seeded (Avery, Jun, Mila, Theo).
   The front page then greets you, "Mine" on a list shows your tasks, and new tasks are yours unless
   you pick someone else. "I'd rather not say" forgets you.
3. **`/lists/1`**, a list. Its tasks are in order, each with a box to tick, a badge for when it is
   due ("Overdue · Nov 21", "Today", "Tomorrow", "Fri, Nov 27"), and who has it. The filters across
   the top (`?show=open`, `done`, `mine`) each show a count. Tick a task, move it up or down, delete
   it, or drag it onto another: the list changes at once and saves in the background. It dims a
   little while the server's copy is read again. Under the list, a form adds a task. It is checked
   as you type, so an empty title is refused under the field.
4. **`/tasks/1`**, a task. Every field is in one form, with a button that deletes the task. Saving
   takes you back to the list. A refusal comes back with what you typed, and why, under each field.
   If you leave with changes not saved, the page asks first.
5. **Turn JavaScript off** and do it all again. Every button and form still works, as a plain form
   that posts and is redirected back (a 303).
6. **A list or task that isn't there** (`/lists/99`) is a 404 page, and so is any other unknown
   address.

## What it shows

Each row names a feature and the file to read for it. Paths are from `examples/tasks/`.

### Routes and pages

| Feature | Where |
|---|---|
| A layout: the document around every page, with the lists down the side. It reads `GET /api/team` in a memo, so the counts follow each change | [`routes/+layout.rocx`](routes/+layout.rocx) |
| Links that navigate without a page load, the list you are on marked (`aria-current`, as every link is) | [`routes/+layout.rocx`](routes/+layout.rocx) |
| Pages, and a dynamic route's `params` (`/lists/:id`, `/tasks/:id`) | [`routes/+page.rocx`](routes/+page.rocx), [`routes/me/+page.rocx`](routes/me/+page.rocx), [`routes/lists/[id]/+page.rocx`](routes/lists/[id]/+page.rocx), [`routes/tasks/[id]/+page.rocx`](routes/tasks/[id]/+page.rocx) |
| The error page: for a path no page has (404), and a page that failed (500) | [`routes/+error.rocx`](routes/+error.rocx) |
| A page's endpoints under `api/`, at the page's path: a path is a page or an endpoint, never both. `GET /lists/:id` is the page; `GET /api/lists/:id` the list as JSON, which is what the page reads; `POST /api/lists/:id` adds a task | [`routes/api/lists/[id]/+server.roc`](routes/api/lists/[id]/+server.roc), [`routes/api/tasks/[id]/+server.roc`](routes/api/tasks/[id]/+server.roc), [`routes/api/+server.roc`](routes/api/+server.roc) (`POST /api`, a new list) |
| Endpoints of their own, which scripts can call too | [`routes/api/team`](routes/api/team/+server.roc), [`routes/api/tasks/toggle`](routes/api/tasks/toggle/+server.roc), [`move`](routes/api/tasks/move/+server.roc), [`delete`](routes/api/tasks/delete/+server.roc) |
| A page that reads its endpoint by the endpoint's own method, `Api.get_api_lists_id({ id: params.id }).read!()` (D-102). When the endpoint refuses with `NotFound`, the page becomes the error page, answered 404 | [`routes/lists/[id]/+page.rocx`](routes/lists/[id]/+page.rocx), [`routes/tasks/[id]/+page.rocx`](routes/tasks/[id]/+page.rocx) |
| `<Errored>`: a part of the layout that shows a fallback if its read fails | [`routes/+layout.rocx`](routes/+layout.rocx) |
| `<Title>`: a page's title from its data | [`routes/lists/[id]/+page.rocx`](routes/lists/[id]/+page.rocx), [`routes/tasks/[id]/+page.rocx`](routes/tasks/[id]/+page.rocx) |

### The server

| Feature | Where |
|---|---|
| A middleware around every request, `routes/+middleware.roc`: `identify` puts who you are, from your session (`Auth.optional`), into every handler's `context`; `logged` logs each answer (`Log.info!`, or `Log.error!` for a 5xx). A change sent from another site's page the platform refuses before it | [`Middlewares.roc`](Middlewares.roc), named in [`routes/+middleware.roc`](routes/+middleware.roc) |
| A plugin: packages/auth keeps sessions in the app's database, its cookie `tasks_session`. With none of its sign-in routes (D-116), nobody signs in by a link or a provider; the app starts sessions itself. The team is the app's own `people` table: a session's user is a person's id, and the package's `auth_users` (D-134) stays empty | [`main.roc`](main.roc) (`Auth.plugin`), [`migrations/0001_tables.sql`](migrations/0001_tables.sql) |
| A session started and ended by an endpoint: `Auth.switch!` ends the one you had and starts one for the person picked, `Auth.sign_out!` forgets you | [`routes/api/me/+server.roc`](routes/api/me/+server.roc) |
| A handler's own answer as its `Ok` (`Try(Server.Response, Endpoint.Refusal)`, D-106): a redirect, which the runtime follows too | [`routes/api/me/+server.roc`](routes/api/me/+server.roc), [`routes/api/+server.roc`](routes/api/+server.roc), [`routes/api/tasks/[id]/+server.roc`](routes/api/tasks/[id]/+server.roc) |
| SQLite in the server's process, with migrations and a seed that is safe to run twice | [`main.roc`](main.roc), [`migrations/0001_tables.sql`](migrations/0001_tables.sql), [`migrations/0002_seed.sql`](migrations/0002_seed.sql) |
| Queries: `Db.all!` into typed rows, `Db.one!` for the one row a query reads, `Db.run!`, a transaction, and `Db.Nullable` for optional columns | [`Store.roc`](Store.roc) (`Row`, `task_of`, `task!`, `move!`) |
| A database that failed: why goes on the log (`Log.error!`), and the client gets a plain 500, since the database's text can name the app's tables and values | [`Store.roc`](Store.roc) (`refusal!`) |
| One endpoint for a plain form and the runtime, answering each in its way: `Endpoint.posted_by` tells them apart (a redirect for a form; for the runtime, which sends every form to an endpoint, JSON and what to read again, `Router.revalidate!`). The task's page reads the answer and goes to the list | [`routes/api/tasks/delete/+server.roc`](routes/api/tasks/delete/+server.roc), [`routes/tasks/[id]/+page.rocx`](routes/tasks/[id]/+page.rocx) |

### Forms and changes

| Feature | Where |
|---|---|
| Rules written once and run on both sides (filters, toggles, moves, places, due badges), with expects | [`Tasks.roc`](Tasks.roc) |
| Forms with packages/forms: one schema for the page and the endpoint, issues shown in place with what was typed | [`TaskForm.roc`](TaskForm.roc), [`components/AddTask.rocx`](components/AddTask.rocx) (`LiveForm`, `<TextField>`), [`routes/api/lists/[id]/+server.roc`](routes/api/lists/[id]/+server.roc) (`post_body = TaskForm.adding`: the body read and checked by the form, D-093) |
| An edit form that starts filled in, and an add form that starts afresh once the endpoint accepts it | [`routes/tasks/[id]/+page.rocx`](routes/tasks/[id]/+page.rocx) (`LiveForm.filled!`), [`components/AddTask.rocx`](components/AddTask.rocx) (`accepted!` and `reset!`, in an effect) |
| Working without JavaScript: every control is a plain `<form>` that posts, then a 303 back | [`components/AddTask.rocx`](components/AddTask.rocx), [`components/TaskRow.rocx`](components/TaskRow.rocx) |
| A form's fields read into the endpoint's body type. `Tasks.Toggle` is `{ id : Str, done : Bool }`, whether a row's form posts it or an action sends it as JSON | [`Tasks.roc`](Tasks.roc), [`routes/api/tasks/toggle/+server.roc`](routes/api/tasks/toggle/+server.roc) |
| Optimistic changes. The list reads every submission to its endpoints (`use_submissions!`) and shows each change applied at once; the server's list takes over once it has been read again. A drop has no form, so it is sent as an action (`use_action!`) | [`routes/lists/[id]/+page.rocx`](routes/lists/[id]/+page.rocx) (`Board`), [`components/TaskRow.rocx`](components/TaskRow.rocx) (`dropped!`) |
| Pending states: `is_pending!` dims the list while it is read again, and "Saving…" shows while changes are on their way | [`routes/lists/[id]/+page.rocx`](routes/lists/[id]/+page.rocx) |
| A refused change, undone, with why and a Dismiss button that reads the list again (`refresh!`) | [`routes/lists/[id]/+page.rocx`](routes/lists/[id]/+page.rocx) (`refused!`, `dismiss!`) |
| Asking before you leave a form with changes not saved (`use_before_leave!`) | [`routes/tasks/[id]/+page.rocx`](routes/tasks/[id]/+page.rocx) (`Editor`) |

### Components and markup

| Feature | Where |
|---|---|
| Pure components (`view`). `DueBadge` and `Avatar` are rendered in expects; `FilterTabs` takes an accessor prop (`counts!`) and reads it in its holes | [`components/DueBadge.rocx`](components/DueBadge.rocx), [`components/Avatar.rocx`](components/Avatar.rocx), [`components/FilterTabs.rocx`](components/FilterTabs.rocx) |
| Effectful components (`view!`), which run once and may make signals | [`components/TaskRow.rocx`](components/TaskRow.rocx), [`components/AddTask.rocx`](components/AddTask.rocx), and the pages' `Board`, `Editor` and `Field` |
| A list's rows, kept by their `key`: `{...shown!().map(\|task\| <TaskRow key={task.id} … />)}`. Each row is made once and kept, with its state, as the list changes; a moved row glides to its new place (`transition:move`), and a new one fades in (`transition:in`) | [`routes/lists/[id]/+page.rocx`](routes/lists/[id]/+page.rocx), [`components/TaskRow.rocx`](components/TaskRow.rocx) |
| `if` and `match` in holes | [`components/TaskRow.rocx`](components/TaskRow.rocx), [`routes/lists/[id]/+page.rocx`](routes/lists/[id]/+page.rocx), [`routes/me/+page.rocx`](routes/me/+page.rocx) |
| Stories of a pure component, shown at `/__rocx/stories` in a dev build | [`components/DueBadge.rocx`](components/DueBadge.rocx) (four) |
| Scoped `<style>`s, design tokens on `:root` (light and dark), and a narrow layout | every component; the tokens in [`routes/+layout.rocx`](routes/+layout.rocx) |

## Test it

```sh
just examples tasks                            # build, type-check, lint, check the SQL, run the expects and the tests
just examples-release tasks                    # as deployed: rocx build, then the node tests against a server built for speed
bin/rocx fmt --check examples/tasks            # the formatting
bin/rocx check examples/tasks                  # type-check the server's and the browser's programs
bin/rocx check --sql examples/tasks            # every query, against the migrations' tables
bin/rocx test examples/tasks                   # the expects: rules, forms, pure components
node --test 'examples/tasks/test/*.test.mjs'   # HTTP and browser tests
```

The node tests in [`test/tasks.test.mjs`](test/tasks.test.mjs) build the app, make a SQLite file of
their own in a temporary directory (and remove it after), and start the server on a free port.

Over HTTP, they cover:

- the pages, and every form, posted both as a browser without JavaScript posts it and as the
  runtime sends it;
- the endpoints as JSON, and what lands in the database (nulls included);
- a task sent as JSON, read and refused by the same form as one posted (D-093);
- who you are: a session whose cookie is a token, not a name (a cookie naming someone is nobody),
  ended when you pick someone else or forget yourself;
- the middleware's log, and its refusal of another site's post;
- 404s, and the seed run twice.

In Chromium (skipped when there is none), they cover:

- ticking a task, which shows at once and then in the counts down the side;
- adding a task (refused when empty, then added and the form emptied), moving it up, and deleting
  another, each without a page load, and each in the database after;
- a change the server refuses (a task deleted elsewhere, then ticked): undone, explained, and
  dismissed, which reads the list again;
- a task's page that starts filled in, checks what is typed, and saves;
- deleting from a task's page, which goes on to the list without a load, never reading the deleted
  task's page again;
- leaving a task's page with changes not saved, which asks first.

Rows glide to their places when the list changes, so the browser tests wait for the page to stop
moving before they click.

## Product calls

- **Identity is a picker, not a sign-in.** You say who you are, and anyone may say they are anyone.
  The `notes` example signs people in. Who you picked is still a session kept on the server
  (packages/auth), so the cookie holds a random token, not a name anyone could change by hand. It
  lasts a year, and picking someone else ends it.
- **A filter is an address** (`?show=open`), not a toggle in the page. It can be shared and
  reloaded, and works without JavaScript. The counts beside each filter are of the whole list.
- **New tasks go to you**, once the app knows who you are. Pick "Nobody yet" to leave one
  unassigned.
- **Quick add, then edit.** The form under a list asks for a title, a due day and a person. Notes
  are on the task's page.
- **A done task shows no due badge.** It isn't due any more.
- **Deleting asks nothing.** It is one click, as ticking is. The task's page has a delete button
  too, which goes back to the list.
- **Order is by hand.** Use the up and down buttons (which work without JavaScript), or drag a task
  onto another to put it in that one's place. Moving under a filter moves past the tasks you can
  see.
- **Lists are made, not deleted or renamed**, to keep the example small.

## What it asked of the platform

Building this app showed what the platform didn't do yet. Most of it has been fixed since, in the
platform or in packages/forms: forms that start filled in or start afresh, form fields read into
typed bodies, bodies read and checked by the form itself (D-093: a form's endpoint read its body
twice, once typed as strings for the list's pending tasks, once with the form), `Endpoint.read!` of a
refusal answered as the error page, and a favicon as a `data:` URL. What remains, and what the app
does about it:

1. **`node --test <dir>` finds no tests on Node 24.** Use the glob,
   `node --test 'examples/tasks/test/*.test.mjs'`, as `just examples` does.
2. **Roc, met on the way:**
    - `{ me }` alone is a block, not a record: write `{ me: me }`.
    - A record update can't add a field (`{ ..fields, error }`).
    - It is `Str.join_with(list, ", ")`, not `list.join_with`.
    - A local can't share a name with a definition of its module (`toggled` in `Tasks.showing`).
