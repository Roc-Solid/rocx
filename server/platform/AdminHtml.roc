import Calendar
import Events
import Host
import Live
import Server

## What the dev mailbox is drawn with (a copy of packages/admin's look, until email is a package):
## whole HTML documents in the shape of a console (a sidebar, a header, panels), plain forms, one
## stylesheet that follows the reader's light or dark scheme, and a few lines of script: they
## refresh the page when its stream of events says something changed, keep its times (`3 s ago`)
## current, say whether the page is live, and close a drawer on Escape. With no script, the page is
## the same, with a button that refreshes it.
AdminHtml := [].{

	## Text as HTML has it, in an element or an attribute's quotes.
	escape : Str -> Str
	escape = |text| text.replace_each("&", "&amp;").replace_each("<", "&lt;").replace_each(">", "&gt;").replace_each("\"", "&quot;").replace_each("'", "&#39;")

	## A page: its title, the URL of its stream of changes ("" for none), the server's time (`now`,
	## which the script counts the page's times on from; 0 for none), its sidebar (`AdminHtml.side`;
	## "" for none) and its main part. What the stream refreshes is the sidebar and the main part
	## together (`[data-events]`).
	page : U16, { title : Str, events : Str, now : I64, side : Str, body : Str } -> Server.Response
	page = |status, shown| {
		stream = if (shown.events.is_empty()) "" else " data-events=\"${escape(shown.events)}\""
		clock = if (shown.now == 0) "" else " data-now=\"${shown.now.to_str()}\""
		shell = if (shown.side.is_empty()) "shell bare" else "shell"
		document = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><meta name=\"color-scheme\" content=\"light dark\"><title>${escape(shown.title)}</title><style>${stylesheet}</style></head><body class=\"rocx-admin\"><div class=\"${shell}\"${stream}${clock}>${shown.side}<main>${shown.body}</main></div><script>${script}</script></body></html>"
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
	problem = |status, why, back|
		AdminHtml.page(
			status,
			{
				title: "Not done",
				events: "",
				now: 0,
				side: "",
				body: "${AdminHtml.header({ eyebrow: "Not done", title: "That couldn't be done", actions: "" })}<section class=\"panel\"><div class=\"callout tone-bad\">${AdminHtml.icon("alert")}<div><p class=\"problem\">${escape(why)}</p></div></div><div class=\"panel-foot\"><a class=\"btn\" href=\"${escape(back)}\">${AdminHtml.icon("back")}Back</a></div></section>",
			},
		)

	## The sidebar: a brand (`name`, a `note` under it, a link `home`), the navigation's links
	## (`AdminHtml.nav_link`, `AdminHtml.nav_label`) and a line at its foot.
	side : { name : Str, note : Str, home : Str, nav : Str, foot : Str } -> Str
	side = |{ name, note, home, nav, foot }|
		"<aside class=\"side\"><a class=\"brand\" href=\"${escape(home)}\"><span class=\"mark\" aria-hidden=\"true\"><span></span></span><span><strong>${escape(name)}</strong><small>${escape(note)}</small></span></a><nav class=\"side-nav\" aria-label=\"${escape(name)}\">${nav}</nav><p class=\"side-foot\">${foot}</p></aside>"

	## A link in the sidebar: where it goes, its icon (`AdminHtml.icon`'s name, or "" for a dot of
	## `tone`), its label (HTML), a count ("" for none), and whether it is the page shown.
	nav_link : { href : Str, icon : Str, tone : Str, label : Str, count : Str, on : Bool } -> Str
	nav_link = |item| {
		current = if (item.on) " aria-current=\"page\"" else ""
		mark = if (item.icon.is_empty()) "<i class=\"dot tone-${item.tone}\"></i>" else AdminHtml.icon(item.icon)
		number = if (item.count.is_empty()) "" else "<span class=\"count tone-${item.tone}\">${item.count}</span>"
		"<a href=\"${escape(item.href)}\"${current}>${mark}<span class=\"label\">${item.label}</span>${number}</a>"
	}

	## A heading between the sidebar's links.
	nav_label : Str -> Str
	nav_label = |text| "<p class=\"nav-label\">${escape(text)}</p>"

	## The top of the main part: a line over the title (`eyebrow`), the title (HTML), and what goes
	## on its right (`actions`, HTML).
	header : { eyebrow : Str, title : Str, actions : Str } -> Str
	header = |{ eyebrow, title, actions }| "<header class=\"top\"><div class=\"top-title\"><p class=\"eyebrow\">${eyebrow}</p><h1>${title}</h1></div><div class=\"top-actions\">${actions}</div></header>"

	## What the header's right side says of a live page: when it was drawn (counted on by the
	## script), whether its stream is open, and a button that refreshes it (`refresh`, its URL).
	live : I64, Str -> Str
	live = |now, refresh| "<span class=\"stamp\">Updated ${AdminHtml.relative(now, now)}</span><span class=\"live\" role=\"status\"><i></i><span class=\"live-on\">Live</span><span class=\"live-off\">Reconnecting</span></span><a class=\"icon-btn\" href=\"${escape(refresh)}\" title=\"Refresh\" aria-label=\"Refresh\">${AdminHtml.icon("refresh")}</a>"

	## A panel: a line over its title, its title, what goes on the right of its head (HTML), its
	## body (HTML), and a class of its own ("" for none).
	panel : { eyebrow : Str, title : Str, aside : Str, body : Str, class : Str } -> Str
	panel = |{ eyebrow, title, aside, body, class }| {
		over = if (eyebrow.is_empty()) "" else "<p class=\"eyebrow\">${eyebrow}</p>"
		classes = if (class.is_empty()) "panel" else "panel ${class}"
		"<section class=\"${classes}\"><header class=\"panel-head\"><div>${over}<h2>${title}</h2></div><div class=\"panel-aside\">${aside}</div></header>${body}</section>"
	}

	## What a panel says when it has nothing to show: an icon, a title and a line.
	empty : Str, Str, Str -> Str
	empty = |symbol, title, line| "<div class=\"empty\">${AdminHtml.icon(symbol)}<strong>${escape(title)}</strong><span>${line}</span></div>"

	## An icon, drawn with lines (`refresh`, `overview`, `clock`, `close`, `alert`, `check`,
	## `back`, `next`, `mail`, `play`, `retry`, `stop`, `layers`), as tall as the text.
	icon : Str -> Str
	icon = |name| {
		paths =
			match name {
				"refresh" => "<path d=\"M20 11a8 8 0 1 0-2.3 5.7\"/><path d=\"M20 4v7h-7\"/>"
				"overview" => "<rect x=\"3.5\" y=\"3.5\" width=\"7\" height=\"7\" rx=\"1.5\"/><rect x=\"13.5\" y=\"3.5\" width=\"7\" height=\"7\" rx=\"1.5\"/><rect x=\"3.5\" y=\"13.5\" width=\"7\" height=\"7\" rx=\"1.5\"/><rect x=\"13.5\" y=\"13.5\" width=\"7\" height=\"7\" rx=\"1.5\"/>"
				"clock" => "<circle cx=\"12\" cy=\"12\" r=\"8.5\"/><path d=\"M12 7.5V12l3 2\"/>"
				"close" => "<path d=\"M6 6l12 12M18 6 6 18\"/>"
				"alert" => "<path d=\"M12 3.5 2.8 19.5h18.4L12 3.5Z\"/><path d=\"M12 10v4.2M12 17h.01\"/>"
				"check" => "<circle cx=\"12\" cy=\"12\" r=\"8.5\"/><path d=\"m8.5 12.2 2.4 2.4 4.6-5\"/>"
				"back" => "<path d=\"m14.5 6-6 6 6 6\"/>"
				"next" => "<path d=\"m9.5 6 6 6-6 6\"/>"
				"mail" => "<rect x=\"3\" y=\"5\" width=\"18\" height=\"14\" rx=\"2\"/><path d=\"m3.5 7 8.5 6 8.5-6\"/>"
				"play" => "<path d=\"M8 5.5v13l10-6.5-10-6.5Z\"/>"
				"retry" => "<path d=\"M4 12a8 8 0 1 0 2.3-5.7\"/><path d=\"M4 4v5h5\"/>"
				"stop" => "<circle cx=\"12\" cy=\"12\" r=\"8.5\"/><path d=\"m9 9 6 6M15 9l-6 6\"/>"
				"layers" => "<path d=\"m12 3.5 8.5 4.5-8.5 4.5L3.5 8 12 3.5Z\"/><path d=\"m3.5 12 8.5 4.5 8.5-4.5\"/><path d=\"m3.5 16 8.5 4.5 8.5-4.5\"/>"
				_ => ""
			}
		"<svg class=\"icon\" viewBox=\"0 0 24 24\" width=\"16\" height=\"16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.7\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\">${paths}</svg>"
	}

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
	button = |action, fields, label| AdminHtml.button_with("", "", action, fields, label)

	## A form's button as `button` draws it, with a class on its form (`act-primary`, `act-danger`;
	## "" for none) and an icon before its label ("" for none).
	button_with : Str, Str, Str, List((Str, Str)), Str -> Str
	button_with = |class, symbol, action, fields, label| {
		hidden = fields.map(|(name, value)| "<input type=\"hidden\" name=\"${escape(name)}\" value=\"${escape(value)}\">")
		drawn = if (symbol.is_empty()) "" else AdminHtml.icon(symbol)
		classes = if (class.is_empty()) "act" else "act ${class}"
		"<form class=\"${classes}\" method=\"post\" action=\"${escape(action)}\">${Str.join_with(hidden, "")}<button>${drawn}${escape(label)}</button></form>"
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

	## A moment as it stands from `now`: `in 5 s`, `3 min ago`, in an element whose title says when
	## (the script keeps it current).
	relative : I64, I64 -> Str
	relative = |at, now| {
		said = if (at - now >= 1000) "in ${AdminHtml.span(at - now)}" else if (now - at >= 1000) "${AdminHtml.span(now - at)} ago" else "now"
		"<time datetime=\"${at.to_str()}\" title=\"${AdminHtml.moment(at)}\">${said}</time>"
	}

	## JSON as text (an input), indented, its keys, strings and other values in elements of their
	## own (`j-key`, `j-str`, `j-lit`), escaped. Text that isn't JSON comes out as it was, escaped.
	json : Str -> Str
	json = |text| {
		bytes = text.to_utf8()
		count = bytes.len()
		var $out = []
		var $at = 0
		var $depth = 0
		var $bad = Bool.False
		while $at < count and !$bad {
			byte = bytes.get($at) ?? ' '
			if byte == '"' {
				# A string, to its closing quote; a key when a colon comes next.
				var $end = $at + 1
				var $closed = Bool.False
				while $end < count and !$closed {
					each = bytes.get($end) ?? '"'
					if each == '\\' {
						$end = $end + 2
					} else if each == '"' {
						$closed = Bool.True
					} else {
						$end = $end + 1
					}
				}
				var $after = $end + 1
				while $after < count and is_space(bytes.get($after) ?? 'x') {
					$after = $after + 1
				}
				class = if (bytes.get($after) == Ok(':')) "j-key" else "j-str"
				$out = $out.concat("<span class=\"${class}\">".to_utf8()).concat(escape(Str.from_utf8_lossy(bytes.sublist({ start: $at, len: $end + 1 - $at }))).to_utf8()).concat("</span>".to_utf8())
				$at = $end + 1
			} else if byte == '{' or byte == '[' {
				var $peek = $at + 1
				while $peek < count and is_space(bytes.get($peek) ?? 'x') {
					$peek = $peek + 1
				}
				closing = if (byte == '{') '}' else ']'
				if bytes.get($peek) == Ok(closing) {
					$out = $out.append(byte).append(closing)
					$at = $peek + 1
				} else {
					$depth = $depth + 1
					$out = $out.append(byte).concat(indent($depth))
					$at = $at + 1
				}
			} else if byte == '}' or byte == ']' {
				$depth = if ($depth > 0) $depth - 1 else 0
				$out = $out.concat(indent($depth)).append(byte)
				$at = $at + 1
			} else if byte == ',' {
				$out = $out.append(',').concat(indent($depth))
				$at = $at + 1
			} else if byte == ':' {
				$out = $out.append(':').append(' ')
				$at = $at + 1
			} else if is_space(byte) {
				$at = $at + 1
			} else {
				# A number, `true`, `false` or `null`: to the next byte that ends it.
				var $stop = $at
				while $stop < count and !ends_literal(bytes.get($stop) ?? ',') {
					$stop = $stop + 1
				}
				if $stop == $at {
					$bad = Bool.True
				} else {
					$out = $out.concat("<span class=\"j-lit\">".to_utf8()).concat(escape(Str.from_utf8_lossy(bytes.sublist({ start: $at, len: $stop - $at }))).to_utf8()).concat("</span>".to_utf8())
					$at = $stop
				}
			}
		}
		if ($bad) escape(text) else Str.from_utf8_lossy($out)
	}
}

decoded : Str -> Str
decoded = |text| Server.decode_segment(text.replace_each("+", " "))

two : I64 -> Str
two = |n| if (n < 10) "0${n.to_str()}" else n.to_str()

is_space : U8 -> Bool
is_space = |byte| byte == ' ' or byte == '\n' or byte == '\r' or byte == '\t'

ends_literal : U8 -> Bool
ends_literal = |byte| is_space(byte) or byte == ',' or byte == '}' or byte == ']' or byte == ':' or byte == '"' or byte == '{' or byte == '['

indent : U64 -> List(U8)
indent = |depth| [10].concat(List.repeat(' ', depth * 2))

## Refreshes the page's live part (`[data-events]`) from the page itself each time its stream of
## events says something, keeping where the reader is (a drawer's scroll too); says whether the
## stream is open (`html[data-live]`); counts each `<time datetime>` on from the server's time
## (`data-now`) every second; and follows a drawer's close link on Escape.
script : Str
script =
	Str.join_with(
		[
			"(()=>{const root=document.documentElement;let skew=0;",
			"const sync=()=>{const s=document.querySelector(\"[data-now]\");if(s)skew=Number(s.dataset.now)-Date.now()};",
			"const span=ms=>{const s=Math.abs(ms);return s<1e3?s+\" ms\":s<6e4?Math.floor(s/1e3)+\" s\":s<36e5?Math.floor(s/6e4)+\" min\":s<864e5?Math.floor(s/36e5)+\" h\":Math.floor(s/864e5)+\" d\"};",
			"const tick=()=>{const now=Date.now()+skew;for(const t of document.querySelectorAll(\"time[datetime]\")){const at=Number(t.getAttribute(\"datetime\"));if(!at)continue;const said=at-now>=1e3?\"in \"+span(at-now):now-at>=1e3?span(now-at)+\" ago\":\"now\";if(t.textContent!==said)t.textContent=said}};",
			"sync();setInterval(tick,1000);",
			"document.addEventListener(\"keydown\",e=>{if(e.key===\"Escape\"){const c=document.querySelector(\"[data-close]\");if(c)location.assign(c.href)}});",
			"const live=document.querySelector(\"[data-events]\");if(!live||!window.EventSource)return;",
			"let busy=false,again=false;",
			"const refresh=async()=>{if(busy){again=true;return}busy=true;try{const answer=await fetch(location.href,{headers:{accept:\"text/html\"}});if(answer.ok){const fresh=new DOMParser().parseFromString(await answer.text(),\"text/html\").querySelector(\"[data-events]\");const now=document.querySelector(\"[data-events]\");if(fresh&&now){const drawer=now.querySelector(\".drawer\"),top=drawer?drawer.scrollTop:0;now.replaceWith(fresh);const kept=fresh.querySelector(\".drawer\");if(kept)kept.scrollTop=top;sync();tick()}}}catch{}finally{busy=false;if(again){again=false;refresh()}}};",
			"const source=new EventSource(live.dataset.events);source.onopen=()=>{root.dataset.live=\"on\"};source.onerror=()=>{root.dataset.live=\"off\"};source.onmessage=()=>{root.dataset.live=\"on\";refresh()};",
			"})()",
		],
		"",
	)

stylesheet : Str
stylesheet =
	Str.join_with(
		[
			# Tokens: light, and dark when the reader's scheme is.
			":root{color-scheme:light dark;--canvas:#f4f6f7;--side:#fafbfb;--surface:#fff;--soft:#f6f8f9;--line:#e2e7ea;--line-strong:#cdd5da;--text:#121a1f;--muted:#5b6870;--subtle:#7a868d;--accent:#0e8a7e;--good:#1d8a3a;--warn:#a96a00;--bad:#c63a2f;--active:#2c6cc2;--neutral:#6b777e;--bar-good:#45b260;--bar-warn:#e6a63a;--bar-bad:#e0685d;--bar-active:#5b93e0;--bar-neutral:#a6b0b6;--shadow:0 1px 2px rgba(16,24,32,.04),0 1px 3px rgba(16,24,32,.06);--radius:10px}",
			"@media (prefers-color-scheme:dark){:root{--canvas:#090c0f;--side:#0c1013;--surface:#11161a;--soft:#0e1317;--line:#232b31;--line-strong:#354047;--text:#edf1f2;--muted:#8e9aa1;--subtle:#76828a;--accent:#55c7bb;--good:#68c778;--warn:#e7ad52;--bad:#e8766e;--active:#6ca6e8;--neutral:#8e9aa1;--bar-good:#68c778;--bar-warn:#e7ad52;--bar-bad:#e26a62;--bar-active:#6ca6e8;--bar-neutral:#5d6a71;--shadow:none}}",
			".tone-good{--tone:var(--good)}.tone-warn{--tone:var(--warn)}.tone-bad{--tone:var(--bad)}.tone-active{--tone:var(--active)}.tone-neutral{--tone:var(--neutral)}.tone-accent{--tone:var(--accent)}",
			"*{box-sizing:border-box}",
			"html{background:var(--canvas)}",
			"body.rocx-admin{margin:0;min-width:320px;background:var(--canvas);color:var(--text);font:14px/1.5 Inter,ui-sans-serif,system-ui,-apple-system,\"Segoe UI\",sans-serif;font-feature-settings:\"cv11\",\"ss01\";-webkit-font-smoothing:antialiased}",
			"a{color:inherit;text-decoration:none}",
			"code,pre,.mono{font-family:ui-monospace,\"SF Mono\",SFMono-Regular,Menlo,Consolas,monospace;font-size:.92em}",
			"button,input,select{font:inherit;color:inherit}",
			"a:focus-visible,button:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:6px}",
			".icon{display:block;flex:none}",
			".muted{color:var(--muted)}.problem{color:var(--bad)}",
			# The shell: a sidebar, and the main part.
			".shell{display:grid;grid-template-columns:232px minmax(0,1fr);min-height:100vh}",
			".shell.bare{grid-template-columns:minmax(0,1fr)}.shell.bare main{max-width:60rem;margin:0 auto;width:100%}",
			".side{position:sticky;top:0;height:100vh;overflow:auto;display:flex;flex-direction:column;border-right:1px solid var(--line);background:var(--side)}",
			".brand{display:flex;align-items:center;gap:12px;min-height:84px;padding:18px 20px;border-bottom:1px solid var(--line)}",
			".brand strong,.brand small{display:block}.brand strong{font-size:14px;letter-spacing:-.01em}.brand small{color:var(--muted);font-size:13px}",
			".mark{display:grid;place-items:center;width:28px;height:28px;border:1px solid var(--accent);border-radius:50%;flex:none}",
			".mark::before,.mark span{grid-area:1/1;content:\"\";border-radius:50%}",
			".mark::before{width:15px;height:15px;border:1px solid color-mix(in srgb,var(--accent) 65%,transparent)}",
			".mark span{width:5px;height:5px;background:var(--accent);box-shadow:0 0 10px var(--accent)}",
			".side-nav{display:grid;gap:2px;padding:14px 10px}",
			".side-nav a{display:flex;align-items:center;gap:10px;min-height:36px;padding:0 10px;border:1px solid transparent;border-radius:8px;color:var(--muted)}",
			".side-nav a:hover{background:color-mix(in srgb,var(--text) 5%,transparent);color:var(--text)}",
			".side-nav a[aria-current=page]{border-color:color-mix(in srgb,var(--accent) 22%,transparent);background:color-mix(in srgb,var(--accent) 11%,transparent);color:var(--text)}",
			".side-nav a[aria-current=page] .icon{color:var(--accent)}",
			".side-nav .label{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}",
			".side-nav code{font-size:12.5px}",
			".side-nav .count{font-size:12px;font-variant-numeric:tabular-nums;color:var(--subtle)}",
			".side-nav .count.tone-bad{color:var(--bad);font-weight:600}",
			".nav-label{margin:14px 10px 4px;color:var(--subtle);font-size:11px;font-weight:600;letter-spacing:.08em;text-transform:uppercase}",
			".side-foot{margin:auto 0 0;padding:16px 20px 20px;border-top:1px solid var(--line);color:var(--subtle);font-size:12.5px}",
			".dot{display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--tone,var(--neutral));flex:none}",
			".side-nav .dot{margin:0 4px}",
			# The main part's header.
			"main{min-width:0;padding:0 32px 56px}",
			".top{display:flex;align-items:center;justify-content:space-between;gap:16px;min-height:84px;padding:16px 0;margin-bottom:20px;border-bottom:1px solid var(--line)}",
			".eyebrow{margin:0 0 2px;color:var(--subtle);font-size:11px;font-weight:600;letter-spacing:.1em;text-transform:uppercase}",
			"h1{margin:0;font-size:26px;line-height:1.2;letter-spacing:-.025em;font-weight:650}",
			"h1 code{font-size:.85em;letter-spacing:-.01em}",
			"h1 .meta{margin-left:12px;color:var(--muted);font-size:14px;font-weight:400;letter-spacing:0}",
			".top-title{min-width:0}.top-title h1{overflow-wrap:anywhere}",
			".top-actions{display:flex;align-items:center;gap:10px;flex-wrap:wrap;justify-content:flex-end}",
			".stamp{color:var(--muted);font-size:13px}",
			".live{display:none;align-items:center;gap:7px;height:28px;padding:0 10px;border:1px solid var(--line);border-radius:999px;color:var(--muted);font-size:12.5px}",
			".live i{width:7px;height:7px;border-radius:50%;background:var(--neutral)}",
			"html[data-live] .live{display:inline-flex}.live-on{display:none}",
			"html[data-live=on] .live-on{display:inline}html[data-live=on] .live-off{display:none}",
			"html[data-live=on] .live i{background:var(--good);box-shadow:0 0 0 0 color-mix(in srgb,var(--good) 55%,transparent);animation:pulse 2s infinite}",
			"@keyframes pulse{70%{box-shadow:0 0 0 6px transparent}100%{box-shadow:0 0 0 0 transparent}}",
			".icon-btn{display:grid;place-items:center;width:34px;height:34px;border:1px solid var(--line-strong);border-radius:8px;background:var(--surface);color:var(--text)}",
			".icon-btn:hover{background:var(--soft)}",
			# Metrics: how many of each state.
			".metrics{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));margin:0 0 20px;border:1px solid var(--line);border-radius:var(--radius);background:var(--surface);box-shadow:var(--shadow);overflow:hidden}",
			".metric{position:relative;display:block;padding:14px 18px 16px;border-left:1px solid var(--line)}",
			".metric:first-child{border-left:0}",
			".metric:hover{background:var(--soft)}",
			".metric[aria-current=page]{background:color-mix(in srgb,var(--tone,var(--accent)) 8%,transparent)}",
			".metric[aria-current=page]::after{content:\"\";position:absolute;left:0;right:0;bottom:0;height:2px;background:var(--tone,var(--accent))}",
			".metric-label{display:flex;align-items:center;gap:8px;color:var(--muted);font-size:13px}",
			".metric strong{display:block;margin-top:4px;font-size:28px;line-height:1.1;font-weight:600;letter-spacing:-.02em;font-variant-numeric:tabular-nums slashed-zero;color:var(--tone,var(--text))}",
			".metric.zero strong{color:var(--subtle)}",
			# Panels.
			".grid{display:grid;grid-template-columns:minmax(0,2fr) minmax(0,1fr);gap:16px;margin-bottom:16px;align-items:stretch}",
			".panel{min-width:0;margin-bottom:16px;border:1px solid var(--line);border-radius:var(--radius);background:var(--surface);box-shadow:var(--shadow)}",
			".grid>.panel{margin-bottom:0;display:flex;flex-direction:column}",
			".panel-head{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:14px 18px;border-bottom:1px solid var(--line)}",
			".panel-head h2{margin:0;font-size:15px;font-weight:600;letter-spacing:-.01em}",
			".panel-head h2 code{font-size:.9em}",
			".panel-aside{display:flex;align-items:center;gap:8px;flex-wrap:wrap;justify-content:flex-end;color:var(--muted);font-size:13px}",
			".panel-body{padding:16px 18px}",
			".panel-foot{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:12px 18px;border-top:1px solid var(--line);color:var(--muted);font-size:13px}",
			".panel-foot .pages{display:flex;gap:8px;margin-left:auto}",
			# Tables.
			".table-wrap{overflow-x:auto}",
			"table{width:100%;border-collapse:collapse}",
			"th{padding:10px 18px;text-align:left;color:var(--subtle);font-size:11px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;white-space:nowrap;border-bottom:1px solid var(--line)}",
			"td{padding:11px 18px;border-bottom:1px solid var(--line);vertical-align:middle}",
			"tbody tr:last-child td{border-bottom:0}",
			"tbody tr{position:relative}",
			"tbody tr:hover td{background:color-mix(in srgb,var(--text) 2.5%,transparent)}",
			"td.n,th.n{text-align:right;font-variant-numeric:tabular-nums}",
			"td.nowrap{white-space:nowrap}",
			".row-link::after{content:\"\";position:absolute;inset:0}",
			".row-link{display:block;min-width:0}",
			".row-link strong{display:block;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}",
			".row-link span{display:block;color:var(--subtle);font-size:12.5px;font-family:ui-monospace,\"SF Mono\",Menlo,monospace}",
			"tbody tr:hover .row-link strong{color:var(--accent)}",
			"tr.selected td{background:color-mix(in srgb,var(--accent) 9%,transparent)}",
			".kinds th,.kinds td{padding-left:10px;padding-right:10px}.kinds th:first-child,.kinds td:first-child{padding-left:18px}.kinds th:last-child,.kinds td:last-child{padding-right:18px}",
			"td .act,td a:not(.row-link),td .err{position:relative;z-index:1}",
			".key{display:inline-block;max-width:16rem;padding:1px 7px;border:1px solid var(--line);border-radius:6px;background:var(--soft);font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;vertical-align:middle}",
			"td.job,td.last{width:100%;max-width:0}",
			".err{display:block;max-width:100%;margin-top:3px;color:var(--bad);font-family:ui-monospace,\"SF Mono\",Menlo,monospace;font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}",
			".tries{font-variant-numeric:tabular-nums;white-space:nowrap}.tries small{color:var(--subtle);font-size:inherit}",
			".when{white-space:nowrap;color:var(--muted)}",
			"td.actions{text-align:right;white-space:nowrap}",
			# A job's state.
			".state{display:inline-flex;align-items:center;gap:7px;font-size:13px;font-weight:600;color:var(--tone);white-space:nowrap}",
			".state::before{content:\"\";width:7px;height:7px;border-radius:50%;background:currentColor}",
			".state-queued{--tone:var(--warn)}.state-running{--tone:var(--active)}.state-failed{--tone:var(--bad)}.state-done{--tone:var(--good)}.state-canceled{--tone:var(--neutral)}",
			".state-running::before{animation:pulse 1.6s infinite;box-shadow:0 0 0 0 color-mix(in srgb,var(--active) 55%,transparent)}",
			# Buttons.
			".act{display:inline-block;margin:0 0 0 6px}",
			".act button,.btn{display:inline-flex;align-items:center;gap:6px;height:30px;padding:0 11px;border:1px solid var(--line-strong);border-radius:7px;background:var(--surface);color:var(--text);font-size:13px;font-weight:500;cursor:pointer;white-space:nowrap}",
			".act button:hover,.btn:hover{background:var(--soft);border-color:var(--subtle)}",
			".act button .icon,.btn .icon{width:14px;height:14px}",
			".act-primary button{background:var(--text);border-color:var(--text);color:var(--surface)}",
			".act-primary button:hover{background:color-mix(in srgb,var(--text) 85%,var(--surface));border-color:transparent}",
			".act-danger button:hover{color:var(--bad);border-color:color-mix(in srgb,var(--bad) 50%,transparent);background:color-mix(in srgb,var(--bad) 8%,transparent)}",
			".btn[aria-disabled=true]{opacity:.45;pointer-events:none}",
			# Filters.
			".chip{display:inline-flex;align-items:center;gap:6px;height:26px;padding:0 4px 0 10px;border:1px solid var(--line-strong);border-radius:999px;color:var(--text);font-size:12.5px}",
			".chip a{display:grid;place-items:center;width:18px;height:18px;border-radius:50%;color:var(--muted)}",
			".chip a:hover{background:var(--soft);color:var(--text)}.chip .icon{width:12px;height:12px}",
			# The last hour.
			".chart{flex:1;display:flex;flex-direction:column;padding:16px 18px 14px}",
			".legend{display:flex;flex-wrap:wrap;gap:16px;margin:0 0 14px;color:var(--muted);font-size:13px}",
			".legend span{display:inline-flex;align-items:center;gap:7px}.legend b{color:var(--text);font-weight:600;font-variant-numeric:tabular-nums}",
			".bars{flex:1;display:grid;grid-template-columns:repeat(12,minmax(0,1fr));gap:8px;align-items:end;min-height:148px;border-bottom:1px solid var(--line);background:linear-gradient(color-mix(in srgb,var(--line) 70%,transparent) 1px,transparent 1px) 0 0/100% 25%}",
			".bar{display:flex;flex-direction:column-reverse;min-height:2px;border-radius:4px 4px 1px 1px;overflow:hidden;background:var(--line)}",
			".bar i{display:block;min-height:0}",
			":is(.bar,.dist) .tone-good{background:var(--bar-good)}:is(.bar,.dist) .tone-warn{background:var(--bar-warn)}:is(.bar,.dist) .tone-bad{background:var(--bar-bad)}:is(.bar,.dist) .tone-active{background:var(--bar-active)}:is(.bar,.dist) .tone-neutral{background:var(--bar-neutral)}",
			".bar:hover{filter:brightness(1.12)}",
			".axis{display:flex;justify-content:space-between;margin-top:8px;color:var(--subtle);font-size:12px;font-family:ui-monospace,\"SF Mono\",Menlo,monospace}",
			# Lists in a panel: failures, schedules.
			".list{margin:0;padding:0;list-style:none}",
			".list li{border-bottom:1px solid var(--line)}.list li:last-child{border-bottom:0}",
			".failure{display:flex;gap:12px;padding:13px 18px}",
			".failure:hover{background:color-mix(in srgb,var(--text) 2.5%,transparent)}",
			".failure .badge{display:grid;place-items:center;width:30px;height:30px;border-radius:50%;flex:none;color:var(--bad);background:color-mix(in srgb,var(--bad) 12%,transparent)}",
			".failure div{min-width:0;flex:1}",
			".failure strong{display:block;font-weight:600}.failure span{display:block;color:var(--muted);font-size:12.5px}",
			".failure .err{max-width:none;margin-top:4px}",
			".schedule{padding:13px 18px}",
			".schedule>div{display:flex;align-items:center;justify-content:space-between;gap:12px;min-width:0}",
			".schedule>div+div{margin-top:4px}",
			".schedule a{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:600}.schedule a:hover{color:var(--accent)}",
			".schedule .cron{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--muted);font-size:12.5px}",
			".schedule .cron code{margin-right:6px;padding:1px 6px;border-radius:5px;background:var(--soft);border:1px solid var(--line);font-size:11.5px}",
			".schedule .next{flex:none;color:var(--muted);font-size:12.5px;white-space:nowrap}",
			".schedule .next time{color:var(--text);font-weight:500}",
			".schedule .act{margin:0;flex:none}",
			".schedule .act button{height:26px;padding:0 9px;font-size:12.5px}",
			# Kinds.
			".kind-name{display:block;font-weight:600}.kind-name:hover{color:var(--accent)}",
			".kind-meta{display:block;color:var(--subtle);font-size:12.5px;white-space:nowrap}",
			".dist{display:flex;height:8px;min-width:90px;border-radius:999px;overflow:hidden;background:var(--line);gap:2px}",
			".dist i{display:block;min-width:3px}",
			"td.count a{font-weight:600;color:var(--tone)}td.count a:hover{text-decoration:underline}",
			"td.count.zero{color:var(--line-strong)}",
			# Nothing to show; a callout.
			".empty{display:flex;flex-direction:column;align-items:center;gap:4px;padding:36px 18px;text-align:center;color:var(--muted)}",
			".empty .icon{width:26px;height:26px;margin-bottom:6px;color:var(--good)}",
			".empty strong{color:var(--text);font-weight:600}",
			".callout{display:flex;gap:12px;align-items:flex-start;padding:14px 18px;background:color-mix(in srgb,var(--tone,var(--accent)) 9%,transparent);color:var(--text)}",
			".callout>.icon{width:18px;height:18px;margin-top:2px;color:var(--tone,var(--accent))}",
			".callout div{flex:1;min-width:0}.callout strong{display:block;font-weight:600}.callout p{margin:0}.callout span{display:block;color:var(--muted);font-size:13px}",
			".callout .acts{flex:none;display:flex;gap:6px;align-items:center}.callout .act{margin:0}",
			# A job, in a drawer over the list.
			".scrim{position:fixed;inset:0;z-index:30;background:rgba(5,8,10,.45);backdrop-filter:blur(3px);-webkit-backdrop-filter:blur(3px)}",
			".drawer{position:fixed;top:0;right:0;bottom:0;z-index:31;width:min(640px,100%);overflow:auto;border-left:1px solid var(--line);background:var(--surface);box-shadow:-24px 0 60px rgba(0,0,0,.25)}",
			".drawer-head{position:sticky;top:0;z-index:2;display:flex;align-items:flex-start;justify-content:space-between;gap:16px;padding:20px 22px 16px;border-bottom:1px solid var(--line);background:var(--surface)}",
			".drawer-head h2{margin:0;font-size:20px;letter-spacing:-.02em;font-weight:650;overflow-wrap:anywhere}",
			".drawer-head h2 code{font-size:.85em}",
			".drawer-status{display:flex;align-items:center;flex-wrap:wrap;gap:6px 14px;padding:12px 22px;border-bottom:1px solid var(--line);color:var(--muted);font-size:13px}",
			".drawer .callout{padding:14px 22px;border-bottom:1px solid var(--line)}",
			".section{padding:18px 22px;border-bottom:1px solid var(--line)}.section:last-child{border-bottom:0}",
			".section h3{display:flex;justify-content:space-between;gap:12px;margin:0 0 10px;font-size:13px;font-weight:600}",
			".section h3 small{color:var(--subtle);font-weight:400}",
			"pre{margin:0;padding:12px 14px;overflow:auto;border:1px solid var(--line);border-radius:8px;background:var(--soft);font-size:12.5px;line-height:1.6;white-space:pre-wrap;overflow-wrap:anywhere}",
			"pre.problem{border-color:color-mix(in srgb,var(--bad) 35%,transparent);background:color-mix(in srgb,var(--bad) 7%,transparent);color:var(--bad)}",
			".j-key{color:var(--active)}.j-str{color:var(--good)}.j-lit{color:var(--warn)}",
			".facts{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px 20px;margin:0}",
			".facts dt{color:var(--subtle);font-size:11px;font-weight:600;letter-spacing:.08em;text-transform:uppercase}",
			".facts dd{margin:2px 0 0;overflow-wrap:anywhere}",
			".timeline{position:relative;margin:0;padding:0;list-style:none}",
			".timeline li{position:relative;display:flex;gap:12px;padding:0 0 14px}",
			".timeline li:last-child{padding-bottom:0}",
			".timeline li::before{content:\"\";position:absolute;left:5px;top:16px;bottom:-2px;width:1px;background:var(--line-strong)}",
			".timeline li:last-child::before{display:none}",
			".timeline .dot{width:11px;height:11px;margin-top:5px;border:2px solid var(--surface);box-shadow:0 0 0 1px var(--tone,var(--neutral))}",
			".timeline strong{display:block;font-weight:600;font-size:13.5px}.timeline span{display:block;color:var(--muted);font-size:12.5px}",
			# Plain pages (the mailbox's): a list of facts, a frame.
			"dl.plain{display:grid;grid-template-columns:max-content 1fr;gap:6px 18px;margin:0;padding:16px 18px}",
			"dl.plain dt{color:var(--subtle)}dl.plain dd{margin:0;overflow-wrap:anywhere}",
			"iframe{display:block;width:100%;min-height:24rem;border:0;border-radius:0 0 var(--radius) var(--radius);background:#fff}",
			"details summary{cursor:pointer;padding:14px 18px;font-weight:600}details[open] summary{border-bottom:1px solid var(--line)}details pre{margin:14px 18px 18px}",
			".panel>pre{margin:14px 18px 18px}",
			".panel>p{margin:0;padding:14px 18px}",
			".panel>h2{margin:0;padding:14px 18px;border-bottom:1px solid var(--line);font-size:15px;font-weight:600}",
			".panel>details summary{list-style-position:inside}",
			"table.mail td:nth-child(-n+3){white-space:nowrap}",
			# Narrower screens.
			"@media (max-width:1180px){.grid{grid-template-columns:minmax(0,1fr)}.metrics{grid-template-columns:repeat(3,minmax(0,1fr))}.metric:nth-child(4){border-left:0}.metric:nth-child(n+4){border-top:1px solid var(--line)}}",
			"@media (max-width:820px){.shell{grid-template-columns:minmax(0,1fr);align-content:start}.side{position:static;height:auto;border-right:0;border-bottom:1px solid var(--line)}.brand{min-height:0;padding:14px 16px}.side-nav{display:flex;overflow-x:auto;padding:8px 10px}.side-nav a{flex:none}.nav-label,.side-foot{display:none}main{padding:0 16px 40px}.top{min-height:0;flex-wrap:wrap}h1 .meta{display:block;margin:4px 0 0}.stamp{display:none}.facts{grid-template-columns:minmax(0,1fr)}th,td{padding-left:12px;padding-right:12px}}",
			"@media (max-width:820px){table.jobs thead{display:none}table.jobs tbody tr{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:center;gap:6px 12px;padding:12px 14px;border-bottom:1px solid var(--line)}table.jobs tbody tr:last-child{border-bottom:0}table.jobs td{padding:0;border:0}table.jobs td:nth-child(3),table.jobs td:nth-child(5),table.jobs td.actions:empty{display:none}table.jobs td.job{grid-column:1;grid-row:1;width:auto;max-width:none;min-width:0}table.jobs td:nth-child(2){grid-column:2;grid-row:1;text-align:right;align-self:start}table.jobs td.when{grid-column:1;grid-row:2}table.jobs td.actions{grid-column:2;grid-row:2}}",
			"@media (prefers-reduced-motion:reduce){*{animation:none!important}}",
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
expect AdminHtml.json("{\"a\":[1, true],\"b\":{}}") == "{\n  <span class=\"j-key\">&quot;a&quot;</span>: [\n    <span class=\"j-lit\">1</span>,\n    <span class=\"j-lit\">true</span>\n  ],\n  <span class=\"j-key\">&quot;b&quot;</span>: {}\n}"
expect AdminHtml.json("\"x\\\"y\"") == "<span class=\"j-str\">&quot;x\\&quot;y&quot;</span>"
