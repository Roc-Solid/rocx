# Acme Notes

Personal notes in Markdown, in Roc Solid, that AI agents can use too. Each person signs in with a
link mailed to them, writes notes with a live preview, tags them, pins and archives them, and finds
them again with full-text search. An AI client (Claude, an IDE, the MCP Inspector) searches, reads
and writes the same notes over MCP, with a personal access token the person made for it. Each
person sees only their own notes, whichever way they ask.

## A tour

1. Open the app and you are sent to sign in: type `ada@example.com` (the seeded person with notes)
   or any address. A link is mailed; on a local run it lands in the dev mailbox,
   http://localhost:18160/__rocx/mail. The link opens a page with a **Sign in** button, so a mail
   scanner that follows links doesn't use yours up. A link works once, for 15 minutes. Someone new
   starts with a note of welcome.
2. The notebook: cards with the start of each note, pinned ones first, and your tags down the side
   with their counts. A tag's link shows its notes; **Archive** shows the archived ones.
3. Search from the box at the top: words (`rehearsals` finds "rehearsal"), `"an exact phrase"`,
   `or`, `-without`, and `#tag` to look only at a tag's notes (`launch #meetings`). The results come
   best first, archived notes too, with the words found highlighted.
4. Open a note: its Markdown as it reads, its tags, and **Edit**, **Pin**, **Archive**. An archived
   note can be restored, or deleted for good. Deleting takes two steps, so a slip loses nothing.
5. **New note** or **Edit**: the title, tags (`work, ideas`) and Markdown, with a preview beside it,
   rendered as you type. On a phone, Write and Preview are tabs.
6. **Settings**: make a personal access token, read-only or not. It is shown once, with the command
   that connects Claude Code to it. Revoke a token, see when each was last used, or sign out of
   every browser at once.
7. Connect an AI client with that token (below) and ask it about your notes: "what did I plan for
   launch week?", "add 'buy rye flour' to my sourdough note", "capture this as a note".
8. Turn JavaScript off: signing in, the editor (without its live preview), every button and the
   search still work, as plain forms and links.

## What it shows

