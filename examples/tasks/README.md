# Tasks

A small team's task lists, in Roc Solid. Each list has tasks; a task has a title, notes, maybe a
day it is due and someone to do it, and is done or not. You add, edit, tick off, reorder and delete
tasks, filter a list (all, open, done, mine), and see how many are still open. There is no sign-in:
you say who you are, and a cookie remembers it.

It is the example to read first. It does the usual things the plain way, and its comments say why
each piece is where it is.

## A tour

1. **`/`**, the front page: each list as a card, with how many of its tasks are open and done and
   a bar of how far along it is; a form that makes a new list; the team. Down the side, on every
   page, the lists again, each with its open count; at the top, who you are.
2. **`/me`**, "Who are you?": pick yourself from the four people seeded (Avery, Jun, Mila, Theo).
   The front page greets you, "Mine" on a list shows your tasks, and new tasks are yours unless
   you say otherwise. "I'd rather not say" forgets you.
3. **`/lists/1`**, a list: its tasks in order, each with a box to tick, a badge for when it is due
   ("Overdue · Nov 21", "Today", "Tomorrow", "Fri, Nov 27"), and who has it. Filters across the
   top (`?show=open`, `done`, `mine`), each with its count. Tick a task, move it up or down, delete
   it, or drag it onto another: the list changes at once and saves in the background, dimmed a
   little while the server's copy is read again. Under the list, a form adds a task, checked as you
   type; a title left empty is refused under the field.
4. **`/tasks/1`**, a task: every field in one form, and a button that deletes it. Saving goes back
   to the list; a refusal comes back with what you typed and why, under each field.
5. Turn JavaScript off and do it all again: every button and form still works, as a plain form that
   posts and comes back (303).
6. A list or task that isn't there (`/lists/99`) is a 404 page, and so is any other address.

## What it shows

| Feature | Where |
|---|---|
| File routing: the document around every page | [`routes/+layout.rocx`](routes/+layout.rocx) |
| A page, and a form posted to the page's own URL | [`routes/+page.rocx`](routes/+page.rocx), [`routes/+server.roc`](routes/+server.roc) (`POST /`) |
| The error page (404, and a page that failed) | [`routes/+error.rocx`](routes/+error.rocx) |
| A dynamic route, its page and its endpoints at one path | [`routes/lists/[id]/+page.rocx`](routes/lists/[id]/+page.rocx), [`+server.roc`](routes/lists/[id]/+server.roc) (`GET` and `POST /lists/:id`) |
| A second dynamic route, a task's page | [`routes/tasks/[id]/+page.rocx`](routes/tasks/[id]/+page.rocx), [`+server.roc`](routes/tasks/[id]/+server.roc) |
| `+server.roc` endpoints of their own (JSON for scripts too) | [`routes/api/team`](routes/api/team/+server.roc), [`routes/api/tasks/toggle`](routes/api/tasks/toggle/+server.roc), [`move`](routes/api/tasks/move/+server.roc), [`delete`](routes/api/tasks/delete/+server.roc) |
| A `Middleware`: who you are, from a cookie, into every handler's `context`; each answer logged with `Log.info!` (`Log.error!` with why for a 5xx); `Middleware.same_origin` before it | [`Middlewares.roc`](Middlewares.roc), named in [`main.roc`](main.roc) |
| A cookie set and cleared by an endpoint, then a redirect | [`routes/me/+server.roc`](routes/me/+server.roc) |
| SQLite in the server's process (`database: Sqlite("data/tasks.db")`, D-045): migrations, and a seed that is safe to run twice | [`migrations/0001_tables.sql`](migrations/0001_tables.sql), [`0002_seed.sql`](migrations/0002_seed.sql) |
| `Db.all!`, `Db.run!`, a transaction, typed rows, `Db.Nullable` for the optional fields | [`Store.roc`](Store.roc) (`Row`, `task_of`, `move!`) |
| Pages that read endpoints with `Endpoint.get!` (in a memo, for the list): one its endpoint refuses with `NotFound` is the error page, a 404 | [`+layout.rocx`](routes/+layout.rocx), [`lists/[id]/+page.rocx`](routes/lists/[id]/+page.rocx), [`tasks/[id]/+page.rocx`](routes/tasks/[id]/+page.rocx) |
| Rules written once, run by the server and the browser, with expects | [`Tasks.roc`](Tasks.roc) (filters, toggles, moves, places, due badges) |
| Forms with packages/forms: one schema for the page and the endpoint; issues in place, with what was typed | [`TaskForm.roc`](TaskForm.roc), [`components/AddTask.rocx`](components/AddTask.rocx) (`LiveForm`, `<TextField>`), [`routes/lists/[id]/+server.roc`](routes/lists/[id]/+server.roc) (`Issues.refusal`) |
| An edit form that starts filled in, and an add form that starts afresh once it is accepted | [`routes/tasks/[id]/+page.rocx`](routes/tasks/[id]/+page.rocx) (`LiveForm.filled!`), [`components/AddTask.rocx`](components/AddTask.rocx) (`accepted!`, `reset!`) |
| Adding and completing without JavaScript: a plain form post, then a 303 back | [`components/AddTask.rocx`](components/AddTask.rocx), [`components/TaskRow.rocx`](components/TaskRow.rocx) |
| Actions (D-030): every submission to an endpoint (`use_submissions!`), an optimistic list, revalidation; a drop sent as an action (`use_action!`) | [`routes/lists/[id]/+page.rocx`](routes/lists/[id]/+page.rocx) (`Board`), [`components/TaskRow.rocx`](components/TaskRow.rocx) (`dropped!`) |
| A pending state: `is_pending!` dims the list while it is read again; "Saving…" while changes are on their way | [`routes/lists/[id]/+page.rocx`](routes/lists/[id]/+page.rocx) |
| A refused change undone, and why, with a Dismiss | [`routes/lists/[id]/+page.rocx`](routes/lists/[id]/+page.rocx) (`refused!`, `dismiss!`) |
| Pure components (`view`), with expects that render them | [`components/DueBadge.rocx`](components/DueBadge.rocx), [`components/Avatar.rocx`](components/Avatar.rocx), [`components/FilterTabs.rocx`](components/FilterTabs.rocx) |
| Effectful components (`view!`) | [`components/TaskRow.rocx`](components/TaskRow.rocx), [`components/AddTask.rocx`](components/AddTask.rocx), the pages' `Board`, `Editor`, `Field` |
| A `<story>` of a pure component | [`components/DueBadge.rocx`](components/DueBadge.rocx) (four: `rocx build --dev`, then `/__rocx/stories`) |
| Scoped `<style>`s, tokens on `:root` (light and dark), a narrow layout | every component; the tokens in [`routes/+layout.rocx`](routes/+layout.rocx) |
| `<For>` keyed rows that glide when they move (`transition:move`), `<Show>`, `<Title>`, `<HttpStatusCode>` | [`components/TaskRow.rocx`](components/TaskRow.rocx), [`routes/lists/[id]/+page.rocx`](routes/lists/[id]/+page.rocx) |
| Tests: expects, HTTP, the database, a real browser | [`test/tasks.test.mjs`](test/tasks.test.mjs), and the expects in each module |

