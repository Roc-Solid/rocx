## What the Rust host does for Roc (`server/host/src/hosted.rs`): general effects, which the
## platform's modules build on (`Db`, `Live`, `Log`, `Time`, `Tcp`, `Http`, `Random`, `AesGcm`,
## `P256`, `Env`, `Plugin`; and, in Roc, `Actor`, the migrations; and the packages' plugins: jobs
## and cron, email). An error here is the host's message.
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

	## The offset from UTC, in seconds, of the IANA time zone named (`Europe/Warsaw`) at a moment
	## (milliseconds since the epoch), summer time counted; an `Err` for a name it doesn't know.
	zone_offset! : Str, I64 => Try(I64, Str)

	## Nanoseconds since the Unix epoch, on a clock that doesn't go back while the server runs: the
	## system clock's when the server started, plus a steady clock's time since.
	now_nanos! : {} => U64

	## A setting the server was started with: `database_url` (`--database-url`), `dev` ("yes" with
	## `--dev`), `debug` ("yes" with `--debug`), `public_url` (`--public-url`, or else where it
	## listens). Empty when it wasn't given.
	setting! : Str => Str

	## Whether the server is stopping: a background loop's cue to end.
	stopping! : {} => Bool

	## Runs a part of the app (a plugin's call, `<plugin>.<name>`) in a call of its own, as
	## `isolated_for_host!`, within
	## `limit_ms` milliseconds (0: no limit): its answer (status 0), why it failed (1), the crash
	## that ended it (2), or "timed out after …" (3: the first effect that waited past the limit cut
	## it off). The call has its own context (its transaction, its rooms), and what it allocated is
	## freed if it crashes or is cut off.
	isolated! : Str, Str, U64 => { status : U8, out : Str }

	## The app's kinds of actor (`program.actors`), a name a line, given as the platform starts: a
	## message to any other kind is refused.
	actor_kinds! : Str => {}

	## A plugin's file (`Plugin.File`), given as the platform starts: the host answers `GET` and
	## `HEAD` at `url` (`/rocx/plugins/push/push.js`, `/push-sw.js`) with `body`, as it is, its
	## `content_type` and an ETag of its bytes, before the app (and its middleware) sees the request;
	## any other method, 405.
	plugin_file! : Str, Str, List(U8) => {}

	## The plugins' scripts, a URL a line (`/rocx/plugins/audio/audio.js`), given as the platform
	## starts: every page the host renders loads each, a `<script type="module">` before start.js.
	page_scripts! : Str => {}

	## Asks the actor of kind `kind` called `key`, its message as JSON: its reply (JSON), once it has
	## handled the messages before it (`actor_for_host!` runs its turn); or why there is none: the
	## message isn't one it takes, it crashed, it is waiting on this call's actor (refused at once),
	## or it hasn't answered in 30 s.
	actor_ask! : Str, Str, Str => Try(Str, Str)

	## Sends the actor of kind `kind` called `key` a message (JSON), answered by no one: one it
	## doesn't take is logged as an error.
	actor_tell! : Str, Str, Str => {}

	## Sends the actor of kind `kind` called `key` a message (JSON) in `ms` milliseconds, as the timer
	## numbered `timer` (`actor_cancel!`). The host keeps it in memory; with a database, the platform
	## keeps its row (`ActorTimers`), which the host deletes once its turn has ended.
	actor_after! : Str, Str, U64, Str, U64 => {}

	## Stops a timer whose message hasn't been handled: waiting, or fired with its turn still to come.
	actor_cancel! : U64 => {}

	## A value the server keeps in its memory, by name (an `Err` when it has none): what the
	## platform's start keeps (`Registry`). Set a handful of times: each value set stays.
	store_get! : Str => Try(Str, Str)

	store_set! : Str, Str => {}

	## The text under a key in the server's key-value store (`Kv`), a list as a JSON array; an `Err`
	## when there is none, or it has expired.
	kv_get! : Str => Try(Str, Str)

	## Keeps text under a key for so many milliseconds (0: until the server stops).
	kv_set! : Str, Str, U64 => {}

	## Forgets a key.
	kv_delete! : Str => {}

	## The text under a key, forgotten as it is read: one caller gets it.
	kv_take! : Str => Try(Str, Str)

	## Keeps text under a key only if nothing is there: whether it did.
	kv_add! : Str, Str, U64 => Bool

	## Replaces the text under a key with another, for so many milliseconds, only if it is still
	## the text given: whether it did (D-043).
	kv_swap! : Str, Str, Str, U64 => Bool

	## Adds to the integer under a key (0 if none, its time to live starting then): the new value,
	## as text, or why it can't (what is there isn't an integer).
	kv_increment! : Str, I64, U64 => Try(Str, Str)

	## Puts text at the front of the list under a key, keeping so many of the newest.
	kv_push! : Str, Str, U64, U64 => {}

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

	## AES-GCM with the caller's 12-byte nonce (`AesGcm.seal_with_nonce!`): AES-128 under a 16-byte
	## key, AES-256 under a 32-byte one; the ciphertext, then the tag; or "bad key", "bad nonce".
	aes_gcm_seal_with_nonce! : List(U8), List(U8), List(U8) => Try(List(U8), Str)

	## ECDH on P-256 with a key pair made for this call alone (`P256.ecdh!`): its public key (65
	## bytes, uncompressed), then the 32-byte secret it shares with the peer's; or "bad key" when
	## the peer's isn't an uncompressed point on the curve.
	p256_ecdh! : List(U8) => Try(List(U8), Str)

	## ES256 (`P256.sign!`): the signature of the message (the third) by the private key (the first,
	## 32 bytes) whose public key is the second (65 bytes), 64 bytes, `r` then `s`; or "bad key"
	## when the keys aren't a pair.
	p256_sign! : List(U8), List(U8), List(U8) => Try(List(U8), Str)

	## The process's environment variable `name` (an `Err` when it has none).
	env_var! : Str => Try(Str, Str)

	## A request to another server (`Http`): its method, URL, headers (`name: value` a line) and
	## body; given up after `timeout_ms` (0: never), refused past `max_bytes` of body (0: any size),
	## redirects followed if `follow`, through the proxy `via` says (`env`: the environment's,
	## `direct`: none, `via <url>`: that one). Any status is an answer, its headers a `name: value` a
	## line; an `Err` means there was none: "timed out", "too large", or why.
	http_send! : Str, Str, Str, List(U8), U64, U64, Bool, Str => Try({ status : U16, headers : Str, body : List(U8) }, Str)

	## The same request, its answer's body kept for this call to read in chunks (`http_read!`): `<id>
	## <status>`, a line break, then its headers, a `name: value` a line. The time limit runs to the
	## body's last byte, and `max_bytes` counts every chunk.
	http_open! : Str, Str, Str, List(U8), U64, U64, Bool, Str => Try(Str, Str)

	## The next chunk of an answer's body this call keeps (`http_open!`), as it comes: `[]` at its
	## end; "timed out", "too large", or why it broke off. After either, the host has let it go.
	http_read! : U64 => Try(List(U8), Str)

	## Lets go of an answer's body this call keeps before its end: its connection is closed (unless
	## the rest of it has come already). The host lets go of what a call keeps when the call ends.
	http_close! : U64 => {}

	## Opens the app's database at a URL (`postgres://…`, `sqlite:<path>` or `turso:<path>`): its
	## flavor, "postgres", "sqlite" or "turso". The platform's start calls it once, before anything
	## reads.
	db_open! : Str => Try(Str, Str)

	## The database the server opened: "postgres", "sqlite", "turso", or "" for none.
	db_flavor! : {} => Str

	## The rows a statement reads, as a JSON array of objects (a column's name, its value), for
	## the parameters in `params`, a JSON array of text, integers, booleans and nulls (Postgres is
	## sent each as text, which it reads as the type its place wants; SQLite and Turso bind each as
	## it is).
	db_query! : Str, Str => Try(Str, Str)

	## How many rows a statement changed.
	db_execute! : Str, Str => Try(U64, Str)

	## Runs statements, one after another, with no parameters (a migration).
	db_script! : Str => Try({}, Str)

	## Begins a transaction on a connection this call keeps (every statement goes to it) until it
	## commits or rolls back. A call that ends with one open rolls it back. Inside the one the call
	## has open, it begins a level of it instead (D-076): a savepoint, which `db_commit!` releases
	## and `db_rollback!` rolls back to, the transaction around it going on.
	db_begin! : {} => Try({}, Str)

	db_commit! : {} => Try({}, Str)

	db_rollback! : {} => {}

	## Whether the call's last transaction, rolled back, lost to another's write to the same row,
	## or needed to be exclusive (it changed the schema): on Turso's MVCC (D-049), where
	## transactions write at once. `Db.transaction!` runs its body again. Never for a level inside
	## a transaction still open (D-076): the whole transaction runs again, from its outermost level.
	db_conflicted! : {} => Bool

	## From now until this call ends, it hears what is notified on `channel` (`db_notify!`, or
	## Postgres's `pg_notify`) as messages on the topic `db:<channel>` (`live_next!`).
	db_listen! : Str => Try({}, Str)

	## Tells `channel`'s listeners a payload: when this call's transaction commits (never, if it
	## rolls back), or at once outside one.
	db_notify! : Str, Str => Try({}, Str)

	## Keeps bytes at a key under a root (`file:<dir>`, `memory:<name>`), with their content type,
	## in place of what was there (`Blobs`, D-047).
	blob_put! : Str, Str, List(U8), Str => Try({}, Str)

	## The bytes at a key, whole; `Err("NotFound")` for none.
	blob_get! : Str, Str => Try(List(U8), Str)

	## So many bytes at a key from an offset (fewer at its end), and its size; `Err("NotFound")`.
	blob_range! : Str, Str, U64, U64 => Try({ bytes : List(U8), size : U64 }, Str)

	## A key's size, content type and ETag; `Err("NotFound")`.
	blob_head! : Str, Str => Try({ size : U64, content_type : Str, etag : Str }, Str)

	## The bytes at a key gone (none is no problem).
	blob_delete! : Str, Str => Try({}, Str)

	## The keys' bytes joined in order, kept at another key with a content type; `Err("NotFound")`
	## when one isn't there.
	blob_compose! : Str, List(Str), Str, Str => Try({}, Str)

	## The keys under a root that start with a prefix, in order.
	blob_keys! : Str, Str => Try(List(Str), Str)

	## Whether a root can be written (a directory made when missing).
	blob_check! : Str => Try({}, Str)

	## A root's secret for signed URLs when its URL gives none: drawn once, kept while the server
	## runs.
	blob_secret! : Str => Str

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

	## The running memo's value; `same` (a store's selection, equal to the value it had) means
	## nothing here: the server computes a memo once.
	memo_done! : Box(() -> a), Bool => {}

	## The memo's value, or the failure it failed with.
	memo_get! : U64 => Box(() -> a)

	## A selector (`Solid.create_selector!`): its computation, run once (the server renders final
	## values), answers its source's key; its id.
	selector_new! : Box(() => Str) => U64

	## Whether `key` is the selector's key.
	selector_is! : U64, Str => Bool

	## A template's state (`Html.template`, D-084): always 0 here, the markup itself (the server
	## renders a page's HTML once; templates are for the browser).
	template! : Str => U32

	refresh! : Box(() => Str) => {}

	## False: the server renders final values, so nothing it renders is computed again.
	is_pending! : Box(() => Str) => Bool

	## Fails the caller, with why: the nearest <Errored> shows it.
	fail! : Str => {}
	event_value! : {} => Str

	## In an <Errored> fallback: the boundary, and what failed.
	boundary! : {} => U64
	problem! : {} => Str
	retry! : U64 => {}

	## A `.map`'s rows (`Html.rows!`, D-071): its id; a row's index; and a row's item, by its key
	## (`same`, the item equal to what it was, means nothing here: a list is read once; every row is
	## new, so it answers false); the row's item, or `fallback` for a new row.
	for_new! : {} => U64
	row_index! : U64, Str => U64
	row_set! : U64, Str, Box(() -> a), Bool => Bool
	row_get! : U64, Str => Box(() -> a)
	row_last! : U64, Str, Box(() -> a) => Box(() -> a)

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

	## The app, as its root renders (`Generated/Root.roc`, D-040): the build's id, which the page's
	## bootstrap carries (`data-build`), whether rocx built it with `--dev`, and its route table (the
	## browser's; the server keeps only the build).
	app! : Str, Bool, Str => {}

	## Navigating is the browser's (`Router.navigate!`): on the server no handler runs, and it does nothing.
	navigate! : Str, Bool, Bool => {}

	## A `<Navigate href>` rendered (D-040): the page answers with a 303 to `href` instead of itself,
	## as a redirect a read met while it rendered does (the first one).
	redirect_page! : Str => {}

	## Bool.False: on the server no navigation is on its way.
	is_routing! : {} => Bool

	## A `Router.use_before_leave!` listener: on the server no navigation happens, so it is let go of.
	before_leave! : Box(() => Str) => {}

	## Leaving is the browser's (`Leave.prevent!`, `Leave.retry!`): on the server, nothing.
	leave_prevent! : U64 => {}
	leave_retry! : U64, Bool => {}

	## The status the page being rendered is answered with (`<HttpStatusCode>`).
	status! : U16 => {}

	## A component's request, or its listening to events: the browser's, from a handler; never run
	## while the server renders.
	fetch! : Str, Str, Str, Str => Str
	listen! : Str, Box(() => Str) => {}

	## A channel's subscription, what is said on it, a resync: the browser's (`Endpoint.subscribe!`,
	## `say!`, `resync!`); on the server, nothing (its box is let go of).
	subscribe! : Str, Box(() => Str) => {}
	say! : Str, Str => {}
	resync! : Str => {}

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

	## The flash a plain form's post came back with (`Server.flash!`), which Roc took from the store
	## (`FlashStore`): noted for the page (a script the browser reads), and given back. Given "", the
	## flash this render noted already, or "": a page may read it in several places, and the store
	## gives it once.
	flash! : Str => Str

	## The runtime's form submissions are the browser's: none on the server.
	action! : Str => {}
	submission! : Str => Str
	submission_clear! : Str => {}
	submissions! : Str => Str
	submit! : Str, Str, Str, Str => {}
	submission_drop! : Str, U64 => {}

	## The document's title, as a `<Title>` says it while the server renders: noted for the page,
	## whose `<head>` gets it, the last one rendered's (`<title data-rocx>`).
	title! : Str => {}

	## A `<Meta>`, `<Link>` or `<Style>` while the server renders: its key (a later one with the same
	## key takes its place; "" for none) and its markup, noted for the page's `<head>`, before
	## `</head>`, in the order they ran.
	head! : Str, Str => {}

	## While a request is answered: the reads its submission has read again in the browser, as JSON
	## (`["/board"]`), said in the answer (`x-rocx-revalidate`). Elsewhere, nothing.
	revalidate! : Str => {}

	## Submissions and optimistic writes are the browser's: nothing on the server.
	submission_retry! : Str, U64 => {}
	optimistic_set! : U64, Box(() -> a) => {}

	## `Solid.untrack!`: the running computation's reads aren't tracked from `Bool.True` on, until
	## `Bool.False`. The server tracks nothing, but a hole whose reads were all untracked is static.
	untrack! : Bool => {}

	## A dev build's `Html.read_at!`: in the browser, where the read a component's body is making is.
	## The server warns of none: it answers "".
	read_at! : Str => Str

	## An effect's options (`create_render_effect!`, `create_effect_with!`): the browser's; no effect
	## runs on the server.
	effect_options! : Bool, U64 => {}

	## False: on the server nothing runs again, so a store's selection is read once, and nothing is
	## made for it (D-053).
	tracking! : {} => Bool

	## The running memo's value, or `fallback` when it has none yet. Unused on the server, where
	## nothing makes a selection.
	memo_last! : Box(() -> a) => Box(() -> a)

	## A signal's value: on the server no handler writes one.
	signal_latest! : U64 => Box(() -> a)
}
