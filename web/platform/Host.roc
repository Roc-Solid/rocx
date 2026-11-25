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

	## The running memo's value. `same`: it equals the value the memo has (a store's selection says
	## so, by Roc's `==`), so the memo's readers aren't told; `create_memo!`'s always say `Bool.False`.
	memo_done! : Box(() -> a), Bool => {}

	## Aborts the caller while the memo waits, or fails it when the memo failed.
	memo_get! : U64 => Box(() -> a)

	## A selector (`Solid.create_selector!`): its computation answers its source's key (the value as
	## `Str.inspect` writes it), run now and again when what it reads changes; its id.
	selector_new! : Box(() => Str) => U64

	## Whether `key` is the selector's key now, tracked by that key alone: a reader runs again only
	## when the answer for its own key changes. Waits while the selector does.
	selector_is! : U64, Str => Bool

	## A template's state (`Html.template`, D-084), by its site: 0 for none (as the page hydrates, or a
	## site the runtime refused), else its id times two, plus one once the runtime has its skeleton.
	template! : Str => U32

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

	## A `.map`'s rows (`Html.rows!`, D-071): its id; a row's index (tracked: it changes as the row
	## moves); and a row's item, by its key (tracked: it changes as the list does). `row_set!`'s
	## `same`: the item is `==` the one the row had (D-053's comparison, every list's), so the row isn't
	## told; it answers whether the page shows a row of that key already (the runtime keeps it, and
	## needs no box to make it). `row_last!`: the row's item, untracked, or `fallback` for a new row.
	for_new! : {} => U64
	row_index! : U64, Str => U64
	row_set! : U64, Str, Box(() -> a), Bool => Bool
	row_get! : U64, Str => Box(() -> a)
	row_last! : U64, Str, Box(() -> a) => Box(() -> a)

	## A context's value, given by a provider: kept by the runtime, by its id, while what made it is.
	context_value! : Box(() -> a) => U64

	## The id of the value the nearest provider of the named context gives, or 0 with none.
	context_find! : Str => U64
	context_get! : U64 => Box(() -> a)

	## On the server: the request being answered, as HTTP writes it: `METHOD target`, a header a
	## line (`name: value`), a blank line, then its body.
	request! : {} => Str

	## Where the page is: its path, and a query after a `?`, a trailing slash dropped. On the server,
	## the request's; in the browser, the location the page on screen was rendered for (committed by
	## each navigation in place, D-040), a source the reading computation tracks.
	location! : {} => Str

	## The app, as its root renders (`Generated/Root.roc`, D-040): the build's id, whether rocx built
	## it with `--dev`, and its route table (JSON rocx build wrote): the runtime keeps them, to know
	## which links are the app's pages and whether a fetched page is of this build.
	app! : Str, Bool, Str => {}

	## In a handler: navigates to a path, a path with a query, or a query alone (`replace`: the entry
	## replaced, not pushed; `scroll`: to the top, or the hash's element), once the handler is done.
	## Anywhere else, it fails.
	navigate! : Str, Bool, Bool => {}

	## Whether a navigation is on its way (tracked): from a click until the new page is on screen.
	is_routing! : {} => Bool

	## A `Router.use_before_leave!` listener, owned by the component or computation running (it stops
	## when that goes): run as a handler before each navigation in place, `event_value!` the leave
	## (`Leave.of`); and asked ahead of a load, its writes dropped, again when what it read changes,
	## the browser's `beforeunload` prompt armed while one would stop it. Anywhere else, it fails; on
	## the server, let go of.
	before_leave! : Box(() => Str) => {}

	## In a `use_before_leave!` listener: stops the leave with this id (0: the load it is asked
	## about ahead of time). Once its listeners have all run, nothing.
	leave_prevent! : U64 => {}

	## In a handler: the leave with this id navigated to after all, once the handler is done
	## (`force`: its listeners not asked again). Anywhere else, it fails.
	leave_retry! : U64, Bool => {}

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

	## The flash a plain form's post came back with (`Server.flash!`), as JSON: in the browser, what
	## the page noted, whatever it is given; rendered by renderToString (the tests'), what Roc found
	## in the request's cookie, noted for the page.
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

	## A `<Meta>`, `<Link>` or `<Style>` (its hole's run): its key (`meta name=description`: a later
	## one with the same key takes its place; "" for none) and its markup, `data-rocx` on it. In the
	## browser, the runtime keeps each in `<head>` while its hole's computation is there, in the order
	## they first ran; rendering as a server would, noted for the page's `<head>`.
	head! : Str, Str => {}

	## The reads to read again, as JSON (`["/board"]`: a GET whose URL is one, or begins with one
	## and a `/` or a `?`): in a handler, in the browser, read again once it is done
	## (`Router.revalidate!`); anywhere else there, it fails. On the server, said in the answer of the
	## request being answered (`x-rocx-revalidate`), for the submission that sent it.
	revalidate! : Str => {}

	## Sends a submission to this URL again, by its id (0: the latest), with what it sent before
	## (in a handler, once it is done).
	submission_retry! : Str, U64 => {}

	## `create_optimistic!`'s write, in a handler: shown once the handler is done, and held until
	## the submissions the handler sent (or the form its submit event sends) are done; with none,
	## undone at once.
	optimistic_set! : U64, Box(() -> a) => {}

	## `Solid.untrack!`: the running computation's reads aren't tracked from `Bool.True` on, until
	## `Bool.False` (a computation made meanwhile tracks its own).
	untrack! : Bool => {}

	## A dev build's `Html.read_at!`: where the read a component's body is making is (a `.rocx`
	## file's line and column), "" once it is done; answers the place before, to put back.
	read_at! : Str => Str

	## Called by the running effect's `compute`, first (D-052): whether it is a render effect
	## (`create_render_effect!`: its apply runs at once, as the render does), and the box of its
	## error handler (`create_effect_with!`'s `error`, `keep!`'s id; 0 for none), which a failed
	## `compute` calls instead of the nearest <Errored>.
	effect_options! : Bool, U64 => {}

	## Whether the running computation tracks what it reads, and runs again when it changes (a hole,
	## an attribute, a memo, an effect's compute): not a handler, a component's body, a part's first
	## run, nor inside `untrack!`. Whether a store's selection is worth making (D-053).
	tracking! : {} => Bool

	## The running memo's value, or `fallback` when it has none yet: what a store's selection
	## compares its new value with (D-053).
	memo_last! : Box(() -> a) => Box(() -> a)

	## A signal's value as the running handler leaves it: its own write, not yet applied, if it made
	## one, else the signal's. So two writes to a store in one handler compose, as two of Solid's
	## draft setters do (D-053).
	signal_latest! : U64 => Box(() -> a)
}