## Build and run it

From the repository's root, with the toolchain (`just setup`). Nothing else: the tasks are a SQLite
file, `data/tasks.db` from where the server starts (`--database-url sqlite:<path>` puts it
elsewhere).

```sh
bin/rocx build examples/tasks --client examples/tasks/build/client   # bin/rocx: any repo script builds it
.tools/roc-active build --target=wasm32 --opt=size --output=examples/tasks/build/client/static/rocx/app.wasm examples/tasks/build/client/main.roc
node server/build.mjs examples/tasks/main.roc examples/tasks/build/tasks
cd examples/tasks && build/tasks --port 18110 --static build/client/static
```

Then http://localhost:18110. The server runs the migrations as it starts, so the first start makes
the file, its tables and the seed. Add `--dev` to see crashes in the page and reload it on
restart, and `rocx build examples/tasks --dev` (the same `--client`) for the stories at
`/__rocx/stories`.

## Test it

```sh
bin/rocx fmt --check examples/tasks
bin/rocx check -- .tools/roc-active test examples/tasks/main.roc   # the expects: rules, forms, pure components
node --test 'examples/tasks/test/*.test.mjs'                       # a SQLite file of their own
just examples tasks                                                # all of it, as `just examples` does each example
```

The node tests build the app, make a SQLite file of their own in a temporary directory (and
remove it after), and start the server on a free port. Over HTTP: the pages, each form as a browser
without JavaScript posts it and as the runtime sends it, the endpoints as JSON, what lands in
the database (nulls included), the cookie, the middleware's log and its refusal of another site's post,
404s, and the seed run twice. In Chromium (skipped when there is none): ticking a task, which shows
at once and then in the counts down the side; adding one (refused when empty, then added, the form
emptied), moving it up, and deleting another, each without the page loading again, and each in
the database after; and a change the server refuses (a task deleted elsewhere, then ticked), undone,
said why, and dismissed, which reads the list again. Rows glide to their places when the list
changes, so the browser's tests wait for the page to stop moving before they click.

## Product calls

- **Identity is a picker, not a sign-in.** You say who you are; anyone may say they are anyone.
  The `notes` example signs people in.
- **A filter is an address** (`?show=open`), not a toggle in the page: it can be shared and
  reloaded, and works without JavaScript. The counts beside each filter are of the whole list.
- **New tasks go to you**, once the app knows who you are; pick "Nobody yet" to leave one
  unassigned.
- **Quick add, then edit.** The form under a list asks for a title, a due day and a person; notes
  are on the task's page.
- **A done task shows no due badge**: it isn't due any more.
- **Deleting asks nothing**: it is one click, as ticking is. The task's page has a delete button
  too, which goes back to the list.
