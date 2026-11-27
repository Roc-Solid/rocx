import pf.Time
import pf.WebSocket
import tools.JsonValue
import crypto.Base64

## A tab of Chromium's headless shell (`Chrome.open!`), on a socket of its own: any method of the
## DevTools protocol (`call!`), and what a test or a renderer does with a page, each through the
## browser's own input pipeline where a person's hands would be: going to a URL, running JavaScript
## in the page, waiting for it to say something is true, clicking, typing, keys, its size, and
## photographs of it. Events the browser sends meanwhile wait on the socket; `errors!` takes those
## that say the page threw.
Tab := { socket : WebSocket }.{

	## The tab on this socket (`ws://…/devtools/page/<id>`): what `Chrome.open!` gives.
	at : WebSocket -> Tab
	at = |socket| { socket: socket }

	## A method of the DevTools protocol (`Page.navigate`) with its params, and its result; `Failed`
	## with the method's name and the browser's message when it failed, or when nothing answered in
	## a minute.
	call! : Tab, Str, JsonValue => Try(JsonValue, [Failed(Str)])
	call! = |tab, method, params| {
		text = asked!(tab, method, params)?
		match JsonValue.parse(text) {
			Ok(answer) =>
				match answer.get("error") {
					Ok(_) => Err(Failed("${method}: ${failure(text)}"))
					Err(Missing) => Ok(answer.get("result") ?? Object([]))
				}
			Err(InvalidJson(why)) => Err(Failed("${method}: an answer that isn't JSON (${why})"))
		}
	}

	## Runs `source` in every document the tab loads from now on, before the document's own scripts.
	before_each_document! : Tab, Str => Try({}, [Failed(Str)])
	before_each_document! = |tab, source| {
		_ = call!(tab, "Page.enable", Object([]))?
		_ = call!(tab, "Page.addScriptToEvaluateOnNewDocument", Object([("source", String(source))]))?
		Ok({})
	}

	## Goes to `url`, and waits (up to `ms`) until its document has loaded (`readyState` complete).
	## `Failed` when the browser couldn't load it (nothing listens there).
	goto! : Tab, Str, U64 => Try({}, [Failed(Str)])
	goto! = |tab, url, ms| {
		_ = call!(tab, "Runtime.enable", Object([]))?
		_ = call!(tab, "Page.enable", Object([]))?
		went = call!(tab, "Page.navigate", Object([("url", String(url))]))?
		match went.get("errorText") {
			Ok(String(why)) if !why.is_empty() => Err(Failed("${url}: ${why}"))
			_ => wait!(tab, "document.readyState === 'complete'", ms)
		}
	}

	## The value of the JavaScript `expression` in the page (awaited when it is a promise), as JSON
	## (`Null` for `undefined`); `Failed` with what it threw.
	eval! : Tab, Str => Try(JsonValue, [Failed(Str)])
	eval! = |tab, expression| {
		evaluated = call!(tab, "Runtime.evaluate", Object([("expression", String(expression)), ("awaitPromise", Boolean(Bool.True)), ("returnByValue", Boolean(Bool.True))]))?
		match evaluated.get("exceptionDetails") {
			Ok(details) => Err(Failed(thrown(details)))
			Err(Missing) => Ok(field(evaluated, ["result", "value"]) ?? Null)
		}
	}

	## Waits until the JavaScript `expression` is true in the page, looking every 25 ms, up to `ms`.
	wait! : Tab, Str, U64 => Try({}, [Failed(Str)])
	wait! = |tab, expression, ms| {
		started = Time.now_ms!({})
		var $done = Bool.False
		while !$done {
			if eval!(tab, "Boolean(${expression})")? == Boolean(Bool.True) {
				$done = Bool.True
			} else if Time.now_ms!({}) - started >= ms {
				return Err(Failed("timed out after ${ms.to_str()} ms waiting for ${expression}"))
			} else {
				Time.sleep!(25)
			}
		}
		Ok({})
	}

	## A real click in the middle of the element `selector` (CSS) finds, scrolled into view at once
	## first, through the browser's input pipeline.
	click! : Tab, Str => Try({}, [Failed(Str)])
	click! = |tab, selector| {
		point = center!(tab, selector)?
		click_at!(tab, point.x, point.y)
	}

	## A real click at a point of the page (CSS pixels from the viewport's top left).
	click_at! : Tab, F64, F64 => Try({}, [Failed(Str)])
	click_at! = |tab, x, y| {
		for kind in ["mousePressed", "mouseReleased"] {
			_ = call!(tab, "Input.dispatchMouseEvent", Object([("type", String(kind)), ("x", number(x)), ("y", number(y)), ("button", String("left")), ("clickCount", Number("1"))]))?
		}
		Ok({})
	}

	## Typing, as a keyboard does: the element `selector` finds focused, then `text` inserted where
	## the caret is (an `input` event).
	type! : Tab, Str, Str => Try({}, [Failed(Str)])
	type! = |tab, selector, text| {
		_ = eval!(tab, "document.querySelector(${JsonValue.to_str(String(selector))}).focus()")?
		_ = call!(tab, "Input.insertText", Object([("text", String(text))]))?
		Ok({})
	}

	## A key pressed and released, by its `key` as the browser names it (`Enter`, `Escape`, `Tab`,
	## `Backspace`, `ArrowUp`…, `" "` for the space bar, or a letter). Enter and Space carry their
	## text, as a keyboard's do, so Enter submits a form.
	press! : Tab, Str => Try({}, [Failed(Str)])
	press! = |tab, key| {
		{ code, virtual, text } = key_of(key)
		down = [("type", String(if (text.is_empty()) "rawKeyDown" else "keyDown")), ("key", String(key)), ("code", String(code)), ("windowsVirtualKeyCode", JsonValue.uint(virtual))]
		_ = call!(tab, "Input.dispatchKeyEvent", Object(if (text.is_empty()) down else down.append(("text", String(text)))))?
		_ = call!(tab, "Input.dispatchKeyEvent", Object([("type", String("keyUp")), ("key", String(key)), ("code", String(code)), ("windowsVirtualKeyCode", JsonValue.uint(virtual))]))?
		Ok({})
	}

	## The page laid out `width` by `height` CSS pixels, each `scale` device pixels wide (2 for a
	## photograph twice as sharp), as a desktop browser (not a phone's).
	viewport! : Tab, { width : U64, height : U64, scale : F64 } => Try({}, [Failed(Str)])
	viewport! = |tab, { width, height, scale }| {
		_ = call!(tab, "Emulation.setDeviceMetricsOverride", Object([("width", JsonValue.uint(width)), ("height", JsonValue.uint(height)), ("deviceScaleFactor", number(scale)), ("mobile", Boolean(Bool.False))]))?
		Ok({})
	}

	## A PNG of the viewport, or of `Clip` (a box of the page in CSS pixels, from the document's top
	## left, even past the viewport), at the device's scale.
	screenshot! : Tab, [Viewport, Clip({ x : F64, y : F64, width : F64, height : F64 })] => Try(List(U8), [Failed(Str)])
	screenshot! = |tab, area| {
		params = match area {
			Viewport => [("format", String("png"))]
			Clip({ x, y, width, height }) => [("format", String("png")), ("captureBeyondViewport", Boolean(Bool.True)), ("clip", Object([("x", number(x)), ("y", number(y)), ("width", number(width)), ("height", number(height)), ("scale", Number("1"))]))]
		}
		# The answer is the PNG in Base64 (megabytes, for a large page): read from where it starts, not
		# parsed as a whole.
		text = asked!(tab, "Page.captureScreenshot", Object(params))?
		match text.split_first("\"data\":\"") {
			Ok({ after, .. }) =>
				match after.split_first("\"") {
					Ok({ before: data, .. }) => Base64.decode(data).map_err(|InvalidBase64| Failed("Page.captureScreenshot: its data isn't Base64"))
					Err(NotFound) => Err(Failed("Page.captureScreenshot: its data didn't end"))
				}
			Err(NotFound) => Err(Failed("Page.captureScreenshot: ${failure(text)}"))
		}
	}

	## What the page threw since this was last asked (the browser's own words, as its console has
	## them), oldest first. Other events waiting on the socket are passed over.
	errors! : Tab => List(Str)
	errors! = |tab| {
		var $errors = []
		var $more = Bool.True
		while $more {
			match WebSocket.receive!(tab.socket, 0) {
				Ok(text) =>
					match JsonValue.parse(text) {
						Ok(event) if event.get("method") == Ok(String("Runtime.exceptionThrown")) => {
							details = field(event, ["params", "exceptionDetails"]) ?? Null
							$errors = $errors.append(thrown(details))
						}
						_ => {}
					}
				Err(_) => {
					$more = Bool.False
				}
			}
		}
		$errors
	}

	## Closes the tab, and its socket.
	close! : Tab => {}
	close! = |tab| {
		_ = call!(tab, "Page.close", Object([]))
		WebSocket.close!(tab.socket)
	}
}

