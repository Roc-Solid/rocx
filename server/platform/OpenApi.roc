import Endpoint
import Events
import Middleware
import Server

## An app's endpoints as an OpenAPI document (3.2), which the server answers `GET /openapi.json`
## with. rocx writes it from the routes (`Api.openapi`): each path and its params; each method
## there and what its handler's comment says; and the JSON Schemas of what it is sent and what it
## answers, from their types as the compiler has them, written down or inferred.
##
## Roc has no reflection, but a type's parser is one for any format, and is handed each record's
## field names. This module's format (`Schema`) reads nothing: it writes the schema of each shape
## it is asked to read. A tag union's parser doesn't say what its tags are, so the format tries
## each name rocx found in the app's code (`tags`) and keeps the ones the union has.
OpenApi := [].{

	## The schema of what an endpoint is sent (its `body`), as JSON.
	body : Endpoint(context, arg, result), List(Str) -> Str
		where [arg.parser_for : Schema -> (State -> Try({ value : arg, rest : State }, Problem))]
	body = |_, tags| {
		Sent : arg
		described(Sent.parser_for(Schema.Default)(start(tags)))
	}

	## What an endpoint is sent, as an operation's request body has it: JSON, and, when its type is
	## one a form has (a record of strings, numbers, yes-or-no, choices and lists of them: what
	## `FormBody` reads), a form's fields too, URL-encoded (`application/x-www-form-urlencoded`) or
	## as a browser sends a form with files (`multipart/form-data`), the same schema, but a yes-or-no
	## and a list not required (a box left unticked isn't sent). A checked endpoint's (D-093) is its
	## rules' schema (`Endpoint.checked_schema`: what they require, their lengths, patterns and
	## ranges), the same three ways, as it reads a JSON object and a form alike.
	sent : Endpoint(context, arg, result), List(Str) -> Str
		where [arg.parser_for : Schema -> (State -> Try({ value : arg, rest : State }, Problem))]
	sent = |endpoint, tags|
		match Endpoint.checked_schema(endpoint) {
			Ok(schema) => "\"application/json\":{\"schema\":${schema}},\"application/x-www-form-urlencoded\":{\"schema\":${schema}},\"multipart/form-data\":{\"schema\":${schema}}"
			Err(Unchecked) => {
				Sent : arg
				json = "\"application/json\":{\"schema\":${described(Sent.parser_for(Schema.Default)(start(tags)))}}"
				match Sent.parser_for(Schema.Default)({ ..start(tags), form: Bool.True }) {
					Ok(done) if !done.rest.formless and done.rest.out.starts_with("{\"type\":\"object\",\"properties\":") =>
						"${json},\"application/x-www-form-urlencoded\":{\"schema\":${done.rest.out}},\"multipart/form-data\":{\"schema\":${done.rest.out}}"
					_ => json
				}
			}
		}

	## An endpoint's answer, as an operation's content has it: JSON, and its schema.
	answer : Endpoint(context, arg, result), List(Str) -> Str
		where [result.parser_for : Schema -> (State -> Try({ value : result, rest : State }, Problem))]
	answer = |_, tags| {
		Answered : result
		"\"application/json\":{\"schema\":${described(Answered.parser_for(Schema.Default)(start(tags)))}}"
	}

	## An endpoint's answer of its own (D-106: its handler's `Try(Server.Response, …)`), as an
	## operation's content has it: any type, with no schema, since the handler says what it sends.
	as_is : Endpoint(context, arg, Server.Response), List(Str) -> Str
	as_is = |_, _| "\"*/*\":{}"

	## An endpoint's events (`events!`), as an operation's content has them: a stream of events,
	## each one's data JSON, with its schema; then an `end` event, with none.
	events : Endpoint(context, {}, Events(event)), List(Str) -> Str
		where [event.parser_for : Schema -> (State -> Try({ value : event, rest : State }, Problem))]
	events = |_, tags| {
		Sent : event
		data = described(Sent.parser_for(Schema.Default)(start(tags)))
		each = "{\"type\":\"object\",\"required\":[\"data\"],\"properties\":{\"data\":{\"type\":\"string\",\"contentMediaType\":\"application/json\",\"contentSchema\":${data}}}}"
		end = "{\"type\":\"object\",\"required\":[\"event\"],\"properties\":{\"event\":{\"const\":\"end\"}}}"
		"\"text/event-stream\":{\"itemSchema\":{\"oneOf\":[${each},${end}]}}"
	}

	## A method at a path (`"get"`): its summary (its handler's comment's first sentence, which
	## Swagger UI and Scalar list it by), what its handler's comment says, its body's contents
	## (`sent`; `""` for none: a GET's, a DELETE's) and its answer's contents (`answer`, `events`).
	operation : Str, Str, Str, Str, List(Str) -> Str
	operation = |verb, summary, doc, taken, contents| {
		summed_up = if (summary.is_empty()) "" else "\"summary\":${Json.to_str(summary)},"
		described_as = if (doc.is_empty()) "" else "\"description\":${Json.to_str(doc)},"
		request = if (taken.is_empty()) "" else "\"requestBody\":{\"required\":true,\"content\":{${taken}}},"
		refused = "\"default\":{\"description\":\"Refused: its status, and why, as text (400 for a body it can't read); a form's issues (422) as JSON; or the handler's own answer (a redirect)\",\"content\":{\"text/plain\":{\"schema\":{\"type\":\"string\"}},\"application/json\":{}}}"
		"${Json.to_str(verb)}:{${summed_up}${described_as}${request}\"responses\":{\"200\":{\"description\":\"OK\",\"content\":{${Str.join_with(contents, ",")}}},${refused}}}"
	}

	## A path as OpenAPI writes it (`/api/count/{to}`), its params, and its methods (`operation`).
	path : Str, List(Str), List(Str) -> Str
	path = |at, params, operations| with_parameters(at, params.map(|name| { name: name, schema: "{\"type\":\"string\"}" }), operations)

	## A path as `path` writes it, its params of the types their handlers give them (D-092): `api`
	## is Api's function of the path's params (`Api.get_monitors_id`), which this doesn't call; each
	## field of its params' record is a parameter of the path, with its schema (`{ id : I64 }`: an
	## integer).
	typed_path : Str, (params -> Endpoint(context, arg, result)), List(Str), List(Str) -> Str
		where [params.parser_for : Schema -> (State -> Try({ value : params, rest : State }, Problem))]
	typed_path = |at, _, tags, operations| {
		Params : params
		written =
			match Params.parser_for(Schema.Default)(start(tags)) {
				Ok(done) => {
					out = done.rest.out.to_utf8()
					done.rest.marks.map(|mark| { name: mark.name, schema: Str.from_utf8_lossy(out.sublist({ start: mark.start, len: mark.end - mark.start })) })
				}
				Err(_) => []
			}
		with_parameters(at, written, operations)
	}

	## The document: its title, and its paths (`path`).
	document : Str, List(Str) -> Str
	document = |title, paths|
		"{\"openapi\":\"3.2.0\",\"info\":{\"title\":${Json.to_str(title)},\"version\":\"0\"},\"paths\":{${Str.join_with(paths, ",")}}}"

	## Whether an app serves its endpoints' document, and a page to read it in. `Off`, unless the
	## app says (`App.program({ …, openapi: Page(Swagger) })`): nothing. `Document`:
	## `GET /openapi.json`. `Page(Swagger)` or `Page(Scalar)`: that, and `GET /openapi.html`, the
	## document in Swagger UI or Scalar, which the page loads from jsDelivr, pinned to one version and
	## checked against its hash, and tells not to call home.
	Serving : [Off, Document, Page([Swagger, Scalar])]

	## The answer to a request for the document (`json`, the app's `Api.openapi`) or its page, as
	## `serving` says: JSON, or HTML; 405 for a method but GET. Any other request, or one for what
	## `serving` doesn't serve, is `NotHere`: the routes answer it. A program an app writes itself can
	## ask it before its routes:
	##
	##     match OpenApi.respond(request, Page(Swagger), Api.openapi) {
	##         Ok(served) => served
	##         Err(NotHere) => Routes.respond!(request, context)
	##     }
	##
	## or put `middleware` at the end of its chain, as `App.program` does.
	respond : Server.Request, Serving, Str -> Try(Server.Response, [NotHere])
	respond = |request, serving, json| {
		reading = request.method == "GET" or request.method == "HEAD"
		served = |kind, text|
			if reading {
				Ok(Server.response(200, [{ name: "content-type", value: kind }], text))
			} else {
				Ok(Endpoint.not_allowed(request, ["GET"]))
			}
		match serving {
			Off => Err(NotHere)
			Document =>
				if request.path == "/openapi.json" {
					served("application/json", json)
				} else {
					Err(NotHere)
				}
			Page(viewer) =>
				if request.path == "/openapi.json" {
					served("application/json", json)
				} else if request.path == "/openapi.html" {
					served("text/html; charset=utf-8", page(viewer))
				} else {
					Err(NotHere)
				}
		}
	}

	## The document and its page as a middleware: it answers what `respond` serves, and hands every
	## other request on, unchanged. `App.program` runs it behind the app's own middleware
	## (routes/+middleware.roc), so a guard there guards the document too:
	##
	##     Middleware.run!(OpenApi.middleware(Page(Swagger), Api.openapi), request, context, next!)
	middleware : Serving, Str -> Middleware(context, context)
	middleware = |serving, json|
		Middleware.make(
			|request, context, next!|
				match respond(request, serving, json) {
					Ok(served) => served
					Err(NotHere) => next!(request, context)
				},
		)
}

