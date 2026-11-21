import Host
import HttpResponse
import Server

## Requests to other servers over HTTP/1.1, plain or over TLS (`https`, the server's certificate
## checked against the web's certificate authorities): an API, an OAuth server, S3. One effect makes
## them, `Http.fetch!(url, init)`, as JS's `fetch` does; `init` says what isn't a plain GET, each
## field left out has its default, and `{}` is a GET:
##
##     weather = Http.fetch!("${api}/forecast", { query: [("city", city)] })?.json()?
##     Http.fetch!(url, { method: Post, body: Http.json(order) })?
##
## The host makes each request (`server/host/src/client.rs`), waiting on the call's thread, as `Db`
## and `Tcp` do. Any status is an answer (`Ok`, an `HttpResponse`): a 404 or a 500 is the other
## server's to give, and `res.ok` says whether it is a success. An `Err` means there was none: it
## couldn't be reached, TLS failed, or it broke off (`HttpErr`); it didn't answer whole in time
## (`TimedOut`); its body was larger than allowed (`TooLarge`).
##
## `Request`, `Response`, `Opts`, `defaults`, `send!`, `send_request!`, `get`, `post_form`,
## `post_json`, `with_header`, `header` and `text` are the API before `fetch!` (D-024), kept for the
## apps that use them, deprecated: each is `fetch!` underneath.
Http := [].{

	## A request's method: `Get` unless `init` says otherwise. `Other("PROPFIND")` is any other,
	## sent as written.
	Method : [Get, Post, Put, Patch, Delete, Head, Options, Other(Str)]

	## What a request sends: `Empty` (no body: the default), or what `Http.json`, `Http.form`,
	## `Http.plain_text` or `Http.bytes` make of a value, with its `content-type`.
	Body := [Empty, Json(Str), Form(List((Str, Str))), PlainText(Str), Bytes(List(U8))]

	## How a request is made (`fetch!`'s `init`), as `fetch`'s `RequestInit` says; any field may be
	## left out:
	##
	## - `method`: `Get`;
	## - `headers`: each `(name, value)`, sent as given (and a `content-type` given wins over the
	##   body's);
	## - `query`: `(name, value)` pairs, each percent-encoded, added to the URL's query (after a `&`
	##   if it has one already);
	## - `body`: `Empty`;
	## - `timeout_ms`: how long it may take, from connecting to the last byte of its answer: 30 s
	##   (0: no limit);
	## - `max_bytes`: how large its answer's body may be: 64 MiB (0: any size);
	## - `redirect`: `Follow` one, as `fetch` follows it (a 303 becomes a GET, credentials don't go
	##   to another origin, 20 at most), or `Manual`: the redirect is the answer.
	##
	## A record says some, as `{ method: Delete }`. One kept to build on is an `Http.Init`
	## (`authed : Http.Init`), so a record update can add to it: `{ ..authed, method: Delete }`.
	Init := {
		method : Method ?? Get,
		headers : List((Str, Str)) ?? [],
		query : List((Str, Str)) ?? [],
		body : Body ?? Empty,
		timeout_ms : U64 ?? 30_000,
		max_bytes : U64 ?? 67_108_864,
		redirect : [Follow, Manual] ?? Follow,
	}

	## Makes a request to `url`, as `init` says (`{}`: a GET, as `fetch(url)` makes), and reads its
	## answer whole: any status is `Ok` (`res.ok` if it is 2xx). `Err(HttpErr(why))` with no answer:
	## no server there, TLS that failed, a URL that isn't `http` or `https`, or a header that can't
	## be sent (a line break in it, or a colon in its name); `Err(TimedOut)`, no whole answer within
	## `timeout_ms`; `Err(TooLarge)`, a body over `max_bytes`.
	##
	##     authed : Http.Init
	##     authed = { headers: [("authorization", "Bearer ${token}")] }
	##     res = Http.fetch!("${api}/notes/${id}", { ..authed, method: Delete })?
	fetch! : Str, Init => Try(HttpResponse, [HttpErr(Str), TimedOut, TooLarge])
	fetch! = |url, init| {
		(content_type, payload) = sent(init.body)
		given = init.headers
		headers = if (content_type.is_empty() or given.any(|(name, _)| name.with_ascii_lowercased() == "content-type")) given else given.append(("content-type", content_type))
		follow =
			match init.redirect {
				Follow => Bool.True
				Manual => Bool.False
			}
		match header_lines(headers) {
			Err(why) => Err(HttpErr(why))
			Ok(lines) =>
				match Host.http_send!(method_name(init.method), with_query(url, init.query), lines, payload, init.timeout_ms, init.max_bytes, follow) {
					Ok(answer) => Ok(HttpResponse.new(answer.status, parsed(answer.headers), answer.body))
					Err("timed out") => Err(TimedOut)
					Err("too large") => Err(TooLarge)
					Err(why) => Err(HttpErr(why))
				}
		}
	}

	## `value` as JSON (`Json.to_str`), `content-type: application/json`: `{ method: Post, body:
	## Http.json(order) }`.
	json : a -> Body where [a.Json.Encodable([])]
	json = |value| Json(Json.to_str(value))

	## A form's fields, each percent-encoded, `content-type: application/x-www-form-urlencoded`: what
	## OAuth's token endpoints take.
	form : List((Str, Str)) -> Body
	form = |fields| Form(fields)

	## Text, UTF-8, `content-type: text/plain; charset=utf-8`.
	plain_text : Str -> Body
	plain_text = |said| PlainText(said)

	## Bytes as they are, with no `content-type` (as `fetch` sends a `Uint8Array`): a header says
	## one, as `{ headers: [("content-type", "image/png")], body: Http.bytes(png) }`.
	bytes : List(U8) -> Body
	bytes = |data| Bytes(data)

	# ---- Deprecated: the API before `fetch!` (D-024), each `fetch!` underneath ----

	## deprecated: use `Http.fetch!`, with an `Http.Init`. A request: its method, URL, headers and
	## body.
	Request : { method : Str, url : Str, headers : List({ name : Str, value : Str }), body : List(U8) }

	## deprecated: use `Http.fetch!`, whose answer is an `HttpResponse`. An answer: its status,
	## headers and body.
	Response : { status : U16, headers : List({ name : Str, value : Str }), body : List(U8) }

	## deprecated: use `Http.fetch!`'s `init` (`timeout_ms`, `max_bytes`, `redirect`). How long a
	## request may take (0: no limit), how large its answer may be (0: any size), and whether a
	## redirect is followed.
	Opts : { timeout_ms : U64, max_bytes : U64, follow_redirects : Bool }

	## deprecated: use `Http.fetch!`, whose `init` has these defaults. 30 seconds, 64 MiB,
	## redirects followed.
	defaults : Opts
	defaults = { timeout_ms: 30_000, max_bytes: 67_108_864, follow_redirects: Bool.True }

	## deprecated: use `Http.fetch!`. Makes `request` as `opts` say: `fetch!` with the request's
	## method (as written), headers and bytes.
	send! : Request, Opts => Try(Response, [HttpErr(Str), TimedOut, TooLarge])
	send! = |request, opts| {
		init : Init
		init = {
			method: method_of(request.method),
			headers: request.headers.map(|each| (each.name, each.value)),
			body: Bytes(request.body),
			timeout_ms: opts.timeout_ms,
			max_bytes: opts.max_bytes,
			redirect: if (opts.follow_redirects) Follow else Manual,
		}
		res = Http.fetch!(request.url, init)?
		Ok({ status: res.status, headers: res.headers.map(|(name, value)| { name, value }), body: res.body })
	}

	## deprecated: use `Http.fetch!` (this was `fetch!` before it). `send!` with `defaults`.
	send_request! : Request => Try(Response, [HttpErr(Str), TimedOut, TooLarge])
	send_request! = |request| Http.send!(request, Http.defaults)

	## deprecated: use `Http.fetch!(url, {})`. A GET of `url`.
	get : Str -> Request
	get = |url| { method: "GET", url, headers: [], body: [] }

	## deprecated: use `Http.fetch!(url, { method: Post, body: Http.form(fields) })`. A POST of a
	## form's fields.
	post_form : Str, List((Str, Str)) -> Request
	post_form = |url, fields| { method: "POST", url, headers: [{ name: "content-type", value: "application/x-www-form-urlencoded" }], body: encoded(fields).to_utf8() }

	## deprecated: use `Http.fetch!(url, { method: Post, body: Http.json(value) })`. A POST of
	## JSON, as text.
	post_json : Str, Str -> Request
	post_json = |url, json_text| { method: "POST", url, headers: [{ name: "content-type", value: "application/json" }], body: json_text.to_utf8() }

	## deprecated: use `Http.fetch!`'s `headers`. The request with one more header.
	with_header : Request, Str, Str -> Request
	with_header = |request, name, value| { ..request, headers: request.headers.append({ name, value }) }

	## deprecated: use `res.header(name)` on `Http.fetch!`'s answer. The first header called `name`
	## (in any case).
	header : Response, Str -> Try(Str, [Missing])
	header = |response, name| HttpResponse.new(response.status, response.headers.map(|each| (each.name, each.value)), []).header(name)

	## deprecated: use `res.text()` on `Http.fetch!`'s answer. The body as UTF-8 (lossy).
	text : Response -> Str
	text = |response| Str.from_utf8_lossy(response.body)
}