## The answer's text, or why there is none.
asked! : Tab, Str, JsonValue => Try(Str, [Failed(Str)])
asked! = |tab, method, params| {
	request = JsonValue.to_str(Object([("method", String(method)), ("params", params)]))
	match WebSocket.request!(tab.socket, request, 60_000) {
		Ok(text) => Ok(text)
		Err(Timeout) => Err(Failed("${method}: no answer in a minute"))
		Err(Closed(why)) => Err(Failed("${method}: the tab's socket closed (${why})"))
		Err(NotAnObject) => Err(Failed("${method}: the request isn't a JSON object"))
	}
}

## The middle of the element `selector` finds, scrolled into view at once (even on a page that
## scrolls smoothly): where a real pointer would press it.
center! : Tab, Str => Try({ x : F64, y : F64 }, [Failed(Str)])
center! = |tab, selector| {
	found = Tab.eval!(tab, "(() => { const element = document.querySelector(${JsonValue.to_str(String(selector))}); if (!element) return null; element.scrollIntoView({ block: \"center\", behavior: \"instant\" }); const r = element.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()")?
	match (found.get("x"), found.get("y")) {
		(Ok(Number(x)), Ok(Number(y))) => Ok({ x: F64.from_str(x) ?? 0, y: F64.from_str(y) ?? 0 })
		_ => Err(Failed("nothing matches ${selector}"))
	}
}

