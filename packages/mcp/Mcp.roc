import crypto.Base64
import tools.JsonValue
import Prompt
import Resource
import Rpc
import Template
import tools.Tool

## An app's MCP server: what it offers AI agents (tools, resources, prompts), and the protocol they
## ask for them with, over HTTP (Streamable HTTP: one endpoint, a JSON-RPC message a POST).
##
##     server : Mcp.Server(McpHttp.Caller(Context))
##     server = {
##         name: "notes",
##         version: "1.0.0",
##         instructions: "Notes, by id. List them first.",
##         tools: [McpHttp.endpoint(Handlers.post_api_notes, { name: "add_note", description: "Adds a note" }, McpHttp.openapi({}))],
##     }
##
## It speaks both eras of MCP. The current one (2026-07-28) has no handshake: each request says its
## version and the client's capabilities in its `_meta`, and its headers repeat its method and
## what it names (`Mcp-Method`, `Mcp-Name`). The earlier ones (2025-11-25, 2025-06-18, 2025-03-26)
## start with `initialize`; the server keeps no session (no `Mcp-Session-Id`), which they allow, so
## every request stands alone in both. Nothing is pushed: `GET` and `DELETE` are 405.
##
## `receive` is the protocol, pure: it reads a request and either answers it (`Reply`) or says
## what to run (`Run`: a tool, reading a resource, a prompt), which `handle!` does. Who may ask is
## the app's middleware's to decide, in front of the route that serves it (`McpHttp.respond!`).
Mcp := [].{

	## What the server says about itself (`name`, `version`, `title`, and `instructions` for the
	## model: how its tools go together), and what it offers. A list is sent `page_size` at a
	## time; a client may keep it `ttl_ms` (current MCP). A request from a browser page is answered
	## only if the page is this server's (its `Origin` is the `Host` it asked) or one of `origins`
	## (`"https://app.example.com"`).
	Server(ctx) := {
		name : Str,
		version : Str,
		title : Str ?? "",
		instructions : Str ?? "",
		tools : List(Tool(ctx)) ?? [],
		resources : List(Resource(ctx)) ?? [],
		templates : List(Template(ctx)) ?? [],
		prompts : List(Prompt(ctx)) ?? [],
		page_size : U64 ?? 100,
		ttl_ms : U64 ?? 300000,
		origins : List(Str) ?? [],
	}

	## A request, as far as MCP reads it: its method, its headers, its body.
	Incoming : { method : Str, headers : List({ name : Str, value : Str }), body : Str }

	## An answer: its status, its headers, its body (JSON, or nothing).
	Answer : { status : U16, headers : List({ name : Str, value : Str }), body : Str }

	## Which MCP a request speaks, and its version.
	Era : [Current(Str), Earlier(Str)]

	## What a request comes to: an answer, or something to run first.
	Step(ctx) : [Reply(Answer), Run(Running(ctx))]

	## A tool to call, a resource to read or a prompt to get, for the request `id`: `run!` does it,
	## given what the app hands its tools (`ctx`), and makes the answer. `stream` is whether to send
	## the answer as events, so the tool's progress goes first (`progress`): a tool that reports it,
	## for a client that sent a `progressToken` and takes `text/event-stream`.
	Running(ctx) : {
		id : JsonValue,
		era : Era,
		method : Str,
		name : Str,
		stream : Bool,
		progress : Try(JsonValue, [NoToken]),
		run : ctx => Ran,
	}

	## The answer `run!` made, and what failed inside, if anything (for the server's log: the
	## answer only says that it failed).
	Ran : { answer : Answer, failure : Try(Str, [NoFailure]) }

	## The protocol versions the server speaks, the current first.
	versions : List(Str)
	versions = current.concat(earlier)

	## The answer to a request, given what the app hands its tools: `receive`, then `run!` if there
	## is something to run.
	handle! : Server(ctx), Incoming, ctx => Answer
	handle! = |server, incoming, ctx|
		match Mcp.receive(server, incoming) {
			Reply(answer) => answer
			Run(running) => {
				run! = running.run
				run!(ctx).answer
			}
		}

	## What a request comes to. In turn: only a POST (405); from a page of this site, if from a page
	## (403); JSON (415); one JSON-RPC message (400). A notification or a response is accepted
	## (202), with nothing to say. A request's era and version are checked (400), and its method
	## answered: one there is no such method for is 404 in current MCP, and an error in earlier MCP.
	receive : Server(ctx), Incoming -> Step(ctx)
	receive = |server, incoming| {
		if incoming.method != "POST" {
			return Reply({ status: 405, headers: [{ name: "allow", value: "POST" }, plain_text], body: "MCP is asked by POST here, not ${incoming.method}" })
		}
		if !origin_allowed(server, incoming) {
			return Reply(json_answer(403, Rpc.error(Err(NoId), Rpc.fail(Rpc.invalid_request, "Requests from pages of another site aren't answered"))))
		}
		type = media_type(header(incoming, "content-type") ?? "application/json")
		if type != "application/json" and !type.ends_with("+json") {
			return Reply({ status: 415, headers: [plain_text], body: "MCP is sent as JSON (application/json), not ${type}" })
		}
		match Rpc.read(incoming.body) {
			Err(unread) => Reply(json_answer(400, Rpc.error(unread.id, unread.error)))
			Ok(Response) => Reply(accepted)
			Ok(Notification(_)) => Reply(accepted)
			Ok(Request(request)) =>
				match era_of(incoming, request) {
					Err(refused) => Reply(refused)
					Ok(era) => answer(server, incoming, era, request)
				}
		}
	}

	## A tool's progress, as the notification the stream sends: how far it has got (`done`), of how
	## much (`total`, 0 for unknown), and a message (`""` for none).
	progress : Running(ctx), U64, U64, Str -> Str
	progress = |running, done, total, message|
		Rpc.notification(
			"notifications/progress",
			JsonValue.object_of([
				("progressToken", Ok(running.progress ?? Null)),
				("progress", Ok(JsonValue.uint(done))),
				("total", if (total == 0) Err(Absent) else Ok(JsonValue.uint(total))),
				("message", JsonValue.text_unless_empty(message)),
			]),
		)

	## What is wrong with a server's tools, resources and prompts, for a test of the app's
	## (`expect Mcp.problems(server) == []`): a name MCP doesn't take (a tool's is 1 to 128 letters,
	## digits, `_`, `-` and `.`), one given twice, a schema that isn't JSON, an endpoint's tool whose
	## path params and body name one field.
	problems : Server(ctx) -> List(Str)
	problems = |server| {
		tools = server.tools.map(|tool| tool.name)
		named = tools.keep_if(|name| !is_tool_name(name)).map(|name| "The tool name \"${name}\" isn't 1 to 128 of A-Z, a-z, 0-9, _, - and .")
		schemas = server.tools.keep_oks(
			|tool|
				match (tool.input, tool.output) {
					(Err(InvalidJson(why)), _) => Ok("The tool ${tool.name}'s input schema isn't JSON: ${why}")
					(Err(Clash(names)), _) => Ok("The tool ${tool.name}'s arguments name ${Str.join_with(names, ", ")} both as its endpoint's path params and in its body: one object can't fill both (rename the body's field)")
					(_, Err(InvalidJson(why))) => Ok("The tool ${tool.name}'s output schema isn't JSON: ${why}")
					_ => Err(Fine)
				},
		)
		named
			.concat(schemas)
			.concat(twice("tool", tools))
			.concat(twice("resource", server.resources.map(|resource| resource.uri)))
			.concat(twice("resource template", server.templates.map(|family| family.pattern)))
			.concat(twice("prompt", server.prompts.map(|prompt| prompt.name)))
	}
}