## What a body sends: its `content-type` ("": none) and its bytes.
sent : Http.Body -> (Str, List(U8))
sent = |body|
	match body {
		Empty => ("", [])
		Json(json_text) => ("application/json", json_text.to_utf8())
		Form(fields) => ("application/x-www-form-urlencoded", encoded(fields).to_utf8())
		PlainText(said) => ("text/plain; charset=utf-8", said.to_utf8())
		Bytes(data) => ("", data)
	}

## Pairs as a query or a form writes them: `name=value`, each percent-encoded, joined by `&`.
encoded : List((Str, Str)) -> Str
encoded = |pairs| Str.join_with(pairs.map(|(name, value)| "${Server.encode_segment(name)}=${Server.encode_segment(value)}"), "&")

## `url` with `pairs` added to its query: after a `?`, or a `&` if it has a query already, and
## before its fragment.
with_query : Str, List((Str, Str)) -> Str
with_query = |url, pairs|
	if pairs.is_empty() {
		url
	} else {
		(before, fragment) =
			match url.split_first("#") {
				Ok({ before: start, after }) => (start, "#${after}")
				Err(_) => (url, "")
			}
		joined =
			if !before.contains("?") {
				"${before}?${encoded(pairs)}"
			} else if before.ends_with("?") or before.ends_with("&") {
				"${before}${encoded(pairs)}"
			} else {
				"${before}&${encoded(pairs)}"
			}
		"${joined}${fragment}"
	}

