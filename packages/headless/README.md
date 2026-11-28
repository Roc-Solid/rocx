# headless

Chromium's headless shell, driven from Roc. `Chrome` starts it with a profile of its own and opens
tabs; a `Tab` is used as a test or a renderer uses a page: going to a URL, running JavaScript in it,
waiting for something to be true, real clicks, typing and keys through the browser's input
pipeline, its size, photographs of it, and what it threw. Under it is Chromium's DevTools protocol,
on the CLI platform's `WebSocket`; nothing of Playwright's runs, though its downloaded headless
shell is used when `$CHROME` names none.

It names the CLI platform (`cli/`), so programs on that platform use it: rocx itself (`rocx render`
films packages/video's players with it, D-128) and checks written in Roc (`test/main.roc`). Apps
don't import it; their tests in Node use packages/testing's browser, which drives the same headless
shell from JavaScript.

```roc
app [main!] { pf: platform "…/cli/platform/main.roc", headless: "…/packages/headless/main.roc" }

import pf.File
import headless.Chrome
import headless.Tab

main! = |_| {
	chrome = Chrome.launch!(Chrome.find!({})?)?
	tab = Chrome.open!(chrome)?
	photographed = counted!(tab)
	Chrome.close!(chrome)
	File.write_bytes!("page.png", photographed?)?
	Ok({})
}

counted! : Tab => Try(List(U8), [Failed(Str)])
counted! = |tab| {
	Tab.goto!(tab, "http://127.0.0.1:8091/", 10_000)?
	Tab.click!(tab, "button.add")?
	Tab.wait!(tab, "document.querySelector('output').textContent === '1'", 2_000)?
	Tab.viewport!(tab, { width: 1280, height: 720, scale: 2 })?
	Tab.screenshot!(tab, Viewport)
}
```

Close the browser on every path. One the program leaves running is stopped when the program ends,
but its profile stays in the temporary directory.

## `Chrome`

| Function | What it does |
|---|---|
| `Chrome.find!({})` | The headless shell: `$CHROME`, else the newest Playwright keeps in its cache (`npx playwright install --only-shell chromium`); `NoChrome(how)` says how to get one |
| `Chrome.launch!(binary)` | Starts it headless in a new profile in the system's temporary directory, as a laptop's browser: motion as a page gets it when it asks for none, scrollbars that take no room, no sandbox (as Playwright runs it). It picks its own DevTools port, read from the profile once it listens. `CantLaunch(why)` with what it said |
| `Chrome.open!(chrome)` | A new tab at about:blank, on a socket of its own; the tabs share the profile's cookies |
| `Chrome.close!(chrome)` | Asks it to close, makes it, and deletes its profile |

## `Tab`

Each function that can fail fails with `Failed(why)`: the protocol method and the browser's own
message, what the page threw, or what timed out.

| Function | What it does |
|---|---|
| `Tab.goto!(tab, url, ms)` | Goes to `url` and waits (up to `ms`) until its document has loaded; fails with the browser's error when nothing serves it (`net::ERR_CONNECTION_REFUSED`) |
| `Tab.eval!(tab, expression)` | The JavaScript's value as JSON (packages/tools' `JsonValue`; a promise awaited, `undefined` as `Null`); fails with what it threw |
| `Tab.wait!(tab, expression, ms)` | Waits until the expression is true, looking every 25 ms |
| `Tab.before_each_document!(tab, source)` | Runs `source` in every document the tab loads from then on, before the page's own scripts (a clock to freeze, a listener) |
| `Tab.click!(tab, selector)`, `Tab.click_at!(tab, x, y)` | A real click in the middle of what the CSS selector finds (scrolled into view at once first), or at a point |
| `Tab.type!(tab, selector, text)` | Focuses the element and inserts `text` where the caret is, as typing does (an `input` event) |
| `Tab.press!(tab, key)` | A key pressed and released: `Enter` (which submits a form), `Escape`, `Tab`, `Backspace`, the arrows, `" "`. A letter reaches the page's key handlers but types nothing (`type!` types) |
| `Tab.viewport!(tab, { width, height, scale })` | Lays the page out at that size in CSS pixels, `scale` device pixels each |
| `Tab.screenshot!(tab, Viewport)`, `Tab.screenshot!(tab, Clip({ x, y, width, height }))` | A PNG of the viewport, or of a box of the page (from the document's top left, past the viewport too), at the device's scale |
| `Tab.errors!(tab)` | What the page threw since this was last asked, oldest first |
| `Tab.call!(tab, method, params)` | Any method of the DevTools protocol, with its params as a `JsonValue`: its result |
| `Tab.close!(tab)` | Closes the tab |

A tab's socket keeps the events the browser sends between calls (the CLI platform's `WebSocket`
keeps each message until it is taken), so `errors!` reads the page's exceptions whenever it is
asked, and nothing else needs a loop.

## Tests

`node --test 'packages/headless/test/*.test.mjs'` runs the WebSocket's unit tests
(`cli/host/src/websocket.rs`), then builds `test/main.roc`, a program of checks on a page made for
them, and runs it in the headless shell. Without one they skip; in CI, or with
`ROCX_BROWSERS=required`, that is an error instead.

## Not yet

See [PROPOSALS.md](PROPOSALS.md): Gecko over WebDriver BiDi, drags and touch, the testing package's
queries in a tab, and tests of an app written in Roc.
