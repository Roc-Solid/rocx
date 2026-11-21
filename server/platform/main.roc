## The server's platform: Roc compiled to native code, in a Rust host (`server/host`). The host
## answers HTTP with tokio and hyper and gives Roc a few general effects: Postgres, time, live
## topics and rooms, background loops, calls run in isolation, actors' mailboxes and timers, TCP and
## TLS. Jobs, cron, migrations, actors' state and email are Roc, here, built on them. The browser's
## platform is `web/platform`, wasm; an app is two programs, one on each, talking over HTTP.
##
## - `respond!(method, target, headers, body, context)` answers a request: a page or an endpoint.
##   `target` is the path and the query; `headers` a `name: value` a
##   line; `body` the bytes as they came; `context` what the server was started with
##   (`--context-file`). Its answer is a `Server.Response`, whose body is text; bytes, sent as they
##   are; a body the host fetches from elsewhere and sends on as it comes, never through Roc
##   (`Forward`); a page of components (`Page`), which the host renders for the request, every hole run
##   once, into a document for the browser to hydrate, with the answers its endpoint reads got
##   and `/rocx/start.js` before `</body>` (a HEAD isn't rendered; `Host.status!`,
##   `<HttpStatusCode>`, sets the status); or a stream of events
##   (server-sent events, `Events`): a loop the host runs on a thread of its own, to its end, with
##   `{ send!, sleep! }`. `send!` writes to the response and says whether the client is still
##   there, `sleep!` waits that many milliseconds (and wakes early if the client goes).
## - `migrations`: the app's schema, applied once each, in order, when the server starts (each a
##   name and its SQL: `import "migrations/0001_notes.sql" as notes : Str` embeds a file).
## - `jobs`: the kinds of job the server's workers run (`Job.handler(kind)`: each with its attempts
##   and time limit); `crons`: jobs on a schedule (`Cron.every`). The jobs page (`JobsPage`) is the
##   app's to mount, behind its own middleware.
## - `actors`: the kinds of actor the app defines (`Actor.handler(kind)`), which `rocx build` lists:
##   the host runs their turns (`actor_for_host!`), one message at a time each, and refuses a
##   message to a kind that isn't here.
## - `logs`: the format of the server's log (`Log`), the host's lines and the app's: `{ format: Auto }`
##   (`ROCX_LOG`, `pretty` or `json`, if it is set; or else pretty when stderr is a terminal, and JSON
##   when it isn't), `Pretty` or `Json`. `App.program` says `Auto`; an app says otherwise with
##   `{ ..App.program(…), logs: { format: Json } }`.
## - Under `--dev`, the platform answers `/__rocx/mail` itself: the dev mailbox (`Outbox`), email
##   kept rather than sent.
## - A page's components are Solid-style (web/runtime.js hydrates the document in the browser). A
##   GET endpoint a component reads while the host renders the page (`Endpoint.get!`) is answered by
##   its route, in-process (`Host.fetch!`). The modules components are written with (`Html`, `Solid`, `Show`,
##   `For`, `Loading`, `Errored`, `Context`, `Call`, `Router`, `HttpStatusCode`), and HTTP's
##   (`Server`, `Endpoint`, `Middleware`, `Events`, `OpenApi`), are the browser's platform's
##   (web/platform), copied here by the build, so the same code compiles on both.
##
## Each call runs on a thread of its own from a pool, so an effect (`Db.all!`, a stream's
## `sleep!`) may wait without holding up other requests. A crash (`crash`, an integer
## overflowing) ends that call only: the host answers 500 (or ends the stream, or the job's call, or
## the actor's turn), frees what the call had allocated, rolls back its transaction, and goes on.
platform ""
	requires {
		program : {
			respond! : Str, Str, Str, List(U8), Str => Server.Response,
			migrations : List({ name : Str, sql : Str }),
			jobs : List({ name : Str, attempts : U64, timeout_ms : U64, run! : Str => Try({}, Str) }),
			crons : List({ name : Str, schedule : Str, job : Str, input : Str }),
			actors : List({ name : Str, run! : Str, Str, Str => Try({ state : Str, reply : Str }, Str) }),
			logs : { format : [Auto, Pretty, Json] },
		}
	}
	exposes [Actor, AesGcm, Audio, Browser, Call, Channel, Context, Cron, Db, Email, Endpoint, Env, Errored, Events, For, Html, Http, HttpResponse, HttpStatusCode, Job, JobsPage, Live, Loading, Log, Middleware, OpenApi, Random, Router, Server, Show, Solid, Submission, Tcp, Time, Title, Transition]
	packages {}
	provides {
		"roc_actor": actor_for_host!,
		"roc_background": background_for_host!,
		"roc_background_count": background_count_for_host!,
		"roc_drop_feed": drop_feed_for_host,
		"roc_init": init_for_host!,
		"roc_isolated": isolated_for_host!,
		"roc_respond": respond_for_host!,
		"roc_run": run_for_host!,
		"roc_stream": stream_for_host!,
	}
	hosted {
		"roc_action": Host.action!,
		"roc_boundary": Host.boundary!,
		"roc_browser_call": Host.browser_call!,
		"roc_cleanup": Host.cleanup!,
		"roc_clear_timer": Host.clear_timer!,
		"roc_context_find": Host.context_find!,
		"roc_context_get": Host.context_get!,
		"roc_context_value": Host.context_value!,
		"roc_effect_new": Host.effect_new!,
		"roc_event_value": Host.event_value!,
		"roc_fail": Host.fail!,
		"roc_fetch": Host.fetch!,
		"roc_flash": Host.flash!,
		"roc_for_new": Host.for_new!,
		"roc_host_actor_after": Host.actor_after!,
		"roc_host_actor_ask": Host.actor_ask!,
		"roc_host_actor_cancel": Host.actor_cancel!,
		"roc_host_actor_kinds": Host.actor_kinds!,
		"roc_host_actor_tell": Host.actor_tell!,
		"roc_host_aes_gcm_open": Host.aes_gcm_open!,
		"roc_host_aes_gcm_seal": Host.aes_gcm_seal!,
		"roc_host_db_begin": Host.db_begin!,
		"roc_host_db_commit": Host.db_commit!,
		"roc_host_db_execute": Host.db_execute!,
		"roc_host_db_listen": Host.db_listen!,
		"roc_host_db_query": Host.db_query!,
		"roc_host_db_rollback": Host.db_rollback!,
		"roc_host_db_script": Host.db_script!,
		"roc_host_env_var": Host.env_var!,
		"roc_host_http_send": Host.http_send!,
		"roc_host_isolated": Host.isolated!,
		"roc_host_live_count": Host.live_count!,
		"roc_host_live_join": Host.live_join!,
		"roc_host_live_listen": Host.live_listen!,
		"roc_host_live_next": Host.live_next!,
		"roc_host_live_publish": Host.live_publish!,
		"roc_host_log": Host.log!,
		"roc_host_log_format": Host.log_format!,
		"roc_host_now_millis": Host.now_millis!,
		"roc_host_now_nanos": Host.now_nanos!,
		"roc_host_outbox_clear": Host.outbox_clear!,
		"roc_host_outbox_keep": Host.outbox_keep!,
		"roc_host_outbox_list": Host.outbox_list!,
		"roc_host_random_bytes": Host.random_bytes!,
		"roc_host_random_u64": Host.random_u64!,
		"roc_host_send": Host.send!,
		"roc_host_setting": Host.setting!,
		"roc_host_sleep": Host.sleep!,
		"roc_host_stopping": Host.stopping!,
		"roc_host_store_get": Host.store_get!,
		"roc_host_store_set": Host.store_set!,
		"roc_host_tcp_close": Host.tcp_close!,
		"roc_host_tcp_connect": Host.tcp_connect!,
		"roc_host_tcp_read_exactly": Host.tcp_read_exactly!,
		"roc_host_tcp_read_until": Host.tcp_read_until!,
		"roc_host_tcp_read_up_to": Host.tcp_read_up_to!,
		"roc_host_tcp_start_tls": Host.tcp_start_tls!,
		"roc_host_tcp_write": Host.tcp_write!,
		"roc_interval": Host.interval!,
		"roc_keep": Host.keep!,
		"roc_listen": Host.listen!,
		"roc_location": Host.location!,
		"roc_memo_done": Host.memo_done!,
		"roc_memo_get": Host.memo_get!,
		"roc_memo_new": Host.memo_new!,
		"roc_problem": Host.problem!,
		"roc_refresh": Host.refresh!,
		"roc_request": Host.request!,
		"roc_resync": Host.resync!,
		"roc_retry": Host.retry!,
		"roc_row_get": Host.row_get!,
		"roc_row_index": Host.row_index!,
		"roc_row_set": Host.row_set!,
		"roc_say": Host.say!,
		"roc_signal_get": Host.signal_get!,
		"roc_signal_new": Host.signal_new!,
		"roc_signal_set": Host.signal_set!,
		"roc_status": Host.status!,
		"roc_submission": Host.submission!,
		"roc_submission_clear": Host.submission_clear!,
		"roc_subscribe": Host.subscribe!,
		"roc_timeout": Host.timeout!,
		"roc_title": Host.title!,
	}
	targets: {
		inputs_dir: "targets/",
		arm64mac: { inputs: ["libhost.a", app] },
		x64mac: { inputs: ["libhost.a", app] },
		arm64musl: { inputs: ["rcrt1.o", "libhost.a", app, "libunwind.a", "libc.a"] },
		x64musl: { inputs: ["rcrt1.o", "libhost.a", app, "libunwind.a", "libc.a"] },
	}