## A method as HTTP writes it.
method_name : Http.Method -> Str
method_name = |method|
	match method {
		Get => "GET"
		Post => "POST"
		Put => "PUT"
		Patch => "PATCH"
		Delete => "DELETE"
		Head => "HEAD"
		Options => "OPTIONS"
		Other(written) => written
	}

## A method as the deprecated `Request` writes it: one of `Method`'s, or `Other` as written.
method_of : Str -> Http.Method
method_of = |written|
	match written {
		"GET" => Get
		"POST" => Post
		"PUT" => Put
		"PATCH" => Patch
		"DELETE" => Delete
		"HEAD" => Head
		"OPTIONS" => Options
		_ => Other(written)
	}

## The headers as the host takes them, a `name: value` a line; a line break in one would make
## another, so it is refused.
header_lines : List((Str, Str)) -> Try(Str, Str)
header_lines = |headers| {
	breaks = |said| said.contains("\n") or said.contains("\r")
	match headers.find_first(|(name, value)| breaks(name) or breaks(value) or name.contains(":")) {
		Ok((bad, _)) => Err("the header ${Json.to_str(bad)} has a line break or a colon in it")
		Err(_) => Ok(Str.join_with(headers.map(|(name, value)| "${name}: ${value}"), "\n"))
	}
}

