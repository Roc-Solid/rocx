import Content
import JsonValue

## Something an agent can do through the app: a name, what it does (for the model), the JSON Schema
## of its arguments, and what it does with them.
##
## `Tool.typed` reads the arguments into a Roc type (with `Json`, as an endpoint reads its body),
## and answers the result as JSON: the model reads it as text, and a client that wants data
## reads it as `structuredContent`. Its schema is the platform's, written from the same type
## (`McpHttp.tool`, `McpHttp.endpoint`), or one of the app's own. `Tool.new` takes the arguments as
## any JSON and answers with content of its own: text, images, links.
##
## A refusal (`Err("No note 7")`) goes back to the model as a tool error, which it can read and act
## on, as do arguments that don't fit; a failure inside (`Failed`) as a JSON-RPC error, its reason
## kept out of the answer, for the server's log.
Tool(ctx) := {
	name : Str,
	title : Str,
	description : Str,
	input : Try(JsonValue, [InvalidJson(Str), Clash(List(Str))]),
	output : Try(JsonValue, [NoOutput, InvalidJson(Str)]),
	hints : List((Str, Bool)),
	reports : Bool,
	prepare : JsonValue -> Try(ctx => Outcome, Str),
	doing : Str,
	listening : Try((JsonValue, ctx, (Tool.Update => Try({}, [Stopped])) => Outcome), [Plain]),
}.{

	## What a page can show while a model works, as it happens: a progress note the model wrote
	## between its tool calls (`Progress`), or a tool it is about to use (`Using`), with what the tool
	## says it is doing (`doing`; "" when it says nothing). Each names the agent it came from (its
	## name; "" for a call that has none). packages/ai sends them when a call asks for `updates`.
	Update : [Progress({ agent : Str, says : Str }), Using({ agent : Str, tool : Str, says : Str })]

	## The tool, with what a person is shown while it runs (`"Looking for your info…"`): the `says` of
	## the `Using` update a model's call sends as it is about to use it.
	doing : Tool(ctx), Str -> Tool(ctx)
	doing = |tool, said| { ..tool, doing: said }

	## What the tool says it is doing while it runs ("" for nothing).
	doing_of : Tool(ctx) -> Str
	doing_of = |tool| tool.doing

	## The tool, run with a listener when its caller has one: for a tool that works as a model does
	## (an agent), which tells the listener its own updates as they happen, for the caller to pass on.
	## `run!` checks its arguments itself (a refusal is a tool error); a caller without a listener runs
	## the tool as it was.
	with_listener : Tool(ctx), (JsonValue, ctx, (Tool.Update => Try({}, [Stopped])) => Outcome) -> Tool(ctx)
	with_listener = |tool, run!| { ..tool, listening: Ok(run!) }

	## The tool's run with a listener, if it takes one (`with_listener`).
	listener_of : Tool(ctx) -> Try((JsonValue, ctx, (Tool.Update => Try({}, [Stopped])) => Outcome), [Plain])
	listener_of = |tool| tool.listening

	## A tool: its name, what it does, the JSON Schema of its arguments (`""` takes any object), and
	## what it does with them, given as any JSON.
	new : Str, Str, Str, (JsonValue, ctx => Outcome) -> Tool(ctx)
	new = |name, description, schema, run!| {
		name: name,
		title: "",
		description: description,
		input: schema_of(schema).map_err(|InvalidJson(why)| InvalidJson(why)),
		output: Err(NoOutput),
		hints: [],
		reports: Bool.False,
		prepare: |arguments| Ok(|ctx| run!(arguments, ctx)),
		doing: "",
		listening: Err(Plain),
	}

	## A tool whose arguments are a Roc type and whose answer is a value of another: its name, what
	## it does, the JSON Schema of the arguments' type, and what it does with them. Arguments that
	## don't fit the type go back to the model, as a tool error saying why. A schema that isn't an
	## object's (a tool that takes a `Str`) is the schema of an object's `input` field, which is
	## what the tool is given. The answer is its JSON, as text and as structured content (an object;
	## any other value as its `result` field).
	typed : Str, Str, Str, (arg, ctx => Try(result, Str)) -> Tool(ctx)
		where [arg.Json.Parseable([InvalidJson(Str)]), result.Json.Encodable(e)]
	typed = |name, description, schema, run!| {
		read = schema_of(schema)
		wrapped = !is_object_schema(read)
		input = if (wrapped) read.map_ok(wrap_input) else read
		{
			name: name,
			title: "",
			description: description,
			input: input.map_err(|InvalidJson(why)| InvalidJson(why)),
			output: Err(NoOutput),
			hints: [],
			reports: Bool.False,
			prepare: |arguments| {
				given = if (wrapped) arguments.get("input") ?? Null else arguments
				decoded : Try(arg, [InvalidJson(Str)])
				decoded = JsonValue.decode(given)
				match decoded {
					Ok(arg) => Ok(|ctx| Tool.answer(run!(arg, ctx)))
					Err(InvalidJson(why)) => Err("Invalid arguments for ${name}: ${why}")
				}
			},
			doing: "",
			listening: Err(Plain),
		}
	}

	## A tool whose arguments are two Roc types, read from one object: an endpoint's path params
	## (`{ id : Str }`) and its body, as `McpHttp.endpoint` makes one, each read from the arguments
	## (`Json` skips the fields a type doesn't have). Its schema is both: the params' properties and
	## the body's, and both required lists. A name in both is an input schema `Mcp.problems`
	## reports, as the arguments can't say which it is for. A body whose schema isn't an object's is
	## the arguments' `input` field, as `typed` reads one; params of no fields leave the body's
	## schema as it is.
	typed_with_params : Str, Str, Str, Str, (params, arg, ctx => Try(result, Str)) -> Tool(ctx)
		where [params.Json.Parseable([InvalidJson(Str)]), arg.Json.Parseable([InvalidJson(Str)]), result.Json.Encodable(e)]
	typed_with_params = |name, description, params_schema, body_schema, run!| {
		read = schema_of(body_schema)
		wrapped = !is_object_schema(read)
		body = if (wrapped) read.map_ok(wrap_input) else read
		{
			name: name,
			title: "",
			description: description,
			input: merged(schema_of(params_schema), body),
			output: Err(NoOutput),
			hints: [],
			reports: Bool.False,
			prepare: |arguments| {
				given = if (wrapped) arguments.get("input") ?? Null else arguments
				in_path : Try(params, [InvalidJson(Str)])
				in_path = JsonValue.decode(arguments)
				decoded : Try(arg, [InvalidJson(Str)])
				decoded = JsonValue.decode(given)
				match (in_path, decoded) {
					(Ok(params), Ok(arg)) => Ok(|ctx| Tool.answer(run!(params, arg, ctx)))
					(Err(InvalidJson(why)), _) => Err("Invalid arguments for ${name}: ${why}")
					(_, Err(InvalidJson(why))) => Err("Invalid arguments for ${name}: ${why}")
				}
			},
			doing: "",
			listening: Err(Plain),
		}
	}

	## A typed tool's outcome: its result as JSON, or its refusal.
	answer : Try(result, Str) -> Outcome where [result.Json.Encodable(e)]
	answer = |done|
		match done {
			Ok(result) =>
				match JsonValue.encode(result) {
					Ok(written) => Tool.structured(written)
					Err(Unwritable) => Failed("its answer holds a number JSON can't write (an F64 that is NaN or an infinity)")
				}
			Err(why) => Refused(why)
		}

	## The tool, with a title for people.
	titled : Tool(ctx), Str -> Tool(ctx)
	titled = |tool, title| { ..tool, title: title }

	## The tool, with the JSON Schema of its answer (`outputSchema`); an object's, or the schema of
	## an object's `result` field, as `typed` answers.
	answers : Tool(ctx), Str -> Tool(ctx)
	answers = |tool, schema| {
		read = schema_of(schema)
		wrapped = if (is_object_schema(read)) read else read.map_ok(|inner| Object([("type", String("object")), ("properties", Object([("result", inner)])), ("required", Array([String("result")]))]))
		{ ..tool, output: wrapped.map_err(|InvalidJson(why)| InvalidJson(why)) }
	}

	## The tool changes nothing: a hint for the client, which may ask before running one that does.
	read_only : Tool(ctx) -> Tool(ctx)
	read_only = |tool| hinted(tool, "readOnlyHint", Bool.True)

	## The tool changes things, but only adds: it never deletes or overwrites (`destructiveHint:
	## false`). A client takes one that changes things to destroy them, unless it says.
	additive : Tool(ctx) -> Tool(ctx)
	additive = |tool| hinted(tool, "destructiveHint", Bool.False)

	## Running the tool twice with the same arguments does no more than running it once.
	idempotent : Tool(ctx) -> Tool(ctx)
	idempotent = |tool| hinted(tool, "idempotentHint", Bool.True)

	## The tool reaches nothing outside the app (`openWorldHint: false`): no web, no other service.
	closed_world : Tool(ctx) -> Tool(ctx)
	closed_world = |tool| hinted(tool, "openWorldHint", Bool.False)

	## The tool says how far it has got (`progress!`): a client that asks to hear it (a
	## `progressToken`) gets the answer as a stream of events, each step as it is taken, then the
	## answer.
	reporting : Tool(ctx) -> Tool(ctx)
	reporting = |tool| { ..tool, reports: Bool.True }

	## An answer of text.
	text : Str -> Outcome
	text = |said| Answered({ content: [Text(said)], structured: Err(Unstructured) })

	## An answer of data: as text for the model, and as `structuredContent` (an object; any other
	## value as its `result` field).
	structured : JsonValue -> Outcome
	structured = |data| {
		object = if (data.is_object()) data else Object([("result", data)])
		Answered({ content: [Text(JsonValue.to_str(data))], structured: Ok(object) })
	}

	## What running a tool came to: its answer (content, and data if it has some); a refusal the
	## model can act on, as a tool error; or a failure inside, as a JSON-RPC error, its reason for
	## the server's log.
	Outcome : [Answered({ content : List(Content), structured : Try(JsonValue, [Unstructured]) }), Refused(Str), Failed(Str)]

	## The tool as `tools/list` lists it. A schema that isn't JSON is listed as any object's (and
	## `Mcp.problems` names it).
	to_json : Tool(ctx) -> JsonValue
	to_json = |tool| {
		any = Object([("type", String("object"))])
		JsonValue.object_of([
			("name", Ok(String(tool.name))),
			("title", JsonValue.text_unless_empty(tool.title)),
			("description", JsonValue.text_unless_empty(tool.description)),
			("inputSchema", Ok(tool.input ?? any)),
			("outputSchema", tool.output.map_err(|_| Absent)),
			("annotations", if (tool.hints.is_empty()) Err(Absent) else Ok(Object(tool.hints.map(|(hint, yes)| (hint, Boolean(yes)))))),
		])
	}

	## What running a tool came to, as `tools/call` answers it (or `Failed`, which isn't).
	outcome_json : Outcome -> Try(List((Str, JsonValue)), [Failed(Str)])
	outcome_json = |outcome|
		match outcome {
			Answered(done) => {
				data =
					match done.structured {
						Ok(given) => [("structuredContent", given)]
						Err(Unstructured) => []
					}
				Ok([("content", Array(done.content.map(Content.to_json)))].concat(data))
			}
			Refused(why) => Ok([("content", Array([Content.to_json(Text(why))])), ("isError", Boolean(Bool.True))])
			Failed(why) => Err(Failed(why))
		}
}