current : List(Str)
current = ["2026-07-28"]

earlier : List(Str)
earlier = ["2025-11-25", "2025-06-18", "2025-03-26"]

## The version a request is taken to speak when nothing says (as Streamable HTTP's first one has it).
assumed : Str
assumed = "2025-03-26"

version_key : Str
version_key = "io.modelcontextprotocol/protocolVersion"

capabilities_key : Str
capabilities_key = "io.modelcontextprotocol/clientCapabilities"

server_info_key : Str
server_info_key = "io.modelcontextprotocol/serverInfo"

plain_text : { name : Str, value : Str }
plain_text = { name: "content-type", value: "text/plain; charset=utf-8" }

accepted : Mcp.Answer
accepted = { status: 202, headers: [], body: "" }

json_answer : U16, Str -> Mcp.Answer
json_answer = |status, body| { status: status, headers: [{ name: "content-type", value: "application/json" }], body: body }

## A header's value, by its name in any case.
header : Mcp.Incoming, Str -> Try(Str, [Missing])
header = |incoming, name|
	match incoming.headers.find_first(|each| each.name.with_ascii_lowercased() == name) {
		Ok(found) => Ok(found.value)
		Err(_) => Err(Missing)
	}

## A header's value as MCP writes one that isn't plain ASCII: `=?base64?…?=`, the UTF-8 in Base64.
header_text : Str -> Str
header_text = |value|
	if value.starts_with("=?base64?") and value.ends_with("?=") {
		match Base64.decode(value.drop_prefix("=?base64?").drop_suffix("?=")) {
			Ok(bytes) => Str.from_utf8(bytes) ?? value
			Err(_) => value
		}
	} else {
		value
	}

## A `content-type`'s type, without its parameters, in lower case.
media_type : Str -> Str
media_type = |given| {
	bare =
		match given.split_first(";") {
			Ok({ before, .. }) => before
			Err(_) => given
		}
	bare.trim().with_ascii_lowercased()
}

## Whether a request from a page may be answered: one that says no page sent it (no `Origin`), one
## from this server's own pages (`Origin`'s host is the `Host` asked), or one from `origins`. A
## page of another site can make a browser send a request to a server on the reader's own computer
## (DNS rebinding); this is what stops it.
origin_allowed : Mcp.Server(ctx), Mcp.Incoming -> Bool
origin_allowed = |server, incoming|
	match header(incoming, "origin") {
		Err(Missing) => Bool.True
		Ok(origin) => {
			host =
				match origin.split_first("://") {
					Ok({ after, .. }) => after
					Err(_) => ""
				}
			server.origins.contains(origin) or (!host.is_empty() and Ok(host) == header(incoming, "host"))
		}
	}

