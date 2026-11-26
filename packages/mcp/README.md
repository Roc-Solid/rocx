# mcp

Make a Roc Solid app an MCP server. AI agents, and the apps they run in (Claude, an editor, the
MCP Inspector), call its **tools**, read its **resources** and use its **prompts** over the
[Model Context Protocol](https://modelcontextprotocol.io/specification). An endpoint the app already
has becomes a tool in one line, and the JSON Schema of the tool's arguments is the one the platform
writes for `/openapi.json`, from the same Roc types.

The user guide, with real requests and the package's answers, is the docs site's
[MCP page](https://roc-solid.github.io/ecosystem/mcp). This file is the reference.
`examples/notes` is a complete app whose notes agents search, read and write over MCP.

## Installing it

Name it in the app's header as `mcp`. It has two parts, one package:

- **The protocol** (`Mcp`, `Resource`, `Template`, `Prompt`, `Rpc`, `Bearer`): plain Roc on no
  platform, which the browser's half of an app may import too (`browser.roc` lists them).
- **The HTTP side** (`McpHttp`): on the server platform, it serves the protocol at a path and makes
  tools from the app's endpoints. `import mcp.McpHttp`; nothing is copied.

```roc
# main.roc
app [program] { mcp: "…/packages/mcp/main.roc", pf: platform "…/server/platform/main.roc", tools: "…/packages/tools/main.roc" }
```

The package is not a plugin, and it has no components: its readers are agents, not people. It
depends on `packages/crypto` (for Base64), `packages/tools` and the server's platform, which it
names itself. What a tool is (`Tool`), what it answers (`Content`) and `JsonValue` are
packages/tools', not this package's (D-085): packages/ai gives the same tools to Claude. An app that
makes tools names `tools` too, and imports `tools.Tool`.

## A first server

A server is a record. This one makes three of the app's endpoints and one of its functions into
tools:

```roc
# Agents.roc
import mcp.Mcp
import mcp.McpHttp
import Generated/Handlers   # each endpoint with its handler, which a tool runs

## What the app offers agents.
server : Mcp.Server(McpHttp.Caller(Context))
server = {
    name: "notes",
    version: "1.0.0",
    instructions: "Notes, by id: list them, then read or add one.",
    tools: [
        McpHttp.endpoint(Handlers.post_api_notes, { name: "add_note", description: "Adds a note" }, McpHttp.openapi({})),
        McpHttp.endpoint(Handlers.get_api_notes_id, { name: "read_note", description: "A note, by its id" }, McpHttp.openapi({})).read_only(),
        McpHttp.function(Notes.search!, { name: "search", description: "Finds notes by their words" }, McpHttp.openapi({})).read_only(),
    ],
}
```

Mount it in `main.roc`, after the middleware that decides who may ask:

```roc
program = App.program({
    init!: |started| Ok({ secret: started }),
    middleware: Middlewares.signed_in.then(McpHttp.middleware("/mcp", Agents.server)),
})
```

Why `main.roc`: the tools run the endpoints' handlers through `Generated/Handlers`, and
`Generated/Handlers` imports every route file that has endpoints. So a module those route files
import can't import it (that would be an import cycle), but `main.roc`, or a module only `main.roc`
imports, can. A route file that has `respond!` and no endpoints may serve it too
(`routes/mcp/+server.roc`, with its own `middleware`), because `Generated/Handlers` doesn't import
such a file:

```roc
respond! = |{ request, context, .. }| McpHttp.respond!(Agents.server, request, context)
```

## The protocol's modules

The protocol reads a request, checks it, and either answers it or says what to run. It has no
effects of its own: tools, resources and prompts are functions the app gives it.
`roc test packages/mcp/main.roc` runs the expects, including the spec's example messages.

| Module | What it has |
|---|---|
| `Mcp` | `Mcp.Server(ctx)`: what the server offers ([below](#the-server-record)). `handle!(server, incoming, ctx)`: a request's answer. `receive(server, incoming)`: the same, pure: `Reply(answer)` or `Run(running)`. `progress(running, done, total, message)`: a progress notification. `problems(server)`: for the app's own test. `versions`: the versions it speaks, current first. Types: `Incoming`, `Answer`, `Era`, `Step`, `Running`, `Ran`. |
| `Resource` | `Resource.text(uri, name, mime, read!)` and `Resource.new(uri, name, read!)`: what reading a URI gives. `titled`, `described`, `typed(mime)`. `Resource.contents(uri, mime, Text(…) or Blob(bytes))`. |
| `Template` | `Template.new("notes://note/{id}", name, read!)`: a family of resources; `read!` gets the values the URI gave the template's names, and the URI. `titled`, `described`, `typed(mime)`. `Template.matching(pattern, uri)`. |
| `Prompt` | `Prompt.new(name, description, arguments, get!)`: messages made from string arguments. `Prompt.argument` (required), `Prompt.optional`; `Prompt.user`, `Prompt.assistant`; `titled`. |
| `Bearer` | The pieces of OAuth's answers, for the app's middleware: `token`, `challenge`, `insufficient`, `metadata` ([below](#who-may-ask)). |
| `Rpc` | JSON-RPC 2.0: `read` one message; write a `result`, an `error` or a `notification`; the error codes, MCP's own among them (`header_mismatch`, `missing_capability`, `unsupported_version`). |

`Tool`, `Content` and `JsonValue` are in packages/tools ([its README](../tools/README.md)): a tool
made there is served here as it is, and packages/ai's models use it too.

## The HTTP side

`McpHttp` imports the server platform (`Server`, `Endpoint`, `OpenApi`, `Events`, `Middleware`,
`Log`), so the package names it, and its `browser.roc` lists the protocol's modules alone for the
browser's half of an app (D-033, as packages/push and packages/guard do). `roc test
packages/mcp/main.roc` runs McpHttp's expects with the protocol's.

| `McpHttp.` | What it is |
|---|---|
| `middleware(path, server)` | The MCP server as a middleware: it answers requests to `path` and passes every other request on. Put it after the middleware that decides who may ask. |
| `respond!(server, request, context)` | The answer to one request to the MCP route, for a route file's `respond!`. |
| `endpoint(Handlers.x, about, McpHttp.openapi({}))` | An endpoint as a tool. `Handlers.x` is the function from the endpoint's path params to the endpoint, from `Generated/Handlers` (which has the handler), not `Generated/Api` (the contract alone). The tool's arguments are one object, read both as the path's params and as the body: `{ "id": "7", "tags": ["work"] }` for `Handlers.put_api_notes_id_tags`. An endpoint with no params takes its body alone. It runs as `Endpoint.run!` runs it, with the MCP route's request and context; its own middleware doesn't run (the MCP route's has). Its answer is the tool's, and a refusal (`NotFound`, `BadRequest`) goes back to the model as a tool error. A body field with the same name as a path param is a problem `Mcp.problems` reports. |
| `function(Module.name!, about, McpHttp.openapi({}))` | A function of the app's own, `arg => result`, as a tool, run inside the MCP request, behind the MCP route's middleware. An argument that isn't a record is the arguments' `input` field. |
| `tool(about, handler!, McpHttp.openapi({}))` | A handler written for the tool, `arg, Caller(c) => Try(result, Str)`, its schemas written from its types. |
| `Caller(c)` | What a tool is given: `{ request, context, progress! }`. `context` is what the middleware passed on, such as who is asking. |
| `About` | `{ name, description }`, and optionally `title` and `tags` (the names of the tags in its types' unions, for their schemas). |
| `response(answer)` | One of the protocol's answers (`Bearer.challenge(…)`) as a `Server.Response`. |
| `openapi({})` | The platform's schema writers (`OpenApi`'s), as a record. |

`McpHttp.openapi({})` is always the same argument. It exists because of a compiler limit: a generic
function can't both read a type with `Json` and describe it with `OpenApi` (each needs its own
`parser_for` on the type), so the writers are passed in as a value and instantiated where the call
knows the types. PROPOSALS.md 4 has the upstream fix that would drop it.

A tool that fails inside (`Failed`) is logged as an error with the reason; the client is only told
that it failed.

## The server record

`Mcp.Server(ctx)` needs only `name` and `version`.

| Field | What it is |
|---|---|
| `name`, `version` | The server's, as clients show them. |
| `title` | Its name for people. |
| `instructions` | For the model: how the tools fit together, what to do first. |
| `tools`, `resources`, `templates`, `prompts` | What it offers. None by default; the capabilities the server declares follow from which are given. |
| `page_size` | How many items of a list go in one answer, with a cursor for the next page (default 100; 0 for all). |
| `ttl_ms` | How long a client may keep a list, in current MCP (default 300000, 5 minutes). |
| `origins` | Pages of other sites whose requests are answered (`"https://app.example.com"`). A page of the server's own site always is, and so is a request from no page (an agent, curl). |

`ctx` is what a tool, a resource or a prompt is given when it runs: `McpHttp.Caller(c)` over HTTP.

## Tools

```roc
## Its arguments and its answer are Roc types; its schemas are the platform's, from them.
convert! : { celsius : Dec }, McpHttp.Caller(Context) => Try({ fahrenheit : Dec }, Str)
convert! = |{ celsius }, _|
    if (celsius < -273.15) Err("Below absolute zero") else Ok({ fahrenheit: celsius * 9.0 / 5.0 + 32.0 })

McpHttp.tool({ name: "convert", description: "Celsius to Fahrenheit" }, convert!, McpHttp.openapi({})).read_only()
```

- The answer is the result's JSON, sent twice: as text, for the model, and as `structuredContent`,
  with its `outputSchema`. An answer that isn't an object goes in a `result` field. Arguments that
  aren't an object (a tool that takes a `Str`) come in an `input` field.
- `Err("…")`, and arguments that don't fit the type, go back to the model as a tool error
  (`isError`), which it can read and act on. An unknown tool is a JSON-RPC error.
- `Tool.new(name, description, schema, |args, ctx| …)` takes the arguments as a `JsonValue` (a
  schema of `""` takes any object) and answers an `Outcome`: `Tool.text(…)`, `Tool.structured(…)`,
  `Answered({ content, structured })` (for images and links), `Refused(why)`, or `Failed(why)`. A
  failure is a JSON-RPC error that only says the tool failed; its reason goes to the server's log.
- Hints tell the client what the tool does, so it can ask the user before running one that changes
  things: `read_only` (changes nothing), `additive` (changes things but never deletes or
  overwrites), `idempotent` (running it twice does no more than once), `closed_world` (reaches
  nothing outside the app).
- `.reporting()`: the tool may call `progress!(done, total, message)` (`|args, { progress!, .. }| …`;
  `total` 0 for unknown). A client that asks to hear progress (a `progressToken`, and
  `Accept: text/event-stream`) gets the answer as a stream of server-sent events: each step as it is
  taken, then the answer. A client that doesn't ask gets JSON, and `progress!` does nothing.

## Resources, templates, prompts

```roc
resources: [Resource.text("notes://index", "index", "text/markdown", |_| Ok(Notes.index!({})))],
templates: [Template.new("notes://note/{id}", "note", read_note!).described("A note, by its id")],
prompts: [Prompt.new("summarize", "Summarizes a note", [Prompt.argument("id", "The note's id")], |args, _|
    Ok({ description: "", messages: [Prompt.user("Summarize note ${args.get("id") ?? ""}.")] }))],
```

- A URI that no resource and no template has is answered "Resource not found", with the URI.
- A template's `{name}` takes at least one character, up to the template's next literal text. It
  never takes a `/`, unless it is the last thing in the template, so `files://{path}` matches
  `files://docs/a.md`. Its value is percent-decoded. `read!` answers `Err(NotFound)` when nothing is
  there.
- A prompt's missing required argument is an invalid-params error, sent before `get!` runs.

## Who may ask

The middleware in front of the MCP route decides, as it does for any route: a session cookie, an API
key, an OAuth access token. examples/notes takes a personal access token (`Middlewares.agent`) and
limits how often each token may ask. For OAuth, `Bearer` has the answers the spec wants:

- `Bearer.token(headers)`: the token a request carries (`Authorization: Bearer …`), or `NoToken`.
- `Bearer.challenge({ resource_metadata, scope })`: a 401 with `WWW-Authenticate`, which says where
  the client learns how to get a token.
- `Bearer.insufficient({ resource_metadata, scope })`: a 403 for a good token without the scope.
- `Bearer.metadata({ resource, authorization_servers, scopes })`: the protected resource metadata
  document (RFC 9728), to serve at `routes/.well-known/oauth-protected-resource/+server.roc`.

```roc
bearer = Middleware.make(|request, context, next!|
    match Bearer.token(request.headers) {
        Ok(token) if Tokens.good!(token) => next!(request, context)
        _ => McpHttp.response(Bearer.challenge({ resource_metadata: "https://notes.example/.well-known/oauth-protected-resource", scope: "notes" }))
    })
```

Not yet: issuing tokens. An authorization server of the platform's own is proposal 5 in
PROPOSALS.md.

Separately, a request a browser sends from a page of another site (its `Origin`) is refused with
403, so a web page can't reach an MCP server on the reader's own computer (DNS rebinding).

## What it speaks

MCP over Streamable HTTP: one endpoint, where each POST carries one JSON-RPC message and is answered
with JSON, or with a stream of events for a reporting tool. The same endpoint speaks both eras of
the protocol:

- **2026-07-28**, the current version, has no handshake. Each request states its version and the
  client's capabilities in its `_meta`, and its headers repeat them (`MCP-Protocol-Version`,
  `Mcp-Method`, `Mcp-Name`; a name that isn't plain ASCII is sent as `=?base64?…?=`).
  `server/discover` says what the server offers. Results carry `resultType`, and lists and reads say
  how long a client may keep them (`ttlMs`, `cacheScope`).
- **2025-11-25, 2025-06-18, 2025-03-26** start with `initialize`, answered with the version asked
  for if the server speaks it, or else its latest earlier one. Then come
  `notifications/initialized`, `ping` and the rest. The server keeps no session, which these
  versions allow, so it sends no `Mcp-Session-Id`.

| A request | Is answered |
|---|---|
| a notification, or a response | 202, with an empty body |
| a body that isn't JSON (by its `Content-Type`) | 415 |
| not one JSON-RPC message (invalid JSON, a batch, no method) | 400, a JSON-RPC error |
| a version the server doesn't speak, a header that doesn't match the body, `_meta` missing what it needs | 400, a JSON-RPC error |
| a method that doesn't exist | 404 in current MCP; a JSON-RPC error in a 200 in earlier MCP |
| an unknown tool, a bad cursor, a resource that doesn't exist | 200, a JSON-RPC error |
| arguments that don't fit a tool, or a tool's refusal | 200, a tool result with `isError` |
| from a page of another site | 403 |
| `GET`, `DELETE` | 405: the server pushes nothing, and has no session to end |

## Testing an app's server

`Mcp.receive` is pure, so an app's expects can send its server requests and read the answers with
no network, as `Mcp.roc`'s own expects do. `Mcp.problems(server)` lists what MCP won't accept: a
tool name outside 1 to 128 of `A-Z a-z 0-9 _ - .`, a name or a URI given twice, a schema that isn't
JSON, and an endpoint's tool whose path params and body share a field name.

```roc
expect Mcp.problems(Agents.server) == []
```

## Status

Tested:

- The protocol: 93 expects, and McpHttp's 2 (`Tool`, `Content` and `JsonValue` are packages/tools',
  with theirs).
- End to end, in scratch apps built with `rocx build` on the server platform, with the official
  clients: the MCP Inspector's CLI (2.16.0, which speaks 2025-11-25) and the TypeScript SDK's v2
  client (`@modelcontextprotocol/client` 2.4.0), pinned to 2026-07-28 and in `auto` mode (it asks
  `server/discover` and stays current). Tools from an endpoint, a function and a handler; a refusal;
  an unknown tool; resources; a template; a prompt; and a reporting tool's progress, streamed as
  events.
- examples/notes, whose tests call its tools over JSON-RPC.

Waiting on a proposal (PROPOSALS.md):

1. a union's tags in a tool's schema (`Api.tags`): today a tag union none of whose tags are given in
   `About.tags` is "any value";
2. an endpoint's doc comment as its tool's description (today the app repeats it);
3. an OAuth authorization server of the platform's own.

## Limits

- Not yet: list-change notifications, resource subscriptions (`subscriptions/listen`),
  `completion/complete`, logging to the client, and requests from the server to the client
  (sampling, elicitation, 2026-07-28's `input_required`).
- No sessions: nothing is kept between requests.
- Every record field of a typed tool's arguments is required, as the platform's schemas say. For an
  optional argument, use a `Tool.new` tool.
- Batches (a JSON array of messages) are refused: no revision since 2025-06-18 has them.