import Actor
import ActorTurn
import AesGcm
import Audio
import Browser
import Call
import Channel
import Context
import Cron
import CronTicker
import Db
import Email
import Endpoint
import Env
import Errored
import Events
import For
import Host
import Html
import Http
import HttpResponse
import HttpStatusCode
import Job
import JobsPage
import JobWorker
import Live
import Loading
import Log
import Outbox
import Middleware
import Migrations
import OpenApi
import Random
import Registry
import Router
import Server
import Setting
import Show
import Solid
import Submission
import Tcp
import Time
import Title
import Transition

## A stream an answer sends (`respond!`'s `feed`): a loop, run with the host's `send!` and
## `sleep!`. The host keeps it boxed in a record: a box it doesn't look into. (A boxed function
## would be one it calls, and the functions in its argument would have to be boxed too.)
Feed : { run! : { send! : Str => Bool, sleep! : U64 => {} } => {} }

## The answer, as the host takes it (`Server.for_host`): its `kind` says which it sends, its `text`
## (0), the page (1), the stream (2), its `bytes` (3) or the `upstream` the host fetches its body
## from (4). The page is boxed for the host to run
## (`run_for_host!`): run, it renders the page's components, its holes kept by the host, as JSON
## (`Html.serialize!`). The boxes an answer doesn't send do nothing, and the host releases them.
## Under `--dev`, the platform answers the dev mailbox's paths itself (`Outbox`).
respond_for_host! : Str, Str, Str, List(U8), Str => { status : U16, headers : Str, kind : U8, text : Str, bytes : List(U8), upstream : { method : Str, url : Str, headers : Str }, page : Box(() => Str), feed : Box(Feed) }
respond_for_host! = |method, target, headers, body, context| {
	answered =
		if Outbox.serves!(target) {
			Outbox.respond!(Server.from_http(method, target, headers, body))
		} else {
			(program.respond!)(method, target, headers, body, context)
		}
	answer = Server.for_host(answered)
	view! = answer.page
	{
		status: answer.status,
		headers: answer.headers,
		kind: answer.kind,
		text: answer.text,
		bytes: answer.bytes,
		upstream: answer.upstream,
		page: Box.box(|| Html.serialize!(view!({}))),
		feed: Box.box({ run!: answer.feed }),
	}
}

