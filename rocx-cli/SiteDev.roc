## `rocx site dev [--port 8080] [--database-url URL]` (`just dev`): the docs site (site/main.roc on
## the server platform), built and served under --dev, built again and restarted on each save, as
## `rocx dev` does an app (Dev.run!). The site's build is more than an app's: rocx itself is built
## again first when its Roc changed (the site shows rocx on itself, and the loop watches rocx-cli/,
## cli/, web/, packages/ and the server platform too); `rocx site prepare` writes what the pages
## show (Site.roc), in a process of its own, so a rocx just built does it; then the browser's wasm,
## the server's host and the server, all from Roc's dev backend; the pages show the numbers the last
## `just site` measured. The build holds site/build's lock (site/build/building.lock), as `just
## site` and the tests do.
##
## When a build had to build rocx again, the loop is rocx's old code: it stops the server and runs
## the new rocx in its place (`Cmd.exec!`), so an edit to rocx, its dev loop included, is used at once.
import pf.Cmd
import pf.Env
import pf.File
import pf.Stderr
import pf.Time
import Dev
import Fs
import Hosts
import Site
import Text

SiteDev := [].{

	run! : List(Str), Str => Try({}, [Exit(I32)])
	run! = |args, rocx| {
		usage = "usage: rocx site dev [--port 8080] [--database-url URL]"
		var $port = Env.var!("PORT") ?? "8080"
		var $database = Env.var!("DATABASE_URL") ?? ""
		var $i = 0
		while $i < args.len() {
			arg = args.get($i) ?? ""
			next = args.get($i + 1) ?? ""
			if arg == "--port" and !next.is_empty() {
				$port = next
			} else if arg == "--database-url" and !next.is_empty() {
				$database = next
			} else {
				return Dev.fail!(usage)
			}
			$i = $i + 2
		}
		target = Hosts.native_target!({})
		# rocx older than its Roc: built, and run in this one's place.
		match Hosts.rocx_binary!(rocx, target) {
			Ok(Bool.True) => return SiteDev.again!(rocx, args)
			Ok(Bool.False) => {}
			Err(Failed(message)) => {
				_ = Stderr.line!(message)
			}
		}
		tools = match Dev.tools!(rocx) {
			Ok(found) => found
			Err(Failed(message)) => return Dev.fail!(message)
		}
		site = Fs.join([rocx, "site"])
		out = Fs.join([site, "build"])
		client_static = Fs.join([out, "client", "static"])
		database = if ($database.is_empty()) [] else ["--database-url", $database]
		var $watch = []
		for dir in ["site", "packages", "web", "rocx-cli", "cli", "server/platform", "server/host"] {
			path = Fs.join([rocx, dir])
			if File.is_dir!(path) {
				$watch = $watch.append(path)
			}
		}
		Dev.run!({
			label: "rocx site",
			base: rocx,
			watch: $watch,
			skip: ["build", "dist", "Generated", "target", "targets", "node_modules"],
			edited!: |path| SiteDev.edited!(rocx, path),
			build!: |{}| SiteDev.build!(tools, args),
			serve: Cmd.new(Fs.join([out, "server"])).args(["--port", $port, "--static", Fs.join([site, "static"]), "--static", client_static, "--context-file", Fs.join([out, "context.txt"])].concat(database).append("--dev")),
			check: Nothing,
		})
	}

	## This program again, as rocx is now, with the same arguments; the server is stopped first by
	## the platform (a child still running gets SIGTERM before the program is replaced).
	again! : Str, List(Str) => Try({}, [Exit(I32)])
	again! = |rocx, args| {
		_ = Stderr.line!("rocx site: rocx was built again; running it")
		match Cmd.new(Fs.join([rocx, "bin", "rocx"])).args(["site", "dev"].concat(args)).exec!() {
			Ok({}) => Ok({})
			Err(CantStart(why)) => Dev.fail!("rocx site: ${why}")
		}
	}

	## A source file that changed: the site's, rocx's, a platform's or a package's (.rocx, .roc,
	## .zig, .rs, .c, .js, .mjs, .css, .svg, .toml), not a test's, and not one the build writes
	## itself: a .roc rocx wrote (beside its .rocx, or ending with its marker) or the server
	## platform's copy of a module both platforms have.
	edited! : Str, Str => Bool
	edited! = |rocx, path| {
		rel = Fs.relative(rocx, path)
		source = [".rocx", ".roc", ".zig", ".rs", ".c", ".js", ".mjs", ".css", ".svg", ".toml"].any(|ext| rel.ends_with(ext))
		if !source or rel.ends_with(".tmp") or rel.starts_with("test/") or rel.contains("/test/") {
			return Bool.False
		}
		if rel.ends_with(".roc") and (!File.exists!(path) or Dev.rocx_wrote!(path)) {
			return Bool.False
		}
		!Hosts.shared_modules.any(|name| rel == "server/platform/${name}.roc")
	}

	## Everything `just site` builds, from Roc's dev backend, and no measuring; holding site/build's
	## lock while it writes there.
	build! : Dev.Tools, List(Str) => Try({}, [Failed(Str)])
	build! = |tools, args| {
		started = Time.now_ms!({})
		rocx = tools.rocx
		match Hosts.rocx_binary!(rocx, tools.target) {
			Ok(Bool.True) => {
				_ = SiteDev.again!(rocx, args)
				return Err(Failed("rocx site: couldn't run the rocx just built"))
			}
			Ok(Bool.False) => {}
			Err(Failed(message)) => return Err(Failed("${message}\nrocx site: the build failed; fix it and save again"))
		}
		match Site.acquire!(rocx, "a dev build") {
			Ok({}) => {}
			Err(Problem(message)) => return Err(Failed("rocx site: ${message}"))
		}
		built = SiteDev.build_locked!(tools)
		Site.release!(rocx)
		match built {
			Ok({}) => {
				_ = Stderr.line!("rocx site: built in ${Dev.seconds(Time.now_ms!({}) - started)} s (dev backend; numbers from the last `just site`)")
				Ok({})
			}
			Err(Failed(message)) => Err(Failed("${Text.trim_end(message)}\nrocx site: the build failed; fix it and save again"))
		}
	}

	build_locked! : Dev.Tools => Try({}, [Failed(Str)])
	build_locked! = |tools| {
		rocx = tools.rocx
		site = Fs.join([rocx, "site"])
		out = Fs.join([site, "build"])
		# What the pages show, and the site's .rocx as Roc: rocx just built, in a process of its own.
		prepared =
			match Cmd.new(Fs.join([rocx, "bin", "rocx"])).args(["site", "prepare", "--dev", "--no-lock"]).cwd(rocx).merged!() {
				Ok(ran) => ran
				Err(CantStart(why)) => return Err(Failed("rocx site prepare: ${why}"))
			}
		if prepared.code != 0 {
			return Err(Failed(prepared.output))
		}
		if !Text.trim(prepared.output).is_empty() {
			_ = Stderr.line!(Text.trim_end(prepared.output))
		}
		Dev.web_host!(tools)?
		wasm = Fs.join([out, "client", "static", "rocx", "app.wasm"])
		Dev.roc_build!(tools, ["--target=wasm32", "--opt=dev", "--output=${wasm}.building", Fs.join([out, "client", "main.roc"])], "the browser's build")?
		match Hosts.server_host!(rocx, tools.target) {
			Ok({}) => {}
			Err(Failed(message)) => return Err(Failed("${Text.trim_end(message)}\nrocx site: the server's host didn't build"))
		}
		server = Fs.join([out, "server"])
		Dev.roc_build!(tools, ["--target=${tools.target}", "--opt=dev", "--output=${server}.building", Fs.join([site, "main.roc"])], "the server's build")?
		for file in [wasm, server] {
			match File.rename!("${file}.building", file) {
				Ok({}) => {}
				Err(CantRename(why)) => return Err(Failed("rocx site: ${why}"))
			}
		}
		# The facts the last measured build saved, marked as a dev build's: its own wasm, from the dev
		# backend, is neither as small nor as fast as what was measured.
		measured = Text.lines(Fs.read_or_empty!(Fs.join([out, "facts.txt"]))).keep_if(|line| !line.is_empty() and !line.starts_with("dev="))
		Site.write_if_changed!(Fs.join([out, "context.txt"]), Str.join_with(measured.append("dev=yes"), "\n"))
		Ok({})
	}
}
