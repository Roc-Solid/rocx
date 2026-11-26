# Proposals: what packages/mcp needs outside its folder

Proposals 1 and 2 are done. The others are written up, not built: the package works today without
them, with the workaround each one names. Tried in scratch apps under `/tmp/rocx-pkg-mcp/` (`app`:
the glue copied in; `app2`: the glue named as a package), both built with `rocx build` and
`roc build` on the server platform, and talked to by the MCP Inspector's CLI and the TypeScript
SDK's v2 client.

## 1. Server-only modules in packages

**Done (D-033), as option B was sketched here.** The package names the server platform (`main.roc`
lists `McpHttp` with the protocol's modules), and `browser.roc` lists the protocol's alone, which
`rocx build --client` names in the browser's copy of the app instead (as packages/push, guard and
auth do). Apps write `import mcp.McpHttp`; nothing is copied, and `server/` is gone. The caveat
this section raised holds for every package that names the server platform: Roc wants the app's
platform and the package's at one path, which `rocx new`'s vendored `.rocx` gives.

## 2. `Api` imports only route files with endpoints

**Done, differently (D-037).** `Generated/Api` is the app's contract and imports no route file at
all; each endpoint with its handler is `Generated/Handlers`', which imports only the route files
with endpoints or a channel. So a route of `respond!` alone (`routes/mcp/+server.roc`) may import a
module that imports Handlers, and serve an MCP server whose tools are the app's endpoints
(`test/e2e.test.mjs` runs a handler from such a route). What follows is the proposal as it was.

**Problem.** `Generated/Api.roc` imports every `+server` module (`apiModule` in `src/routes.mjs`),
including one with only `respond!` (D-013), which has no endpoints in `Api`. So a route file can't
import `Api`, or any module that does: `routes/mcp/+server.roc` → `Agents` → `Api` →
`McpServer` is an import cycle, and the compiler refuses it. An MCP server whose tools are the app's
endpoints can't be served from a route file.

**Options considered.** (a) `Api` imports only the modules it uses (those with a method). (b) Serve
MCP from `main.roc` as a middleware: works today (`McpHttp.middleware("/mcp", server)`), and is what
the README shows; but a route's own `middleware = …` (a guard for `/mcp` only) and `rocx routes`'s
listing don't apply to it. (c) Put the tools' endpoints in the MCP route file itself: the endpoints
are elsewhere.

**Recommended: (a)**, a line in `apiModule`:

```diff
-		...(client ? [] : ["import pf.OpenApi", ...[...new Set(table.servers.map((server) => server.module))].sort().map((module) => `import ${module}`)]),
+		...(client ? [] : ["import pf.OpenApi", ...[...new Set(table.servers.filter((server) => sources.get(server.file).methods.length).map((server) => server.module))].sort().map((module) => `import ${module}`)]),
```

A `respond!`-only file is still in `Routes`, which imports it and `Api` both, and no cycle remains.
(A route file with methods that imports `Api` is still a cycle, as it should be.)

**Depends on it.** `routes/mcp/+server.roc` with `middleware = Middlewares.bearer` and
`respond! = |{ request, context, .. }| McpHttp.respond!(Agents.server, request, context)` for any
server. Tried in `app2`'s `/lite` route with a server that doesn't import `Api`: it works.

**Undo.** Revert the line.

## 3. `Api.tags`, and an endpoint's doc comment

**Problem.** A tag union's schema needs the names of its tags: `OpenApi.body(endpoint, tags)` tries
each name rocx found in the app's code. rocx writes that list only inside `Api.openapi`, as a local
(`tags = [...]`), so `McpHttp.endpoint` passes `About.tags`, `[]` by default, and a union in a tool's
arguments is "any value" (`{"description": "A tag union none of whose tags rocx found…"}`). Likewise
rocx has each endpoint's doc comment (it is the operation's `description` in `/openapi.json`), and an
app repeats it as the tool's description.

**Recommended.** `openApiDocument` writes the list as a member, which `openapi` uses, and each
endpoint's comment as a record:

```roc
Api := [].{
	…
	## Every name in the app's code that could be a tag (`OpenApi`).
	tags : List(Str)
	tags = ["A", "Actions", …]

	## What each endpoint's comment says.
	docs = { post_api_convert: "Celsius to Fahrenheit. Below absolute zero is refused.", … }

	openapi : Str
	openapi = OpenApi.document("app", [ … OpenApi.body(post_api_convert({}), tags) … ])
}
```

Then: `McpHttp.endpoint(Api.post_api_convert({}), { name: "convert", description: Api.docs.post_api_convert, tags: Api.tags }, McpHttp.openapi({}))`.

**Depends on it.** Complete schemas for tag unions in tools; descriptions written once.

**Undo.** Drop the two members; `openapi` keeps its local list.

## 4. One type read with `Json` and described with `OpenApi` (the compiler)

