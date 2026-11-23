## The server's platform: Roc compiled to native code, in a Rust host (`server/host`). The host
## answers HTTP with tokio and hyper and gives Roc a few general effects: a database (Postgres or
## SQLite, D-045), time, live
## topics and rooms, background loops, calls run in isolation, actors' mailboxes and timers, TCP and
## TLS. Migrations, plugins and actors' state are Roc, here, built on them; jobs and cron, and email,
## are packages' plugins (packages/jobs, packages/email: D-034, D-035), on the same effects. The browser's
## platform is `web/platform`, wasm; an app is two programs, one on each, talking over HTTP.
##
## - `respond!(request, context)` answers a request: a page or an endpoint. The host hands over one
##   record of what it knows of the request (`HostRequest`: its method, its target, its headers, its
##   body as it came, and the address of the connection it came on), which the platform makes a
##   `Server.Request` (`peer` is that address); `context` is what the server was started with
##   (`--context-file`). Its answer is a `Server.Response`, whose body is text; bytes, sent as they
##   are; a body the host fetches from elsewhere and sends on as it comes, never through Roc
##   (`Forward`); a page of components (`Page`), which the host renders for the request, every hole run
##   once, into a document for the browser to hydrate, with the answers its endpoint reads got
##   and `/rocx/start.js` before `</body>` (a HEAD isn't rendered; `Host.status!`,
##   `<HttpStatusCode>`, sets the status); or a stream of events
##   (server-sent events, `Events`): a loop the host runs as a call of its own, to its end, with
##   `{ send!, sleep! }`. `send!` writes to the response and says whether the client is still
##   there, `sleep!` waits that many milliseconds (and wakes early if the client goes).
## - `database`: the app's database (D-045). `Postgres`, at `--database-url` (`DATABASE_URL`), and
##   none without it; or `Sqlite(path)`, a file in the server's process at `path` (from where the
##   server starts; made, with its directory, when missing), or at `--database-url`
##   (`sqlite:<path>`) when it is given; or `Turso(path)`, the same with Turso's engine (D-046:
##   SQLite written again in Rust, its SQL SQLite's). The URL picks between SQLite and Turso
##   (`turso:<path>` runs a SQLite app on Turso); one of the other flavor stops the server at start.
##   The app's SQL is its database's: nothing is translated.
## - `migrations`: the app's schema, applied once each, in order, when the server starts (each a
##   name and its SQL, in its database's flavor: `import "migrations/0001_notes.sql" as notes : Str`
##   embeds a file).
## - `actors`: the kinds of actor the app defines (`Actor.handler(kind)`), which `rocx build` lists:
##   the host runs their turns (`actor_for_host!`), one message at a time each, and refuses a
##   message to a kind that isn't here.
## - `logs`: the format of the server's log (`Log`), the host's lines and the app's: `{ format: Auto }`
##   (`ROCX_LOG`, `pretty` or `json`, if it is set; or else pretty when stderr is a terminal, and JSON
##   when it isn't), `Pretty` or `Json`. `App.program` says `Auto`; an app says otherwise with
##   `{ ..App.program(…), logs: { format: Json } }`.
## - `plugins`: what packages add to the app (`Plugin`), all but their routes, which `respond!`
##   answers: early paths, files (which the host serves before the app, and its middleware, ever
##   sees the request), scripts (which every page loads), tables, calls, loops, starts, checks and
##   needs, checked when the server starts (`Plugins`); `routes`, the app's own (`Routes.claims`),
##   which no plugin's route or file at the root may meet.
## - A page's components are Solid-style (web/runtime.js hydrates the document in the browser). A
##   GET endpoint a component reads while the host renders the page (`Endpoint.get!`) is answered by
##   its route, in-process (`Host.fetch!`). The modules components are written with (`Html`, `Solid`,
##   `Store`, `Show`, `Switch`, `Match`, `For`, `Loading`, `Errored`, `Context`, `Call`, `Router`, `Search`, `Leave`, `A`, `HttpStatusCode`, `Transition`,
##   `Title`, `Browser`, `Submission`, `Submissions`), and HTTP's (`Server`, `Endpoint`,
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
			respond! : Server.Request, Str => Server.Response,
			database : [Postgres, Sqlite(Str), Turso(Str)],
			migrations : List({ name : Str, sql : Str }),
			actors : List({ name : Str, run! : Str, Str, Str => Try({ state : Str, reply : Str }, Str) }),
			logs : { format : [Auto, Pretty, Json] },
			plugins : List(Plugin.Running),
			routes : List({ method : Str, path : Str, file : Str }),
		}
	}
	exposes [A, Actor, AesGcm, Blobs, Browser, Call, Channel, Context, Db, Endpoint, Env, Errored, Events, For, Html, Http, HttpResponse, HttpStatusCode, Kv, Leave, Live, Loading, Log, Match, Middleware, Navigate, OpenApi, Plugin, Random, Repeat, Router, Search, Server, Show, Solid, Store, Submission, Submissions, Switch, Tcp, Time, Title, Transition]
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
		"roc_app": Host.app!,
		"roc_before_leave": Host.before_leave!,
		"roc_boundary": Host.boundary!,
		"roc_browser_call": Host.browser_call!,
		"roc_cleanup": Host.cleanup!,
		"roc_clear_timer": Host.clear_timer!,
		"roc_context_find": Host.context_find!,
		"roc_context_get": Host.context_get!,
		"roc_context_value": Host.context_value!,
		"roc_effect_new": Host.effect_new!,
		"roc_effect_options": Host.effect_options!,
		"roc_event_value": Host.event_value!,
		"roc_fail": Host.fail!,
		"roc_fetch": Host.fetch!,
		"roc_flash": Host.flash!,
		"roc_for_new": Host.for_new!,
		"roc_head": Host.head!,
		"roc_host_actor_after": Host.actor_after!,
		"roc_host_actor_ask": Host.actor_ask!,
		"roc_host_actor_cancel": Host.actor_cancel!,
		"roc_host_actor_kinds": Host.actor_kinds!,
		"roc_host_actor_tell": Host.actor_tell!,
		"roc_host_aes_gcm_open": Host.aes_gcm_open!,
		"roc_host_aes_gcm_seal": Host.aes_gcm_seal!,
		"roc_host_blob_check": Host.blob_check!,
		"roc_host_blob_compose": Host.blob_compose!,
		"roc_host_blob_delete": Host.blob_delete!,
		"roc_host_blob_get": Host.blob_get!,
		"roc_host_blob_head": Host.blob_head!,
		"roc_host_blob_keys": Host.blob_keys!,
		"roc_host_blob_put": Host.blob_put!,
		"roc_host_blob_range": Host.blob_range!,
		"roc_host_blob_secret": Host.blob_secret!,
		"roc_host_db_begin": Host.db_begin!,
		"roc_host_db_commit": Host.db_commit!,
		"roc_host_db_conflicted": Host.db_conflicted!,
		"roc_host_db_execute": Host.db_execute!,
		"roc_host_db_flavor": Host.db_flavor!,
		"roc_host_db_listen": Host.db_listen!,
		"roc_host_db_notify": Host.db_notify!,
		"roc_host_db_open": Host.db_open!,
		"roc_host_db_query": Host.db_query!,
		"roc_host_db_rollback": Host.db_rollback!,
		"roc_host_db_script": Host.db_script!,
		"roc_host_env_var": Host.env_var!,
		"roc_host_http_close": Host.http_close!,
		"roc_host_http_open": Host.http_open!,
		"roc_host_http_read": Host.http_read!,
		"roc_host_http_send": Host.http_send!,
		"roc_host_isolated": Host.isolated!,
		"roc_host_kv_add": Host.kv_add!,
		"roc_host_kv_delete": Host.kv_delete!,
		"roc_host_kv_get": Host.kv_get!,
		"roc_host_kv_increment": Host.kv_increment!,
		"roc_host_kv_push": Host.kv_push!,
		"roc_host_kv_set": Host.kv_set!,
		"roc_host_kv_swap": Host.kv_swap!,
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
		"roc_host_page_scripts": Host.page_scripts!,
		"roc_host_plugin_file": Host.plugin_file!,
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
		"roc_host_zone_offset": Host.zone_offset!,
		"roc_interval": Host.interval!,
		"roc_is_pending": Host.is_pending!,
		"roc_is_routing": Host.is_routing!,
		"roc_keep": Host.keep!,
		"roc_leave_prevent": Host.leave_prevent!,
		"roc_leave_retry": Host.leave_retry!,
		"roc_listen": Host.listen!,
		"roc_location": Host.location!,
		"roc_memo_done": Host.memo_done!,
		"roc_memo_get": Host.memo_get!,
		"roc_memo_last": Host.memo_last!,
		"roc_memo_new": Host.memo_new!,
		"roc_navigate": Host.navigate!,
		"roc_optimistic_set": Host.optimistic_set!,
		"roc_problem": Host.problem!,
		"roc_read_at": Host.read_at!,
		"roc_redirect_page": Host.redirect_page!,
		"roc_refresh": Host.refresh!,
		"roc_request": Host.request!,
		"roc_resync": Host.resync!,
		"roc_retry": Host.retry!,
		"roc_revalidate": Host.revalidate!,
		"roc_row_get": Host.row_get!,
		"roc_row_index": Host.row_index!,
		"roc_row_last": Host.row_last!,
		"roc_row_set": Host.row_set!,
		"roc_say": Host.say!,
		"roc_signal_get": Host.signal_get!,
		"roc_signal_latest": Host.signal_latest!,
		"roc_signal_new": Host.signal_new!,
		"roc_signal_set": Host.signal_set!,
		"roc_status": Host.status!,
		"roc_submission": Host.submission!,
		"roc_submission_clear": Host.submission_clear!,
		"roc_submission_drop": Host.submission_drop!,
		"roc_submission_retry": Host.submission_retry!,
		"roc_submissions": Host.submissions!,
		"roc_submit": Host.submit!,
		"roc_subscribe": Host.subscribe!,
		"roc_timeout": Host.timeout!,
		"roc_title": Host.title!,
		"roc_tracking": Host.tracking!,
		"roc_untrack": Host.untrack!,
	}
	targets: {
		inputs_dir: "targets/",
		arm64mac: { inputs: ["libhost.a", app] },
		x64mac: { inputs: ["libhost.a", app] },
		arm64musl: { inputs: ["rcrt1.o", "libhost.a", app, "libunwind.a", "libc.a"] },
		x64musl: { inputs: ["rcrt1.o", "libhost.a", app, "libunwind.a", "libc.a"] },
	}

