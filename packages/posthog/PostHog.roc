import pf.Env
import pf.Http
import pf.Kv
import pf.Log
import pf.Middleware
import pf.Plugin
import pf.Random
import pf.Server
import pf.Time
import Event
import Fingerprint

## Errors, sent to PostHog's error tracking, from the app itself: no platform hook. What it reports:
##
## - every answer with a 5xx status (`middleware`): its route's pattern, its method, its text;
## - an error the app dealt with but wants seen (`capture!`, `capture_for!`), with fields;
## - a job that failed for good (`job_failed!`, the jobs plugin's `on_failed!`);
## - an error nothing caught in a browser (the page's script, `<at>.js`, sends it to `<at>`).
##
## Each is kept in the server's memory (`Kv`, the newest 1,000) and a background loop sends what
## there is every `interval_ms` (10 s) and as the server stops, as `$exception` events (`Event`)
## grouped by a fingerprint of their own (`Fingerprint`); one issue is sent at most 20 times a
## minute. Without a project key it is all off, and costs nothing.
##
## A crash in Roc ends its call before the middleware sees an answer: the host answers it, and logs
## it (`rocx server: Roc crashed`), so crashes are on the server's log, not here.
##
## ```roc
## plugins: [PostHog.plugin({})]          # POSTHOG_KEY, POSTHOG_HOST and POSTHOG_RELEASE, from the environment
## middleware = Middlewares.member.then(PostHog.middleware(|context| context.member.id))   # routes/+middleware.roc
##
## PostHog.capture!("the payment provider refused a refund", { order: order.id, why: why })
## ```
PostHog := [].{

	## The project's key (`key`; "" for `POSTHOG_KEY`, and without either reporting is off); where
	## PostHog takes events (`host`; "" for `POSTHOG_HOST`, else `https://us.i.posthog.com`, or
	## `https://eu.i.posthog.com` for EU Cloud); the app's version on each event (`release`, a
	## commit; "" for `POSTHOG_RELEASE`); where a page's script sends errors (`at`, its script at
	## `<at>.js`); and how often what was kept is sent (`interval_ms`).
	Options := {
		key : Str ?? "",
		host : Str ?? "",
		release : Str ?? "",
		at : Str ?? "/rocx-errors",
		interval_ms : U64 ?? 10_000,
	}

	## The PostHog plugin: the browser's script (`GET <at>.js`) and where it sends errors
	## (`POST <at>`), the loop that sends what was kept (`posthog.send`), its options kept when the
	## server starts, and a look once started (`posthog.reporting`: where errors go, or that
	## reporting is off).
	plugin : Options -> Plugin.Value(context, ctx)
	plugin = |options| {
		given : Settings
		given = { key: options.key, host: options.host, release: options.release, interval_ms: options.interval_ms }
		{
			name: "posthog",
			routes: [
				{ method: "POST", path: options.at, kind: Endpoint, answer!: |request, _context| browser!(request) },
				{ method: "GET", path: "${options.at}.js", kind: Endpoint, answer!: |_request, _context| script({}) },
			],
			starts: [|_context| keep!(given)],
			loops: [{ name: "posthog.send", run!: |_context| sender!({}) }],
			checks: [{ name: "posthog.reporting", run!: |_context| check!({}) }],
		}
	}

	## Reports every answer with a 5xx status, from the middleware after it: its route's pattern, its
	## method, its status and its text (the first line, when it isn't HTML). `user` names who asked,
	## from what the middleware before handed on ("" for nobody known): put it after the one that
	## knows who is signed in, or first with `|_| ""`.
	##
	##     # routes/+middleware.roc
	##     middleware = Middlewares.member.then(PostHog.middleware(|context| context.member.id))
	middleware : (context -> Str) -> Middleware(context, context)
	middleware = |user|
		Middleware.make(
			|request, context, next!| {
				answer = next!(request, context)
				if (answer.status >= 500) answered!(request, answer, user(context)) else {}
				answer
			},
		)

	## Reports an error the app dealt with but wants seen, with fields (a record, as `Log.error!`
	## takes them), and the request being answered, if one is. Its fingerprint is the message's:
	## one issue wherever it happens.
	##
	##     PostHog.capture!("the payment provider refused a refund", { order: order.id, why: why })
	capture! : Str, fields => {} where [fields.Json.Encodable(e)]
	capture! = |message, fields| PostHog.capture_for!("", message, fields)

	## `capture!`, for someone the app knows (`user`, as it names them): PostHog counts the people
	## an issue reached.
	capture_for! : Str, Str, fields => {} where [fields.Json.Encodable(e)]
	capture_for! = |user, message, fields| {
		request = Server.request!({})
		# Outside a request (a job, a loop) the request is an empty GET of `/`.
		answering = !request.headers.is_empty()
		report!(
			{
				kind: "Error",
				message: message,
				handled: Bool.True,
				source: "server",
				place: if (answering) request.path else "",
				method: if (answering) request.method else "",
				status: 0,
				user: user,
				fields: written(fields),
				stack: "",
			},
			["server", "Error", message],
		)
	}

	## Reports a job that failed for good: what the jobs plugin calls with its `on_failed!`.
	##
	##     plugins: [Job.plugin({ jobs: App.jobs, on_failed!: PostHog.job_failed! }), PostHog.plugin({})]
	job_failed! : { kind : Str, id : I64, attempts : U64, error : Str } => {}
	job_failed! = |failure|
		report!(
			{
				kind: "JobFailed",
				message: failure.error,
				handled: Bool.False,
				source: "job",
				place: failure.kind,
				method: "",
				status: 0,
				user: "",
				fields: "{\"job\":${failure.id.to_str()},\"attempts\":${failure.attempts.to_str()}}",
				stack: "",
			},
			["job", failure.kind, failure.error],
		)
}

