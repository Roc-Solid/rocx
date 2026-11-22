import pf.Db
import pf.Middleware
import pf.Plugin
import pf.Server
import pf.Time
import jobs.Cron
import jobs.Job
import AdminHtml
import Look

## The jobs page: a console of packages/jobs's queue, as a plugin the app lists, behind a guard of
## its own (only the app knows who may see it). How many jobs are queued, running, failed, done and
## canceled; what finished in the last hour, and the latest failures; each kind, with its attempts,
## time limit and jobs; the schedules and when each runs next; and the jobs, newest first, each
## opening in a drawer with its input, attempts, times and last error. Retry, cancel and run now
## are plain forms, answered with a redirect back. It refreshes itself as jobs change (a stream of
## events), and works without script too.
##
## ```roc
## plugins: [
##     Job.plugin({ jobs: App.jobs }),
##     JobsPage.plugin({ at: "/admin/jobs", guard: Middlewares.admin }),   # `guard` has no default
##     # or, with a link back to the app's own pages, first in its sidebar:
##     JobsPage.plugin({ guard: Middlewares.admin, back: { label: "Status", href: "/admin" } }),
## ]
## ```
##
## An app that mounts it itself answers a route with `respond!` (`mount` is the path it is at):
##
## ```roc
## # routes/admin/jobs/+server.roc
## middleware = Middlewares.admin
## respond! = |{ request, .. }| JobsPage.respond!(request, { mount: "/admin/jobs" })   # back: as above
## ```
##
## It answers GET (`?state=failed`, `?kind=…`, `?before=<id>` for older ones, `?id=123` for one
## job, over the list the rest of the query picks, `?events` for its stream of changes) and POST
## (`action=retry|cancel|run_now` with `id=`, or `action=run_schedule` with `name=`). A POST from
## another site's page is refused (403), as `Middleware.same_origin` would.
JobsPage := [].{

	## Where the page is (`at`), and who may see it: `guard`, the app's middleware for its admins,
	## which runs after the app's own and may refuse, or send a stranger to sign in. What it hands on
	## isn't used. `guard` has no default: a jobs page is never public because an option was left
	## out. `back`: a link back to the app's own pages, first in the sidebar
	## (`{ label: "Status", href: "/admin" }`); none unless the app says (`href` "").
	Options(ctx, out) := { at : Str ?? "/admin/jobs", guard : Middleware(ctx, out), back : { label : Str, href : Str } ?? { label: "", href: "" } }

	## Where the page an app mounts itself is (`mount`), and its link back to the app (`back`, as
	## `Options` has it).
	Mount := { mount : Str, back : { label : Str, href : Str } ?? { label: "", href: "" } }

	## The jobs page as a plugin (`jobs-page`): its page at `at`, behind `guard`, which answers GET
	## and POST (and 405 to any other method). It needs the jobs plugin (`Job.plugin`), whose queue it
	## shows. Pages, not endpoints: not in the app's `/openapi.json`.
	plugin : Options(ctx, out) -> Plugin.Value(ctx)
	plugin = |options| {
		at = options.at
		guard = options.guard
		back = options.back
		{
			name: "jobs-page",
			# One route, for every method (`*`): two routes (GET and POST) whose closures each capture the
			# guard crash a server built with --opt=speed as it starts (a compiler bug:
			# test/compiler-bugs/two-guarded-routes-opt-speed). Back to a GET and a POST route once the
			# compiler is fixed.
			routes: [{ method: "*", path: at, kind: Page, answer!: |request, context| Middleware.run!(guard, request, context, |passed, _handed| JobsPage.respond!(passed, { mount: at, back })) }],
			needs: [Plugin("jobs")],
		}
	}

	## Answers a request to the jobs page at `mount`: a GET draws it (or streams its changes), a
	## POST retries, cancels or runs a job, or runs a schedule, and redirects back; any other method
	## is a 405.
	respond! : Server.Request, Mount => Server.Response
	respond! = |request, mounted| {
		mount = mounted.mount
		if request.method == "POST" {
			act!(request, mount)
		} else if request.method == "GET" or request.method == "HEAD" {
			if AdminHtml.asks(request.query, "events") {
				AdminHtml.changes([Job.changes], "rocx_jobs")
			} else {
				shown!(mount, mounted.back, request.query)
			}
		} else {
			Server.response(405, [{ name: "allow", value: "GET, HEAD, POST" }, { name: "content-type", value: "text/plain; charset=utf-8" }], "The jobs page answers GET and POST.")
		}
	}
}

states : List(Str)
states = ["queued", "running", "failed", "done", "canceled"]

## How many jobs a page lists at a time.
per_page : U64
per_page = 50

