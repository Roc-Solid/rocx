## The admin look, in one place: whole HTML documents in the shape of a console (a sidebar, a
## header, panels), under one class, `rocx-admin`, in light or dark as the reader's scheme is. Its
## rules every admin page shares, part by part (`shared`), and its helpers (`side`, `nav_link`,
## `nav_label`, `header`, `panel`, `empty`, `icon`, `button`, `button_with`): the tables admin's
## pages are drawn with them and its own rules (`stylesheet`, `document`), and so are the server's
## pages (`AdminHtml`: the jobs page, the dev mailbox), with theirs. On no platform, so a page in
## the browser can show the tables admin too.
Look := [].{

	## Text as HTML has it, in an element or an attribute's quotes.
	escape : Str -> Str
	escape = |text| text.replace_each("&", "&amp;").replace_each("<", "&lt;").replace_each(">", "&gt;").replace_each("\"", "&quot;").replace_each("'", "&#39;")

	## A whole page: its title, its sidebar (`Look.side`; "" for none) and its main part, as HTML.
	document : Str, Str, Str -> Str
	document = |title, sidebar, body| {
		shell = if (sidebar.is_empty()) "shell bare" else "shell"
		"<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><meta name=\"color-scheme\" content=\"light dark\"><meta name=\"robots\" content=\"noindex\"><title>${escape(title)}</title><style>${stylesheet}</style></head><body class=\"rocx-admin\"><div class=\"${shell}\">${sidebar}<main>${body}</main></div></body></html>"
	}

	## The headers every page is sent with: HTML, never kept by a cache, never in another site's
	## frame, and no script, no request elsewhere, no form sent elsewhere.
	headers : List({ name : Str, value : Str })
	headers = [
		{ name: "content-type", value: "text/html; charset=utf-8" },
		{ name: "cache-control", value: "no-store" },
		{ name: "x-frame-options", value: "DENY" },
		{ name: "content-security-policy", value: "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'" },
		{ name: "referrer-policy", value: "same-origin" },
	]

	## The sidebar: a brand (`name`, a `note` under it, a link `home`), the navigation's links
	## (`Look.nav_link`, `Look.nav_label`) and a line at its foot.
	side : { name : Str, note : Str, home : Str, nav : Str, foot : Str } -> Str
	side = |{ name, note, home, nav, foot }|
		"<aside class=\"side\"><a class=\"brand\" href=\"${escape(home)}\"><span class=\"mark\" aria-hidden=\"true\"><span></span></span><span><strong>${escape(name)}</strong><small>${escape(note)}</small></span></a><nav class=\"side-nav\" aria-label=\"${escape(name)}\">${nav}</nav><p class=\"side-foot\">${foot}</p></aside>"

	## A link in the sidebar: where it goes, its icon (`Look.icon`'s name, or "" for a dot of
	## `tone`), its label (HTML), a count ("" for none), and whether it is the page shown.
	nav_link : { href : Str, icon : Str, tone : Str, label : Str, count : Str, on : Bool } -> Str
	nav_link = |item| {
		current = if (item.on) " aria-current=\"page\"" else ""
		mark = if (item.icon.is_empty()) "<i class=\"dot tone-${item.tone}\"></i>" else Look.icon(item.icon)
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
	empty = |symbol, title, line| "<div class=\"empty\">${Look.icon(symbol)}<strong>${escape(title)}</strong><span>${line}</span></div>"

	## An icon, drawn with lines, as tall as the text: `AdminHtml`'s (`refresh`, `overview`,
	## `clock`, `close`, `alert`, `check`, `back`, `next`, `mail`, `play`, `retry`, `stop`,
	## `layers`), and the admin's own (`table`, `plus`, `trash`, `search`, `filter`).
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
				# The admin's own.
				"table" => "<rect x=\"3.5\" y=\"4.5\" width=\"17\" height=\"15\" rx=\"2\"/><path d=\"M3.5 9.5h17M3.5 14.5h17M9.5 9.5v10\"/>"
				"plus" => "<path d=\"M12 5v14M5 12h14\"/>"
				"trash" => "<path d=\"M4.5 7h15\"/><path d=\"M9.5 7V4.5h5V7\"/><path d=\"m6.5 7 .9 12.5h9.2L17.5 7\"/>"
				"search" => "<circle cx=\"11\" cy=\"11\" r=\"6.5\"/><path d=\"m16 16 4 4\"/>"
				"filter" => "<path d=\"M4 5.5h16l-6.2 7.3v5.4l-3.6 1.8v-7.2L4 5.5Z\"/>"
				_ => ""
			}
		"<svg class=\"icon\" viewBox=\"0 0 24 24\" width=\"16\" height=\"16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.7\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\">${paths}</svg>"
	}

	## A form that posts `fields` (hidden) to `action`, as a button saying `label`.
	button : Str, List((Str, Str)), Str -> Str
	button = |action, fields, label| Look.button_with("", "", action, fields, label)

	## A form's button as `button` draws it, with a class on its form (`act-primary`, `act-danger`;
	## "" for none) and an icon before its label ("" for none).
	button_with : Str, Str, Str, List((Str, Str)), Str -> Str
	button_with = |class, symbol, action, fields, label| {
		hidden = fields.map(|(name, value)| "<input type=\"hidden\" name=\"${escape(name)}\" value=\"${escape(value)}\">")
		drawn = if (symbol.is_empty()) "" else Look.icon(symbol)
		classes = if (class.is_empty()) "act" else "act ${class}"
		"<form class=\"${classes}\" method=\"post\" action=\"${escape(action)}\">${Str.join_with(hidden, "")}<button>${drawn}${escape(label)}</button></form>"
	}

	## The rules every admin page shares, part by part (the jobs page's, the dev mailbox's, the
	## tables admin's), in the order a stylesheet has them: each page's stylesheet puts its own rules
	## among them (`Look.stylesheet`, `AdminHtml`'s).
	Shared : { tokens : Str, shell : Str, top : Str, panels : Str, tables : Str, buttons : Str, empty : Str, narrower : Str }

	shared : Shared
	shared = {
		# Tokens: light, and dark when the reader's scheme is.
		tokens: Str.join_with(
			[
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
			],
			"",
		),
		# The shell: a sidebar, and the main part.
		shell: Str.join_with(
			[
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
			],
			"",
		),
		# The main part's header.
		top: Str.join_with(
			[
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
			],
			"",
		),
		# Panels.
		panels: Str.join_with(
			[
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
			],
			"",
		),
		# Tables.
		tables: Str.join_with(
			[
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
			],
			"",
		),
		# Buttons.
		buttons: Str.join_with(
			[
				".act{display:inline-block;margin:0 0 0 6px}",
				".act button,.btn{display:inline-flex;align-items:center;gap:6px;height:30px;padding:0 11px;border:1px solid var(--line-strong);border-radius:7px;background:var(--surface);color:var(--text);font-size:13px;font-weight:500;cursor:pointer;white-space:nowrap}",
				".act button:hover,.btn:hover{background:var(--soft);border-color:var(--subtle)}",
				".act button .icon,.btn .icon{width:14px;height:14px}",
				".act-primary button{background:var(--text);border-color:var(--text);color:var(--surface)}",
				".act-primary button:hover{background:color-mix(in srgb,var(--text) 85%,var(--surface));border-color:transparent}",
				".act-danger button:hover{color:var(--bad);border-color:color-mix(in srgb,var(--bad) 50%,transparent);background:color-mix(in srgb,var(--bad) 8%,transparent)}",
				".btn[aria-disabled=true]{opacity:.45;pointer-events:none}",
			],
			"",
		),
		# Nothing to show; a callout.
		empty: Str.join_with(
			[
				".empty{display:flex;flex-direction:column;align-items:center;gap:4px;padding:36px 18px;text-align:center;color:var(--muted)}",
				".empty .icon{width:26px;height:26px;margin-bottom:6px;color:var(--good)}",
				".empty strong{color:var(--text);font-weight:600}",
				".callout{display:flex;gap:12px;align-items:flex-start;padding:14px 18px;background:color-mix(in srgb,var(--tone,var(--accent)) 9%,transparent);color:var(--text)}",
				".callout>.icon{width:18px;height:18px;margin-top:2px;color:var(--tone,var(--accent))}",
				".callout div{flex:1;min-width:0}.callout strong{display:block;font-weight:600}.callout p{margin:0}.callout span{display:block;color:var(--muted);font-size:13px}",
				".callout .acts{flex:none;display:flex;gap:6px;align-items:center}.callout .act{margin:0}",
			],
			"",
		),
		# Narrower screens.
		narrower: Str.join_with(
			[
				"@media (max-width:1180px){.grid{grid-template-columns:minmax(0,1fr)}.metrics{grid-template-columns:repeat(3,minmax(0,1fr))}.metric:nth-child(4){border-left:0}.metric:nth-child(n+4){border-top:1px solid var(--line)}}",
				"@media (max-width:820px){.shell{grid-template-columns:minmax(0,1fr);align-content:start}.side{position:static;height:auto;border-right:0;border-bottom:1px solid var(--line)}.brand{min-height:0;padding:14px 16px}.side-nav{display:flex;overflow-x:auto;padding:8px 10px}.side-nav a{flex:none}.nav-label,.side-foot{display:none}main{padding:0 16px 40px}.top{min-height:0;flex-wrap:wrap}h1 .meta{display:block;margin:4px 0 0}.stamp{display:none}.facts{grid-template-columns:minmax(0,1fr)}th,td{padding-left:12px;padding-right:12px}}",
				"@media (max-width:820px){table.jobs thead{display:none}table.jobs tbody tr{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:center;gap:6px 12px;padding:12px 14px;border-bottom:1px solid var(--line)}table.jobs tbody tr:last-child{border-bottom:0}table.jobs td{padding:0;border:0}table.jobs td:nth-child(3),table.jobs td:nth-child(5),table.jobs td.actions:empty{display:none}table.jobs td.job{grid-column:1;grid-row:1;width:auto;max-width:none;min-width:0}table.jobs td:nth-child(2){grid-column:2;grid-row:1;text-align:right;align-self:start}table.jobs td.when{grid-column:1;grid-row:2}table.jobs td.actions{grid-column:2;grid-row:2}}",
				"@media (prefers-reduced-motion:reduce){*{animation:none!important}}",
			],
			"",
		),
	}

	## The tables admin's stylesheet: the shared rules, then its own.
	stylesheet : Str
	stylesheet = Str.join_with([Look.shared.tokens, Look.shared.shell, Look.shared.top, Look.shared.panels, Look.shared.tables, Look.shared.buttons, Look.shared.empty, Look.shared.narrower, own], "")
}

