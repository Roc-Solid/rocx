import AdminHtml
import Db
import Host
import Live
import Server
import Setting

## The dev mailbox: email `Email.send!` keeps instead of sending (no `--smtp-url`), shown at
## `/__rocx/mail` under `--dev`: the messages, newest first; each one's headers, its text, its HTML
## (in a sandboxed frame: no script runs, links open elsewhere) and the message as SMTP would have
## carried it. It updates as mail comes (a stream of events). With a database the messages are kept
## in Postgres (`rocx_outbox`, the last 500, for a week), so a restart keeps them; without one, in
## the server's memory (the last 100).
##
## The platform answers its paths before the app sees them (`main.roc`): with `--dev`,
## `GET /__rocx/mail` (JSON if asked for with `accept: application/json`), `GET /__rocx/mail/<id>`,
## `POST /__rocx/mail/clear`, and `GET /__rocx/mail.json`; with only `--debug` (the tests), the JSON
## at `/__rocx/mail` and `/__rocx/mail.json`. Without either, the app answers them.
Outbox := [].{

	## A message as it is kept: when, from and to whom, its subject, text, HTML ("" for none), and
	## the message whole, as SMTP's DATA would carry it.
	Message : { at : I64, from : Str, to : Str, subject : Str, text : Str, html : Str, raw : Str }

	keep! : Message => Try({}, Str)
	keep! = |message| {
		kept =
			if Setting.database!({}) {
				done = Db.run!(
					"with kept as (insert into rocx_outbox (sent_at, from_address, to_address, subject, text, html, raw) values (to_timestamp($1::bigint / 1000.0), $2, $3, $4, $5, $6, $7) returning id) delete from rocx_outbox where sent_at < now() - interval '7 days' or id <= (select id - 500 from kept)",
					[Text(message.at.to_str()), Text(message.from), Text(message.to), Text(message.subject), Text(message.text), Text(message.html), Text(message.raw)],
				)
				match done {
					Ok(_) => Ok({})
					Err(DbErr(why)) => Err("couldn't keep it in the outbox: ${why}")
				}
			} else {
				Host.outbox_keep!(Json.to_str(message))
				Ok({})
			}
		if (kept.is_ok()) Live.publish!("rocx:mail", message.subject) else {}
		kept
	}

	## Whether the platform answers `target` (a path and its query), not the app.
	serves! : Str => Bool
	serves! = |target| {
		path = path_of(target)
		if path == "/__rocx/mail" or path == "/__rocx/mail.json" {
			dev!({}) or !Setting.text!("debug").is_empty()
		} else if path.starts_with("/__rocx/mail/") {
			dev!({})
		} else {
			Bool.False
		}
	}

	respond! : Server.Request => Server.Response
	respond! = |request| {
		wants_json = (Server.header(request, "accept") ?? "").contains("application/json")
		# HEAD as GET: the host sends the headers alone.
		method = if (request.method == "HEAD") "GET" else request.method
		match (method, request.path) {
			("GET", "/__rocx/mail.json") => json!({})
			("GET", "/__rocx/mail") =>
				if !dev!({}) or wants_json {
					json!({})
				} else if AdminHtml.asks(request.query, "events") {
					AdminHtml.changes(["rocx:mail"], "")
				} else {
					listed!({})
				}
			("POST", "/__rocx/mail/clear") =>
				if Server.same_origin(request) {
					clear!({})
					Server.redirect("/__rocx/mail")
				} else {
					Server.refused(403, "The mailbox is cleared from its own page.")
				}
			("GET", path) =>
				match I64.from_str(path.drop_prefix("/__rocx/mail/")) {
					Ok(id) => one!(id)
					Err(_) => Server.refused(404, "No page at ${path}.")
				}
			_ => Server.refused(405, "The mailbox answers GET, and POST /__rocx/mail/clear.")
		}
	}
}

## A message kept, with its id.
Kept : { id : I64, at : I64, from : Str, to : Str, subject : Str, text : Str, html : Str, raw : Str }

dev! : {} => Bool
dev! = |{}| !Setting.text!("dev").is_empty()

path_of : Str -> Str
path_of = |target|
	match target.split_first("?") {
		Ok({ before, .. }) => before
		Err(_) => target
	}

## Every message kept, oldest first.
all! : {} => Try(List(Kept), Str)
all! = |{}|
	if Setting.database!({}) {
		found : Try(List(Kept), [DbErr(Str), BadRow(Str)])
		found = Db.all!("select id, (extract(epoch from sent_at) * 1000)::int8 as \"at!\", from_address as \"from\", to_address as \"to\", subject, text, html, raw from rocx_outbox order by id", [])
		match found {
			Ok(messages) => Ok(messages)
			Err(DbErr(why)) => Err(why)
			Err(BadRow(why)) => Err(why)
		}
	} else {
		match Json.parse(Host.outbox_list!({})) {
			Ok(messages) => Ok(messages)
			Err(InvalidJson(why)) => Err(why)
		}
	}

