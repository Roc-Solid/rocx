import Host
import Call
import Html
import Events

## The server: what it knows about a request, and how it answers. An app's `respond!` gets each
## request from its platform (`from_http`) and gives back the answer; its routes, endpoints and
## middleware (rocx writes them from `routes/`) take and make these in between.
##
## And its functions. A function that runs on the server, in a .rocx file, is one definition:
##
##     echo! : Str => Str
##     echo! = server!(|request, message| "Echo: ${message}")
##
## and it is called as a function everywhere. `rocx build` names it after its module and definition
## (`Demos/Echo.echo`), and the app's routes answer `POST /rocx/call/Demos/Echo.echo` with it
## (`serve!`), behind the middleware that guards it. Its body runs there, given the request; what
## its middleware handed on is `Server.context!({})`. Called anywhere else, it is that request: from
## the browser (`remote`) over HTTP, its answer read as a plain value (a computation waits for it, a
## failure shows the nearest <Errored>); on the server (`local`), while a component renders, the same
## request answered in-process, its answer noted for the page, so the browser's first run reads it
## there instead of asking again.
Server := [].{

	## What the server knows about a request: its method, its path and query, its headers (cookies
	## among them) and its body, the bytes as they came (`text_of` reads them as text: JSON, a form).
	## A page has the request it was rendered for; an endpoint, the request it came in.
	Request : { method : Str, path : Str, query : Str, headers : List({ name : Str, value : Str }), body : List(U8) }

	## The server's answer to a request: its status, its headers and its body.
	Response : { status : U16, headers : List({ name : Str, value : Str }), body : Body }

	## What an answer sends after its status and headers: text (HTML, JSON, why it refused); bytes
	## (an image, a file: `Server.bytes`); a page of components, which the server renders, a document
	## for the browser to hydrate; a stream of events (`Server.events`); or a body the server fetches
	## from elsewhere and sends on as it comes (`Server.forward`).
	Body : [Text(Str), Bytes(List(U8)), Page({} => Html), Events(Events(Str)), Forward(Upstream)]

	## Where a forwarded answer's body comes from (`Server.forward`): the request the server makes
	## for it, its method, URL and headers (keys and all: `Storage.serve!` signs one).
	Upstream : { method : Str, url : Str, headers : List({ name : Str, value : Str }) }

	## What asking an endpoint can come to instead of its answer: none (`HttpErr`, from the
	## network), an answer that isn't one (`Refused`, with its status and text: 404 for a path the
	## server doesn't have, 400 for input it can't read), or one that isn't the result's type
	## (`BadAnswer`: a browser and a server built from different versions).
	Problem : [HttpErr(Str), Refused(U16, Str), BadAnswer(Str)]

	## A GET of `target` (a path, and a query after a `?`), with its headers, a `name: value` a line.
	from_host : Str, Str -> Request
	from_host = |target, lines| Server.from_http("GET", target, lines, [])

	## The request, from what the host passes: its method, its target (a path, and a query after a
	## `?`), its headers (a `name: value` a line) and its body, as it came.
	from_http : Str, Str, Str, List(U8) -> Request
	from_http = |method, target, lines, body| {
		headers = lines.split_on("\n").keep_oks(
			|line|
				match line.split_first(": ") {
					Ok({ before, after }) => Ok({ name: before.with_ascii_lowercased(), value: after })
					Err(_) => Err(NoHeader)
				},
		)
		(path, query) =
			match target.split_first("?") {
				Ok({ before, after }) => (before, after)
				Err(_) => (target, "")
			}
		{ method: method.with_ascii_uppercased(), path: path, query: query, headers: headers, body: body }
	}

	## The answer as the server platform's host takes it: its headers a `name: value` a line, and its
	## `kind`, which says which of the rest it sends:
	##
	## - 0, `text`;
	## - 1, the page (`page`), which the host renders, as HTML unless the answer says otherwise;
	## - 2, the stream (`feed`): a loop the host runs on a thread of its own, with its `send!` and
	##   `sleep!`, which sends the events (`sent!`). A stream that has already ended is text: none;
	## - 3, `bytes`, as they are;
	## - 4, the `upstream` the host fetches the body from, and sends on (`forward`): its headers a
	##   `name: value` a line too.
	##
	## The ones an answer doesn't send do nothing.
	for_host : Response -> { status : U16, headers : Str, kind : U8, text : Str, bytes : List(U8), upstream : { method : Str, url : Str, headers : Str }, page : {} => Html, feed : { send! : Str => Bool, sleep! : U64 => {} } => {} }
	for_host = |answered| {
		lines = |headers| Str.join_with(headers.map(|each| "${each.name}: ${each.value}"), "\n")
		headers = lines(answered.headers)
		none = { method: "", url: "", headers: "" }
		match answered.body {
			Text(text) => { status: answered.status, headers, kind: 0, text, bytes: [], upstream: none, page: |{}| Html.empty({}), feed: |_| {} }
			Bytes(sent) => { status: answered.status, headers, kind: 3, text: "", bytes: sent, upstream: none, page: |{}| Html.empty({}), feed: |_| {} }
			Page(view!) => {
				typed = answered.headers.any(|each| each.name.with_ascii_lowercased() == "content-type")
				html = { name: "content-type", value: "text/html; charset=utf-8" }
				{ status: answered.status, headers: if (typed) headers else lines(answered.headers.append(html)), kind: 1, text: "", bytes: [], upstream: none, page: view!, feed: |_| {} }
			}
			Events(stream) =>
				if Events.is_ended(stream) {
					{ status: answered.status, headers, kind: 0, text: "", bytes: [], upstream: none, page: |{}| Html.empty({}), feed: |_| {} }
				} else {
					{ status: answered.status, headers, kind: 2, text: "", bytes: [], upstream: none, page: |{}| Html.empty({}), feed: |io| sent!(stream, io) }
				}
			Forward(from) => {
				upstream = { method: from.method, url: from.url, headers: lines(from.headers) }
				{ status: answered.status, headers, kind: 4, text: "", bytes: [], upstream, page: |{}| Html.empty({}), feed: |_| {} }
			}
		}
	}

	## An answer: its status, headers and body.
	response : U16, List({ name : Str, value : Str }), Str -> Response
	response = |status, headers, body| { status: status, headers: headers, body: Text(body) }

	## An answer whose body is bytes, sent as they are (an image, a file): its status, headers (its
	## `content-type` among them) and bytes.
	bytes : U16, List({ name : Str, value : Str }), List(U8) -> Response
	bytes = |status, headers, sent| { status: status, headers: headers, body: Bytes(sent) }

	## An answer whose body the server fetches from `upstream` and sends on as it comes, never
	## through Roc: a file in S3 (`Storage.serve!`), a video of 500 MB. Upstream's status is the
	## answer's (200, 206 for a range, 304, 404…), with its `content-type`, `content-length`,
	## `content-range`, `accept-ranges`, `etag` and `last-modified`; `headers` are added, or replace
	## those. The answer's own `status` (200) is a stand-in. Upstream is sent `upstream.headers` and
	## nothing else: to pass on the client's range and cache questions, add `Server.passed_on(request)`
	## to them (an app may change or drop any first: a range that doesn't fit, say). Redirects are
	## followed. An error upstream (400 or more) is its status and its reason, a line of text,
	## without `headers`: never what upstream said. No answer is a 502 (a 504 after 30 s); either is
	## logged.
	forward : Upstream, List({ name : Str, value : Str }) -> Response
	forward = |upstream, headers| { status: 200, headers: headers, body: Forward(upstream) }

	## What a forwarded GET or HEAD passes on of the request: its `Range`, `If-Range`,
	## `If-None-Match` and `If-Modified-Since`, as the request record has them (none it hasn't), for
	## `upstream.headers` (`Storage.serve!` adds them).
	passed_on : Request -> List({ name : Str, value : Str })
	passed_on = |asked| asked.headers.keep_if(|each| ["range", "if-range", "if-none-match", "if-modified-since"].contains(each.name))

	## A request's body as text, UTF-8 (a byte that isn't is read as U+FFFD): what JSON and a form
	## are read from. An upload's bytes are `request.body`, as they came.
	text_of : Request -> Str
	text_of = |asked| Str.from_utf8_lossy(asked.body)

	## An answer that is a stream of events (server-sent events: `text/event-stream`), each sent as
	## it comes, as the text it is. An endpoint's `events!` makes one of its events, as JSON.
	events : Events(Str) -> Response
	events = |stream| {
		status: 200,
		headers: [{ name: "content-type", value: "text/event-stream" }, { name: "cache-control", value: "no-cache" }],
		body: Events(stream),
	}

	## The text an answer sends: its body's, if it is text (or bytes, as UTF-8); nothing for a page,
	## a stream or a body fetched from elsewhere.
	body_text : Response -> Str
	body_text = |answered|
		match answered.body {
			Text(text) => text
			Bytes(sent) => Str.from_utf8_lossy(sent)
			_ => ""
		}

	## Whether a request would change something: its method isn't GET, HEAD or OPTIONS.
	changes : Request -> Bool
	changes = |asked| !(asked.method == "GET" or asked.method == "HEAD" or asked.method == "OPTIONS")

	## Whether a browser sent it for a page (it accepts HTML), not a script or another program.
	wants_html : Request -> Bool
	wants_html = |asked| (Server.header(asked, "accept") ?? "").contains("text/html")

	## An answer that sends the browser elsewhere (303, See Other: with GET, whatever sent it).
	redirect : Str -> Response
	redirect = |location| Server.response(303, [{ name: "location", value: location }], "")

	## A refusal: its status, and why, as text.
	refused : U16, Str -> Response
	refused = |status, why| Server.response(status, [{ name: "content-type", value: "text/plain; charset=utf-8" }], why)

	## How a browser keeps a cookie (`set_cookie`), as `Set-Cookie` says it:
	##
	## - `max_age_s`: it lasts so many seconds (`Max-Age`); `expires_ms`: until that moment, in
	##   milliseconds since the epoch (`Expires`, the session's own end, say). 0 leaves either out;
	##   with neither, the cookie ends when the browser does.
	## - `secure`: sent over HTTPS only (`Secure`). A `__Host-` or `__Secure-` cookie, or one that is
	##   `SameSite=None`, is dropped by the browser without it.
	## - `http_only`: out of reach of the page's scripts (`HttpOnly`).
	## - `same_site`: whether a request another site starts carries it: `Lax` (following a link to
	##   here, yes; a form or a script, no), `Strict` (never), `None` (always: it needs `secure`).
	## - `path`: the paths it is sent to (`/`: all); `""` leaves it out.
	## - `domain`: `""` for this host alone, as a `__Host-` cookie must be; a domain (`example.com`)
	##   sends it to its subdomains too.
	CookieOpts : { max_age_s : U64, expires_ms : U64, secure : Bool, http_only : Bool, same_site : [Lax, Strict, None], path : Str, domain : Str }

	## Until the browser closes, over HTTP too, out of scripts' reach, `SameSite=Lax`, the whole
	## site, this host alone. Change what differs: `{ ..Server.cookie_defaults, secure: Bool.True,
	## max_age_s: 30 * 86_400 }`.
	cookie_defaults : CookieOpts
	cookie_defaults = { max_age_s: 0, expires_ms: 0, secure: Bool.False, http_only: Bool.True, same_site: Lax, path: "/", domain: "" }

	## The answer, setting the cookie `name` to `value` (`%XX`-encoded, as `cookie` decodes it), kept
	## as `opts` says.
	set_cookie : Response, Str, Str, CookieOpts -> Response
	set_cookie = |answer, name, value, opts| {
		lasts = [
			if (opts.max_age_s == 0) "" else "; Max-Age=${opts.max_age_s.to_str()}",
			if (opts.expires_ms == 0) "" else "; Expires=${http_date(opts.expires_ms)}",
		]
		{ ..answer, headers: answer.headers.append({ name: "set-cookie", value: "${name}=${Server.encode_segment(value)}${placed(opts)}${Str.join_with(lasts, "")}${guarded(opts)}" }) }
	}

	## The answer, removing the cookie `name`: given the `path` and `domain` it was set with (a
	## browser keeps one cookie for each), and `secure` for a `__Host-` or `__Secure-` one.
	clear_cookie : Response, Str, CookieOpts -> Response
	clear_cookie = |answer, name, opts| { ..answer, headers: answer.headers.append({ name: "set-cookie", value: "${name}=${placed(opts)}; Max-Age=0${guarded(opts)}" }) }

	## The answer, setting the cookie `name` to `value` for the whole site (`HttpOnly`: scripts can't
	## read it; `SameSite=Lax`: another site's page doesn't get it sent along), until the browser
	## closes: `set_cookie` with `cookie_defaults`.
	with_cookie : Response, Str, Str -> Response
	with_cookie = |answer, name, value| Server.set_cookie(answer, name, value, Server.cookie_defaults)

	## The answer, removing the cookie `name`.
	without_cookie : Response, Str -> Response
	without_cookie = |answer, name| { ..answer, headers: answer.headers.append({ name: "set-cookie", value: "${name}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0" }) }

	## A form's fields (`name=Ada&plan=b`, as a browser posts a form) as a JSON object of strings,
	## so an endpoint reads them as a record (`{ name : Str, plan : Str }`).
	form_json : Str -> Str
	form_json = |body| {
		fields = body.split_on("&").keep_if(|field| !field.is_empty()).map(
			|field| {
				(key, value) =
					match field.split_first("=") {
						Ok({ before, after }) => (before, after)
						Err(_) => (field, "")
					}
				"${Json.to_str(form_decoded(key))}:${Json.to_str(form_decoded(value))}"
			},
		)
		"{${Str.join_with(fields, ",")}}"
	}

	## A form's fields (`name=Ada+L&plan=b`, as a browser posts a form), decoded, in order.
	form_fields : Str -> List({ name : Str, value : Str })
	form_fields = |body|
		body.split_on("&").keep_if(|field| !field.is_empty()).map(
			|field|
				match field.split_first("=") {
					Ok({ before, after }) => { name: form_decoded(before), value: form_decoded(after) }
					Err(_) => { name: form_decoded(field), value: "" }
				},
		)

	## What a form posted without the runtime (a plain `<form method="post">`) comes back to its page
	## with: the URL it posted to, its fields as typed, and the endpoint's answer, its status and
	## body (200 and the result as JSON, or a refusal's status and why). `Endpoint.respond!` sends
	## it back (`flash_back`), and the page it lands on reads it (`flash!`).
	Flash : { url : Str, fields : List({ name : Str, value : Str }), status : U16, body : Str }

	## The flash a plain form's post came back with, on the page the redirect lands on: the next page
	## a browser asks for after it (`clear_flash`). On the server it is in the request's cookie,
	## and the page notes it for the browser (a script hydration reads), so both render the same.
	## `Err(NoFlash)` on any other page. `use_submission!` reads it for you.
	flash! : {} => Try(Flash, [NoFlash])
	flash! = |{}| {
		found =
			match Server.cookie(Server.request!({}), flash_cookie) {
				Ok(value) => value
				Err(Missing) => ""
			}
		match flashed(Host.flash!(found)) {
			Ok(posted) => Ok({ url: posted.url, fields: Server.form_fields(posted.input), status: posted.status, body: posted.body })
			Err(NoFlash) => Err(NoFlash)
		}
	}

	## The answer to a plain form's post, instead of the endpoint's own: back to the page it was
	## posted from (`Referer`, when it is this site's; `/` otherwise), with a 303, and the flash
	## (`url` posted to, the form's body as posted, the answer's status and body) in a cookie that
	## lasts a minute, for that page to read (`flash!`). Past what a cookie may hold (~3.8 KB), the
	## fields are left out, and the answer kept.
	flash_back : Request, { url : Str, input : Str, status : U16, body : Str } -> Response
	flash_back = |asked, posted| {
		back = referrer(asked)
		whole = Server.encode_segment(Json.to_str(posted))
		value = if (whole.count_utf8_bytes() <= 3800) whole else Server.encode_segment(Json.to_str({ ..posted, input: "" }))
		kept = "${flash_cookie}=${value}; Path=/; Max-Age=60; HttpOnly; SameSite=Lax"
		Server.response(303, [{ name: "location", value: back }, { name: "set-cookie", value: kept }], "")
	}

	## The answer, letting the flash go if the request is a browser's GET of a page that had one (the
	## page the flash was for: it reads it now, or never), so a reload doesn't show it again.
	## `App.program` does this for every answer.
	clear_flash : Request, Response -> Response
	clear_flash = |asked, answer|
		if asked.method == "GET" and Server.wants_html(asked) and Server.cookie(asked, flash_cookie).is_ok() {
			{ ..answer, headers: answer.headers.append({ name: "set-cookie", value: "${flash_cookie}=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax" }) }
		} else {
			answer
		}

	## What went wrong, as text: a refusal's why, or what kept an answer from coming.
	explain : Problem -> Str
	explain = |problem|
		match problem {
			HttpErr(said) => said
			Refused(_, said) => said
			BadAnswer(said) => "an answer that isn't what was asked for: ${said}"
		}

	## Whether a request comes from a page of this site, or from no page (curl): a browser says
	## which site's page sent it (`Origin`), and a page of another site may not change anything here.
	same_origin : Request -> Bool
	same_origin = |asked|
		match Server.header(asked, "origin") {
			Ok(origin) =>
				match origin.split_first("://") {
					Ok({ after, .. }) => Server.header(asked, "host") == Ok(after)
					Err(_) => Bool.False
				}
			Err(Missing) => Bool.True
		}

	## A path's part with anything but a letter, a digit or `-._~` as `%XX`: what a link to a page
	## or an endpoint with params puts in its path.
	encode_segment : Str -> Str
	encode_segment = |text| {
		var $out = []
		for byte in text.to_utf8() {
			$out =
				if (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '.' or byte == '_' or byte == '~' {
					$out.append(byte)
				} else {
					$out.concat(['%', upper_hex.get((byte // 16).to_u64()) ?? '0', upper_hex.get((byte % 16).to_u64()) ?? '0'])
				}
		}
		Str.from_utf8_lossy($out)
	}

	## A path's part as the text it stands for: `%XX` decoded.
	decode_segment : Str -> Str
	decode_segment = |text| percent_decoded(text)

	## The value of the header `wanted` (any case), if the request has it.
	header : Request, Str -> Try(Str, [Missing])
	header = |asked, wanted| {
		lower = wanted.with_ascii_lowercased()
		match asked.headers.find_first(|each| each.name == lower) {
			Ok(found) => Ok(found.value)
			Err(_) => Err(Missing)
		}
	}

	## The value of the cookie `wanted`, `%XX` decoded, if the request has it.
	cookie : Request, Str -> Try(Str, [Missing])
	cookie = |asked, wanted|
		match Server.header(asked, "cookie") {
			Ok(cookies) =>
				cookies.split_on(";").fold(
					Err(Missing),
					|found, pair|
						match found {
							Ok(_) => found
							Err(_) =>
								match pair.trim().split_first("=") {
									Ok({ before, after }) => if (before == wanted) Ok(percent_decoded(after)) else found
									Err(_) => found
								}
						},
				)
			Err(Missing) => Err(Missing)
		}

	## The request being answered: on the server, the one the host is answering (a page's, an
	## endpoint's, a server function's call); empty, a GET of `/`, anywhere else. The host hands it
	## over as text, so a body that isn't UTF-8 comes with U+FFFD where it isn't: an endpoint is
	## given its request's bytes as they came.
	request! : {} => Request
	request! = |{}| from_wire(Host.request!({}))

	## What the middleware in front of the server function being answered handed on (its
	## `context`), read as the type its body reads: `Server.context!({}).member`. Only a server
	## function's body has one, as the server answers its call: read anywhere else (a component, the
	## browser), it crashes. A context that isn't that type (a field the middleware doesn't hand on)
	## crashes too, naming the function: the server answers 500.
	context! : {} => c where [c.Json.Parseable([InvalidJson(Str)])]
	context! = |{}| {
		called = Host.serving!({})
		if called.is_empty() {
			crash "Server.context! is read in a server function's body, as the server answers its call: not in a component, nor in the browser"
		} else {
			match Json.parse(Host.context!({})) {
				Ok(context) => context
				Err(InvalidJson(why)) => crash "${called}: the context its middleware handed on isn't what it reads (${why})"
			}
		}
	}

	## The server's copy of a server function (`server!`), called `called`. Answering its own route
	## (`serve!`), it runs: the implementation, given the request. Anywhere else (a component the
	## server renders) it is a call of that route, which the host answers in-process, as the browser's
	## request would be answered: the same middleware, the same answer, noted for the page. An answer
	## that isn't 200 fails the caller, and the nearest <Errored> shows its status and text.
	local : Str, (Request, arg => result) -> (arg => result) where [arg.Json.Encodable([Infinity, NaN, NegativeInfinity, ..]), result.Json.Encodable([Infinity, NaN, NegativeInfinity, ..]), result.Json.Parseable([InvalidJson(Str)])]
	local = |called, implementation|
		|arg|
			if Host.serving!({}) == called {
				implementation(Server.request!({}), arg)
			} else {
				input =
					match Json.to_str_try(arg) {
						Ok(json) => json
						Err(_) => {
							Host.fail!("${called}: ${Server.unwritable}")
							crash "unreachable: fail! doesn't return"
						}
					}
				answer = Host.call!(called, input)
				match Json.parse(answer) {
					Ok(result) => {
						Host.record!(called, input, answer)
						result
					}
					Err(InvalidJson(why)) => {
						Host.fail!("${called} answered something else: ${why}")
						crash "unreachable: fail! doesn't return"
					}
				}
			}

	## The browser's copy: a request, by its name.
	remote : Str -> (arg => result) where [arg.Json.Encodable([Infinity, NaN, NegativeInfinity, ..]), result.Json.Parseable([InvalidJson(Str)])]
	remote = |called| |arg| Call.server!(called, arg)

	## The answer to a call of the server function `called` (`POST /rocx/call/<called>`, its input
	## the request's body, as JSON), past its middleware, which handed on `context`: 200 and its
	## answer, as JSON; 400 for input it can't read. The host is told which function it is serving
	## and the context (as JSON), so the function runs its body (`local`), and `context!` reads it.
	## rocx writes the calls (`Generated/ServerFunctions`).
	serve! : Str, Request, c, (arg => result) => Response where [c.Json.Encodable([Infinity, NaN, NegativeInfinity, ..]), arg.Json.Parseable([InvalidJson(Str)]), result.Json.Encodable([Infinity, NaN, NegativeInfinity, ..])]
	serve! = |called, asked, context, function|
		match Json.parse(Server.text_of(asked)) {
			Err(InvalidJson(why)) => Server.refused(400, "${called} can't read its input: ${why}")
			Ok(arg) =>
				match Json.to_str_try(context) {
					Err(_) => Server.refused(500, "${called}: the context its middleware handed on: ${Server.unwritable}")
					Ok(handed) => {
						Host.serve!(called, handed)
						result = function(arg)
						Host.serve!("", "")
						match Json.to_str_try(result) {
							Ok(json) => Server.response(200, [{ name: "content-type", value: "application/json" }], json)
							Err(_) => Server.refused(500, "${called}'s answer: ${Server.unwritable}")
						}
					}
				}
		}

	## Why a value can't be sent as JSON: it holds a number JSON has no way to write (an `F64` that is
	## NaN or an infinity). Any other `F64` is sent as a number, and read back as one.
	##
	## What crosses is `Json.Encodable([Infinity, NaN, NegativeInfinity, ..])` here, in `Call`,
	## `Endpoint` and `Browser`: an open union that already names the floats' failures, not a type
	## variable (`Encodable(e)`) or `[..]`. On this Roc, `Json.to_str_try` of a record or tuple
	## holding a nominal type with a derived `encoder_for` beside another field crashes the
	## compiler (`boxy_lowering`) unless the error type is given so
	## (test/compiler-bugs/json-to-str-try-nominal).
	unwritable : Str
	unwritable = "it holds a number JSON can't write (an F64 that is NaN or an infinity)"
}

## A request as the host passes it (`Host.request!`), as HTTP writes it: `METHOD target`, a header
## a line, a blank line, then its body (as text).
from_wire : Str -> Server.Request
from_wire = |given| {
	(head, body) =
		match given.split_first("\n\n") {
			Ok({ before, after }) => (before, after)
			Err(_) => (given, "")
		}
	(first, lines) =
		match head.split_first("\n") {
			Ok({ before, after }) => (before, after)
			Err(_) => (head, "")
		}
	match first.split_first(" ") {
		Ok({ before, after }) => Server.from_http(before, after, lines, body.to_utf8())
		Err(_) => Server.from_http("GET", "/", lines, body.to_utf8())
	}
}

## Sends a stream, on the thread the host runs it on: each event as the wire has it (`data: …`,
## then a blank line) through the host's `send!`, which says whether the page is still there; then,
## if it is, an `end` event, so a page that listens knows it is over, rather than asking again.
sent! : Events(Str), { send! : Str => Bool, sleep! : U64 => {} } => {}
sent! = |events, { send!, sleep! }| {
	ran = Events.run!(events, { send!: |item| if (send!(frame(item))) Ok({}) else Err(Gone), sleep! })
	match ran {
		Ok({}) => {
			_ = send!("event: end\ndata: \n\n")
			{}
		}
		Err(Gone) => {}
	}
}

## An event as the wire has it: a `data:` line for each of its lines, then a blank line.
frame : Str -> Str
frame = |text| Str.join_with(text.split_on("\n").map(|line| "data: ${line}\n"), "").concat("\n")

## The cookie a plain form's flash is kept in, between its post and its page (`Server.flash_back`).
flash_cookie : Str
flash_cookie = "rocx-flash"

## A flash as the cookie keeps it (JSON), or none.
flashed : Str -> Try({ url : Str, input : Str, status : U16, body : Str }, [NoFlash])
flashed = |given|
	if given.is_empty() {
		Err(NoFlash)
	} else {
		match Json.parse(given) {
			Ok(posted) => Ok(posted)
			Err(InvalidJson(_)) => Err(NoFlash)
		}
	}

## Where a plain form was posted from, if it was a page of this site (`Referer`'s path and query);
## `/` otherwise.
referrer : Server.Request -> Str
referrer = |asked|
	match Server.header(asked, "referer") {
		Ok(url) =>
			match url.split_first("://") {
				Ok({ after, .. }) => {
					(host, rest) =
						match after.split_first("/") {
							Ok({ before, after: path }) => (before, "/${path}")
							Err(_) => (after, "/")
						}
					if Server.header(asked, "host") == Ok(host) {
						match rest.split_first("#") {
							Ok({ before, .. }) => before
							Err(_) => rest
						}
					} else {
						"/"
					}
				}
				Err(_) => "/"
			}
		Err(Missing) => "/"
	}

## A form's field, as a browser encodes it: `+` a space, `%XX` a byte.
form_decoded : Str -> Str
form_decoded = |text| percent_decoded(Str.join_with(text.split_on("+"), " "))

upper_hex : List(U8)
upper_hex = "0123456789ABCDEF".to_utf8()

## A cookie's `Path` and `Domain`, as its options say.
placed : Server.CookieOpts -> Str
placed = |opts| {
	path = if (opts.path.is_empty()) "" else "; Path=${opts.path}"
	domain = if (opts.domain.is_empty()) "" else "; Domain=${opts.domain}"
	"${path}${domain}"
}

## A cookie's `Secure`, `HttpOnly` and `SameSite`, as its options say.
guarded : Server.CookieOpts -> Str
guarded = |opts| {
	secure = if (opts.secure) "; Secure" else ""
	http_only = if (opts.http_only) "; HttpOnly" else ""
	same_site =
		match opts.same_site {
			Lax => "Lax"
			Strict => "Strict"
			None => "None"
		}
	"${secure}${http_only}; SameSite=${same_site}"
}

## A moment (milliseconds since the epoch) as HTTP writes one: `Sun, 06 Nov 1994 08:49:37 GMT`, in
## UTC. The calendar is Howard Hinnant's civil-from-days.
http_date : U64 -> Str
http_date = |ms| {
	seconds = ms // 1000
	days = (seconds // 86400).to_i64_wrap()
	of_day = seconds % 86400
	z = days + 719468
	era = z // 146097
	doe = z - era * 146097
	yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	mp = (5 * doy + 2) // 153
	day = doy - (153 * mp + 2) // 5 + 1
	month = if (mp < 10) mp + 3 else mp - 9
	year = if (month <= 2) yoe + era * 400 + 1 else yoe + era * 400
	weekday = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"].get((days % 7).to_u64_wrap()) ?? "?"
	month_name = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].get((month - 1).to_u64_wrap()) ?? "?"
	"${weekday}, ${padded(day.to_u64_wrap(), 2)} ${month_name} ${padded(year.to_u64_wrap(), 4)} ${padded(of_day // 3600, 2)}:${padded(of_day % 3600 // 60, 2)}:${padded(of_day % 60, 2)} GMT"
}

## `value` in decimal, zero-padded to `width` digits.
padded : U64, U64 -> Str
padded = |value, width| {
	text = value.to_str()
	Str.concat(Str.repeat("0", width - U64.min(width, text.count_utf8_bytes())), text)
}

## `%XX` sequences as the bytes they stand for; anything else as it is.
percent_decoded : Str -> Str
percent_decoded = |text| {
	bytes = text.to_utf8()
	var $out = []
	var $at = 0.U64
	while $at < bytes.len() {
		byte = bytes.get($at) ?? 0
		decoded =
			if byte == '%' {
				match (hex_value(bytes.get($at + 1) ?? 0), hex_value(bytes.get($at + 2) ?? 0)) {
					(Ok(high), Ok(low)) => Ok(high * 16 + low)
					_ => Err(NotEscaped)
				}
			} else {
				Err(NotEscaped)
			}
		match decoded {
			Ok(value) => {
				$out = $out.append(value)
				$at = $at + 3
			}
			Err(_) => {
				$out = $out.append(byte)
				$at = $at + 1
			}
		}
	}
	Str.from_utf8_lossy($out)
}

hex_value : U8 -> Try(U8, [NotHex])
hex_value = |digit|
	if digit >= '0' and digit <= '9' {
		Ok(digit - '0')
	} else if digit >= 'a' and digit <= 'f' {
		Ok(digit - 'a' + 10)
	} else if digit >= 'A' and digit <= 'F' {
		Ok(digit - 'A' + 10)
	} else {
		Err(NotHex)
	}

expect Server.from_host("/p?q=1", "Cookie: a=1; user=Grace%20Hopper\nx-empty: \nbroken") == { method: "GET", path: "/p", query: "q=1", headers: [{ name: "cookie", value: "a=1; user=Grace%20Hopper" }, { name: "x-empty", value: "" }], body: [] }
expect Server.from_http("post", "/rocx/call/x", "", "{}".to_utf8()).method == "POST"
expect Server.text_of(Server.from_http("POST", "/", "", [0x22, 0xC3, 0xA9, 0xFF, 0x22])) == "\"é\u(FFFD)\""
expect Server.same_origin(Server.from_http("POST", "/", "origin: http://localhost:8080\nhost: localhost:8080", []))
expect !Server.same_origin(Server.from_http("POST", "/", "origin: https://evil.example\nhost: localhost:8080", []))
expect Server.same_origin(Server.from_http("POST", "/", "host: localhost:8080", []))
expect Server.encode_segment("Ada Lovelace/1") == "Ada%20Lovelace%2F1"
expect Server.form_json("name=Ada+Lovelace&plan=a%26b&empty=") == "{\"name\":\"Ada Lovelace\",\"plan\":\"a&b\",\"empty\":\"\"}"
expect Server.changes(Server.from_http("DELETE", "/", "", [])) and !Server.changes(Server.from_host("/", ""))
expect Server.with_cookie(Server.redirect("/members"), "member", "Ada L").headers == [{ name: "location", value: "/members" }, { name: "set-cookie", value: "member=Ada%20L; Path=/; HttpOnly; SameSite=Lax" }]
expect Server.without_cookie(Server.redirect("/"), "member").headers == [{ name: "location", value: "/" }, { name: "set-cookie", value: "member=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0" }]
expect Server.set_cookie(Server.redirect("/"), "__Host-session", "t/1", { ..Server.cookie_defaults, secure: Bool.True, max_age_s: 30 * 86_400 }).headers == [{ name: "location", value: "/" }, { name: "set-cookie", value: "__Host-session=t%2F1; Path=/; Max-Age=2592000; Secure; HttpOnly; SameSite=Lax" }]
expect Server.set_cookie(Server.redirect("/"), "org", "7", { max_age_s: 0, expires_ms: 784111777000, secure: Bool.False, http_only: Bool.False, same_site: Strict, path: "", domain: "example.com" }).headers == [{ name: "location", value: "/" }, { name: "set-cookie", value: "org=7; Domain=example.com; Expires=Sun, 06 Nov 1994 08:49:37 GMT; SameSite=Strict" }]
expect Server.clear_cookie(Server.redirect("/"), "__Host-session", { ..Server.cookie_defaults, secure: Bool.True, same_site: None, max_age_s: 60 }).headers == [{ name: "location", value: "/" }, { name: "set-cookie", value: "__Host-session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=None" }]
expect http_date(0) == "Thu, 01 Jan 1970 00:00:00 GMT"
expect http_date(951782400000) == "Tue, 29 Feb 2000 00:00:00 GMT"
expect http_date(4102444799999) == "Thu, 31 Dec 2099 23:59:59 GMT"
expect Server.decode_segment(Server.encode_segment("zażółć & co")) == "zażółć & co"
expect Server.cookie(Server.from_host("/", "cookie: a=1; user=Grace%20Hopper%zz"), "user") == Ok("Grace Hopper%zz")
expect Server.cookie(Server.from_host("/", "cookie: a=1"), "user") == Err(Missing)
expect Server.header(Server.from_host("/", "X-Thing: yes"), "x-thing") == Ok("yes")
expect frame("one\ntwo") == "data: one\ndata: two\n\n"
expect Server.for_host(Server.redirect("/")).kind == 0
expect Server.for_host(Server.events(Events.from_list(["a"], 0))).kind == 2
expect Server.for_host(Server.events(Events.none({}))).kind == 0
expect Server.for_host(Server.refused(404, "gone")).text == "gone"
expect Server.for_host(Server.bytes(200, [{ name: "content-type", value: "image/png" }], [0x89, 0x50, 0x00, 0xFF])).kind == 3
expect Server.for_host(Server.bytes(200, [{ name: "content-type", value: "image/png" }], [0x89, 0x50, 0x00, 0xFF])).bytes == [0x89, 0x50, 0x00, 0xFF]
expect Server.for_host(Server.bytes(200, [{ name: "content-type", value: "image/png" }], [0x89, 0x50, 0x00, 0xFF])).headers == "content-type: image/png"
expect Server.for_host(Server.forward({ method: "GET", url: "http://s3/b/k", headers: [{ name: "x-amz-date", value: "20261121T000000Z" }, { name: "authorization", value: "AWS4 …" }] }, [{ name: "cache-control", value: "private" }])).kind == 4
expect Server.for_host(Server.forward({ method: "GET", url: "http://s3/b/k", headers: [{ name: "x-amz-date", value: "20261121T000000Z" }, { name: "authorization", value: "AWS4 …" }] }, [{ name: "cache-control", value: "private" }])).upstream == { method: "GET", url: "http://s3/b/k", headers: "x-amz-date: 20261121T000000Z\nauthorization: AWS4 …" }
expect Server.for_host(Server.forward({ method: "GET", url: "http://s3/b/k", headers: [] }, [{ name: "cache-control", value: "private" }])).headers == "cache-control: private"
expect Server.for_host(Server.redirect("/")).upstream == { method: "", url: "", headers: "" }
expect Server.passed_on(Server.from_host("/v", "Range: bytes=0-9\ncookie: a=1\nif-none-match: \"v1\"")) == [{ name: "range", value: "bytes=0-9" }, { name: "if-none-match", value: "\"v1\"" }]
expect Server.passed_on(Server.from_host("/v", "cookie: a=1")) == []
expect Server.form_fields("name=Ada+L&plan=a%26b&&empty=&bare") == [{ name: "name", value: "Ada L" }, { name: "plan", value: "a&b" }, { name: "empty", value: "" }, { name: "bare", value: "" }]
expect referrer(Server.from_http("POST", "/join", "host: localhost:8080\nreferer: http://localhost:8080/members/join?x=1#form", [])) == "/members/join?x=1"
expect referrer(Server.from_http("POST", "/join", "host: localhost:8080\nreferer: http://localhost:8080", [])) == "/"
expect referrer(Server.from_http("POST", "/join", "host: localhost:8080\nreferer: https://evil.example/members", [])) == "/"
expect referrer(Server.from_http("POST", "/join", "host: localhost:8080", [])) == "/"
expect Server.flash_back(Server.from_http("POST", "/join", "host: h\nreferer: http://h/j", []), { url: "/join", input: "name=", status: 400, body: "a name" }).headers == [{ name: "location", value: "/j" }, { name: "set-cookie", value: "rocx-flash=%7B%22body%22%3A%22a%20name%22%2C%22input%22%3A%22name%3D%22%2C%22status%22%3A400%2C%22url%22%3A%22%2Fjoin%22%7D; Path=/; Max-Age=60; HttpOnly; SameSite=Lax" }]
expect Server.flash_back(Server.from_http("POST", "/join", "", []), { url: "/join", input: Str.repeat("x", 5000), status: 400, body: "long" }).headers.get(1).map_ok(|header| header.value.contains("xxx")) == Ok(Bool.False)
expect flashed("{\"url\":\"/join\",\"input\":\"name=Ada\",\"status\":400,\"body\":\"no\"}") == Ok({ url: "/join", input: "name=Ada", status: 400, body: "no" })
expect flashed("") == Err(NoFlash) and flashed("{") == Err(NoFlash)
expect Server.clear_flash(Server.from_http("GET", "/j", "accept: text/html\ncookie: rocx-flash=x", []), Server.redirect("/")).headers.len() == 2
expect Server.clear_flash(Server.from_http("GET", "/j", "accept: text/html", []), Server.redirect("/")).headers.len() == 1
expect Server.clear_flash(Server.from_http("POST", "/j", "accept: text/html\ncookie: rocx-flash=x", []), Server.redirect("/")).headers.len() == 1
expect Server.explain(Refused(400, "a name")) == "a name"
expect Server.for_host({ status: 404, headers: [], body: Page(|{}| Html.text("hi")) }).kind == 1
expect Server.for_host({ status: 404, headers: [], body: Page(|{}| Html.text("hi")) }).status == 404
expect Server.for_host({ status: 200, headers: [{ name: "set-cookie", value: "a=1" }], body: Page(|{}| Html.text("hi")) }).headers == "set-cookie: a=1\ncontent-type: text/html; charset=utf-8"
expect Server.for_host({ status: 200, headers: [{ name: "Content-Type", value: "application/xhtml+xml" }], body: Page(|{}| Html.text("hi")) }).headers == "Content-Type: application/xhtml+xml"
expect Server.body_text(Server.refused(401, "members only")) == "members only"
expect Server.body_text(Server.events(Events.none({}))) == ""
expect Server.body_text(Server.bytes(200, [], "ok".to_utf8())) == "ok"
expect from_wire("POST /rocx/call/Demos/Echo.echo?x=1\ncookie: member=Ada\ncontent-type: application/json\n\n\"hi\"\n\nmore") == { method: "POST", path: "/rocx/call/Demos/Echo.echo", query: "x=1", headers: [{ name: "cookie", value: "member=Ada" }, { name: "content-type", value: "application/json" }], body: "\"hi\"\n\nmore".to_utf8() }
expect from_wire("GET /about") == { method: "GET", path: "/about", query: "", headers: [], body: [] }
expect from_wire("") == { method: "GET", path: "/", query: "", headers: [], body: [] }