| Feature | Where |
|---|---|
| Sign-in by a mailed link: the form, `Email.send!` (packages/email's plugin, D-035), the landing page and its button | `routes/sign-in/`, `routes/sign-in/link/`, `Account.send_link!`, `main.roc` (`Email.plugin`) |
| A single-use token with a time to live, in `Kv` (D-028), kept by its hash; why `Kv` and not Postgres | `Account.roc` (its `##` comment, `use_link!` with `Kv.take!`), `Token.link` |
| A session cookie signed with HMAC-SHA256 (packages/crypto), refused when forged, expired or signed out everywhere, with its `expect`s | `Session.roc`, `Account.session!`, `Account.signed_in!` |
| Signing out, and out of every browser (a session epoch) | `routes/sign-out/`, `routes/settings/everywhere/`, `Store.sign_out_everywhere!` |
| Middleware that puts the person into the context and guards pages, the API and MCP | `Middlewares.roc` (`signed_in`, `api`, `agent`), each route file's `middleware = …` |
| Personal access tokens: made, shown once, kept as SHA-256 only, named, last use noted, read-only, revoked | `routes/settings/`, `Token.roc` (with its `expect`s), `Account.make_token!`, `Store.bearer!` |
| An MCP server (packages/mcp) at `/mcp`: six tools with their hints, notes as resources, two prompts | `Agents.roc` |
| MCP tools made of the JSON API's endpoints (`McpHttp.endpoint`, and `Endpoint.run!` for those with an id) | `Agents.roc` (`server`, `read_note!` and the others) |
| Bearer tokens turned into the person, so a token never reaches another's notes; read-only tokens refused for writes | `Middlewares.agent`, `Notebook.writer`, `Store.roc` (every query names the person) |
| The JSON API, and its OpenAPI document with Scalar (`openapi: Page(Scalar)`) | `routes/api/`, `main.roc`, `/openapi.html` |
| Rate limits (packages/guard): sign-in links for each address, MCP calls for each token | `Middlewares.mail_limit`, `Middlewares.agent_limit` |
| Full-text search in Postgres: a generated `tsvector`, `websearch_to_tsquery`, ranking, `ts_headline` snippets | `migrations/0001_notes.sql`, `Store.search!`, `Note.query_of`, `Note.pieces` |
| Matches highlighted as text, never as markup | `Note.pieces`, `Ui/NoteCard.rocx` (`snippet`) |
| Markdown rendered by packages/markdown: on a note's page by the server alone (`<NoHydration>`), in the editor's preview by the browser as you type | `Ui/Prose.rocx`, `routes/notes/[id]/+page.rocx`, `Ui/Editor.rocx` |
| One rule set for every write, whoever sends it (a page, a script, an agent) | `Note.roc` (rules, with `expect`s), `Notebook.roc` (operations) |
| Appends that never overwrite each other (one statement) | `Store.append!` |
| Tags, pinning and archiving | `Notebook.tag!`, `pin!`, `archive!`; `routes/notes/[id]/+server.roc` |
| Pages that read their own endpoint, typed for both halves | `Pages.roc`, each page's `Endpoint.get!` / `read!` |
| A 404 for a note that isn't there or isn't yours (the same page, so ids tell nothing) | `Ui/Missing.rocx` (`<HttpStatusCode>`) |
| Forms without JavaScript, and the same forms sent by the page with it (`use_submission!`) | every `<form method="post">` |
| Pure and effectful components: `view` for what only shows its props, `view!` for what keeps state or sets the status | `Ui/NoteCard.rocx`, `Ui/Topbar.rocx`, `Ui/Prose.rocx` (pure); `Ui/Editor.rocx`, `Ui/Missing.rocx` (effectful) |
| Scoped styles and a look of its own (ink, paper, a highlighter), light and dark, narrow screens | each component's `<style>`; the tokens in `routes/+layout.rocx` |
| Stories for the components (`rocx build --dev`, `/__rocx/stories`) | `<story>` in `Ui/*.rocx` |
| Postgres by migrations, and an idempotent seed | `migrations/` |

## Build and run

The toolchain once (`just setup`), and the platforms' hosts (`just test` builds both). Then, from the
repository's root, with a Postgres (`just db`):

```sh
docker exec rocx-postgres createdb -U rocx acme_notes
export DATABASE_URL=postgres://rocx:rocx@127.0.0.1:55432/acme_notes
export NOTES_SECRET="$(openssl rand -base64 32)"   # signs the session cookies

bin/rocx build examples/notes --client examples/notes/build/client
.tools/roc-active build --target=wasm32 --opt=size --output=examples/notes/build/client/static/rocx/app.wasm examples/notes/build/client/main.roc
node server/build.mjs examples/notes/main.roc examples/notes/build/server
examples/notes/build/server --port 18160 --dev --static examples/notes/build/client/static
```

Open http://localhost:18160 and sign in as `ada@example.com`; the link is in the dev mailbox,
http://localhost:18160/__rocx/mail (`--dev` serves it). The server migrates and seeds the database
as it starts.

| Setting | |
|---|---|
| `DATABASE_URL` | the Postgres |
| `NOTES_SECRET` | what session cookies are signed with (through HKDF). Unset, a key is made at random when first needed and kept in memory, so a restart signs everyone out (the log says so) |
| `NOTES_ORIGIN` | the app's address, for the links in email and the MCP address Settings shows (`http://localhost:18160`) |
| `SMTP_URL` | a mail server (`smtp://user:password@smtp.example.com:587?tls=required`); unset, mail goes to the dev mailbox |
| `NOTES_LINK_TTL_MS` | how long a sign-in link works (900000: 15 minutes) |
| `NOTES_MCP_PER_MINUTE` | MCP calls a minute for each token (120) |

Mail is from `Acme Notes <notes@example.com>` (`Email.plugin`'s `from`, in `main.roc`).

## Connect an AI client

Make a token in **Settings** (read and write, if the agent should change notes), then give it to
the client. The token and everything else below are made up; use your own.

**Claude Code**:

```sh
claude mcp add --transport http acme-notes http://localhost:18160/mcp \
  --header "Authorization: Bearer acme_pat_q7Vd2LkM9xR4tB8nW1yZ5cH3jF6gP0sAeUoIiOuYtRe"
```

Then, in Claude Code, `/mcp` lists `acme-notes` and its tools; ask "search my notes for launch".

**A client that reads a JSON file** (Claude Code's `.mcp.json`, and others in the same shape):

```json
{
  "mcpServers": {
    "acme-notes": {
      "type": "http",
      "url": "http://localhost:18160/mcp",
      "headers": { "Authorization": "Bearer acme_pat_q7Vd2LkM9xR4tB8nW1yZ5cH3jF6gP0sAeUoIiOuYtRe" }
    }
  }
}
```

**The MCP Inspector** (`npx @modelcontextprotocol/inspector`): Transport "Streamable HTTP", URL
`http://localhost:18160/mcp`, and an `Authorization` header with `Bearer acme_pat_…`.

**By hand**, to see what a client sends:

```sh
curl -s http://localhost:18160/mcp \
  -H "Authorization: Bearer acme_pat_q7Vd2LkM9xR4tB8nW1yZ5cH3jF6gP0sAeUoIiOuYtRe" \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_notes","arguments":{"query":"launch"}}}'
```

What the server offers:

| | |
|---|---|
| `search_notes { query }` (read-only) | words, `"phrases"`, `or`, `-without`, `#tag`; best first, archived notes too, the matches marked. `POST /api/search` |
| `read_note { id }` (read-only) | a note whole. `GET /api/notes/<id>` |
| `create_note { title, body, tags }` | a new note (`tags` may be `[]`). `POST /api/notes` |
| `append_to_note { id, text }` | text added at the end, never overwriting. `POST /api/notes/<id>/append` |
| `tag_note { id, tags }` | the note's tags, all of them. `PUT /api/notes/<id>/tags` |
| `archive_note { id, archived }` | archived, or brought back. `PUT /api/notes/<id>/archived` |
| `notes://index` | every note not archived, as a Markdown list |
| `notes://note/{id}` | a note as Markdown |
| `summarize_note { id }`, `capture { text, tags? }` | prompts: a note summarized and tags suggested; rough text made a note, added to a similar one if there is one |

A read-only token's writes are refused, as a tool error the model reads ("This token can only read").
Nothing an agent can do deletes a note.

The same token works for the JSON API (`curl -H "Authorization: Bearer acme_pat_…"
http://localhost:18160/api/me`); http://localhost:18160/openapi.html describes it.

## Test

```sh
.tools/roc-active test examples/notes/main.roc   # the expects
node --test 'examples/notes/test/*.test.mjs'      # needs DATABASE_URL; the browser test needs Chromium
just examples notes                               # both, after building and checking it
```

- **75 `expect`s** in the app's modules: `Session.roc` (a cookie signed and read back, expired,
  forged by another key, with another id, a later time or a newer epoch, and malformed in five
  ways), `Token.roc` (shapes, the hash being SHA-256's, the hint, names), `Note.roc` (titles,
  bodies, tags, the search box's `#tags`, snippets' marks, dates), `Address.roc`, `Query.roc`,
  `Account.path_of` (never another site after signing in), the editor's word count, `NoteCard` and
  `Topbar` rendered and read with packages/testing's `Dom`, and `Mcp.problems(Agents.server)`.
- **`test/http.test.mjs`** (14 tests): signed out, pages send you to sign in and the API and MCP
  refuse; signing in through the mailed link (`waitForMail`, `links`), back where you were going,
  someone new getting a welcome note; a link used again, a made-up one and one past its time
  refused; signing out and out everywhere; the seed, run again adding nothing; a note through the
  pages' forms without JavaScript and with the runtime (written, refused, edited, pinned, archived,
  deleted); search (stemming, phrases, `-without`, `#tags`, highlighting, archived notes); the JSON
  API with a token (every operation, ten appends at once, every refusal); tokens (kept only as a
  hash, never listed, last use, read-only refused, shown once through a plain form's flash,
  revoked); one person never reaching another's notes through a page, an endpoint, the API or a
  token; the OpenAPI document; and the limit on sign-in mail.
- **`test/mcp.test.mjs`** (10 tests): `initialize`, `tools/list` and its hints and schemas,
  `tools/call` of every tool, refusals going back to the model, no token or a bad one or a cookie
  alone refused (401), a read-only token's writes refused with nothing changed, another person's
  notes out of reach of tools, resources and prompts, resources, prompts, and the limit on calls.
- **`test/browser.test.mjs`** (3 tests, in Chromium): sign in with the mailed link, write a note
  and see its preview rendered as it is typed, save it, and find it by searching, the word
  highlighted; every page hydrating strictly, with no errors.
- **`test/copies.test.mjs`** (4 tests): the modules copied from packages (below) are still theirs.

The test files build the app once between them, each with a database and a server of its own.

Also tried by hand: the official MCP TypeScript SDK's v2 client (`@modelcontextprotocol/client`
2.4.0), at the current protocol (2026-07-28) and in `auto`, listed the tools, searched, read the
index and got a prompt; with a wrong token it got 401.

