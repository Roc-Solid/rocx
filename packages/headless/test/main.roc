## packages/headless's checks, as a program on the CLI platform: Chromium's headless shell started,
## a page used as a person would (clicks, typing, keys), what it throws heard, photographed at a
## size, and closed. Each check says what it found when it fails, and the program then exits 1.
## `headless.test.mjs` builds and runs it (`$CHROME`, or Playwright's headless shell).
app [main!] { headless: "../main.roc", pf: platform "../../../cli/platform/main.roc" }

import pf.Http
import pf.Stderr
import pf.Stdout
import headless.Chrome
import headless.Tab

page = "data:text/html,<title>Start</title><form onsubmit=\"event.preventDefault(); document.title = 'sent ' + this.elements.note.value\"><label>Note <input name=note></label><button type=button onclick=\"document.title = 'clicked'\">Go</button></form>"

main! = |_| {
	chrome = Chrome.launch!(Chrome.find!({})?)?
	tab = Chrome.open!(chrome)?
	checked = checks!(tab)
	Tab.close!(tab)
	Chrome.close!(chrome)
	match checked {
		Ok({}) => {
			Stdout.line!("headless: every check passed")?
			Ok({})
		}
		Err(Failed(why)) => {
			Stderr.line!("headless: ${why}")?
			Err(Exit(1))
		}
	}
}

checks! : Tab => Try({}, [Failed(Str)])
checks! = |tab| {
	Tab.goto!(tab, page, 10_000)?
	same(Tab.eval!(tab, "document.title")?, String("Start"), "the page's title")?
	same(Tab.eval!(tab, "Promise.resolve(6 * 7)")?, Number("42"), "a promise's value, awaited")?
	same(Tab.eval!(tab, "undefined")?, Null, "undefined")?

	Tab.click!(tab, "button")?
	same(Tab.eval!(tab, "document.title")?, String("clicked"), "the title after a real click")?

	Tab.type!(tab, "input", "milk")?
	same(Tab.eval!(tab, "document.querySelector('input').value")?, String("milk"), "what was typed")?
	Tab.press!(tab, "Enter")?
	Tab.wait!(tab, "document.title === 'sent milk'", 2_000)?

	failed(Tab.eval!(tab, "(() => { throw new Error('boom') })()"), "Error: boom", "what eval! throws")?
	failed(Tab.wait!(tab, "false", 100), "timed out after 100 ms waiting for false", "a wait that times out")?
	failed(Tab.click!(tab, "#nothing"), "nothing matches #nothing", "a click on nothing")?

	_ = Tab.errors!(tab)
	_ = Tab.eval!(tab, "setTimeout(() => { throw new Error('later') }, 0)")?
	Tab.wait!(tab, "new Promise((done) => setTimeout(() => done(true), 50))", 2_000)?
	errors = Tab.errors!(tab)
	if errors.len() != 1 or !(errors.first() ?? "").starts_with("Error: later") {
		return Err(Failed("the error the page threw: ${Str.inspect(errors)}"))
	}
	same(Str.inspect(Tab.errors!(tab)), "[]", "errors! again, once taken")?

	Tab.viewport!(tab, { width: 200, height: 100, scale: 2 })?
	png = Tab.screenshot!(tab, Viewport)?
	same(png.take_first(8), [137, 80, 78, 71, 13, 10, 26, 10], "a PNG's signature")?
	same((size(png, 16), size(png, 20)), (400, 200), "the PNG's size at scale 2")?
	clipped = Tab.screenshot!(tab, Clip({ x: 10, y: 10, width: 50, height: 20 }))?
	same((size(clipped, 16), size(clipped, 20)), (100, 40), "a clip's size at scale 2")?

	nowhere = "http://127.0.0.1:${Http.free_port!({}).map_err(|NoPort(why)| Failed(why))?.to_str()}/"
	failed(Tab.goto!(tab, nowhere, 5_000), "${nowhere}: net::ERR_CONNECTION_REFUSED", "a page nothing serves")?
	Ok({})
}

## A PNG's width or height: the big-endian number at `at` in its header (16, 20).
size : List(U8), U64 -> U64
size = |png, at| png.sublist({ start: at, len: 4 }).fold(0, |n, byte| n * 256 + byte.to_u64())

same = |got, wanted, what| if (got == wanted) Ok({}) else Err(Failed("${what}: ${Str.inspect(got)}, not ${Str.inspect(wanted)}"))

failed : Try(_, [Failed(Str)]), Str, Str -> Try({}, [Failed(Str)])
failed = |result, wanted, what|
	match result {
		Err(Failed(why)) if why.starts_with(wanted) => Ok({})
		Err(Failed(why)) => Err(Failed("${what}: failed with ${Str.inspect(why)}, not ${Str.inspect(wanted)}"))
		Ok(_) => Err(Failed("${what}: didn't fail"))
	}
