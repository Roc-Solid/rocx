import pf.Db
import pf.Events
import pf.Live
import pf.Server
import jobs.Calendar
import Look

## The server's admin pages (the jobs page, the dev mailbox), in the admin look (`Look`: its shared
## rules and helpers): whole HTML documents answered as they are, their own rules among the shared
## ones (`stylesheet`), and a few lines of script: they refresh the page when its stream of events
## says something changed (`changes`), keep its times (`3 s ago`) current, say whether the page is
## live, and close a drawer on Escape. A link or a form to the page's own path (another filter, a
## drawer, an older page, Retry) is answered in place, as a View Transition: the sidebar stays where
## it is, the rest fades through, a drawer slides in and out, and the stream stays open. With no
## script, the page is the same, with a button that refreshes it, and its links and forms load
## whole pages (a View Transition too, where the browser has them across documents). Times, links
## and a query's fields, as those pages show and read them.
AdminHtml := [].{

	## A page: its title, the URL of its stream of changes ("" for none), the server's time (`now`,
	## which the script counts the page's times on from; 0 for none), its sidebar (`AdminHtml.side`;
	## "" for none) and its main part. What the stream refreshes is the sidebar and the main part
	## together (`[data-events]`).
	page : U16, { title : Str, events : Str, now : I64, side : Str, body : Str } -> Server.Response
	page = |status, shown| {
		stream = if (shown.events.is_empty()) "" else " data-events=\"${Look.escape(shown.events)}\""
		clock = if (shown.now == 0) "" else " data-now=\"${shown.now.to_str()}\""
		shell = if (shown.side.is_empty()) "shell bare" else "shell"
		document = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><meta name=\"color-scheme\" content=\"light dark\"><title>${Look.escape(shown.title)}</title><style>${stylesheet}</style></head><body class=\"rocx-admin\"><div class=\"${shell}\"${stream}${clock}>${shown.side}<main>${shown.body}</main></div><script>${script}</script></body></html>"
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
				body: "${Look.header({ eyebrow: "Not done", title: "That couldn't be done", actions: "" })}<section class=\"panel\"><div class=\"callout tone-bad\">${Look.icon("alert")}<div><p class=\"problem\">${Look.escape(why)}</p></div></div><div class=\"panel-foot\"><a class=\"btn\" href=\"${Look.escape(back)}\">${Look.icon("back")}Back</a></div></section>",
			},
		)

	## What the header's right side says of a live page: when it was drawn (counted on by the
	## script), whether its stream is open, and a button that refreshes it (`refresh`, its URL).
	live : I64, Str -> Str
	live = |now, refresh| "<span class=\"stamp\">Updated ${AdminHtml.relative(now, now)}</span><span class=\"live\" role=\"status\"><i></i><span class=\"live-on\">Live</span><span class=\"live-off\">Reconnecting</span></span><a class=\"icon-btn\" href=\"${Look.escape(refresh)}\" title=\"Refresh\" aria-label=\"Refresh\">${Look.icon("refresh")}</a>"

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
						_ = Db.listen!(channel)
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
				$out = $out.concat("<span class=\"${class}\">".to_utf8()).concat(Look.escape(Str.from_utf8_lossy(bytes.sublist({ start: $at, len: $end + 1 - $at }))).to_utf8()).concat("</span>".to_utf8())
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
					$out = $out.concat("<span class=\"j-lit\">".to_utf8()).concat(Look.escape(Str.from_utf8_lossy(bytes.sublist({ start: $at, len: $stop - $at }))).to_utf8()).concat("</span>".to_utf8())
					$at = $stop
				}
			}
		}
		if ($bad) Look.escape(text) else Str.from_utf8_lossy($out)
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
## events says something, keeping where the reader is (a drawer's scroll too, and the focus on the
## drawer, the heading or a link to the same place: `twin`); says whether the stream is open
## (`html[data-live]`); counts each `<time datetime>` on from the server's time (`data-now`) every
## second; and follows a drawer's close link on Escape.
##
## A link to the page's own path, and a form posted to it, are answered in place (`go`): the answer
## is fetched (a form's redirect followed), its `.shell` (the sidebar and the main part) put in for
## the page's, its address pushed (replaced when it is the same: Refresh, or an action sent back),
## and Back and Forward fetch theirs. The swap is a View Transition, where the browser has them and
## less motion isn't asked for, said on `html[data-moving]` for the stylesheet: `drawer` when only
## `?id=` changes and a drawer opens or closes, `same` when the address stays, `page` otherwise.
## A page goes to the top and its heading has the focus; a drawer keeps the scroll and has the
## focus, and closed, the link to it does. The stream follows the page (`connect`). Any other
## answer (another path, a guard's sign-in page) is loaded whole; a form whose fetch failed is sent
## as it would have been. A refresh that started before a navigation is dropped (`seq`). A form's
## attributes are read as attributes: its hidden `action` field hides `form.action`.
script : Str
script =
	Str.join_with(
		[
			"(()=>{const root=document.documentElement;let skew=0;",
			"const sync=()=>{const s=document.querySelector('[data-now]');if(s)skew=Number(s.dataset.now)-Date.now()};",
			"const span=ms=>{const s=Math.abs(ms);return s<1e3?s+' ms':s<6e4?Math.floor(s/1e3)+' s':s<36e5?Math.floor(s/6e4)+' min':s<864e5?Math.floor(s/36e5)+' h':Math.floor(s/864e5)+' d'};",
			"const tick=()=>{const now=Date.now()+skew;for(const t of document.querySelectorAll('time[datetime]')){const at=Number(t.getAttribute('datetime'));if(!at)continue;const said=at-now>=1e3?'in '+span(at-now):now-at>=1e3?span(now-at)+' ago':'now';if(t.textContent!==said)t.textContent=said}};",
			"sync();setInterval(tick,1000);",
			"const here=()=>location.href.split('#')[0];",
			"const bare=u=>{const x=new URL(u);x.hash='';x.searchParams.delete('id');return x.href};",
			"const own=u=>u.origin===location.origin&&u.pathname===location.pathname;",
			"let seq=0,shown=here(),source=null,stream='',busy=false,again=false,posting=false;",
			"const focusOn=to=>{if(!to)return;if(!to.hasAttribute('tabindex')&&to.tabIndex<0)to.tabIndex=-1;to.focus({preventScroll:true})};",
			"const twin=(had,fresh)=>had.matches('.drawer')?fresh.querySelector('.drawer'):had.matches('main h1')?fresh.querySelector('main h1'):had.matches('a[href]')?[...fresh.querySelectorAll('a[href]')].find(a=>a.getAttribute('href')===had.getAttribute('href')):null;",
			"const refresh=async()=>{if(busy){again=true;return}busy=true;const mine=seq;try{const answer=await fetch(location.href,{headers:{accept:'text/html'}});const text=answer.ok?await answer.text():'';const fresh=text&&new DOMParser().parseFromString(text,'text/html').querySelector('[data-events]');const now=document.querySelector('[data-events]');if(fresh&&now&&mine===seq){const drawer=now.querySelector('.drawer'),top=drawer?drawer.scrollTop:0,had=document.activeElement,inside=had&&now.contains(had);now.replaceWith(fresh);const kept=fresh.querySelector('.drawer');if(kept)kept.scrollTop=top;if(inside)focusOn(twin(had,fresh));sync();tick()}}catch{}finally{busy=false;if(again){again=false;refresh()}}};",
			"const connect=()=>{const live=document.querySelector('[data-events]'),want=live&&window.EventSource?new URL(live.dataset.events,location.href).href:'';if(want===stream)return;if(source)source.close();source=null;stream=want;delete root.dataset.live;if(want){source=new EventSource(want);source.onopen=()=>{root.dataset.live='on'};source.onerror=()=>{root.dataset.live='off'};source.onmessage=()=>{root.dataset.live='on';refresh()}}};",
			"const settle=(mode,was)=>{const drawer=document.querySelector('.drawer');focusOn(mode==='page'?document.querySelector('main h1'):drawer?drawer:mode==='drawer'?[...document.querySelectorAll('a[href]')].find(a=>a.href===was):null)};",
			"const go=async(to,how,init,fallback)=>{const mine=++seq;root.dataset.going='';let answer,doc,fresh;try{answer=await fetch(to,{...init,headers:{accept:'text/html'}});doc=new DOMParser().parseFromString(await answer.text(),'text/html');fresh=doc.querySelector('.shell')}catch{}if(mine!==seq)return;delete root.dataset.going;",
			"if(!answer)return(fallback||(()=>location.assign(to)))();const at=answer.url;if(!fresh||!own(new URL(at)))return location.assign(at);",
			"const was=here(),mode=at===was?'same':bare(at)===bare(was)&&(document.querySelector('.drawer')||fresh.querySelector('.drawer'))?'drawer':'page';const y=how==='pop'?(history.state&&history.state.y)||0:mode==='page'?0:scrollY;",
			"if(how==='pop'){if(at!==was)history.replaceState(history.state,'',at)}else{history.replaceState({...history.state,y:scrollY},'');if(at===was)history.replaceState(history.state,'',at);else history.pushState({y:0},'',at)}shown=at;",
			"const swap=()=>{try{const now=document.querySelector('.shell');if(now)now.replaceWith(fresh);document.title=doc.title;scrollTo(0,y);sync();tick();connect();settle(mode,was)}catch{location.assign(at)}};",
			"if(document.hidden||!document.startViewTransition||matchMedia('(prefers-reduced-motion: reduce)').matches)return swap();root.dataset.moving=mode;const t=document.startViewTransition(swap);t.ready.catch(()=>{});t.finished.catch(()=>{}).then(()=>{if(mine===seq)delete root.dataset.moving})};",
			"document.addEventListener('click',e=>{const a=e.target.closest&&e.target.closest('a[href]');if(!a||e.defaultPrevented||e.button||e.metaKey||e.ctrlKey||e.shiftKey||e.altKey||(a.target&&a.target!=='_self')||a.hasAttribute('download'))return;const to=new URL(a.getAttribute('href'),location.href);if(!own(to)||(to.hash&&to.search===location.search))return;e.preventDefault();go(to.href,'push')});",
			"document.addEventListener('submit',e=>{const f=e.target,target=f.getAttribute('target');if(e.defaultPrevented||(f.getAttribute('method')||'').toLowerCase()!=='post'||(target&&target!=='_self'))return;const to=new URL(f.getAttribute('action')||'',location.href);if(!own(to))return;e.preventDefault();if(posting)return;posting=true;go(to.href,'push',{method:'POST',body:new URLSearchParams(new FormData(f))},()=>HTMLFormElement.prototype.submit.call(f)).finally(()=>{posting=false})});",
			"document.addEventListener('keydown',e=>{if(e.key!=='Escape'||e.defaultPrevented)return;const c=document.querySelector('[data-close]');if(c){e.preventDefault();go(new URL(c.getAttribute('href'),location.href).href,'push')}});",
			"addEventListener('popstate',()=>{if(here()!==shown)go(here(),'pop')});",
			"history.scrollRestoration='manual';addEventListener('pagehide',()=>{history.scrollRestoration='auto'});addEventListener('pageshow',()=>{history.scrollRestoration='manual'});",
			"connect()})()",
		],
		"",
	)

