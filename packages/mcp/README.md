# mcp

A Roc Solid app as an MCP server: AI agents and the apps they run in (Claude, an IDE, the MCP
Inspector) call its tools, read its resources and use its prompts, over the
[Model Context Protocol](https://modelcontextprotocol.io/specification). An endpoint the app already
has becomes a tool in a line, and the JSON Schema of its arguments is the one the platform writes
for `/openapi.json`, from the same types.

```roc
import mcp.Mcp
import mcp.Tool
import McpHttp

## What the app offers agents.
server : Mcp.Server(McpHttp.Caller(Context))
server = {
    name: "notes",
    version: "1.0.0",
    instructions: "Notes, by id: list them, then read or add one.",
    tools: [
        McpHttp.endpoint(Api.post_api_notes({}), { name: "add_note", description: "Adds a note" }, McpHttp.openapi({})),
        McpHttp.function(Notes.search!, { name: "search", description: "Finds notes by their words" }, McpHttp.openapi({})).read_only(),
    ],
}
```

and, in `main.roc`, behind the middleware that decides who may ask:

```roc
program = App.program({
    context: |started| { secret: started },
    middleware: Middlewares.signed_in.then(McpHttp.middleware("/mcp", Agents.server)),
})
```

## Two halves

**The protocol is a Roc package** (`main.roc`): plain Roc on no platform. It reads a request,
checks it, answers it or says what to run, and writes the answer. It has no effects of its own:
tools, resources and prompts are functions the app gives it. Its expects run the spec's example
messages through it.

| Module | What it does |
|---|---|
| `Mcp` | `Mcp.Server(ctx)`: what the server offers; `handle!(server, incoming, ctx)`, a request's answer; `receive(server, incoming)`, the same, pure: `Reply(answer)` or `Run(running)`; `progress`, a progress notification; `problems(server)`, for the app's own test; `versions` |
| `Tool` | `Tool.typed(name, description, schema, run!)`: arguments read into a Roc type, the answer written as JSON; `Tool.new`: any JSON in, content out; hints (`read_only`, `additive`, `idempotent`, `closed_world`), `titled`, `answers(schema)`, `reporting`; `Tool.text`, `Tool.structured` |
| `Resource` | `Resource.text(uri, name, mime, read!)`, `Resource.new(uri, name, read!)`: what reading a URI gives; `Resource.contents(uri, mime, Text(…) or Blob(bytes))` |
| `Template` | `Template.new("notes://note/{id}", name, read!)`: a family of resources, read with the values the URI gave the template's names; `Template.matching` |
| `Prompt` | `Prompt.new(name, description, arguments, get!)`: messages made from string arguments (`Prompt.argument`, `Prompt.optional`; `Prompt.user`, `Prompt.assistant`) |
| `Content` | what a tool answers with: `Text`, `Image`, `Audio` (bytes, sent as Base64), `Link` (to a resource), `Embedded` (a resource's contents) |
| `Auth` | the pieces of OAuth's answers, for the app's middleware: `bearer` (the token a request carries), `challenge` (401 and `WWW-Authenticate`), `insufficient` (403), `metadata` (RFC 9728, `/.well-known/oauth-protected-resource`) |
| `JsonValue` | any JSON, read a field at a time; `decode` into a Roc type and `encode` from one, through `Json`. A number keeps the text it came as, so an id or an `I64` goes back exactly |
| `Rpc` | JSON-RPC 2.0: `read` one message, write a `result`, an `error` or a `notification`; the error codes |

`roc test packages/mcp/main.roc` runs their `expect`s. Base64 is `packages/crypto`'s, which this
package names itself: an app names `mcp` alone.

**The HTTP side is a module on the server platform** (`server/McpHttp.roc`). It imports the
platform's `Server`, `Endpoint`, `OpenApi`, `Events`, `Middleware` and `Log`, and a package can't
import a platform for an app's two halves at once (see packages/charts). `server/main.roc` makes it
a package of its own that names the server platform, so `roc check packages/mcp/server/main.roc`
checks it. An app can't name that package yet: `rocx build` puts every package in the server's
header into the browser's, where that platform is the wrong one (PROPOSALS.md, "Server-only modules
in packages"). Until it can, copy `server/McpHttp.roc` into the app (`Agents/McpHttp.roc`), and
name the protocol's package `mcp` in the app's header:

```roc
app [program] { mcp: "../packages/mcp/main.roc", pf: platform "../server/platform/main.roc" }
```

| `McpHttp.` | |
|---|---|
| `middleware(path, server)` | the MCP server as a middleware: it answers `path`, and hands every other request on. Put it after the middleware that decides who may ask |
| `respond!(server, request, context)` | the answer to a request to the MCP route; a route file's `respond!` can call it (`routes/mcp/+server.roc`), for a server whose tools aren't `Api`'s (a route file can't import `Api` yet: PROPOSALS.md) |
| `endpoint(Api.x({}), about, McpHttp.openapi({}))` | an endpoint as a tool: its body is the arguments, its answer the tool's; run as `Endpoint.run!` runs it; a refusal goes back to the model |
| `function(Module.name!, about, McpHttp.openapi({}))` | a function of the app's own (`arg => result`) as a tool, run in the MCP request, behind the MCP route's middleware |
| `tool(about, handler!, McpHttp.openapi({}))` | a handler of the app's own, `arg, Caller(c) => Try(result, Str)`, its schemas from its types |
| `Caller(c)` | what a tool is given: `{ request, context, progress! }`. `context` is what the middleware handed on: who is asking |
| `About` | `{ name, description }`, and `title`, `tags` if wanted |
| `response(answer)` | an answer of the protocol's (`Auth.challenge(…)`) as a `Server.Response` |

`McpHttp.openapi({})` is the platform's schema writers, given as a value: a generic function can't
read a type with `Json` and describe it with `OpenApi` both (each wants its own `parser_for`), so
they are instantiated where the call has the types.

## A server

`Mcp.Server(ctx)` is a record; only `name` and `version` are needed.

| Field | |
|---|---|
| `name`, `version` | the server's, as clients show them |
| `title` | its name for people |
| `instructions` | for the model: how the tools go together, what to do first |
| `tools`, `resources`, `templates`, `prompts` | what it offers (none of any by default; the capabilities it declares follow) |
| `page_size` | how many of a list go in one answer, with a cursor for the next (100; 0 for all) |
| `ttl_ms` | how long a client may keep a list (current MCP: 300000) |
| `origins` | pages of other sites whose requests are answered (`"https://app.example.com"`); a page of this site always is, a request from no page (an agent, curl) too |

`ctx` is what a tool, a resource or a prompt is given when it runs: `McpHttp.Caller(c)` over HTTP.

## Tools

```roc
## Its arguments and answer are Roc types; its schemas the platform's, from them.
convert! : { celsius : Dec }, McpHttp.Caller(Context) => Try({ fahrenheit : Dec }, Str)
convert! = |{ celsius }, _|
    if (celsius < -273.15) Err("Below absolute zero") else Ok({ fahrenheit: celsius * 9.0 / 5.0 + 32.0 })

McpHttp.tool({ name: "convert", description: "Celsius to Fahrenheit" }, convert!, McpHttp.openapi({})).read_only()
```

- The answer is the result's JSON, as text (for the model) and as `structuredContent`, with its
  `outputSchema`. An answer that isn't an object is its `result` field; arguments that aren't one
  (a `Str`) are its `input` field.
- `Err("…")`, or arguments that don't fit the type, go back to the model as a tool error
  (`isError`), which it can read and act on. An unknown tool is a JSON-RPC error.
- `Tool.new(name, description, schema, |args, ctx| …)` takes the arguments as a `JsonValue` and
  answers `Tool.text(…)`, `Tool.structured(…)`, `Answered({ content, structured })` (images,
  links), `Refused(why)`, or `Failed(why)`: a JSON-RPC error that only says the tool failed, its
  reason in the server's log.
- `.reporting()`: the tool calls `progress!(done, total, message)` (`|args, { progress!, .. }| …`), and a client that asks to
  hear (a `progressToken`, `Accept: text/event-stream`) gets the answer as a stream of server-sent
  events, each step as it is taken, then the answer. A client that doesn't ask gets JSON, and
  `progress!` does nothing.

## Resources, templates, prompts

```roc
resources: [Resource.text("notes://index", "index", "text/markdown", |_| Ok(Notes.index!({})))],
templates: [Template.new("notes://note/{id}", "note", read_note!).described("A note, by its id")],
prompts: [Prompt.new("summarize", "Summarizes a note", [Prompt.argument("id", "The note's id")], |args, _|
    Ok({ description: "", messages: [Prompt.user("Summarize note ${args.get("id") ?? ""}.")] }))],
```

A URI no resource and no template has is "Resource not found", with the URI. A template's name
takes one character or more, up to its next literal text, and never a `/` unless it is the last
thing in the template; its value is percent-decoded. A prompt's missing required argument is an
invalid-params error, before `get!` runs.

## Who may ask

The middleware in front of the MCP route decides, as for any route: a session cookie, an API key,
an OAuth access token. `Auth` has the answers OAuth wants for the last:

```roc
bearer = Middleware.make(|request, context, next!|
    match Auth.bearer(request.headers) {
        Ok(token) if Tokens.good!(token) => next!(request, context)
        _ => McpHttp.response(Auth.challenge({ resource_metadata: "https://notes.example/.well-known/oauth-protected-resource", scope: "notes" }))
    })
```

and `Auth.metadata({ resource, authorization_servers, scopes })` is the document to serve at
`routes/.well-known/oauth-protected-resource/+server.roc`. Issuing the tokens (an authorization
server) is a proposal (PROPOSALS.md).

A request a browser sends from a page of another site (its `Origin`) is refused with 403, so a page
can't reach a server on the reader's own computer (DNS rebinding).

## What it speaks

MCP over Streamable HTTP: one endpoint, a JSON-RPC message a POST, answered with JSON (or a stream
of events, for a reporting tool). Both eras of the protocol, on the same endpoint:

- **2026-07-28**, the current one: no handshake. Each request says its version and the client's
  capabilities in its `_meta`, and its headers repeat them (`MCP-Protocol-Version`, `Mcp-Method`,
  `Mcp-Name`). `server/discover` says what the server offers. Results say `resultType`; lists and
  reads say how long a client may keep them (`ttlMs`, `cacheScope`).
- **2025-11-25, 2025-06-18, 2025-03-26**: `initialize`, answered with the version asked for if the
  server speaks it (or its latest earlier one), then `notifications/initialized`, `ping`, and the
  rest. The server keeps no session: it sends no `Mcp-Session-Id`, which these allow.

`GET` and `DELETE` are 405: the server pushes nothing, and has no session to end. Statuses: 202 for a
notification; 400 for a body that isn't one JSON-RPC message, a version the server doesn't speak, a
header that doesn't match, `_meta` without what it needs; 404 for no such method (current MCP); 403
for a page of another site; 415 for a body that isn't JSON. A method's own errors (an unknown tool,
a bad cursor, no such resource) are JSON-RPC errors in a 200.

## Testing an app's server

`Mcp.receive` is pure, so an app's expects can send its server requests and read the answers
without a network, as `Mcp.roc`'s do. `Mcp.problems(server)` names what MCP won't take: tool names
outside 1 to 128 of `A-Z a-z 0-9 _ - .`, a name or URI given twice, a schema that isn't JSON.

```roc
expect Mcp.problems(Agents.server) == []
```

## Status

Works today, tested end to end in a scratch app (`/tmp`, built with `rocx build` and the server
platform; the HTTP glue copied in, and also named as a package once rocx leaves it out of the
browser's half):

- The official clients: the MCP Inspector's CLI (2.16.0, which speaks 2025-11-25) and the
  TypeScript SDK's v2 client (`@modelcontextprotocol/client` 2.4.0) pinned to 2026-07-28 and in
  `auto` mode (it asks `server/discover`, and stays current). Tools from an endpoint, a function of
  the app's and handlers, a refusal, an unknown tool, resources, a template, a prompt, and a
  reporting tool's progress, streamed as events, all as the spec says.
- The protocol package: 137 expects.

Waits on a proposal (PROPOSALS.md):

- naming `server/` as a package (or rocx copying it): today it is copied by hand;
- mounting MCP from a route file when its tools are `Api`'s (an import cycle): today, `McpHttp.middleware` in `main.roc`;
- a union's tags in a tool's schema (`Api.tags`): today a tag union none of whose tags are given is "any value";
- the description of an endpoint's tool from its doc comment;
- an authorization server (OAuth) of the platform's own.

## Limits, for now

- No list-change notifications or resource subscriptions (`subscriptions/listen`), no
  `completion/complete`, no logging to the client, no requests from the server (sampling,
  elicitation, or 2026-07-28's `input_required`).
- No sessions: nothing is kept between requests.
- Every record field of a tool's arguments is required (as the platform's schemas say); an optional
  argument is a `Tool.new` tool's.
- Batches (a JSON array of messages) are refused: no revision since 2025-06-18 has them.