- **Order is by hand**: up and down buttons (which work without JavaScript), or dragging a task onto
  another, which puts it in that one's place. Moving under a filter moves past the tasks you can
  see.
- **Lists are made, not deleted or renamed**, to keep the example small.

## What it asked of the platform

What the platform didn't do, or did in a way an app has to know about, and what the app does
instead. None needed a change to the platform; two needed one to packages/forms, since made.
Two more were fixed in rocx and the platform since (9, 10).

1. **Fixed: a `LiveForm` couldn't start filled in.** It started empty, or with what a refused
   plain post typed (the flash), and a signal can't be written while a component renders, so the
   task's page read its submission itself (`use_submission!`, `Issues.from_problem`) with fields of
   its own. packages/forms has `LiveForm.filled!(form, endpoint, values)` now: the task's page
   (`routes/tasks/[id]/+page.rocx`) starts its form with the task, checks it as it is typed with
   `TaskForm.editing`, and uses `<TextField>` and `<CheckboxField>`.
2. **Fixed: a `LiveForm` couldn't be reset.** After a successful add the form still held the
   title, and once sent it showed every field's issues, so the list rendered the form inside a
   `<For>` keyed by how many adds had succeeded, and focus left the title field each time.
   `live.reset!()` starts a form afresh where it is, and `live.accepted!()` says the endpoint took
   what was sent: `AddTask` resets once it has, and the title field keeps focus (and, its props
   being getters since D-039, the list read again after an add doesn't make it anew either).
3. **Fixed: one endpoint for a form and an action took a record of strings.** A plain form posts
   strings, and the runtime sends an action's arg as JSON, so an endpoint both reach read strings:
   `{ id : Str, done : Str }`, `done` `"true"`, and `to` a place as text. A form's fields are read
   by the endpoint's types now (D-038), on the server and in the browser's submissions, so
   `Tasks.Toggle` is `{ id : Str, done : Bool }` and `Tasks.Move` `{ id : Str, to : U64 }`, from a
   row's form and from a drop's action alike.
4. **A form's endpoint reads the body twice.** `Tasks.Adding` is the add form's fields as strings,
   so the list can show a task while it is on its way (`pending_inputs!` gives the endpoint's arg),
   and `TaskForm.adding.parse_body(Server.text_of(request))` reads the same body again, checked.
5. **The browser's copy needs the types said** (D-030 says why): every memo that reads an
   endpoint, and every `use_submissions!` and `use_submission!`, was annotated
   (`team! : () => Tasks.Team`, `toggles : Submissions(Tasks.Toggle, {})`), or the browser's
   program didn't compile ("This decodes a record whose full set of fields is not known"). (Fixed
   in the platform since: the browser's copy of `Api` has the endpoints' types, copied from each
   handler's annotation (D-037), so the annotations are gone; the list's `sheet!` keeps its.)
6. **Fixed: `Endpoint.get!` of a 404 was a 500 page.** A refusal failed the read, and the root
   `<Errored>` answered 500, so the list and task pages read with `Endpoint.read!` and showed their
   own 404, for any refusal (a failing database too). Now a read its endpoint refuses with a 4xx
   makes the page that status, with the app's error page (`routes/+error.rocx`), as a path no page
   has does; a 5xx is still a 500. Both pages read with `get!`.
7. **Fixed: a plain form and the runtime need different answers from delete.** From the task's own
   page a browser should go to the list, not back to the deleted task; from the list, the runtime
   wants JSON. `Endpoint.posted_by` was private, so the endpoint asked `Server.wants_html(request)`;
   now it is public, and the endpoint asks it (`PlainForm`, `Runtime` or `Other`).
8. **`node --test <dir>` finds no tests on Node 24**: the glob `'examples/tasks/test/*.test.mjs'`
   does (`just examples` uses it).
9. **Fixed: `rocx build --client` of an app with no component pages** (echo) wrote a `main.roc`
   that was the server's, which doesn't type-check there ("Api … has no associated openapi"), and
   `just examples-check` checked the browser's program only when the build wrote
   `static/rocx/start.js` beside it. The browser's copy now leaves the server's program out, an app
   of endpoints alone has no browser's `main.roc` (the build says so), and `examples-check` checks
   the copy's `main.roc` whenever there is one.
10. **Fixed: a favicon as a `data:` URL was refused** (`href` took relative and http(s) URLs only),
    and the app has no static files of its own. `Html` now allows a `data:image/…` URL where the
    browser only shows it as an image (`<link href>`, `<img src>`, `<source src>`, `<video
    poster>`), so the layout's icon is an inline SVG.
11. Roc, met on the way: `{ me }` alone is a block, not a record (`{ me: me }`); a record update
    can't add a field (`{ ..fields, error }`); `Str.join_with(list, ", ")`, not `list.join_with`; a
    local can't share a name with a definition of its module (`toggled` in `Tasks.showing`).