**Problem.** A generic function can't both decode a type variable with `Json` and describe it with
`OpenApi`'s format: each is a `parser_for` constraint on the same variable, at a different format,
and "a type has only one parser_for method". Concrete types are fine (the generated `Api` does both,
at each endpoint's types), but a helper over any endpoint is generic. A record of the two writers
(`{ body: OpenApi.body, answer: OpenApi.answer }`) as a top-level value isn't generalized either.

**Today.** `McpHttp.openapi({})`, a function returning the record, is passed in where the types are
known, so the writers are instantiated there: `McpHttp.endpoint(api, about, McpHttp.openapi({}))`.
It works, at the cost of an argument that is always the same.

**Recommended.** An upstream ask, for the user to make (never an agent): a where clause's method
polymorphic in the format (`arg.parser_for : fmt -> …` for every `fmt`), as derived `parser_for`s
already are for concrete types. Then the argument goes. Nothing to change in the repo meanwhile.

**Undo.** Not applicable.

## 5. OAuth: tokens for MCP clients

**Problem.** MCP's authorization is OAuth 2.1 (2026-07-28: optional, but HTTP servers SHOULD). A
client that gets 401 reads `WWW-Authenticate: Bearer resource_metadata="…"`, fetches the protected
resource metadata (RFC 9728), finds the authorization server, registers (a Client ID Metadata
Document; dynamic registration is deprecated), sends the user through the authorization code flow
with PKCE and `resource` (RFC 8707), and calls the server with `Authorization: Bearer …`. The server
checks each token: issued for it (audience), not expired, the scopes the call needs (403
`insufficient_scope` if not). v1 leaves that to the app's middleware, with `Bearer`'s answers.

**Options considered.**

- **a. An external authorization server** (an identity provider the app already uses). The app's
  middleware checks tokens by introspection (RFC 7662: `Http.fetch!` to the provider, cached for the
  token's life), or as JWTs against the provider's keys, which needs RS256 or ES256 verification: a
  host primitive the platform doesn't have (it has `Hmac`, `Sha256`, `AesGcm`).
- **b. The app as its own authorization server**, a package (`packages/oauth`) on the platform's
  pieces: `Db` (clients, grants, codes, token hashes), `Hmac` and `Random.bytes!` (opaque tokens,
  stored hashed), a consent page (a route behind the app's sign-in), and routes for
  `/.well-known/oauth-authorization-server` (RFC 8414), `/oauth/authorize`, `/oauth/token`,
  revocation. Clients identified by their metadata document's URL (fetched with `Http`), PKCE S256
  required, refresh tokens rotated.
- **c. Both**: the package checks tokens through one interface, `Tokens.check! : Str => Try({ subject : Str, scopes : List(Str) }, [Invalid])`, backed by (a) or (b).

**Recommended: c, built in this order.** First, in this package: `McpHttp.guarded(check!, { resource_metadata, scopes })`, a middleware
that reads the bearer token, calls the app's `check!`, hands on `{ ..context, token }`, and answers
`Bearer.challenge` / `Bearer.insufficient` (the pieces exist: `Bearer`). Then `packages/oauth` (b), its own
package and its own proposal, since every API an agent signs in to wants it, not only MCP. A host
primitive for RS256/ES256 verification only if an app needs (a) with JWTs.

```roc
guarded : (Str => Try({ subject : Str, scopes : List(Str) }, [Invalid])), { resource_metadata : Str, scopes : List(Str) } -> Middleware(c, { token : { subject : Str, scopes : List(Str) }, context : c })
```

**Depends on it.** Nothing in v1. With it, the README's middleware example becomes a line.

**Undo.** Each part is additive: drop `guarded`, or the oauth package.

## Open questions (for the user)

1. **Mounting.** Decided by D-103: a route file (`routes/mcp/+server.roc`), guarded by its
   directory's `+middleware.roc`; `McpHttp.middleware` is gone, and a tool sends `Api`'s endpoint
   in-process, through the endpoint's own middleware.
2. **Caching.** Current MCP asks every list how long a client may keep it. The package says 5
   minutes, `public` (a server's lists are fixed when it is built; who is asking doesn't change
   them), and 0, `private` for a resource read. Right defaults, or should a list be `private` when
   the route is behind a guard?
3. **Errors' statuses.** For an unknown tool, a bad cursor or no such resource, the spec (2026-07-28)
   names no HTTP status; the package answers the JSON-RPC error with 200, and 400/404 only where the
   spec says so. Keep 200, or 400 for every invalid-params error?
4. **Earlier MCP.** The current Inspector CLI (2.16.0) and SDK v1 still speak 2025-11-25 by
   default, so both eras are served. Drop the earlier one once clients default to 2026-07-28?
5. **Name.** `mcp` for the package, `McpHttp` for the HTTP side. Fine, or `Mcp.Http`-style names
   once server modules are part of the package (proposal 1)?