import Actor
import ActorTimers
import ActorTurn
import AesGcm
import Blobs
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
import Repeat
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
import Store
import Switch
import Match
import Submission
import Submissions
import Tcp
import Time
import Title
import A
import Search
import Leave
import Navigate
import Transition

## A request as the host hands it over, everything it knows of it in one record: its method, its
## target (the path, and a query after a `?`), its headers (a `name: value` a line), its body, the
## bytes as they came, and the address of the connection it came on (`peer`: `203.0.113.7`, `::1`;
## for a GET a page reads as the host renders it, the page's). What else the host comes to know of
## a request goes here too.
HostRequest : { method : Str, target : Str, headers : Str, body : List(U8), peer : Str }

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
respond_for_host! : HostRequest, Str => { status : U16, headers : Str, kind : U8, text : Str, bytes : List(U8), upstream : { method : Str, url : Str, headers : Str }, page : Box(() => Str), feed : Box(Feed) }
respond_for_host! = |given, context| {
	request = { ..Server.from_http(given.method, given.target, given.headers, given.body), peer: given.peer }
	answered =
		match early!(given.method, given.target) {
			Ok(early) => (early.answer!)({ ..request, route: early.path })
			Err(NotEarly) => (program.respond!)(request, context)
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

## The server is starting: the log takes the app's format (before anything is logged: a migration,
## a plugin's problem); the app's database is opened, where its program and `--database-url` say;
## the plugins are checked (any problem stops it here, with every one) and put in order; the host
## is told the kinds of actor, and handed the plugins' files and their scripts' URLs; then the
## platform's tables, the plugins' and the app's migrations are applied (the platform's and the
## plugins' for its database), the actors' timers the database keeps are set again, and the
## plugins' starts run (a jobs plugin's queues again the jobs a stop cut short).
init_for_host! : {} => Try({}, Str)
init_for_host! = |{}| {
	Host.log_format!(
		match program.logs.format {
			Auto => 0
			Pretty => 1
			Json => 2
		},
	)
	database_opened!(program.database)?
	# The plugins, checked all at once: any problem stops the server, with every one.
	problems = Plugins.problems(program.plugins, program.routes).concat(Plugins.unmet!(program.plugins))
	if !problems.is_empty() {
		return Err(Str.join_with(problems, "\n"))
	}
	# The app's flavor: each plugin's migrations for it alone, for the log and the database. Turso's
	# SQL is SQLite's.
	flavor =
		match program.database {
			Postgres => Postgres
			Sqlite(_) => Sqlite
			Turso(_) => Sqlite
		}
	plugins = Plugins.ordered(program.plugins).map(|plugin| { ..plugin, migrations: plugin.migrations.keep_if(|migration| applies(migration.on, flavor)) })
	Host.actor_kinds!(Str.join_with(program.actors.map(|actor| actor.name), "\n"))
	# The plugins' files, which the host serves before the app, and their scripts, which every page
	# loads.
	for plugin in plugins {
		for file in plugin.files {
			Host.plugin_file!(Plugin.url(plugin.name, file), file.content_type, file.body)
		}
	}
	Host.page_scripts!(Str.join_with(plugins.join_map(|plugin| plugin.scripts.join_map(|script| plugin.files.keep_if(|file| file.path == script).map(|file| Plugin.url(plugin.name, file)))), "\n"))
	if Setting.database!({}) {
		# The platform's tables, then each plugin's (recorded as `<plugin>/<name>`), then the app's.
		theirs = plugins.join_map(|plugin| plugin.migrations.map(|migration| { name: "${plugin.name}/${migration.name}", sql: migration.sql }))
		match Migrations.apply!(Migrations.own(flavor).concat(theirs).concat(program.migrations)) {
			Err(why) => Err(why)
			Ok({}) => {
				# The actors' timers a stop left waiting, set again (D-057).
				ActorTimers.load!({})?
				started!(plugins)
			}
		}
	} else {
		started!(plugins)
	}
}

## Whether a plugin's migration for `on` (`Plugin.Migration`) is one for the app's database.
applies : [Any, Postgres, Sqlite], [Postgres, Sqlite] -> Bool
applies = |on, flavor|
	match (on, flavor) {
		(Any, _) => Bool.True
		(Postgres, Postgres) => Bool.True
		(Sqlite, Sqlite) => Bool.True
		_ => Bool.False
	}

## The app's database, opened where its program and `--database-url` say (D-045, D-046):
## `Postgres` at the URL, and none without one; `Sqlite(path)` or `Turso(path)` at the URL when it
## is a `sqlite:` or a `turso:` one (either engine: the SQL is SQLite's), or else at `path`. A URL
## of the other flavor stops the server, saying which the app wants; but a check of the app's SQL
## (`--describe-sql`, D-058), which opens a scratch database of the app's kind, leaves a Postgres
## URL alone for a SQLite or Turso app (DATABASE_URL may be set in a shell).
database_opened! : [Postgres, Sqlite(Str), Turso(Str)] => Try({}, Str)
database_opened! = |wanted| {
	url = Host.setting!("database_url")
	checking = !Host.setting!("describe_sql").is_empty()
	file_url = url.starts_with("sqlite:") or url.starts_with("turso:")
	given =
		match wanted {
			Sqlite(_) | Turso(_) if checking and !file_url => ""
			_ => url
		}
	match wanted {
		Postgres =>
			if given.is_empty() {
				Ok({})
			} else if file_url {
				Err("the app's database is Postgres (its program's `database`), and --database-url (or DATABASE_URL) is a sqlite: or turso: one: give it a postgres:// URL, or say `database: Sqlite(path)` in the program")
			} else {
				opened!(given)
			}
		Sqlite(path) => file_opened!(given, file_url, "sqlite:${path}", "SQLite", "Sqlite(\"${path}\")")
		Turso(path) => file_opened!(given, file_url, "turso:${path}", "Turso", "Turso(\"${path}\")")
	}
}

## A SQLite or Turso app's file: at `--database-url` when it is a `sqlite:` or a `turso:` one, or
## else at the program's (`url`).
file_opened! : Str, Bool, Str, Str, Str => Try({}, Str)
file_opened! = |given, file_url, url, name, said| {
	if given.is_empty() {
		opened!(url)
	} else if file_url {
		opened!(given)
	} else {
		Err("the app's database is ${name} (its program's `database: ${said}`), and --database-url (or DATABASE_URL) isn't a sqlite:<path> or turso:<path> one: leave it unset (DATABASE_URL too) for the program's file, or say `database: Postgres` in the program")
	}
}

opened! : Str => Try({}, Str)
opened! = |url|
	match Host.db_open!(url) {
		Ok(_) => Ok({})
		Err(why) => Err("the database: ${why}")
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
								Ok(said) => if (said.is_empty()) {} else Log.info!(said, { check: check.name })
								Err(why) => Log.warn!(why, { check: check.name })
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
	# The platform's own (`rocx:…`, a name no plugin's call can have): its actors' timers' rows.
	if what.starts_with("rocx:") {
		ActorTimers.isolated!(what, input)
	} else {
		match program.plugins.join_map(|plugin| plugin.calls).find_first(|call| call.name == what) {
			Ok(call) => (call.run!)(input)
			Err(_) => Err("nothing in the app is called ${what}")
		}
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