## The stream, sent to its end on the thread the host gave it.
stream_for_host! : Box(Feed) => {}
stream_for_host! = |boxed| {
	{ run! } = Box.unbox(boxed)
	# Each in a lambda: a hosted function passed on as it is traps in optimized wasm (Roc
	# nightly-2026-11-18: `--opt=speed`, or `--specialize=yes`).
	run!({ send!: |data| Host.send!(data), sleep!: |ms| Host.sleep!(ms) })
}

## A stream the host won't send (the answer wasn't one, or was to a HEAD), handed back here to be
## released: Roc lets go of the box, the function in it and what that captured.
drop_feed_for_host : Box(Feed) -> {}
drop_feed_for_host = |_| {}

## The server is starting, connected to its database if it has one: the log takes the app's format
## (before anything is logged: a migration, a bad schedule), the kinds of job and the schedules are
## kept for the modules that read them (`Registry`), the host is told the kinds of actor; the
## schedules are checked (a bad
## one, or one naming a job the app doesn't list, stops it here), then the platform's tables and the
## app's migrations are applied, and the jobs a stop cut short are queued again.
init_for_host! : {} => Try({}, Str)
init_for_host! = |{}| {
	Host.log_format!(
		match program.logs.format {
			Auto => 0
			Pretty => 1
			Json => 2
		},
	)
	# The kinds of job the app runs (names, attempts, time limits): its workers take only these.
	kinds = program.jobs.map(|job| { name: job.name, attempts: job.attempts, timeout_ms: job.timeout_ms })
	names = kinds.map(|kind| kind.name)
	Registry.keep!(kinds, program.crons)
	Host.actor_kinds!(Str.join_with(program.actors.map(|actor| actor.name), "\n"))
	match Cron.check(program.crons, names) {
		Err(why) => Err(why)
		Ok({}) =>
			if Setting.database!({}) {
				match Migrations.apply!(Migrations.own.concat(program.migrations)) {
					Err(why) => Err(why)
					Ok({}) => JobWorker.recover!(names)
				}
			} else {
				Ok({})
			}
	}
}

