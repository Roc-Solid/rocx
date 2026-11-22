## The server's platform: Roc compiled to native code, in a Rust host (`server/host`). The host
## answers HTTP with tokio and hyper and gives Roc a few general effects: Postgres, time, live
## topics and rooms, background loops, calls run in isolation, actors' mailboxes and timers, TCP and
## TLS. Migrations, plugins and actors' state are Roc, here, built on them; jobs and cron, and email,
## are packages' plugins (packages/jobs, packages/email: D-034, D-035), on the same effects. The browser's
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
##   (server-sent events, `Events`): a loop the host runs as a call of its own, to its end, with
##   `{ send!, sleep! }`. `send!` writes to the response and says whether the client is still
##   there, `sleep!` waits that many milliseconds (and wakes early if the client goes).
## - `migrations`: the app's schema, applied once each, in order, when the server starts (each a
##   name and its SQL: `import "migrations/0001_notes.sql" as notes : Str` embeds a file).
## - `actors`: the kinds of actor the app defines (`Actor.handler(kind)`), which `rocx build` lists:
##   the host runs their turns (`actor_for_host!`), one message at a time each, and refuses a
##   message to a kind that isn't here.
## - `logs`: the format of the server's log (`Log`), the host's lines and the app's: `{ format: Auto }`
##   (`ROCX_LOG`, `pretty` or `json`, if it is set; or else pretty when stderr is a terminal, and JSON
##   when it isn't), `Pretty` or `Json`. `App.program` says `Auto`; an app says otherwise with
##   `{ ..App.program(…), logs: { format: Json } }`.
## - `plugins`: what packages add to the app (`Plugin`), all but their routes, which `respond!`
##   answers: early paths, tables, calls, loops, starts, checks and needs, checked when the server
##   starts (`Plugins`); `routes`, the app's own (`Routes.claims`), which no plugin's may meet.
## - A page's components are Solid-style (web/runtime.js hydrates the document in the browser). A
##   GET endpoint a component reads while the host renders the page (`Endpoint.get!`) is answered by
##   its route, in-process (`Host.fetch!`). The modules components are written with (`Html`, `Solid`,
##   `Show`, `For`, `Loading`, `Errored`, `Context`, `Call`, `Router`, `HttpStatusCode`, `Transition`,
##   `Title`, `Browser`, `Audio`, `Submission`, `Submissions`), and HTTP's (`Server`, `Endpoint`,
##   `Channel`, `Middleware`, `Events`, `OpenApi`), are the browser's platform's (web/platform),
##   copied here by the build, so the same code compiles on both.
##
## Each call is a coroutine on one of a few threads of Roc's own (D-027), which pauses while an
## effect (`Db.all!`, a stream's `sleep!`) waits, so it holds up no other request and holds no
## thread. A crash (`crash`, an integer
## overflowing) ends that call only: the host answers 500 (or ends the stream, or the job's call, or
## the actor's turn), frees what the call had allocated, rolls back its transaction, and goes on.
platform ""
	requires {
		program : {
			respond! : Str, Str, Str, List(U8), Str => Server.Response,
			migrations : List({ name : Str, sql : Str }),
			actors : List({ name : Str, run! : Str, Str, Str => Try({ state : Str, reply : Str }, Str) }),
			logs : { format : [Auto, Pretty, Json] },
			plugins : List(Plugin.Running),
			routes : List({ method : Str, path : Str, file : Str }),
		}
	}
	exposes [Actor, AesGcm, Audio, Browser, Call, Channel, Context, Db, Endpoint, Env, Errored, Events, For, Html, Http, HttpResponse, HttpStatusCode, Kv, Live, Loading, Log, Middleware, OpenApi, Plugin, Random, Router, Server, Show, Solid, Submission, Submissions, Tcp, Time, Title, Transition]
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
		"roc_host_kv_add": Host.kv_add!,
		"roc_host_kv_delete": Host.kv_delete!,
		"roc_host_kv_get": Host.kv_get!,
		"roc_host_kv_increment": Host.kv_increment!,
		"roc_host_kv_push": Host.kv_push!,
		"roc_host_kv_set": Host.kv_set!,
		"roc_host_kv_take": Host.kv_take!,
		"roc_host_live_count": Host.live_count!,
		"roc_host_live_join": Host.live_join!,
		"roc_host_live_listen": Host.live_listen!,
		"roc_host_live_next": Host.live_next!,
		"roc_host_live_publish": Host.live_publish!,
		"roc_host_log": Host.log!,
		"roc_host_log_format": Host.log_format!,
		"roc_host_now_millis": Host.now_millis!,
		"roc_host_now_nanos": Host.now_nanos!,
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
		"roc_is_pending": Host.is_pending!,
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
		"roc_submission_drop": Host.submission_drop!,
		"roc_submissions": Host.submissions!,
		"roc_submit": Host.submit!,
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
import Db
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
import Kv
import Live
import Loading
import Log
import Middleware
import Migrations
import OpenApi
import Plugin
import Plugins
import Random
import Router
import Server
import Setting
import Show
import Solid
import Submission
import Submissions
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
## A plugin's early path (`Plugin.Early`) is answered before the app, under the flag it names.
respond_for_host! : Str, Str, Str, List(U8), Str => { status : U16, headers : Str, kind : U8, text : Str, bytes : List(U8), upstream : { method : Str, url : Str, headers : Str }, page : Box(() => Str), feed : Box(Feed) }
respond_for_host! = |method, target, headers, body, context| {
	answered =
		match early!(method, target) {
			Ok(early) => (early.answer!)({ ..Server.from_http(method, target, headers, body), route: early.path })
			Err(NotEarly) => (program.respond!)(method, target, headers, body, context)
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
## (before anything is logged: a migration, a plugin's problem); the plugins are checked (any
## problem stops it here, with every one) and put in order; the host is told the kinds of actor;
## then the platform's tables, the plugins' and the app's migrations are applied, and the plugins'
## starts run (a jobs plugin's queues again the jobs a stop cut short).
init_for_host! : {} => Try({}, Str)
init_for_host! = |{}| {
	Host.log_format!(
		match program.logs.format {
			Auto => 0
			Pretty => 1
			Json => 2
		},
	)
	# The plugins, checked all at once: any problem stops the server, with every one.
	problems = Plugins.problems(program.plugins, program.routes).concat(Plugins.unmet!(program.plugins))
	if !problems.is_empty() {
		return Err(Str.join_with(problems, "\n"))
	}
	plugins = Plugins.ordered(program.plugins)
	Host.actor_kinds!(Str.join_with(program.actors.map(|actor| actor.name), "\n"))
	if Setting.database!({}) {
		# The platform's tables, then each plugin's (recorded as `<plugin>/<name>`), then the app's.
		theirs = plugins.join_map(|plugin| plugin.migrations.map(|migration| { name: "${plugin.name}/${migration.name}", sql: migration.sql }))
		match Migrations.apply!(Migrations.own.concat(theirs).concat(program.migrations)) {
			Err(why) => Err(why)
			Ok({}) => started!(plugins)
		}
	} else {
		started!(plugins)
	}
}

## The plugins' starts, in their order: the first `Err` stops the server. Then a line a plugin on
## the log.
started! : List(Plugin.Running) => Try({}, Str)
started! = |plugins| {
	for plugin in plugins {
		for start! in plugin.starts {
			match start!({}) {
				Ok({}) => {}
				Err(why) => return Err("${plugin.name}: ${why}")
			}
		}
	}
	Plugins.log!(plugins)
	Ok({})
}

## The early path `target` is (a path and its query), when the server has a flag it is under.
early! : Str, Str => Try(Plugin.Early, [NotEarly])
early! = |method, target| {
	path =
		match target.split_first("?") {
			Ok({ before, .. }) => before
			Err(_) => target
		}
	if !path.starts_with("/__rocx/") {
		return Err(NotEarly)
	}
	dev = !Setting.text!("dev").is_empty()
	debug = !Setting.text!("debug").is_empty()
	flagged = |under| under.any(|flag| (flag == Dev and dev) or (flag == Debug and debug))
	wanted = |each| each.method == method or each.method == "*" or (each.method == "GET" and method == "HEAD")
	match program.plugins.join_map(|plugin| plugin.early).find_first(|each| wanted(each) and Plugin.matches(each.path, path) and flagged(each.under)) {
		Ok(each) => Ok(each)
		Err(_) => Err(NotEarly)
	}
}

## What the server runs in the background, each loop a call of its own: each plugin's loops, and its
## checks (each run once), by where they are in the plugins' order.
Loop : [Plugged(U64, U64), Checked(U64, U64)]

loops! : {} => List(Loop)
loops! = |{}| {
	plugins = Plugins.ordered(program.plugins)
	plugins.map_with_index(|plugin, p| plugin.loops.map_with_index(|_, l| Plugged(p, l)).concat(plugin.checks.map_with_index(|_, c| Checked(p, c)))).join_map(|each| each)
}

background_count_for_host! : {} => U64
background_count_for_host! = |{}| loops!({}).len()

## Runs the background loop at `index` to its end: a plugin's loop (until it returns, or the
## server stops); a plugin's check, once.
background_for_host! : U64 => {}
background_for_host! = |index|
	match loops!({}).get(index) {
		Ok(Plugged(p, l)) =>
			match Plugins.ordered(program.plugins).get(p) {
				Ok(plugin) =>
					match plugin.loops.get(l) {
						Ok(each) => (each.run!)({})
						Err(_) => {}
					}
				Err(_) => {}
			}
		Ok(Checked(p, c)) =>
			match Plugins.ordered(program.plugins).get(p) {
				Ok(plugin) =>
					match plugin.checks.get(c) {
						Ok(check) =>
							match (check.run!)({}) {
								Ok(said) => if (said.is_empty()) {} else Log.line!("${check.name}: ${said}")
								Err(why) => Log.warn!("${check.name}: ${why}", {})
							}
						Err(_) => {}
					}
				Err(_) => {}
			}
		Err(_) => {}
	}

## Runs a part of the app in a call of its own (`Host.isolated!`): a plugin's call
## (`<plugin>.<name>`, `Plugin.isolated!`: a job, for the jobs plugin). What it answers, or why it
## failed; a crash in it ends this call only.
isolated_for_host! : Str, Str => Try(Str, Str)
isolated_for_host! = |what, input|
	match program.plugins.join_map(|plugin| plugin.calls).find_first(|call| call.name == what) {
		Ok(call) => (call.run!)(input)
		Err(_) => Err("nothing in the app is called ${what}")
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