## A path's entry: its params, each with its schema, then its methods.
with_parameters : Str, List({ name : Str, schema : Str }), List(Str) -> Str
with_parameters = |at, params, operations| {
	param = |each| "{\"name\":${Json.to_str(each.name)},\"in\":\"path\",\"required\":true,\"schema\":${each.schema}}"
	taken = if (params.is_empty()) "" else "\"parameters\":[${Str.join_with(params.map(param), ",")}],"
	"${Json.to_str(at)}:{${taken}${Str.join_with(operations, ",")}}"
}

## The page that shows the document, `openapi.json` beside it (so a copy under a base path, as
## on GitHub Pages, finds it too), in `viewer`. Each is pinned to one version on jsDelivr and
## checked against its hash (`integrity`), and told not to call home: Swagger UI not to send the
## document's address to its validator, Scalar to send no telemetry, load no fonts of its own, and
## show no developer tools (links to its services) or agent or MCP panel.
page : [Swagger, Scalar] -> Str
page = |viewer| {
	(head, body) =
		match viewer {
			Swagger => (
				"<link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.35.1/swagger-ui.css\" integrity=\"sha384-WlYgdmXYOOBWL5apwjDEZwN+U3HmXSSu5R6V5aGxEcf7z+KuRNwBhoxKVN1i3D5I\" crossorigin=\"anonymous\">\n<style>body { margin: 0; }</style>",
				"<div id=\"swagger-ui\"></div>\n<script src=\"https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.35.1/swagger-ui-bundle.js\" integrity=\"sha384-J5eKRXKO1KzUTPkO0GRmGH2WEYUg6SSZlufilxvTwI6nmhLumjNWFMby3QQnyobZ\" crossorigin=\"anonymous\"></script>\n<script>SwaggerUIBundle({ url: \"openapi.json\", dom_id: \"#swagger-ui\", validatorUrl: null });</script>",
			)
			Scalar => (
				"",
				"<div id=\"app\"></div>\n<script src=\"https://cdn.jsdelivr.net/npm/@scalar/api-reference@1.82.1/dist/browser/standalone.js\" integrity=\"sha384-3llXraiLKrfG/eL4517CCzYH4wdaQ+bXhZeTcZKnEyJUu2vwIdsFBOVMa3m5lD4h\" crossorigin=\"anonymous\"></script>\n<script>Scalar.createApiReference(\"#app\", { url: \"openapi.json\", telemetry: false, withDefaultFonts: false, showDeveloperTools: \"never\", agent: { disabled: true }, mcp: { disabled: true } });</script>",
			)
		}
	"<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>API</title>\n${head}\n</head>\n<body>\n${body}\n</body>\n</html>\n"
}

