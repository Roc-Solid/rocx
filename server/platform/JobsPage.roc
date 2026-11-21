import AdminHtml
import Cron
import Job
import Registry
import Server
import Time

## The jobs page, drawn by the platform for the app to mount behind its own middleware (only the
## app knows who may see it): what is queued, running, done, failed and canceled, of each kind;
## each job's input, attempts, times and last error; the schedules and when each runs next. Retry,
## cancel and run now are plain forms, answered with a redirect back. It refreshes itself as jobs
## change (a stream of events), and works without script too.
##
## ```roc
## # routes/admin/jobs/+server.roc
## middleware = Middlewares.admin
## get! = |{ request, .. }| Err(Answer(JobsPage.respond!(request, { mount: "/admin/jobs" })))
## post! = |{ request, .. }| Err(Answer(JobsPage.respond!(request, { mount: "/admin/jobs" })))
## ```
##
## `mount` is the path it is at. It answers GET (`?state=failed`, `?kind=…`, `?before=<id>` for
## older ones, `?id=123` for one job, `?events` for its stream of changes) and POST (`action=retry|
## cancel|run_now` with `id=`, or `action=run_schedule` with `name=`). A POST from another site's
## page is refused (403), as `Middleware.same_origin` would.
JobsPage := [].{

	## Answers a request to the jobs page at `mount`: a GET draws it (or streams its changes), a
	## POST retries, cancels or runs a job, or runs a schedule, and redirects back; any other method
	## is a 405.
	respond! : Server.Request, { mount : Str } => Server.Response
	respond! = |request, { mount }|
		if request.method == "POST" {
			act!(request, mount)
		} else if request.method == "GET" or request.method == "HEAD" {
			if AdminHtml.asks(request.query, "events") {
				AdminHtml.changes(["rocx:jobs"], "rocx_jobs")
			} else {
				match I64.from_str(AdminHtml.param(request.query, "id")) {
					Ok(id) => one!(mount, id)
					Err(_) => listed!(mount, request.query)
				}
			}
		} else {
			Server.response(405, [{ name: "allow", value: "GET, HEAD, POST" }, { name: "content-type", value: "text/plain; charset=utf-8" }], "The jobs page answers GET and POST.")
		}
}

states : List(Str)
states = ["queued", "running", "failed", "done", "canceled"]

## How many there are in `state` (of `kind`, or of all if "").
count_of : List({ kind : Str, state : Str, count : U64 }), Str, Str -> U64
count_of = |counts, kind, state| counts.keep_if(|each| (kind.is_empty() or each.kind == kind) and (state.is_empty() or each.state == state)).fold(0, |sum, each| sum + each.count)

## The list: the states and kinds with their counts, the schedules, then the jobs the query picks.
listed! : Str, Str => Server.Response
listed! = |mount, query| {
	state = AdminHtml.param(query, "state")
	kind = AdminHtml.param(query, "kind")
	before = I64.from_str(AdminHtml.param(query, "before")) ?? 0
	now = Time.now_millis!({}).to_i64_wrap()
	read =
		match (Job.counts!({}), Job.list!({ state, kind, before_id: before, limit: 50 })) {
			(Ok(counts), Ok(rows)) => Ok((counts, rows))
			(Err(JobErr(why)), _) => Err(why)
			(_, Err(JobErr(why))) => Err(why)
		}
	match read {
		Err(why) => AdminHtml.page(500, { title: "Jobs", events: "", body: "<h1>Jobs</h1><p class=\"problem\">The queue can't be read: ${AdminHtml.escape(why)}</p>" })
		Ok((counts, rows)) => {
			nav_link = |label, wanted| {
				on = if (wanted == state) " class=\"on\"" else ""
				"<a${on} href=\"${AdminHtml.escape(AdminHtml.link(mount, [("state", wanted), ("kind", kind)]))}\">${label} ${count_of(counts, kind, wanted).to_str()}</a>"
			}
			nav = Str.join_with([nav_link("All", "")].concat(states.map(|each| nav_link(AdminHtml.capitalized(each), each))), "")
			refresh = "<a href=\"${AdminHtml.escape(AdminHtml.link(mount, [("state", state), ("kind", kind), ("before", if (before == 0) "" else before.to_str())]))}\">Refresh</a>"
			kind_note = if (kind.is_empty()) "" else " of <code>${AdminHtml.escape(kind)}</code> (<a href=\"${AdminHtml.escape(AdminHtml.link(mount, [("state", state)]))}\">every kind</a>)"
			heading = "<div class=\"bar\"><h1>${if (state.is_empty()) "Jobs" else "${AdminHtml.capitalized(state)} jobs"}${kind_note}</h1>${refresh}</div>"
			older =
				match rows.last() {
					Ok(last) if rows.len() == 50 => "<p><a href=\"${AdminHtml.escape(AdminHtml.link(mount, [("state", state), ("kind", kind), ("before", last.id.to_str())]))}\">Older</a></p>"
					_ => ""
				}
			table = if (rows.is_empty()) "<p class=\"muted\">None.</p>" else jobs_table(mount, query, rows, now)
			body = Str.join_with([heading, "<nav>${nav}</nav>", kinds_table!(mount, counts), schedules_table!(mount, query, now), "<h2>Jobs</h2>", table, older], "")
			AdminHtml.page(200, { title: "Jobs", events: AdminHtml.link(mount, [("events", "1")]), body })
		}
	}
}

