import Server
import Events
import Call
import Channel
import FormBody
import Host

## An HTTP endpoint: a method at a path, which a route's `+server.roc` defines (`get!`, `post!`,
## `put!`, `patch!`, `delete!`; `events!`, a stream of events, asked for with GET). Anyone may call
## it over HTTP. The app calls it through what rocx writes from the routes (`Generated/Api.roc`), as
## a function of its params: its contract, the method, the URL and the types its handler's
## annotation gives, and nothing the handler does, so any module may import it (D-037). A component
## reads a GET endpoint as a plain value (`get!`, or `read!` for its refusal too): while the server
## renders the page, the server answers it, and the page carries the answer to the browser. It sends
## any endpoint from a handler (`send!`), or listens to one's events (`listen!`), through the
## platform's `Call`. On the server, a channel's messages are published to it (`publish!`), and
## `run!` runs an endpoint there and then, with its handler (`Generated/Handlers.roc`, which `bind`s
## each contract to its handler).
##
## A handler is given the request, the context its middleware handed on, its path's params and its
## body, and answers `Ok(result)`, sent as JSON with the status 200, or a `Refusal`: a status and
## why, or an answer of its own (`Answer`: a redirect that sets a cookie).
##
## Its arg is one type whoever sends it: JSON (an action, a script) is read as JSON; a form's fields
## (a plain form, or one the runtime sent) are read by the arg's type too (`FormBody`, D-038), a
## number from its text, a box left unticked `Bool.False`, the values a name has as a `List`. The
## endpoint keeps that reader (`form`), made where its arg's type is known (`remote`, `local`).
##
## A form's fields may be given ahead of time (`with_fields`, Solid Router's `action.with`): they go in the
## URL the form posts to, and its own fields after them.
Endpoint(context, arg, result) :: { method : Str, url : Str, run : Server.Request, context, arg => Try(result, Endpoint.Refusal), form : [Typed(List({ name : Str, value : Str }) -> Try(arg, Str)), Untyped], bound : Str }.{

	## What a handler may answer instead of its result: a status, and why; or exactly this answer.
	Refusal : [BadRequest(Str), Unauthorized, Forbidden, NotFound, Conflict(Str), Status(U16, Str), Answer(Server.Response)]

	## An endpoint of the app's own, with its handler, outside the routes: its method, its URL and
	## what it does (a test's, or one made for `run!` alone). Its reader of a form (`FormBody`) is
	## made here, where its arg's type is known.
	local : Str, Str, (Server.Request, context, arg => Try(result, Refusal)) -> Endpoint(context, arg, result) where [arg.FormBody.Readable]
	local = |method, url, handler| { method: method, url: url, run: handler, form: Typed(|fields| FormBody.parse(fields)), bound: "" }

	## As `local`, for a function generic in its arg that knows it as JSON alone
	## (`where [arg.Json.Parseable(…)]`, which can't be asked for with `FormBody`'s: see
	## test/compiler-bugs/two-formats-one-where): an endpoint only code sends (`run!`). A form posted
	## to it is read as a record of strings.
	local_json : Str, Str, (Server.Request, context, arg => Try(result, Refusal)) -> Endpoint(context, arg, result)
	local_json = |method, url, handler| { method: method, url: url, run: handler, form: Untyped, bound: "" }

	## A contract: its method and URL, and nothing it does; its types are the annotation's of what
	## names it (`Generated/Api.roc`'s, copied from its handler's). Its `run` captures nothing, so
	## naming an endpoint allocates nothing: a read that isn't in yet unwinds the frame that named
	## it, and what that held would never be let go of. Its reader of a form's fields (`FormBody`,
	## D-038) is made here, where Api's annotation gives the arg its type, in both copies: the
	## server's router reads a form posted to it with it (`bind` keeps it), and the browser what a
	## form sent (`Router.use_submission!`).
	remote : Str, Str -> Endpoint(context, arg, result) where [arg.FormBody.Readable]
	remote = |method, url| { method: method, url: url, run: |_, _, _| crash "Endpoint.run! was given a contract (Generated/Api), which has no handler: give it Generated/Handlers' endpoint of the same name. In the browser, send it (Endpoint.send!)", form: Typed(|fields| FormBody.parse(fields)), bound: "" }

	## On the server: the contract `endpoint` (Api's: its method, its URL, its types) with the
	## handler that answers it, as `Generated/Handlers.roc` pairs each route's
	## (`Endpoint.bind(Api.get_board(params), |request, context, {}| BoardServer.get!({ request, params,
	## context }))`), so the compiler checks that they agree. The router answers with it (`respond!`,
	## `stream!`, `channel!`), and `run!` runs it. It keeps the contract's reader of a form.
	bind : Endpoint(context, arg, result), (Server.Request, context, arg => Try(result, Refusal)) -> Endpoint(context, arg, result)
	bind = |endpoint, handler| { method: endpoint.method, url: endpoint.url, run: handler, form: endpoint.form, bound: endpoint.bound }

	## A path's typed params (D-092), read from its parts as a form's fields are (`FormBody`):
	## `[{ name: "id", value: "7" }]` as `{ id : I64 }`, or why not. Generated/Routes and Root read a
	## typed path with it, and a part that doesn't read is no match (404).
	read_params : List({ name : Str, value : Str }) -> Try(params, Str) where [params.FormBody.Readable]
	read_params = |parts| FormBody.parse(parts)

	## Its reader of a form's fields as its arg (`FormBody`), or why it can't: what a submission of a
	## form to it reads what was typed with (`Router.use_submission!`, `Submission.input!`).
	form_of : Endpoint(context, arg, result) -> (List({ name : Str, value : Str }) -> Try(arg, Str))
	form_of = |endpoint|
		match endpoint.form {
			Typed(reader) => reader
			Untyped => |_| Err("${endpoint.method} ${endpoint.url} reads JSON alone (Endpoint.local_json)")
		}

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
	## why (`GET /api/likes: 500: the database is down`). One no <Errored> of the page's catches
	## reaches the app's root one (rocx writes it), and the page is the app's error page
	## (`+error.rocx`), answered with the refusal's status when it is a 4xx (`GET /notes/9: 404: Not
	## found` is a 404, as a path no page has is: `Errored.status_of`), else 500. A boundary of the
	## page's own that catches it shows its fallback, as it would in the browser, and the page is
	## answered as it is (200, unless the fallback says otherwise with `<HttpStatusCode>`). A
	## redirect, while the page renders (a signed-out visitor sent to sign in), is the page's answer
	## instead. `with_query` adds a query.
	get! : Endpoint(context, {}, result) => result
		where [result.Json.Parseable([InvalidJson(Str)])]
	get! = |endpoint|
		match Endpoint.read!(endpoint) {
			Ok(result) => result
			Err(problem) => {
				why =
					match problem {
						Refused(status, said) => "${status.to_str()}: ${said}"
						_ => Server.explain(problem)
					}
				Host.fail!("${endpoint.method} ${endpoint.url}: ${why}")
				crash "unreachable: fail! doesn't return"
			}
		}

	## A GET endpoint's answer, as `get!` reads it, with a refusal as a value: `Err(Refused(404, why))`,
	## for a computation that shows it itself.
	read! : Endpoint(context, {}, result) => Try(result, Server.Problem)
		where [result.Json.Parseable([InvalidJson(Str)])]
	read! = |endpoint|
		if endpoint.method == "GET" {
			# `Call.fetch!`'s request, its header written as the host takes it: a read that isn't in yet
			# unwinds this frame, and a list made for the header would never be let go of.
			match fetched(Host.fetch!("GET", endpoint.url, "accept: application/json", "")) {
				Ok(answered) => Endpoint.answer(endpoint, Ok({ status: answered.status, headers: [], body: answered.body }))
				Err(InvalidJson(why)) => {
					Host.fail!("GET ${endpoint.url}: ${why}")
					crash "unreachable: fail! doesn't return"
				}
			}
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

	## From a component, in the browser: its answer, sent with the platform's `Call.fetch!`, and
	## read as a plain value (`Endpoint.send!(Api.post_api_shout({}), { word })`). The handler or
	## computation that sends it stops until the answer is in, and runs again then.
	send! : Endpoint(context, arg, result), arg => Try(result, Server.Problem)
		where [arg.Json.Encodable(e), result.Json.Parseable([InvalidJson(Str)])]
	send! = |endpoint, arg| {
		answered = Call.fetch!(Endpoint.to_request(endpoint, arg))
		Endpoint.answer(endpoint, Ok({ status: answered.status, headers: [], body: answered.body }))
	}

	## From a component, in the browser: listens to an endpoint's events with the platform's
	## `Call.listen!` (`Endpoint.listen!(Api.events_api_count_to({ to }), heard!)`): `heard!` is
	## given each event as it comes, typed, then `Ended`, or what went wrong.
	listen! : Endpoint(context, {}, Events(event)), ([Event(event), Ended, Failed(Server.Problem)] => {}) => {}
		where [event.Json.Parseable([InvalidJson(Str)])]
	listen! = |endpoint, heard!|
		Call.listen!(
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

	## From a component, in the browser: subscribes to a channel (a route's `channel!`), from an
	## effect, until the effect runs again or its component goes
	## (`create_effect!(|| org!(), |org| Endpoint.subscribe!(Api.channel_org_org_news({ org }), heard!))`).
	## `heard!` is given what its subscription hears (`Channel.Event`), in order, one at a time:
	## `Resync` when it should read its data again, then each `Message`; or why it hears nothing.
	##
	## Every subscription in a tab shares one stream (`/rocx/live`), which the runtime opens once the
	## page has rendered, and opens again, a little later each time, when it drops. When what the
	## page subscribes to changes, the runtime tells the stream so (a post), and the route's
	## `on_close!` hears `Dropped` for a channel the page no longer subscribes to. Two components on one channel share its subscription. A
	## message it can't read as `message` is a `Resync`. On a host with no server (a static copy), it
	## is `Refused(404, …)`, asked for once. On the server, it does nothing.
	subscribe! : Endpoint(context, {}, Channel(who, message, said)), (Channel.Event(message) => {}) => {}
		where [message.Json.Parseable([InvalidJson(Str)])]
	subscribe! = |endpoint, heard!| {
		each! = || {
			heard!(heard_of(Host.event_value!({})))
			""
		}
		Host.subscribe!(endpoint.url, Box.box(each!))
	}

	## From a component, in the browser: says `said` on a channel, to the server, where its route's
	## `receive!` hears it, if its check lets the page in (`Endpoint.say!(Api.channel_rooms_room({
	## room }), Moved({ x, y }))`). What a page says in one frame goes in one request
	## (`POST /rocx/live/send`); nothing waits for it, and a refusal is a warning in the console. Not
	## on the server.
	say! : Endpoint(context, {}, Channel(who, message, said)), said => {}
		where [said.Json.Encodable(e)]
	say! = |endpoint, said|
		match Json.to_str_try(said) {
			Ok(json) => Host.say!(endpoint.url, json)
			Err(_) => crash "${endpoint.url}: what is said ${Server.unwritable}"
		}

	## From a component, in the browser: asks the server for a `Resync` on a channel this tab
	## subscribes to (and the route's `on_open!` messages after it), as when the page saw it missed
	## something (a gap in the numbers its messages carry). Every subscriber to it in the tab hears
	## it. Not on the server.
	resync! : Endpoint(context, {}, Channel(who, message, said)) => {}
	resync! = |endpoint| Host.resync!(endpoint.url)

	## On the server: publishes `message` to every page subscribed to a channel
	## (`Endpoint.publish!(Api.channel_org_org_news({ org: "acme" }), news)`), from a request, a
	## job or an actor: only those subscribed with the same params hear it. A subscriber hears the
	## messages on a channel in the order they were published; one that falls too far behind (256)
	## hears `Resync` instead of what it missed. In the server's memory (`Live`): published while
	## nobody listens, it is gone.
	publish! : Endpoint(context, {}, Channel(who, message, said)), message => {}
		where [message.Json.Encodable(e)]
	publish! = |endpoint, message|
		match Json.to_str_try(message) {
			Ok(json) => Host.live_publish!("channel:${topic_of(endpoint.url)}", json)
			Err(_) => crash "${endpoint.url}: a message ${Server.unwritable}"
		}

	## On the server: publishes `message` as `publish!` does, but only the latest with each `key`
	## matters (where each member's cursor is, say: its key, the member). A subscriber behind gets
	## only the newest with each key, and never a `Resync` for these: what it missed is replaced.
	## They aren't ordered with the channel's other messages.
	publish_latest! : Endpoint(context, {}, Channel(who, message, said)), Str, message => {}
		where [message.Json.Encodable(e)]
	publish_latest! = |endpoint, key, message|
		match Json.to_str_try(message) {
			Ok(json) => Host.live_publish!("latest:${topic_of(endpoint.url)}", "${Json.to_str(key)}\n${json}")
			Err(_) => crash "${endpoint.url}: a message ${Server.unwritable}"
		}

	## On the server: the answer to the host's question about a subscription (`/rocx/live`), as the
	## generated routes give it, behind the route's middleware: its check, given the context that
	## handed on; then, as the host asks (`x-rocx-channel`), who it let in and what it is sent first
	## (`open`), who it is now (`check`), or what a page said, for `received!` (`receive`). A refusal
	## is its status and why, or the answer it is (a redirect).
	##
	## Its hooks: `opened!`, the messages a subscriber is sent first; `received!`, what a page said, as
	## JSON (`receiving` reads it as the channel's `said`); `closes`, whether the host tells the route
	## when a subscription ends.
	channel! : Endpoint(context, {}, Channel(who, message, said)), Server.Request, context, { opened! : who, Str => List(message), received! : who, Str, Str => Try({}, Refusal), closes : Bool } => Server.Response
		where [who.Json.Encodable(e), message.Json.Encodable(f)]
	channel! = |endpoint, request, context, hooks| {
		asked = Server.header(request, "x-rocx-channel") ?? ""
		tab = Server.header(request, "x-rocx-tab") ?? ""
		handler = endpoint.run
		match handler(request, context, {}) {
			Ok(channel) => {
				who = Channel.who_of(channel)
				if asked == "open" {
					opened! = hooks.opened!
					# Each part encoded on its own: a record holding `who` isn't, while `who` is a type
					# variable (the fork's compiler, 3f66e242ea).
					match (Json.to_str_try(who), messages_json(opened!(who, tab))) {
						(Ok(who_json), Ok(opened)) => json_answer("{\"url\":${Json.to_str(topic_of(endpoint.url))},\"who\":${who_json},\"opened\":${opened},\"closes\":${if (hooks.closes) "true" else "false"}}")
						_ => text(500, "${endpoint.url}: who the subscriber is, or a message, ${Server.unwritable}")
					}
				} else if asked == "receive" {
					received! = hooks.received!
					match received!(who, tab, Server.text_of(request)) {
						Ok({}) => Server.response(204, [], "")
						Err(Answer(own)) => own
						Err(refusal) => {
							(status, why) = Endpoint.refused(refusal)
							text(status, why)
						}
					}
				} else {
					match Json.to_str_try(who) {
						Ok(who_json) => json_answer("{\"who\":${who_json}}")
						Err(_) => text(500, "${endpoint.url}: who the subscriber is ${Server.unwritable}")
					}
				}
			}
			Err(Answer(own)) => own
			Err(refusal) => {
				(status, why) = Endpoint.refused(refusal)
				text(status, why)
			}
		}
	}

	## On the server: a channel's `receive!` (`received!`), for `channel!`, given what a page said as
	## JSON: read as the channel's `said`, or refused (400) when it isn't one.
	receiving : Endpoint(context, {}, Channel(who, message, said)), (who, Str, said => Try({}, Refusal)) -> (who, Str, Str => Try({}, Refusal))
		where [said.Json.Parseable([InvalidJson(Str)])]
	receiving = |endpoint, received!| |who, tab, json|
		match Json.parse(json) {
			Ok(said) => received!(who, tab, said)
			Err(InvalidJson(why)) => Err(BadRequest("${endpoint.url} can't read what was said: ${why}"))
		}

	## On the server: a subscription has ended, as the host tells it (`x-rocx-channel: close`, its
	## body who the check said it was and why it ended): the route's `on_close!`, given them. Its
	## middleware doesn't run, nor its check: a subscription refused at a beat ends too.
	closed! : Endpoint(context, {}, Channel(who, message, said)), Server.Request, (who, Str, Channel.Closed => {}) => Server.Response
		where [who.Json.Parseable([InvalidJson(Str)])]
	closed! = |endpoint, request, on_close!| {
		tab = Server.header(request, "x-rocx-tab") ?? ""
		match closing(Server.text_of(request)) {
			Ok({ who, why }) => {
				on_close!(who, tab, why)
				Server.response(204, [], "")
			}
			Err(InvalidJson(why)) => text(400, "${endpoint.url} can't read who the subscriber was: ${why}")
		}
	}

	## What the host asks of a channel's route about a subscription (`x-rocx-channel`: `open`,
	## `check`, `receive` or `close`), or "": a request from anyone else, whose headers the host never
	## passes on with that name.
	channel_asked : Server.Request -> Str
	channel_asked = |request| Server.header(request, "x-rocx-channel") ?? ""

	## Its URL: where a form posts to it, say, with the fields `with_fields` gave it in its query.
	url_of : Endpoint(context, arg, result) -> Str
	url_of = |endpoint|
		if endpoint.bound.is_empty() {
			endpoint.url
		} else if endpoint.url.contains("?") {
			"${endpoint.url}&${endpoint.bound}"
		} else {
			"${endpoint.url}?${endpoint.bound}"
		}

	## Its URL without the fields `with_fields` gave it: what its submissions are kept by
	## (`Router.use_submissions!`), so a form's with bound fields are the endpoint's too, as Solid
	## Router keeps an `action.with`'s.
	base_of : Endpoint(context, arg, result) -> Str
	base_of = |endpoint| endpoint.url

	## The endpoint with some of a form's fields given ahead of time (Solid Router's `action.with`):
	## `bound`, a record of them (as JSON writes it: text, numbers, yes-or-no, choices, lists of them),
	## goes in the URL the form posts to (`url_of`: `/todos/toggle?id=7`), read before the form's own
	## fields, with JavaScript or without. Its submissions are the endpoint's (`base_of`).
	##
	##     <form method="post" action={Endpoint.url_of(Endpoint.with_fields(toggle, { id: todo.id }))}>
	##         <button name="done" value="true">Done</button>
	##     </form>
	##
	## The endpoint reads them as it reads any form's: an action (`Router.use_action!`) sends its whole
	## arg as JSON, so a handler binds its values in a closure instead (`|done| toggle!({ id, done })`).
	## A record inside a field has no form: it crashes, saying so.
	with_fields : Endpoint(context, arg, result), bound -> Endpoint(context, arg, result) where [bound.Json.Encodable(e)]
	with_fields = |endpoint, bound| {
		fields =
			match Json.to_str_try(bound) {
				Ok(json) =>
					match json_fields(json) {
						Ok(found) => found
						Err(why) => crash "Endpoint.with_fields(${endpoint.url}, …): ${why}"
					}
				Err(_) => crash "Endpoint.with_fields(${endpoint.url}, …): its fields ${Server.unwritable}"
			}
		encoded = Str.join_with(fields.map(|field| "${Server.encode_segment(field.name)}=${Server.encode_segment(field.value)}"), "&")
		{ ..endpoint, bound: if (endpoint.bound.is_empty()) encoded else if (encoded.is_empty()) endpoint.bound else "${endpoint.bound}&${encoded}" }
	}

	## On the server: runs it there and then, with the request being answered and the context its
	## handler is given (its middleware doesn't run: the caller ran its own); a refusal as the
	## browser would see it. It needs the endpoint with its handler: `Generated/Handlers`'s
	## (`Endpoint.run!(Handlers.get_note({ id }), request, context, {})`), not Api's contract.
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
	## or a form (`application/x-www-form-urlencoded`: its fields, as a browser posts them, read by
	## the arg's type, `FormBody`; a field it lacks or can't read is a 400 naming it). Any other body
	## (an upload: `application/octet-stream`, `video/mp4`, or no type at all) isn't read: the arg is
	## `{}`, and the handler reads `request.body`, the bytes as they came.
	## No body is `{}` too. Its result is sent as JSON, a refusal as its status and why, or as the
	## answer it is. A body it doesn't read, for a handler that wants an arg, is 415.
	##
	## A form a browser posted without the runtime (a plain `<form method="post">`: a form's body,
	## `accept: text/html`) gets neither its result nor its refusal, which would be a page of JSON or
	## of text: it goes back to the page it came from, which reads them with what was typed
	## (`Server.flash_back!`, `Server.flash!`, `use_submission!`). A form the runtime sent
	## (`x-rocx-submission`) gets them, and a redirect of its handler's own comes back as 200 with
	## `x-rocx-redirect` (fetch would follow it before anyone could read it), for the runtime to go
	## there. An answer of its own is otherwise sent as it is.
	respond! : Endpoint(context, arg, result), Server.Request, context => Server.Response
		where [arg.Json.Parseable([InvalidJson(Str)]), result.Json.Encodable(e)]
	respond! = |endpoint, request, context| {
		read = input_of(request)
		parsed : Try(arg, Str)
		parsed =
			match read {
				Fields(fields) =>
					match endpoint.form {
						Typed(reader) => reader(fields)
						Untyped => Json.parse(Server.form_json(Server.text_of(request))).map_err(|InvalidJson(why)| why)
					}
				Read(json) => Json.parse(json).map_err(|InvalidJson(why)| why)
				Unread(_) => Json.parse("{}").map_err(|InvalidJson(why)| why)
			}
		posted = Endpoint.posted_by(request)
		reply! = |status, body|
			match posted {
				PlainForm => Server.flash_back!(request, { url: endpoint.url, input: form_input(read), status, body })
				_ => if (status == 200) Server.response(200, [{ name: "content-type", value: "application/json" }], body) else text(status, body)
			}
		match parsed {
			Ok(arg) => {
				handler = endpoint.run
				match handler(request, context, arg) {
					Ok(result) =>
						match Json.to_str_try(result) {
							Ok(json) => reply!(200, json)
							Err(_) => reply!(500, "${endpoint.method} ${request.path}'s answer: ${Server.unwritable}")
						}
					Err(Answer(own)) =>
						match posted {
							Runtime => redirected(own)
							_ => own
						}
					Err(refusal) => {
						(status, why) = Endpoint.refused(refusal)
						reply!(status, why)
					}
				}
			}
			Err(why) =>
				match read {
					Unread(type) => text(415, "${endpoint.method} ${request.path} reads JSON (application/json) or a form, not ${if (type.is_empty()) "a body with no content-type" else type}")
					_ => reply!(400, "${endpoint.method} ${request.path} can't read its body: ${why}")
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

	## Who sent a request, as `respond!` answers each: `PlainForm`, a browser's form posted without the
	## runtime (a form's body, for a page: `accept: text/html`), which goes back to its page with a
	## flash; `Runtime`, a form the runtime sent or an action (`use_action!`: `x-rocx-submission`),
	## which gets the result as JSON or the refusal; `Other`, anything else (JSON from a script,
	## `Endpoint.send!`), which gets them too. A handler that answers its own way asks it: a plain
	## form's delete sends the browser to the list, where the runtime wants the list's id.
	posted_by : Server.Request -> [PlainForm, Runtime, Other]
	posted_by = |request|
		if Server.header(request, "x-rocx-submission").is_ok() {
			Runtime
		} else if is_form(media_type(Server.header(request, "content-type") ?? "")) and Server.wants_html(request) {
			PlainForm
		} else {
			Other
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

## The host's answer to a request (`Host.fetch!`), as `Call.fetch!` reads it.
fetched : Str -> Try({ status : U16, body : Str }, [InvalidJson(Str)])
fetched = |answer| Json.parse(answer)

## What a subscription heard, as the runtime tells it (`Host.event_value!`): `"Resync"`,
## `{"Message":"<the message's JSON>"}`, `{"Refused":[403,"why"]}`, `{"Ended":"why"}`. A message it
## can't read as the channel's, or anything else, is a `Resync`: the subscriber reads its data again.
heard_of : Str -> Channel.Event(message) where [message.Json.Parseable([InvalidJson(Str)])]
heard_of = |value| {
	told : Try([Message(Str), Resync, Refused(U16, Str), Ended(Str)], [InvalidJson(Str)])
	told = Json.parse(value)
	match told {
		Ok(Message(data)) =>
			match Json.parse(data) {
				Ok(message) => Message(message)
				Err(InvalidJson(_)) => Resync
			}
		Ok(Resync) => Resync
		Ok(Refused(status, why)) => Refused(status, why)
		Ok(Ended(why)) => Ended(why)
		Err(InvalidJson(_)) => Resync
	}
}

## A channel's topic in `Live`: its URL's path, without a query.
topic_of : Str -> Str
topic_of = |url|
	match url.split_first("?") {
		Ok({ before, .. }) => before
		Err(_) => url
	}

## The messages, as a JSON list.
messages_json : List(message) -> Try(Str, [Unwritable]) where [message.Json.Encodable(e)]
messages_json = |messages| {
	var $written = []
	for message in messages {
		match Json.to_str_try(message) {
			Ok(json) => {
				$written = $written.append(json)
			}
			Err(_) => return Err(Unwritable)
		}
	}
	Ok("[${Str.join_with($written, ",")}]")
}

## An answer to the host: JSON.
json_answer : Str -> Server.Response
json_answer = |json| Server.response(200, [{ name: "content-type", value: "application/json" }], json)

## What the host says when a subscription ends: who it was, and why it ended.
closing : Str -> Try({ who : who, why : Channel.Closed }, [InvalidJson(Str)]) where [who.Json.Parseable([InvalidJson(Str)])]
closing = |body| Json.parse(body)

## What an endpoint's arg is read from: a form's fields (`Fields`, read by the arg's type: the
## URL's query first, its fields given ahead of time, `with_fields`; then the body's, URL-encoded or
## multipart, a file's its name); the body as JSON, when it says it is JSON, or `{}` for no body
## (`Read`). A body of any other type isn't read (`Unread`, with its type): an upload, which the
## handler reads itself.
input_of : Server.Request -> [Fields(List({ name : Str, value : Str })), Read(Str), Unread(Str)]
input_of = |request| {
	type = media_type(Server.header(request, "content-type") ?? "")
	if type == "application/x-www-form-urlencoded" {
		Fields(Server.form_fields(request.query).concat(Server.form_fields(Server.text_of(request))))
	} else if type == "multipart/form-data" {
		match Server.multipart(request) {
			Ok(parts) => Fields(Server.form_fields(request.query).concat(parts.fields))
			Err(NotMultipart) => Unread("multipart/form-data with no boundary")
		}
	} else if type == "application/json" or type.ends_with("+json") {
		body = Server.text_of(request)
		Read(if (body.trim().is_empty()) "{}" else body)
	} else if request.body.is_empty() {
		Read("{}")
	} else {
		Unread(type)
	}
}

## Whether a body of this type is a form's: URL-encoded, or multipart (a form with files).
is_form : Str -> Bool
is_form = |type| type == "application/x-www-form-urlencoded" or type == "multipart/form-data"

## What a form sent, as a flash keeps it (`Server.flash_back!`): its fields, the URL's and the
## body's (a file's its name), URL-encoded.
form_input : [Fields(List({ name : Str, value : Str })), Read(Str), Unread(Str)] -> Str
form_input = |read|
	match read {
		Fields(fields) => Str.join_with(fields.map(|field| "${Server.encode_segment(field.name)}=${Server.encode_segment(field.value)}"), "&")
		Read(json) => json
		Unread(_) => ""
	}

## A record's JSON (`{"id":7,"tags":["a","b"],"done":true}`) as a form's fields: text as it is,
## a number, `true` or `false` as written, `null` as nothing, a list as its items, each a field of
## the same name. A record or a list inside one has no form: why not.
json_fields : Str -> Try(List({ name : Str, value : Str }), Str)
json_fields = |json| {
	bytes = json.to_utf8()
	var $at = spaces(bytes, 0)
	if (bytes.get($at) ?? ' ') != '{' {
		return Err("its fields are a record's")
	}
	$at = spaces(bytes, $at + 1)
	var $fields = []
	while (bytes.get($at) ?? '}') != '}' {
		name = json_string(bytes, $at)?
		$at = spaces(bytes, name.next)
		if (bytes.get($at) ?? ' ') != ':' {
			return Err("its JSON isn't a record's")
		}
		$at = spaces(bytes, $at + 1)
		if (bytes.get($at) ?? ' ') == '[' {
			$at = spaces(bytes, $at + 1)
			while (bytes.get($at) ?? ']') != ']' {
				item = json_scalar(bytes, $at, name.text)?
				$fields = $fields.concat(item.values.map(|value| { name: name.text, value }))
				$at = spaces(bytes, item.next)
				if (bytes.get($at) ?? ' ') == ',' {
					$at = spaces(bytes, $at + 1)
				}
			}
			$at = spaces(bytes, $at + 1)
		} else {
			value = json_scalar(bytes, $at, name.text)?
			$fields = $fields.concat(value.values.map(|each| { name: name.text, value: each }))
			$at = spaces(bytes, value.next)
		}
		if (bytes.get($at) ?? ' ') == ',' {
			$at = spaces(bytes, $at + 1)
		}
	}
	Ok($fields)
}

## Past the spaces at `at`.
spaces : List(U8), U64 -> U64
spaces = |bytes, at| {
	var $at = at
	while [' ', '\n', '\r', '\t'].contains(bytes.get($at) ?? 'x') {
		$at = $at + 1
	}
	$at
}

## A JSON string at `at` (its opening quote), read, and where it ends.
json_string : List(U8), U64 -> Try({ text : Str, next : U64 }, Str)
json_string = |bytes, at| {
	if (bytes.get(at) ?? ' ') != '"' {
		return Err("its JSON isn't a record's")
	}
	var $at = at + 1
	var $escaped = Bool.False
	while $escaped or (bytes.get($at) ?? '"') != '"' {
		$escaped = !$escaped and bytes.get($at) == Ok('\\')
		$at = $at + 1
	}
	quoted = Str.from_utf8_lossy(bytes.sublist({ start: at, len: $at + 1 - at }))
	match Json.parse(quoted) {
		Ok(read) => Ok({ text: read, next: $at + 1 })
		Err(InvalidJson(why)) => Err(why)
	}
}

## A field's value at `at`: text, a number, `true` or `false` (one value), or `null` (none).
json_scalar : List(U8), U64, Str -> Try({ values : List(Str), next : U64 }, Str)
json_scalar = |bytes, at, name|
	match bytes.get(at) ?? ' ' {
		'"' => json_string(bytes, at).map_ok(|found| { values: [found.text], next: found.next })
		'{' => Err("the field ${name} is a record, which a form doesn't have")
		'[' => Err("the field ${name} is a list of lists, which a form doesn't have")
		_ => {
			var $end = at
			while !([',', '}', ']', ' ', '\n', '\r', '\t'].contains(bytes.get($end) ?? ',')) {
				$end = $end + 1
			}
			word = Str.from_utf8_lossy(bytes.sublist({ start: at, len: $end - at }))
			Ok({ values: if (word == "null") [] else [word], next: $end })
		}
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
expect {
	read : Try({ id : I64, kind : [Low, High] }, Str)
	read = Endpoint.read_params([{ name: "id", value: "7" }, { name: "kind", value: "High" }])
	read == Ok({ id: 7, kind: High })
}
expect {
	read : Try({ id : I64 }, Str)
	read = Endpoint.read_params([{ name: "id", value: "seven" }])
	read.is_err()
}
expect Endpoint.url_of(Endpoint.bind(Endpoint.remote("POST", "/shout"), |_, _, said| Ok(Str.concat(said, "!")))) == "/shout"
expect Endpoint.url_of(Endpoint.with_query(shout, "weeks=1")) == "/shout?weeks=1"
expect Endpoint.url_of(Endpoint.with_query(Endpoint.with_query(shout, "weeks=1"), "weeks=2")) == "/shout?weeks=2"
expect Endpoint.url_of(Endpoint.with_query(shout, "")) == "/shout"
expect input_of(Server.from_http("POST", "/shout", "content-type: application/json", "\"hi\"".to_utf8())) == Read("\"hi\"")
expect input_of(Server.from_http("POST", "/shout", "Content-Type: application/merge-patch+json; charset=utf-8", "{}".to_utf8())) == Read("{}")
expect input_of(Server.from_http("POST", "/shout", "content-type: application/x-www-form-urlencoded", "said=hi".to_utf8())) == Fields([{ name: "said", value: "hi" }])
expect input_of(Server.from_http("POST", "/shout", "content-type: application/json", " ".to_utf8())) == Read("{}")
expect input_of(Server.from_http("PUT", "/upload", "content-type: video/mp4", [0, 0xFF, 0xD8])) == Unread("video/mp4")
expect input_of(Server.from_http("PUT", "/upload", "content-type: text/plain", "\"hi\"".to_utf8())) == Unread("text/plain")
expect input_of(Server.from_http("PUT", "/upload", "", [0xFF])) == Unread("")
expect input_of(Server.from_http("DELETE", "/upload", "content-type: video/mp4", [])) == Read("{}")
expect media_type("Application/JSON ; charset=utf-8") == "application/json"
expect Endpoint.posted_by(Server.from_http("POST", "/shout", "content-type: application/x-www-form-urlencoded\naccept: text/html,*/*", [])) == PlainForm
expect Endpoint.posted_by(Server.from_http("POST", "/shout", "content-type: application/x-www-form-urlencoded\naccept: application/json\nx-rocx-submission: 1", [])) == Runtime
expect Endpoint.posted_by(Server.from_http("POST", "/shout", "content-type: application/json\naccept: text/html", [])) == Other
expect Endpoint.posted_by(Server.from_http("POST", "/shout", "content-type: application/x-www-form-urlencoded", [])) == Other
expect redirected(Server.with_cookie(Server.redirect("/members"), "member", "Ada")).headers == [{ name: "x-rocx-redirect", value: "/members" }, { name: "set-cookie", value: "member=Ada; Path=/; HttpOnly; SameSite=Lax" }]
expect redirected(Server.redirect("/members")).status == 200
expect redirected(Server.refused(409, "taken")).status == 409
expect Endpoint.not_allowed(Server.from_host("/shout", ""), ["POST"]).headers.first() == Ok({ name: "allow", value: "POST" })
expect json_fields("{\"done\":true,\"id\":7,\"note\":\"a, \\\"b\\\"\",\"tags\":[\"x\",\"y\"],\"gone\":null}") == Ok([{ name: "done", value: "true" }, { name: "id", value: "7" }, { name: "note", value: "a, \"b\"" }, { name: "tags", value: "x" }, { name: "tags", value: "y" }])
expect json_fields("{\"at\":{\"x\":1}}") == Err("the field at is a record, which a form doesn't have")
expect Endpoint.url_of(Endpoint.with_fields(shout, { id: 7.U64, tag: "a b" })) == "/shout?id=7&tag=a%20b"
expect Endpoint.base_of(Endpoint.with_fields(shout, { id: 7.U64 })) == "/shout"
expect Endpoint.url_of(Endpoint.with_fields(Endpoint.with_query(shout, "weeks=1"), { id: 7.U64 })) == "/shout?weeks=1&id=7"
expect input_of(Server.from_http("POST", "/todos/toggle?id=7", "content-type: application/x-www-form-urlencoded", "done=on".to_utf8())) == Fields([{ name: "id", value: "7" }, { name: "done", value: "on" }])
expect input_of(Server.from_http("POST", "/photos", "content-type: multipart/form-data; boundary=b", "--b\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"a.png\"\r\n\r\nPNG\r\n--b--".to_utf8())) == Fields([{ name: "photo", value: "a.png" }])
expect Endpoint.posted_by(Server.from_http("POST", "/photos", "content-type: multipart/form-data; boundary=b\naccept: text/html", [])) == PlainForm
