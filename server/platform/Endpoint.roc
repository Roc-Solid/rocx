import Server
import Events
import Call
import Host

## An HTTP endpoint: a method at a path, which a route's `+server.roc` defines (`get!`, `post!`,
## `put!`, `patch!`, `delete!`; `events!`, a stream of events, asked for with GET). Anyone may call
## it over HTTP. The app calls it through what rocx writes from the routes (`Generated/Api.roc`), as
## a function of its params. A component reads a GET endpoint as a plain value (`get!`, or `read!`
## for its refusal too): while the server renders the page, the server answers it, and the page
## carries the answer to the browser. It sends any endpoint from a handler (`send!`, with the
## platform's `Call.fetch!`), or listens to one's events (`listen!`). On the server, `run!` runs
## one there and then.
##
## A handler is given the request, the context its middleware handed on, its path's params and its
## body, and answers `Ok(result)`, sent as JSON with the status 200, or a `Refusal`: a status and
## why, or an answer of its own (`Answer`: a redirect that sets a cookie).
Endpoint(context, arg, result) :: { method : Str, url : Str, run : Server.Request, context, arg => Try(result, Endpoint.Refusal) }.{

	## What a handler may answer instead of its result: a status, and why; or exactly this answer.
	Refusal : [BadRequest(Str), Unauthorized, Forbidden, NotFound, Conflict(Str), Status(U16, Str), Answer(Server.Response)]

	## The server's: what its handler does.
	local : Str, Str, (Server.Request, context, arg => Try(result, Refusal)) -> Endpoint(context, arg, result)
	local = |method, url, handler| { method: method, url: url, run: handler }

	## The browser's copy: its method and URL, and nothing it does.
	remote : Str, Str -> Endpoint(context, arg, result)
	remote = |method, url| { method: method, url: url, run: |_, _, _| crash "${method} ${url} runs on the server: send it with Endpoint.send!" }

	## A GET endpoint's answer, as a plain value, for a component or a computation
	## (`create_memo!(|| Endpoint.get!(Api.get_profile({ id })))`): one definition of a page's data,
	## the endpoint's, read where the page renders.
	##
	## - While the server renders the page, the server answers it in-process. The GET goes through the
	##   endpoint's route, as the browser's would, with `accept: application/json` and the page's
	##   cookies and headers, behind the route's middleware. The answer is noted for the page.
	## - Hydrating, the browser reads that answer from the page and asks nothing.
	## - Asked again later (`refresh!`), the browser GETs the endpoint's URL.
	##
	## An answer that isn't 200 fails the computation: the nearest <Errored> shows its status and
	## why. A redirect, while the page renders (a signed-out visitor sent to sign in), is the page's
	## answer instead. `with_query` adds a query.
	get! : Endpoint(context, {}, result) => result
		where [result.Json.Parseable([InvalidJson(Str)])]
	get! = |endpoint|
		match Endpoint.read!(endpoint) {
			Ok(result) => result
			Err(problem) => {
				Host.fail!("${endpoint.method} ${endpoint.url}: ${Server.explain(problem)}")
				crash "unreachable: fail! doesn't return"
			}
		}

	## A GET endpoint's answer, as `get!` reads it, with a refusal as a value: `Err(Refused(404, why))`,
	## for a computation that shows it itself.
	read! : Endpoint(context, {}, result) => Try(result, Server.Problem)
		where [result.Json.Parseable([InvalidJson(Str)])]
	read! = |endpoint|
		if endpoint.method == "GET" {
			answered = Call.fetch!({ method: "GET", url: endpoint.url, headers: [{ name: "accept", value: "application/json" }], body: "" })
			Endpoint.answer(endpoint, Ok({ status: answered.status, headers: [], body: answered.body }))
		} else {
			Host.fail!("${endpoint.method} ${endpoint.url} isn't read: send it with Endpoint.send!, from a handler")
			crash "unreachable: fail! doesn't return"
		}

	## The endpoint, asked with a query (`weeks=1`, as a URL writes it after the `?`): the page's own,
	## to read the data for what it shows (`Endpoint.with_query(Api.get_board({}),
	## Router.location!({}).query)`). Its handler reads it as `request.query`. It replaces a query the
	## URL had; an empty one leaves the endpoint as it was.
	with_query : Endpoint(context, arg, result), Str -> Endpoint(context, arg, result)
	with_query = |endpoint, query|
		if query.is_empty() {
			endpoint
		} else {
			bare =
				match endpoint.url.split_first("?") {
					Ok({ before, .. }) => before
					Err(_) => endpoint.url
				}
			{ ..endpoint, url: "${bare}?${query}" }
		}

	## From a component, in the browser: its answer, sent with the platform's `fetch!`, and read as
	## a plain value (`Endpoint.send!(Api.post_api_shout({}), { word }, Call.fetch!)`).
	send! : Endpoint(context, arg, result), arg, ({ method : Str, url : Str, headers : List({ name : Str, value : Str }), body : Str } => { status : U16, body : Str }) => Try(result, Server.Problem)
		where [arg.Json.Encodable(e), result.Json.Parseable([InvalidJson(Str)])]
	send! = |endpoint, arg, fetch!| {
		answered = fetch!(Endpoint.to_request(endpoint, arg))
		Endpoint.answer(endpoint, Ok({ status: answered.status, headers: [], body: answered.body }))
	}

	## From a component, in the browser: listens to an endpoint's events with the platform's
	## `listen!` (`Endpoint.listen!(Api.events_api_count_to({ to }), Call.listen!, heard!)`):
	## `heard!` is given each event as it comes, typed, then `Ended`, or what went wrong.
	listen! : Endpoint(context, {}, Events(event)), (Str, ([Event(Str), Ended, Refused(U16, Str), Failed(Str)] => {}) => {}), ([Event(event), Ended, Failed(Server.Problem)] => {}) => {}
		where [event.Json.Parseable([InvalidJson(Str)])]
	listen! = |endpoint, listen_with!, heard!|
		listen_with!(
			endpoint.url,
			|heard|
				match heard {
					Event(data) =>
						match Json.parse(data) {
							Ok(event) => heard!(Event(event))
							Err(InvalidJson(why)) => heard!(Failed(BadAnswer(why)))
						}
					Ended => heard!(Ended)
					Refused(status, why) => heard!(Failed(Refused(status, why)))
					Failed(why) => heard!(Failed(HttpErr(why)))
				},
		)

	## Its URL: where a form posts to it, say.
	url_of : Endpoint(context, arg, result) -> Str
	url_of = |endpoint| endpoint.url

	## On the server: runs it there and then, with the request being answered and the context its
	## handler is given (its middleware doesn't run: the caller ran its own); a refusal as the
	## browser would see it.
	run! : Endpoint(context, arg, result), Server.Request, context, arg => Try(result, Server.Problem)
	run! = |endpoint, request, context, arg| {
		handler = endpoint.run
		match handler(request, context, arg) {
			Ok(result) => Ok(result)
			Err(refusal) => {
				(status, why) = Endpoint.refused(refusal)
				Err(Refused(status, why))
			}
		}
	}

	## The request the browser sends for it: `arg` as JSON in its body (with POST, PUT and PATCH;
	## the others have none).
	to_request : Endpoint(context, arg, result), arg -> { method : Str, url : Str, headers : List({ name : Str, value : Str }), body : Str }
		where [arg.Json.Encodable(e)]
	to_request = |endpoint, arg|
		if has_body(endpoint.method) {
			body =
				match Json.to_str_try(arg) {
					Ok(json) => json
					Err(_) => crash "${endpoint.method} ${endpoint.url}: its body ${Server.unwritable}"
				}
			{ method: endpoint.method, url: endpoint.url, headers: [{ name: "content-type", value: "application/json" }], body }
		} else {
			{ method: endpoint.method, url: endpoint.url, headers: [{ name: "accept", value: "application/json" }], body: "" }
		}

	## Its answer, from the response to that request.
	answer : Endpoint(context, arg, result), Try({ status : U16, headers : List({ name : Str, value : Str }), body : Str }, [HttpErr(Str)]) -> Try(result, Server.Problem)
		where [result.Json.Parseable([InvalidJson(Str)])]
	answer = |_, response|
		match response {
			Ok(answered) =>
				if answered.status == 200 {
					match Json.parse(answered.body) {
						Ok(result) => Ok(result)
						Err(InvalidJson(why)) => Err(BadAnswer(why))
					}
				} else {
					Err(Refused(answered.status, answered.body))
				}
			Err(HttpErr(why)) => Err(HttpErr(why))
		}

	## On the server: the answer to a request to it, given the context its middleware handed on. Its
	## arg is the body, read when it says it is JSON (`application/json`, or a type ending `+json`)
	## or a form (`application/x-www-form-urlencoded`: its fields, as a browser posts them, a record
	## of strings). Any other body (an upload: `application/octet-stream`, `video/mp4`, or no type at
	## all) isn't read: the arg is `{}`, and the handler reads `request.body`, the bytes as they came.
	## No body is `{}` too. Its result is sent as JSON, a refusal as its status and why, or as the
	## answer it is. A body it doesn't read, for a handler that wants an arg, is 415.
	##
	## A form a browser posted without the runtime (a plain `<form method="post">`: a form's body,
	## `accept: text/html`) gets neither its result nor its refusal, which would be a page of JSON or
	## of text: it goes back to the page it came from, which reads them with what was typed
	## (`Server.flash_back`, `Server.flash!`, `use_submission!`). A form the runtime sent
	## (`x-rocx-submission`) gets them, and a redirect of its handler's own comes back as 200 with
	## `x-rocx-redirect` (fetch would follow it before anyone could read it), for the runtime to go
	## there. An answer of its own is otherwise sent as it is.
	respond! : Endpoint(context, arg, result), Server.Request, context => Server.Response
		where [arg.Json.Parseable([InvalidJson(Str)]), result.Json.Encodable(e)]
	respond! = |endpoint, request, context| {
		read = input_of(request)
		input =
			match read {
				Read(json) => json
				Unread(_) => "{}"
			}
		posted = posted_by(request)
		reply = |status, body|
			match posted {
				PlainForm => Server.flash_back(request, { url: endpoint.url, input: Server.text_of(request), status, body })
				_ => if (status == 200) Server.response(200, [{ name: "content-type", value: "application/json" }], body) else text(status, body)
			}
		match Json.parse(input) {
			Ok(arg) => {
				handler = endpoint.run
				match handler(request, context, arg) {
					Ok(result) =>
						match Json.to_str_try(result) {
							Ok(json) => reply(200, json)
							Err(_) => reply(500, "${endpoint.method} ${request.path}'s answer: ${Server.unwritable}")
						}
					Err(Answer(own)) =>
						match posted {
							Runtime => redirected(own)
							_ => own
						}
					Err(refusal) => {
						(status, why) = Endpoint.refused(refusal)
						reply(status, why)
					}
				}
			}
			Err(InvalidJson(why)) =>
				match read {
					Read(_) => reply(400, "${endpoint.method} ${request.path} can't read its body: ${why}")
					Unread(type) => text(415, "${endpoint.method} ${request.path} reads JSON (application/json) or a form, not ${if (type.is_empty()) "a body with no content-type" else type}")
				}
		}
	}

	## On the server: the answer to a request for an endpoint's events (`events!`, asked with
	## `accept: text/event-stream`), given the context its middleware handed on: a stream, each event
	## sent as JSON as it comes; a refusal as its status and why, or as the answer it is.
	stream! : Endpoint(context, {}, Events(event)), Server.Request, context => Server.Response
		where [event.Json.Encodable(e)]
	stream! = |endpoint, request, context| {
		handler = endpoint.run
		match handler(request, context, {}) {
			Ok(events) =>
				Server.events(
					Events.map(
						events,
						|event|
							match Json.to_str_try(event) {
								Ok(json) => json
								Err(_) => crash "${endpoint.url}: an event ${Server.unwritable}"
							},
					),
				)
			Err(Answer(own)) => own
			Err(refusal) => {
				(status, why) = Endpoint.refused(refusal)
				text(status, why)
			}
		}
	}

	## A refusal's status, and why.
	refused : Refusal -> (U16, Str)
	refused = |refusal|
		match refusal {
			BadRequest(why) => (400, why)
			Unauthorized => (401, "Unauthorized")
			Forbidden => (403, "Forbidden")
			NotFound => (404, "Not found")
			Conflict(why) => (409, why)
			Status(status, why) => (status, why)
			Answer(own) => (own.status, Server.body_text(own))
		}

	## The answer a method that isn't there gets: 405, and the ones that are (`Allow`).
	not_allowed : Server.Request, List(Str) -> Server.Response
	not_allowed = |request, allowed|
		Server.response(
			405,
			[{ name: "allow", value: Str.join_with(allowed, ", ") }, { name: "content-type", value: "text/plain; charset=utf-8" }],
			"${request.path} takes ${Str.join_with(allowed, ", ")}, not ${request.method}",
		)
}

