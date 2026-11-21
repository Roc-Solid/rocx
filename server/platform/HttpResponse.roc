## What another server answered a request (`Http.fetch!`), read whole, as `fetch`'s `Response`
## is read: its `status`; `ok`, whether that is a success (2xx); its `headers`, each name in lower
## case; its `body`; and, from those, `res.header(name)`, `res.text()`, `res.json()` and
## `res.bytes()`.
##
##     res = Http.fetch!(url, {})?
##     if res.ok res.text() else "${res.status.to_str()}: ${res.header("content-type") ?? "?"}"
HttpResponse := { status : U16, ok : Bool, headers : List((Str, Str)), body : List(U8) }.{

	## The answer to a request: `ok` from its `status`.
	new : U16, List((Str, Str)), List(U8) -> HttpResponse
	new = |status, headers, body| { status, ok: status >= 200 and status < 300, headers, body }

	## The first header called `name` (in any case), or `Err(Missing)`.
	header : HttpResponse, Str -> Try(Str, [Missing])
	header = |res, name| {
		wanted = name.with_ascii_lowercased()
		match res.headers.find_first(|(each, _)| each.with_ascii_lowercased() == wanted) {
			Ok((_, value)) => Ok(value)
			Err(_) => Err(Missing)
		}
	}

	## The body as text, UTF-8: a byte that isn't is U+FFFD.
	text : HttpResponse -> Str
	text = |res| Str.from_utf8_lossy(res.body)

	## The body as JSON, read as the type wanted (`weather : Try({ high : I64 }, _)`), as `Json.parse`
	## reads it: `Err(InvalidJson(why))` if it isn't JSON, or isn't of that shape.
	json : HttpResponse -> Try(a, [InvalidJson(Str)]) where [a.Json.Parseable([InvalidJson(Str)])]
	json = |res| Json.parse(Str.from_utf8_lossy(res.body))

	## The body as it came, bytes.
	bytes : HttpResponse -> List(U8)
	bytes = |res| res.body
}

expect HttpResponse.new(200, [], []).ok
expect HttpResponse.new(299, [], []).ok
expect !HttpResponse.new(199, [], []).ok
expect !HttpResponse.new(300, [], []).ok
expect !HttpResponse.new(404, [], []).ok
expect HttpResponse.new(200, [("content-type", "text/plain"), ("x-empty", "")], []).header("Content-Type") == Ok("text/plain")
expect HttpResponse.new(200, [("content-type", "text/plain"), ("x-empty", "")], []).header("x-empty") == Ok("")
expect HttpResponse.new(200, [], []).header("location") == Err(Missing)
expect HttpResponse.new(200, [], [104, 105, 255]).text() == "hi\u(FFFD)"
expect HttpResponse.new(200, [], [0, 255]).bytes() == [0, 255]
expect {
	read : Try({ high : I64, sky : Str }, [InvalidJson(Str)])
	read = HttpResponse.new(200, [], "{\"high\":21,\"sky\":\"clear\"}".to_utf8()).json()
	read == Ok({ high: 21, sky: "clear" })
}
expect {
	read : Try({ high : I64 }, [InvalidJson(Str)])
	read = HttpResponse.new(200, [], "<html>".to_utf8()).json()
	read.is_err()
}
expect {
	read : Try({ high : I64 }, [InvalidJson(Str)])
	read = HttpResponse.new(200, [], "{\"high\":\"warm\"}".to_utf8()).json()
	read.is_err()
}