## Which MCP a request speaks. Current MCP's say so in their `_meta` (its version, and the
## client's capabilities), and their headers repeat it, the method, and the name of what
## `tools/call`, `resources/read` and `prompts/get` ask for; any that doesn't match is refused
## (400). Earlier MCP's start with `initialize`, answered with the version it asks for if the server
## speaks it, else the latest earlier one; their requests after it say their version in the
## `MCP-Protocol-Version` header.
era_of : Mcp.Incoming, { id : JsonValue, method : Str, params : JsonValue } -> Try(Mcp.Era, Mcp.Answer)
era_of = |incoming, request| {
	refused = |code, message, data| Err(json_answer(400, Rpc.error(Ok(request.id), { code: code, message: message, data: data })))
	unsupported = |version| refused(Rpc.unsupported_version, "Unsupported protocol version", Ok(Object([("supported", Array(Mcp.versions.map(|known| String(known)))), ("requested", String(version))])))
	mismatch = |name, sent, body| refused(Rpc.header_mismatch, "Header mismatch: ${name} header value '${sent}' does not match body value '${body}'", Err(NoData))
	meta = request.params.get("_meta") ?? Null
	asked = header(incoming, "mcp-protocol-version")
	match meta.get(version_key) {
		Ok(String(version)) => {
			if !current.contains(version) {
				return unsupported(version)
			}
			if !(meta.get(capabilities_key) ?? Null).is_object() {
				return refused(Rpc.invalid_params, "A request's _meta has \"${capabilities_key}\", an object", Err(NoData))
			}
			if asked != Ok(version) {
				return mismatch("MCP-Protocol-Version", asked ?? "", version)
			}
			if header(incoming, "mcp-method") != Ok(request.method) {
				return mismatch("Mcp-Method", header(incoming, "mcp-method") ?? "", request.method)
			}
			match named(request) {
				Ok(name) => {
					sent = header_text(header(incoming, "mcp-name") ?? "")
					if (sent != name) mismatch("Mcp-Name", sent, name) else Ok(Current(version))
				}
				Err(Unnamed) => Ok(Current(version))
			}
		}
		Ok(_) => refused(Rpc.invalid_params, "\"${version_key}\" is a string", Err(NoData))
		Err(Missing) =>
			if request.method == "initialize" {
				wanted = (request.params.get("protocolVersion") ?? Null).to_text() ?? ""
				Ok(Earlier(if (earlier.contains(wanted)) wanted else earlier.first() ?? assumed))
			} else {
				match asked {
					Ok(version) if earlier.contains(version) => Ok(Earlier(version))
					Ok(version) if current.contains(version) => refused(Rpc.invalid_params, "A request in MCP ${version} carries _meta with \"${version_key}\" and \"${capabilities_key}\"", Err(NoData))
					Ok(version) => unsupported(version)
					Err(Missing) => Ok(Earlier(assumed))
				}
			}
	}
}

## What a request names, which `Mcp-Name` repeats: a tool's, a prompt's name, a resource's URI.
named : { id : JsonValue, method : Str, params : JsonValue } -> Try(Str, [Unnamed])
named = |request| {
	key =
		match request.method {
			"tools/call" => "name"
			"prompts/get" => "name"
			"resources/read" => "uri"
			_ => return Err(Unnamed)
		}
	match request.params.get(key) {
		Ok(String(name)) => Ok(name)
		_ => Err(Unnamed)
	}
}

## The answer to a request of a known era.
answer : Mcp.Server(ctx), Mcp.Incoming, Mcp.Era, { id : JsonValue, method : Str, params : JsonValue } -> Mcp.Step(ctx)
answer = |server, incoming, era, request| {
	id = request.id
	params = request.params
	answered = |fields| Reply(json_answer(200, Rpc.result(id, Object(complete(era, fields)))))
	failed = |code, message| Reply(json_answer(status_of(era, code), Rpc.error(Ok(id), Rpc.fail(code, message))))
	listed = |items, key|
		match page(items, params.get("cursor"), server.page_size) {
			Ok(shown) => {
				next =
					match shown.next {
						Ok(cursor) => [("nextCursor", String(cursor))]
						Err(End) => []
					}
				answered([(key, Array(shown.items))].concat(next).concat(cached(era, server.ttl_ms, "public")))
			}
			Err(BadCursor) => failed(Rpc.invalid_params, "Invalid cursor")
		}
	given = |key, what|
		match params.get(key) {
			Ok(String(name)) => Ok(name)
			_ => Err(failed(Rpc.invalid_params, "${request.method} names its ${what}: params.${key}"))
		}
	running = |name, stream, token, run!| Run({ id: id, era: era, method: request.method, name: name, stream: stream, progress: token, run: run! })
	match (era, request.method) {
		(Current(_), "server/discover") =>
			answered(
				[("supportedVersions", Array(Mcp.versions.map(|known| String(known)))), ("capabilities", capabilities(server))]
					.concat(instructions(server))
					.concat(cached(era, server.ttl_ms, "public"))
					.append(("_meta", Object([(server_info_key, server_info(server))]))),
			)
		(Earlier(version), "initialize") =>
			answered([("protocolVersion", String(version)), ("capabilities", capabilities(server)), ("serverInfo", server_info(server))].concat(instructions(server)))
		(Earlier(_), "ping") => answered([])
		(_, "tools/list") => listed(server.tools.map(Tool.to_json), "tools")
		(_, "resources/list") => listed(server.resources.map(Resource.to_json), "resources")
		(_, "resources/templates/list") => listed(server.templates.map(Template.to_json), "resourceTemplates")
		(_, "prompts/list") => listed(server.prompts.map(Prompt.to_json), "prompts")
		(_, "tools/call") => {
			name =
				match given("name", "tool") {
					Ok(found) => found
					Err(refusal) => return refusal
				}
			tool =
				match server.tools.find_first(|each| each.name == name) {
					Ok(found) => found
					Err(_) => return failed(Rpc.invalid_params, "Unknown tool: ${name}")
				}
			arguments : JsonValue
			arguments =
				match params.get("arguments") {
					Err(Missing) => Object([])
					Ok(Null) => Object([])
					Ok(Object(fields)) => Object(fields)
					Ok(_) => return failed(Rpc.invalid_params, "A tool's arguments are an object")
				}
			prepare = tool.prepare
			match prepare(arguments) {
				Err(why) => answered(Tool.outcome_json(Refused(why)) ?? [])
				Ok(call!) => {
					token = progress_token(params)
					stream = tool.reports and token.is_ok() and (header(incoming, "accept") ?? "").contains("text/event-stream")
					running(name, stream, token, |ctx| tool_ran(era, id, name, call!(ctx)))
				}
			}
		}
		(_, "resources/read") => {
			uri =
				match given("uri", "resource") {
					Ok(found) => found
					Err(refusal) => return refusal
				}
			match server.resources.find_first(|each| each.uri == uri) {
				Ok(resource) => {
					read! = resource.read
					running(uri, Bool.False, Err(NoToken), |ctx| read_ran(era, id, uri, read!(ctx).map_err(|why| Failed(why))))
				}
				Err(_) =>
					match matching_template(server.templates, uri) {
						Ok((family, values)) => {
							read! = family.read
							running(uri, Bool.False, Err(NoToken), |ctx| read_ran(era, id, uri, read!(values, uri, ctx)))
						}
						Err(NoMatch) => Reply(not_found(era, id, uri))
					}
			}
		}
		(_, "prompts/get") => {
			name =
				match given("name", "prompt") {
					Ok(found) => found
					Err(refusal) => return refusal
				}
			prompt =
				match server.prompts.find_first(|each| each.name == name) {
					Ok(found) => found
					Err(_) => return failed(Rpc.invalid_params, "Unknown prompt: ${name}")
				}
			match Prompt.arguments_of(prompt, params.get("arguments") ?? Null) {
				Err(why) => failed(Rpc.invalid_params, why)
				Ok(taken) => {
					get! = prompt.get
					running(name, Bool.False, Err(NoToken), |ctx| prompt_ran(era, id, get!(taken, ctx)))
				}
			}
		}
		_ => failed(Rpc.method_not_found, "Method not found: ${request.method}")
	}
}

