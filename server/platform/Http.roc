import Host
import Server

## Requests to other servers over HTTP/1.1, plain or over TLS (`https`, the server's certificate
## checked against the web's certificate authorities): an API, an OAuth server, S3. The host makes
## each (`server/host/src/client.rs`), waiting on the call's thread, as `Db` and `Tcp` do.
##
## Any status is an answer (`Ok`): a 404 or a 500 is the other server's to give. An `Err` means
## there was none: it couldn't be reached, TLS failed, or it broke off (`HttpErr`); it didn't answer
## whole in time (`TimedOut`); its body was larger than allowed (`TooLarge`).
Http := [].{

	Request : { method : Str, url : Str, headers : List({ name : Str, value : Str }), body : List(U8) }

	Response : { status : U16, headers : List({ name : Str, value : Str }), body : List(U8) }

	## How long a request may take, from connecting to the last byte of its answer (0: no limit);
	## how large its answer's body may be (0: any size); whether a redirect is followed, as
	## `fetch` follows one (a 303 becomes a GET, credentials don't go to another origin), or is
	## the answer.
	Opts : { timeout_ms : U64, max_bytes : U64, follow_redirects : Bool }

	## 30 seconds, 64 MiB, redirects followed.
	defaults : Opts
	defaults = { timeout_ms: 30_000, max_bytes: 67_108_864, follow_redirects: Bool.True }

	send! : Request, Opts => Try(Response, [HttpErr(Str), TimedOut, TooLarge])
	send! = |request, opts|
		match header_lines(request.headers) {
			Err(why) => Err(HttpErr(why))
			Ok(lines) =>
				match Host.http_send!(request.method, request.url, lines, request.body, opts.timeout_ms, opts.max_bytes, opts.follow_redirects) {
					Ok(answer) => Ok({ status: answer.status, headers: parsed(answer.headers), body: answer.body })
					Err("timed out") => Err(TimedOut)
					Err("too large") => Err(TooLarge)
					Err(why) => Err(HttpErr(why))
				}
		}

	## `send!` with `defaults`.
	fetch! : Request => Try(Response, [HttpErr(Str), TimedOut, TooLarge])
	fetch! = |request| Http.send!(request, Http.defaults)

	get : Str -> Request
	get = |url| { method: "GET", url, headers: [], body: [] }

	## A form's fields, `application/x-www-form-urlencoded`: what OAuth's token endpoints take.
	post_form : Str, List((Str, Str)) -> Request
	post_form = |url, fields| {
		encoded = Str.join_with(fields.map(|(name, value)| "${Server.encode_segment(name)}=${Server.encode_segment(value)}"), "&")
		{ method: "POST", url, headers: [{ name: "content-type", value: "application/x-www-form-urlencoded" }], body: encoded.to_utf8() }
	}

	## JSON (`Json.to_str(value)` makes some).
	post_json : Str, Str -> Request
	post_json = |url, json| { method: "POST", url, headers: [{ name: "content-type", value: "application/json" }], body: json.to_utf8() }

	## The request with one more header: `Http.with_header(Http.get(url), "authorization", "Bearer …")`.
	with_header : Request, Str, Str -> Request
	with_header = |request, name, value| { ..request, headers: request.headers.append({ name, value }) }

	## The first header called `name` (in any case).
	header : Response, Str -> Try(Str, [Missing])
	header = |response, name| {
		wanted = name.with_ascii_lowercased()
		match response.headers.find_first(|each| each.name.with_ascii_lowercased() == wanted) {
			Ok(found) => Ok(found.value)
			Err(_) => Err(Missing)
		}
	}

	## The body as UTF-8 (lossy).
	text : Response -> Str
	text = |response| Str.from_utf8_lossy(response.body)
}

## The headers as the host takes them, a `name: value` a line; a line break in one would make
## another, so it is refused.
header_lines : List({ name : Str, value : Str }) -> Try(Str, Str)
header_lines = |headers| {
	breaks = |text| text.contains("\n") or text.contains("\r")
	match headers.find_first(|each| breaks(each.name) or breaks(each.value) or each.name.contains(":")) {
		Ok(bad) => Err("the header ${Json.to_str(bad.name)} has a line break or a colon in it")
		Err(_) => Ok(Str.join_with(headers.map(|each| "${each.name}: ${each.value}"), "\n"))
	}
}

## The answer's headers, from the host's `name: value` lines.
parsed : Str -> List({ name : Str, value : Str })
parsed = |lines|
	lines.split_on("\n").keep_if(|line| !line.is_empty()).map(
		|line|
			match line.split_first(": ") {
				Ok({ before, after }) => { name: before, value: after }
				Err(_) => { name: line, value: "" }
			},
	)

expect Http.get("https://example.com/a").method == "GET"
expect Http.post_form("https://example.com", [("grant_type", "authorization_code"), ("code", "a b&c")]).body == "grant_type=authorization_code&code=a%20b%26c".to_utf8()
expect Http.post_json("https://example.com", "{}").headers == [{ name: "content-type", value: "application/json" }]
expect Http.with_header(Http.get("https://example.com"), "authorization", "Bearer x").headers == [{ name: "authorization", value: "Bearer x" }]
expect Http.header({ status: 200, headers: parsed("content-type: text/plain\nx-empty: "), body: [] }, "Content-Type") == Ok("text/plain")
expect Http.header({ status: 200, headers: parsed("content-type: text/plain\nx-empty: "), body: [] }, "x-empty") == Ok("")
expect Http.header({ status: 200, headers: [], body: [] }, "location") == Err(Missing)
expect header_lines([{ name: "a", value: "1" }, { name: "b", value: "2" }]) == Ok("a: 1\nb: 2")
expect header_lines([{ name: "a", value: "1\r\nx-injected: yes" }]).is_err()