## What an endpoint's arg is read from, as JSON: the body, when it says it is JSON; a form's fields;
## `{}` for no body. A body of any other type isn't read (`Unread`, with its type): an upload, which
## the handler reads itself.
input_of : Server.Request -> [Read(Str), Unread(Str)]
input_of = |request| {
	type = media_type(Server.header(request, "content-type") ?? "")
	if type == "application/x-www-form-urlencoded" {
		Read(Server.form_json(Server.text_of(request)))
	} else if type == "application/json" or type.ends_with("+json") {
		body = Server.text_of(request)
		Read(if (body.trim().is_empty()) "{}" else body)
	} else if request.body.is_empty() {
		Read("{}")
	} else {
		Unread(type)
	}
}

## Who posted a request: a browser's plain form (a form's body, for a page: `accept: text/html`),
## the runtime (a form it sent: `x-rocx-submission`), or anything else (a script, `Endpoint.send!`).
posted_by : Server.Request -> [PlainForm, Runtime, Other]
posted_by = |request|
	if Server.header(request, "x-rocx-submission").is_ok() {
		Runtime
	} else if media_type(Server.header(request, "content-type") ?? "") == "application/x-www-form-urlencoded" and Server.wants_html(request) {
		PlainForm
	} else {
		Other
	}

## A redirect of a handler's own, for the runtime: 200, its `location` as `x-rocx-redirect`, the rest
## (a cookie it sets) kept. Any other answer as it is.
redirected : Server.Response -> Server.Response
redirected = |own|
	if own.status >= 300 and own.status < 400 and own.headers.any(|header| header.name.with_ascii_lowercased() == "location") {
		headers = own.headers.map(|header| if (header.name.with_ascii_lowercased() == "location") { name: "x-rocx-redirect", value: header.value } else header)
		{ status: 200, headers, body: Text("") }
	} else {
		own
	}

