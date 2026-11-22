## What the JS runtime does for Roc. A box the runtime keeps is a Roc value it can't read: a
## computation to run, or a signal's or memo's value, kept as a function that returns it.
Host := [].{

	## Keeps a computation, handler or fallback; its id goes in the markup's JSON.
	keep! : Box(() => Str) => U64
	signal_new! : Box(() -> a) => U64
	signal_get! : U64 => Box(() -> a)

	## Queued until the handler that writes it is done (dropped if it aborts).
	signal_set! : U64, Box(() -> a) => {}

	## Makes a memo from its computation, and runs it.
	memo_new! : Box(() => Str) => U64

	## The running memo's value.
	memo_done! : Box(() -> a) => {}

	## Aborts the caller while the memo waits, or fails it when the memo failed.
	memo_get! : U64 => Box(() -> a)

	## Runs it once, noting the memos it reads, and computes those again, asking the server again.
	refresh! : Box(() => Str) => {}

	## Runs it once, noting the memos it reads (its reads untracked, a wait or a failure caught):
	## whether one of them, or a memo one of them reads, has a value and waits for a new one. The
	## caller runs again when that answer changes.
	is_pending! : Box(() => Str) => Bool

	## Fails the caller, with why: the nearest <Errored> shows it.
	fail! : Str => {}

	## The value of the event a handler runs for (`on:input`).
	event_value! : {} => Str

	## In an <Errored> fallback: the boundary, and what failed.
	boundary! : {} => U64
	problem! : {} => Str
	retry! : U64 => {}

	## A `<For>`'s rows: its id; a row's index (tracked: it changes as the row moves); and a row's
	## item, by its key (tracked: it changes as the list does).
	for_new! : {} => U64
	row_index! : U64, Str => U64
	row_set! : U64, Str, Box(() -> a) => {}
	row_get! : U64, Str => Box(() -> a)

	## A context's value, given by a provider: kept by the runtime, by its id, while what made it is.
	context_value! : Box(() -> a) => U64

	## The id of the value the nearest provider of the named context gives, or 0 with none.
	context_find! : Str => U64
	context_get! : U64 => Box(() -> a)

	## On the server: the request being answered, as HTTP writes it: `METHOD target`, a header a
	## line (`name: value`), a blank line, then its body.
	request! : {} => Str

	## Where the page is: its path, and a query after a `?`, a trailing slash dropped. On the server,
	## the request's; in the browser, `location.pathname` and `location.search`.
	location! : {} => Str

	## On the server: the status the page is answered with (`<HttpStatusCode>`). In the browser, nothing.
	status! : U16 => {}

	## In the browser: a request (method, URL, headers a line each, body), its answer as JSON
	## (`{"status":…,"body":…}`); aborts the caller until it is in, fails it if there is none.
	fetch! : Str, Str, Str, Str => Str

	## In the browser: listens to the events at a URL. The handler runs for each, `event_value!` its
	## data (`{"Event":"…"}`), then once more at the end (`"Ended"`, or `{"Failed":"…"}`). Started
	## in an owner (a component, a computation, an effect's apply), it stops when that owner is
	## cleaned up.
	listen! : Str, Box(() => Str) => {}

	## In the browser: subscribes the handler to the channel at a URL, on the tab's one stream
	## (`/rocx/live`). The handler runs for each thing it hears, in order, `event_value!` what
	## (`"Resync"`, `{"Message":"…"}`, `{"Refused":[403,"…"]}`, `{"Ended":"…"}`), until its owner (a
	## component, a computation, an effect's apply) is cleaned up.
	subscribe! : Str, Box(() => Str) => {}

	## In the browser: says something (JSON) on the channel at a URL: sent with what else is said in
	## this frame (`POST /rocx/live/send`).
	say! : Str, Str => {}

	## In the browser: asks for a `Resync` of the channel at a URL, on the tab's stream.
	resync! : Str => {}

	## Publishing on a `Live` topic is the server's: in the browser, it fails.
	live_publish! : Str, Str => {}

	## In the browser: runs the handler after `ms` milliseconds (`timeout!`), or every `ms`
	## (`interval!`), until `clear_timer!` with the id they answer, or until what made it is cleaned
	## up (a component, a computation, an effect's apply: as its cleanups run). On the server,
	## never: the id is 0, and clearing it does nothing.
	timeout! : U64, Box(() => Str) => U64
	interval! : U64, Box(() => Str) => U64
	clear_timer! : U64 => {}

	## The browser's clock: milliseconds since the Unix epoch (`Date.now()`).
	now_millis! : {} => U64

	## Nanoseconds since the Unix epoch, on a clock that doesn't go back while the page is open
	## (`performance.timeOrigin + performance.now()`).
	now_nanos! : {} => U64

	## In a handler, in the browser: the page's own function by that name, given the argument (JSON),
	## called once the handler is done and the page patched. Anywhere else, it fails.
	browser_call! : Str, Str => {}

	## An effect (`create_effect!`), owned by what is running: its computation, run now and again
	## when what it read changes, answers the id of the box (`keep!`) its apply is, which the
	## runtime runs after the flush, the last apply's cleanups first. On the server, nothing.
	effect_new! : Box(() => Str) => {}

	## A cleanup (`on_cleanup!`) for the owner running: run before it runs again, and when it goes.
	## On the server, let go of: nothing it would undo started there.
	cleanup! : Box(() => Str) => {}

	## The flash a plain form's post came back with (`Server.flash!`), as JSON: on the server, what
	## Roc found in the request's cookie, noted for the page; in the browser, what the page noted.
	flash! : Str => Str

	## A form posting to this URL is sent by the runtime (`use_submission!`), while what is running
	## now is there. On the server, nothing.
	action! : Str => {}

	## The latest submission the runtime sent to this URL (tracked), as JSON
	## (`{"state":"pending"|"done"|"cleared","input":…,"status":…,"body":…}`), or "" with none: always
	## "" on the server.
	submission! : Str => Str

	## Forgets the latest submission to this URL (in a handler, applied when it is done).
	submission_clear! : Str => {}

	## Every submission the runtime sent to this URL (tracked), as JSON, oldest first:
	## `{"cleared":…,"list":[{"id":…,"state":…,"input":…,"json":…,"status":…,"body":…}]}`; "" with
	## none, and none forgotten: always "" on the server.
	submissions! : Str => Str

	## In a handler: a submission without a form (its method, URL, body, and its input: what it sent,
	## as JSON), sent once the handler is done; a result has the page's reads read again before the
	## submission is done. Anywhere else, it fails; on the server, nothing.
	submit! : Str, Str, Str, Str => {}

	## Forgets one submission to this URL, by its id (in a handler, applied when it is done).
	submission_drop! : Str, U64 => {}

	## The document's title, as a `<Title>` says it (its hole's run): in the browser, the last one
	## rendered that is still there is `document.title`, until it goes; on the server, noted for the
	## page's `<head>`.
	title! : Str => {}
}