## A result as the era writes it: current MCP's says it is complete (`resultType`).
complete : Mcp.Era, List((Str, JsonValue)) -> List((Str, JsonValue))
complete = |era, fields|
	match era {
		Current(_) => [("resultType", String("complete"))].concat(fields)
		Earlier(_) => fields
	}

## How long a client may keep a result, and whether one client's may be another's (current MCP).
cached : Mcp.Era, U64, Str -> List((Str, JsonValue))
cached = |era, ttl_ms, scope|
	match era {
		Current(_) => [("ttlMs", JsonValue.uint(ttl_ms)), ("cacheScope", String(scope))]
		Earlier(_) => []
	}

## An error's status: 404 for no such method, in current MCP; any other error of a method's is 200,
## a JSON-RPC error in a JSON-RPC answer.
status_of : Mcp.Era, I64 -> U16
status_of = |era, code|
	match era {
		Current(_) if code == Rpc.method_not_found => 404
		_ => 200
	}

capabilities : Mcp.Server(ctx) -> JsonValue
capabilities = |server| {
	offered = |yes| if (yes) Ok(Object([])) else Err(Absent)
	JsonValue.object_of([
		("tools", offered(!server.tools.is_empty())),
		("resources", offered(!server.resources.is_empty() or !server.templates.is_empty())),
		("prompts", offered(!server.prompts.is_empty())),
	])
}

server_info : Mcp.Server(ctx) -> JsonValue
server_info = |server| JsonValue.object_of([("name", Ok(String(server.name))), ("title", JsonValue.text_unless_empty(server.title)), ("version", Ok(String(server.version)))])

instructions : Mcp.Server(ctx) -> List((Str, JsonValue))
instructions = |server| if (server.instructions.is_empty()) [] else [("instructions", String(server.instructions))]

## The page a cursor starts (none: the first), `size` long (0: all), and the cursor of the next, if
## there is one. A cursor is where its page starts; any other is refused.
page : List(a), Try(JsonValue, [Missing]), U64 -> Try({ items : List(a), next : Try(Str, [End]) }, [BadCursor])
page = |all, cursor, size| {
	start =
		match cursor {
			Err(Missing) => 0
			Ok(Null) => 0
			Ok(String(text)) =>
				match U64.from_str(text) {
					Ok(at) if at <= all.len() => at
					_ => return Err(BadCursor)
				}
			Ok(_) => return Err(BadCursor)
		}
	if size == 0 {
		Ok({ items: all.drop_first(start), next: Err(End) })
	} else {
		end = start + size
		Ok({ items: all.sublist({ start: start, len: size }), next: if (end < all.len()) Ok(end.to_str()) else Err(End) })
	}
}

## The `progressToken` a request's `_meta` gives, a string or a number.
progress_token : JsonValue -> Try(JsonValue, [NoToken])
progress_token = |params|
	match (params.get("_meta") ?? Null).get("progressToken") {
		Ok(String(token)) => Ok(String(token))
		Ok(Number(token)) => Ok(Number(token))
		_ => Err(NoToken)
	}

