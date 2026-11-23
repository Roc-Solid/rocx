## `rocx dev`: an app built and served under --dev, built again and its server restarted on each
## save. Its open pages reload when the server is back (the server does that: `/__reload`). One loop
## over `Events.next!` (cli/platform): a file changed (a build 100 ms after the last change), a
## child ended (the server, stopped to restart or on its own; the SQL check), a signal (stop
## everything, and exit).
##
## What is built, served and watched is a plan: an app's (`app!`), and the docs site's (`Site`).
import pf.Child
import pf.Cmd
import pf.Env
import pf.Events
import pf.File
import pf.Stderr
import pf.Time
import pf.Watch
import Build
import Fs
import Hosts
import Remap
import Text

Dev := [].{

	## What a dev loop builds, serves and watches. `label` starts what it says (`rocx dev`);
	## `base` is where the paths it names are from; `watch` the directories (real paths) it watches,
	## but for hidden entries and directories named in `skip`; `edited!` says whether a path that
	## changed (absolute) is an edit. `build!` builds everything; `serve` is the server and its
	## arguments; `check` the command run beside it after each start (the app's SQL check), if any.
	Plan : {
		label : Str,
		base : Str,
		watch : List(Str),
		skip : List(Str),
		edited! : Str => Bool,
		build! : {} => Try({}, [Failed(Str)]),
		serve : Cmd,
		check : [Run(Cmd), Nothing],
	}

	## Builds, serves and watches until a signal.
	run! : Plan => Try({}, [Exit(I32)])
	run! = |plan| {
		var $server = Down
		var $checking = Idle
		match (plan.build!)({}) {
			Ok({}) => {
				$server = Dev.start!(plan)
				$checking = Dev.check!(plan, Idle)
			}
			Err(Failed(message)) => {
				_ = Stderr.line!(message)
			}
		}
		for dir in plan.watch {
			match Watch.dir!(dir, plan.skip) {
				Ok({}) => {}
				Err(CantWatch(why)) => {
					_ = Stderr.line!("${plan.label}: can't watch ${why}")
					return Err(Exit(2))
				}
			}
		}
		# The server was asked to stop, to start the new build when it has.
		var $stopping = Bool.False
		# The first file changed since the last build, waiting for 100 ms without another change.
		var $pending = ""
		var $running = Bool.True
		while $running {
			match Events.next!(if ($pending.is_empty()) 0 else 100) {
				Changed(paths) => {
					for path in paths {
						if $pending.is_empty() and (plan.edited!)(path) {
							$pending = Fs.relative(plan.base, path)
						}
					}
				}
				Timeout => {
					_ = Stderr.line!("${plan.label}: ${$pending} changed")
					$pending = ""
					match (plan.build!)({}) {
						Ok({}) =>
							match $server {
								Up(child) => {
									Child.terminate!(child)
									$stopping = Bool.True
								}
								Down => {
									$server = Dev.start!(plan)
									$checking = Dev.check!(plan, $checking)
								}
							}
						Err(Failed(message)) => {
							_ = Stderr.line!(message)
						}
					}
				}
				Exited(id, code) =>
					match $server {
						Up(child) if child.id() == id => {
							if $stopping {
								$stopping = Bool.False
								$server = Dev.start!(plan)
								$checking = Dev.check!(plan, $checking)
							} else {
								_ = Stderr.line!("${plan.label}: the server stopped (${code.to_str()}); save a file to build and start it again")
								$server = Down
							}
						}
						_ =>
							match $checking {
								Checking(child) if child.id() == id => {
									$checking = Idle
								}
								_ => {}
							}
					}
				Signal(_) => {
					# The children end with this program: the platform sends them SIGTERM as it exits.
					$running = Bool.False
				}
			}
		}
		Ok({})
	}

	start! : Plan => [Up(Child), Down]
	start! = |plan|
		match plan.serve.spawn!() {
			Ok(child) => Up(child)
			Err(CantStart(why)) => {
				_ = Stderr.line!("${plan.label}: the server didn't start: ${why}")
				Down
			}
		}

	## The plan's check, beside the server; a check still running is stopped first.
	check! : Plan, [Checking(Child), Idle] => [Checking(Child), Idle]
	check! = |plan, checking| {
		match checking {
			Checking(before) => Child.terminate!(before)
			Idle => {}
		}
		match plan.check {
			Run(command) =>
				match command.spawn!() {
					Ok(child) => Checking(child)
					Err(_) => Idle
				}
			Nothing => Idle
		}
	}

	# ---- An app ----

	## `rocx dev [dir] [--port 8080] [-- server options…]`: the app in `dir` (or here), a directory
	## with routes/ in it, built with the clone rocx is in (`rocx`): rocx build, the server's host
	## when it changed, the server and the browser's wasm (when the app has pages), all from Roc's
	## dev backend; served at http://localhost:8080 under --dev, with what follows `--` (and the
	## environment: DATABASE_URL, PORT). An app without a main.roc gets one, the smallest program,
	## which is the author's to change after. After each start the app's SQL is checked, as
	## `rocx check --sql` checks it (D-058), and what that finds is said.
	app! : List(Str), Str => Try({}, [Exit(I32)])
	app! = |args, rocx| {
		usage = "usage: rocx dev [dir] [--port 8080] [-- server options…]"
		var $own = []
		var $passed = []
		var $after = Bool.False
		for arg in args {
			if $after {
				$passed = $passed.append(arg)
			} else if arg == "--" {
				$after = Bool.True
			} else {
				$own = $own.append(arg)
			}
		}
		var $port = Env.var!("PORT") ?? "8080"
		var $dirs = []
		var $i = 0
		while $i < $own.len() {
			arg = $own.get($i) ?? ""
			if arg == "--port" and $i + 1 < $own.len() {
				$port = $own.get($i + 1) ?? ""
				$i = $i + 2
			} else if arg.starts_with("-") {
				return Dev.fail!(usage)
			} else {
				$dirs = $dirs.append(arg)
				$i = $i + 1
			}
		}
		if $dirs.len() > 1 or $port.is_empty() or !$port.to_utf8().all(|byte| byte >= '0' and byte <= '9') {
			return Dev.fail!(usage)
		}
		given = $dirs.first() ?? "."
		dir = match File.real_path!(given) {
			Ok(real) => real
			Err(_) => return Dev.fail!("rocx dev: no directory ${given}")
		}
		shown = {
			way = Fs.relative(Fs.cwd!(), dir)
			if (way.is_empty()) "." else way
		}
		if !File.is_dir!(Fs.join([dir, "routes"])) {
			return Dev.fail!("rocx dev: ${shown} has no routes/: make routes/+page.rocx (the page at /) or routes/hello/+server.roc (an endpoint at /hello)")
		}
		main = Fs.join([dir, "main.roc"])
		if !File.exists!(main) {
			Dev.write_main!(dir, main, rocx)
		}
		tools = match Dev.tools!(rocx) {
			Ok(found) => found
			Err(Failed(message)) => return Dev.fail!(message)
		}
		client = Fs.join([dir, "build", "client"])
		server = Fs.join([dir, "build", "server"])
		app_static = Fs.join([dir, "static"])
		statics = ["--static", Fs.join([client, "static"])].concat(if (File.exists!(app_static)) ["--static", app_static] else [])
		Dev.run!({
			label: "rocx dev",
			base: dir,
			watch: [dir],
			skip: ["build", "dist", "Generated", "node_modules", "static"],
			edited!: |path| Dev.app_edit!(path),
			build!: |{}| Dev.build_app!({ dir, shown, main, client, server, tools }),
			serve: Cmd.new(server).args(["--port", $port, "--dev"].concat(statics).concat($passed)),
			check: Run(Cmd.new(Fs.join([rocx, "bin", "rocx"])).args(["check", "--sql", dir, "--server", server, "--quiet", "--"].concat($passed))),
		})
	}

	fail! : Str => Try(a, [Exit(I32)])
	fail! = |message| {
		_ = Stderr.line!(message)
		Err(Exit(2))
	}

	## The smallest program, for an app that has none: what every request's middleware starts from
	## (nothing), and a middleware that passes each request on to the routes. The platform is the
	## clone's, by a path from the app, as Roc wants it.
	write_main! : Str, Str, Str => {}
	write_main! = |dir, main, rocx| {
		pf_path = Fs.relative(dir, Fs.join([rocx, "server", "platform", "main.roc"]))
		text = [
			"## The app's program, written by `rocx dev` because there was none: it is yours to change.",
			"## `context` is what each request's middleware is given, and `middleware` runs around every",
			"## request (this one passes it on to the routes); App.program also takes `plugins` and `openapi`.",
			"app [program] { pf: platform \"${pf_path}\" }",
			"",
			"import pf.Middleware",
			"import Generated/App",
			"",
			"program = App.program({",
			"\tcontext: |_started| {},",
			"\tmiddleware: Middleware.make(|request, context, next!| next!(request, context)),",
			"})",
			"",
		]
		_ = Fs.write!(main, Str.join_with(text, "\n"))
		_ = Stderr.line!("rocx dev: wrote ${Fs.relative(Fs.cwd!(), main)}, the app's program")
		{}
	}

	## A path that changed and matters: not a backup or swap file, nor a .roc file rocx wrote (beside
	## its .rocx, or ending with rocx's marker). The platform leaves out hidden entries and the
	## output directories.
	app_edit! : Str => Bool
	app_edit! = |path| {
		if [".swp", ".tmp", ".building", "~"].any(|suffix| path.ends_with(suffix)) {
			return Bool.False
		}
		!(path.ends_with(".roc") and Dev.rocx_wrote!(path))
	}

	## Whether rocx wrote a .roc file: beside its .rocx, or its last line rocx's marker.
	rocx_wrote! : Str => Bool
	rocx_wrote! = |path|
		File.exists!("${path}x") or (Text.lines(Text.trim_end(Fs.read_or_empty!(path))).last() ?? "").starts_with(Remap.marker)

	## Everything, beside what is served, then moved into place together: the server serving the
	## build before keeps serving it whole until it is restarted. The server first: it compiles every
	## page the browser does, from the app's own Generated/, whose reports point into the .rocx files.
	build_app! : { dir : Str, shown : Str, main : Str, client : Str, server : Str, tools : Tools } => Try({}, [Failed(Str)])
	build_app! = |a| {
		started = Time.now_ms!({})
		built = match Build.build!([a.dir], { client: Some(a.client), cwd: Fs.cwd!(), dev: Bool.True, rocx: a.tools.rocx }) {
			Ok(done) => done
			Err(Problem(message)) => return Err(Failed("Error: ${message}\nrocx dev: rocx build failed; fix it and save again"))
		}
		said = built.said.keep_if(|line| !Dev.files_written(line))
		if !built.ok {
			return Err(Failed("${Str.join_with(said, "\n")}\nrocx dev: rocx build failed; fix it and save again"))
		}
		if !said.is_empty() {
			_ = Stderr.line!(Str.join_with(said, "\n"))
		}
		match Hosts.server_host!(a.tools.rocx, a.tools.target) {
			Ok({}) => {}
			Err(Failed(message)) => return Err(Failed("${Text.trim_end(message)}\nrocx dev: the server's host didn't build"))
		}
		Dev.roc_build!(a.tools, ["--target=${a.tools.target}", "--opt=dev", "--output=${a.server}.building", a.main], "the server's build")?
		var $built = [a.server]
		# An app of pages has a browser's half (rocx build wrote its main.roc); one of endpoints alone hasn't.
		client_main = Fs.join([a.client, "main.roc"])
		if File.exists!(client_main) {
			Dev.web_host!(a.tools)?
			wasm = Fs.join([a.client, "static", "rocx", "app.wasm"])
			Dev.roc_build!(a.tools, ["--target=wasm32", "--opt=dev", "--output=${wasm}.building", client_main], "the browser's build")?
			$built = $built.append(wasm)
		}
		for file in $built {
			match File.rename!("${file}.building", file) {
				Ok({}) => {}
				Err(CantRename(why)) => return Err(Failed("rocx dev: ${why}"))
			}
		}
		_ = Stderr.line!("rocx dev: built ${a.shown} in ${Dev.seconds(Time.now_ms!({}) - started)} s")
		Ok({})
	}

	# ---- Building ----

	## The tools a build uses, found once: rocx's clone, Roc (the fork rocx builds with), Zig, and
	## this machine's target (Hosts).
	Tools : { rocx : Str, roc : Str, zig : Str, target : Str }

	tools! : Str => Try(Tools, [Failed(Str)])
	tools! = |rocx| Ok({ rocx, roc: Hosts.roc!(rocx)?, zig: Hosts.zig!(rocx), target: Hosts.native_target!({}) })

	## `roc build`, its reports pointed into the .rocx files (as `rocx check` does). Roc exits 1 on an
	## error (it still says it built: what it wrote crashes where the error is) and 2 on warnings
	## alone, which are shown and served. On success only what isn't routine is said.
	roc_build! : Tools, List(Str), Str => Try({}, [Failed(Str)])
	roc_build! = |tools, args, what| {
		ran = match Cmd.new(tools.roc).args(["build"].concat(args)).env("NO_COLOR", "1").output!() {
			Ok(done) => done
			Err(CantStart(why)) => return Err(Failed("rocx dev: ${what} failed: ${why}"))
		}
		said = Remap.remap!(ran.stdout.concat(ran.stderr))
		if ran.code != 0 and ran.code != 2 {
			return Err(Failed("${Text.trim_end(said)}\nrocx dev: ${what} failed; fix it and save again"))
		}
		lines = Text.lines(said)
		if !lines.any(|line| line.starts_with("0 errors and 0 warnings found")) {
			rest = lines.keep_if(|line| !Text.trim(line).is_empty())
			if !rest.is_empty() {
				_ = Stderr.line!(Str.join_with(rest, "\n"))
			}
		}
		Ok({})
	}

	## rocx build's routine line: `rocx: 12 files written`.
	files_written : Str -> Bool
	files_written = |line| {
		count = line.drop_prefix("rocx: ").drop_suffix(" files written").drop_suffix(" file written")
		line.starts_with("rocx: ") and count != line.drop_prefix("rocx: ") and !count.is_empty() and count.to_utf8().all(|byte| byte >= '0' and byte <= '9')
	}

	## A command that says nothing unless it fails.
	quiet! : Cmd, Str => Try({}, [Failed(Str)])
	quiet! = |command, what|
		match command.merged!() {
			Ok(ran) if ran.code == 0 => Ok({})
			Ok(ran) => Err(Failed("${Text.trim_end(ran.output)}\nrocx dev: ${what} didn't build"))
			Err(CantStart(why)) => Err(Failed("rocx dev: ${what}: ${why}"))
		}

	## The browser's host (Zig), built once, and again when its Zig changes.
	web_host! : Tools => Try({}, [Failed(Str)])
	web_host! = |tools| {
		object = Fs.join([tools.rocx, "web", "platform", "targets", "wasm32", "host.wasm"])
		host = Fs.join([tools.rocx, "web", "host", "host.zig"])
		sources = [host, Fs.join([tools.rocx, "web", "host", "roc_platform_abi.zig"])]
		built = File.modified!(object)
		if built > 0 and Dev.not_newer!(sources, built) {
			return Ok({})
		}
		Fs.make_dirs!(Fs.dirname(object))
		Dev.quiet!(Cmd.new(tools.zig).args(["build-obj", host, "-target", "wasm32-freestanding", "-O", "ReleaseSmall", "-fcompiler-rt", "-femit-bin=${object}"]), "the browser's host")
	}

	## Whether none of the files changed after `time` (nanoseconds since the epoch).
	not_newer! : List(Str), U64 => Bool
	not_newer! = |files, time| {
		for file in files {
			if File.modified!(file) > time {
				return Bool.False
			}
		}
		Bool.True
	}

	## Milliseconds as seconds, with two decimals (`0.35`).
	seconds : U64 -> Str
	seconds = |ms| {
		hundredths = (ms % 1000) // 10
		"${(ms // 1000).to_str()}.${if (hundredths < 10) "0" else ""}${hundredths.to_str()}"
	}
}