## How deep the format goes into lists and tag unions, so a type that holds itself (a tree) ends.
max_depth : U64
max_depth = 5

## Where the format is: in a record, the index of its next field; in a list or a dict, whether it
## reads its one item (`Item`, `Entry`) or none (`NoItem`, deeper than `max_depth`).
Frame : [Fields(U64), Item, NoItem, Entry]

## What the format has written, where it is, and the names it tries as a tag union's tags. Writing
## a form's schema (`form`, for `sent`): the record's field it is in (`field`), the fields a form
## may leave out (`loose`: a yes-or-no, a list), and whether it found a shape a form doesn't have
## (`formless`: a record in a field, a tuple, a dict, null, a tag with a payload, a list of lists).
## Where each of the outermost record's fields' schemas starts and ends in `out` (`marks`, its
## bytes), for a path's params (`typed_path`).
State : { out : Str, at : List(Frame), tags : List(Str), depth : U64, form : Bool, field : Str, loose : List(Str), formless : Bool, marks : List({ name : Str, start : U64, end : U64 }) }

## Why a schema couldn't be written: a tag union none of the names are tags of, or one too deep.
## (`NotThisTag` is a name that isn't one of a union's: the format tries the next.)
Problem : [NotThisTag, TooDeep, NoTags, MissingField(Str), Invalid]

start : List(Str) -> State
start = |tags| { out: "", at: [], tags: tags, depth: 0, form: Bool.False, field: "", loose: [], formless: Bool.False, marks: [] }

## Writing a form's schema, at a shape a form doesn't have: so noted.
formless : State -> State
formless = |state| if (state.form) { ..state, formless: Bool.True } else state

## Writing a form's schema, a value right in the record's field (`at` one deep) a form may leave
## out: the field noted as not required.
loose : State -> State
loose = |state| if (state.form and state.at.len() == 1) { ..state, loose: state.loose.append(state.field) } else state

## A schema, or, where the format couldn't write one, a schema any value meets, saying why.
described : Try({ value : a, rest : State }, Problem) -> Str
described = |parsed|
	match parsed {
		Ok(done) => done.rest.out
		Err(NoTags) => "{\"description\":\"A tag union none of whose tags rocx found in the app's code\"}"
		Err(TooDeep) => "{\"description\":\"A type that holds itself, deeper than rocx describes\"}"
		Err(_) => "{}"
	}

emit : State, Str -> State
emit = |state, text| { ..state, out: state.out.concat(text) }

## Into a list or a dict: one level deeper, and its frame.
enter : State, Str, Frame -> State
enter = |state, text, frame| { ..state, out: state.out.concat(text), at: state.at.append(frame), depth: state.depth + 1 }

## Out of a list or a dict, or a record.
leave : State, Str -> State
leave = |state, text| { ..state, out: state.out.concat(text), at: state.at.drop_last(1), depth: if (state.depth > 0) state.depth - 1 else 0 }