## The first template a URI matches, and the values its names took.
matching_template : List(Template(ctx)), Str -> Try((Template(ctx), Dict(Str, Str)), [NoMatch])
matching_template = |families, uri| {
	for family in families {
		match Template.matching(family.pattern, uri) {
			Ok(values) => return Ok((family, values))
			Err(NoMatch) => {}
		}
	}
	Err(NoMatch)
}

## The answer to a `tools/call`, from what running the tool came to.
tool_ran : Mcp.Era, JsonValue, Str, Tool.Outcome -> Mcp.Ran
tool_ran = |era, id, name, outcome|
	match Tool.outcome_json(outcome) {
		Ok(fields) => { answer: json_answer(200, Rpc.result(id, Object(complete(era, fields)))), failure: Err(NoFailure) }
		Err(Failed(why)) => { answer: json_answer(200, Rpc.error(Ok(id), Rpc.fail(Rpc.internal_error, "The tool ${name} failed"))), failure: Ok("The tool ${name} failed: ${why}") }
	}

## The answer to a `resources/read`: its contents, which a client keeps for no time, as its own.
read_ran : Mcp.Era, JsonValue, Str, Try(List(Resource.Contents), [NotFound, Failed(Str)]) -> Mcp.Ran
read_ran = |era, id, uri, read|
	match read {
		Ok(contents) => { answer: json_answer(200, Rpc.result(id, Object(complete(era, [("contents", Array(contents.map(Resource.contents_json)))].concat(cached(era, 0, "private")))))), failure: Err(NoFailure) }
		Err(NotFound) => { answer: not_found(era, id, uri), failure: Err(NoFailure) }
		Err(Failed(why)) => { answer: json_answer(200, Rpc.error(Ok(id), Rpc.fail(Rpc.internal_error, "Reading ${uri} failed"))), failure: Ok("Reading ${uri} failed: ${why}") }
	}

## No resource at a URI: invalid params in current MCP, -32002 in earlier MCP, with the URI.
not_found : Mcp.Era, JsonValue, Str -> Mcp.Answer
not_found = |era, id, uri| {
	code =
		match era {
			Current(_) => Rpc.invalid_params
			Earlier(_) => -32002
		}
	json_answer(200, Rpc.error(Ok(id), { code: code, message: "Resource not found", data: Ok(Object([("uri", String(uri))])) }))
}

## The answer to a `prompts/get`: its messages, or why it can't make them (an argument it can't use).
prompt_ran : Mcp.Era, JsonValue, Try(Prompt.Got, Str) -> Mcp.Ran
prompt_ran = |era, id, got|
	match got {
		Ok(made) => { answer: json_answer(200, Rpc.result(id, Object(complete(era, Prompt.got_json(made))))), failure: Err(NoFailure) }
		Err(why) => { answer: json_answer(200, Rpc.error(Ok(id), Rpc.fail(Rpc.invalid_params, why))), failure: Err(NoFailure) }
	}

## A tool's name as MCP takes it: 1 to 128 letters, digits, `_`, `-` and `.`.
is_tool_name : Str -> Bool
is_tool_name = |name| {
	bytes = name.to_utf8()
	!bytes.is_empty() and bytes.len() <= 128 and bytes.all(|byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '_' or byte == '-' or byte == '.')
}

## Each name given more than once.
twice : Str, List(Str) -> List(Str)
twice = |what, names| {
	var $seen = []
	var $said = []
	for name in names {
		if $seen.contains(name) and !$said.contains(name) {
			$said = $said.append(name)
		}
		$seen = $seen.append(name)
	}
	$said.map(|name| "Two of the ${what}s are ${name}")
}

# ── Tests: the spec's example messages, through `receive` ──────────────────────────────────────────

Notes : { owner : Str }

note_text : Dict(Str, Str), Str, Notes => Try(List(Resource.Contents), [NotFound, Failed(Str)])
note_text = |values, uri, _|
	match values.get("id") {
		Ok("1") => Ok([Resource.contents(uri, "text/plain", Text("Buy milk"))])
		_ => Err(NotFound)
	}

index_text : Notes => Try(Str, Str)
index_text = |notes| Ok("Notes of ${notes.owner}")

adding : { a : I64, b : I64 }, Notes => Try({ sum : I64 }, Str)
adding = |args, _| Ok({ sum: args.a + args.b })

shouting : Str, Notes => Try(Str, Str)
shouting = |said, _| Ok(said.with_ascii_uppercased())

asking : Dict(Str, Str), Notes => Try(Prompt.Got, Str)
asking = |args, _| Ok({ description: "", messages: [Prompt.user("Summarize note ${args.get("id") ?? ""}")] })

example : Mcp.Server(Notes)
example = {
	name: "notes",
	version: "1.0.0",
	title: "Notes",
	instructions: "Notes, by id.",
	tools: [
		Tool.typed("add", "Adds two numbers", "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"integer\"},\"b\":{\"type\":\"integer\"}},\"required\":[\"a\",\"b\"]}", adding).read_only(),
		Tool.typed("shout", "Shouts", "{\"type\":\"string\"}", shouting).reporting(),
	],
	resources: [Resource.text("notes://index", "index", "text/plain", index_text)],
	templates: [Template.new("notes://note/{id}", "note", note_text)],
	prompts: [Prompt.new("summarize", "Summarizes a note", [Prompt.argument("id", "The note's id")], asking)],
	page_size: 1,
}

