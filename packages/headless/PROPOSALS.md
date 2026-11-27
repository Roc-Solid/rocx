# headless: what it could do next

## 1. Gecko, over WebDriver BiDi

**Problem.** packages/testing's browser drives Gecko too (Zen, Firefox), over WebDriver BiDi, for
what only Gecko shows. This package drives Chromium alone.

**Proposal.** `Gecko.find!`, `Gecko.launch!` and the same `Tab` functions, over BiDi's
`session`, `browsingContext`, `script` and `input` modules on the same `WebSocket`: BiDi answers by
`id` as the DevTools protocol does, so `request!` serves both. `Tab` would carry which protocol its
socket speaks. web/test/browser.mjs's `GeckoPage` is the map (its `drag` falls back to the DOM's own
events: Mozilla's bug 1515879).

## 2. Drags and touch

**Problem.** web/test/browser.mjs's `drag` (the browser's own drag and drop, through
`Input.setInterceptDrags`) and `touchDrag` (`Input.dispatchTouchEvent`) aren't here.

**Proposal.** `Tab.drag!(tab, from, over)` and `Tab.touch_drag!(tab, from, over, { hold, steps })`.
`drag` waits for one event (`Input.dragIntercepted`): a `Tab.event!(tab, method, ms)` taking the
first waiting event with that method, the others kept (the socket would need a `receive!` that
takes by a test of the message, or the tab keeps what it passed over in the host).

## 3. The testing package's queries in a tab

**Problem.** packages/testing finds elements as a person does (by role and name, by label, by
text), in Roc (`Dom`) for a pure component's HTML and in JavaScript for a tab. A tab driven from Roc
has CSS selectors alone.

**Proposal.** `Tab.dom!(tab)`: `Dom.parse` of the document's HTML (`document.documentElement.outerHTML`),
so the same `Dom.Query` values (`Named("button", "Save")`) find what to click; and an element found
that way clicked by a selector the page computes for it (a `data-` mark set by `eval!`). packages/testing
would name the CLI platform in a module of its own for it (its `Dom` is on none).

## 4. An app's tests in Roc

**Problem.** An app's tests that start its server and use its pages are JavaScript (packages/testing).

**Proposal.** packages/testing's proposal 8 (requests answered in-process, `rocx test`) for the
server, and for pages a test program on the CLI platform that starts the app's built server
(`Cmd.spawn!`), opens its pages with this package, and calls its endpoints through the browser's
typed copy of its `Api`. The Node half stays for rocx's own suites, which check what the compiler
makes from outside it.