## A scalar: its schema written, and a value of its type, which nothing reads.
scalar : State, Str, a -> Try({ value : a, rest : State }, Problem)
scalar = |state, schema, value| Ok({ value: value, rest: emit(state, schema) })

## The schema of a tag union, from the names of its tags with no payload and the schemas of those
## with: as JSON has them, `"Red"`, `{ "Rgb": [1, 2, 3] }`.
union_schema : List(Str), List(Str) -> Str
union_schema = |bare, shaped| {
	names = if (bare.is_empty()) [] else ["{\"type\":\"string\",\"enum\":[${Str.join_with(bare.map(Json.to_str), ",")}]}"]
	all = names.concat(shaped)
	if all.len() == 1 {
		Str.join_with(all, "")
	} else {
		"{\"oneOf\":[${Str.join_with(all, ",")}]}"
	}
}

## A format that reads nothing: each `parse_*` writes the JSON Schema of the shape it is asked for,
## as `Json` writes that shape, and gives back a value of its type that nothing reads.
Schema := [Default].{
	rename_field : Schema, Str -> Str
	rename_field = |_, name| name

	missing_field : Schema, Str -> Problem
	missing_field = |_, name| MissingField(name)

	invalid_value : Schema, State -> Problem
	invalid_value = |_, _| Invalid

	parse_str : Schema, State -> Try({ value : Str, rest : State }, Problem)
	parse_str = |_, state| scalar(state, "{\"type\":\"string\"}", "")

	parse_bool : Schema, State -> Try({ value : Bool, rest : State }, Problem)
	parse_bool = |_, state| scalar(loose(state), "{\"type\":\"boolean\"}", False)

	parse_u8 : Schema, State -> Try({ value : U8, rest : State }, Problem)
	parse_u8 = |_, state| scalar(state, "{\"type\":\"integer\",\"minimum\":0,\"maximum\":255}", 0)

	parse_i8 : Schema, State -> Try({ value : I8, rest : State }, Problem)
	parse_i8 = |_, state| scalar(state, "{\"type\":\"integer\",\"minimum\":-128,\"maximum\":127}", 0)

	parse_u16 : Schema, State -> Try({ value : U16, rest : State }, Problem)
	parse_u16 = |_, state| scalar(state, "{\"type\":\"integer\",\"minimum\":0,\"maximum\":65535}", 0)

	parse_i16 : Schema, State -> Try({ value : I16, rest : State }, Problem)
	parse_i16 = |_, state| scalar(state, "{\"type\":\"integer\",\"minimum\":-32768,\"maximum\":32767}", 0)

	parse_u32 : Schema, State -> Try({ value : U32, rest : State }, Problem)
	parse_u32 = |_, state| scalar(state, "{\"type\":\"integer\",\"minimum\":0,\"maximum\":4294967295}", 0)

	parse_i32 : Schema, State -> Try({ value : I32, rest : State }, Problem)
	parse_i32 = |_, state| scalar(state, "{\"type\":\"integer\",\"format\":\"int32\"}", 0)

	parse_u64 : Schema, State -> Try({ value : U64, rest : State }, Problem)
	parse_u64 = |_, state| scalar(state, "{\"type\":\"integer\",\"minimum\":0}", 0)

	parse_i64 : Schema, State -> Try({ value : I64, rest : State }, Problem)
	parse_i64 = |_, state| scalar(state, "{\"type\":\"integer\",\"format\":\"int64\"}", 0)

	parse_u128 : Schema, State -> Try({ value : U128, rest : State }, Problem)
	parse_u128 = |_, state| scalar(state, "{\"type\":\"integer\",\"minimum\":0}", 0)

	parse_i128 : Schema, State -> Try({ value : I128, rest : State }, Problem)
	parse_i128 = |_, state| scalar(state, "{\"type\":\"integer\"}", 0)

	parse_dec : Schema, State -> Try({ value : Dec, rest : State }, Problem)
	parse_dec = |_, state| scalar(state, "{\"type\":\"number\"}", 0)

	parse_f32 : Schema, State -> Try({ value : F32, rest : State }, Problem)
	parse_f32 = |_, state| scalar(state, "{\"type\":\"number\",\"format\":\"float\"}", 0)

	parse_f64 : Schema, State -> Try({ value : F64, rest : State }, Problem)
	parse_f64 = |_, state| scalar(state, "{\"type\":\"number\",\"format\":\"double\"}", 0)

	parse_null : Schema, State -> Try(State, Problem)
	parse_null = |_, state| Ok(emit(formless(state), "{\"type\":\"null\"}"))

	## A list: the schema of its one item, unless it is too deep (a type that holds itself).
	parse_list_start : Schema, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], Problem)
	parse_list_start = |_, given| {
		state = if (given.form and given.at.len() != 1) formless(given) else loose(given)
		if state.depth >= max_depth {
			Ok(Uncounted(enter(state, "{\"type\":\"array\"}", NoItem)))
		} else {
			Ok(Uncounted(enter(state, "{\"type\":\"array\",\"items\":", Item)))
		}
	}

	parse_list_next : Schema, State -> Try([Item(State), Done(State)], Problem)
	parse_list_next = |_, state|
		match state.at.last() {
			Ok(Item) => Ok(Item(state))
			_ => Ok(Done(leave(state, "")))
		}

	parse_list_after_item : Schema, State -> Try([Continue(State), Done(State)], Problem)
	parse_list_after_item = |_, state| Ok(Done(leave(state, "}")))

	## A tuple (and a tag's payloads, past one): an array of so many, each its own schema.
	parse_tuple_start : Schema, State, U64 -> Try(State, Problem)
	parse_tuple_start = |_, state, _| Ok(emit(formless(state), "{\"type\":\"array\",\"prefixItems\":["))

	parse_tuple_next : Schema, State, U64, U64 -> Try(State, Problem)
	parse_tuple_next = |_, state, _, _| Ok(emit(state, ","))

	parse_tuple_end : Schema, State, U64 -> Try(State, Problem)
	parse_tuple_end = |_, state, len| Ok(emit(state, "],\"minItems\":${len.to_str()},\"maxItems\":${len.to_str()}}"))

	## A record: each field, by name, in turn; every one required.
	parse_record_start : Schema, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], Problem)
	parse_record_start = |_, given| {
		state = if (given.at.is_empty()) given else formless(given)
		Ok(Uncounted({ ..state, out: state.out.concat("{\"type\":\"object\",\"properties\":{"), at: state.at.append(Fields(0)) }))
	}

	parse_record_field : Schema, Encoding.FieldName.FieldNames(_shape), State -> Try([Field({ field : Encoding.FieldName(_shape), rest : State }), TryField({ name : Str, rest : State }), TryFieldCaseless({ name : Str, rest : State }), Continue(State), Done(State)], Problem)
	parse_record_field = |_, names, state| {
		next = match state.at.last() {
			Ok(Fields(index)) => index
			_ => 0
		}
		var $index = 0
		var $required = []
		for field in Encoding.FieldName.FieldNames.iter(names) {
			if $index == next {
				comma = if (next == 0) "" else ","
				out = state.out.concat("${comma}${Json.to_str(field.name())}:")
				outermost = state.at.len() == 1
				marks = if (outermost) state.marks.append({ name: field.name(), start: out.to_utf8().len(), end: 0 }) else state.marks
				return Ok(Field({ field: field, rest: { ..state, out, at: state.at.drop_last(1).append(Fields(next + 1)), field: if (outermost) field.name() else state.field, marks } }))
			}
			# A form's yes-or-no and lists, right in its record, may be left out.
			if !(state.form and state.at.len() == 1 and state.loose.contains(field.name())) {
				$required = $required.append(Json.to_str(field.name()))
			}
			$index = $index + 1
		}
		Ok(Done({ ..state, out: state.out.concat("},\"required\":[${Str.join_with($required, ",")}]}"), at: state.at.drop_last(1) }))
	}

	## After a field's schema: in the outermost record, where it ends.
	parse_record_after_field : Schema, State -> Try([Continue(State), Done(State)], Problem)
	parse_record_after_field = |_, state|
		match state.marks.last() {
			Ok(mark) if state.at.len() == 1 => Ok(Continue({ ..state, marks: state.marks.drop_last(1).append({ ..mark, end: state.out.to_utf8().len() }) }))
			_ => Ok(Continue(state))
		}

	skip_record_field : Schema, State -> Try(State, Problem)
	skip_record_field = |_, state| Ok(state)

	## A dict: an object, the schema of its one value for each of its keys.
	parse_dict_start : Schema, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], Problem)
	parse_dict_start = |_, given| {
		state = formless(given)
		if state.depth >= max_depth {
			Ok(Uncounted(enter(state, "{\"type\":\"object\"}", NoItem)))
		} else {
			Ok(Uncounted(enter(state, "{\"type\":\"object\",\"additionalProperties\":", Entry)))
		}
	}

	parse_dict_next : Schema, State -> Try([Entry(State), Done(State)], Problem)
	parse_dict_next = |_, state|
		match state.at.last() {
			Ok(Entry) => Ok(Entry(state))
			_ => Ok(Done(leave(state, "")))
		}

	parse_dict_after_key : Schema, State -> Try(State, Problem)
	parse_dict_after_key = |_, state| Ok(state)

	parse_dict_after_entry : Schema, State -> Try([Continue(State), Done(State)], Problem)
	parse_dict_after_entry = |_, state| Ok(Done(leave(state, "}")))

	## A dict's key: JSON's are strings, whatever they are in Roc, so they write nothing.
	parse_key_str : Schema, State -> Try({ value : Str, rest : State }, Problem)
	parse_key_str = |_, state| Ok({ value: "", rest: state })

	parse_key_bool : Schema, State -> Try({ value : Bool, rest : State }, Problem)
	parse_key_bool = |_, state| Ok({ value: False, rest: state })

	parse_key_u8 : Schema, State -> Try({ value : U8, rest : State }, Problem)
	parse_key_u8 = |_, state| Ok({ value: 0, rest: state })

	parse_key_i8 : Schema, State -> Try({ value : I8, rest : State }, Problem)
	parse_key_i8 = |_, state| Ok({ value: 0, rest: state })

	parse_key_u16 : Schema, State -> Try({ value : U16, rest : State }, Problem)
	parse_key_u16 = |_, state| Ok({ value: 0, rest: state })

	parse_key_i16 : Schema, State -> Try({ value : I16, rest : State }, Problem)
	parse_key_i16 = |_, state| Ok({ value: 0, rest: state })

	parse_key_u32 : Schema, State -> Try({ value : U32, rest : State }, Problem)
	parse_key_u32 = |_, state| Ok({ value: 0, rest: state })

	parse_key_i32 : Schema, State -> Try({ value : I32, rest : State }, Problem)
	parse_key_i32 = |_, state| Ok({ value: 0, rest: state })

	parse_key_u64 : Schema, State -> Try({ value : U64, rest : State }, Problem)
	parse_key_u64 = |_, state| Ok({ value: 0, rest: state })

	parse_key_i64 : Schema, State -> Try({ value : I64, rest : State }, Problem)
	parse_key_i64 = |_, state| Ok({ value: 0, rest: state })

	parse_key_u128 : Schema, State -> Try({ value : U128, rest : State }, Problem)
	parse_key_u128 = |_, state| Ok({ value: 0, rest: state })

	parse_key_i128 : Schema, State -> Try({ value : I128, rest : State }, Problem)
	parse_key_i128 = |_, state| Ok({ value: 0, rest: state })

	parse_key_dec : Schema, State -> Try({ value : Dec, rest : State }, Problem)
	parse_key_dec = |_, state| Ok({ value: 0, rest: state })

	parse_key_f32 : Schema, State -> Try({ value : F32, rest : State }, Problem)
	parse_key_f32 = |_, state| Ok({ value: 0, rest: state })

	parse_key_f64 : Schema, State -> Try({ value : F64, rest : State }, Problem)
	parse_key_f64 = |_, state| Ok({ value: 0, rest: state })

	## A tag union: each name in `tags` tried as one of its tags; those it has, kept, a payload's
	## schema written as JSON has it (one bare, more an array). Deeper than `max_depth`, only the
	## tags with no payload: a tree ends at its leaves.
	parse_tag_union : Schema, Encoding.ParseTagUnionSpec(a, Schema, State, Problem), State -> Try({ value : a, rest : State }, Problem)
	parse_tag_union = |format, spec, state| {
		var $bare = []
		var $shaped = []
		var $found = Err(NoTags)
		for name in state.tags {
			key = Json.to_str(name)
			tried = Encoding.ParseTagUnionSpec.parse(
				spec,
				{
					tag: name,
					encoding: format,
					state: { ..state, out: "", depth: state.depth + 1 },
					start_payloads: |payload, count|
						if count == 0 {
							Ok(payload)
						} else if state.depth >= max_depth {
							Err(TooDeep)
						} else if count == 1 {
							Ok(emit(payload, "{\"type\":\"object\",\"properties\":{${key}:"))
						} else {
							Ok(emit(payload, "{\"type\":\"object\",\"properties\":{${key}:{\"type\":\"array\",\"prefixItems\":["))
						},
					next_payload: |payload, _, _| Ok(emit(payload, ",")),
					finish_payloads: |payload, count|
						if count == 0 {
							Ok(payload)
						} else if count == 1 {
							Ok(emit(payload, "},\"required\":[${key}],\"additionalProperties\":false}"))
						} else {
							Ok(emit(payload, "],\"minItems\":${count.to_str()},\"maxItems\":${count.to_str()}}},\"required\":[${key}],\"additionalProperties\":false}"))
						},
					missing: NotThisTag,
				},
			)
			match tried {
				Ok(done) => {
					if done.rest.out.is_empty() {
						$bare = $bare.append(name)
					} else {
						$shaped = $shaped.append(done.rest.out)
					}
					$found = Ok(done.value)
				}
				Err(_) => {}
			}
		}
		match $found {
			Ok(value) => Ok({ value: value, rest: emit(if ($shaped.is_empty()) state else formless(state), union_schema($bare, $shaped)) })
			Err(problem) => if (state.depth >= max_depth) Err(TooDeep) else Err(problem)
		}
	}
}