## A request of current MCP: its method, the name `Mcp-Name` repeats (`""` for none), its params
## (an object's fields, `_meta` added), and headers changed (`""` drops one).
current_request : Str, Str, List((Str, JsonValue)), List((Str, Str)) -> Mcp.Incoming
current_request = |method, name, params, changed| {
	meta = Object([(version_key, String("2026-07-28")), ("io.modelcontextprotocol/clientInfo", Object([("name", String("ExampleClient")), ("version", String("1.0.0"))])), (capabilities_key, Object([]))])
	body = JsonValue.to_str(Object([("jsonrpc", String("2.0")), ("id", Number("1")), ("method", String(method)), ("params", Object(params.append(("_meta", meta))))]))
	usual = [("content-type", "application/json"), ("accept", "application/json, text/event-stream"), ("mcp-protocol-version", "2026-07-28"), ("mcp-method", method)].concat(if (name.is_empty()) [] else [("mcp-name", name)])
	headers = usual.keep_if(|(key, _)| !changed.any(|(other, _)| other == key)).concat(changed.keep_if(|(_, value)| !value.is_empty()))
	{ method: "POST", headers: headers.map(|(key, value)| { name: key, value: value }), body: body }
}

## A request of earlier MCP: its body, and its `MCP-Protocol-Version` (`""` for none).
earlier_request : Str, Str -> Mcp.Incoming
earlier_request = |body, version| {
	headers = [{ name: "content-type", value: "application/json" }, { name: "accept", value: "application/json, text/event-stream" }]
	{ method: "POST", headers: if (version.is_empty()) headers else headers.append({ name: "mcp-protocol-version", value: version }), body: body }
}

## What a request comes to: an answer's status and body, or what is to run.
replied : Mcp.Incoming -> [Replied(U16, Str), Runs(Str, Str, Bool)]
replied = |incoming|
	match Mcp.receive(example, incoming) {
		Reply(answered) => Replied(answered.status, answered.body)
		Run(running) => Runs(running.method, running.name, running.stream)
	}

## The result (or error) of an answer, as JSON.
result_of : Mcp.Incoming -> JsonValue
result_of = |incoming|
	match replied(incoming) {
		Replied(_, body) => {
			read = JsonValue.parse(body) ?? Null
			match read.get("result") {
				Ok(found) => found
				Err(_) => read.get("error") ?? Null
			}
		}
		Runs(_, _, _) => Null
	}

## `server/discover`, as the spec's example sends it.
expect {
	discovered = replied({ method: "POST", headers: [{ name: "Content-Type", value: "application/json" }, { name: "MCP-Protocol-Version", value: "2026-07-28" }, { name: "Mcp-Method", value: "server/discover" }], body: "{\"jsonrpc\":\"2.0\",\"id\":\"discover-1\",\"method\":\"server/discover\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientInfo\":{\"name\":\"ExampleClient\",\"version\":\"1.0.0\"},\"io.modelcontextprotocol/clientCapabilities\":{}}}}" })
	discovered
		== Replied(200, "{\"jsonrpc\":\"2.0\",\"id\":\"discover-1\",\"result\":{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\",\"2025-11-25\",\"2025-06-18\",\"2025-03-26\"],\"capabilities\":{\"tools\":{},\"resources\":{},\"prompts\":{}},\"instructions\":\"Notes, by id.\",\"ttlMs\":300000,\"cacheScope\":\"public\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"notes\",\"title\":\"Notes\",\"version\":\"1.0.0\"}}}}")
}

## Versions: one the server doesn't speak (the spec's example), and `_meta` without capabilities.
expect replied(current_request("tools/list", "", [], [("mcp-protocol-version", "1900-01-01")])) == Replied(400, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32020,\"message\":\"Header mismatch: MCP-Protocol-Version header value '1900-01-01' does not match body value '2026-07-28'\"}}")
expect {
	body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"1900-01-01\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}"
	replied({ method: "POST", headers: [{ name: "mcp-protocol-version", value: "1900-01-01" }, { name: "mcp-method", value: "tools/list" }], body: body })
		== Replied(400, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"supported\":[\"2026-07-28\",\"2025-11-25\",\"2025-06-18\",\"2025-03-26\"],\"requested\":\"1900-01-01\"}}}")
}
expect {
	body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}"
	(result_of({ method: "POST", headers: [{ name: "mcp-protocol-version", value: "2026-07-28" }, { name: "mcp-method", value: "tools/list" }], body: body })).get("code") == Ok(Number("-32602"))
}

## A current request with no `_meta`: refused, not taken for an earlier one.
expect (result_of(earlier_request("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}", "2026-07-28"))).get("code") == Ok(Number("-32602"))

## Headers that don't repeat the body: the method, the tool's name (sent in Base64 when it isn't
## plain ASCII, as `Mcp-Name: =?base64?…?=`).
expect (result_of(current_request("tools/list", "", [], [("mcp-method", "prompts/list")]))).get("code") == Ok(Number("-32020"))
expect (result_of(current_request("tools/list", "", [], [("mcp-method", "")]))).get("code") == Ok(Number("-32020"))
expect (result_of(current_request("tools/call", "shout", [("name", String("add")), ("arguments", Object([]))], []))).get("message") == Ok(String("Header mismatch: Mcp-Name header value 'shout' does not match body value 'add'"))
expect replied(current_request("tools/call", "=?base64?YWRk?=", [("name", String("add")), ("arguments", Object([("a", Number("1")), ("b", Number("2"))]))], [])) == Runs("tools/call", "add", Bool.False)