## Product calls

- **No passwords, and no sign-up.** Anyone who can read an address's mail may sign in as it, and an
  address new to the app gets a notebook. The answer to "mail me a link" is the same whether the
  address has notes or not, so the form tells nobody who uses Acme Notes.
- **A link is a page with a button**, not a sign-in by itself: mail scanners follow links.
- **Links live in `Kv`** for 15 minutes, by their hash, and are taken once (`Kv.take!`). A restart
  forgets those on their way, which only means asking again. Sessions are signed cookies (30 days);
  the server keeps none, and "sign out everywhere" raises a number the cookies carry.
- **Tokens start read-only** in the form: writing is the choice to make. A token's last use is
  written at most once a minute, so a busy agent writes one row a minute, not one a call.
- **An AI client needs a token**, even from the browser the person is signed in on: an agent acts
  for you only with a token you made for it, and can revoke.
- **Agents can't delete**, and nor can anyone delete a note that isn't archived.
- **Search covers archived notes** (marked so); the lists don't. A note's id is a number, but a
  note that isn't yours is answered exactly as one that doesn't exist.
- **`tag_note` sets all of a note's tags**, as the API's `PUT` does: an agent reads the note first.
- **Limits:** five sign-in links an hour to an address (then one each 12 minutes), and 120 MCP calls
  a minute for each token (then two a second).