shout : Endpoint({}, { word : Str }, { shouted : Str, length : U64 })
shout = Endpoint.local("POST", "/shout", |_, _, said| Ok({ shouted: said.word.with_ascii_uppercased(), length: said.word.count_utf8_bytes() }))

expect OpenApi.body(shout, []) == "{\"type\":\"object\",\"properties\":{\"word\":{\"type\":\"string\"}},\"required\":[\"word\"]}"
expect OpenApi.answer(shout, []) == "\"application/json\":{\"schema\":{\"type\":\"object\",\"properties\":{\"length\":{\"type\":\"integer\",\"minimum\":0},\"shouted\":{\"type\":\"string\"}},\"required\":[\"length\",\"shouted\"]}}"

## Lists, nested records, tuples, dicts, numbers.
shelf : Endpoint({}, { books : List({ title : Str, pages : U16 }), at : (F64, F64), counts : Dict(Str, I64) }, {})
shelf = Endpoint.local("PUT", "/shelf", |_, _, _| Ok({}))

expect OpenApi.body(shelf, []) == "{\"type\":\"object\",\"properties\":{\"at\":{\"type\":\"array\",\"prefixItems\":[{\"type\":\"number\",\"format\":\"double\"},{\"type\":\"number\",\"format\":\"double\"}],\"minItems\":2,\"maxItems\":2},\"books\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"pages\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":65535},\"title\":{\"type\":\"string\"}},\"required\":[\"pages\",\"title\"]}},\"counts\":{\"type\":\"object\",\"additionalProperties\":{\"type\":\"integer\",\"format\":\"int64\"}}},\"required\":[\"at\",\"books\",\"counts\"]}"

