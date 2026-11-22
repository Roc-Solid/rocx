import email.Email
import pf.Env
import pf.Html
import Days
import Store
import Ui/AlertMail

## The emails subscribers get when an incident opens or closes. Each is a job of its own
## (`Jobs.alert`, one a subscriber, keyed so it is queued once), so a mail server that doesn't
## answer is tried again, and one subscriber's bad address holds up nobody else. Without
## `--smtp-url` they go to the dev mailbox (`/__rocx/mail`).
Alerts := [].{

	## What happened to an incident: it opened, or it closed.
	Kind : [Opened, Closed]

	## A kind as a job's input and a key say it.
	kind_name : Alerts.Kind -> Str
	kind_name = |kind|
		match kind {
			Opened => "opened"
			Closed => "closed"
		}

	## Mails `subscriber` that `incident` opened or closed (`kind`, as `kind_name` says it). Nothing,
	## if they unsubscribed since. An `Err` has the job tried again.
	send! : { incident : I64, kind : Str, subscriber : I64 } => Try({}, Str)
	send! = |{ incident, kind, subscriber }|
		match (Store.incident!(incident), Store.subscriber!(subscriber)) {
			(Ok(found), Ok(who)) => {
				origin = Env.public_url!({})
				said = found.updates.first().map_ok(|update| update.body) ?? found.incident.title
				message = Alerts.mail({ kind: if (kind == "closed") Closed else Opened, incident: found.incident, said, origin, to: who.email, token: who.token })
				Email.send!(message).map_err(|EmailErr(why)| why)
			}
			(_, Err(NotFound)) => Ok({})
			(Err(NotFound), _) => Ok({})
			(Err(DbErr(why)), _) | (_, Err(DbErr(why))) => Err(why)
			(Err(BadRow(why)), _) | (_, Err(BadRow(why))) => Err(why)
		}

	## The email: its subject, its text and the same as HTML (`Ui/AlertMail`).
	mail : { kind : Alerts.Kind, incident : Store.IncidentRow, said : Str, origin : Str, to : Str, token : Str } -> Email.Message
	mail = |{ kind, incident, said, origin, to, token }| {
		follow = "${origin}/incidents/${incident.id.to_str()}"
		unsubscribe = "${origin}/unsubscribe?token=${token}"
		(subject, heading, when) =
			match kind {
				Opened => ("[Status] ${incident.monitor_name} is down", "${incident.monitor_name} is down", "Opened ${Days.moment(incident.opened_at)}.")
				Closed => ("[Status] Resolved: ${incident.monitor_name} is back", "${incident.monitor_name} is back", "Down for ${Days.minutes(U64.max(incident.minutes, 1))}, from ${Days.moment(incident.opened_at)}.")
			}
		text = "${heading}.\n\n${said}\n${when}\n\nFollow it on the status page: ${follow}\n\nYou get these emails because you subscribed to this status page. Unsubscribe: ${unsubscribe}\n"
		html = Html.to_str(AlertMail.view({ heading, said, when, follow, unsubscribe, resolved: kind == Closed }))
		{ to, subject, text, html }
	}
}

incident_row : Store.IncidentRow
incident_row = { id: 7, monitor: 2, monitor_name: "Payments API", title: "Payments API is down", opened_at: "2026-11-22T14:05:00Z", closed_at: Null, minutes: 23 }

expect {
	mail = Alerts.mail({ kind: Opened, incident: incident_row, said: "Payments API failed 3 checks in a row (expected 200, got 503).", origin: "https://status.example.com", to: "ada@example.com", token: "abc" })
	mail.subject == "[Status] Payments API is down" and mail.text.contains("https://status.example.com/incidents/7") and mail.text.contains("unsubscribe?token=abc") and mail.html.contains("Payments API failed 3 checks in a row") and mail.html.contains("<h1 style=\"font-size: 22px; color: #b42318\">")
}

expect {
	mail = Alerts.mail({ kind: Closed, incident: incident_row, said: "Back.", origin: "https://status.example.com", to: "ada@example.com", token: "abc" })
	mail.subject == "[Status] Resolved: Payments API is back" and mail.text.contains("Down for 23 minutes, from Nov 22, 14:05 UTC.") and mail.html.contains("color: #11734b")
}