## What it asked of the platform

What the app met, and how it works around each. None needed a change outside the example.

1. **Packages' server modules are copied in by hand.** packages/guard's middleware (`Guard`, `Kept`,
   `FlagStore`) and packages/mcp's HTTP side (`McpHttp`) import the server platform, so `rocx build`
   doesn't copy them into an app, as their READMEs say, and guard keeps its counts in actors, whose
   kinds `rocx build` finds only in the app's own files. Workaround: the four files copied verbatim,
   and `test/copies.test.mjs` failing when they drift.
2. **The MCP server can't be a route** (packages/mcp's PROPOSALS.md, "`Api` imports only route files
   with endpoints"): its tools are `Api`'s endpoints, and a route file can't import `Api`.
   Workaround: `Agents.mount`, a middleware main.roc puts after the default one, which answers
   `/mcp` behind its own middleware (`Middlewares.agent`, `agent_limit`). `rocx routes` doesn't list
   `/mcp`.
3. **`McpHttp.endpoint` can't fill an endpoint's path from a tool's arguments**: `Api.get_api_notes_id({ id })`
   needs its `id` when the tool is made. Workaround: `search_notes` and `create_note` are endpoints
   whole, and the four tools that take an `id` are `McpHttp.tool`s that run the endpoint for that id
   (`Endpoint.run!(Api.get_api_notes_id({ id: id }), caller.request, caller.context, {})`), so they
   still go through the API's code. Something like `McpHttp.endpoint_for(|args| Api.x({ id: args.id }), …)`
   would make them a line each.