## A schema's JSON; `""`, any object's.
schema_of : Str -> Try(JsonValue, [InvalidJson(Str)])
schema_of = |schema| if (schema.trim().is_empty()) Ok(Object([("type", String("object"))])) else JsonValue.parse(schema)

## An object's schema with `inner` as its one field, `input`: the arguments of a tool that takes
## another value.
wrap_input : JsonValue -> JsonValue
wrap_input = |inner| Object([("type", String("object")), ("properties", Object([("input", inner)])), ("required", Array([String("input")]))])

## The arguments' schema of a tool with params (`typed_with_params`): the params' properties and the
## body's, and both required lists; `Clash` with the names both have. Params of no fields, the body's.
merged : Try(JsonValue, [InvalidJson(Str)]), Try(JsonValue, [InvalidJson(Str)]) -> Try(JsonValue, [InvalidJson(Str), Clash(List(Str))])
merged = |params, body|
	match (params, body) {
		(Err(InvalidJson(why)), _) => Err(InvalidJson(why))
		(_, Err(InvalidJson(why))) => Err(InvalidJson(why))
		(Ok(of_params), Ok(of_body)) => {
			named = fields_of(of_params, "properties")
			if named.is_empty() {
				Ok(of_body)
			} else {
				own = fields_of(of_body, "properties")
				both = named.keep_if(|(key, _)| own.any(|(other, _)| other == key)).map(|(key, _)| key)
				if both.is_empty() {
					Ok(Object([("type", String("object")), ("properties", Object(named.concat(own))), ("required", Array(items_of(of_params, "required").concat(items_of(of_body, "required"))))]))
				} else {
					Err(Clash(both))
				}
			}
		}
	}

