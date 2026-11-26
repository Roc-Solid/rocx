## `rocx build <dir> --release <out> [--target arm64mac|x64mac|arm64musl|x64musl]` (D-078): the app
## built to deploy, with no Node and no `roc` of the app's own. rocx builds the app (rocx build, with
## the browser's copy in build/release/client), the server's host when it changed (an installed
## version has it built) with the database engine the app's program names alone (D-104:
## `Hosts.release_platform!`), the server optimized for speed with boxy lowering (`--specialize=no`,
## D-064; `ROCX_SPECIALIZE=yes` asks for specialization) for the target (this machine's by
## default; a musl target is a static Linux executable), and the browser's wasm optimized for size,
## its lambda sets specialized (as `rocx build --static` builds it). Then `<out>` holds what is
## deployed:
##
## - `server`, the app's executable (its migrations and its plugins' files are in it; a musl one's
##   debug info taken out, D-104);
## - `static/`, what it serves as files: the app's `static/`, and the browser's copy's (`rocx/`:
##   start.js, runtime.js, the wasm, the stylesheet), which wins where both have a file, as the
##   server's first `--static` does under `rocx dev`.
##
## It is run as `<out>/server --static <out>/static` (with PORT, DATABASE_URL, PUBLIC_URL…). The copy
## is made beside `out` and put in its place at the end: a build that fails leaves the one before.
import pf.Env
import pf.File
import pf.Stderr
import pf.Time
import Build
import Dev
import Fs
import Hosts
import Static