## A `content-type`'s type, without its parameters, in lower case: `application/json`.
media_type : Str -> Str
media_type = |given| {
	bare =
		match given.split_first(";") {
			Ok({ before, .. }) => before
			Err(_) => given
		}
	bare.trim().with_ascii_lowercased()
}

has_body : Str -> Bool
has_body = |method| method == "POST" or method == "PUT" or method == "PATCH"

text : U16, Str -> Server.Response
text = |status, body| Server.response(status, [{ name: "content-type", value: "text/plain; charset=utf-8" }], body)

shout : Endpoint({}, Str, Str)
shout = Endpoint.local("POST", "/shout", |_, _, said| if (said.is_empty()) Err(BadRequest("say something")) else Ok(said.with_ascii_uppercased()))

expect Endpoint.to_request(shout, "hi") == { method: "POST", url: "/shout", headers: [{ name: "content-type", value: "application/json" }], body: "\"hi\"" }
expect Endpoint.answer(shout, Ok({ status: 200, headers: [], body: "\"HI\"" })) == Ok("HI")
expect Endpoint.answer(shout, Ok({ status: 400, headers: [], body: "say something" })) == Err(Refused(400, "say something"))
expect Endpoint.refused(NotFound) == (404, "Not found")
expect Endpoint.url_of(Endpoint.with_query(shout, "weeks=1")) == "/shout?weeks=1"
expect Endpoint.url_of(Endpoint.with_query(Endpoint.with_query(shout, "weeks=1"), "weeks=2")) == "/shout?weeks=2"
expect Endpoint.url_of(Endpoint.with_query(shout, "")) == "/shout"
expect input_of(Server.from_http("POST", "/shout", "content-type: application/json", "\"hi\"".to_utf8())) == Read("\"hi\"")
expect input_of(Server.from_http("POST", "/shout", "Content-Type: application/merge-patch+json; charset=utf-8", "{}".to_utf8())) == Read("{}")
expect input_of(Server.from_http("POST", "/shout", "content-type: application/x-www-form-urlencoded", "said=hi".to_utf8())) == Read("{\"said\":\"hi\"}")
expect input_of(Server.from_http("POST", "/shout", "content-type: application/json", " ".to_utf8())) == Read("{}")
expect input_of(Server.from_http("PUT", "/upload", "content-type: video/mp4", [0, 0xFF, 0xD8])) == Unread("video/mp4")
expect input_of(Server.from_http("PUT", "/upload", "content-type: text/plain", "\"hi\"".to_utf8())) == Unread("text/plain")
expect input_of(Server.from_http("PUT", "/upload", "", [0xFF])) == Unread("")
expect input_of(Server.from_http("DELETE", "/upload", "content-type: video/mp4", [])) == Read("{}")
expect media_type("Application/JSON ; charset=utf-8") == "application/json"
expect posted_by(Server.from_http("POST", "/shout", "content-type: application/x-www-form-urlencoded\naccept: text/html,*/*", [])) == PlainForm
expect posted_by(Server.from_http("POST", "/shout", "content-type: application/x-www-form-urlencoded\naccept: application/json\nx-rocx-submission: 1", [])) == Runtime
expect posted_by(Server.from_http("POST", "/shout", "content-type: application/json\naccept: text/html", [])) == Other
expect posted_by(Server.from_http("POST", "/shout", "content-type: application/x-www-form-urlencoded", [])) == Other
expect redirected(Server.with_cookie(Server.redirect("/members"), "member", "Ada")).headers == [{ name: "x-rocx-redirect", value: "/members" }, { name: "set-cookie", value: "member=Ada; Path=/; HttpOnly; SameSite=Lax" }]
expect redirected(Server.redirect("/members")).status == 200
expect redirected(Server.refused(409, "taken")).status == 409
expect Endpoint.not_allowed(Server.from_host("/shout", ""), ["POST"]).headers.first() == Ok({ name: "allow", value: "POST" })