## How many there are in `state` (of `kind`, or of all if "").
count_of : List({ kind : Str, state : Str, count : U64 }), Str, Str -> U64
count_of = |counts, kind, state| counts.keep_if(|each| (kind.is_empty() or each.kind == kind) and (state.is_empty() or each.state == state)).fold(0, |sum, each| sum + each.count)

## The colour a state is drawn in.
tone : Str -> Str
tone = |state|
	match state {
		"queued" => "warn"
		"running" => "active"
		"failed" => "bad"
		"done" => "good"
		_ => "neutral"
	}

## Each kind's name: the app's, then any other the queue has jobs of (another app's).
kind_names : List(Job.KindInfo), List({ kind : Str, state : Str, count : U64 }) -> List(Str)
kind_names = |kinds, counts| {
	listed = kinds.map(|each| each.name)
	counts.map(|each| each.kind).fold(listed, |seen, name| if (seen.contains(name)) seen else seen.append(name))
}

## What a kind says of itself: its attempts and time limit, or that it is another app's.
kind_meta : List(Job.KindInfo), Str -> Str
kind_meta = |kinds, name|
	match kinds.find_first(|each| each.name == name) {
		Ok(kind) => "${kind.attempts.to_str()} attempts · ${if (kind.timeout_ms == 0) "no time limit" else "${AdminHtml.span(kind.timeout_ms.to_i64_wrap())} limit"}"
		Err(_) => "another app's kind"
	}

## The page: how many there are in each state, then the jobs the query picks; with no filter, the
## last hour, the latest failures, the kinds and the schedules too; with `?id=`, that job in a
## drawer over it.
shown! : Str, { label : Str, href : Str }, Str => Server.Response
shown! = |mount, back, query| {
	state = AdminHtml.param(query, "state")
	kind = AdminHtml.param(query, "kind")
	before = I64.from_str(AdminHtml.param(query, "before")) ?? 0
	wanted = I64.from_str(AdminHtml.param(query, "id"))
	now = Time.now_millis!({}).to_i64_wrap()
	kinds = Job.kinds!({})
	read =
		match (Job.counts!({}), Job.list!({ state, kind, before_id: before, limit: per_page })) {
			(Ok(counts), Ok(rows)) => Ok((counts, rows))
			(Err(JobErr(why)), _) => Err(why)
			(_, Err(JobErr(why))) => Err(why)
		}
	match read {
		Err(why) => {
			body = "${Look.header({ eyebrow: "Queue", title: "Jobs", actions: "" })}<section class=\"panel\"><div class=\"callout tone-bad\">${Look.icon("alert")}<div><strong>The queue can't be read</strong><p class=\"problem\">${Look.escape(why)}</p></div></div></section>"
			side = if (back.href.is_empty()) "" else Look.side({ name: "Jobs", note: "The queue, in Postgres", home: mount, nav: Look.back_link(back), foot: "" })
			AdminHtml.page(500, { title: "Jobs", events: "", now, side, body })
		}
		Ok((counts, rows)) => {
			filters = [("state", state), ("kind", kind), ("before", if (before == 0) "" else before.to_str())]
			here = AdminHtml.link(mount, filters)
			overview = state.is_empty() and kind.is_empty() and before == 0
			opened =
				match wanted {
					Ok(id) => drawer!(mount, query, here, id, now, kinds)
					Err(_) => { status: 200, html: "" }
				}
			refresh =
				match wanted {
					Ok(id) => AdminHtml.link(mount, filters.append(("id", id.to_str())))
					Err(_) => here
				}
			titled = if (state.is_empty()) "Jobs" else "${AdminHtml.capitalized(state)} jobs"
			heading =
				if kind.is_empty() {
					Look.header({ eyebrow: if (state.is_empty()) "Queue · Overview" else "Queue · State", title: titled, actions: AdminHtml.live(now, refresh) })
				} else {
					Look.header({ eyebrow: if (state.is_empty()) "Kind" else "Kind · ${AdminHtml.capitalized(state)}", title: "<code>${Look.escape(kind)}</code><span class=\"meta\">${Look.escape(kind_meta(kinds, kind))}</span>", actions: AdminHtml.live(now, refresh) })
				}
			hour =
				if state.is_empty() and before == 0 {
					activity_panel!(mount, kind)
				} else {
					""
				}
			upper =
				if overview {
					"<div class=\"grid\">${hour}${failures_panel!(mount, counts, now)}</div>"
				} else {
					hour
				}
			lower =
				if overview {
					kinds_html = kinds_panel(mount, counts, kinds)
					schedules_html = schedules_panel!(mount, query, now)
					if kinds_html.is_empty() or schedules_html.is_empty() {
						"${kinds_html}${schedules_html}"
					} else {
						"<div class=\"grid\">${kinds_html}${schedules_html}</div>"
					}
				} else {
					""
				}
			body = Str.join_with(
				[
					heading,
					metrics(mount, counts, state, kind),
					upper,
					lower,
					jobs_panel(mount, query, { state, kind, before, selected: wanted ?? 0 }, rows, now),
					opened.html,
				],
				"",
			)
			title =
				match wanted {
					Ok(id) => "Job #${id.to_str()} · Jobs"
					Err(_) => if (kind.is_empty()) titled else "${kind} · Jobs"
				}
			AdminHtml.page(opened.status, { title, events: AdminHtml.link(mount, [("events", "1")]), now, side: sidebar(mount, back, counts, kinds, state, kind), body })
		}
	}
}