## The tables admin's own rules: a trail in an eyebrow, its forms, a list's search, filters and
## pages, a row's fields.
own : Str
own =
	Str.join_with(
		[
			# The admin's own: a trail in an eyebrow, links as buttons, a note or a problem over a page.
			".eyebrow a:hover{color:var(--text)}.eyebrow code{font-size:12px;letter-spacing:0;text-transform:none}",
			".btn.primary{background:var(--text);border-color:var(--text);color:var(--surface)}.btn.primary:hover{background:color-mix(in srgb,var(--text) 85%,var(--surface));border-color:transparent}",
			".btn.danger:hover{color:var(--bad);border-color:color-mix(in srgb,var(--bad) 50%,transparent);background:color-mix(in srgb,var(--bad) 8%,transparent)}",
			".confirm .act-danger button{background:var(--bad);border-color:var(--bad);color:var(--surface)}.confirm .act-danger button:hover{background:color-mix(in srgb,var(--bad) 85%,var(--text));border-color:transparent;color:var(--surface)}",
			".panel>.callout:first-child{border-radius:calc(var(--radius) - 1px) calc(var(--radius) - 1px) 0 0}.panel>.callout:last-child{border-radius:0 0 calc(var(--radius) - 1px) calc(var(--radius) - 1px)}.panel>.callout:only-child{border-radius:calc(var(--radius) - 1px)}",
			".callout .problem{overflow-wrap:anywhere}",
			# Inputs, selects and text areas.
			"input,select,textarea{height:32px;padding:0 10px;border:1px solid var(--line-strong);border-radius:7px;background:var(--surface);color:var(--text);font:inherit;font-size:13.5px}",
			"textarea{display:block;width:100%;height:auto;min-height:5rem;padding:8px 10px;line-height:1.5;resize:vertical}",
			"textarea.code{font-family:ui-monospace,\"SF Mono\",SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px}",
			"input:focus,select:focus,textarea:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px color-mix(in srgb,var(--accent) 22%,transparent)}",
			"input[type=checkbox]{width:16px;height:16px;padding:0;margin:8px 0 0;accent-color:var(--accent)}",
			"input::placeholder{color:var(--subtle)}[aria-invalid=true]{border-color:var(--bad)}",
			# The index of tables.
			"td.name a{display:block;font-weight:600}td.name a:hover{color:var(--accent)}td.name code{display:block;color:var(--subtle);font-size:12.5px}",
			"td.about{color:var(--muted)}",
			# A list: its search and the filters' button; its rows, which scroll sideways, a filter under each
			# heading, each input as wide as its column (and at least as its kind needs); its pages.
			".tools{display:flex;flex-wrap:wrap;align-items:center;gap:10px 16px;padding:12px 18px;border-bottom:1px solid var(--line)}",
			"form.search{display:flex;flex:1 1 18rem;max-width:34rem;align-items:center;gap:8px;margin:0}form.search input{flex:1;min-width:0}",
			".filtering{display:flex;align-items:center;gap:12px;margin-left:auto}",
			".tools a{color:var(--muted);font-size:13px}.tools a:hover{color:var(--text)}",
			".tools input{height:30px}",
			"form.filters{display:block;margin:0}",
			".rows{overflow-x:auto}",
			".rows th,.rows td{padding-left:12px;padding-right:12px}.rows th:first-child,.rows td:first-child{padding-left:18px}.rows th:last-child,.rows td:last-child{padding-right:18px}",
			".rows td{max-width:26rem;overflow-wrap:break-word}",
			".rows td a{color:var(--accent)}.rows td a:hover{text-decoration:underline}",
			".rows tbody td:first-child>a{color:var(--text);font-weight:600}.rows tbody td:first-child>a:hover{color:var(--accent);text-decoration:none}",
			"td.null,.value.null{color:var(--subtle);font-style:italic}",
			"th a{color:inherit}th a:hover,th a.on{color:var(--text)}",
			"tr.filter td{padding-top:8px;padding-bottom:8px;background:var(--soft);vertical-align:top}",
			"tbody tr:hover td.none{background:none}",
			"tr.filter input,tr.filter select{display:block;width:100%;min-width:6rem;height:28px;padding:0 8px;font-size:12.5px}",
			"tr.filter input[type=number]{min-width:4.5rem}tr.filter input[type=date]{min-width:8.5rem}tr.filter input[type=datetime-local]{min-width:12rem}tr.filter input[type=time]{min-width:6rem}",
			"tr.filter .range{display:grid;grid-template-columns:max-content 1fr;gap:4px 6px;align-items:center}",
			"tr.filter .range span{color:var(--subtle);font-size:11px}",
			"tr.filter select.nulls{margin-top:4px}",
			"tr.filter .note{display:block;margin-top:4px;color:var(--bad);font-size:11.5px;font-weight:500;white-space:normal}",
			"td.none{padding:36px 18px;text-align:center;color:var(--muted)}",
			".pager{display:flex;flex-wrap:wrap;gap:4px;margin-left:auto}",
			".pager a{display:inline-grid;place-items:center;min-width:30px;height:30px;padding:0 8px;border:1px solid var(--line-strong);border-radius:7px;background:var(--surface);color:var(--text);font-variant-numeric:tabular-nums}",
			".pager a:hover{background:var(--soft)}.pager a.on{background:var(--text);border-color:var(--text);color:var(--surface)}",
			".pager .gap{display:inline-grid;place-items:center;min-width:20px;color:var(--subtle)}",
			# A row's fields: a label, then its input, the column's comment and type.
			".fields{display:grid;grid-template-columns:minmax(9rem,max-content) minmax(0,1fr);gap:16px 28px;align-items:start;padding:20px 18px}",
			".fields>label,.fields>.label{padding-top:6px;font-weight:600}",
			".fields>div{min-width:0}",
			".fields input:not([type=checkbox]),.fields select{width:100%;max-width:32rem}",
			".fields input[type=number],.fields input[type=date],.fields input[type=time],.fields input[type=datetime-local]{width:auto;min-width:12rem}",
			".fields textarea{max-width:48rem}",
			".fields div>a{margin-left:6px;color:var(--accent);font-size:13px}.fields div>a:hover{text-decoration:underline}",
			".help{display:block;margin-top:5px;color:var(--muted);font-size:12.5px}",
			".help .muted{color:var(--subtle);font-family:ui-monospace,\"SF Mono\",SFMono-Regular,Menlo,Consolas,monospace;font-size:12px}",
			".value{display:block;padding-top:6px;white-space:pre-wrap;overflow-wrap:anywhere}",
			".panel-foot .act{margin:0}",
			"@media (max-width:820px){.tools{padding:12px 14px}form.search{max-width:none}.filtering{margin-left:0}.rows th:first-child,.rows td:first-child{padding-left:12px}.rows th:last-child,.rows td:last-child{padding-right:12px}.fields{grid-template-columns:minmax(0,1fr);gap:6px;padding:16px 14px}.fields>div{margin-bottom:10px}.fields>label,.fields>.label{padding-top:0}}",
		],
		"",
	)

expect Look.escape("<a href=\"x\">'&") == "&lt;a href=&quot;x&quot;&gt;&#39;&amp;"
expect Look.document("A <b>", "", "<p>hi</p>").contains("<title>A &lt;b&gt;</title>") and Look.document("A", "", "").contains("<div class=\"shell bare\"><main>")
expect Look.document("A", Look.side({ name: "Db", note: "", home: "/db", nav: "", foot: "" }), "").contains("<div class=\"shell\"><aside class=\"side\"><a class=\"brand\" href=\"/db\">")
expect Look.nav_link({ href: "/db?table=a&b", icon: "", tone: "good", label: "A", count: "", on: Bool.True }) == "<a href=\"/db?table=a&amp;b\" aria-current=\"page\"><i class=\"dot tone-good\"></i><span class=\"label\">A</span></a>"
expect Look.icon("plus").contains("<path d=\"M12 5v14M5 12h14\"/>") and Look.icon("nothing").contains("aria-hidden=\"true\"></svg>")