## What the server runs in the background, each loop on a thread of its own: the job workers and
## the schedules (with a database), and a look at the SMTP server (with one).
Loop : [Work, Schedules, CheckMail]

loops! : {} => List(Loop)
loops! = |{}| {
	database = Setting.database!({})
	workers = if (database and !program.jobs.is_empty()) List.repeat(Work, Setting.number!("job-workers", 4)) else []
	schedules = if (database and !program.crons.is_empty()) [Schedules] else []
	mail = if (Setting.text!("smtp-url").is_empty()) [] else [CheckMail]
	workers.concat(schedules).concat(mail)
}

background_count_for_host! : {} => U64
background_count_for_host! = |{}| loops!({}).len()

## Runs the background loop at `index` to its end: a worker or the schedules, until the server
## stops; the mail check, once.
background_for_host! : U64 => {}
background_for_host! = |index|
	match loops!({}).get(index) {
		Ok(Work) => JobWorker.run!(Registry.kinds!({}))
		Ok(Schedules) => CronTicker.run!(program.crons)
		Ok(CheckMail) => Email.check!({})
		Err(_) => {}
	}

## Runs a part of the app in a call of its own (`Host.isolated!`): a job (`job:<kind>`, its input).
## What it answers, or why it failed; a crash in it ends this call only.
isolated_for_host! : Str, Str => Try(Str, Str)
isolated_for_host! = |what, input|
	if what.starts_with("job:") {
		name = what.drop_prefix("job:")
		match program.jobs.find_first(|job| job.name == name) {
			Ok(job) =>
				match (job.run!)(input) {
					Ok({}) => Ok("")
					Err(why) => Err(why)
				}
			Err(_) => Err("no job is called ${name}: list it in the app's `jobs`")
		}
	} else {
		Err("nothing in the app is called ${what}")
	}

## An actor's turn, which its mailbox in the host runs (`actors.rs`): the actor of kind `kind`
## called `key`, its state as its last turn left it (`kept`, when `loaded`; else it is read), and
## the message, as JSON. Its next state and its reply, or why it has none: its kind isn't the app's,
## or it doesn't take the message. A crash in it ends the turn only.
actor_for_host! : Str, Str, Bool, Str, Str => Try({ state : Str, reply : Str }, Str)
actor_for_host! = |kind, key, loaded, kept, message|
	match program.actors.find_first(|actor| actor.name == kind) {
		Ok(actor) => ActorTurn.run!(actor, key, loaded, kept, message)
		Err(_) => Err("no kind of actor is called ${kind}: the app defines none (`Actor.define`)")
	}

## Runs a box the host keeps: a page's (its markup), a hole, a memo, a fallback; its answer as JSON.
run_for_host! : Box(() => Str) => Str
run_for_host! = |runner| {
	run = Box.unbox(runner)
	run()
}
