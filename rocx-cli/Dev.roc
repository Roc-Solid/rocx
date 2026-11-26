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
import pf.Stdout
import pf.Time
import pf.Watch
import Agents
import Build
import Commands
import Fs
import Hosts
import qr.Qr
import Remap
import Term
import Text

Dev := [].{

	## What a dev loop builds, serves and watches. `label` starts what it says (`rocx dev`);
	## `base` is where the paths it names are from; `watch` the directories (real paths) it watches,
	## but for hidden entries and directories named in `skip`; `edited!` says whether a path that
	## changed (absolute) is an edit. `build!` builds everything; `serve` is the server and its
	## arguments; `started!` runs once it is started again (a phone's build is announced then);
	## `check` the command run beside it after each start (the app's SQL check), if any; `header!`
	## what it says first.
	Plan : {
		label : Str,
		header! : {} => {},
		base : Str,
		watch : List(Str),
		skip : List(Str),
		edited! : Str => Bool,
		build! : {} => Try({}, [Failed(Str)]),
		serve : Cmd,
		started! : {} => {},
		check : [Run(Cmd), Nothing],
	}

	## Builds, serves and watches until a signal. The first build can take a while (a platform's host,
	## the browser's wasm), so it says it has begun.
	run! : Plan => Try({}, [Exit(I32)])
	run! = |plan| {
		var $server = Down
		var $checking = Idle
		styled = Term.styled!({})
		(plan.header!)({})
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
					_ = Stderr.line!(Term.red(styled, "${plan.label}: can't watch ${why}"))
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
					# Plain, the line an editor reads as a build's start (editors/vscode/reports.js).
					_ = Stderr.line!(if (styled) "  ${Term.cyan(styled, "↻")} ${$pending}" else "${plan.label}: ${$pending} changed")
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
								said = "the server stopped (${code.to_str()}); save a file to build and start it again"
								if styled {
									Term.warn!(styled, said)
								} else {
									_ = Stderr.line!("${plan.label}: ${said}")
								}
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
			Ok(child) => {
				(plan.started!)({})
				Up(child)
			}
			Err(CantStart(why)) => {
				styled = Term.styled!({})
				if styled {
					Term.warn!(styled, "the server didn't start: ${why}")
				} else {
					_ = Stderr.line!("${plan.label}: the server didn't start: ${why}")
				}
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

	## `rocx dev [dir] [--port 8080] [--android [--lan]] [-- server options…]`: the app in `dir` (or here), a directory
	## with routes/ in it, built with its root (`Hosts.root_of!`: its `.rocx`, else the home of this
	## rocx, `rocx`): rocx build, the server's host
	## when it changed, the server and the browser's wasm (when the app has pages), all from Roc's
	## dev backend; served at http://localhost:8080 under --dev, with what follows `--` (and the
	## environment: DATABASE_URL, PORT). An app without a main.roc gets one, the smallest program,
	## which is the author's to change after. After each start the app's SQL is checked, as
	## `rocx check --sql` checks it (D-058), and what that finds is said. With `--android`, each
	## build is the phone's too, for the dev client (`phone!`, D-063's dev mode); with `--lan`, the
	## server is on this network too, for phones on its Wi-Fi (a QR code shows the way).
	app! : List(Str), Str => Try({}, [Exit(I32)])
	app! = |args, rocx| {
		usage = "usage: rocx dev [dir] [--port 8080] [--android [--lan]] [-- server options…]"
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
		var $android = Bool.False
		var $lan = Bool.False
		var $i = 0
		while $i < $own.len() {
			arg = $own.get($i) ?? ""
			if arg == "--port" and $i + 1 < $own.len() {
				$port = $own.get($i + 1) ?? ""
				$i = $i + 2
			} else if arg == "--android" {
				$android = Bool.True
				$i = $i + 1
			} else if arg == "--lan" {
				# The server on this network, for phones on its Wi-Fi: the dev mode's alone.
				$android = Bool.True
				$lan = Bool.True
				$i = $i + 1
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
		root = Hosts.root_of!(dir, rocx)
		main = Fs.join([dir, "main.roc"])
		if !File.exists!(main) {
			Dev.write_main!(dir, main, root)
		}
		tools = match Dev.tools!(root) {
			Ok(found) => found
			Err(Failed(message)) => return Dev.fail!(message)
		}
		client = Fs.join([dir, "build", "client"])
		server = Fs.join([dir, "build", "server"])
		app_static = Fs.join([dir, "static"])
		phone =
			if $android {
				match Dev.phone!(dir, root, tools) {
					Ok(found) => On(found)
					Err(Failed(message)) => return Dev.fail!(message)
				}
			} else {
				Off
			}
		phone_static =
			match phone {
				On(found) => ["--static", found.served]
				Off => []
			}
		statics = ["--static", Fs.join([client, "static"])].concat(if (File.exists!(app_static)) ["--static", app_static] else []).concat(phone_static)
		match phone {
			On(found) => Dev.phone_connect!(found, $port, $lan)
			Off => {}
		}
		lan_host = if ($lan) ["--host", "0.0.0.0"] else []
		# The `.env` here, if there is one, for the server and the check's (D-098): the server reads
		# none it isn't given.
		server_flags = $passed.concat(Hosts.env_file!($passed))
		Dev.run!({
			label: "rocx dev",
			header!: |{}| {
				styled = Term.styled!({})
				if styled {
					Dev.banner!(styled, Fs.basename(dir), $port, $lan, Fs.read_or_empty!(main))
				} else {
					_ = Stderr.line!("rocx dev: building")
				}
			},
			base: dir,
			watch: [dir],
			skip: ["build", "dist", "Generated", "node_modules", "static"],
			edited!: |path| Dev.app_edit!(path),
			build!: |{}| Dev.build_app!({ dir, shown, main, client, server, tools, phone }),
			serve: Cmd.new(server).args(["--port", $port, "--dev"].concat(lan_host).concat(statics).concat(server_flags)),
			started!: |{}|
				match phone {
					On(found) => Dev.phone_publish!(found)
					Off => {}
				},
			check: Run(Cmd.new(Fs.join([rocx, "bin", "rocx"])).args(["check", "--sql", dir, "--server", server, "--quiet", "--"].concat(server_flags))),
		})
	}

	## `rocx check [dir]`: the app in `dir` (or here) checked from its sources, so a check never reads
	## what an older build left: `rocx build` as `rocx dev` builds it (Generated/, and the browser's copy
	## in build/client, a dev build's: its stories too), its problems said at their lines; then the
	## compiler `rocx dev` builds with type-checks the server's program (main.roc) and, for an app of
	## pages, the browser's (build/client/main.roc), every report pointed into the .rocx files. Exit 1
	## on an error (rocx build's or the compiler's), 2 on warnings alone, 0 when all is well.
	check_app! : List(Str), Str => Try({}, [Exit(I32)])
	check_app! = |args, rocx| {
		# At a terminal: a header, a step for each program, and what was found (D-107); elsewhere (an
		# editor's task, a script) the compiler's reports as they come, on standard output.
		styled = Term.styled!({})
		if styled {
			Term.header!(styled, "rocx check", [Fs.basename(Fs.real!(Fs.resolve(Fs.cwd!(), [args.first() ?? "."])))])
		}
		ready = Dev.from_sources!(args, rocx, "rocx check")?
		client_main = Fs.join([ready.client, "main.roc"])
		programs = [{ path: ready.main, what: "server program" }].concat(if (File.exists!(client_main)) [{ path: client_main, what: "browser program" }] else [])
		# rocx build's own warnings (`⚠ file:line:col: …`, D-070's arm values read once) count as the
		# compiler's do: 2.
		var $code = if (ready.warned) 2 else 0
		for program in programs {
			step = if (styled) Some(Term.begin!(styled, program.what)) else None
			match Commands.checked!(ready.tools.roc, ["check", program.path]) {
				Ok(ran) => {
					match step {
						Some(begun) => if (ran.code == 0) Term.done!(begun) else Term.failed!(begun)
						None => {}
					}
					text = Text.trim_end(ran.said)
					routine = Text.lines(text).all(|line| line.starts_with("No errors found") or Text.trim(line).is_empty())
					if !text.is_empty() and !(styled and routine) {
						_ = Stdout.line!(text)
					}
					$code =
						if ran.code == 0 {
							$code
						} else if ran.code == 2 {
							if ($code == 0) 2 else $code
						} else {
							1
						}
				}
				Err(CantStart(why)) => return Dev.fail!("rocx check: ${why}")
			}
		}
		# AGENTS.md's rocx block (D-108), when the app has one: said when it is another rocx's or was
		# edited, never counted against the check.
		match Agents.standing!(Fs.dirname(ready.main), rocx) {
			Stale => Term.warn!(styled, "AGENTS.md's rocx block is from another version of rocx: rocx agents rewrites it")
			Edited => Term.warn!(styled, "AGENTS.md's rocx block was edited since rocx wrote it: rocx agents --force rewrites it")
			_ => {}
		}
		if styled {
			_ = Stderr.line!("")
			_ = Stderr.line!(
				if $code == 0 {
					"  ${Term.green(styled, "No problems.")}"
				} else if $code == 2 {
					"  ${Term.yellow(styled, "Warnings, no errors.")}"
				} else {
					"  ${Term.red(styled, "Errors: see above.")}"
				},
			)
		}
		if $code == 0 {
			Ok({})
		} else {
			Err(Exit($code))
		}
	}

	## `rocx test [dir]`: the app in `dir` (or here) built from its sources as `rocx check` builds it,
	## then its expects run by the compiler its root has (`roc test main.roc`), what that says pointed
	## into the .rocx files: an app needs no `roc` of its own to test. Exit 1 when the build fails,
	## else roc test's own code (1 when an expect failed).
	test_app! : List(Str), Str => Try({}, [Exit(I32)])
	test_app! = |args, rocx| {
		ready = Dev.from_sources!(args, rocx, "rocx test")?
		match Commands.checked!(ready.tools.roc, ["test", ready.main]) {
			Ok(ran) => {
				text = Text.trim_end(ran.said)
				if !text.is_empty() {
					_ = Stdout.line!(text)
				}
				if (ran.code == 0) Ok({}) else Err(Exit(ran.code))
			}
			Err(CantStart(why)) => Dev.fail!("rocx test: ${why}")
		}
	}

	## For `rocx check` and `rocx test` (`label`): the app in the one directory `args` may name (else
	## here), a directory with routes/ and a main.roc, built from its sources as `rocx dev` builds it,
	## with its root's tools; what rocx build said is printed. `warned`: it warned (`⚠`).
	from_sources! : List(Str), Str, Str => Try({ main : Str, client : Str, tools : Tools, warned : Bool }, [Exit(I32)])
	from_sources! = |args, rocx, label| {
		given = args.first() ?? "."
		if args.len() > 1 or given.starts_with("-") {
			return Dev.fail!("usage: ${label} [dir]")
		}
		dir =
			match File.real_path!(given) {
				Ok(real) => real
				Err(_) => return Dev.fail!("${label}: no directory ${given}")
			}
		shown = {
			way = Fs.relative(Fs.cwd!(), dir)
			if (way.is_empty()) "." else way
		}
		if !File.is_dir!(Fs.join([dir, "routes"])) {
			return Dev.fail!("${label}: ${shown} has no routes/: an app is a directory with routes/ in it (rocx check -- <command> checks with a command of your own)")
		}
		main = Fs.join([dir, "main.roc"])
		if !File.exists!(main) {
			return Dev.fail!("${label}: ${shown} has no main.roc (rocx dev writes the smallest one)")
		}
		tools =
			match Dev.tools!(Hosts.root_of!(dir, rocx)) {
				Ok(found) => found
				Err(Failed(message)) => return Dev.fail!(message)
			}
		client = Fs.join([dir, "build", "client"])
		built =
			match Build.build!([dir], { client: Some(client), cwd: Fs.cwd!(), dev: Bool.True, rocx: tools.rocx }) {
				Ok(done) => done
				Err(Problem(message)) => {
					_ = Stdout.line!("Error: ${message}")
					return Err(Exit(1))
				}
			}
		said = built.said.keep_if(|line| !Dev.files_written(line))
		if !said.is_empty() {
			_ = Stdout.line!(Str.join_with(said, "\n"))
		}
		if !built.ok {
			_ = Stderr.line!("${label}: ${shown}: rocx build failed")
			return Err(Exit(1))
		}
		Ok({ main, client, tools, warned: said.any(|line| line.starts_with("⚠")) })
	}

	fail! : Str => Try(a, [Exit(I32)])
	fail! = |message| {
		_ = Stderr.line!(message)
		Err(Exit(2))
	}

	## The smallest program, for an app that has none: what every request's middleware starts from
	## (nothing); its middleware, if any, is routes/+middleware.roc's (D-103). The platform is the
	## root's (`Hosts.root_of!`), by a path from the app, as Roc wants it: `./.rocx/…` through an app's
	## link, `../../server/…` in the repo.
	write_main! : Str, Str, Str => {}
	write_main! = |dir, main, rocx| {
		pf_path = Fs.dotted(Fs.relative(dir, Fs.join([rocx, "server", "platform", "main.roc"])))
		text = [
			"## The app's program, written by `rocx dev` because there was none: it is yours to change.",
			"## `context` is what each request's middleware is given (routes/+middleware.roc runs around every",
			"## request, if the app has one); App.program also takes `plugins`, `openapi`, `database` and `cross_site`.",
			"app [program] { pf: platform \"${pf_path}\" }",
			"",
			"import Generated/App",
			"",
			"program = App.program({",
			"\tinit!: |_started| Ok({}),",
			"})",
			"",
		]
		_ = Fs.write!(main, Str.join_with(text, "\n"))
		_ = Stderr.line!("rocx dev: wrote ${Fs.relative(Fs.cwd!(), main)}, the app's program")
		{}
	}

	## A path that changed and matters: not a backup or swap file, nor a SQLite database's file (the
	## server writes its own, `data/app.db` and the WAL beside it, under the app when it runs there:
	## a change to one would restart it, again and again), nor a .roc file rocx wrote (beside its
	## .rocx, or ending with rocx's marker). The platform leaves out hidden entries and the output
	## directories.
	app_edit! : Str => Bool
	app_edit! = |path| {
		if [".swp", ".tmp", ".building", "~", ".db", ".db-shm", ".db-wal", ".db-journal"].any(|suffix| path.ends_with(suffix)) {
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
	build_app! : { dir : Str, shown : Str, main : Str, client : Str, server : Str, tools : Tools, phone : [On(Phone), Off] } => Try({}, [Failed(Str)])
	build_app! = |a| {
		match Dev.build_all!(a) {
			Ok({}) => Ok({})
			Err(Failed(message)) => {
				# The phone shows why on its red screen until the next build.
				match a.phone {
					On(phone) => Dev.phone_latest!(phone, "latest.json", Dev.epoch_ms!({}).to_str(), "", message)
					Off => {}
				}
				Err(Failed(message))
			}
		}
	}

	build_all! : { dir : Str, shown : Str, main : Str, client : Str, server : Str, tools : Tools, phone : [On(Phone), Off] } => Try({}, [Failed(Str)])
	build_all! = |a| {
		styled = Term.styled!({})
		if !styled {
			# Plain, the lines an editor reads as a build's end (editors/vscode/reports.js).
			started = Time.now_ms!({})
			Dev.build_steps!(a)?
			_ = Stderr.line!("rocx dev: built ${a.shown} in ${Dev.seconds(Time.now_ms!({}) - started)} s")
			return Ok({})
		}
		step = Term.begin!(styled, "building")
		match Dev.build_steps!(a) {
			Ok({}) => {
				Term.done_as!(step, "built ${Term.dim(styled, "in ${Term.took(Time.now_ms!({}) - step.started)}")}")
				Ok({})
			}
			Err(failed) => {
				Term.failed!(step)
				Err(failed)
			}
		}
	}

	## What `rocx dev` says first: the app, where it is served, and its database.
	banner! : Bool, Str, Str, Bool, Str => {}
	banner! = |styled, name, port, lan, main_text| {
		Term.header!(styled, "rocx dev", [name])
		_ = Stderr.line!("  ${Term.cyan(styled, "➜")}  ${Term.bold(styled, "http://localhost:${port}")}${if (lan) Term.dim(styled, "  (and on this network)") else ""}")
		database = Dev.database_said(main_text)
		if !database.is_empty() {
			_ = Stderr.line!("     ${Term.dim(styled, database)}")
		}
		_ = Stderr.line!("")
		{}
	}

	## The app's database as `rocx dev`'s banner says it, from its main.roc: `SQLite · data/app.db`
	## (App.program's default, D-105, when it names none), `Turso · …`, `Postgres · DATABASE_URL`;
	## "" when the program names it some other way.
	database_said : Str -> Str
	database_said = |text| {
		lines = Text.lines(text).map(|line| Text.trim(line)).keep_if(|line| !line.starts_with("#"))
		named = lines.keep_if(|line| line.starts_with("database:") or line.contains(" database:") or line.contains("{ database:"))
		match named.first() {
			Err(_) => if (text.contains("App.program({")) "SQLite · data/app.db" else ""
			Ok(line) => {
				value = Text.trim(line.split_on("database:").get(1) ?? "")
				quoted = (value.split_on("\"").get(1) ?? "")
				if value.starts_with("Sqlite(") {
					"SQLite · ${quoted}"
				} else if value.starts_with("Turso(") {
					"Turso · ${quoted}"
				} else if value.starts_with("Postgres") {
					"Postgres · DATABASE_URL"
				} else {
					""
				}
			}
		}
	}

	build_steps! : { dir : Str, shown : Str, main : Str, client : Str, server : Str, tools : Tools, phone : [On(Phone), Off] } => Try({}, [Failed(Str)])
	build_steps! = |a| {
		built = match Build.build!([a.dir], { client: Some(a.client), cwd: Fs.cwd!(), dev: Bool.True, rocx: a.tools.rocx }) {
			Ok(done) => done
			Err(Problem(message)) => return Err(Failed("Error: ${message}\nrocx dev: rocx build failed; fix it and save again"))
		}
		said = built.said.keep_if(|line| !Dev.files_written(line))
		if !built.ok {
			return Err(Failed("${Str.join_with(said, "\n")}\nrocx dev: rocx build failed; fix it and save again"))
		}
		if !said.is_empty() {
			Term.note!(Str.join_with(said, "\n"))
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
			match a.phone {
				On(phone) => Dev.phone_build!(phone, client_main, a.tools)?
				Off => {}
			}
		} else {
			match a.phone {
				On(_) => return Err(Failed("rocx dev --android: ${a.shown} has no pages (routes/+page.rocx): there is nothing for a phone to show"))
				Off => {}
			}
		}
		for file in $built {
			match File.rename!("${file}.building", file) {
				Ok({}) => {}
				Err(CantRename(why)) => return Err(Failed("rocx dev: ${why}"))
			}
		}
		Ok({})
	}

	# ---- A phone (D-063's dev mode) ----

	## `rocx dev --android`'s: where the app's library is built (`work`, <app>/build/android) and
	## served from (`served`, one more `--static` directory: `/rocx/android/latest.json` names the
	## latest build, `/rocx/android/app-<build>.so` is its library), the NDK's clang, adb, and the
	## platform a build is for (`fingerprint`), which the dev client checks against its own.
	Phone : { work : Str, served : Str, clang : Str, adb : Str, fingerprint : Str, rocx : Str }

	## What `--android` needs: the Android SDK ($ANDROID_HOME, else ~/Library/Android/sdk) for adb,
	## and the NDK ($ANDROID_NDK, else the clone's .tools/android-ndk from Nix, else the SDK's ndk/).
	phone! : Str, Str, Tools => Try(Phone, [Failed(Str)])
	phone! = |dir, rocx, tools| {
		sdk =
			match Env.var!("ANDROID_HOME") {
				Ok(given) => given
				Err(NotFound) => Fs.join([Env.var!("HOME") ?? "", "Library", "Android", "sdk"])
			}
		var $ndks =
			match Env.var!("ANDROID_NDK") {
				Ok(given) => [given]
				Err(NotFound) => []
			}
		for base in [Fs.join([rocx, ".tools", "android-ndk", "libexec", "android-sdk", "ndk"]), Fs.join([sdk, "ndk"])] {
			for version in Fs.entries!(base) {
				$ndks = $ndks.append(Fs.join([base, version]))
			}
		}
		var $clang = ""
		for ndk in $ndks {
			prebuilt = Fs.join([ndk, "toolchains", "llvm", "prebuilt"])
			for host in Fs.entries!(prebuilt) {
				candidate = Fs.join([prebuilt, host, "bin", "aarch64-linux-android29-clang"])
				if $clang.is_empty() and File.exists!(candidate) {
					$clang = candidate
				}
			}
		}
		if $clang.is_empty() {
			return Err(Failed("rocx dev --android: no Android NDK (set ANDROID_NDK, or see spike/native-apps/README.md, Setting up)"))
		}
		work = Fs.join([dir, "build", "android"])
		served = Fs.join([work, "static"])
		Fs.make_dirs!(Fs.join([served, "rocx", "android"]))
		Fs.make_dirs!(Fs.join([work, "stub"]))
		version =
			match Cmd.new(tools.roc).args(["version"]).output!() {
				Ok(ran) => Text.trim(ran.stdout)
				Err(_) => "unknown"
			}
		platform_dir = Fs.join([rocx, "web", "platform"])
		hashed = Dev.fnv([Fs.read_or_empty!(Fs.join([platform_dir, "main.roc"])), Fs.read_or_empty!(Fs.join([platform_dir, "Host.roc"])), version])
		Ok({ work, served, clang: $clang, adb: Fs.join([sdk, "platform-tools", "adb"]), fingerprint: "${hashed} ${version}", rocx })
	}

	## Milliseconds since the epoch: a build's name, unique across runs of rocx dev, and when it was
	## made, which the dev client compares with its own clock.
	epoch_ms! : {} => U64
	epoch_ms! = |{}| Time.now_ns!({}) // 1_000_000

	## FNV-1a, 64 bits, in hex, of `inputs` joined by NULs: native/core/build.rs's fingerprint.
	fnv : List(Str) -> Str
	fnv = |inputs| {
		start : U64
		start = 0xcbf29ce484222325
		prime : U64
		prime = 0x100000001b3
		Text.in_base(Str.join_with(inputs, "\u(0)").to_utf8().fold(start, |h, b| h.bitwise_xor(b.to_u64()).times_wrap(prime)), 16)
	}

	## The app's Roc for the phone, from the browser's copy (`client_main`): the dev backend's arm64
	## archive (Roc has no Android target; its static Linux objects link as Android's), linked by the
	## NDK's clang into a library that needs libhost.so (a stub here: the dev client's is the real
	## one, already loaded), then named the next build (`latest.next.json`), which is announced once
	## the server built with it has started (`phone_publish!`): the phone's first reads find it up.
	## Older libraries go, but the one before.
	phone_build! : Phone, Str, Tools => Try({}, [Failed(Str)])
	phone_build! = |phone, client_main, tools| {
		archive = Fs.join([phone.work, "app.a"])
		Dev.roc_build!(tools, ["--target=arm64musl", "--opt=dev", "--output=${archive}", client_main], "the phone's build")?
		stub = Fs.join([phone.work, "stub", "libhost.so"])
		if !File.exists!(stub) {
			source = Fs.join([phone.work, "stub", "stub.c"])
			_ = Fs.write!(source, "/* libhost.so's name, for the app's library to need: the dev client has the real one. */\n")
			Dev.quiet!(Cmd.new(phone.clang).args(["-shared", "-o", stub, "-Wl,-soname,libhost.so", source]), "the phone's stub libhost.so")?
		}
		build = Dev.epoch_ms!({}).to_str()
		file = "app-${build}.so"
		dir = Fs.join([phone.served, "rocx", "android"])
		before = Fs.entries!(dir).keep_if(|name| name.starts_with("app-") and name.ends_with(".so"))
		Dev.quiet!(Cmd.new(phone.clang).args(["-shared", "-o", Fs.join([dir, file]), "-Wl,--whole-archive", archive, "-Wl,--no-whole-archive", "-L", Fs.dirname(stub), "-lhost", "-Wl,-z,max-page-size=16384"]), "the phone's library")?
		Dev.phone_latest!(phone, "latest.next.json", build, file, "")
		last = before.last() ?? ""
		for name in before {
			if name != last {
				Fs.delete!(Fs.join([dir, name]))
			}
		}
		Ok({})
	}

	## Names a build for the dev client (`/rocx/android/latest.json`, or `latest.next.json` until it
	## is announced): its library, or why there is none (`error`, shown on the phone's red screen).
	phone_latest! : Phone, Str, Str, Str, Str => {}
	phone_latest! = |phone, name, build, file, error| {
		json = "{\"build\":${Text.json_string(build)},\"file\":${Text.json_string(file)},\"fingerprint\":${Text.json_string(phone.fingerprint)},\"built\":${Dev.epoch_ms!({}).to_str()},\"error\":${Text.json_string(error)}}\n"
		latest = Fs.join([phone.served, "rocx", "android", name])
		_ = Fs.write!("${latest}.building", json)
		_ = File.rename!("${latest}.building", latest)
		{}
	}

	## The next build announced (`latest.next.json` becomes `latest.json`), if there is one.
	phone_publish! : Phone => {}
	phone_publish! = |phone| {
		dir = Fs.join([phone.served, "rocx", "android"])
		next = Fs.join([dir, "latest.next.json"])
		if File.exists!(next) {
			_ = File.rename!(next, Fs.join([dir, "latest.json"]))
			{}
		}
		{}
	}

	## The phones: the dev client built if it is missing or older than what it is made from
	## (`phone_client!`). With `lan` (`--lan`, the server on this network), its page for phones on
	## Wi-Fi (`phone_page!`), as a QR code here. And the emulator, or a phone on USB, if adb sees
	## one: the server's port reversed to it (so the dev client asks http://127.0.0.1:<port>), the
	## dev client installed if it was built or isn't there, opened at the server, and crashes in its
	## log (logcat's) shown here. The dev client's own log comes over HTTP (`POST /__rocx/dev/log`,
	## shown by the server `from=phone`), on Wi-Fi as on USB.
	phone_connect! : Phone, Str, Bool => {}
	phone_connect! = |phone, port, lan| {
		say! = |line| {
			_ = Stderr.line!("rocx dev --android: ${line}")
			{}
		}
		apk = Fs.join([phone.rocx, "native", "android", "build", "dev-client", "rocx-dev.apk"])
		built = match Dev.phone_client!(phone, apk) {
			Ok(fresh) => fresh
			Err(Failed(why)) => {
				say!(why)
				return {}
			}
		}
		if lan {
			Dev.phone_page!(phone, port, apk)
		}
		devices =
			match Cmd.new(phone.adb).args(["devices"]).output!() {
				Ok(ran) => Text.lines(ran.stdout).keep_if(|line| line.ends_with("\tdevice"))
				Err(_) => []
			}
		if devices.is_empty() {
			if !lan {
				say!("no emulator or phone on USB (adb devices): for a phone on Wi-Fi, run with --lan and scan the QR code it shows")
			}
			return {}
		}
		_ = Cmd.new(phone.adb).args(["reverse", "tcp:${port}", "tcp:${port}"]).output!()
		installed =
			match Cmd.new(phone.adb).args(["shell", "pm", "path", "dev.rocx.devclient"]).output!() {
				Ok(ran) => ran.stdout.contains("package:")
				Err(_) => Bool.False
			}
		if built or !installed {
			say!("installing the dev client")
			_ = Cmd.new(phone.adb).args(["install", "-r", apk]).output!()
			{}
		}
		_ = Cmd.new(phone.adb).args(["shell", "am", "start", "-n", "dev.rocx.devclient/dev.rocx.phone.RocxActivity", "--es", "origin", "http://127.0.0.1:${port}"]).output!()
		say!("the dev client is open at http://127.0.0.1:${port}; each build reloads it")
		_ = Cmd.new(phone.adb).args(["logcat", "-T", "1", "-v", "tag", "AndroidRuntime:E", "DEBUG:F", "libc:F", "*:S"]).spawn!()
		{}
	}

	## For a phone on Wi-Fi (`--lan`): the page it scans its way to (`/rocx/android/connect.html`,
	## served with the build), which opens the dev client at this computer's address (its
	## `rocx-dev://connect` link, through Chrome's `intent:`), or downloads it (`rocx-dev.apk`, beside
	## the page) where it isn't installed; and the page's address as a QR code, here.
	phone_page! : Phone, Str, Str => {}
	phone_page! = |phone, port, apk| {
		address = Dev.lan_address!({})
		if address.is_empty() {
			_ = Stderr.line!("rocx dev --android: no address on this network found (Wi-Fi off?); set ROCX_LAN_IP")
			return {}
		}
		origin = "http://${address}:${port}"
		dir = Fs.join([phone.served, "rocx", "android"])
		if File.exists!(apk) {
			_ = Hosts.copy_if_changed!(apk, Fs.join([dir, "rocx-dev.apk"]))
			{}
		}
		app_name = Fs.basename(Fs.dirname(Fs.dirname(phone.work)))
		link = "intent://connect?origin=${Dev.percent(origin)}#Intent;scheme=rocx-dev;package=dev.rocx.devclient;S.browser_fallback_url=${Dev.percent("${origin}/rocx/android/rocx-dev.apk")};end"
		page = Str.join_with(
			[
				"<!doctype html>",
				"<html lang=\"en\">",
				"<meta charset=\"utf-8\">",
				"<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
				"<title>rocx dev</title>",
				"<style>body{font:17px/1.45 system-ui,sans-serif;margin:2rem 1.5rem;max-width:30rem;color:#1b1b1f}a{display:block;margin:1rem 0;padding:.9rem 1rem;border-radius:.7rem;background:#1b1b1f;color:#fff;text-align:center;text-decoration:none}a.second{background:#e7e7ec;color:#1b1b1f}small{color:#5d5d66}</style>",
				"<h1>rocx dev</h1>",
				"<p>${app_name}, served at ${origin}: each save on the computer shows here.</p>",
				"<a href=\"${link}\">Open it in the rocx dev client</a>",
				"<a class=\"second\" href=\"/rocx/android/rocx-dev.apk\">Install the dev client</a>",
				"<p><small>Installing asks once for leave to install apps from this browser. The dev client is for development: it runs the builds rocx dev serves.</small></p>",
				"",
			],
			"\n",
		)
		_ = Fs.write!(Fs.join([dir, "connect.html"]), page)
		url = "${origin}/rocx/android/connect.html"
		match Qr.encode(url, Medium) {
			Ok(code) => {
				_ = Stderr.line!("rocx dev --android: a phone on this Wi-Fi: scan this, or open ${url}")
				_ = Stderr.line!(Qr.terminal(code))
				{}
			}
			Err(TooLong) => {
				_ = Stderr.line!("rocx dev --android: a phone on this Wi-Fi: open ${url}")
				{}
			}
		}
	}

	## This computer's address on its network: $ROCX_LAN_IP, else the Wi-Fi's or Ethernet's (macOS's
	## `ipconfig getifaddr`, Linux's `hostname -I`); "" with none.
	lan_address! : {} => Str
	lan_address! = |{}| {
		match Env.var!("ROCX_LAN_IP") {
			Ok(given) if !given.is_empty() => return given
			_ => {}
		}
		for card in ["en0", "en1", "en2"] {
			match Cmd.new("ipconfig").args(["getifaddr", card]).output!() {
				Ok(ran) if ran.code == 0 and !Text.trim(ran.stdout).is_empty() => return Text.trim(ran.stdout)
				_ => {}
			}
		}
		match Cmd.new("hostname").args(["-I"]).output!() {
			Ok(ran) if ran.code == 0 => Text.trim(ran.stdout).split_on(" ").first() ?? ""
			_ => ""
		}
	}

	## `text` for a URL's query: every byte but letters, digits and `-._~` as `%XX`.
	percent : Str -> Str
	percent = |text| {
		var $out = []
		for byte in text.to_utf8() {
			plain = (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '.' or byte == '_' or byte == '~'
			if plain {
				$out = $out.append(byte)
			} else {
				hex = Text.hex(byte.to_u32())
				$out = $out.concat("%${if (hex.to_utf8().len() == 1) "0" else ""}${hex}".to_utf8())
			}
		}
		Str.from_utf8_lossy($out)
	}

	## The dev client's APK, built (`native/android/build.sh --dev-client`, about a minute) when it
	## is missing, older than what it is made from (native/'s sources and web/platform's header), or
	## built for another fingerprint (another compiler: `rocx-dev.fingerprint` beside it says which).
	## Whether it was built now.
	phone_client! : Phone, Str => Try(Bool, [Failed(Str)])
	phone_client! = |phone, apk| {
		made = File.modified!(apk)
		native = Fs.join([phone.rocx, "native"])
		sources = ["core/src", "android/src", "android/app", "android-dev/src"].map(|dir| Fs.join([native, dir]))
		files = ["Cargo.toml", "Cargo.lock", "core/build.rs", "core/Cargo.toml", "android/Cargo.toml", "android/build.sh", "android-dev/Cargo.toml", "android-dev/build.rs"].map(|file| Fs.join([native, file])).concat([Fs.join([phone.rocx, "web", "platform", "main.roc"]), Fs.join([phone.rocx, "web", "platform", "Host.roc"])])
		# The platform the client was built for (its fingerprint), as this rocx dev noted it when it
		# built the client: another compiler or header means another client.
		noted = Fs.join([Fs.dirname(apk), "rocx-dev.fingerprint"])
		var $fresh = made > 0 and Fs.read_or_empty!(noted) == phone.fingerprint
		for dir in sources {
			if !Hosts.not_newer!(dir, made) {
				$fresh = Bool.False
			}
		}
		for file in files {
			if File.modified!(file) > made {
				$fresh = Bool.False
			}
		}
		if $fresh {
			return Ok(Bool.False)
		}
		_ = Stderr.line!("rocx dev --android: building the dev client (native/android/build.sh --dev-client, about a minute)")
		match Cmd.new(Fs.join([native, "android", "build.sh"])).arg("--dev-client").merged!() {
			Ok(ran) if ran.code == 0 => {
				_ = Fs.write!(noted, phone.fingerprint)
				Ok(Bool.True)
			}
			Ok(ran) => Err(Failed("the dev client didn't build:\n${Text.trim_end(ran.output)}"))
			Err(CantStart(why)) => Err(Failed("the dev client didn't build: ${why}"))
		}
	}

	# ---- Building ----

	## The tools a build uses, found once: the app's root (`Hosts.root_of!`: an installed version, or
	## rocx's clone), Roc (the fork rocx builds with), Zig, and this machine's target (Hosts).
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
				Term.note!(Str.join_with(rest, "\n"))
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

	## The browser's host (Rust), built once, and again when its Rust changes (Hosts.web_host!).
	web_host! : Tools => Try({}, [Failed(Str)])
	web_host! = |tools| Hosts.web_host!(tools.rocx, tools.zig)

	## Milliseconds as seconds, with two decimals (`0.35`).
	seconds : U64 -> Str
	seconds = |ms| {
		hundredths = (ms % 1000) // 10
		"${(ms // 1000).to_str()}.${if (hundredths < 10) "0" else ""}${hundredths.to_str()}"
	}
}
expect Dev.database_said("program = App.program({\n\tinit!: |_| Ok({}),\n\tdatabase: Sqlite(\"data/shop.db\"),\n})") == "SQLite · data/shop.db"
expect Dev.database_said("program = App.program({ init!: |_| Ok({}), database: Turso(\"data/t.db\") })") == "Turso · data/t.db"
expect Dev.database_said("program = App.program({\n\tdatabase: Postgres,\n})") == "Postgres · DATABASE_URL"
expect Dev.database_said("## App.program also takes `database`\nprogram = App.program({ init!: |_| Ok({}) })") == "SQLite · data/app.db"
expect Dev.database_said("program = App.program(Config.app)") == ""
