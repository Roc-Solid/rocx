import Calendar
import Events
import Host
import Live
import Server

## What the platform's own pages (the jobs page, the dev mailbox) are drawn with: whole HTML
## documents, plain forms, a small stylesheet under one class (`rocx-admin`), and a few lines of
## script that refresh the page's main part when its stream of events says something changed. With
## no script, the page is the same, and has a link that refreshes it.
AdminHtml := [].{

	## Text as HTML has it, in an element or an attribute's quotes.
	escape : Str -> Str
	escape = |text| text.replace_each("&", "&amp;").replace_each("<", "&lt;").replace_each(">", "&gt;").replace_each("\"", "&quot;").replace_each("'", "&#39;")

	## A page: its title, the URL of its stream of changes ("" for none), and its main part.
	page : U16, { title : Str, events : Str, body : Str } -> Server.Response
	page = |status, { title, events, body }| {
		live = if (events.is_empty()) "" else " data-events=\"${escape(events)}\""
		script = if (events.is_empty()) "" else "<script>${refresh_script}</script>"
		document = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>${escape(title)}</title><style>${stylesheet}</style></head><body class=\"rocx-admin\"><main${live}>${body}</main>${script}</body></html>"
		Server.response(
			status,
			[
				{ name: "content-type", value: "text/html; charset=utf-8" },
				{ name: "cache-control", value: "no-store" },
				{ name: "x-frame-options", value: "DENY" },
			],
			document,
		)
	}

	## A page that says why an action couldn't be done, with a way back.
	problem : U16, Str, Str -> Server.Response
	problem = |status, why, back| AdminHtml.page(status, { title: "Not done", events: "", body: "<p class=\"problem\">${escape(why)}</p><p><a href=\"${escape(back)}\">Back</a></p>" })

	## A stream of events that says `changed` (at most once a second) when something is said on
	## one of `topics`, or Postgres notifies `channel` ("" for none); and `quiet` every 15 s
	## otherwise. A page's script refreshes on each.
	changes : List(Str), Str -> Server.Response
	changes = |topics, channel|
		Server.events(
			Events.stream(
				|{ send!, sleep! }| {
					for topic in topics {
						Live.listen!(topic)
					}
					if channel.is_empty() {
						{}
					} else {
						_ = Host.db_listen!(channel)
						{}
					}
					var $open = Bool.True
					while $open {
						match Live.next!(15_000) {
							Heard(_) => {
								# What else comes within half a second is the same change.
								sleep!(500)
								var $draining = 0
								while $draining < 1000 {
									$draining =
										match Live.next!(1) {
											Heard(_) => $draining + 1
											_ => 1000
										}
								}
								send!("changed")?
							}
							Quiet => send!("quiet")?
							Gone => {
								$open = Bool.False
							}
						}
					}
					Ok({})
				},
			),
		)

	## A form that posts `fields` (hidden) to `action`, as a button saying `label`.
	button : Str, List((Str, Str)), Str -> Str
	button = |action, fields, label| {
		hidden = fields.map(|(name, value)| "<input type=\"hidden\" name=\"${escape(name)}\" value=\"${escape(value)}\">")
		"<form method=\"post\" action=\"${escape(action)}\">${Str.join_with(hidden, "")}<button>${escape(label)}</button></form>"
	}

	## `path`, with the non-empty ones of `params` as its query.
	link : Str, List((Str, Str)) -> Str
	link = |path, params| {
		given = params.keep_if(|(_, value)| !value.is_empty()).map(|(name, value)| "${Server.encode_segment(name)}=${Server.encode_segment(value)}")
		if (given.is_empty()) path else "${path}?${Str.join_with(given, "&")}"
	}

	## The value of `name` in a query or a posted form (`a=1&b=two+words`), decoded; "" if it has none.
	param : Str, Str -> Str
	param = |encoded, name| {
		found = encoded.split_on("&").keep_oks(
			|pair|
				match pair.split_first("=") {
					Ok({ before, after }) => if (decoded(before) == name) Ok(decoded(after)) else Err(Elsewhere)
					Err(_) => Err(Elsewhere)
				},
		)
		found.first() ?? ""
	}

	## Whether a query or a form has `name`, with a value or without (`?events`).
	asks : Str, Str -> Bool
	asks = |encoded, name| encoded.split_on("&").any(|pair| pair == name or pair.starts_with("${name}="))

	## A moment (milliseconds since the epoch) as `2026-11-21 14:05:03 UTC`.
	moment : I64 -> Str
	moment = |ms| {
		seconds = ms // 1000
		of_day = seconds % 86400
		date = Calendar.civil(seconds // 86400)
		"${date.year.to_str()}-${two(date.month)}-${two(date.day)} ${two(of_day // 3600)}:${two(of_day % 3600 // 60)}:${two(of_day % 60)} UTC"
	}

	## A span of milliseconds, roughly: `300 ms`, `5 s`, `3 min`, `2 h`, `4 d`.
	span : I64 -> Str
	span = |ms| {
		size = I64.abs(ms)
		if size < 1000 {
			"${size.to_str()} ms"
		} else if size < 60_000 {
			"${(size // 1000).to_str()} s"
		} else if size < 3_600_000 {
			"${(size // 60_000).to_str()} min"
		} else if size < 86_400_000 {
			"${(size // 3_600_000).to_str()} h"
		} else {
			"${(size // 86_400_000).to_str()} d"
		}
	}

	## A query sent back in a form (where to go back to), kept to the characters a query is written
	## with: nothing that could end a header.
	safe_query : Str -> Str
	safe_query = |query| Str.from_utf8_lossy(query.to_utf8().keep_if(|byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '=' or byte == '&' or byte == '%' or byte == '.' or byte == '_' or byte == '-' or byte == '~' or byte == '+'))

	## A text's first line, 140 bytes at most (an error, in a table).
	shortened : Str -> Str
	shortened = |text| {
		line = (text.split_on("\n").first()) ?? text
		bytes = line.to_utf8()
		if (bytes.len() <= 140 and line == text) line else "${Str.from_utf8_lossy(bytes.take_first(140))}…"
	}

	## A word with its first letter a capital (ASCII).
	capitalized : Str -> Str
	capitalized = |word| {
		bytes = word.to_utf8()
		match bytes.first() {
			Ok(first) if first >= 'a' and first <= 'z' => Str.from_utf8_lossy(bytes.drop_first(1).prepend(first - 32))
			_ => word
		}
	}

	## A moment as it stands from `now`: `in 5 s`, `3 min ago`, in an element whose title says when.
	relative : I64, I64 -> Str
	relative = |at, now| {
		said = if (at - now > 500) "in ${AdminHtml.span(at - now)}" else if (now - at > 500) "${AdminHtml.span(now - at)} ago" else "now"
		"<time datetime=\"${at.to_str()}\" title=\"${AdminHtml.moment(at)}\">${said}</time>"
	}
}

decoded : Str -> Str
decoded = |text| Server.decode_segment(text.replace_each("+", " "))

two : I64 -> Str
two = |n| if (n < 10) "0${n.to_str()}" else n.to_str()

## Refreshes the page's main part (`main[data-events]`) from the page itself each time its stream
## of events says something, keeping where the reader is.
refresh_script : Str
refresh_script = "(()=>{const main=document.querySelector(\"main[data-events]\");if(!main||!window.EventSource)return;let busy=false,again=false;const refresh=async()=>{if(busy){again=true;return}busy=true;try{const answer=await fetch(location.href,{headers:{accept:\"text/html\"}});if(answer.ok){const fresh=new DOMParser().parseFromString(await answer.text(),\"text/html\").querySelector(\"main[data-events]\");const now=document.querySelector(\"main[data-events]\");if(fresh&&now)now.replaceWith(fresh)}}catch{}finally{busy=false;if(again){again=false;refresh()}}};new EventSource(main.dataset.events).onmessage=refresh})()"

stylesheet : Str
stylesheet =
	Str.join_with(
		[
			".rocx-admin{margin:0;font:14px/1.45 system-ui,-apple-system,sans-serif;color:#1f2328;background:#f6f8fa}",
			".rocx-admin main{max-width:72rem;margin:0 auto;padding:1.5rem}",
			".rocx-admin h1{font-size:1.4rem;margin:0 0 .75rem}.rocx-admin h2{font-size:1.05rem;margin:1.5rem 0 .5rem}",
			".rocx-admin a{color:#0969da;text-decoration:none}.rocx-admin a:hover{text-decoration:underline}",
			".rocx-admin nav{display:flex;flex-wrap:wrap;gap:.35rem;align-items:center;margin-bottom:1rem}",
			".rocx-admin nav a{padding:.2rem .6rem;border:1px solid #d0d7de;border-radius:2rem;background:#fff}",
			".rocx-admin nav a.on{background:#1f2328;color:#fff;border-color:#1f2328}",
			".rocx-admin table{width:100%;border-collapse:collapse;background:#fff;border:1px solid #d0d7de;border-radius:6px}",
			".rocx-admin th,.rocx-admin td{text-align:left;padding:.4rem .6rem;border-bottom:1px solid #eaeef2;vertical-align:top}",
			".rocx-admin th{font-weight:600;color:#59636e;font-size:.8rem;text-transform:uppercase;letter-spacing:.03em}",
			".rocx-admin td.error{color:#cf222e;max-width:24rem;overflow-wrap:anywhere}",
			".rocx-admin td.actions{white-space:nowrap}.rocx-admin form{display:inline;margin:0 .15rem 0 0}",
			".rocx-admin button{font:inherit;font-size:.8rem;padding:.15rem .55rem;border:1px solid #d0d7de;border-radius:4px;background:#f6f8fa;cursor:pointer}",
			".rocx-admin button:hover{background:#eaeef2}",
			".rocx-admin .state{display:inline-block;padding:0 .5rem;border-radius:2rem;font-size:.8rem;background:#eaeef2}",
			".rocx-admin .state-running{background:#ddf4ff;color:#0969da}.rocx-admin .state-done{background:#dafbe1;color:#1a7f37}",
			".rocx-admin .state-failed{background:#ffebe9;color:#cf222e}.rocx-admin .state-canceled{background:#eaeef2;color:#59636e}",
			".rocx-admin .state-queued{background:#fff8c5;color:#9a6700}",
			".rocx-admin dl{display:grid;grid-template-columns:max-content 1fr;gap:.3rem 1rem;background:#fff;border:1px solid #d0d7de;border-radius:6px;padding:.75rem 1rem}",
			".rocx-admin dt{color:#59636e}.rocx-admin dd{margin:0}",
			".rocx-admin pre{background:#fff;border:1px solid #d0d7de;border-radius:6px;padding:.75rem;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere}",
			".rocx-admin .problem{color:#cf222e}.rocx-admin .muted{color:#59636e}",
			".rocx-admin iframe{width:100%;min-height:24rem;border:1px solid #d0d7de;border-radius:6px;background:#fff}",
			".rocx-admin .bar{display:flex;gap:1rem;align-items:baseline;justify-content:space-between}",
		],
		"",
	)

expect AdminHtml.param("state=failed&kind=a+b%26c", "kind") == "a b&c"
expect AdminHtml.param("state=failed", "kind") == ""
expect AdminHtml.asks("events", "events") and AdminHtml.asks("a=1&events=", "events") and !AdminHtml.asks("eventsx=1", "events")
expect AdminHtml.link("/jobs", [("state", "failed"), ("kind", ""), ("before", "12")]) == "/jobs?state=failed&before=12"
expect AdminHtml.moment(1795211647000) == "2026-11-20 21:54:07 UTC"
expect AdminHtml.span(-4000) == "4 s"
expect AdminHtml.escape("<a href=\"x\">'") == "&lt;a href=&quot;x&quot;&gt;&#39;"
expect AdminHtml.capitalized("failed") == "Failed"
expect AdminHtml.safe_query("state=failed&kind=a%20b\r\nx: y") == "state=failed&kind=a%20bxy"
expect AdminHtml.shortened("one\ntwo") == "one…"
expect AdminHtml.shortened("short") == "short"
