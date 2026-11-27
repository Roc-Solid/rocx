import Host
import Html
import Events
import FlashStore

## The server: what it knows about a request, and how it answers. An app's `respond!` gets each
## request from its platform (`from_http`) and gives back the answer; its routes, endpoints and
## middleware (rocx writes them from `routes/`) take and make these in between. A component talks to
## the server through endpoints (`Endpoint`).
Server := [].{

	## What the server knows about a request: its method, its path and query, its headers (cookies
	## among them) and its body, the bytes as they came (`text_of` reads them as text: JSON, a form).
	## A page has the request it was rendered for; an endpoint, the request it came in.
	##
	## `route` is the route that answers it, as its route file's directory names it (`/blog/[slug]`,
	## `/` for routes/ itself), whatever the params: what a metric or a log line groups requests by,
	## where the path would make a group for every post. A request nothing answers (the error page)
	## has `""`. The server sets it before the app's middleware runs;
	## a request made by hand (`from_http`), and the browser's, have `""`.
	##
	## `peer` is the address of the connection it came on, as the host saw it (`203.0.113.7`, `::1`):
	## the client's, or a proxy's in front of the server, whose `X-Forwarded-For` says the client's
	## (packages/guard's `ClientIp` reads that as far as the app trusts its proxies). A GET a page
	## reads as the server renders it has the page's. `""` in the browser, and in a request made by
	## hand (`from_http`).
	Request : { method : Str, path : Str, query : Str, headers : List({ name : Str, value : Str }), body : List(U8), route : Str, peer : Str }

	## The server's answer to a request: its status, its headers and its body.
	Response : { status : U16, headers : List({ name : Str, value : Str }), body : Body }

	## What an answer sends after its status and headers: text (HTML, JSON, why it refused); bytes
	## (an image, a file: `Server.bytes`); a page of components, which the server renders, a document
	## for the browser to hydrate; a stream of events (`Server.events`); a body the server fetches
	## from elsewhere and sends on as it comes (`Server.forward`); or an object the server keeps
	## (`Server.stored`: packages/storage's `file:` and `memory:` buckets, D-047).
	Body : [Text(Str), Bytes(List(U8)), Page({} => Html), Events(Events(Str)), Forward(Upstream), Stored({ root : Str, key : Str, asked : List({ name : Str, value : Str }) })]

	## Where a forwarded answer's body comes from (`Server.forward`): the request the server makes
	## for it, its method, URL and headers (keys and all: packages/storage's `Storage.serve!` signs one
	## for an S3 bucket).
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
		{ method: method.with_ascii_uppercased(), path: path, query: query, headers: headers, body: body, route: "", peer: "" }
	}

	## The answer as the server platform's host takes it: its headers a `name: value` a line, and its
	## `kind`, which says which of the rest it sends:
	##
	## - 0, `text`;
	## - 1, the page (`page`), which the host renders, as HTML unless the answer says otherwise;
	## - 2, the stream (`feed`): a loop the host runs as a call of its own, with its `send!` and
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
			# A stored object rides in the upstream's fields: its root, its key, and what the request asks of it.
			Stored(object) => { status: answered.status, headers, kind: 5, text: "", bytes: [], upstream: { method: object.root, url: object.key, headers: lines(object.asked) }, page: |{}| Html.empty({}), feed: |_| {} }
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
	## through Roc: a file in S3 (packages/storage's `Storage.serve!`), a video of 500 MB. Upstream's status is the
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

	## An answer whose body is the object at `key` under `root` (`Blobs`: `file:<dir>`,
	## `memory:<name>`), sent by the server as it is, never through Roc: 200 with its length, type
	## (its own, unless `headers` say another), ETag and `last-modified`; 206 for the request's
	## `Range` (one range; 416 for one past its end); 304 for an `If-None-Match` its ETag meets; 404
	## when there is none. The range and the ETag asked about are `request`'s, as its record has them
	## (`passed_on`), so an app may drop or change them first. `headers` are added, or replace those
	## (`cache-control`). The answer's own `status` (200) is a stand-in.
	stored : Str, Str, Request, List({ name : Str, value : Str }) -> Response
	stored = |root, key, request, headers| { status: 200, headers: headers, body: Stored({ root, key, asked: Server.passed_on(request) }) }

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
	##   `SameSite=None`, is dropped by the browser without it. The server platform makes every cookie
	##   `Secure` anyway when the app's public URL is HTTPS (D-123: `secure_cookies`), so leaving it
	##   off is for development over HTTP.
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

	## The answer, every cookie it sets `Secure` (sent back over HTTPS alone): those that say so
	## already as they are. The server platform answers every request through it when the app's public
	## URL is HTTPS (D-123), as SvelteKit makes its cookies `secure` but on `http://localhost`.
	secure_cookies : Response -> Response
	secure_cookies = |answer| {
		says_secure = |value| value.split_on(";").any(|part| part.trim().with_ascii_lowercased() == "secure")
		{ ..answer, headers: answer.headers.map(|line| if (line.name.with_ascii_lowercased() == "set-cookie" and !says_secure(line.value)) { name: line.name, value: "${line.value}; Secure" } else line) }
	}

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

	## A file a form sent (`multipart/form-data`: a form with an `<input type="file">`, or an action
	## given a file the page picked, dropped or pasted, D-054): the field it came as, its name as the
	## browser gave it, its type, and its bytes. In the endpoint's arg, its field is its name (a
	## `Str`); `Server.file` reads the rest, and packages/storage keeps it (`Storage.put_upload!`). A
	## request's body is read whole (16 MiB at most unless `--max-body` says more), files and all.
	Upload : { field : Str, name : Str, type : Str, bytes : List(U8) }

	## The files a form sent with its fields (`multipart/form-data`), in the order they came; none
	## for any other body.
	files : Request -> List(Upload)
	files = |request|
		match Server.multipart(request) {
			Ok(parts) => parts.files
			Err(NotMultipart) => []
		}

	## The file sent as `field` (the first, if several), or `Err(NoFile)`: none was, or the field's
	## file input was left empty (a browser sends a part with no name and no bytes).
	file : Request, Str -> Try(Upload, [NoFile])
	file = |request, field|
		match Server.files(request).find_first(|upload| upload.field == field and !(upload.name.is_empty() and upload.bytes.is_empty())) {
			Ok(found) => Ok(found)
			Err(_) => Err(NoFile)
		}

	## A `multipart/form-data` body as its parts: each text part a field, as `form_fields` reads a
	## URL-encoded body; each part with a `filename` an upload, its field's value its name (as the
	## browser's `URLSearchParams` of the form's data gives it). `Err(NotMultipart)` for any other
	## body, or one without its boundary.
	multipart : Request -> Try({ fields : List({ name : Str, value : Str }), files : List(Upload) }, [NotMultipart])
	multipart = |request| {
		boundary =
			match boundary_of(Server.header(request, "content-type") ?? "") {
				Ok(found) => found
				Err(NotMultipart) => return Err(NotMultipart)
			}
		delimiter = "--${boundary}".to_utf8()
		closing = ['\r', '\n'].concat(delimiter)
		body = request.body
		var $at =
			match found_at(body, delimiter, 0) {
				Ok(first) => first + delimiter.len()
				Err(NotFound) => return Err(NotMultipart)
			}
		var $fields = []
		var $files = []
		var $going = Bool.True
		while $going {
			# After a delimiter: `--`, the end; else its line's end, then a part to the next one.
			if body.sublist({ start: $at, len: 2 }) == ['-', '-'] {
				$going = Bool.False
			} else {
				start =
					match found_at(body, ['\r', '\n'], $at) {
						Ok(line_end) => line_end + 2
						Err(NotFound) => body.len()
					}
				match found_at(body, closing, start) {
					Ok(end) => {
						part = body.sublist({ start, len: end - start })
						match part_of(part) {
							Field(field) => {
								$fields = $fields.append(field)
							}
							File(upload) => {
								$fields = $fields.append({ name: upload.field, value: upload.name })
								$files = $files.append(upload)
							}
							Unnamed => {}
						}
						$at = end + closing.len()
					}
					Err(NotFound) => {
						$going = Bool.False
					}
				}
			}
		}
		Ok({ fields: $fields, files: $files })
	}

	## What a form posted without the runtime (a plain `<form method="post">`) comes back to its page
	## with: the URL it posted to, its fields as typed, and the endpoint's answer, its status and
	## body (200 and the result as JSON, or a refusal's status and why). `Endpoint.respond!` sends
	## it back (`flash_back!`), and the page it lands on reads it (`flash!`).
	Flash : { url : Str, fields : List({ name : Str, value : Str }), status : U16, body : Str }

	## The flash a plain form's post came back with, on the page the redirect lands on: the next page
	## a browser asks for after it (`clear_flash`). On the server it waits in the server's memory, its
	## id in the request's cookie, and the first page that reads it takes it (it is read once); the
	## page notes it for the browser (a script hydration reads), so both render the same. A field the
	## page has as an `<input type="password">` is left out of that note, and the page never fills
	## such an input in again. `Err(NoFlash)` on any other page. `use_submission!` reads it for you.
	flash! : {} => Try(Flash, [NoFlash])
	flash! = |{}| {
		found =
			match Server.cookie(Server.request!({}), flash_cookie) {
				Ok(value) => value
				Err(Missing) => ""
			}
		match flashed(FlashStore.read!(found)) {
			Ok(posted) => Ok({ url: posted.url, fields: Server.form_fields(posted.input), status: posted.status, body: posted.body })
			Err(NoFlash) => Err(NoFlash)
		}
	}

	## The answer to a plain form's post, instead of the endpoint's own: back to the page it was
	## posted from (`Referer`, when it is this site's; `/` otherwise), with a 303, and the flash
	## (`url` posted to, the form's body as posted, the answer's status and body) kept for that page
	## to read (`flash!`): in the server's memory for a minute, under a random id that a cookie
	## (`rocx-flash`, HttpOnly) holds, and nothing else. However long what was typed, it is kept.
	flash_back! : Request, { url : Str, input : Str, status : U16, body : Str } => Response
	flash_back! = |asked, posted| Server.response(303, [{ name: "location", value: referrer(asked) }].concat(FlashStore.keep!(posted)), "")

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

	## A typed path param as a path's part (D-092), as `FormBody` reads it back: text as it is, a
	## number or yes-or-no as JSON writes it (`7`, `1.5`, `true`), a choice its tag's name (`High`);
	## encoded as `encode_segment` encodes. What a link to an endpoint or a page with typed params
	## puts in its path (Generated/Api, Generated/Paths).
	encode_param : a -> Str where [a.Json.Encodable(e)]
	encode_param = |value|
		match Json.to_str_try(value) {
			Ok(json) =>
				if json.starts_with("\"") {
					parsed : Try(Str, [InvalidJson(Str)])
					parsed = Json.parse(json)
					Server.encode_segment(parsed ?? json)
				} else {
					Server.encode_segment(json)
				}
			Err(_) => crash "a path's param ${Server.unwritable}"
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
	## endpoint's, a GET a page reads as it renders), its `peer` too; empty, a GET of `/`, anywhere
	## else. The host hands it over as text, so a body that isn't UTF-8 comes with U+FFFD where it
	## isn't: an endpoint is given its request's bytes as they came.
	request! : {} => Request
	request! = |{}| from_wire(Host.request!({}))

	## Why a value can't be sent as JSON: it holds a number JSON has no way to write (an `F64` that is
	## NaN or an infinity). Any other `F64` is sent as a number, and read back as one.
	unwritable : Str
	unwritable = "it holds a number JSON can't write (an F64 that is NaN or an infinity)"
}

