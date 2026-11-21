## What a notification shows, as this package's service worker (`static/push-sw.js`) reads it from
## a push message's data: a title, a body, the page a click opens (`url`, on this site), a `tag`
## (a newer notification with the same tag replaces an older one, rather than piling up) and an
## `icon`'s URL. Empty fields are left out of the JSON, and the service worker does without them.
##
## ```roc
## Notification.new("Your export is ready", "orders-2026-11.csv, 3 MB")
## { ..Notification.new("New reply", "Ada answered your question"), url: "/questions/42", tag: "question-42" }
## ```
Notification := { title : Str, body : Str, url : Str, tag : Str, icon : Str }.{

	## A title and a body, opening the site's front page when clicked.
	new : Str, Str -> Notification
	new = |title, body| { title, body, url: "", tag: "", icon: "" }

	## The JSON the service worker reads.
	to_json : Notification -> Str
	to_json = |notification| {
		fields = [("title", notification.title), ("body", notification.body), ("url", notification.url), ("tag", notification.tag), ("icon", notification.icon)]
		"{${Str.join_with(fields.keep_if(|(_, value)| !value.is_empty()).map(|(name, value)| "\"${name}\":${Json.to_str(value)}"), ",")}}"
	}

	## The JSON's bytes: a message's data.
	data : Notification -> List(U8)
	data = |notification| Notification.to_json(notification).to_utf8()
}

expect Notification.new("Hi", "there").to_json() == "{\"title\":\"Hi\",\"body\":\"there\"}"
expect { ..Notification.new("New reply", "Ada \"answered\""), url: "/questions/42", tag: "q42", icon: "/icon.png" }.to_json() == "{\"title\":\"New reply\",\"body\":\"Ada \\\"answered\\\"\",\"url\":\"/questions/42\",\"tag\":\"q42\",\"icon\":\"/icon.png\"}"
expect Notification.new("", "").to_json() == "{}"
expect Notification.new("é", "").data() == "{\"title\":\"é\"}".to_utf8()