## The sidebar: the link back to the app (`back`, if it has one), the overview, each state and each
## kind, with how many jobs each has.
sidebar : Str, { label : Str, href : Str }, List({ kind : Str, state : Str, count : U64 }), List(Job.KindInfo), Str, Str -> Str
sidebar = |mount, back, counts, kinds, state, kind| {
	overview = Look.nav_link({ href: mount, icon: "overview", tone: "accent", label: "Overview", count: "", on: state.is_empty() and kind.is_empty() })
	by_state = states.map(
		|each| {
			count = count_of(counts, "", each)
			Look.nav_link({ href: AdminHtml.link(mount, [("state", each)]), icon: "", tone: if (each == "failed" and count == 0) "neutral" else tone(each), label: AdminHtml.capitalized(each), count: count.to_str(), on: kind.is_empty() and state == each })
		},
	)
	by_kind = kind_names(kinds, counts).map(|name| Look.nav_link({ href: AdminHtml.link(mount, [("kind", name)]), icon: "layers", tone: "neutral", label: "<code>${Look.escape(name)}</code>", count: count_of(counts, name, "").to_str(), on: kind == name }))
	kinds_nav = if (by_kind.is_empty()) "" else "${Look.nav_label("Kinds")}${Str.join_with(by_kind, "")}"
	nav = "${Look.back_link(back)}${overview}${Look.nav_label("States")}${Str.join_with(by_state, "")}${kinds_nav}"
	Look.side({ name: "Jobs", note: "The queue, in Postgres", home: mount, nav, foot: "Times are UTC. Done jobs are kept for a week." })
}

## How many jobs are in each state (of the kind shown), each a link to them.
metrics : Str, List({ kind : Str, state : Str, count : U64 }), Str, Str -> Str
metrics = |mount, counts, state, kind| {
	cell = |label, wanted|
		{
			count = count_of(counts, kind, wanted)
			current = if (wanted == state) " aria-current=\"page\"" else ""
			zero = if (count == 0) " zero" else ""
			toned = if (wanted.is_empty()) "" else " tone-${tone(wanted)}"
			dot = if (wanted.is_empty()) "" else "<i class=\"dot\"></i>"
			"<a class=\"metric${toned}${zero}\" href=\"${Look.escape(AdminHtml.link(mount, [("state", wanted), ("kind", kind)]))}\"${current}><span class=\"metric-label\">${dot}${label}</span><strong>${count.to_str()}</strong></a>"
		}
	cells = [cell("All", "")].concat(states.map(|each| cell(AdminHtml.capitalized(each), each)))
	"<nav class=\"metrics\" aria-label=\"States\">${Str.join_with(cells, "")}</nav>"
}

## What finished in each five minutes of the last hour (of `kind`, or of all if ""): done (`retried`
## when it took more than one attempt) or failed.
activity! : Str => Try(List({ bucket : I64, state : Str, count : I64 }), [DbErr(Str), BadRow(Str)])
activity! = |kind|
	if Db.backend!({}) == Sqlite {
		# The queue's times are milliseconds there (packages/jobs, D-045).
		Db.all!(
			"select max(0, min(11, ($2 - finished_at) / 300000)) as bucket, case when state = 'done' and attempts > 1 then 'retried' else state end as state, count(*) as count from rocx_jobs where finished_at > $2 - 3600000 and state in ('done', 'failed') and ($1 = '' or kind = $1) group by 1, 2",
			[Text(kind), Int(Time.now_millis!({}).to_i64_wrap())],
		)
	} else {
		Db.all!(
			"select greatest(0, least(11, floor(extract(epoch from (now() - finished_at)) / 300)))::int8 as bucket, case when state = 'done' and attempts > 1 then 'retried' else state end as state, count(*)::int8 as count from rocx_jobs where finished_at > now() - interval '60 minutes' and state in ('done', 'failed') and ($1 = '' or kind = $1) group by 1, 2",
			[Text(kind)],
		)
	}