clear! : {} => {}
clear! = |{}|
	if Setting.database!({}) {
		_ = Db.run!("delete from rocx_outbox", [])
		{}
	} else {
		Host.outbox_clear!({})
	}

json! : {} => Server.Response
json! = |{}|
	match all!({}) {
		Ok(messages) => Server.response(200, [{ name: "content-type", value: "application/json" }], Json.to_str(messages))
		Err(why) => Server.refused(500, why)
	}

listed! : {} => Server.Response
listed! = |{}|
	match all!({}) {
		Err(why) => AdminHtml.page(500, { title: "Mailbox", events: "", body: "<h1>Mailbox</h1><p class=\"problem\">${AdminHtml.escape(why)}</p>" })
		Ok(messages) => {
			now = Host.now_millis!({}).to_i64_wrap()
			rows = messages.fold([], |newest_first, each| newest_first.prepend(each)).map(
				|each| {
					link = "/__rocx/mail/${each.id.to_str()}"
					subject = if (each.subject.is_empty()) "(no subject)" else each.subject
					"<tr><td>${AdminHtml.relative(each.at, now)}</td><td>${AdminHtml.escape(each.from)}</td><td>${AdminHtml.escape(each.to)}</td><td><a href=\"${link}\">${AdminHtml.escape(subject)}</a></td></tr>"
				},
			)
			kept = if (Setting.database!({})) "in Postgres (the last 500, for a week)" else "in the server's memory (the last 100, until it stops)"
			table =
				if rows.is_empty() {
					"<p class=\"muted\">No mail yet.</p>"
				} else {
					"<table><thead><tr><th>When</th><th>From</th><th>To</th><th>Subject</th></tr></thead><tbody>${Str.join_with(rows, "")}</tbody></table>"
				}
			clear = if (rows.is_empty()) "" else AdminHtml.button("/__rocx/mail/clear", [], "Clear")
			body = Str.join_with(
				[
					"<div class=\"bar\"><h1>Mailbox</h1><span>${clear} <a href=\"/__rocx/mail\">Refresh</a></span></div>",
					"<p class=\"muted\">Email the server kept rather than sent (it has no <code>--smtp-url</code>), ${kept}.</p>",
					table,
				],
				"",
			)
			AdminHtml.page(200, { title: "Mailbox", events: "/__rocx/mail?events", body })
		}
	}

one! : I64 => Server.Response
one! = |id|
	match all!({}) {
		Err(why) => AdminHtml.page(500, { title: "Mailbox", events: "", body: "<p class=\"problem\">${AdminHtml.escape(why)}</p>" })
		Ok(messages) =>
			match messages.find_first(|each| each.id == id) {
				Err(_) => AdminHtml.page(404, { title: "Mailbox", events: "", body: "<p><a href=\"/__rocx/mail\">Mailbox</a></p><h1>No message #${id.to_str()}</h1>" })
				Ok(message) => {
					subject = if (message.subject.is_empty()) "(no subject)" else message.subject
					html =
						if message.html.is_empty() {
							""
						} else {
							# A frame of its own, sandboxed: no script runs in it, and a link opens elsewhere.
							"<h2>HTML</h2><iframe sandbox=\"allow-popups allow-popups-to-escape-sandbox\" referrerpolicy=\"no-referrer\" srcdoc=\"${AdminHtml.escape("<base target=\"_blank\">${message.html}")}\"></iframe>"
						}
					body = Str.join_with(
						[
							"<p><a href=\"/__rocx/mail\">Mailbox</a></p>",
							"<h1>${AdminHtml.escape(subject)}</h1>",
							"<dl><dt>From</dt><dd>${AdminHtml.escape(message.from)}</dd><dt>To</dt><dd>${AdminHtml.escape(message.to)}</dd><dt>Subject</dt><dd>${AdminHtml.escape(message.subject)}</dd><dt>Date</dt><dd>${AdminHtml.moment(message.at)}</dd></dl>",
							html,
							"<h2>Text</h2><pre>${AdminHtml.escape(message.text)}</pre>",
							"<details><summary>The message as SMTP would carry it</summary><pre>${AdminHtml.escape(message.raw)}</pre></details>",
						],
						"",
					)
					AdminHtml.page(200, { title: subject, events: "", body })
				}
			}
	}

expect path_of("/__rocx/mail?events") == "/__rocx/mail"
