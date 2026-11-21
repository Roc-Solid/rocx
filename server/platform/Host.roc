## What the Rust host does for Roc (`server/host/src/hosted.rs`): general effects, which the
## platform's modules build on (`Db`, `Live`, `Log`, `Time`, `Tcp`, `Http`, `Random`, `AesGcm`,
## `Env`; and, in Roc, `Job`,
## `Cron`, `Actor`, `Email`, the migrations). An error here is the host's message.
Host := [].{

	## An event on the server's log (stderr, `Log`): its level (0 debug, 1 info, 2 warn, 3 error),
	## its message, and its fields as JSON (an object), or "" with none. The host formats it, as
	## it does its own lines, pretty or as JSON (`log_format!`), on a thread of its own.
	log! : U8, Str, Str => {}

	## The log's format, as the app's `program` says (`logs.format`), given as the platform starts:
	## 0 `Auto` (`ROCX_LOG`, or else pretty on a terminal and JSON elsewhere), 1 `Pretty`, 2 `Json`.
	log_format! : U8 => {}

	## Writes to the response of the stream this thread is sending; whether its client is still
	## there to read it.
	send! : Str => Bool

	## Waits so many milliseconds, or less if the client of the stream this thread is sending goes.
	sleep! : U64 => {}

	## Milliseconds since the Unix epoch.
	now_millis! : {} => U64

	## Nanoseconds since the Unix epoch, on a clock that doesn't go back while the server runs: the
	## system clock's when the server started, plus a steady clock's time since.
	now_nanos! : {} => U64

	## A setting the server was started with: `database` ("yes" with one), `job-workers`,
	## `job-retry-ms`, `smtp-url`, `mail-from`, `dev` ("yes" with `--dev`), `debug`
	## ("yes" with `--debug`). Empty when it wasn't given.
	setting! : Str => Str

	## Whether the server is stopping: a background loop's cue to end.
	stopping! : {} => Bool

	## Runs a part of the app (`job:<kind>`) in a call of its own, as `isolated_for_host!`, within
	## `limit_ms` milliseconds (0: no limit): its answer (status 0), why it failed (1), the crash
	## that ended it (2), or "timed out after …" (3: the first effect that waited past the limit cut
	## it off). The call has its own context (its transaction, its rooms), and what it allocated is
	## freed if it crashes or is cut off.
	isolated! : Str, Str, U64 => { status : U8, out : Str }

	## The app's kinds of actor (`program.actors`), a name a line, given as the platform starts: a
	## message to any other kind is refused.
	actor_kinds! : Str => {}

	## Asks the actor of kind `kind` called `key`, its message as JSON: its reply (JSON), once it has
	## handled the messages before it (`actor_for_host!` runs its turn); or why there is none: the
	## message isn't one it takes, it crashed, it is waiting on this call's actor (refused at once),
	## or it hasn't answered in 30 s.
	actor_ask! : Str, Str, Str => Try(Str, Str)

	## Sends the actor of kind `kind` called `key` a message (JSON), answered by no one: one it
	## doesn't take is logged as an error.
	actor_tell! : Str, Str, Str => {}

	## Sends the actor of kind `kind` called `key` a message (JSON) in `ms` milliseconds: the timer's
	## number (`actor_cancel!`). Timers are in the server's memory: a restart loses them.
	actor_after! : Str, Str, U64, Str => U64

	## Stops a timer that hasn't fired.
	actor_cancel! : U64 => {}

	## A value the server keeps in its memory, by name (an `Err` when it has none): what the
	## platform's start keeps (`Registry`). Set a handful of times: each value set stays.
	store_get! : Str => Try(Str, Str)

	store_set! : Str, Str => {}

	## A random number from the operating system.
	random_u64! : {} => U64

	## So many random bytes from the operating system.
	random_bytes! : U64 => List(U8)

	## AES-256-GCM under a 32-byte key (`AesGcm`): the nonce (fresh, random), the ciphertext and the
	## tag; or "bad key".
	aes_gcm_seal! : List(U8), List(U8) => Try(List(U8), Str)

	## What `aes_gcm_seal!` sealed; "bad key", or "forged" when it wasn't sealed under this key or
	## was changed.
	aes_gcm_open! : List(U8), List(U8) => Try(List(U8), Str)

	## The process's environment variable `name` (an `Err` when it has none).
	env_var! : Str => Try(Str, Str)

	## A request to another server (`Http`): its method, URL, headers (`name: value` a line) and
	## body; given up after `timeout_ms` (0: never), refused past `max_bytes` of body (0: any size),
	## redirects followed if `follow`. Any status is an answer, its headers a `name: value` a line;
	## an `Err` means there was none: "timed out", "too large", or why.
	http_send! : Str, Str, Str, List(U8), U64, U64, Bool => Try({ status : U16, headers : Str, body : List(U8) }, Str)

	## Keeps a message (a JSON object) in the outbox in memory (a server with no database), giving it
	## an `id`: the dev mailbox shows it (`Mailbox`).
	outbox_keep! : Str => {}

	## The outbox in memory, as a JSON array, oldest first.
	outbox_list! : {} => Str

	outbox_clear! : {} => {}

	## The rows a statement reads, as a JSON array of objects (a column's name, its value), for
	## the parameters in `params`, a JSON array of strings and nulls: Postgres reads each as the
	## type its place in the statement wants.
	db_query! : Str, Str => Try(Str, Str)

	## How many rows a statement changed.
	db_execute! : Str, Str => Try(U64, Str)

	## Runs statements, one after another, with no parameters (a migration).
	db_script! : Str => Try({}, Str)

	## Begins a transaction on a connection this call keeps (every statement goes to it) until it
	## commits or rolls back. A call that ends with one open rolls it back.
	db_begin! : {} => Try({}, Str)

	db_commit! : {} => Try({}, Str)

	db_rollback! : {} => {}

	## From now until this call ends, it hears Postgres's notifications on `channel` (`notify`,
	## sent when the transaction that sent them commits) as messages on the topic `pg:<channel>`
	## (`live_next!`).
	db_listen! : Str => Try({}, Str)

	## Sends `message` to every call listening to `topic`.
	live_publish! : Str, Str => {}

	## From now until this call ends, it hears what is published on `topic`.
	live_listen! : Str => {}

	## This call is in `room` until it ends; joining and leaving are published on `room`.
	live_join! : Str => {}

	## How many calls are in `room`.
	live_count! : Str => U64

	## The next message on a topic this call listens to (`status` 0), or nothing within `ms`
	## milliseconds (1), or the stream's client has gone, or the server is stopping and this is a
	## background loop (2).
	live_next! : U64 => { status : U8, topic : Str, message : Str }

	## A connection to `host` at `port`, over TLS if `tls` (the server's name checked against the
	## web's certificate authorities): its id, which the call that made it owns; it is closed when
	## that call ends, if not before.
	tcp_connect! : Str, U16, Bool => Try(U64, Str)

	## Goes on over TLS (SMTP's STARTTLS), checking that the server is `host`.
	tcp_start_tls! : U64, Str => Try({}, Str)

	tcp_write! : U64, List(U8) => Try({}, Str)

	## Exactly so many bytes; `Err("eof")` if the connection ends first.
	tcp_read_exactly! : U64, U64 => Try(List(U8), Str)

	## What has come, up to so many bytes, waiting for some; none once the connection has ended.
	tcp_read_up_to! : U64, U64 => Try(List(U8), Str)

	## Up to and including the next `byte`; `Err("eof")` if the connection ends first.
	tcp_read_until! : U64, U8 => Try(List(U8), Str)

	tcp_close! : U64 => {}

	# ---- Signals: what the signals modules (Html, Solid, Show, For, Context, Server, Call, copied
	# from web/platform) ask of a host. Here the host renders a page of components on the server
	# (`server/host/src/signals.rs`), as web/runtime.js's `renderToString` does: each hole run
	# once, nothing tracked, nothing waiting. ----

	## Keeps a computation, handler or fallback; its id goes in the markup's JSON.
	keep! : Box(() => Str) => U64
	signal_new! : Box(() -> a) => U64
	signal_get! : U64 => Box(() -> a)

	## On the server a signal isn't written: a handler never runs.
	signal_set! : U64, Box(() -> a) => {}

	## Makes a memo from its computation, and runs it.
	memo_new! : Box(() => Str) => U64

	## The running memo's value.
	memo_done! : Box(() -> a) => {}

	## The memo's value, or the failure it failed with.
	memo_get! : U64 => Box(() -> a)
	refresh! : Box(() => Str) => {}

	## Fails the caller, with why: the nearest <Errored> shows it.
	fail! : Str => {}
	event_value! : {} => Str

	## In an <Errored> fallback: the boundary, and what failed.
	boundary! : {} => U64
	problem! : {} => Str
	retry! : U64 => {}

	## A `<For>`'s rows: its id; a row's index; and a row's item, by its key.
	for_new! : {} => U64
	row_index! : U64, Str => U64
	row_set! : U64, Str, Box(() -> a) => {}
	row_get! : U64, Str => Box(() -> a)

	## A context's value, given by a provider, by its id.
	context_value! : Box(() -> a) => U64

	## The id of the value the nearest provider of the named context gives, or 0 with none.
	context_find! : Str => U64
	context_get! : U64 => Box(() -> a)

	## The request being answered, as HTTP writes it: `METHOD target`, a header a line
	## (`name: value`), a blank line, then its body.
	request! : {} => Str

	## The request's path, and its query after a `?`, a trailing slash dropped: `Router.location!`.
	location! : {} => Str

	## The status the page being rendered is answered with (`<HttpStatusCode>`).
	status! : U16 => {}

	## A component's request, or its listening to events: the browser's, from a handler; never run
	## while the server renders.
	fetch! : Str, Str, Str, Str => Str
	listen! : Str, Box(() => Str) => {}

	## A component's timers: the browser's. Rendering, the server starts none (the id is 0), and
	## clearing one does nothing.
	timeout! : U64, Box(() => Str) => U64
	interval! : U64, Box(() => Str) => U64
	clear_timer! : U64 => {}

	## A call of the page's own function (`Browser.call!`): a handler's, in the browser. The server
	## renders without it, so it fails here.
	browser_call! : Str, Str => {}

	## Effects and cleanups are the browser's: on the server none runs (their boxes are let go of),
	## since nothing they would undo started.
	effect_new! : Box(() => Str) => {}
	cleanup! : Box(() => Str) => {}

	## The flash a plain form's post came back with (`Server.flash!`), which Roc found in the
	## request's cookie: noted for the page (a script the browser reads), and given back.
	flash! : Str => Str

	## The runtime's form submissions are the browser's: none on the server.
	action! : Str => {}
	submission! : Str => Str
	submission_clear! : Str => {}

	## The document's title, as a `<Title>` says it while the server renders: noted for the page,
	## whose `<head>` gets it, the last one rendered's (`<title data-rocx>`).
	title! : Str => {}
}