## The last hour, as twelve bars of five minutes: done, done after a retry, and failed.
activity_panel! : Str, Str => Str
activity_panel! = |mount, kind| {
	head = |aside, body| Look.panel({ eyebrow: "Last 60 minutes", title: "Finished jobs", aside, body, class: "hour" })
	match activity!(kind) {
		Err(DbErr(why)) => head("", "<p class=\"problem\">${Look.escape(why)}</p>")
		Err(BadRow(why)) => head("", "<p class=\"problem\">${Look.escape(why)}</p>")
		Ok(found) => {
			got = |bucket, wanted| found.keep_if(|each| each.bucket == bucket and each.state == wanted).fold(0, |sum, each| sum + each.count)
			columns = [11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0].map(|bucket| { bucket, done: got(bucket, "done"), retried: got(bucket, "retried"), failed: got(bucket, "failed") })
			tallest = columns.fold(1, |most, each| if (each.done + each.retried + each.failed > most) each.done + each.retried + each.failed else most)
			done = columns.fold(0, |sum, each| sum + each.done)
			retried = columns.fold(0, |sum, each| sum + each.retried)
			failed = columns.fold(0, |sum, each| sum + each.failed)
			if done + retried + failed == 0 {
				head("", Look.empty("clock", "Nothing finished in the last hour", "Jobs show here as the workers finish them."))
			} else {
				bars = columns.map(
					|each| {
						total = each.done + each.retried + each.failed
						height = if (total == 0) 0 else if (total * 100 // tallest < 3) 3 else total * 100 // tallest
						segment = |count, toned| if (count == 0) "" else "<i class=\"tone-${toned}\" style=\"flex-grow:${count.to_str()}\"></i>"
						said = "${((each.bucket + 1) * 5).to_str()} to ${(each.bucket * 5).to_str()} min ago: ${each.done.to_str()} done, ${each.retried.to_str()} done after a retry, ${each.failed.to_str()} failed"
						"<div class=\"bar\" style=\"height:${height.to_str()}%\" title=\"${said}\">${segment(each.done, "good")}${segment(each.retried, "warn")}${segment(each.failed, "bad")}</div>"
					},
				)
				failed_link = if (failed == 0) "<span><i class=\"dot tone-bad\"></i><b>0</b> failed</span>" else "<a href=\"${Look.escape(AdminHtml.link(mount, [("state", "failed"), ("kind", kind)]))}\"><span><i class=\"dot tone-bad\"></i><b>${failed.to_str()}</b> failed</span></a>"
				legend = "<div class=\"legend\"><span><i class=\"dot tone-good\"></i><b>${done.to_str()}</b> done</span><span><i class=\"dot tone-warn\"></i><b>${retried.to_str()}</b> done after a retry</span>${failed_link}</div>"
				chart = "<div class=\"chart\">${legend}<div class=\"bars\" role=\"img\" aria-label=\"In the last hour: ${done.to_str()} done, ${retried.to_str()} done after a retry, ${failed.to_str()} failed\">${Str.join_with(bars, "")}</div><div class=\"axis\"><span>60 min ago</span><span>30 min</span><span>now</span></div></div>"
				head("<span>${(done + retried + failed).to_str()} in all</span>", chart)
			}
		}
	}
}

## The latest jobs that failed for good, with why.
failures_panel! : Str, List({ kind : Str, state : Str, count : U64 }), I64 => Str
failures_panel! = |mount, counts, now| {
	failed = count_of(counts, "", "failed")
	all = if (failed == 0) "" else "<a class=\"btn\" href=\"${Look.escape(AdminHtml.link(mount, [("state", "failed")]))}\">All ${failed.to_str()}${Look.icon("next")}</a>"
	body =
		match Job.list!({ state: "failed", kind: "", before_id: 0, limit: 5 }) {
			Err(JobErr(why)) => "<p class=\"problem\">${Look.escape(why)}</p>"
			Ok(rows) if rows.is_empty() => Look.empty("check", "No failed jobs", "Each job that fails for good shows here, with why.")
			Ok(rows) => {
				items = rows.map(
					|row| {
						why =
							match row.last_error {
								Some(text) => "<code class=\"err\" title=\"${Look.escape(text)}\">${Look.escape(AdminHtml.shortened(text))}</code>"
								Null => ""
							}
						ago =
							match row.finished_at {
								Some(at) => " · ${AdminHtml.relative(at, now)}"
								Null => ""
							}
						"<li><a class=\"failure\" href=\"${Look.escape(AdminHtml.link(mount, [("id", row.id.to_str())]))}\"><span class=\"badge\">${Look.icon("alert")}</span><div><strong>${Look.escape(row.kind)}</strong><span>#${row.id.to_str()} · tried ${row.attempts.to_str()} of ${row.max_attempts.to_str()}${ago}</span>${why}</div></a></li>"
					},
				)
				"<ul class=\"list\">${Str.join_with(items, "")}</ul>"
			}
		}
	Look.panel({ eyebrow: "Latest", title: "Failures", aside: all, body, class: "failures" })
}

## Each kind (the app's, and any other in the queue), its attempts and time limit, and how many of
## its jobs are in each state.
kinds_panel : Str, List({ kind : Str, state : Str, count : U64 }), List(Job.KindInfo) -> Str
kinds_panel = |mount, counts, kinds| {
	names = kind_names(kinds, counts)
	if names.is_empty() {
		""
	} else {
		rows = names.map(
			|name| {
				total = count_of(counts, name, "")
				parts = states.keep_if(|state| count_of(counts, name, state) > 0).map(|state| "<i class=\"tone-${tone(state)}\" style=\"flex-grow:${count_of(counts, name, state).to_str()}\"></i>")
				spread = if (total == 0) "<div class=\"dist\"></div>" else "<div class=\"dist\" title=\"${total.to_str()} jobs\">${Str.join_with(parts, "")}</div>"
				cells = states.map(
					|state| {
						count = count_of(counts, name, state)
						if count == 0 {
							"<td class=\"n count zero\">0</td>"
						} else {
							"<td class=\"n count tone-${tone(state)}\"><a href=\"${Look.escape(AdminHtml.link(mount, [("state", state), ("kind", name)]))}\">${count.to_str()}</a></td>"
						}
					},
				)
				"<tr><td><a class=\"kind-name\" href=\"${Look.escape(AdminHtml.link(mount, [("kind", name)]))}\"><code>${Look.escape(name)}</code></a><span class=\"kind-meta\">${Look.escape(kind_meta(kinds, name))}</span></td><td class=\"spread\">${spread}</td>${Str.join_with(cells, "")}</tr>"
			},
		)
		heads = Str.join_with(states.map(|state| "<th class=\"n\">${state}</th>"), "")
		table = "<div class=\"table-wrap\"><table class=\"kinds\"><thead><tr><th>Kind</th><th>Jobs</th>${heads}</tr></thead><tbody>${Str.join_with(rows, "")}</tbody></table></div>"
		Look.panel({ eyebrow: "What the workers run", title: "Kinds", aside: "<span>${names.len().to_str()} kinds</span>", body: table, class: "" })
	}
}

## The schedules, when each runs next, and a button that queues its job now.
schedules_panel! : Str, Str, I64 => Str
schedules_panel! = |mount, query, now| {
	schedules = Cron.schedules!({})
	if schedules.is_empty() {
		""
	} else {
		items = schedules.map(
			|each| {
				next =
					match each.next_at {
						Some(at) => "next ${AdminHtml.relative(at, now)}"
						Null => "never again"
					}
				run = Look.button_with("", "play", mount, [("action", "run_schedule"), ("name", each.name), ("back", query)], "Run now")
				"<li class=\"schedule\"><div><a href=\"${Look.escape(AdminHtml.link(mount, [("kind", each.job)]))}\"><code>${Look.escape(each.job)}</code></a>${run}</div><div><span class=\"cron\"><code>${Look.escape(each.schedule)}</code>${Look.escape(described(each.schedule))}</span><span class=\"next\">${next}</span></div></li>"
			},
		)
		Look.panel({ eyebrow: "Cron, in UTC", title: "Schedules", aside: "", body: "<ul class=\"list\">${Str.join_with(items, "")}</ul>", class: "schedules" })
	}
}

## The jobs the query picks, newest first, a page at a time.
jobs_panel : Str, Str, { state : Str, kind : Str, before : I64, selected : I64 }, List(Job.Row), I64 -> Str
jobs_panel = |mount, query, { state, kind, before, selected }, rows, now| {
	filters = [("state", state), ("kind", kind), ("before", if (before == 0) "" else before.to_str())]
	chip_state = if (state.is_empty()) "" else "<span class=\"chip\">${badge(state)}<a href=\"${Look.escape(AdminHtml.link(mount, [("kind", kind)]))}\" aria-label=\"Any state\" title=\"Any state\">${Look.icon("close")}</a></span>"
	chip_kind = if (kind.is_empty()) "" else "<span class=\"chip\"><code>${Look.escape(kind)}</code><a href=\"${Look.escape(AdminHtml.link(mount, [("state", state)]))}\" aria-label=\"Every kind\" title=\"Every kind\">${Look.icon("close")}</a></span>"
	title = if (state.is_empty()) "Jobs" else "${AdminHtml.capitalized(state)} jobs"
	body =
		if rows.is_empty() {
			if state == "failed" {
				Look.empty("check", "No failed jobs", "Nothing here has failed for good.")
			} else {
				Look.empty("layers", "No jobs here", "Jobs show here as they are queued.")
			}
		} else {
			lines = rows.map(
				|row| {
					href = AdminHtml.link(mount, filters.append(("id", row.id.to_str())))
					key =
						match row.key {
							Some(text) => "<code class=\"key\" title=\"${Look.escape(text)}\">${Look.escape(text)}</code>"
							Null => "<span class=\"muted\">—</span>"
						}
					error =
						match row.last_error {
							Some(why) => "<span class=\"err\" title=\"${Look.escape(why)}\">${Look.escape(AdminHtml.shortened(why))}</span>"
							Null => ""
						}
					picked = if (selected == row.id) " class=\"selected\"" else ""
					"<tr${picked}><td class=\"job\"><a class=\"row-link\" href=\"${Look.escape(href)}\"><strong>${Look.escape(row.kind)}</strong><span>#${row.id.to_str()}</span></a>${error}</td><td>${badge(row.state)}</td><td class=\"n\"><span class=\"tries\">${row.attempts.to_str()}<small> of ${row.max_attempts.to_str()}</small></span></td><td class=\"when\">${timing(row, now)}</td><td>${key}</td><td class=\"actions\">${actions(mount, query, row, now)}</td></tr>"
				},
			)
			"<div class=\"table-wrap\"><table class=\"jobs\"><thead><tr><th>Job</th><th>State</th><th class=\"n\">Tried</th><th>When</th><th>Key</th><th></th></tr></thead><tbody>${Str.join_with(lines, "")}</tbody></table></div>"
		}
	newest = if (before == 0) "" else "<a class=\"btn\" href=\"${Look.escape(AdminHtml.link(mount, [("state", state), ("kind", kind)]))}\">${Look.icon("back")}Newest</a>"
	older =
		match rows.last() {
			Ok(last) if rows.len() == per_page => "<a class=\"btn\" href=\"${Look.escape(AdminHtml.link(mount, [("state", state), ("kind", kind), ("before", last.id.to_str())]))}\">Older${Look.icon("next")}</a>"
			_ => ""
		}
	shown =
		match (rows.first(), rows.last()) {
			(Ok(first), Ok(last)) => "#${first.id.to_str()} to #${last.id.to_str()}"
			_ => "none"
		}
	foot = if (rows.is_empty() and before == 0) "" else "<div class=\"panel-foot\"><span>${rows.len().to_str()} shown, ${shown}</span><span class=\"pages\">${newest}${older}</span></div>"
	Look.panel({ eyebrow: "Newest first", title, aside: "${chip_state}${chip_kind}", body: "${body}${foot}", class: "jobs-panel" })
}

## One job, in a drawer over the list (`close` is the list): everything the queue knows of it, and
## what may be done to it.
drawer! : Str, Str, Str, I64, I64, List(Job.KindInfo) => { status : U16, html : Str }
drawer! = |mount, query, close, id, now, kinds| {
	frame = |eyebrow, title, content| "<a class=\"scrim\" href=\"${Look.escape(close)}\" tabindex=\"-1\" aria-hidden=\"true\"></a><aside class=\"drawer\" role=\"dialog\" aria-labelledby=\"job-title\"><header class=\"drawer-head\"><div><p class=\"eyebrow\">${eyebrow}</p><h2 id=\"job-title\">${title}</h2></div><a class=\"icon-btn\" href=\"${Look.escape(close)}\" data-close aria-label=\"Close\" title=\"Close (Esc)\">${Look.icon("close")}</a></header>${content}</aside>"
	match Job.get!(id) {
		Err(NotFound) => { status: 404, html: frame("Job #${id.to_str()}", "No job #${id.to_str()}", Look.empty("layers", "No job #${id.to_str()}", "It may have been done more than a week ago.")) }
		Err(JobErr(why)) => { status: 500, html: frame("Job #${id.to_str()}", "Job #${id.to_str()}", "<div class=\"callout tone-bad\">${Look.icon("alert")}<div><strong>The queue can't be read</strong><p class=\"problem\">${Look.escape(why)}</p></div></div>") }
		Ok(row) => {
			limit =
				match kinds.find_first(|kind| kind.name == row.kind) {
					Ok(kind) => if (kind.timeout_ms == 0) "none" else AdminHtml.span(kind.timeout_ms.to_i64_wrap())
					Err(_) => "<span class=\"muted\">not this app's kind</span>"
				}
			key =
				match row.key {
					Some(text) => "<code>${Look.escape(text)}</code>"
					Null => "<span class=\"muted\">none</span>"
				}
			facts = Str.join_with(
				[
					"<div><dt>Kind</dt><dd><a href=\"${Look.escape(AdminHtml.link(mount, [("kind", row.kind)]))}\"><code>${Look.escape(row.kind)}</code></a></dd></div>",
					"<div><dt>Tried</dt><dd>${row.attempts.to_str()} of ${row.max_attempts.to_str()} times</dd></div>",
					"<div><dt>Time limit</dt><dd>${limit}</dd></div>",
					"<div><dt>Key</dt><dd>${key}</dd></div>",
				],
				"",
			)
			error =
				match row.last_error {
					Some(why) => "<section class=\"section\"><h3>Last error</h3><pre class=\"problem\">${Look.escape(why)}</pre></section>"
					Null => ""
				}
			content = Str.join_with(
				[
					"<div class=\"drawer-status\">${badge(row.state)}<span>${timing(row, now)}</span><span>tried ${row.attempts.to_str()} of ${row.max_attempts.to_str()}</span></div>",
					callout(mount, query, row, now),
					error,
					"<section class=\"section\"><h3>Input <small>JSON</small></h3><pre class=\"json\">${AdminHtml.json(row.input)}</pre></section>",
					"<section class=\"section\"><h3>Details</h3><dl class=\"facts\">${facts}</dl></section>",
					"<section class=\"section\"><h3>Timeline</h3><ol class=\"timeline\">${timeline(row, now)}</ol></section>",
				],
				"",
			)
			{ status: 200, html: frame("Job #${id.to_str()}", "<code>${Look.escape(row.kind)}</code>", content) }
		}
	}
}

## What may be done to a job, said in the drawer: retry, run now, cancel; or why nothing may.
callout : Str, Str, Job.Row, I64 -> Str
callout = |mount, back, row, now| {
	act = |class, symbol, action, label| Look.button_with(class, symbol, mount, [("action", action), ("id", row.id.to_str()), ("back", back)], label)
	said = |toned, symbol, title, line, acts| "<div class=\"callout tone-${toned}\">${Look.icon(symbol)}<div><strong>${title}</strong><span>${line}</span></div><div class=\"acts\">${acts}</div></div>"
	match row.state {
		"failed" => said("bad", "retry", "Retry this job", "It is queued again now, its attempts counted from the start.", act("act-primary", "retry", "retry", "Retry"))
		"canceled" => said("neutral", "retry", "Queue it again", "A canceled job runs if it is retried, its attempts counted from the start.", act("act-primary", "retry", "retry", "Retry"))
		"queued" =>
			if row.run_at > now {
				said("warn", "clock", "Waiting until it is due", "It runs ${AdminHtml.relative(row.run_at, now)}. Run it now, or cancel it.", "${act("act-primary", "play", "run_now", "Run now")}${act("act-danger", "stop", "cancel", "Cancel")}")
			} else {
				said("warn", "clock", "Waiting for a worker", "It is due: the next free worker takes it. It can still be canceled.", act("act-danger", "stop", "cancel", "Cancel"))
			}
		"running" => said("active", "play", "Running", "A running job isn't stopped from here: it ends when it is done, fails, or reaches its time limit.", "")
		_ => ""
	}
}

## A job's times, in order: queued, due, its last attempt, finished.
timeline : Job.Row, I64 -> Str
timeline = |row, now| {
	step = |toned, label, at| "<li class=\"tone-${toned}\"><i class=\"dot\"></i><div><strong>${label}</strong><span>${AdminHtml.relative(at, now)} · ${AdminHtml.moment(at)}</span></div></li>"
	due_past = if (row.run_at <= now and row.run_at - row.created_at > 1000) step("neutral", "Due", row.run_at) else ""
	began =
		match row.locked_at {
			Some(at) => step("active", if (row.state == "running") "Started" else if (row.attempts > 1) "Last attempt began" else "Started", at)
			Null => ""
		}
	due_later = if (row.run_at > now) step("warn", if (row.attempts > 0) "Tried again" else "Runs", row.run_at) else ""
	finished =
		match row.finished_at {
			Some(at) => step(tone(row.state), AdminHtml.capitalized(row.state), at)
			Null => ""
		}
	"${step("neutral", "Queued", row.created_at)}${due_past}${began}${due_later}${finished}"
}

badge : Str -> Str
badge = |state| "<span class=\"state state-${Look.escape(state)}\">${Look.escape(state)}</span>"

## When a job runs, ran, or finished, as it stands now.
timing : Job.Row, I64 -> Str
timing = |row, now|
	match row.state {
		"queued" =>
			if row.run_at > now {
				"${if (row.attempts > 0) "again " else "runs "}${AdminHtml.relative(row.run_at, now)}"
			} else {
				"due ${AdminHtml.relative(row.run_at, now)}"
			}
		"running" =>
			match row.locked_at {
				Some(at) => "started ${AdminHtml.relative(at, now)}"
				Null => ""
			}
		_ =>
			match row.finished_at {
				Some(at) => "${row.state} ${AdminHtml.relative(at, now)}"
				Null => ""
			}
	}

## What may be done to a job in its state, in the list: retry one that failed or was canceled; run
## now or cancel one that is queued.
actions : Str, Str, Job.Row, I64 -> Str
actions = |mount, back, row, now| {
	act = |class, action, label| Look.button_with(class, "", mount, [("action", action), ("id", row.id.to_str()), ("back", back)], label)
	match row.state {
		"failed" | "canceled" => act("", "retry", "Retry")
		"queued" => "${if (row.run_at > now) act("", "run_now", "Run now") else ""}${act("act-danger", "cancel", "Cancel")}"
		_ => ""
	}
}

## A schedule in words, for the common ones (`every 5 minutes`, `daily at 03:00`); "" for others.
described : Str -> Str
described = |schedule| {
	fields = schedule.split_on(" ").keep_if(|each| !each.is_empty())
	at = |index| fields.get(index) ?? ""
	rest = |from| fields.drop_first(from).all(|each| each == "*")
	number = |text| U64.from_str(text).is_ok()
	if fields.len() == 6 {
		if rest(0) {
			"every second"
		} else if rest(1) and at(0).starts_with("*/") {
			"every ${at(0).drop_prefix("*/")} seconds"
		} else {
			""
		}
	} else if fields.len() == 5 {
		minute = at(0)
		hour = at(1)
		clock = "${padded(hour)}:${padded(minute)}"
		plain_days = at(2) == "*" and at(3) == "*"
		if rest(0) {
			"every minute"
		} else if rest(1) and minute.starts_with("*/") {
			"every ${minute.drop_prefix("*/")} minutes"
		} else if rest(1) and number(minute) {
			"hourly at :${padded(minute)}"
		} else if number(minute) and hour.starts_with("*/") and rest(2) {
			"every ${hour.drop_prefix("*/")} hours at :${padded(minute)}"
		} else if number(minute) and number(hour) and rest(2) {
			"daily at ${clock}"
		} else if number(minute) and number(hour) and plain_days and at(4) == "1-5" {
			"weekdays at ${clock}"
		} else if number(minute) and number(hour) and plain_days and number(at(4)) {
			"${weekday(at(4))} at ${clock}"
		} else if number(minute) and number(hour) and number(at(2)) and at(3) == "*" and at(4) == "*" {
			"monthly, on day ${at(2)}, at ${clock}"
		} else {
			""
		}
	} else {
		""
	}
}

padded : Str -> Str
padded = |text| if (text.to_utf8().len() == 1) "0${text}" else text

weekday : Str -> Str
weekday = |day|
	match day {
		"0" | "7" => "Sundays"
		"1" => "Mondays"
		"2" => "Tuesdays"
		"3" => "Wednesdays"
		"4" => "Thursdays"
		"5" => "Fridays"
		"6" => "Saturdays"
		_ => "on day ${day} of the week"
	}

## A form's action, done; then back where it was sent from (`back`: the page's query).
act! : Server.Request, Str => Server.Response
act! = |request, mount|
	if !Server.same_origin(request) {
		Server.refused(403, "The jobs page's forms are sent from its own pages.")
	} else {
		form = Server.text_of(request)
		back = AdminHtml.safe_query(AdminHtml.param(form, "back"))
		returned = if (back.is_empty()) mount else "${mount}?${back}"
		action = AdminHtml.param(form, "action")
		id = I64.from_str(AdminHtml.param(form, "id"))
		done =
			match (action, id) {
				("retry", Ok(job)) => Job.retry!(job)
				("cancel", Ok(job)) => Job.cancel_id!(job)
				("run_now", Ok(job)) => Job.run_now!(job)
				("run_schedule", _) =>
					match Cron.run_now!(AdminHtml.param(form, "name")) {
						Ok({}) => Ok({})
						Err(NotFound) => Err(JobErr("no schedule is called ${AdminHtml.param(form, "name")}"))
						Err(JobErr(why)) => Err(JobErr(why))
					}
				_ => Err(JobErr("not something the jobs page does: action=${action}, id=${AdminHtml.param(form, "id")}"))
			}
		match done {
			Ok({}) => Server.redirect(returned)
			Err(NotFound) => AdminHtml.problem(404, "There is no job #${AdminHtml.param(form, "id")}.", returned)
			Err(JobErr(why)) => AdminHtml.problem(409, why, returned)
		}
	}

expect described("*/5 * * * *") == "every 5 minutes"
expect described("0 3 * * *") == "daily at 03:00"
expect described("0 9 * * 1") == "Mondays at 09:00"
expect described("30 8 * * 1-5") == "weekdays at 08:30"
expect described("* * * * * *") == "every second"
expect described("15 * * * *") == "hourly at :15"
expect described("0 0 1 * *") == "monthly, on day 1, at 00:00"
expect described("0 3 * 1 *") == ""

# The link back to the app, first in the sidebar, when the app gives one.
expect sidebar("/admin/jobs", { label: "Status", href: "/admin" }, [], [], "", "").contains("<nav class=\"side-nav\" aria-label=\"Jobs\"><a class=\"back\" href=\"/admin\">")
expect !sidebar("/admin/jobs", { label: "", href: "" }, [], [], "", "").contains("class=\"back\"")
