import JsonValue

## Who may ask. MCP's authorization is OAuth 2.1: a client sends an access token with each request
## (`Authorization: Bearer …`), and a request without a good one is refused with 401 and where to
## learn how to get one (the server's protected resource metadata, RFC 9728). Which tokens are
## good is the app's middleware's to say, in front of its MCP route; these are the pieces it
## answers with. (An authorization server of the platform's own is a proposal: PROPOSALS.md.)
##
##     bearer = Middleware.make(|request, context, next!|
##         match Auth.bearer(request.headers) {
##             Ok(token) if Tokens.good!(token) => next!(request, context)
##             _ => McpHttp.response(Auth.challenge({ resource_metadata: "${origin}/.well-known/oauth-protected-resource", scope: "notes" }))
##         })
Auth := [].{

	## The token a request carries (`Authorization: Bearer …`), if it carries one.
	bearer : List({ name : Str, value : Str }) -> Try(Str, [NoToken])
	bearer = |headers|
		match headers.find_first(|each| each.name.with_ascii_lowercased() == "authorization") {
			Ok(found) => {
				value = found.value.trim()
				if value.with_ascii_lowercased().starts_with("bearer ") {
					token = Str.from_utf8_lossy(value.to_utf8().drop_first(7)).trim()
					if (token.is_empty()) Err(NoToken) else Ok(token)
				} else {
					Err(NoToken)
				}
			}
			Err(_) => Err(NoToken)
		}

	## The answer to a request with no token, or one that isn't good: 401, and the address of the
	## server's protected resource metadata (`resource_metadata`), and the scopes it takes (`""`
	## for none said), in `WWW-Authenticate`, where a client looks for them.
	challenge : { resource_metadata : Str, scope : Str } -> { status : U16, headers : List({ name : Str, value : Str }), body : Str }
	challenge = |asked| {
		scope = if (asked.scope.is_empty()) "" else ", scope=${quoted(asked.scope)}"
		{
			status: 401,
			headers: [{ name: "www-authenticate", value: "Bearer resource_metadata=${quoted(asked.resource_metadata)}${scope}" }, { name: "content-type", value: "text/plain; charset=utf-8" }],
			body: "Unauthorized: send an access token (Authorization: Bearer …)",
		}
	}

	## The answer to a request whose token is good, but not for this (403): the scopes it would
	## need.
	insufficient : { resource_metadata : Str, scope : Str } -> { status : U16, headers : List({ name : Str, value : Str }), body : Str }
	insufficient = |asked| {
		status: 403,
		headers: [{ name: "www-authenticate", value: "Bearer error=\"insufficient_scope\", scope=${quoted(asked.scope)}, resource_metadata=${quoted(asked.resource_metadata)}" }, { name: "content-type", value: "text/plain; charset=utf-8" }],
		body: "Forbidden: the access token doesn't have the scope ${asked.scope}",
	}

	## The server's protected resource metadata (RFC 9728), which it serves at
	## `/.well-known/oauth-protected-resource`: what it is (`resource`, its MCP endpoint's URL),
	## who issues its tokens, and the scopes it knows.
	metadata : { resource : Str, authorization_servers : List(Str), scopes : List(Str) } -> Str
	metadata = |about|
		JsonValue.to_str(
			JsonValue.object_of([
				("resource", Ok(String(about.resource))),
				("authorization_servers", Ok(Array(about.authorization_servers.map(|server| String(server))))),
				("scopes_supported", if (about.scopes.is_empty()) Err(Absent) else Ok(Array(about.scopes.map(|scope| String(scope))))),
				("bearer_methods_supported", Ok(Array([String("header")]))),
			]),
		)
}

## A value in a `WWW-Authenticate` parameter: in quotes, a `"` or `\` escaped.
quoted : Str -> Str
quoted = |text| "\"${text.replace_each("\\", "\\\\").replace_each("\"", "\\\"")}\""

expect Auth.bearer([{ name: "Authorization", value: "Bearer abc.def" }]) == Ok("abc.def")
expect Auth.bearer([{ name: "authorization", value: "bearer  abc " }]) == Ok("abc")
expect Auth.bearer([{ name: "authorization", value: "Basic YWxhZGRpbjpvcGVu" }]) == Err(NoToken)
expect Auth.bearer([{ name: "authorization", value: "Bearer " }]) == Err(NoToken)
expect Auth.bearer([]) == Err(NoToken)

## The spec's example challenge.
expect
	(Auth.challenge({ resource_metadata: "https://mcp.example.com/.well-known/oauth-protected-resource", scope: "files:read" })).headers.first()
		== Ok({ name: "www-authenticate", value: "Bearer resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\", scope=\"files:read\"" })
expect (Auth.challenge({ resource_metadata: "https://a.example/m", scope: "" })).headers.first() == Ok({ name: "www-authenticate", value: "Bearer resource_metadata=\"https://a.example/m\"" })
expect (Auth.insufficient({ resource_metadata: "https://a.example/m", scope: "notes:write" })).status == 403

expect
	Auth.metadata({ resource: "https://mcp.example.com/mcp", authorization_servers: ["https://auth.example.com"], scopes: ["notes"] })
		== "{\"resource\":\"https://mcp.example.com/mcp\",\"authorization_servers\":[\"https://auth.example.com\"],\"scopes_supported\":[\"notes\"],\"bearer_methods_supported\":[\"header\"]}"