## A request as the host passes it (`Host.request!`), as HTTP writes it: `METHOD target`, and the
## connection's address after another space when the host knows it (`GET /about 203.0.113.7`), a
## header a line, a blank line, then its body (as text).
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
		Ok({ before, after }) =>
			match after.split_first(" ") {
				Ok(target) => { ..Server.from_http(before, target.before, lines, body.to_utf8()), peer: target.after }
				Err(_) => Server.from_http(before, after, lines, body.to_utf8())
			}
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

## The cookie that holds the id of a plain form's flash, between its post and its page
## (`Server.flash_back!`).
flash_cookie : Str
flash_cookie = "rocx-flash"

## A flash as it is kept (JSON), or none.
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

expect Server.from_host("/p?q=1", "Cookie: a=1; user=Grace%20Hopper\nx-empty: \nbroken") == { method: "GET", path: "/p", query: "q=1", headers: [{ name: "cookie", value: "a=1; user=Grace%20Hopper" }, { name: "x-empty", value: "" }], body: [], route: "", peer: "" }
expect Server.from_http("post", "/rocx/call/x", "", "{}".to_utf8()).method == "POST"
expect Server.text_of(Server.from_http("POST", "/", "", [0x22, 0xC3, 0xA9, 0xFF, 0x22])) == "\"é\u(FFFD)\""
expect Server.same_origin(Server.from_http("POST", "/", "origin: http://localhost:8080\nhost: localhost:8080", []))
expect !Server.same_origin(Server.from_http("POST", "/", "origin: https://evil.example\nhost: localhost:8080", []))
expect Server.same_origin(Server.from_http("POST", "/", "host: localhost:8080", []))
expect Server.encode_segment("Ada Lovelace/1") == "Ada%20Lovelace%2F1"
expect Server.encode_param(7.I64) == "7"
expect Server.encode_param(-1.5.Dec) == "-1.5"
expect Server.encode_param(Bool.True) == "true"
expect Server.encode_param("Ada Lovelace/1") == "Ada%20Lovelace%2F1"
expect Server.encode_param("say \"hi\"") == "say%20%22hi%22"
expect {
	level : [Low, High]
	level = High
	Server.encode_param(level) == "High"
}
expect Server.form_json("name=Ada+Lovelace&plan=a%26b&empty=") == "{\"name\":\"Ada Lovelace\",\"plan\":\"a&b\",\"empty\":\"\"}"
expect Server.changes(Server.from_http("DELETE", "/", "", [])) and !Server.changes(Server.from_host("/", ""))
expect Server.with_cookie(Server.redirect("/members"), "member", "Ada L").headers == [{ name: "location", value: "/members" }, { name: "set-cookie", value: "member=Ada%20L; Path=/; HttpOnly; SameSite=Lax" }]
expect Server.secure_cookies(Server.with_cookie(Server.redirect("/members"), "member", "Ada")).headers == [{ name: "location", value: "/members" }, { name: "set-cookie", value: "member=Ada; Path=/; HttpOnly; SameSite=Lax; Secure" }]
expect Server.secure_cookies(Server.set_cookie(Server.redirect("/"), "s", "t", { ..Server.cookie_defaults, secure: Bool.True })).headers == [{ name: "location", value: "/" }, { name: "set-cookie", value: "s=t; Path=/; Secure; HttpOnly; SameSite=Lax" }]
expect Server.without_cookie(Server.redirect("/"), "member").headers == [{ name: "location", value: "/" }, { name: "set-cookie", value: "member=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0" }]
expect Server.set_cookie(Server.redirect("/"), "__Host-session", "t/1", { ..Server.cookie_defaults, secure: Bool.True, max_age_s: 30 * 86_400 }).headers == [{ name: "location", value: "/" }, { name: "set-cookie", value: "__Host-session=t%2F1; Path=/; Max-Age=2592000; Secure; HttpOnly; SameSite=Lax" }]
expect Server.set_cookie(Server.redirect("/"), "org", "7", { max_age_s: 0, expires_ms: 784111777000, secure: Bool.False, http_only: Bool.False, same_site: Strict, path: "", domain: "example.com" }).headers == [{ name: "location", value: "/" }, { name: "set-cookie", value: "org=7; Domain=example.com; Expires=Sun, 06 Nov 1994 08:49:37 GMT; SameSite=Strict" }]
expect Server.clear_cookie(Server.redirect("/"), "__Host-session", { ..Server.cookie_defaults, secure: Bool.True, same_site: None, max_age_s: 60 }).headers == [{ name: "location", value: "/" }, { name: "set-cookie", value: "__Host-session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=None" }]
expect http_date(0) == "Thu, 01 Jan 1970 00:00:00 GMT"
expect http_date(951782400000) == "Tue, 29 Feb 2000 00:00:00 GMT"
expect http_date(4102444799999) == "Thu, 31 Dec 2099 23:59:59 GMT"

