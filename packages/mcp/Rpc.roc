import JsonValue

## JSON-RPC 2.0, as MCP sends it over HTTP: one message a POST. A client sends a request (it has an
## id, and is answered with a result or an error for that id) or a notification (no id, no answer).
## `read` reads one; `result` and `error` write the answer.
Rpc := [].{

	## A message a client sent: a request, a notification, or a response to a request of the
	## server's (MCP over HTTP sends none, so a response is only acknowledged).
	Message : [Request({ id : JsonValue, method : Str, params : JsonValue }), Notification({ method : Str, params : JsonValue }), Response]

	## An error, as JSON-RPC sends one: its code, what went wrong, and what more there is to say
	## (`data`), if anything.
	Error : { code : I64, message : Str, data : Try(JsonValue, [NoData]) }

	## Why a message couldn't be read: its error, and its id, if that could be read.
	Unread : { id : Try(JsonValue, [NoId]), error : Error }

	## The message `text` holds. Its `params` are an object (`{}` when it has none); its id a string
	## or a whole number, never `null`. A batch (an array of messages) isn't read: MCP sends one
	## message at a time.
	read : Str -> Try(Message, Unread)
	read = |text| {
		unread = |id, code, message| Err({ id: id, error: { code: code, message: message, data: Err(NoData) } })
		body : JsonValue
		body =
			match JsonValue.parse(text) {
				Ok(Object(fields)) => Object(fields)
				Ok(Array(_)) => return unread(Err(NoId), Rpc.invalid_request, "Send one JSON-RPC message, not a batch")
				Ok(_) => return unread(Err(NoId), Rpc.invalid_request, "Send a JSON-RPC message: an object")
				Err(InvalidJson(why)) => return unread(Err(NoId), Rpc.parse_error, "Not JSON: ${why}")
			}
		id : Try(JsonValue, [NoId])
		id =
			match body.get("id") {
				Ok(String(given)) => Ok(String(given))
				Ok(Number(given)) if is_whole(given) => Ok(Number(given))
				Ok(_) => return unread(Err(NoId), Rpc.invalid_request, "A request's id is a string or a whole number")
				Err(Missing) => Err(NoId)
			}
		if body.get("jsonrpc") != Ok(String("2.0")) {
			return unread(id, Rpc.invalid_request, "Not JSON-RPC 2.0: `\"jsonrpc\": \"2.0\"` is missing")
		}
		method =
			match body.get("method") {
				Ok(String(given)) => given
				Ok(_) => return unread(id, Rpc.invalid_request, "A method is a string")
				Err(Missing) =>
					if id.is_ok() and (body.get("result").is_ok() or body.get("error").is_ok()) {
						return Ok(Response)
					} else {
						return unread(id, Rpc.invalid_request, "A request names its method")
					}
			}
		params : JsonValue
		params =
			match body.get("params") {
				Ok(Object(fields)) => Object(fields)
				Err(Missing) => Object([])
				Ok(_) => return unread(id, Rpc.invalid_params, "A request's params are an object")
			}
		match id {
			Ok(given) => Ok(Request({ id: given, method: method, params: params }))
			Err(NoId) => Ok(Notification({ method: method, params: params }))
		}
	}

	## The answer to the request `id`: its result.
	result : JsonValue, JsonValue -> Str
	result = |id, answer| JsonValue.to_str(Object([("jsonrpc", String("2.0")), ("id", id), ("result", answer)]))

	## The answer to the request `id` (or to one whose id couldn't be read): an error.
	error : Try(JsonValue, [NoId]), Error -> Str
	error = |id, failed| {
		data =
			match failed.data {
				Ok(given) => [("data", given)]
				Err(NoData) => []
			}
		written = Object([("code", JsonValue.int(failed.code)), ("message", String(failed.message))].concat(data))
		identified =
			match id {
				Ok(given) => [("id", given)]
				Err(NoId) => []
			}
		JsonValue.to_str(Object([("jsonrpc", String("2.0"))].concat(identified).append(("error", written))))
	}

	## A notification: its method and params.
	notification : Str, JsonValue -> Str
	notification = |method, params| JsonValue.to_str(Object([("jsonrpc", String("2.0")), ("method", String(method)), ("params", params)]))

	## An error with nothing more to say.
	fail : I64, Str -> Error
	fail = |code, message| { code: code, message: message, data: Err(NoData) }

	## The body isn't JSON.
	parse_error : I64
	parse_error = -32700

	## The body is JSON, but not a JSON-RPC message.
	invalid_request : I64
	invalid_request = -32600

	## No such method.
	method_not_found : I64
	method_not_found = -32601

	## The method's params aren't what it takes: an unknown tool, prompt or resource, a bad cursor.
	invalid_params : I64
	invalid_params = -32602

	## Something went wrong inside the server.
	internal_error : I64
	internal_error = -32603

	## MCP: a header (`Mcp-Method`, `Mcp-Name`, `MCP-Protocol-Version`) that is missing, or says
	## something else than the body.
	header_mismatch : I64
	header_mismatch = -32020

	## MCP: the request needs a capability the client didn't say it has.
	missing_capability : I64
	missing_capability = -32021

	## MCP: a protocol version the server doesn't speak.
	unsupported_version : I64
	unsupported_version = -32022
}