## Where errors go, as the plugin's start found them; `key` "" when reporting is off.
Settings : { key : Str, host : Str, release : Str, interval_ms : U64 }

## The part of a problem its reporter knows: `report!` adds its fingerprint, time and id.
Reported : { kind : Str, message : Str, handled : Bool, source : Str, place : Str, method : Str, status : U16, user : Str, fields : Str, stack : Str }

## Where the plugin keeps its settings, and the problems waiting to be sent.
settings_key : Str
settings_key = "posthog:settings"

queue_key : Str
queue_key = "posthog:queue"

## How many problems wait at most: past that, the oldest go.
kept : U64
kept = 1_000

## How many times one issue is sent a minute, at most: a loop of errors doesn't flood the project.
per_issue_minute : I64
per_issue_minute = 20

## How many errors all browsers together send a minute, at most: a stranger can send as many as
## they like.
browsers_minute : I64
browsers_minute = 120

## The plugin's start: its options, with the environment's where they leave something out, kept.
keep! : Settings => Try({}, Str)
keep! = |given| {
	key = (if (given.key.is_empty()) (Env.var!("POSTHOG_KEY") ?? "") else given.key).trim()
	named = if (given.host.is_empty()) (Env.var!("POSTHOG_HOST") ?? "") else given.host
	host = if (named.trim().is_empty()) "https://us.i.posthog.com" else named.trim().drop_suffix("/")
	release = (if (given.release.is_empty()) (Env.var!("POSTHOG_RELEASE") ?? "") else given.release).trim()
	found : Settings
	found = { key: key, host: host, release: release, interval_ms: U64.max(given.interval_ms, 100) }
	Plugin.keep!(settings_key, Json.to_str(found))
	Ok({})
}

## The settings the plugin's start kept, or `Off`: no key, or no plugin.
settings! : {} => Try(Settings, [Off])
settings! = |{}|
	match Plugin.kept!(settings_key) {
		Ok(text) =>
			match Json.parse(text) {
				Ok(found) => if (found.key.is_empty()) Err(Off) else Ok(found)
				Err(InvalidJson(_)) => Err(Off)
			}
		Err(NotFound) => Err(Off)
	}

## Where errors go, or that reporting is off, said on the log once the server has started.
check! : {} => Try(Str, Str)
check! = |{}|
	match settings!({}) {
		Ok(settings) => Ok("errors go to ${settings.host}, every ${settings.interval_ms.to_str()} ms")
		Err(Off) => Ok("off: no POSTHOG_KEY")
	}