stylesheet : Str
stylesheet =
	Str.join_with(
		[
			# Tokens: light, and dark when the reader's scheme is.
			Look.shared.tokens,
			# The shell: a sidebar, and the main part.
			Look.shared.shell,
			# The main part's header.
			Look.shared.top,
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
			Look.shared.panels,
			# Tables.
			Look.shared.tables,
			# A job's state.
			".state{display:inline-flex;align-items:center;gap:7px;font-size:13px;font-weight:600;color:var(--tone);white-space:nowrap}",
			".state::before{content:\"\";width:7px;height:7px;border-radius:50%;background:currentColor}",
			".state-queued{--tone:var(--warn)}.state-running{--tone:var(--active)}.state-failed{--tone:var(--bad)}.state-done{--tone:var(--good)}.state-canceled{--tone:var(--neutral)}",
			".state-running::before{animation:pulse 1.6s infinite;box-shadow:0 0 0 0 color-mix(in srgb,var(--active) 55%,transparent)}",
			# Buttons.
			Look.shared.buttons,
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
			Look.shared.empty,
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
			Look.shared.narrower,
			# Page transitions (`script` says each in place one's kind on `html[data-moving]`; a whole page
			# loaded is one too, where the browser has them across documents). The sidebar stays where it
			# is and changes only where it differs (not on a narrow screen, where it scrolls away with the
			# page); a page fades out quickly and the next one fades in, rising a little; a drawer slides
			# in from the right and out again, the list behind it cross-fading (its scrim blurs in with
			# it: a named scrim's backdrop-filter would see nothing behind it), as does a page that stays.
			# Under a drawer's scrim, and while one comes or goes, the sidebar is the page's, not held: a
			# named one is drawn above the page, so the scrim wouldn't cover it until the end. The drawer
			# and the heading the script focuses have no ring (a link it focuses keeps its own).
			"@view-transition{navigation:auto}",
			".side{view-transition-name:admin-side}.drawer{view-transition-name:admin-drawer}html[data-going]{cursor:progress}",
			".shell:has(.drawer) .side,html:is([data-moving=drawer],[data-moving=same]) .side{view-transition-name:none}.drawer:focus,main h1:focus{outline:none}",
			"::view-transition-old(root){animation:90ms ease-in both admin-fade-out}::view-transition-new(root){animation:210ms cubic-bezier(.2,0,0,1) 50ms both admin-enter}",
			"html:is([data-moving=drawer],[data-moving=same])::view-transition-old(root){animation:180ms ease both admin-fade-out}html:is([data-moving=drawer],[data-moving=same])::view-transition-new(root){animation:180ms ease both admin-fade-in}",
			"::view-transition-group(admin-side){animation-duration:200ms}",
			"::view-transition-new(admin-drawer):only-child{animation:260ms cubic-bezier(.2,0,0,1) both admin-drawer-in}::view-transition-old(admin-drawer):only-child{animation:180ms cubic-bezier(.4,0,1,1) both admin-drawer-out}",
			"@keyframes admin-fade-out{to{opacity:0}}@keyframes admin-fade-in{from{opacity:0}}@keyframes admin-enter{from{opacity:0;transform:translateY(6px)}}",
			"@keyframes admin-drawer-in{from{transform:translateX(100%)}}@keyframes admin-drawer-out{to{transform:translateX(100%)}}",
			"@media (max-width:820px){.side{view-transition-name:none}}@media (prefers-reduced-motion:reduce){@view-transition{navigation:none}}",
		],
		"",
	)