## An object's field that is an object: its fields; none if it isn't one.
fields_of : JsonValue, Str -> List((Str, JsonValue))
fields_of = |value, key|
	match value.get(key) {
		Ok(Object(fields)) => fields
		_ => []
	}

## An object's field that is an array: its items; none if it isn't one.
items_of : JsonValue, Str -> List(JsonValue)
items_of = |value, key|
	match value.get(key) {
		Ok(Array(items)) => items
		_ => []
	}

## Whether a schema is an object's (`"type": "object"`), as MCP's arguments and structured answers
## have to be.
is_object_schema : Try(JsonValue, [InvalidJson(Str)]) -> Bool
is_object_schema = |read|
	match read {
		Ok(schema) => schema.get("type") == Ok(String("object"))
		Err(_) => Bool.True
	}

hinted : Tool(ctx), Str, Bool -> Tool(ctx)
hinted = |tool, hint, yes| { ..tool, hints: tool.hints.keep_if(|(name, _)| name != hint).append((hint, yes)) }

adding : { a : I64, b : I64 }, {} => Try({ sum : I64 }, Str)
adding = |args, _| if (args.a < 0) Err("Only counts") else Ok({ sum: args.a + args.b })

add : Tool({})
add = Tool.typed("add", "Adds two numbers", "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"integer\"},\"b\":{\"type\":\"integer\"}},\"required\":[\"a\",\"b\"]}", adding).read_only().titled("Add")

