# Notes

Notes is a personal notebook in Markdown that AI agents can use too. You sign in with a link sent
by email, write notes with a live preview, tag, pin and archive them, and find them again with
full-text search. An AI client (Claude Code, an IDE, the MCP Inspector) can search, read and write
the same notes over MCP, using a personal access token you make for it. Each person sees only their
own notes, whichever way they ask.

Read it to see how Roc Solid handles signing in without passwords (packages/auth's plugin), access
tokens, middleware for three kinds of caller (a browser, a script, an AI agent), an MCP server built
from the app's own endpoints, a JSON API with an OpenAPI document, rate limits, full-text search in
SQLite, and Markdown rendered both on the server and in the browser.

## Run it

From the repository's root, once the toolchain is set up (`just setup`):

```sh
cd examples/notes
../../bin/rocx dev
```

Open http://127.0.0.1:8080 and sign in as `ada@example.com` (the seeded person with notes). The
sign-in link is in the dev mailbox, http://127.0.0.1:8080/__rocx/mail.

`rocx dev` builds the app (the server and the browser's WebAssembly), serves it with the server's
`--dev` flag, and builds and restarts it each time you save a file. Run it from the example's
directory: the database is the file `data/notes.db`, relative to where the server starts
(`database: Sqlite("data/notes.db")` in `main.roc`; `*.db` files are git-ignored). The server makes
the file, its tables and the seed data as it starts. Under `--dev`, mail goes to the dev mailbox
unless `SMTP_URL` is set.

The full form is `rocx dev [dir] [--port N] [-- server options…]`. Options after `--` go to the
server, for example `../../bin/rocx dev -- --database-url sqlite:/tmp/notes.db`.

The app reads these settings from the environment:

| Setting | What it is |
|---|---|
| `DATABASE_URL` | Where the notes are, as `sqlite:<path>` (or `--database-url`). Unset, `data/notes.db` from where the server starts. |
| `PUBLIC_URL` | The app's address (or `--public-url`), for the links in emails and the MCP address that Settings shows. Unset, the address the server listens on (`http://127.0.0.1:8080` above). On `https://`, the session cookie is `Secure` and named `__Host-notes_session`. |
| `SMTP_URL` | A mail server (`smtp://user:password@smtp.example.com:587?tls=required`). Unset, mail goes to the dev mailbox under `--dev`, and without `--dev` the server doesn't start. |
| `NOTES_MCP_PER_MINUTE` | MCP calls a minute for each token (120). |

Mail is sent from `Notes <notes@example.com>` (the `from` given to `Email.plugin` in `main.roc`).

### Build it as it would ship

`rocx dev` builds quickly, without optimizations. To build and start it as you would in production
(from the repository's root):

```sh
just web-host   # the browser's host, which the WebAssembly is linked with
bin/rocx build examples/notes --client examples/notes/build/client
.tools/roc-active build --target=wasm32 --opt=size --output=examples/notes/build/client/static/rocx/app.wasm examples/notes/build/client/main.roc
node server/build.mjs examples/notes/main.roc examples/notes/build/server --opt=speed
cd examples/notes && build/server --port 8080 --static build/client/static
```

Without `--dev` the server needs `SMTP_URL`, to send the sign-in links: it doesn't start without one
(add `--dev` to try it locally, with the dev mailbox).

## A tour

1. Open the app and you are sent to sign in. Type `ada@example.com` (the seeded person with notes)
   or any address. A link is mailed; on a local run it lands in the dev mailbox,
   http://127.0.0.1:8080/__rocx/mail. The link opens a page with a **Sign in** button, so a mail
   scanner that follows links doesn't use it up. A link works once, for 15 minutes; one used
   already, or too late, brings you back to sign in, saying so. Someone new starts with a welcome
   note.
2. The notebook shows cards with the start of each note, pinned ones first, and your tags down the
   side with their counts. A tag's link shows its notes; **Archive** shows the archived ones.
3. Search from the box at the top. It takes words (`rehearsals` finds "rehearsal"),
   `"an exact phrase"`, `or`, `-without`, and `#tag` to look only at a tag's notes
   (`launch #meetings`). Results come best first, archived notes included, with the words found
   highlighted.
4. Open a note to see its Markdown rendered, its tags, and **Edit**, **Pin** and **Archive**. An
   archived note can be restored, or deleted for good. Deleting takes these two steps, so a slip
   loses nothing.
5. **New note** or **Edit** has the title, the tags (`work, ideas`) and the Markdown, with a preview
   beside it that renders as you type. On a phone, Write and Preview are tabs.
6. **Settings** makes a personal access token, read-only or able to write. The token is shown once,
   with the command that connects Claude Code to it. You can revoke a token, see when each was last
   used, or sign out of every browser at once.
7. Connect an AI client with that token ([below](#connect-an-ai-client)) and ask it about your
   notes: "what did I plan for launch week?", "add 'buy rye flour' to my sourdough note", "capture
   this as a note".
8. Turn JavaScript off. Signing in, the editor (without its live preview), every button and the
   search still work, as plain forms and links.

## What it shows

Where to look in the code for each Roc Solid feature the app uses.

### Signing in and sessions

| Feature | Where |
|---|---|
| Sign-in as packages/auth's plugin, listed in `main.roc` with the app's `admit!`: anyone with a mailed link gets in, as the person with that address or someone new (with a notebook of their own). | `main.roc`, `Account.admit!`, `Store.person_for!` |
| A sign-in link made by the plugin (`Auth.link!`: kept by its hash, good once, for 15 minutes) and mailed in the app's own words (`Email.send!`, packages/email's plugin). | `routes/sign-in/`, `Account.send_link!` |
| The page a link opens: whom it signs in (`Auth.link_for!`, which doesn't use the link), and a plain form whose button posts the token to the plugin's `/auth/link`. A mail scanner that follows links doesn't use yours up. | `routes/sign-in/link/` |
| A sign-in that didn't work comes back to the sign-in page with `?error=` (a link used or expired, an address turned away), and the page says why. | `routes/sign-in/+page.rocx` (`problem_of`) |
| Sessions kept by the plugin: a random token in the `notes_session` cookie, its hash in the database, for 30 days, kept going while in use. | `Middlewares.signed_in` (`Auth.required`), `Account.session!` |
| Signing out, and signing out of every browser (every session of yours ended). | `routes/sign-out/` (`Auth.sign_out!`), `routes/settings/everywhere/` (`Auth.sign_out_everywhere!`) |
| Middleware that puts the person into the request's context and guards the pages (`signed_in`), the JSON API (`api`) and MCP (`agent`). A route file names its own with `middleware = …`. | `Middlewares.roc`, each route file |

### Tokens, the JSON API and MCP

| Feature | Where |
|---|---|
| Personal access tokens: made, shown once, kept only as a SHA-256 hash, named, last use noted, read-only or not, revoked. | `routes/settings/`, `Token.roc` (with `expect`s), `Account.make_token!`, `Store.bearer!` |
| A form whose body is read by its endpoint's types: the token form's checkbox "It may write too" is `write : Bool`, and a box left unticked is `Bool.False`. | `routes/settings/+server.roc`, `routes/settings/+page.rocx` |
| An MCP server (packages/mcp) at `/mcp`: six tools with their hints, notes as resources, and two prompts. | `Agents.roc` |
| MCP tools made from the JSON API's endpoints (`McpHttp.endpoint`). A tool's arguments fill the endpoint's path parameters too (`read_note`'s `id`), so an agent may do exactly what a script may, checked by the same code. | `Agents.roc` (`server`) |
| The MCP server mounted in front of the routes, as a middleware in `main.roc` (`Agents.mount`). | `main.roc`, `Agents.roc` |
| A bearer token turned into its person, so a token never reaches another person's notes. Read-only tokens are refused for writes. | `Middlewares.agent`, `Notebook.writer`, `Store.roc` (every query names the person) |
| The JSON API, and its OpenAPI document with Scalar to read it (`openapi: Page(Scalar)`), at `/openapi.json` and `/openapi.html`. | `routes/api/`, `main.roc` |
| Rate limits (packages/guard): sign-in links for each address, MCP calls for each token. | `Middlewares.mail_limit`, `Middlewares.agent_limit` |

### Search and Markdown

| Feature | Where |
|---|---|
| Full-text search in SQLite: an FTS5 index kept in step by triggers, each word matched by its stem (porter). A search engine's syntax is read in Roc (`Store.matching`). Titles rank first (`bm25`), and `snippet()` shows the matches in what the body reads as (`Note.plain`). | `migrations/0001_notes.sql`, `Store.search!`, `Store.matching`, `Note.plain`, `Note.query_of` |
| Matches highlighted as text, never as markup, so nothing a note says is read as HTML. | `Note.pieces`, `NoteCard.snippet` in `Ui/NoteCard.rocx` |
| Markdown rendered by packages/markdown: on a note's page by the server alone (inside `<NoHydration>`), and in the editor's preview by the browser as you type. | `Ui/Prose.rocx`, `routes/notes/[id]/+page.rocx`, `Ui/Editor.rocx` |

### Notes, pages and components

| Feature | Where |
|---|---|
| One rule set for a note's title, body and tags, whoever writes it (a page, a script, an agent), tested with `expect`s, and one module of operations that every way in calls. | `Note.roc`, `Notebook.roc` |
| Appends that never overwrite each other: the note is read and written in one transaction, and SQLite's transactions take turns. | `Store.append!`, `Note.appended` |
| Tags, pinning and archiving. | `Notebook.tag!`, `Notebook.pin!`, `Notebook.archive!`, `routes/notes/[id]/+server.roc` |
| Pages that read their own endpoint (`Endpoint.get!`), with the types they answer with in one module, shared by the server and the browser. | `Pages.roc`, each `+page.rocx` |
| A 404 for a note that doesn't exist or isn't yours. The endpoint refuses both alike, so ids tell nothing, and `Endpoint.get!` turns the refusal into the app's error page. | `routes/notes/[id]/+page.rocx`, `routes/+error.rocx` |
| Forms that work without JavaScript, and that the page sends in place with it (`use_submission!`). | every `<form method="post">` |
| Pure components (`view`) for what only shows its props; an effectful component (`view!`) for what keeps state, here the editor's draft and tabs (`create_signal!`). | `Ui/NoteCard.rocx`, `Ui/Topbar.rocx`, `Ui/Prose.rocx`, `Ui/Brand.rocx` (pure); `Ui/Editor.rocx` (effectful) |
| Pure components tested in `expect`s with packages/testing's `Dom`. | `Ui/NoteCard.rocx`, `Ui/Topbar.rocx` |
| Scoped styles and a look of its own (ink, paper, a highlighter), light and dark, narrow screens. | each component's `<style>`; the design tokens in `routes/+layout.rocx` |
| Stories for the component catalog (`<story>`, shown at `/__rocx/stories` under `rocx dev`). | `Ui/*.rocx` |
| SQLite in the server's process, built by migrations, with seed data that is safe to run again. | `main.roc`, `migrations/` |

## Connect an AI client

Make a token in **Settings** (tick "It may write too" if the agent should change notes), then give
it to the client. The token below is made up; use your own. The address is where the app runs:
Settings shows it.

**Claude Code:**

```sh
claude mcp add --transport http acme-notes http://127.0.0.1:8080/mcp \
  --header "Authorization: Bearer acme_pat_q7Vd2LkM9xR4tB8nW1yZ5cH3jF6gP0sAeUoIiOuYtRe"
```

Then, in Claude Code, `/mcp` lists `acme-notes` and its tools. Ask "search my notes for launch".

**A client that reads a JSON file** (Claude Code's `.mcp.json`, and others in the same shape):

```json
{
  "mcpServers": {
    "acme-notes": {
      "type": "http",
      "url": "http://127.0.0.1:8080/mcp",
      "headers": { "Authorization": "Bearer acme_pat_q7Vd2LkM9xR4tB8nW1yZ5cH3jF6gP0sAeUoIiOuYtRe" }
    }
  }
}
```

**The MCP Inspector** (`npx @modelcontextprotocol/inspector`): choose the transport "Streamable
HTTP", the URL `http://127.0.0.1:8080/mcp`, and an `Authorization` header with `Bearer acme_pat_…`.

**By hand**, to see what a client sends:

```sh
curl -s http://127.0.0.1:8080/mcp \
  -H "Authorization: Bearer acme_pat_q7Vd2LkM9xR4tB8nW1yZ5cH3jF6gP0sAeUoIiOuYtRe" \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_notes","arguments":{"query":"launch"}}}'
```

What the server offers:

| Tool, resource or prompt | What it does |
|---|---|
| `search_notes { query }` (read-only) | Words, `"phrases"`, `or`, `-without`, `#tag`; best first, archived notes too, the matches marked. Runs `POST /api/search`. |
| `read_note { id }` (read-only) | A whole note. Runs `GET /api/notes/<id>`. |
| `create_note { title, body, tags }` | A new note (`tags` may be `[]`). Runs `POST /api/notes`. |
| `append_to_note { id, text }` | Text added at the end, never overwriting. Runs `POST /api/notes/<id>/append`. |
| `tag_note { id, tags }` | Sets all of the note's tags. Runs `PUT /api/notes/<id>/tags`. |
| `archive_note { id, archived }` | Archives a note, or brings it back. Runs `PUT /api/notes/<id>/archived`. |
| `notes://index` | A resource: every note that isn't archived, as a Markdown list. |
| `notes://note/{id}` | A resource: a note as Markdown. |
| `summarize_note { id }`, `capture { text, tags? }` | Prompts: summarize a note and suggest tags; turn rough text into a note, or add it to a similar one if there is one. |

A read-only token's writes are refused as a tool error that the model reads ("This token can only
read"). No tool deletes a note.

The same token works for the JSON API (`curl -H "Authorization: Bearer acme_pat_…"
http://127.0.0.1:8080/api/me`), and http://127.0.0.1:8080/openapi.html describes it.

## Test it

```sh
just examples notes
```

This builds the app, type-checks the server's and the browser's programs, lints it, checks its SQL
(`rocx check --sql`), and runs the `expect`s and the node tests. For a quick type check alone, run
`../../bin/rocx check` in `examples/notes` (exit 1 on an error, 2 on warnings).

To run the parts by hand from the repository's root (each test file builds the app and starts its
own server on its own SQLite file; the browser test needs Chromium):

```sh
bin/rocx build examples/notes
bin/rocx check -- .tools/roc-active test examples/notes/main.roc   # the expects
node --test 'examples/notes/test/*.test.mjs'
```

- **76 `expect`s** in the app's modules: `Token.roc` (shapes, the hash being SHA-256's, the hint,
  names), `Note.roc` (titles, bodies, tags, the search box's `#tags`, snippets' marks, dates, what a
  body reads as, appending), `Store.matching` (a search box's words as an FTS5 query),
  `Address.roc`, `Query.roc`, the editor's word count, `NoteCard` and `Topbar` rendered and read
  with packages/testing's `Dom`, and `Mcp.problems(Agents.server)`. packages/auth has its own, for
  its tokens, cookies and where a sign-in may go after.
- **`test/http.test.mjs`** (15 tests):
  - signed out, pages send you to sign in, and the API and MCP refuse;
  - signing in through the mailed link (`waitForMail`, `links`), back where you were going, and
    someone new getting a welcome note; the database keeping only the tokens' hashes;
  - a link used again, a made-up one, and one past its time (aged in the database), all sent back
    to the sign-in page;
  - the sign-in page saying why a sign-in didn't work, and a session whose person is gone ended;
  - signing out, and signing out everywhere;
  - the seed, which adds nothing when run again;
  - a note through the pages' forms, without JavaScript and with the runtime (written, refused,
    edited, pinned, archived, deleted);
  - search (stemming, phrases, `-without`, `#tags`, highlighting, archived notes);
  - the JSON API with a token (every operation, ten appends at once, every refusal);
  - tokens (kept only as a hash, never listed, last use, read-only refused, shown once through a
    plain form's flash, revoked);
  - one person never reaching another's notes through a page, an endpoint, the API or a token;
  - the OpenAPI document, and the limit on sign-in mail.
- **`test/mcp.test.mjs`** (10 tests): `initialize`; `tools/list` with its hints and schemas;
  `tools/call` of every tool; refusals going back to the model; no token, a bad one, or a cookie
  alone refused (401); a read-only token's writes refused with nothing changed; another person's
  notes out of reach of tools, resources and prompts; resources; prompts; and the limit on calls.
- **`test/browser.test.mjs`** (3 tests, in Chromium): sign in with the mailed link; write a note and
  see its preview render as it is typed, then save it; find it by searching, the word highlighted.
  Every page hydrates with strict checks and no errors.
- **`test/copies.test.mjs`** (1 test): `McpHttp.roc` is still packages/mcp's `server/McpHttp.roc`.

Also tried by hand: the official MCP TypeScript SDK's v2 client (`@modelcontextprotocol/client`
2.4.0), at protocol version 2026-07-28 and in `auto`, listed the tools, searched, read the index and
got a prompt. With a wrong token it got 401.

## Product calls

- **No passwords, and no sign-up.** Anyone who can read an address's mail may sign in as it, and an
  address new to the app gets a notebook. The answer to "mail me a link" is the same whether the
  address has notes or not, so the form tells nobody who uses the app.
- **A link opens a page with a button**, rather than signing in by itself, because mail scanners
  follow links.
- **Links and sessions are packages/auth's**, in the app's database, each by its token's hash: a
  link for 15 minutes, used once (in one statement, so two clicks can't both sign in); a session for
  30 days, kept going while in use. "Sign out everywhere" ends every session of yours. The `people`
  table's `session_epoch` column is from before, when the app signed its own cookies; nothing uses
  it now.
- **Tokens start read-only** in the form: writing is the choice you make. A token's last use is
  written at most once a minute, so a busy agent writes one row a minute, not one per call.
- **An AI client needs a token**, even from the browser the person is signed in on. An agent acts
  for you only with a token you made for it, and that you can revoke.
- **Deleting takes two steps on the pages** (archive, then delete for good), and no MCP tool
  deletes. The JSON API's `DELETE /api/notes/<id>` is the exception: with a token that may write
  (or your session cookie), it deletes any of your notes, archived or not.
- **Search covers archived notes** (marked as archived); the lists don't. A note's id is a number,
  but a note that isn't yours is answered exactly as one that doesn't exist.
- **`tag_note` sets all of a note's tags**, as the API's `PUT` does, so an agent reads the note
  first.
- **Limits:** five sign-in links an hour to an address (then one every 12 minutes), and 120 MCP calls
  a minute for each token (then two a second). Sign-in links are limited by the address they are
  mailed to, because the inbox is what needs protecting; MCP calls by the token.

## What it asked of the platform

Writing the app turned up gaps in the platform and the packages. Most are fixed now (a form's
unticked checkbox, the app's public address, a plain form's flash, guard's refusal of a plain form,
404s from `Endpoint.get!`, typed submissions in the browser). These are still worth knowing:

1. **A package's server modules are copied in by hand.** packages/mcp's HTTP side (`McpHttp`)
   imports the server platform, so `rocx build` doesn't copy it into an app, as its README says. The
   app keeps a word-for-word copy, and `test/copies.test.mjs` fails when it drifts.
2. **The MCP server is mounted in `main.roc`, not as a route.** Its tools run the endpoints'
   handlers (`Generated/Handlers`), which import every route file, so no module a route imports may
   import them. `Agents.mount` is a middleware that `main.roc` puts after the default one; it answers
   `/mcp` behind its own middleware (`Middlewares.agent`, then `agent_limit`). `rocx routes` doesn't
   list `/mcp`.
3. **Every field of a tool's arguments is required** (packages/mcp's README), so an agent sends
   `"tags": []` to `create_note`. The search box's `#tag` syntax keeps `search_notes` to one field.
4. **guard's Content-Security-Policy refuses the OpenAPI page**, which loads Scalar from jsDelivr.
   `Middlewares.security` leaves `/openapi.html` out.
5. **Roc gotchas met on the way:**
   - `{ ttl_ms }` alone is a block, not a record: write `{ ttl_ms: ttl_ms }`.
   - A tag isn't a function: write `map_err(|why| BadRequest(why))`, not `map_err(BadRequest)`.
   - A list's `keep_if` takes a pure function, so a page reads its endpoint once before filtering.
6. **SQLite has no regular expressions, and no search engine's syntax.** The app moved from
   Postgres to SQLite, and two things are now done in Roc:
   - What a body reads as (`Note.plain`, the text without Markdown's marks) was a column Postgres
     generated with `regexp_replace`. Now `Store` writes it with every body, so an append reads the
     body and writes it back, in a transaction. The seed carries its own.
   - Postgres's `websearch_to_tsquery` is `Store.matching`, which makes an FTS5 query of the words
     (`"launch" NOT "rehearsal"`).

   What differs from Postgres: FTS5 keeps stopwords, so every word asked for (`the`, `for`) must be
   in the note; a link's address isn't searched, because `Note.plain` leaves it out; and a snippet
   is one piece of about 24 words, not two.
7. **Tags are a JSON column.** SQLite has no arrays, so a note's tags are a column declared `json`:
   written as `Text(Json.to_str(tags))`, read back as a list, and searched with `json_each`
   (`Store.tagged`, and the sidebar's counts).