4. **Every field of a tool's arguments is required** (packages/mcp's README), so an agent sends
   `"tags": []` to `create_note`. The search box's `#tag` syntax keeps `search_notes` to one field.
5. **`Endpoint.get!` of a 404 makes a 500 page** (examples/tasks met it too). The note's page and
   its editor read with `Endpoint.read!` and show `Ui/Missing.rocx` (`<HttpStatusCode code={404}/>`).
6. **`<Show>`'s function child must be pure**, so a `<Show>` inside it doesn't compile. The sign-in
   link's page shows its form under `when!={link!(token).is_ok()}`, with plain children. (Fixed in
   the platform since: a function child is effectful now, and may hold a `<Show>`.)
7. **The browser's copy needs the types said** (D-030): each page's endpoint read and each
   `use_submission!` is annotated, with the pages' data in `Pages.roc`. `roc check` of the browser's
   program passed without them; its wasm build failed ("This decodes a record whose full set of
   fields is not known"), so check with the build.
8. **The server doesn't pass on the client's address** (packages/guard's README), so `Guard.ip`
   can't tell clients apart. Sign-in links are limited by the address they are mailed to (what needs
   keeping safe is the inbox), and MCP calls by the token.
9. **guard's refusal of a plain form is a page of text**: the rate limit answers before the
   endpoint, so a browser without JavaScript gets "Too many requests" on a page of its own rather
   than back on the form with a flash. With the runtime, the form shows it.
10. **guard's CSP refuses the OpenAPI page**, which loads Scalar from jsDelivr: `Middlewares.security`
    leaves `/openapi.html` out (as examples/journal does).
11. **The app's public address isn't the platform's to know.** A link in email needs it, and a
    request's `Host` is whatever the asker sends (a link to their site, mailed to you, would hand them
    your token). Workaround: `NOTES_ORIGIN`.
12. **A plain form's result travels in the flash cookie**: a token made without JavaScript rides in
    `rocx-flash` (`HttpOnly`, `SameSite=Lax`, 60 s) to the page that shows it, which lets it go.
    With the runtime it never leaves the answer.
13. **An unticked checkbox sends nothing**, so a form whose record has its field fails to read: the
    token's access is two radio buttons, one always ticked.
14. **Fixed: `Db.Value` had no list** (D-016), so tags went as a JSON array, `array(select
    jsonb_array_elements_text($1::jsonb))`. `Db.array` makes a list one parameter now (a Postgres
    array, in text), so `tags @> $3` and `set tags = $5` take `Db.array(tags.map(|tag| Text(tag)))`
    (`Store.roc`). Tags still come back as `array_to_json(tags)`: a row reads JSON's types, and an
    array column asks for a cast.
15. **No modifier keys in key handlers**, so no Ctrl+S to save: the editor saves with its button.
16. **Roc on the way**: `{ ttl_ms }` alone is a block, not a record (`{ ttl_ms: ttl_ms }`); a tag
    isn't a function (`map_err(|why| BadRequest(why))`, not `map_err(BadRequest)`); a list's
    `keep_if` takes a pure function, so a page reads its endpoint once before filtering.
17. **Email moved into packages/email (D-035)** while the app was being written: it names the package,
    imports `email.Email`, and lists `Email.plugin` in `main.roc`.