## Keeps a problem to be sent: its fingerprint from `parts`, unless that issue was sent its 20
## times this minute; nothing when reporting is off.
report! : Reported, List(Str) => {}
report! = |reported, parts|
	match settings!({}) {
		Err(Off) => {}
		Ok(_) => {
			fingerprint = Fingerprint.of(parts)
			match Kv.increment!("posthog:seen:${fingerprint}", 1, { ttl_ms: 60_000 }) {
				Ok(count) if count <= per_issue_minute => {
					problem : Event.Problem
					problem = {
						kind: reported.kind,
						message: cut(reported.message, 2_000),
						handled: reported.handled,
						source: reported.source,
						place: reported.place,
						method: reported.method,
						status: reported.status,
						user: reported.user,
						fields: reported.fields,
						stack: cut(reported.stack, 8_000),
						fingerprint: fingerprint,
						at_ms: Time.now_millis!({}),
						id: Event.uuid(Random.bytes!(16)),
					}
					Kv.push!(queue_key, problem, { keep: kept })
				}
				_ => {}
			}
		}
	}

## A 5xx answer, reported.
answered! : Server.Request, Server.Response, Str => {}
answered! = |request, answer, user| {
	text = Server.body_text(answer).trim()
	line =
		match text.split_first("\n") {
			Ok({ before, .. }) => before.trim()
			Err(_) => text
		}
	said = if (line.is_empty() or line.starts_with("<")) "" else cut(line, 300)
	message = if (said.is_empty()) "answered ${answer.status.to_str()}" else "answered ${answer.status.to_str()}: ${said}"
	place = if (request.route.is_empty()) request.path else request.route
	report!(
		{
			kind: "ServerError",
			message: message,
			handled: Bool.False,
			source: "server",
			place: place,
			method: request.method,
			status: answer.status,
			user: user,
			fields: "{}",
			stack: "",
		},
		["server", "ServerError", place, message],
	)
}

## What a page's script sends: the error's type, message and stack, and the page's path.
Sent : { kind : Str, message : Str, stack : Str, page : Str }

## An error a page's script sent (`POST <at>`): reported, unless browsers sent their 120 this
## minute. 204 whatever happens to it, 400 for what isn't one, 413 for over 16 KiB.
browser! : Server.Request => Server.Response
browser! = |request|
	if request.body.len() > 16_384 {
		Server.response(413, [], "")
	} else {
		parsed : Try(Sent, [InvalidJson(Str)])
		parsed = Json.parse(Str.from_utf8_lossy(request.body))
		match parsed {
			Err(_) => Server.response(400, [], "")
			Ok(sent) => {
				match Kv.increment!("posthog:browsers", 1, { ttl_ms: 60_000 }) {
					Ok(count) if count <= browsers_minute => {
						kind = if (sent.kind.trim().is_empty()) "Error" else cut(sent.kind.trim(), 100)
						report!(
							{
								kind: kind,
								message: sent.message,
								handled: Bool.False,
								source: "browser",
								place: cut(sent.page, 500),
								method: "",
								status: 0,
								user: "",
								fields: "{}",
								stack: sent.stack,
							},
							["browser", kind, sent.message],
						)
					}
					_ => {}
				}
				Server.response(204, [], "")
			}
		}
	}

## The page's script (`GET <at>.js`, in a layout: `<script src="/rocx-errors.js" defer></script>`):
## an error nothing caught, and a promise nothing caught the rejection of, sent where the script
## came from without `.js`; ten a page at most.
script : {} -> Server.Response
script = |{}|
	Server.response(
		200,
		[{ name: "content-type", value: "text/javascript; charset=utf-8" }, { name: "cache-control", value: "public, max-age=3600" }],
		"(()=>{const src=document.currentScript.src;const at=src.slice(0,src.lastIndexOf(\".js\"));let left=10;const send=(kind,message,stack)=>{if(left<=0)return;left-=1;const body=JSON.stringify({kind:String(kind||\"Error\"),message:String(message??\"\").slice(0,1000),stack:String(stack??\"\").slice(0,4000),page:location.pathname});if(!navigator.sendBeacon?.(at,new Blob([body],{type:\"application/json\"})))fetch(at,{method:\"POST\",body,headers:{\"content-type\":\"application/json\"},keepalive:true}).catch(()=>{})};addEventListener(\"error\",(e)=>send(e.error?.name,e.error?.message??e.message,e.error?.stack));addEventListener(\"unhandledrejection\",(e)=>send(e.reason?.name??\"UnhandledRejection\",e.reason?.message??e.reason,e.reason?.stack))})();\n",
	)