## A tag union: each name rocx found in the code tried; the union's kept, the rest not.
paint : Endpoint({}, { colour : [Red, Green, Rgb(U8, U8, U8), Named(Str)] }, [Painted, Refused(Str)])
paint = Endpoint.local("POST", "/paint", |_, _, _| Ok(Painted))

expect OpenApi.body(paint, ["Blue", "Green", "Named", "Red", "Rgb", "Ok"]) == "{\"type\":\"object\",\"properties\":{\"colour\":{\"oneOf\":[{\"type\":\"string\",\"enum\":[\"Green\",\"Red\"]},{\"type\":\"object\",\"properties\":{\"Named\":{\"type\":\"string\"}},\"required\":[\"Named\"],\"additionalProperties\":false},{\"type\":\"object\",\"properties\":{\"Rgb\":{\"type\":\"array\",\"prefixItems\":[{\"type\":\"integer\",\"minimum\":0,\"maximum\":255},{\"type\":\"integer\",\"minimum\":0,\"maximum\":255},{\"type\":\"integer\",\"minimum\":0,\"maximum\":255}],\"minItems\":3,\"maxItems\":3}},\"required\":[\"Rgb\"],\"additionalProperties\":false}]}},\"required\":[\"colour\"]}"
expect OpenApi.answer(paint, ["Painted", "Refused"]) == "\"application/json\":{\"schema\":{\"oneOf\":[{\"type\":\"string\",\"enum\":[\"Painted\"]},{\"type\":\"object\",\"properties\":{\"Refused\":{\"type\":\"string\"}},\"required\":[\"Refused\"],\"additionalProperties\":false}]}}"
expect OpenApi.body(paint, ["Blue"]) == "{\"description\":\"A tag union none of whose tags rocx found in the app's code\"}"