## Whether a number's text is a whole number: digits, with a `-` perhaps; no fraction, no exponent.
is_whole : Str -> Bool
is_whole = |written| written.to_utf8().all(|byte| (byte >= '0' and byte <= '9') or byte == '-')

expect
	Rpc.read("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"cursor\":\"2\"}}")
		== Ok(Request({ id: Number("1"), method: "tools/list", params: Object([("cursor", String("2"))]) }))

expect Rpc.read("{\"jsonrpc\":\"2.0\",\"id\":\"a-1\",\"method\":\"ping\"}") == Ok(Request({ id: String("a-1"), method: "ping", params: Object([]) }))
expect Rpc.read("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}") == Ok(Notification({ method: "notifications/initialized", params: Object([]) }))
expect Rpc.read("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}") == Ok(Response)

## What isn't one message: not JSON, a batch, no version, a null id, a fractional id, no method,
## params that aren't an object.
code_of : Str -> (Try(JsonValue, [NoId]), I64)
code_of = |text|
	match Rpc.read(text) {
		Ok(_) => (Err(NoId), 0)
		Err(unread) => (unread.id, unread.error.code)
	}

expect code_of("{\"jsonrpc\":") == (Err(NoId), Rpc.parse_error)
expect code_of("[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]") == (Err(NoId), Rpc.invalid_request)
expect code_of("{\"id\":1,\"method\":\"ping\"}") == (Ok(Number("1")), Rpc.invalid_request)
expect code_of("{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"ping\"}") == (Err(NoId), Rpc.invalid_request)
expect code_of("{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"ping\"}") == (Err(NoId), Rpc.invalid_request)
expect code_of("{\"jsonrpc\":\"2.0\",\"id\":2}") == (Ok(Number("2")), Rpc.invalid_request)
expect code_of("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\",\"params\":[1]}") == (Ok(Number("3")), Rpc.invalid_params)

## The answers, as the spec's examples write them.
expect Rpc.result(String("123"), Object([])) == "{\"jsonrpc\":\"2.0\",\"id\":\"123\",\"result\":{}}"
expect
	Rpc.error(Ok(Number("1")), { code: Rpc.unsupported_version, message: "Unsupported protocol version", data: Ok(Object([("supported", Array([String("2026-07-28")])), ("requested", String("1900-01-01"))])) })
		== "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"supported\":[\"2026-07-28\"],\"requested\":\"1900-01-01\"}}}"
expect Rpc.error(Err(NoId), Rpc.fail(Rpc.parse_error, "Not JSON")) == "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32700,\"message\":\"Not JSON\"}}"
expect Rpc.notification("notifications/progress", Object([("progress", Number("1"))])) == "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":1}}"