## A number as JSON (0 for what JSON can't write: NaN, an infinity).
number : F64 -> JsonValue
number = |value| if (value.is_finite()) Number(value.to_str()) else Number("0")

## The value at a path of fields (`["result", "value"]`); `Missing` when one isn't there.
field : JsonValue, List(Str) -> Try(JsonValue, [Missing])
field = |value, path|
	match path {
		[] => Ok(value)
		[first, .. as rest] =>
			match value.get(first) {
				Ok(inner) => field(inner, rest)
				Err(Missing) => Err(Missing)
			}
	}

## What a failed answer's `error` says (its message), or the answer itself when it has none.
failure : Str -> Str
failure = |text|
	match JsonValue.parse(text) {
		Ok(answer) if !text_of(field(answer, ["error"]) ?? Null, "message").is_empty() => text_of(field(answer, ["error"]) ?? Null, "message")
		_ => "an answer with no result: ${text}"
	}

## What an exception's details say: its description (the message and the stack), else their text.
thrown : JsonValue -> Str
thrown = |details|
	match field(details, ["exception", "description"]) {
		Ok(String(description)) => description
		_ => text_of(details, "text")
	}

## A string field of an object, or "".
text_of : JsonValue, Str -> Str
text_of = |value, key|
	match value.get(key) {
		Ok(String(text)) => text
		_ => ""
	}

## A key's `code`, its Windows virtual key code, and the text it types, as a keyboard reports them.
key_of : Str -> { code : Str, virtual : U64, text : Str }
key_of = |key|
	match key {
		"Enter" => { code: "Enter", virtual: 13, text: "\r" }
		"Escape" => { code: "Escape", virtual: 27, text: "" }
		"Backspace" => { code: "Backspace", virtual: 8, text: "" }
		"Tab" => { code: "Tab", virtual: 9, text: "" }
		" " => { code: "Space", virtual: 32, text: " " }
		"ArrowUp" => { code: "ArrowUp", virtual: 38, text: "" }
		"ArrowDown" => { code: "ArrowDown", virtual: 40, text: "" }
		"ArrowLeft" => { code: "ArrowLeft", virtual: 37, text: "" }
		"ArrowRight" => { code: "ArrowRight", virtual: 39, text: "" }
		_ => { code: key, virtual: 0, text: "" }
	}

expect number(12.5) == Number("12.5")
expect field(Object([("result", Object([("value", Number("3"))]))]), ["result", "value"]) == Ok(Number("3"))
expect field(Object([("result", Null)]), ["result", "value"]) == Err(Missing)
expect key_of("Enter").text == "\r"
expect thrown(Object([("text", String("Uncaught")), ("exception", Object([("description", String("Error: boom"))]))])) == "Error: boom"
expect thrown(Object([("text", String("Uncaught"))])) == "Uncaught"