## The answer's headers, from the host's `name: value` lines.
parsed : Str -> List((Str, Str))
parsed = |lines|
	lines.split_on("\n").keep_if(|line| !line.is_empty()).map(
		|line|
			match line.split_first(": ") {
				Ok({ before, after }) => (before, after)
				Err(_) => (line, "")
			},
	)

expect with_query("https://example.com/a", []) == "https://example.com/a"
expect with_query("https://example.com/forecast", [("city", "São Paulo"), ("days", "3")]) == "https://example.com/forecast?city=S%C3%A3o%20Paulo&days=3"
expect with_query("https://example.com/a?b=1", [("c", "a&b=c")]) == "https://example.com/a?b=1&c=a%26b%3Dc"
expect with_query("https://example.com/a?", [("c", "1")]) == "https://example.com/a?c=1"
expect with_query("https://example.com/a?b=1&", [("c", "1")]) == "https://example.com/a?b=1&c=1"
expect with_query("https://example.com/a#top", [("c", "1")]) == "https://example.com/a?c=1#top"
expect with_query("https://example.com/a?b=1#top", [("c", "1")]) == "https://example.com/a?b=1&c=1#top"
expect sent(Http.json({ a: 1.U8, b: "x" })) == ("application/json", "{\"a\":1,\"b\":\"x\"}".to_utf8())
expect sent(Http.form([("grant_type", "authorization_code"), ("code", "a b&c")])) == ("application/x-www-form-urlencoded", "grant_type=authorization_code&code=a%20b%26c".to_utf8())
expect sent(Http.plain_text("héllo")) == ("text/plain; charset=utf-8", "héllo".to_utf8())
expect sent(Http.bytes([0, 255])) == ("", [0, 255])
expect sent(Empty) == ("", [])
expect method_name(Delete) == "DELETE"
expect method_name(Other("PROPFIND")) == "PROPFIND"
expect method_of("PATCH") == Patch
expect method_of("purge") == Other("purge")
expect header_lines([("a", "1"), ("b", "2")]) == Ok("a: 1\nb: 2")
expect header_lines([("a", "1\r\nx-injected: yes")]).is_err()
expect header_lines([("a:b", "1")]).is_err()
expect parsed("content-type: text/plain\nx-empty: ") == [("content-type", "text/plain"), ("x-empty", "")]
expect Http.get("https://example.com/a").method == "GET"
expect Http.post_form("https://example.com", [("grant_type", "authorization_code"), ("code", "a b&c")]).body == "grant_type=authorization_code&code=a%20b%26c".to_utf8()
expect Http.post_json("https://example.com", "{}").headers == [{ name: "content-type", value: "application/json" }]
expect Http.with_header(Http.get("https://example.com"), "authorization", "Bearer x").headers == [{ name: "authorization", value: "Bearer x" }]
expect Http.header({ status: 200, headers: [{ name: "content-type", value: "text/plain" }, { name: "x-empty", value: "" }], body: [] }, "Content-Type") == Ok("text/plain")
expect Http.header({ status: 200, headers: [{ name: "x-empty", value: "" }], body: [] }, "x-empty") == Ok("")
expect Http.header({ status: 200, headers: [], body: [] }, "location") == Err(Missing)
expect Http.text({ status: 200, headers: [], body: [104, 105] }) == "hi"