shouting : Str, {} => Try(Str, Str)
shouting = |said, _| Ok(said.with_ascii_uppercased())

shout : Tool({})
shout = Tool.typed("shout", "Shouts", "{\"type\":\"string\"}", shouting).answers("{\"type\":\"string\"}")

prepared : Tool({}), Str -> Try({}, Str)
prepared = |tool, arguments| {
	given = JsonValue.parse(arguments) ?? Null
	(tool.prepare)(given).map_ok(|_| {})
}

expect prepared(add, "{\"a\":1,\"b\":2}") == Ok({})
expect prepared(add, "{\"a\":1,\"b\":2,\"c\":3}") == Ok({})
expect prepared(add, "{\"a\":1}").is_err()
expect prepared(add, "{\"a\":\"one\",\"b\":2}").map_err(|why| why.starts_with("Invalid arguments for add: ")) == Err(Bool.True)
expect prepared(shout, "{\"input\":\"hi\"}") == Ok({})
expect prepared(shout, "{\"said\":\"hi\"}").is_err()

## A tool with params: its arguments read twice, as the params and as the body; its schema both.
appending : { id : Str }, { text : Str }, {} => Try(Str, Str)
appending = |params, body, _| Ok("${params.id}: ${body.text}")

append : Tool({})
append = Tool.typed_with_params("append", "Adds to a note", "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}", "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}", appending)