## The loop that sends what was kept, every `interval_ms`, until the server stops (and then once
## more); none when reporting is off.
sender! : {} => {}
sender! = |{}|
	match settings!({}) {
		Err(Off) => {}
		Ok(settings) => {
			var $going = Bool.True
			while $going {
				$going = waited!(settings.interval_ms)
				sent!(settings)
			}
		}
	}

## Sleeps `ms`, a quarter of a second at a time: `Bool.False` as soon as the server is stopping.
waited! : U64 => Bool
waited! = |ms| {
	var $left = ms
	var $going = !Plugin.stopping!({})
	while $going and $left > 0 {
		step = U64.min($left, 250)
		Time.sleep!(step)
		$left = $left - step
		$going = !Plugin.stopping!({})
	}
	$going
}

## Sends what was kept, oldest first. PostHog not answering (or answering 5xx) puts it back for the
## next time; refusing it (4xx: a wrong key) drops it, said on the log.
sent! : Settings => {}
sent! = |settings| {
	taken : Try(List(Event.Problem), [NotFound, BadValue(Str)])
	taken = Kv.take!(queue_key)
	match taken {
		Err(NotFound) => {}
		Err(BadValue(why)) => Log.warn!("posthog: the errors kept can't be read, and go", { error: why })
		Ok(newest_first) =>
			if newest_first.is_empty() {
				{}
			} else {
				body = Event.batch(settings.key, settings.release, reversed(newest_first))
				init : Http.Init
				init = { method: Post, headers: [("content-type", "application/json")], body: PlainText(body), timeout_ms: 10_000, max_bytes: 65_536, redirect: Manual }
				count = newest_first.len()
				match Http.fetch!("${settings.host}/batch/", init) {
					Ok(res) =>
						if res.ok {
							{}
						} else if res.status >= 500 {
							Log.warn!("posthog: PostHog didn't take the errors, sent again next time", { count: count, status: res.status })
							put_back!(newest_first)
						} else {
							Log.warn!("posthog: PostHog refused the errors, and they go", { count: count, status: res.status, answer: cut(res.text(), 300) })
						}
					Err(HttpErr(why)) => {
						Log.warn!("posthog: the errors couldn't be sent, sent again next time", { count: count, error: why })
						put_back!(newest_first)
					}
					Err(TimedOut) => {
						Log.warn!("posthog: the errors couldn't be sent, sent again next time", { count: count, error: "timed out" })
						put_back!(newest_first)
					}
					Err(TooLarge) => {}
				}
			}
	}
}

## Problems not sent, back in the queue, the newest at its front again.
put_back! : List(Event.Problem) => {}
put_back! = |newest_first|
	for problem in reversed(newest_first) {
		Kv.push!(queue_key, problem, { keep: kept })
	}

## `list`, last first.
reversed : List(a) -> List(a)
reversed = |list| {
	var $out = List.with_capacity(list.len())
	var $at = list.len()
	while $at > 0 {
		$at = $at - 1
		$out =
			match list.get($at) {
				Ok(each) => $out.append(each)
				Err(_) => $out
			}
	}
	$out
}

expect reversed([1, 2, 3]) == [3, 2, 1]
expect reversed([]) == []

## The fields as a JSON object (a record that can't be written, said so).
written : fields -> Str where [fields.Json.Encodable(e)]
written = |fields|
	match Json.to_str_try(fields) {
		Ok(json) => json
		Err(_) => "{\"fields\":\"they hold a number JSON can't write (an F64 that is NaN or an infinity)\"}"
	}

## At most `max` bytes of `text` (a character cut in two ends in U+FFFD).
cut : Str, U64 -> Str
cut = |text, max| if (text.count_utf8_bytes() <= max) text else Str.from_utf8_lossy(text.to_utf8().take_first(max))