expect AdminHtml.param("state=failed&kind=a+b%26c", "kind") == "a b&c"
expect AdminHtml.param("state=failed", "kind") == ""
expect AdminHtml.asks("events", "events") and AdminHtml.asks("a=1&events=", "events") and !AdminHtml.asks("eventsx=1", "events")
expect AdminHtml.link("/jobs", [("state", "failed"), ("kind", ""), ("before", "12")]) == "/jobs?state=failed&before=12"
expect AdminHtml.moment(1795211647000) == "2026-11-20 21:54:07 UTC"
expect AdminHtml.span(-4000) == "4 s"
expect Look.escape("<a href=\"x\">'") == "&lt;a href=&quot;x&quot;&gt;&#39;"
expect AdminHtml.capitalized("failed") == "Failed"
expect AdminHtml.safe_query("state=failed&kind=a%20b\r\nx: y") == "state=failed&kind=a%20bxy"
expect AdminHtml.shortened("one\ntwo") == "one…"
expect AdminHtml.shortened("short") == "short"
expect AdminHtml.json("{\"a\":[1, true],\"b\":{}}") == "{\n  <span class=\"j-key\">&quot;a&quot;</span>: [\n    <span class=\"j-lit\">1</span>,\n    <span class=\"j-lit\">true</span>\n  ],\n  <span class=\"j-key\">&quot;b&quot;</span>: {}\n}"
expect AdminHtml.json("\"x\\\"y\"") == "<span class=\"j-str\">&quot;x\\&quot;y&quot;</span>"
