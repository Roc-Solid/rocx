import pf.Endpoint
import pf.Events
import pf.Log
import pf.Middleware
import pf.OpenApi
import pf.Server
import mcp.JsonValue
import mcp.Mcp
import mcp.Tool

## The HTTP side of an app's MCP server, on the server platform: the route that serves it
## (`respond!`, or `middleware`), and tools made from what the app has already, in a line each: an
## endpoint, its path's params too (`endpoint`), a function of the app's (`function`), a handler of
## its own (`tool`). Their
## arguments' and answers' JSON Schemas are the platform's, written from their types as
## /openapi.json's are (`OpenApi`).
##
##     # main.roc
##     middleware: Middlewares.default.then(McpHttp.middleware("/mcp", Agents.server)),
##
## The middleware in front of it decides who may ask, as for any route (`Auth` has the pieces of
## OAuth's answers).
McpHttp := [].{

	## What a tool is given: the request the MCP route is answering, what its middleware handed on
	## (`context`: who is asking), and `progress!`, how far the tool has got (done, of a total, 0
	## for unknown, and a message), which goes to the client before the answer if the tool is
	## `Tool.reporting` and the client asked to hear it; and does nothing if not.
	Caller(c) : { request : Server.Request, context : c, progress! : U64, U64, Str => {} }

	## A tool's name and what it does, for the model; its title, for people; and `tags`, the names
	## of the tags its types' unions have, for their schemas (rocx finds them in the app's code for
	## /openapi.json; PROPOSALS.md, "`Api.tags`"). A union none of whose tags are given is any value.
	About := { name : Str, description : Str, title : Str ?? "", tags : List(Str) ?? [] }

	## The answer to a request to the MCP route: JSON, or, for a tool that reports its progress to a
	## client that asked, a stream of events, its progress then its answer. A tool that failed inside
	## is logged, as an error, with why; the client is only told that it failed.
	respond! : Mcp.Server(Caller(c)), Server.Request, c => Server.Response
	respond! = |server, request, context| {
		incoming = { method: request.method, headers: request.headers, body: Server.text_of(request) }
		match Mcp.receive(server, incoming) {
			Reply(answer) => McpHttp.response(answer)
			Run(running) => {
				run! = running.run
				if running.stream {
					streamed = Events.stream(
						|{ send!, .. }| {
							progress! = |done, total, message| {
								_ = send!(Mcp.progress(running, done, total, message))
								{}
							}
							ran = run!({ request: request, context: context, progress!: progress! })
							logged!(ran)
							send!(ran.answer.body)
						},
					)
					answered = Server.events(streamed)
					{ ..answered, headers: answered.headers.append({ name: "x-accel-buffering", value: "no" }) }
				} else {
					ran = run!({ request: request, context: context, progress!: |_, _, _| {} })
					logged!(ran)
					McpHttp.response(ran.answer)
				}
			}
		}
	}

	## An answer of the protocol's (`Mcp.Answer`, `Auth.challenge`) as the server sends it.
	response : { status : U16, headers : List({ name : Str, value : Str }), body : Str } -> Server.Response
	response = |answer| Server.response(answer.status, answer.headers, answer.body)

	## The MCP server as a middleware: it answers requests to `path` (`respond!`), and hands every
	## other request on. An app whose tools are its endpoints mounts it this way, in `main.roc` (its
	## tools run `Generated/Handlers`' endpoints, which a module the routes import can't import,
	## D-037), after the middleware that decides who may ask:
	##
	##     middleware: Middlewares.default.then(McpHttp.middleware("/mcp", Agents.server)),
	middleware : Str, Mcp.Server(Caller(c)) -> Middleware(c, c)
	middleware = |path, server|
		Middleware.make(
			|request, context, next!|
				if request.path == path {
					McpHttp.respond!(server, request, context)
				} else {
					next!(request, context)
				},
		)

	## How the platform writes the JSON Schemas of what an endpoint's path holds (`params`), what it
	## is sent and what it answers: `McpHttp.openapi`. (Given to `endpoint`, `function` and `tool`
	## as a value, so it is instantiated where the types are known: a generic function can't read a
	## type with `Json` and describe it with `OpenApi` both, as each needs its own `parser_for`.)
	Schemas(c, params, arg, result) : { params : Endpoint(c, params, {}), List(Str) -> Str, body : Endpoint(c, arg, result), List(Str) -> Str, answer : Endpoint(c, arg, result), List(Str) -> Str }

	## The platform's schemas, as /openapi.json has them.
	openapi = |{}| { params: OpenApi.body, body: OpenApi.body, answer: OpenApi.answer }

	## An endpoint as a tool, from the function of its params that names it
	## (`McpHttp.endpoint(Handlers.put_api_notes_id_tags, { name: "tag_note", description: "Sets a
	## note's tags" }, McpHttp.openapi({}))`): the tool's arguments are one object, read as the
	## path's params (`{ id : Str }`) and as the endpoint's body (`{ tags : List(Str) }`), so the
	## model sends `{ "id": "7", "tags": ["work"] }`; its answer is the tool's. An endpoint of no
	## params is the same (`Handlers.post_api_search`). It runs as `Endpoint.run!` runs it (so it is
	## `Generated/Handlers`' endpoint, with its handler, not Api's contract), given the MCP route's
	## request and context; its own middleware doesn't run (the MCP route's has). A refusal
	## (`NotFound`, `BadRequest`) goes back to the model as a tool error. A field of the body named as
	## a param is an input schema `Mcp.problems` reports.
	endpoint : (params -> Endpoint(c, arg, result)), About, Schemas(c, params, arg, result) -> Tool(Caller(c))
		where [params.Json.Parseable([InvalidJson(Str)]), arg.Json.Parseable([InvalidJson(Str)]), result.Json.Encodable(e)]
	endpoint = |api, about, schemas| {
		describe_params = schemas.params
		describe_body = schemas.body
		describe_answer = schemas.answer
		named = contract_of(api)
		run! = |params, arg, caller| Endpoint.run!(api(params), caller.request, caller.context, arg).map_err(Server.explain)
		Tool.typed_with_params(about.name, about.description, describe_params(params_of(api), about.tags), describe_body(named, about.tags), run!).answers(answer_schema(describe_answer(named, about.tags))).titled(about.title)
	}

	## A function of the app's own as a tool (`McpHttp.function(Notes.add!, { name: "add_note",
	## description: "Adds a note" }, McpHttp.openapi({}))`): its argument is the tool's (an object's
	## `input` field, when it isn't a record), its answer the tool's. It runs in the MCP request,
	## behind the MCP route's middleware.
	function : (arg => result), About, Schemas(c, {}, arg, result) -> Tool(Caller(c))
		where [arg.Json.Parseable([InvalidJson(Str)]), result.Json.Encodable(e)]
	function = |called!, about, schemas| McpHttp.endpoint(|{}| Endpoint.local_json("POST", "/", |_, _, arg| Ok(called!(arg))), about, schemas)

	## A handler of the app's own as a tool: its arguments are a Roc type, its answer another, each
	## with the schema the platform writes for it.
	##
	##     McpHttp.tool({ name: "convert", description: "Celsius to Fahrenheit" }, convert!, McpHttp.openapi({}))
	tool : About, (arg, Caller(c) => Try(result, Str)), Schemas(c, {}, arg, result) -> Tool(Caller(c))
		where [arg.Json.Parseable([InvalidJson(Str)]), result.Json.Encodable(e)]
	tool = |about, handler!, schemas| {
		witness = witness_of(handler!)
		describe_body = schemas.body
		describe_answer = schemas.answer
		Tool.typed(about.name, about.description, describe_body(witness, about.tags), handler!).answers(answer_schema(describe_answer(witness, about.tags))).titled(about.title)
	}
}