Release := [].{

	usage : Str
	usage = "usage: rocx build <dir> --release <out> [--target arm64mac|x64mac|arm64musl|x64musl]"

	## The targets a server can be built for (Roc's names).
	known_targets : List(Str)
	known_targets = ["arm64mac", "x64mac", "arm64musl", "x64musl"]

	## What `rocx build … --release` was asked: the app's directory, where the build goes, and the
	## target (`""`: this machine's). Paths are absolute.
	Asked : { dir : Str, out : Str, target : Str }

	## The words after `rocx build`, read, with paths from `cwd`; `Usage` says what is wrong.
	options : List(Str), Str -> Try(Asked, [Usage(Str)])
	options = |args, cwd| {
		var $out = ""
		var $target = ""
		var $dirs = []
		var $i = 0
		while $i < args.len() {
			arg = args.get($i) ?? ""
			value = args.get($i + 1) ?? ""
			if arg == "--release" or arg == "--target" {
				if value.is_empty() or value.starts_with("--") {
					return Err(Usage("rocx build ${arg}: give it a value\n${Release.usage}"))
				}
				if arg == "--release" {
					$out = value
				} else if Release.known_targets.contains(value) {
					$target = value
				} else {
					return Err(Usage("rocx build --target: one of ${Str.join_with(Release.known_targets, ", ")}, not ${value}"))
				}
				$i = $i + 2
			} else if arg == "--dev" or arg == "--static" or arg == "--client" {
				return Err(Usage("rocx build --release: a release is a production build of its own (not with ${arg})\n${Release.usage}"))
			} else if arg.starts_with("-") {
				return Err(Usage(Release.usage))
			} else {
				$dirs = $dirs.append(arg)
				$i = $i + 1
			}
		}
		if $dirs.len() != 1 or $out.is_empty() {
			return Err(Usage("rocx build --release: one directory, the app's, and where its build goes\n${Release.usage}"))
		}
		Ok({ dir: Fs.resolve(cwd, [$dirs.first() ?? "."]), out: Fs.resolve(cwd, [$out]), target: $target })
	}

	## `rocx build <dir> --release <out> …` (the words after `build`), with the home of this rocx
	## (`rocx`; the app's root, `Hosts.root_of!`, builds it): exit 2 for arguments it can't take, 1
	## when the build fails.
	run! : List(Str), Str => Try({}, [Exit(I32)])
	run! = |args, rocx| {
		cwd = Fs.cwd!()
		asked = match Release.options(args, cwd) {
			Ok(read) => read
			Err(Usage(message)) => {
				_ = Stderr.line!(message)
				return Err(Exit(2))
			}
		}
		match Release.made!(asked, cwd, rocx) {
			Ok(said) => {
				for line in said {
					_ = Stderr.line!(line)
				}
				Ok({})
			}
			Err(Failed(message)) => {
				_ = Stderr.line!("rocx build --release: ${message}")
				Err(Exit(1))
			}
		}
	}

	## The build made: what to say.
	made! : Asked, Str, Str => Try(List(Str), [Failed(Str)])
	made! = |asked, cwd, rocx| {
		shown_dir = Static.shown(cwd, asked.dir)
		if !File.is_dir!(Fs.join([asked.dir, "routes"])) {
			return Err(Failed("${shown_dir} has no routes/: give the app's directory"))
		}
		dir = Fs.real!(asked.dir)
		shown_out = Static.shown(cwd, asked.out)
		if Static.holds(asked.out, [dir, cwd]) {
			return Err(Failed("${shown_out} holds the app or this directory: the build replaces what is there, so give a directory of its own (dist)"))
		}
		if File.is_dir!(asked.out) and !Fs.entries!(asked.out).is_empty() and !File.exists!(Fs.join([asked.out, "server"])) {
			return Err(Failed("${shown_out} isn't empty and has no server: the build replaces what is there, so give a directory of its own, or empty this one"))
		}
		started = Time.now_ms!({})
		root = Hosts.root_of!(dir, rocx)
		tools = Dev.tools!(root)?
		target = if (asked.target.is_empty()) tools.target else asked.target
		main = Fs.join([dir, "main.roc"])
		if !File.exists!(main) {
			Dev.write_main!(dir, main, root)
		}
		work = Fs.join([dir, "build", "release"])
		client = Fs.join([work, "client"])
		# Each step says itself as it starts: the compiler's output is read, not shown, and the
		# server's build takes minutes.
		_ = Stderr.line!("rocx: the app's modules (rocx build)…")
		match Build.build!([dir], { client: Some(client), cwd, dev: Bool.False, rocx: root }) {
			Ok(built) if built.ok => {
				said = built.said.keep_if(|line| !Dev.files_written(line))
				if !said.is_empty() {
					_ = Stderr.line!(Str.join_with(said, "\n"))
				}
			}
			Ok(built) => return Err(Failed("${Str.join_with(built.said, "\n")}\nrocx build failed"))
			Err(Problem(message)) => return Err(Failed("Error: ${message}\nrocx build failed"))
		}
		# The host has the database engine the app's program names alone (D-104): its own platform
		# copy, put in the platform's place for this build, when that leaves an engine out.
		engines = Hosts.engines_of(Fs.read_or_empty!(main))
		_ = Stderr.line!("rocx: the server's host for ${target} (${Release.engines_said(engines)}), if it changed…")
		own = Fs.join([root, "server", "platform", "main.roc"])
		linked = Hosts.release_platform!(root, target, engines, Hosts.stage_for(root, dir, target))?
		# Roc knows a dependency by its real path, whichever way the app reached it (a `.rocx` link).
		replaced = if (linked.main == own) [] else ["--replace-dep", Fs.real!(own), linked.main]
		server = Fs.join([work, "server"])
		specialize = if (Env.var!("ROCX_SPECIALIZE") == Ok("yes")) "yes" else "no"
		_ = Stderr.line!("rocx: the server for ${target}, optimized for speed (a few minutes)…")
		built = Static.roc_build!(tools, ["--target=${target}", "--opt=speed", "--specialize=${specialize}", "--output=${server}", main].concat(replaced), "the server's build")
		# The platform's copy is linked in now: gone, so an app built once (a test's) leaves none.
		if linked.main != own {
			Fs.delete_all!(Fs.dirname(linked.main))
		}
		match built {
			Ok({}) => {}
			Err(failed) => return Err(failed)
		}
		for line in Hosts.strip_debug!(root, target, server)? {
			_ = Stderr.line!(line)
		}
		client_main = Fs.join([client, "main.roc"])
		pages = File.exists!(client_main)
		if pages {
			_ = Stderr.line!("rocx: the browser's wasm, optimized for size…")
			Dev.web_host!(tools)?
			Static.browser_build!(tools, client_main, Fs.join([client, "static", "rocx", "app.wasm"]))?
			Static.shake!(root, dir, client)?
		}
		stage = "${asked.out}.building"
		Fs.delete_all!(stage)
		Fs.make_dirs!(stage)
		app_static = Fs.join([dir, "static"])
		# The app's files first, then the browser's copy's over them: the server under `rocx dev` is
		# given the copy's first, and the first that has a file answers.
		served = (if (File.is_dir!(app_static)) [app_static] else []).concat(if (pages) [Fs.join([client, "static"])] else [])
		copies = [{ from: server, to: Fs.join([stage, "server"]) }].concat(served.map(|each| { from: each, to: Fs.join([stage, "static"]) }))
		for copy in copies {
			match File.copy!(copy.from, copy.to) {
				Ok({}) => {}
				Err(CantCopy(why)) => {
					Fs.delete_all!(stage)
					return Err(Failed(why))
				}
			}
		}
		Fs.delete_all!(asked.out)
		match File.rename!(stage, asked.out) {
			Ok({}) => {}
			Err(CantRename(why)) => return Err(Failed(why))
		}
		statics = if (served.is_empty()) "" else " --static ${Fs.join([shown_out, "static"])}"
		Ok([
			"rocx build --release: ${Fs.join([shown_out, "server"])} (${target}, ${Release.engines_said(linked.engines)})${if (served.is_empty()) "" else " and ${Fs.join([shown_out, "static"])}/"} in ${Dev.seconds(Time.now_ms!({}) - started)} s",
			"Run it as ${Fs.join([shown_out, "server"])}${statics} (PORT, DATABASE_URL, PUBLIC_URL…), behind a proxy that speaks TLS.",
		])
	}

	## The database engines a release's host has (D-104), as its message says them.
	engines_said : List(Str) -> Str
	engines_said = |engines| {
		names = engines.map(|engine| if (engine == "turso") "Turso" else if (engine == "postgres") "Postgres" else engine)
		if (engines == Hosts.all_engines) "every database engine" else Str.join_with(["SQLite"].concat(names), " and ")
	}
}

expect Release.options(["app", "--release", "dist"], "/w") == Ok({ dir: "/w/app", out: "/w/dist", target: "" })
expect Release.options(["app", "--release", "dist", "--target", "arm64musl"], "/w") == Ok({ dir: "/w/app", out: "/w/dist", target: "arm64musl" })
expect {
	read = Release.options(["app", "--release", "dist", "--target", "windows"], "/w")
	match read {
		Err(Usage(_)) => Bool.True
		Ok(_) => Bool.False
	}
}
expect {
	read = Release.options(["app", "--release"], "/w")
	match read {
		Err(Usage(_)) => Bool.True
		Ok(_) => Bool.False
	}
}