## Each kind (the app's, and any other in the queue), its attempts and time limit, and how many of
## its jobs are in each state.
kinds_table! : Str, List({ kind : Str, state : Str, count : U64 }) => Str
kinds_table! = |mount, counts|
	if counts.is_empty() and Registry.kinds!({}).is_empty() {
		""
	} else {
		listed = Registry.kinds!({})
		others = counts.map(|each| each.kind).keep_if(|name| !listed.any(|kind| kind.name == name))
		unlisted = others.fold([], |seen, name| if (seen.contains(name)) seen else seen.append(name))
		row = |name, tries, limit| {
			cells = states.map(
				|state| {
					count = count_of(counts, name, state)
					if count == 0 {
						"<td class=\"muted\">0</td>"
					} else {
						"<td><a href=\"${AdminHtml.escape(AdminHtml.link(mount, [("state", state), ("kind", name)]))}\">${count.to_str()}</a></td>"
					}
				},
			)
			"<tr><td><a href=\"${AdminHtml.escape(AdminHtml.link(mount, [("kind", name)]))}\"><code>${AdminHtml.escape(name)}</code></a></td><td>${tries}</td><td>${limit}</td>${Str.join_with(cells, "")}</tr>"
		}
		rows = listed.map(|kind| row(kind.name, kind.attempts.to_str(), if (kind.timeout_ms == 0) "none" else AdminHtml.span(kind.timeout_ms.to_i64_wrap())))
			.concat(unlisted.map(|name| row(name, "<span class=\"muted\">another app's</span>", "")))
		heads = Str.join_with(states.map(|state| "<th>${state}</th>"), "")
		"<h2>Kinds</h2><table><thead><tr><th>Kind</th><th>Attempts</th><th>Time limit</th>${heads}</tr></thead><tbody>${Str.join_with(rows, "")}</tbody></table>"
	}

## The schedules, when each runs next, and a button that queues its job now.
schedules_table! : Str, Str, I64 => Str
schedules_table! = |mount, query, now| {
	schedules = Cron.schedules!({})
	if schedules.is_empty() {
		""
	} else {
		rows = schedules.map(
			|each| {
				next =
					match each.next_at {
						Some(at) => AdminHtml.relative(at, now)
						Null => "<span class=\"muted\">never</span>"
					}
				run = AdminHtml.button(mount, [("action", "run_schedule"), ("name", each.name), ("back", query)], "Run now")
				"<tr><td><code>${AdminHtml.escape(each.schedule)}</code></td><td><a href=\"${AdminHtml.escape(AdminHtml.link(mount, [("kind", each.job)]))}\"><code>${AdminHtml.escape(each.job)}</code></a></td><td>${next}</td><td class=\"actions\">${run}</td></tr>"
			},
		)
		"<h2>Schedules</h2><table><thead><tr><th>Schedule (UTC)</th><th>Job</th><th>Next</th><th></th></tr></thead><tbody>${Str.join_with(rows, "")}</tbody></table>"
	}
}

jobs_table : Str, Str, List(Job.Row), I64 -> Str
jobs_table = |mount, query, rows, now| {
	lines = rows.map(
		|row| {
			key =
				match row.key {
					Some(text) => "<code>${AdminHtml.escape(text)}</code>"
					Null => ""
				}
			error =
				match row.last_error {
					Some(why) => "<span title=\"${AdminHtml.escape(why)}\">${AdminHtml.escape(AdminHtml.shortened(why))}</span>"
					Null => ""
				}
			"<tr><td><a href=\"${AdminHtml.escape(AdminHtml.link(mount, [("id", row.id.to_str())]))}\">#${row.id.to_str()}</a></td><td><code>${AdminHtml.escape(row.kind)}</code></td><td>${badge(row.state)}</td><td>${row.attempts.to_str()} of ${row.max_attempts.to_str()}</td><td>${timing(row, now)}</td><td>${key}</td><td class=\"error\">${error}</td><td class=\"actions\">${actions(mount, query, row, now)}</td></tr>"
		},
	)
	"<table><thead><tr><th>Job</th><th>Kind</th><th>State</th><th>Tried</th><th>When</th><th>Key</th><th>Last error</th><th></th></tr></thead><tbody>${Str.join_with(lines, "")}</tbody></table>"
}