## The schemas above are of what Json writes: a tag with no payload a string, one payload bare,
## more an array.
expect {
	colours : List([Red, Named(Str), Rgb(U8, U8, U8)])
	colours = [Red, Named("teal"), Rgb(1, 2, 3)]
	Json.to_str(colours) == "[\"Red\",{\"Named\":\"teal\"},{\"Rgb\":[1,2,3]}]"
}

## A nominal type with the parser Json has for it (`parser_for : _`) has its schema; one that
## holds itself, as deep as `max_depth`.
Tree := [Leaf(U64), Node(Tree, Tree)].{
	parser_for : _
}

Person := { name : Str, friends : List(Person) }.{
	parser_for : _
}

grow : Endpoint({}, { tree : Tree, person : Person }, {})
grow = Endpoint.local("POST", "/grow", |_, _, _| Ok({}))

expect {
	got = OpenApi.body(grow, ["Leaf", "Node"])
	got.starts_with("{\"type\":\"object\",\"properties\":{\"person\":{\"type\":\"object\",\"properties\":{\"friends\":{\"type\":\"array\",\"items\":{\"type\":\"object\"")
		and got.contains("{\"friends\":{\"type\":\"array\"},\"name\":{\"type\":\"string\"}}")
		and got.contains("\"tree\":{\"oneOf\":[{\"type\":\"object\",\"properties\":{\"Leaf\":")
}

## An endpoint's events: each one's data JSON, then `end`.
ticks : Endpoint({}, {}, Events({ at : U64 }))
ticks = Endpoint.local("GET", "/ticks", |_, _, _| Ok(Events.none({})))

expect OpenApi.events(ticks, []) == "\"text/event-stream\":{\"itemSchema\":{\"oneOf\":[{\"type\":\"object\",\"required\":[\"data\"],\"properties\":{\"data\":{\"type\":\"string\",\"contentMediaType\":\"application/json\",\"contentSchema\":{\"type\":\"object\",\"properties\":{\"at\":{\"type\":\"integer\",\"minimum\":0}},\"required\":[\"at\"]}}}},{\"type\":\"object\",\"required\":[\"event\"],\"properties\":{\"event\":{\"const\":\"end\"}}}]}}"