## Lists, a page at a time (`page_size: 1`): the cursor of the next page, then none.
expect {
	listed = result_of(current_request("tools/list", "", [], []))
	JsonValue.to_str(listed)
		== "{\"resultType\":\"complete\",\"tools\":[{\"name\":\"add\",\"description\":\"Adds two numbers\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"integer\"},\"b\":{\"type\":\"integer\"}},\"required\":[\"a\",\"b\"]},\"annotations\":{\"readOnlyHint\":true}}],\"nextCursor\":\"1\",\"ttlMs\":300000,\"cacheScope\":\"public\"}"
}
expect {
	listed = result_of(current_request("tools/list", "", [("cursor", String("1"))], []))
	(listed.get("tools") ?? Null).to_str().starts_with("[{\"name\":\"shout\"") and listed.get("nextCursor") == Err(Missing)
}
expect (result_of(current_request("tools/list", "", [("cursor", String("nine"))], []))).get("message") == Ok(String("Invalid cursor"))
expect JsonValue.to_str(result_of(current_request("resources/templates/list", "", [], []))) == "{\"resultType\":\"complete\",\"resourceTemplates\":[{\"uriTemplate\":\"notes://note/{id}\",\"name\":\"note\"}],\"ttlMs\":300000,\"cacheScope\":\"public\"}"
expect (result_of(current_request("prompts/list", "", [], []))).get("prompts").map_ok(|found| found.to_str().contains("\"required\":true")) == Ok(Bool.True)

## `tools/call`: an unknown tool and arguments that aren't an object are JSON-RPC errors; arguments
## that don't fit go back to the model, as a tool error; ones that fit, to run. A tool that reports
## progress streams, for a client that asks (a `progressToken`).
expect (result_of(current_request("tools/call", "nope", [("name", String("nope"))], []))).get("message") == Ok(String("Unknown tool: nope"))
expect (result_of(current_request("tools/call", "add", [("name", String("add")), ("arguments", Array([]))], []))).get("code") == Ok(Number("-32602"))
expect {
	refused = result_of(current_request("tools/call", "add", [("name", String("add")), ("arguments", Object([("a", String("one"))]))], []))
	refused.get("isError") == Ok(Boolean(Bool.True)) and refused.get("resultType") == Ok(String("complete"))
}
expect replied(current_request("tools/call", "shout", [("name", String("shout")), ("arguments", Object([("input", String("hi"))]))], [])) == Runs("tools/call", "shout", Bool.False)
expect {
	asked = current_request("tools/call", "shout", [("name", String("shout")), ("arguments", Object([("input", String("hi"))]))], [])
	with_token = { ..asked, body: asked.body.replace_first("\"_meta\":{", "\"_meta\":{\"progressToken\":\"p1\",") }
	replied(with_token) == Runs("tools/call", "shout", Bool.True)
}