## One job: everything the queue knows about it.
one! : Str, I64 => Server.Response
one! = |mount, id|
	match Job.get!(id) {
		Err(NotFound) => AdminHtml.page(404, { title: "No job #${id.to_str()}", events: "", body: "<p><a href=\"${AdminHtml.escape(mount)}\">All jobs</a></p><h1>No job #${id.to_str()}</h1><p class=\"muted\">It may have been done more than a week ago.</p>" })
		Err(JobErr(why)) => AdminHtml.page(500, { title: "Jobs", events: "", body: "<h1>Job #${id.to_str()}</h1><p class=\"problem\">The queue can't be read: ${AdminHtml.escape(why)}</p>" })
		Ok(row) => {
			now = Time.now_millis!({}).to_i64_wrap()
			back = "id=${id.to_str()}"
			optional = |label, value|
				match value {
					Some(at) => "<dt>${label}</dt><dd>${AdminHtml.relative(at, now)} <span class=\"muted\">${AdminHtml.moment(at)}</span></dd>"
					Null => ""
				}
			limit =
				match Registry.kinds!({}).find_first(|kind| kind.name == row.kind) {
					Ok(kind) => if (kind.timeout_ms == 0) "none" else AdminHtml.span(kind.timeout_ms.to_i64_wrap())
					Err(_) => "<span class=\"muted\">not this app's kind</span>"
				}
			key =
				match row.key {
					Some(text) => "<dt>Key</dt><dd><code>${AdminHtml.escape(text)}</code></dd>"
					Null => ""
				}
			facts = Str.join_with(
				[
					"<dt>Kind</dt><dd><a href=\"${AdminHtml.escape(AdminHtml.link(mount, [("kind", row.kind)]))}\"><code>${AdminHtml.escape(row.kind)}</code></a></dd>",
					"<dt>State</dt><dd>${badge(row.state)} ${timing(row, now)}</dd>",
					"<dt>Tried</dt><dd>${row.attempts.to_str()} of ${row.max_attempts.to_str()} times</dd>",
					"<dt>Time limit</dt><dd>${limit}</dd>",
					key,
					"<dt>Queued</dt><dd>${AdminHtml.relative(row.created_at, now)} <span class=\"muted\">${AdminHtml.moment(row.created_at)}</span></dd>",
					"<dt>Due</dt><dd>${AdminHtml.relative(row.run_at, now)} <span class=\"muted\">${AdminHtml.moment(row.run_at)}</span></dd>",
					optional("Last tried", row.locked_at),
					optional("Finished", row.finished_at),
				],
				"",
			)
			error =
				match row.last_error {
					Some(why) => "<h2>Last error</h2><pre class=\"problem\">${AdminHtml.escape(why)}</pre>"
					Null => ""
				}
			buttons = actions(mount, back, row, now)
			body = Str.join_with(
				[
					"<p><a href=\"${AdminHtml.escape(mount)}\">All jobs</a></p>",
					"<div class=\"bar\"><h1>Job #${id.to_str()}</h1><span>${buttons} <a href=\"${AdminHtml.escape(AdminHtml.link(mount, [("id", id.to_str())]))}\">Refresh</a></span></div>",
					"<dl>${facts}</dl>",
					"<h2>Input</h2><pre>${AdminHtml.escape(row.input)}</pre>",
					error,
				],
				"",
			)
			AdminHtml.page(200, { title: "Job #${id.to_str()}", events: AdminHtml.link(mount, [("events", "1")]), body })
		}
	}

badge : Str -> Str
badge = |state| "<span class=\"state state-${AdminHtml.escape(state)}\">${AdminHtml.escape(state)}</span>"

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

## What may be done to a job in its state: retry one that failed or was canceled; run now or
## cancel one that is queued.
actions : Str, Str, Job.Row, I64 -> Str
actions = |mount, back, row, now| {
	act = |action, label| AdminHtml.button(mount, [("action", action), ("id", row.id.to_str()), ("back", back)], label)
	match row.state {
		"failed" | "canceled" => act("retry", "Retry")
		"queued" => "${if (row.run_at > now) act("run_now", "Run now") else ""}${act("cancel", "Cancel")}"
		_ => ""
	}
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