## A `content-type`'s boundary, when it is `multipart/form-data`'s.
boundary_of : Str -> Try(Str, [NotMultipart])
boundary_of = |type| {
	pieces = type.split_on(";")
	kind = (pieces.first() ?? "").trim().with_ascii_lowercased()
	if kind != "multipart/form-data" {
		return Err(NotMultipart)
	}
	found = pieces.drop_first(1).keep_oks(
		|piece|
			match piece.trim().split_first("=") {
				Ok({ before, after }) if before.trim().with_ascii_lowercased() == "boundary" => Ok(unquoted(after.trim()))
				_ => Err(NotIt)
			},
	)
	match found.first() {
		Ok(boundary) if !boundary.is_empty() => Ok(boundary)
		_ => Err(NotMultipart)
	}
}

## A parameter's value without the quotes around it, if it has them.
unquoted : Str -> Str
unquoted = |value|
	if value.starts_with("\"") and value.ends_with("\"") and value.count_utf8_bytes() >= 2 {
		Str.from_utf8_lossy(value.to_utf8().drop_first(1).drop_last(1))
	} else {
		value
	}

## Where `needle` first is in `bytes`, from `from` on.
found_at : List(U8), List(U8), U64 -> Try(U64, [NotFound])
found_at = |bytes, needle, from| {
	first =
		match needle.first() {
			Ok(byte) => byte
			Err(_) => return Err(NotFound)
		}
	if bytes.len() < needle.len() {
		return Err(NotFound)
	}
	last = bytes.len() - needle.len()
	var $at = from
	while $at <= last {
		if (bytes.get($at) ?? 0) == first and bytes.sublist({ start: $at, len: needle.len() }) == needle {
			return Ok($at)
		}
		$at = $at + 1
	}
	Err(NotFound)
}