## What a form may send, beside JSON: the same record, a yes-or-no and a list not required.
signup : Endpoint({}, { name : Str, age : U8, plan : [Free, Paid], news : Bool, tags : List(Str) }, {})
signup = Endpoint.local("POST", "/signup", |_, _, _| Ok({}))

expect {
	form = "{\"type\":\"object\",\"properties\":{\"age\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":255},\"name\":{\"type\":\"string\"},\"news\":{\"type\":\"boolean\"},\"plan\":{\"type\":\"string\",\"enum\":[\"Free\",\"Paid\"]},\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},\"required\":[\"age\",\"name\",\"plan\"]}"
	json = "{\"type\":\"object\",\"properties\":{\"age\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":255},\"name\":{\"type\":\"string\"},\"news\":{\"type\":\"boolean\"},\"plan\":{\"type\":\"string\",\"enum\":[\"Free\",\"Paid\"]},\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},\"required\":[\"age\",\"name\",\"news\",\"plan\",\"tags\"]}"
	OpenApi.sent(signup, ["Free", "Paid"]) == "\"application/json\":{\"schema\":${json}},\"application/x-www-form-urlencoded\":{\"schema\":${form}},\"multipart/form-data\":{\"schema\":${form}}"
}

## A shape a form doesn't have (a record in a field, a tuple, a dict, a tag with a payload): JSON alone.
expect OpenApi.sent(shelf, []).starts_with("\"application/json\":") and !OpenApi.sent(shelf, []).contains("x-www-form-urlencoded")
expect !OpenApi.sent(paint, ["Red", "Rgb"]).contains("x-www-form-urlencoded")
expect OpenApi.sent(shout, []).contains("\"application/x-www-form-urlencoded\":{\"schema\":{\"type\":\"object\",\"properties\":{\"word\":{\"type\":\"string\"}},\"required\":[\"word\"]}}")

## A path's params of their types (D-092): each field of the params' record, with its schema.
counting : { to : U64, kind : [Odd, Even], name : Str } -> Endpoint({}, {}, {})
counting = |_| Endpoint.local("GET", "/count", |_, _, _| Ok({}))

expect {
	got = OpenApi.typed_path("/count/{to}/{kind}/{name}", counting, ["Even", "Odd"], [])
	got == "\"/count/{to}/{kind}/{name}\":{\"parameters\":[{\"name\":\"kind\",\"in\":\"path\",\"required\":true,\"schema\":{\"type\":\"string\",\"enum\":[\"Even\",\"Odd\"]}},{\"name\":\"name\",\"in\":\"path\",\"required\":true,\"schema\":{\"type\":\"string\"}},{\"name\":\"to\",\"in\":\"path\",\"required\":true,\"schema\":{\"type\":\"integer\",\"minimum\":0}}],}"
}

## A document: its paths, their params, their methods.
expect {
	shouting = OpenApi.operation("post", "Shouted.", "What it is sent, \"shouted\".", OpenApi.sent(shout, []), [OpenApi.answer(shout, [])])
	got = OpenApi.document("app", [OpenApi.path("/shout/{word}", ["word"], [shouting])])
	got.starts_with("{\"openapi\":\"3.2.0\",\"info\":{\"title\":\"app\",\"version\":\"0\"},\"paths\":{\"/shout/{word}\":{\"parameters\":[{\"name\":\"word\",\"in\":\"path\",\"required\":true,\"schema\":{\"type\":\"string\"}}],\"post\":{\"summary\":\"Shouted.\",\"description\":\"What it is sent, \\\"shouted\\\".\",\"requestBody\":{\"required\":true,")
}

## The document and its page: only what `serving` says, and only by GET. (A response can hold a
## page or a stream, which can't be compared: these compare its status and its text.)
asked : Str, Str, OpenApi.Serving -> Try((U16, Str), [NotHere])
asked = |method, path, serving|
	OpenApi.respond(Server.from_http(method, path, "", []), serving, "{}").map_ok(
		|served|
			match served.body {
				Text(text) => (served.status, text)
				_ => (served.status, "")
			},
	)

expect asked("GET", "/openapi.json", Off) == Err(NotHere)
expect asked("GET", "/openapi.json", Document) == Ok((200, "{}"))
expect asked("GET", "/openapi.html", Document) == Err(NotHere)
expect asked("GET", "/openapi.json", Page(Scalar)) == Ok((200, "{}"))
expect asked("GET", "/about", Page(Swagger)) == Err(NotHere)
expect asked("POST", "/openapi.json", Document).map_ok(|(status, _)| status) == Ok(405)

expect {
	html = asked("GET", "/openapi.html", Page(Swagger)).map_ok(|(_, text)| text) ?? ""
	html.contains("swagger-ui-bundle.js\" integrity=\"sha384-") and html.contains("validatorUrl: null") and html.contains("url: \"openapi.json\"")
}

expect {
	html = asked("GET", "/openapi.html", Page(Scalar)).map_ok(|(_, text)| text) ?? ""
	html.contains("@scalar/api-reference@1.82.1/dist/browser/standalone.js\" integrity=\"sha384-") and html.contains("telemetry: false")
}
