import pf.Env
import pf.Kv
import pf.Live
import pf.Plugin
import pf.Server
import pf.Time
import admin.AdminHtml
import admin.Look

## The dev mailbox: email `Email.send!` keeps instead of sending (no SMTP server), shown at
## `/__rocx/mail` under `--dev`: the messages, newest first; each one's headers, its text, its HTML
## (in a sandboxed frame: no script runs, links open elsewhere) and the message as SMTP would have
## carried it. It updates as mail comes (a stream of events). The last 100 are kept in the server's
## memory (`Kv`, under `email:mailbox`), database or not: a restart forgets them (D-028).
##
## The email plugin's early paths, answered before the app sees them: with `--dev`,
## `GET /__rocx/mail` (JSON if asked for with `accept: application/json`), `GET /__rocx/mail/<id>`,
## `POST /__rocx/mail/clear`, and `GET /__rocx/mail.json`; with only `--debug` (the tests), the JSON
## at `/__rocx/mail` and `/__rocx/mail.json`. Without either, the app answers them.
Mailbox := [].{

	## A message as it is kept: when, from and to whom, its subject, text, HTML ("" for none), and
	## the message whole, as SMTP's DATA would carry it.
	Message : { at : I64, from : Str, to : Str, subject : Str, text : Str, html : Str, raw : Str }

	keep! : Message => {}
	keep! = |message| {
		# Ids keep counting after a clear, so a page open on an old one never shows another.
		id = Kv.increment!("email:mailbox:id", 1, {}) ?? 0
		kept : Kept
		kept = { id, at: message.at, from: message.from, to: message.to, subject: message.subject, text: message.text, html: message.html, raw: message.raw }
		Kv.push!("email:mailbox", kept, { keep: 100 })
		Live.publish!("email:mailbox", message.subject)
	}

	## Its paths, as the email plugin's early ones: the list, its JSON and one message under `--dev`
	## (the JSON under `--debug` too), clearing it under `--dev`.
	early : List(Plugin.Early)
	early = [
		{ method: "GET", path: "/__rocx/mail", under: [Dev, Debug], answer!: |request| Mailbox.respond!(request) },
		{ method: "GET", path: "/__rocx/mail.json", under: [Dev, Debug], answer!: |request| Mailbox.respond!(request) },
		{ method: "GET", path: "/__rocx/mail/[id]", under: [Dev], answer!: |request| Mailbox.respond!(request) },
		{ method: "POST", path: "/__rocx/mail/clear", under: [Dev], answer!: |request| Mailbox.respond!(request) },
	]

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
					AdminHtml.changes(["email:mailbox"], "")
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
dev! = |{}| Env.dev!({})

## Every message kept, oldest first.
all! : {} => Try(List(Kept), Str)
all! = |{}| {
	listed : Try(List(Kept), [BadValue(Str)])
	listed = Kv.list!("email:mailbox")
	match listed {
		Ok(newest_first) => Ok(newest_first.fold([], |oldest_first, each| oldest_first.prepend(each)))
		Err(BadValue(why)) => Err(why)
	}
}

clear! : {} => {}
clear! = |{}| Kv.delete!("email:mailbox")

json! : {} => Server.Response
json! = |{}|
	match all!({}) {
		Ok(messages) => Server.response(200, [{ name: "content-type", value: "application/json" }], Json.to_str(messages))
		Err(why) => Server.refused(500, why)
	}

## The mailbox's sidebar: its one list, and how many messages it has.
mail_side : U64, Bool -> Str
mail_side = |count, on| {
	inbox = Look.nav_link({ href: "/__rocx/mail", icon: "mail", tone: "accent", label: "Inbox", count: count.to_str(), on })
	Look.side({ name: "Mailbox", note: "Mail kept, not sent", home: "/__rocx/mail", nav: inbox, foot: "Under --dev, with no SMTP_URL, the server keeps each email here instead of sending it." })
}

listed! : {} => Server.Response
listed! = |{}| {
	now = Time.now_millis!({}).to_i64_wrap()
	match all!({}) {
		Err(why) => AdminHtml.page(500, { title: "Mailbox", events: "", now, side: mail_side(0, Bool.True), body: "${Look.header({ eyebrow: "Dev mailbox", title: "Mailbox", actions: "" })}<section class=\"panel\"><p class=\"problem\">${Look.escape(why)}</p></section>" })
		Ok(messages) => {
			rows = messages.fold([], |newest_first, each| newest_first.prepend(each)).map(
				|each| {
					link = "/__rocx/mail/${each.id.to_str()}"
					subject = if (each.subject.is_empty()) "(no subject)" else each.subject
					"<tr><td class=\"when\">${AdminHtml.relative(each.at, now)}</td><td>${Look.escape(each.from)}</td><td>${Look.escape(each.to)}</td><td class=\"last\"><a class=\"row-link\" href=\"${link}\"><strong>${Look.escape(subject)}</strong></a></td></tr>"
				},
			)
			kept = "in the server's memory (the last 100, until it stops)"
			table =
				if rows.is_empty() {
					Look.empty("mail", "No mail yet", "Email the app sends shows here as it is sent.")
				} else {
					"<div class=\"table-wrap\"><table class=\"mail\"><thead><tr><th>When</th><th>From</th><th>To</th><th>Subject</th></tr></thead><tbody>${Str.join_with(rows, "")}</tbody></table></div>"
				}
			clear = if (rows.is_empty()) "" else Look.button_with("act-danger", "stop", "/__rocx/mail/clear", [], "Clear")
			body = Str.join_with(
				[
					Look.header({ eyebrow: "Dev mailbox", title: "Mailbox", actions: "${clear}${AdminHtml.live(now, "/__rocx/mail")}" }),
					Look.panel({ eyebrow: "Newest first", title: "Inbox", aside: "<span>${rows.len().to_str()} kept</span>", body: "<div class=\"callout tone-accent\">${Look.icon("mail")}<div><span>Email the server kept rather than sent (it has no <code>SMTP_URL</code>), ${kept}.</span></div></div>${table}", class: "" }),
				],
				"",
			)
			AdminHtml.page(200, { title: "Mailbox", events: "/__rocx/mail?events", now, side: mail_side(rows.len(), Bool.True), body })
		}
	}
}

one! : I64 => Server.Response
one! = |id| {
	now = Time.now_millis!({}).to_i64_wrap()
	back = "<a class=\"btn\" href=\"/__rocx/mail\">${Look.icon("back")}Mailbox</a>"
	match all!({}) {
		Err(why) => AdminHtml.page(500, { title: "Mailbox", events: "", now, side: mail_side(0, Bool.False), body: "${Look.header({ eyebrow: "Dev mailbox", title: "Mailbox", actions: back })}<section class=\"panel\"><p class=\"problem\">${Look.escape(why)}</p></section>" })
		Ok(messages) =>
			match messages.find_first(|each| each.id == id) {
				Err(_) => AdminHtml.page(404, { title: "Mailbox", events: "", now, side: mail_side(messages.len(), Bool.False), body: "${Look.header({ eyebrow: "Dev mailbox", title: "No message #${id.to_str()}", actions: back })}<section class=\"panel\">${Look.empty("mail", "No message #${id.to_str()}", "It may have been cleared, or kept more than a week ago.")}</section>" })
				Ok(message) => {
					subject = if (message.subject.is_empty()) "(no subject)" else message.subject
					html =
						if message.html.is_empty() {
							""
						} else {
							# A frame of its own, sandboxed: no script runs in it, and a link opens elsewhere.
							"<section class=\"panel\"><h2>HTML</h2><iframe sandbox=\"allow-popups allow-popups-to-escape-sandbox\" referrerpolicy=\"no-referrer\" srcdoc=\"${Look.escape("<base target=\"_blank\">${message.html}")}\"></iframe></section>"
						}
					body = Str.join_with(
						[
							Look.header({ eyebrow: "Message #${id.to_str()}", title: Look.escape(subject), actions: back }),
							"<section class=\"panel\"><dl class=\"plain\"><dt>From</dt><dd>${Look.escape(message.from)}</dd><dt>To</dt><dd>${Look.escape(message.to)}</dd><dt>Subject</dt><dd>${Look.escape(message.subject)}</dd><dt>Date</dt><dd>${AdminHtml.moment(message.at)} <span class=\"muted\">(${AdminHtml.relative(message.at, now)})</span></dd></dl></section>",
							html,
							"<section class=\"panel\"><h2>Text</h2><pre>${Look.escape(message.text)}</pre></section>",
							"<section class=\"panel\"><details><summary>The message as SMTP would carry it</summary><pre>${Look.escape(message.raw)}</pre></details></section>",
						],
						"",
					)
					AdminHtml.page(200, { title: subject, events: "", now, side: mail_side(messages.len(), Bool.False), body })
				}
			}
	}
}