## One part of a multipart body: its headers, a blank line, its content. A text field, or a file
## (a part with a `filename`); one with no name is passed over.
part_of : List(U8) -> [Field({ name : Str, value : Str }), File(Server.Upload), Unnamed]
part_of = |part| {
	(head, content) =
		match found_at(part, ['\r', '\n', '\r', '\n'], 0) {
			Ok(end) => (Str.from_utf8_lossy(part.sublist({ start: 0, len: end })), part.drop_first(end + 4))
			Err(NotFound) => ("", [])
		}
	lines = head.split_on("\r\n")
	header_of = |wanted|
		lines.keep_oks(
			|line|
				match line.split_first(":") {
					Ok({ before, after }) if before.trim().with_ascii_lowercased() == wanted => Ok(after.trim())
					_ => Err(NotIt)
				},
		).first() ?? ""
	params = header_of("content-disposition").split_on(";").drop_first(1).keep_oks(
		|param|
			match param.trim().split_first("=") {
				Ok({ before, after }) => Ok({ key: before.trim().with_ascii_lowercased(), value: escaped_back(unquoted(after.trim())) })
				Err(_) => Err(NotIt)
			},
	)
	param = |wanted| params.find_first(|each| each.key == wanted).map_ok(|each| each.value)
	match (param("name"), param("filename")) {
		(Ok(name), Ok(filename)) => File({ field: name, name: filename, type: header_of("content-type"), bytes: content })
		(Ok(name), Err(_)) => Field({ name, value: Str.from_utf8_lossy(content) })
		_ => Unnamed
	}
}