## What running a tool comes to, as its answer: its result; its failure, kept out of the answer.
expect {
	ran = tool_ran(Current("2026-07-28"), Number("4"), "add", Tool.structured(Object([("sum", Number("3"))])))
	ran.answer.body == "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"{\\\"sum\\\":3}\"}],\"structuredContent\":{\"sum\":3}}}" and ran.failure == Err(NoFailure)
}
expect {
	ran = tool_ran(Earlier("2025-11-25"), String("x"), "add", Failed("the disk is full"))
	ran.answer.body == "{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"error\":{\"code\":-32603,\"message\":\"The tool add failed\"}}" and ran.failure == Ok("The tool add failed: the disk is full")
}

## `resources/read`: a resource of its own URI, one a template matches, and none (the spec's
## example error, with the URI).
expect replied(current_request("resources/read", "notes://index", [("uri", String("notes://index"))], [])) == Runs("resources/read", "notes://index", Bool.False)
expect replied(current_request("resources/read", "notes://note/1", [("uri", String("notes://note/1"))], [])) == Runs("resources/read", "notes://note/1", Bool.False)
expect replied(current_request("resources/read", "file:///nonexistent.txt", [("uri", String("file:///nonexistent.txt"))], [])) == Replied(200, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"Resource not found\",\"data\":{\"uri\":\"file:///nonexistent.txt\"}}}")
expect (read_ran(Current("2026-07-28"), Number("5"), "notes://note/2", Err(NotFound))).answer.body.contains("\"code\":-32602,\"message\":\"Resource not found\"")
expect
	(read_ran(Earlier("2025-06-18"), Number("5"), "notes://note/1", Ok([Resource.contents("notes://note/1", "text/plain", Text("Buy milk"))]))).answer.body
		== "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"contents\":[{\"uri\":\"notes://note/1\",\"mimeType\":\"text/plain\",\"text\":\"Buy milk\"}]}}"
expect (read_ran(Earlier("2025-11-25"), Number("5"), "notes://note/2", Err(NotFound))).answer.body.contains("\"code\":-32002")

## `prompts/get`: an unknown prompt, a missing argument, and one to get.
expect (result_of(current_request("prompts/get", "nope", [("name", String("nope"))], []))).get("message") == Ok(String("Unknown prompt: nope"))
expect (result_of(current_request("prompts/get", "summarize", [("name", String("summarize"))], []))).get("message") == Ok(String("Missing required argument: id"))
expect replied(current_request("prompts/get", "summarize", [("name", String("summarize")), ("arguments", Object([("id", String("1"))]))], [])) == Runs("prompts/get", "summarize", Bool.False)
expect (prompt_ran(Current("2026-07-28"), Number("2"), Ok({ description: "Code review prompt", messages: [Prompt.user("Please review this Python code")] }))).answer.body == "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":\"complete\",\"description\":\"Code review prompt\",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"Please review this Python code\"}}]}}"

## No such method: 404 in current MCP; a JSON-RPC error (200) in earlier MCP, where `ping` is.
expect replied(current_request("ping", "", [], [])) == Replied(404, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"Method not found: ping\"}}")
expect replied(earlier_request("{\"jsonrpc\":\"2.0\",\"id\":\"123\",\"method\":\"ping\"}", "2025-11-25")) == Replied(200, "{\"jsonrpc\":\"2.0\",\"id\":\"123\",\"result\":{}}")
expect replied(earlier_request("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"logging/setLevel\",\"params\":{\"level\":\"info\"}}", "2025-11-25")) == Replied(200, "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32601,\"message\":\"Method not found: logging/setLevel\"}}")

## Earlier MCP: `initialize`, answered with the version asked for if the server speaks it, else
## its latest earlier one; then `notifications/initialized`; then requests, their version in a
## header (none: 2025-03-26; one it doesn't speak: 400).
expect
	replied(earlier_request("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"roots\":{\"listChanged\":true}},\"clientInfo\":{\"name\":\"ExampleClient\",\"version\":\"1.0.0\"}}}", ""))
		== Replied(200, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{},\"resources\":{},\"prompts\":{}},\"serverInfo\":{\"name\":\"notes\",\"title\":\"Notes\",\"version\":\"1.0.0\"},\"instructions\":\"Notes, by id.\"}}")
expect (result_of(earlier_request("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\"}}", ""))).get("protocolVersion") == Ok(String("2025-11-25"))
expect replied(earlier_request("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", "2025-11-25")) == Replied(202, "")
expect (result_of(earlier_request("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", "2025-11-25"))).get("tools").is_ok()
expect (result_of(earlier_request("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", ""))).get("resultType") == Err(Missing)
expect replied(earlier_request("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", "2024-11-05")) == Replied(400, "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"supported\":[\"2026-07-28\",\"2025-11-25\",\"2025-06-18\",\"2025-03-26\"],\"requested\":\"2024-11-05\"}}}")
expect replied(earlier_request("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"add\",\"arguments\":{\"a\":1,\"b\":2}}}", "2025-06-18")) == Runs("tools/call", "add", Bool.False)

## The transport: only POST; JSON; one message; from a page, only this site's.
expect replied({ method: "GET", headers: [{ name: "accept", value: "text/event-stream" }], body: "" }) == Replied(405, "MCP is asked by POST here, not GET")
expect replied({ method: "DELETE", headers: [{ name: "mcp-session-id", value: "abc" }], body: "" }) == Replied(405, "MCP is asked by POST here, not DELETE")
expect replied({ method: "POST", headers: [{ name: "content-type", value: "text/plain" }], body: "{}" }) == Replied(415, "MCP is sent as JSON (application/json), not text/plain")
expect replied(earlier_request("{\"jsonrpc\":", "")) == Replied(400, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32700,\"message\":\"Not JSON: a value expected, at byte 11\"}}")
expect replied(earlier_request("[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]", "")) == Replied(400, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Send one JSON-RPC message, not a batch\"}}")
expect replied(earlier_request("{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{}}", "")) == Replied(202, "")
expect {
	from = |origin| { ..current_request("tools/list", "", [], []), headers: [{ name: "host", value: "localhost:3000" }, { name: "origin", value: origin }, { name: "mcp-protocol-version", value: "2026-07-28" }, { name: "mcp-method", value: "tools/list" }] }
	statuses = ["http://localhost:3000", "https://evil.example", "null"].map(
		|origin|
			match replied(from(origin)) {
				Replied(status, _) => status
				Runs(_, _, _) => 0
			},
	)
	statuses == [200, 403, 403]
}

## What the app's own test checks: names MCP takes, each once, and schemas that are JSON.
expect Mcp.problems(example) == []
expect {
	broken : Mcp.Server(Notes)
	broken = { name: "x", version: "1", tools: [Tool.typed("a b", "", "{", adding), Tool.typed("add", "", "", adding), Tool.typed("add", "", "", adding)] }
	Mcp.problems(broken) == ["The tool name \"a b\" isn't 1 to 128 of A-Z, a-z, 0-9, _, - and .", "The tool a b's input schema isn't JSON: a key expected, at byte 1", "Two of the tools are add"]
}
expect {
	clashing : Mcp.Server(Notes)
	clashing = { name: "x", version: "1", tools: [Tool.typed_with_params("append", "", "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}", "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}", |_, _, _| Ok({}))] }
	Mcp.problems(clashing) == ["The tool append's arguments name id both as its endpoint's path params and in its body: one object can't fill both (rename the body's field)"]
}

## A tool's progress, as the notification the stream sends.
expect {
	running : Mcp.Running(Notes)
	running = { id: Number("1"), era: Current("2026-07-28"), method: "tools/call", name: "shout", stream: Bool.True, progress: Ok(String("p1")), run: |_| { answer: accepted, failure: Err(NoFailure) } }
	Mcp.progress(running, 1, 3, "one done") == "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":\"p1\",\"progress\":1,\"total\":3,\"message\":\"one done\"}}"
}