expect prepared(append, "{\"id\":\"7\",\"text\":\"milk\"}") == Ok({})
expect prepared(append, "{\"text\":\"milk\"}").map_err(|why| why.starts_with("Invalid arguments for append: ")) == Err(Bool.True)
expect prepared(append, "{\"id\":7,\"text\":\"milk\"}").is_err()
expect prepared(append, "{\"id\":\"7\"}").is_err()
expect
	Tool.to_json(append).get("inputSchema").map_ok(JsonValue.to_str)
		== Ok("{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"}},\"required\":[\"id\",\"text\"]}")

## Params of no fields: the body's schema as it is. A body that isn't an object's: its `input`.
expect Tool.to_json(Tool.typed_with_params("add", "", "{\"type\":\"object\",\"properties\":{},\"required\":[]}", "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"integer\"}},\"required\":[\"a\"]}", |{}, { a }, {}| Ok(a + 1))).get("inputSchema").map_ok(JsonValue.to_str) == Ok("{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"integer\"}},\"required\":[\"a\"]}")
expect {
	renaming : Tool({})
	renaming = Tool.typed_with_params("rename", "", "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}", "{\"type\":\"string\"}", |{ id }, name, {}| Ok("${id} is ${name}"))
	Tool.to_json(renaming).get("inputSchema").map_ok(JsonValue.to_str) == Ok("{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"input\":{\"type\":\"string\"}},\"required\":[\"id\",\"input\"]}")
		and prepared(renaming, "{\"id\":\"7\",\"input\":\"Shed\"}") == Ok({})
}

## A name in both the params and the body: a clash, which `Mcp.problems` names.
expect Tool.typed_with_params("both", "", "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}", "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"}},\"required\":[\"id\",\"text\"]}", appending).input == Err(Clash(["id"]))

expect
	JsonValue.to_str(Tool.to_json(add))
		== "{\"name\":\"add\",\"title\":\"Add\",\"description\":\"Adds two numbers\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"integer\"},\"b\":{\"type\":\"integer\"}},\"required\":[\"a\",\"b\"]},\"annotations\":{\"readOnlyHint\":true}}"

## A schema that isn't an object's: an object's `input` (arguments) or `result` (answer).
expect
	JsonValue.to_str(Tool.to_json(shout))
		== "{\"name\":\"shout\",\"description\":\"Shouts\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"input\":{\"type\":\"string\"}},\"required\":[\"input\"]},\"outputSchema\":{\"type\":\"object\",\"properties\":{\"result\":{\"type\":\"string\"}},\"required\":[\"result\"]}}"

expect Tool.to_json(Tool.new("any", "", "", |_, _| Tool.text("ok")).additive().additive()).get("annotations") == Ok(Object([("destructiveHint", Boolean(Bool.False))]))
expect Tool.to_json(Tool.new("broken", "", "{", |_, _| Tool.text("ok"))).get("inputSchema") == Ok(Object([("type", String("object"))]))

## Outcomes, as `tools/call` answers them.
expect {
	done : Try({ sum : I64 }, Str)
	done = Ok({ sum: 3 })
	Tool.answer(done) == Answered({ content: [Text("{\"sum\":3}")], structured: Ok(Object([("sum", Number("3"))])) })
}
expect Tool.answer(Ok("LOUD")) == Answered({ content: [Text("\"LOUD\"")], structured: Ok(Object([("result", String("LOUD"))])) })
expect {
	done : Try(Str, Str)
	done = Err("No note 7")
	Tool.answer(done) == Refused("No note 7")
}

expect
	Tool.outcome_json(Refused("No note 7")).map_ok(|fields| JsonValue.to_str(Object(fields)))
		== Ok("{\"content\":[{\"type\":\"text\",\"text\":\"No note 7\"}],\"isError\":true}")
expect Tool.outcome_json(Failed("the disk")) == Err(Failed("the disk"))
expect
	Tool.outcome_json(Tool.structured(Object([("sum", Number("3"))]))).map_ok(|fields| JsonValue.to_str(Object(fields)))
		== Ok("{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"sum\\\":3}\"}],\"structuredContent\":{\"sum\":3}}")