## A name or file name as a browser writes it in a part's header, its quote and line breaks as
## `%22`, `%0D` and `%0A`, read back.
escaped_back : Str -> Str
escaped_back = |name| name.replace_each("%22", "\"").replace_each("%0D", "\r").replace_each("%0A", "\n")

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
expect from_wire("POST /rocx/call/Demos/Echo.echo?x=1\ncookie: member=Ada\ncontent-type: application/json\n\n\"hi\"\n\nmore") == { method: "POST", path: "/rocx/call/Demos/Echo.echo", query: "x=1", headers: [{ name: "cookie", value: "member=Ada" }, { name: "content-type", value: "application/json" }], body: "\"hi\"\n\nmore".to_utf8(), route: "", peer: "" }
expect from_wire("GET /about") == { method: "GET", path: "/about", query: "", headers: [], body: [], route: "", peer: "" }
expect from_wire("GET /about?x=1 203.0.113.7\nhost: example.com") == { method: "GET", path: "/about", query: "x=1", headers: [{ name: "host", value: "example.com" }], body: [], route: "", peer: "203.0.113.7" }
expect from_wire("") == { method: "GET", path: "/", query: "", headers: [], body: [], route: "", peer: "" }

## A form with a file, as a browser sends it: its text fields, and the file, its name the field's value.
expect {
	body = "--XyZ\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nSea, at dusk\r\n--XyZ\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"sea %22blue%22.png\"\r\nContent-Type: image/png\r\n\r\n".to_utf8().concat([0x89, 0x0D, 0x0A, 0x00]).concat("\r\n--XyZ\r\nContent-Disposition: form-data; name=\"empty\"; filename=\"\"\r\nContent-Type: application/octet-stream\r\n\r\n\r\n--XyZ--\r\n".to_utf8())
	request = Server.from_http("POST", "/photos", "content-type: multipart/form-data; boundary=XyZ", body)
	parts = Server.multipart(request) ?? { fields: [], files: [] }
	parts.fields == [{ name: "title", value: "Sea, at dusk" }, { name: "photo", value: "sea \"blue\".png" }, { name: "empty", value: "" }]
		and Server.file(request, "photo") == Ok({ field: "photo", name: "sea \"blue\".png", type: "image/png", bytes: [0x89, 0x0D, 0x0A, 0x00] })
		and Server.file(request, "empty") == Err(NoFile)
		and Server.files(request).len() == 2
}
expect Server.multipart(Server.from_http("POST", "/photos", "content-type: application/x-www-form-urlencoded", "a=1".to_utf8())) == Err(NotMultipart)
expect boundary_of("Multipart/Form-Data; boundary=\"a b\"") == Ok("a b")
