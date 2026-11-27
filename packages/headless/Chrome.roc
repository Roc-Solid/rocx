import pf.Child
import pf.Cmd
import pf.Env
import pf.File
import pf.Time
import pf.WebSocket
import tools.JsonValue
import Tab

## Chromium's headless shell, started with a profile of its own and driven over its DevTools
## protocol: `launch!` starts it, `open!` opens a tab (`Tab`, a socket of its own), `close!` ends it
## and deletes the profile. Its tabs share that profile's cookies, as one person's browser does.
Chrome := { child : Child, port : Str, profile : Str, socket : WebSocket }.{

	## Chromium's headless shell: `$CHROME`, else the newest one Playwright keeps in its cache
	## (`npx playwright install --only-shell chromium` puts one there). `NoChrome` says how to get one.
	find! : {} => Try(Str, [NoChrome(Str)])
	find! = |{}|
		match Env.var!("CHROME") {
			Ok(binary) => Ok(binary)
			Err(NotFound) => {
				home = Env.var!("HOME") ?? ""
				caches = ["${home}/Library/Caches/ms-playwright", "${home}/.cache/ms-playwright"]
				var $found = Err(NoChrome("set CHROME to Chromium's headless shell, or run `npx playwright install --only-shell chromium`"))
				for cache in caches {
					if $found.is_err() {
						shells = (File.list!(cache) ?? []).keep_if(|name| name.starts_with("chromium_headless_shell-")).sort_with(newest_first)
						for shell in shells {
							for system in File.list!("${cache}/${shell}") ?? [] {
								binary = "${cache}/${shell}/${system}/chrome-headless-shell"
								if $found.is_err() and File.exists!(binary) {
									$found = Ok(binary)
								}
							}
						}
					}
				}
				$found
			}
		}

	## The headless shell at `binary`, started in a new profile in the system's temporary directory,
	## whatever the machine's settings, as a laptop's: motion as a page gets it when it asks for
	## nothing (macOS's Reduce motion is on on GitHub's runners), scrollbars that take no room, and no
	## sandbox (as Playwright runs it: a container's root may not have the namespaces it needs). Its
	## DevTools port is the one it picks, read from the profile once it is listening.
	launch! : Str => Try(Chrome, [CantLaunch(Str)])
	launch! = |binary| {
		temporary = (Env.var!("TMPDIR") ?? "/tmp").drop_suffix("/")
		profile = "${temporary}/rocx-chrome-${Env.pid!({}).to_str()}-${Time.now_ns!({}).to_str()}"
		File.make_dirs!(profile).map_err(|CantWrite(why)| CantLaunch(why))?
		log = "${profile}.log"
		flags = ["--headless", "--remote-debugging-port=0", "--user-data-dir=${profile}", "--no-first-run", "--no-sandbox", "--force-prefers-no-reduced-motion", "--hide-scrollbars", "about:blank"]
		child = Cmd.new(binary).args(flags).log(log).spawn!().map_err(|CantStart(why)| CantLaunch(why))?
		active = "${profile}/DevToolsActivePort"
		started = Time.now_ms!({})
		var $lines = []
		while $lines.len() < 2 and Time.now_ms!({}) - started < 15_000 {
			$lines = (File.read!(active) ?? "").split_on("\n").keep_if(|line| !line.is_empty())
			if $lines.len() < 2 {
				Time.sleep!(20)
			}
		}
		match $lines {
			[port, path, ..] =>
				match WebSocket.connect!("ws://127.0.0.1:${port}${path}") {
					Ok(socket) => {
						chrome : Chrome
						chrome = { child: child, port: port, profile: profile, socket: socket }
						Ok(chrome)
					}
					Err(CantConnect(why)) => {
						Child.kill!(child)
						Err(CantLaunch("${binary}: ${why}"))
					}
				}
			_ => {
				Child.kill!(child)
				said = File.read!(log) ?? ""
				Err(CantLaunch("${binary} didn't start listening in 15 s: ${said}"))
			}
		}
	}

	## A new tab, at about:blank, with a socket of its own.
	open! : Chrome => Try(Tab, [Failed(Str)])
	open! = |chrome| {
		created = WebSocket.request!(chrome.socket, JsonValue.to_str(Object([("method", String("Target.createTarget")), ("params", Object([("url", String("about:blank"))]))])), 30_000)
		match created.map_err(|_| Missing).map_ok(target_of) {
			Ok(Ok(id)) =>
				match WebSocket.connect!("ws://127.0.0.1:${chrome.port}/devtools/page/${id}") {
					Ok(socket) => Ok(Tab.at(socket))
					Err(CantConnect(why)) => Err(Failed("a new tab: ${why}"))
				}
			_ => Err(Failed("Chromium didn't make a tab: ${Str.inspect(created)}"))
		}
	}

	## Ends the browser (asked to close, then made to), and deletes its profile.
	close! : Chrome => {}
	close! = |chrome| {
		_ = WebSocket.request!(chrome.socket, JsonValue.to_str(Object([("method", String("Browser.close"))])), 2_000)
		WebSocket.close!(chrome.socket)
		# The profile is deleted once the browser has stopped writing in it: tried again until it
		# goes, and the browser made to stop when it hasn't in 3 s.
		gone = deleted!(chrome.profile, 3_000)
		Child.kill!(chrome.child)
		if !gone {
			_ = deleted!(chrome.profile, 2_000)
		}
		_ = File.delete!("${chrome.profile}.log")
		{}
	}
}

## Whether `dir` is gone: deleted, tried again every 50 ms for up to `ms` while it is still there.
deleted! : Str, U64 => Bool
deleted! = |dir, ms| {
	started = Time.now_ms!({})
	var $gone = Bool.False
	while !$gone {
		$gone = File.delete!(dir).is_ok() and !File.exists!(dir)
		if !$gone {
			if Time.now_ms!({}) - started >= ms {
				return Bool.False
			}
			Time.sleep!(50)
		}
	}
	Bool.True
}

## The id of the target `Target.createTarget` made, from its answer.
target_of : Str -> Try(Str, [Missing])
target_of = |text|
	match JsonValue.parse(text) {
		Ok(answer) =>
			match answer.get("result") {
				Ok(result) =>
					match result.get("targetId") {
						Ok(String(id)) => Ok(id)
						_ => Err(Missing)
					}
				Err(Missing) => Err(Missing)
			}
		Err(_) => Err(Missing)
	}

## Playwright's headless shells, the newest first: `chromium_headless_shell-1255` by its number.
newest_first : Str, Str -> [Before, Same, After]
newest_first = |a, b| {
	number = |name| U64.from_str(name.drop_prefix("chromium_headless_shell-")) ?? 0
	if (number(a) > number(b)) Before else if (number(a) < number(b)) After else Same
}