## An endpoint of a handler's types, for `OpenApi` to write their schemas: never run.
witness_of : (arg, McpHttp.Caller(c) => Try(result, Str)) -> Endpoint(c, arg, result)
witness_of = |_| Endpoint.local_json("POST", "/", |_, _, _| crash "McpHttp: a witness of a tool's types, never run")

## An endpoint of the types an endpoint's function names, for `OpenApi` to write their schemas:
## never run.
contract_of : (params -> Endpoint(c, arg, result)) -> Endpoint(c, arg, result)
contract_of = |_| Endpoint.local_json("POST", "/", |_, _, _| crash "McpHttp: a witness of an endpoint's types, never run")

## An endpoint sent an endpoint's params, for `OpenApi` to write their schema: never run.
params_of : (params -> Endpoint(c, arg, result)) -> Endpoint(c, params, {})
params_of = |_| Endpoint.local_json("POST", "/", |_, _, _| crash "McpHttp: a witness of an endpoint's params, never run")

## The schema in what `OpenApi.answer` writes (`"application/json":{"schema":…}`).
answer_schema : Str -> Str
answer_schema = |content| content.drop_prefix("\"application/json\":{\"schema\":").drop_suffix("}")

## A failure inside, in the server's log.
logged! : Mcp.Ran => {}
logged! = |ran|
	match ran.failure {
		Ok(why) => Log.error!("mcp", { failure: why })
		Err(NoFailure) => {}
	}

## A tool from an endpoint with params: one object of arguments, its schema the params' and the
## body's.
appended : { id : Str } -> Endpoint({}, { text : Str }, Str)
appended = |params| Endpoint.local("POST", "/notes/${params.id}/append", |_, {}, { text }| Ok("${params.id}: ${text}"))

expect
	Tool.to_json(McpHttp.endpoint(appended, { name: "append", description: "Adds to a note" }, McpHttp.openapi({}))).get("inputSchema").map_ok(JsonValue.to_str)
		== Ok("{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"}},\"required\":[\"id\",\"text\"]}")

## A body that names a field as the path does: `Mcp.problems` says so.
retitled : { id : Str } -> Endpoint({}, { id : Str, title : Str }, Str)
retitled = |params| Endpoint.local("PUT", "/notes/${params.id}/title", |_, {}, { title, .. }| Ok(title))

expect {
	server : Mcp.Server(McpHttp.Caller({}))
	server = { name: "notes", version: "1", tools: [McpHttp.endpoint(appended, { name: "append", description: "" }, McpHttp.openapi({})), McpHttp.endpoint(retitled, { name: "retitle", description: "" }, McpHttp.openapi({}))] }
	Mcp.problems(server) == ["The tool retitle's arguments name id both as its endpoint's path params and in its body: one object can't fill both (rename the body's field)"]
}
