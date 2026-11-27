## What rocx builds apps with, from the clone it is in (`rocx`, the repo's root), as
## server/build.mjs finds and builds them for the repo's JavaScript: the Roc compiler, Zig, this
## machine's target, and the server platform's host (Rust), built and put where Roc links it.
import pf.Cmd
import pf.Env
import pf.File
import pf.Stderr
import pf.Time
import Fs
import Text

Hosts := [].{

	## The modules both platforms have: the browser's platform's (web/platform), copied into the
	## server platform, so the same code compiles on both (server/build.mjs's SHARED_MODULES, which
	## this list follows).
	shared_modules : List(Str)
	shared_modules = ["Html", "Solid", "Store", "Repeat", "Loading", "Errored", "Call", "Server", "Context", "Endpoint", "FormBody", "Middleware", "Events", "OpenApi", "Router", "HttpStatusCode", "Transition", "Browser", "Submission", "Submissions", "Title", "Channel", "Search", "Leave"]

	## Where rocx is: the folder above the one its binary is in (`bin/rocx`), its links followed. A
	## clone of the repo, or an installed version (`~/.rocx/versions/<v>`, with `VERSION` in it).
	home! : {} => Str
	home! = |{}| {
		path = Env.exe_path!({})
		if (path.is_empty()) Fs.cwd!() else Fs.dirname(Fs.dirname(Fs.real!(path)))
	}

	## The server's `--env-file .env` under `rocx dev` (D-098), for its server and its check: the
	## `.env` in the folder it runs in, when there is one and the flags the server is given (`flags`,
	## what follows `--`) name no file of their own. The server reads none unless one is named, so
	## only development asks for it; a test's server, CI's and production's never read one.
	env_file! : List(Str) => List(Str)
	env_file! = |flags| Hosts.env_file(flags, Fs.is_file!(".env"))

	## `env_file!`'s flags, `here` saying whether there is a `.env`.
	env_file : List(Str), Bool -> List(Str)
	env_file = |flags, here| if (here and !flags.any(|flag| flag == "--env-file" or flag.starts_with("--env-file="))) ["--env-file", ".env"] else []

	## The root an app at `dir` is built with: its `.rocx` (a link to an installed version, or to a
	## clone), when it has one; else `rocx`, the home of the rocx running (so an app inside the repo,
	## whose headers reach the platform by `../`, needs none). Not resolved: its paths go through the
	## link, as the app's headers do (`./.rocx/server/platform/main.roc`), so the compiler sees one
	## platform where the app and its packages name it.
	root_of! : Str, Str => Str
	root_of! = |dir, rocx| {
		linked = Fs.join([dir, ".rocx"])
		if (File.is_dir!(linked)) linked else rocx
	}

	## Whether `rocx` (a home) is a clone of the repo, which rocx can build itself in and has the
	## site in: its own sources are there. An installed version has its builds alone.
	is_clone! : Str => Bool
	is_clone! = |rocx| File.exists!(Fs.join([rocx, "rocx-cli", "main.roc"]))

	## The Roc compiler, as the file it links to: the root's own (`bin/roc`, in an installed
	## version), else the one `just setup` links in .tools (the fork rocx builds with; the root's, then
	## the clone's this rocx was built in), else $ROC; never the `roc` on PATH, which may lack the
	## fork's fixes.
	roc! : Str => Try(Str, [Failed(Str)])
	roc! = |root| {
		home = Hosts.home!({})
		for found in [Fs.join([root, "bin", "roc"]), Fs.join([root, ".tools", "roc-active"]), Fs.join([home, ".tools", "roc-active"])] {
			if File.exists!(found) {
				return Ok(Fs.real!(found))
			}
		}
		match Env.var!("ROC") {
			Ok(given) => Ok(given)
			Err(NotFound) => Err(Failed("no Roc compiler: none in ${root}/bin, and no .tools/roc-active: run `just setup` in a clone (or set ROC)"))
		}
	}

	## Roc's name for this machine's target: `arm64mac`, `x64mac`, `arm64musl`, `x64musl`.
	native_target! : {} => Str
	native_target! = |{}| {
		said =
			match Cmd.new("uname").args(["-sm"]).output!() {
				Ok(ran) => ran.stdout
				Err(_) => ""
			}
		arch = if (said.contains("arm64") or said.contains("aarch64")) "arm64" else "x64"
		if (said.starts_with("Darwin")) "${arch}mac" else "${arch}musl"
	}

	## Rust's name for one of Roc's targets.
	rust_target : Str -> Str
	rust_target = |target|
		match target {
			"arm64mac" => "aarch64-apple-darwin"
			"x64mac" => "x86_64-apple-darwin"
			"arm64musl" => "aarch64-unknown-linux-musl"
			_ => "x86_64-unknown-linux-musl"
		}

	## Zig: the system's (`zig` on PATH, e.g. from Nix) when it is the Justfile's `zig_version`, else
	## the one `just setup` put in .tools.
	zig! : Str => Str
	zig! = |rocx| {
		pinned =
			Text.lines(Fs.read_or_empty!(Fs.join([rocx, "Justfile"])))
				.keep_if(|line| line.starts_with("zig_version := \""))
				.first()
				?? ""
		system =
			match Cmd.new("zig").args(["version"]).output!() {
				Ok(ran) if ran.code == 0 => Text.trim(ran.stdout)
				_ => ""
			}
		if (!system.is_empty() and pinned == "zig_version := \"${system}\"") "zig" else Fs.join([rocx, ".tools", "zig", "zig"])
	}

	## Copies the shared modules into the server platform where they differ.
	sync_shared! : Str => {}
	sync_shared! = |rocx| {
		for name in Hosts.shared_modules {
			text = Fs.read_or_empty!(Fs.join([rocx, "web", "platform", "${name}.roc"]))
			to = Fs.join([rocx, "server", "platform", "${name}.roc"])
			if !Fs.exists!(to) or Fs.read_or_empty!(to) != text {
				_ = Fs.write!(to, text)
			}
		}
	}

	## Whether `program` runs (`program --version`).
	on_path! : Str => Bool
	on_path! = |program|
		match Cmd.new(program).arg("--version").output!() {
			Ok(ran) => ran.code == 0
			Err(_) => Bool.False
		}

	## `command` with cargo's environment: the system's toolchain (the cargo on PATH) if there is one,
	## else the one in .tools/rust. A musl target takes the system's only with rustup on PATH too, to
	## add the target.
	rust_env! : Cmd, Str, Bool => Cmd
	rust_env! = |command, rocx, musl| {
		tools = Fs.join([rocx, ".tools", "rust"])
		system = Hosts.on_path!("cargo") and (!musl or Hosts.on_path!("rustup"))
		if system or !File.exists!(Fs.join([tools, "cargo", "bin", "cargo"])) {
			command
		} else {
			path = Env.var!("PATH") ?? ""
			command
				.env("RUSTUP_HOME", Fs.join([tools, "rustup"]))
				.env("CARGO_HOME", Fs.join([tools, "cargo"]))
				.env("PATH", "${Fs.join([tools, "cargo", "bin"])}:${path}")
		}
	}

	## A command that must succeed: its output, or why it failed (server/build.mjs's `run`).
	run! : Cmd, Str => Try(Str, [Failed(Str)])
	run! = |command, shown| {
		match command.output!() {
			Ok(ran) if ran.code == 0 => Ok(ran.stdout)
			Ok(ran) => Err(Failed("${shown} failed:\n${ran.stdout}${ran.stderr}"))
			Err(CantStart(why)) => Err(Failed("${shown} failed: ${why}"))
		}
	}

	## Copies `from` to `to` unless `to` is as new already, whole or not at all (another build may be
	## linking against it right now): through a file beside it, renamed into place.
	copy_if_changed! : Str, Str => Try({}, [Failed(Str)])
	copy_if_changed! = |from, to| {
		if File.exists!(to) and File.modified!(from) <= File.modified!(to) {
			return Ok({})
		}
		Fs.make_dirs!(Fs.dirname(to))
		partial = "${to}.${Env.pid!({}).to_str()}.tmp"
		match File.copy!(from, partial) {
			Ok({}) => {}
			Err(CantCopy(why)) => return Err(Failed(why))
		}
		match File.rename!(partial, to) {
			Ok({}) => Ok({})
			Err(CantRename(why)) => Err(Failed(why))
		}
	}

	## The server platform's host for `target`, built (cargo does nothing when nothing changed) and
	## put where Roc links it (server/platform/targets/<target>/libhost.a); a musl target's C
	## runtime beside it, from Rust's own musl target, its C compiled by Zig.
	##
	## An installed version has no host's Rust (`server/host`), only the libraries built for it: those
	## are linked as they are, and a target it has none for is an error.
	server_host! : Str, Str => Try({}, [Failed(Str)])
	server_host! = |rocx, target| {
		host_dir = Fs.join([rocx, "server", "host"])
		if !File.is_dir!(host_dir) {
			library = Fs.join([rocx, "server", "platform", "targets", target, "libhost.a"])
			if File.exists!(library) {
				return Ok({})
			}
			built = Fs.entries!(Fs.join([rocx, "server", "platform", "targets"]))
			return Err(Failed("no server host for ${target} in ${rocx}: this version of rocx has ${if (built.is_empty()) "none" else Str.join_with(built, ", ")}"))
		}
		Hosts.sync_shared!(rocx)
		triple = Hosts.rust_target(target)
		musl = target.ends_with("musl")
		dir = Fs.join([rocx, "server", "platform", "targets", target])
		# Nothing under server/host newer than the library Roc links: cargo would do nothing, and
		# takes a tenth of a second to say so, on every build.
		if !musl and Hosts.not_newer!(host_dir, File.modified!(Fs.join([dir, "libhost.a"]))) {
			return Ok({})
		}
		Hosts.cargo_host!(rocx, target, [])?
		Hosts.copy_if_changed!(Fs.join([host_dir, "target", triple, "release", "librocx_server_host.a"]), Fs.join([dir, "libhost.a"]))?
		if musl {
			Hosts.musl_runtime!(rocx, triple, dir)?
		}
		Ok({})
	}

	## `cargo build --release --target <target's triple>` in server/host, with `args` after it; for a
	## musl target, its C compiled by Zig and Rust's target added first.
	cargo_host! : Str, Str, List(Str) => Try({}, [Failed(Str)])
	cargo_host! = |rocx, target, args| {
		triple = Hosts.rust_target(target)
		musl = target.ends_with("musl")
		var $cargo = Hosts.rust_env!(Cmd.new("cargo").args(["build", "--release", "--target", triple].concat(args)).cwd(Fs.join([rocx, "server", "host"])), rocx, musl)
		if musl {
			zig = Hosts.zig!(rocx)
			under = Str.join_with(triple.split_on("-"), "_")
			$cargo =
				$cargo
					.env("CC_${under}", "${zig} cc -target ${triple.replace_each("-unknown-", "-")}")
					.env("AR_${under}", "${zig} ar")
					.env("CRATE_CC_NO_DEFAULTS", "1")
					.env("CFLAGS_${under}", "-O2 -fPIC -fno-sanitize=all")
					# A musl host is linked into what is deployed (`--release`, `--image`), never run
					# under `rocx dev`: no debug info of its own crates (the symbols stay, for a
					# backtrace's names). It was 140 MB of a 180 MB server. Rust's std brings its own,
					# which `strip_debug!` takes out of the server (D-104).
					.env("CARGO_PROFILE_RELEASE_DEBUG", "0")
			_ = Hosts.run!(Hosts.rust_env!(Cmd.new("rustup").args(["target", "add", triple]), rocx, musl), "rustup target add ${triple}")?
		}
		_ = Hosts.run!($cargo, Str.join_with(["cargo build --release --target ${triple}"].concat(args), " "))?
		Ok({})
	}

	## A musl target's C runtime, from Rust's own musl target (`triple`), into `dir` beside its host.
	musl_runtime! : Str, Str, Str => Try({}, [Failed(Str)])
	musl_runtime! = |rocx, triple, dir| {
		sysroot = Text.trim(Hosts.run!(Hosts.rust_env!(Cmd.new("rustc").args(["--print", "sysroot"]), rocx, Bool.True), "rustc --print sysroot")?)
		crt = Fs.join([sysroot, "lib", "rustlib", triple, "lib", "self-contained"])
		for file in ["rcrt1.o", "libunwind.a", "libc.a"] {
			Hosts.copy_if_changed!(Fs.join([crt, file]), Fs.join([dir, file]))?
		}
		Ok({})
	}

	## The database engines a server's host can have besides SQLite, which every host has: server/host's
	## cargo features (D-104). `rocx dev`'s host, the tests' and an installed version's have both.
	all_engines : List(Str)
	all_engines = ["postgres", "turso"]

	## The engines a release of the app whose main.roc is `text` needs (D-104): none for
	## `database: Sqlite(…)` or an `App.program({ … })` that names none (its default, D-105; SQLite is
	## in every host), Turso's for `database: Turso(…)`, Postgres's for `database: Postgres`; all of
	## them when the program names its database some other way (a value, a call), names two, or is
	## given its record from elsewhere (`App.program(config)`). Comment lines don't count.
	engines_of : Str -> List(Str)
	engines_of = |text| {
		var $named = []
		for line in Text.lines(text) {
			trimmed = Text.trim(line)
			pieces = trimmed.split_on("database:")
			var $i = 1
			while !trimmed.starts_with("#") and $i < pieces.len() {
				before = (pieces.get($i - 1) ?? "").to_utf8()
				# `sql_database:` and the like are other fields.
				if before.is_empty() or !Text.is_word(Text.at(before, before.len() - 1)) {
					value = Text.trim(pieces.get($i) ?? "")
					engines =
						if value.starts_with("Sqlite(") {
							[]
						} else if value.starts_with("Turso(") {
							["turso"]
						} else if value == "Postgres" or value == "Postgres," or value.starts_with("Postgres ") or value.starts_with("Postgres,") {
							["postgres"]
						} else {
							Hosts.all_engines
						}
					$named = $named.append(engines)
				}
				$i = $i + 1
			}
		}
		match $named.first() {
			Err(_) => if (text.contains("App.program({")) [] else Hosts.all_engines
			Ok(first) => if ($named.all(|each| each == first)) first else Hosts.all_engines
		}
	}

	## The server platform's `main.roc` a release for `target` links with, and the engines its host
	## has (D-104): the platform's own, its host built with every engine (`server_host!`), when
	## `engines` is all of them, or this is an installed version whose bundle has no host for them;
	## else a copy of the platform's modules in `stage`, with a host of `engines` alone in its
	## `targets/<target>/` (a clone's built by cargo with those features, in a target directory of its
	## own beside the full host's; an installed version's from its bundle,
	## server/platform/engines/<variant>/<target>/), for `roc build --replace-dep` to put in the
	## platform's place. The platform's own targets/ stay as they are, so a `rocx dev` or a test
	## linking against them meanwhile is unaffected. `stage` is `stage_for`'s.
	release_platform! : Str, Str, List(Str), Str => Try({ main : Str, engines : List(Str) }, [Failed(Str)])
	release_platform! = |rocx, target, engines, stage| {
		modules = Fs.join([rocx, "server", "platform"])
		host_dir = Fs.join([rocx, "server", "host"])
		full = { main: Fs.join([modules, "main.roc"]), engines: Hosts.all_engines }
		# `engines` may name `images` too (D-125: an app that writes enhanced:src), which the full host has.
		if engines == Hosts.all_engines or engines == Hosts.all_engines.concat(["images"]) {
			Hosts.server_host!(rocx, target)?
			return Ok(full)
		}
		triple = Hosts.rust_target(target)
		variant = if (engines.is_empty()) "sqlite" else Str.join_with(engines, "-")
		inputs = Fs.join([stage, "targets", target])
		if !File.is_dir!(host_dir) {
			# An installed version: the host its bundle carries for these engines (release/pack.sh, a
			# Linux target's SQLite alone or with Postgres), else its full one (a Turso app's: Turso's
			# alone is barely smaller).
			prebuilt = Fs.join([modules, "engines", variant, target, "libhost.a"])
			if !File.exists!(prebuilt) {
				Hosts.server_host!(rocx, target)?
				return Ok(full)
			}
			Hosts.staged!(modules, stage, inputs, prebuilt)?
			for file in ["rcrt1.o", "libunwind.a", "libc.a"] {
				Hosts.copy_if_changed!(Fs.join([modules, "targets", target, file]), Fs.join([inputs, file]))?
			}
			return Ok({ main: Fs.join([stage, "main.roc"]), engines })
		}
		Hosts.sync_shared!(rocx)
		target_dir = Fs.join([host_dir, "target", "engines-${variant}"])
		features = if (engines.is_empty()) [] else ["--features", Str.join_with(engines, ",")]
		Hosts.cargo_host!(rocx, target, ["--no-default-features", "--target-dir", target_dir].concat(features))?
		Hosts.staged!(modules, stage, inputs, Fs.join([target_dir, triple, "release", "librocx_server_host.a"]))?
		if target.ends_with("musl") {
			Hosts.musl_runtime!(rocx, triple, inputs)?
		}
		Ok({ main: Fs.join([stage, "main.roc"]), engines })
	}

	## The platform's modules copied into `stage`, afresh, and `library` as the host in `inputs`
	## (its `targets/<target>/`).
	staged! : Str, Str, Str, Str => Try({}, [Failed(Str)])
	staged! = |modules, stage, inputs, library| {
		Fs.delete_all!(stage)
		Fs.make_dirs!(inputs)
		for name in Fs.entries!(modules) {
			if name.ends_with(".roc") {
				match File.copy!(Fs.join([modules, name]), Fs.join([stage, name])) {
					Ok({}) => {}
					Err(CantCopy(why)) => return Err(Failed(why))
				}
			}
		}
		Hosts.copy_if_changed!(library, Fs.join([inputs, "libhost.a"]))
	}

	## Where a release of the app in `dir` for `target` copies the platform (D-104): in the system's
	## temporary directory (`tmp`, $TMPDIR's), outside the app, whose files rocx's checks and editors
	## read, and outside rocx, which an installed version keeps read-only; one for each app and
	## target, deleted once the server is linked.
	stage_for : Str, Str, Str -> Str
	stage_for = |tmp, dir, target| {
		key = Text.cut(Crypto.SHA256.hash(dir.to_utf8()).to_hex().to_utf8(), 0, 12)
		Fs.join([tmp, "rocx-release-platforms", "${Fs.basename(dir)}-${key}-${target}"])
	}

	## Takes the debug info out of `server`, a release's executable for a musl target, with LLVM's
	## `llvm-strip --strip-debug` (D-104): Rust's std brings its own into the host (12 MB of it), which
	## nothing in a container reads; the symbols stay, for a backtrace's names. A Mac's executable has
	## none (it stays in the objects it was linked from), and an installed version's hosts are
	## stripped already (release/hosts.sh). Its llvm-strip is rustup's (`llvm-tools`, added when
	## missing), else $LLVM_STRIP or one on PATH; with none, what to say instead.
	strip_debug! : Str, Str, Str => Try(List(Str), [Failed(Str)])
	strip_debug! = |rocx, target, server| {
		if !target.ends_with("musl") or !File.is_dir!(Fs.join([rocx, "server", "host"])) {
			return Ok([])
		}
		strip = match Hosts.llvm_strip!(rocx) {
			Ok(found) => found
			Err(NotFound) => return Ok(["rocx build: the server keeps its debug info, as there is no llvm-strip: `rustup component add llvm-tools`, or set LLVM_STRIP"])
		}
		_ = Hosts.run!(Cmd.new(strip).args(["--strip-debug", server]), "llvm-strip --strip-debug")?
		Ok([])
	}

	## LLVM's llvm-strip: $LLVM_STRIP; else rustup's (the `llvm-tools` component, added if it can be:
	## its LLVM is the one the hosts were compiled with); else one on PATH.
	llvm_strip! : Str => Try(Str, [NotFound])
	llvm_strip! = |rocx| {
		match Env.var!("LLVM_STRIP") {
			Ok(given) if !given.is_empty() => return Ok(given)
			_ => {}
		}
		match Hosts.rustup_llvm_strip!(rocx) {
			Ok(found) => return Ok(found)
			Err(NotFound) => {}
		}
		_ = Hosts.run!(Hosts.rust_env!(Cmd.new("rustup").args(["component", "add", "llvm-tools"]), rocx, Bool.True), "rustup component add llvm-tools") ?? ""
		match Hosts.rustup_llvm_strip!(rocx) {
			Ok(found) => Ok(found)
			Err(NotFound) => if (Hosts.on_path!("llvm-strip")) Ok("llvm-strip") else Err(NotFound)
		}
	}

	## rustup's llvm-strip (`llvm-tools`), in the sysroot of the Rust a musl host is built with.
	rustup_llvm_strip! : Str => Try(Str, [NotFound])
	rustup_llvm_strip! = |rocx| {
		sysroot = Text.trim(Hosts.run!(Hosts.rust_env!(Cmd.new("rustc").args(["--print", "sysroot"]), rocx, Bool.True), "rustc --print sysroot") ?? "")
		rustlib = Fs.join([sysroot, "lib", "rustlib"])
		for host in Fs.entries!(rustlib) {
			found = Fs.join([rustlib, host, "bin", "llvm-strip"])
			if File.exists!(found) {
				return Ok(found)
			}
		}
		Err(NotFound)
	}

	## The browser's host (web/host, Rust with no std), built when its Rust is newer than the object
	## Roc links each app's wasm with (web/platform/targets/wasm32/host.wasm): cargo's static library
	## for wasm32, made that object by `zig wasm-ld -r`, every object in it kept (Roc's link takes
	## what the app uses), as server/build.mjs's buildWebHost does. An installed version has no host's
	## Rust, only the object.
	web_host! : Str, Str => Try({}, [Failed(Str)])
	web_host! = |rocx, zig| {
		host_dir = Fs.join([rocx, "web", "host"])
		object = Fs.join([rocx, "web", "platform", "targets", "wasm32", "host.wasm"])
		if !File.is_dir!(host_dir) {
			if File.exists!(object) {
				return Ok({})
			}
			return Err(Failed("no browser host in ${rocx}: no web/host, and no web/platform/targets/wasm32/host.wasm"))
		}
		# Its Rust, and rocx-memory's (web/memory), which it shares with the phone's host.
		built = File.modified!(object)
		if Hosts.not_newer!(host_dir, built) and Hosts.not_newer!(Fs.join([rocx, "web", "memory"]), built) {
			return Ok({})
		}
		triple = "wasm32-unknown-unknown"
		sysroot = Text.trim(Hosts.run!(Hosts.rust_env!(Cmd.new("rustc").args(["--print", "sysroot"]), rocx, Bool.False), "rustc --print sysroot")?)
		if !File.is_dir!(Fs.join([sysroot, "lib", "rustlib", triple])) {
			_ = Hosts.run!(Hosts.rust_env!(Cmd.new("rustup").args(["target", "add", triple]), rocx, Bool.False), "rustup target add ${triple}")?
		}
		_ = Hosts.run!(Hosts.rust_env!(Cmd.new("cargo").args(["build", "--release", "--target", triple]).cwd(host_dir), rocx, Bool.False), "cargo build --release --target ${triple} (web/host)")?
		Fs.make_dirs!(Fs.dirname(object))
		# Whole or not at all: another build may be linking against it right now.
		partial = "${object}.${Env.pid!({}).to_str()}.tmp"
		library = Fs.join([host_dir, "target", triple, "release", "librocx_web_host.a"])
		_ = Hosts.run!(Cmd.new(zig).args(["wasm-ld", "-r", "--whole-archive", library, "-o", partial]), "zig wasm-ld -r (web/host)")?
		match File.rename!(partial, object) {
			Ok({}) => Ok({})
			Err(CantRename(why)) => Err(Failed(why))
		}
	}

	## Whether nothing under `dir` (but its build's `target/`) changed after `time` (nanoseconds since
	## the epoch; 0, never built, is always older).
	not_newer! : Str, U64 => Bool
	not_newer! = |dir, time| {
		if time == 0 {
			return Bool.False
		}
		for name in Fs.entries!(dir) {
			path = Fs.join([dir, name])
			if name != "target" and !name.starts_with(".") {
				if File.is_dir!(path) {
					if !Hosts.not_newer!(path, time) {
						return Bool.False
					}
				} else if File.modified!(path) > time {
					return Bool.False
				}
			}
		}
		Bool.True
	}

	## The CLI platform's host (cli/host), which rocx itself is built on, built and put where Roc links
	## it when its Rust is newer than the library (server/build.mjs's buildCliHost).
	cli_host! : Str, Str => Try({}, [Failed(Str)])
	cli_host! = |rocx, target| {
		if Hosts.cli_host_fresh!(rocx, target) {
			return Ok({})
		}
		host_dir = Fs.join([rocx, "cli", "host"])
		library = Fs.join([rocx, "cli", "platform", "targets", target, "libhost.a"])
		triple = Hosts.rust_target(target)
		_ = Hosts.run!(Hosts.rust_env!(Cmd.new("cargo").args(["build", "--release", "--target", triple]).cwd(host_dir), rocx, target.ends_with("musl")), "cargo build --release --target ${triple}")?
		Fs.make_dirs!(Fs.dirname(library))
		# Copied whatever its time: the library's time says when its sources were last built.
		partial = "${library}.${Env.pid!({}).to_str()}.tmp"
		match File.copy!(Fs.join([host_dir, "target", triple, "release", "librocx_cli_host.a"]), partial) {
			Ok({}) => {}
			Err(CantCopy(why)) => return Err(Failed(why))
		}
		match File.rename!(partial, library) {
			Ok({}) => Ok({})
			Err(CantRename(why)) => Err(Failed(why))
		}
	}

	## Whether the CLI platform's host for `target` is there and newer than its Rust.
	cli_host_fresh! : Str, Str => Bool
	cli_host_fresh! = |rocx, target| Hosts.not_newer!(Fs.join([rocx, "cli", "host"]), File.modified!(Fs.join([rocx, "cli", "platform", "targets", target, "libhost.a"])))

	## rocx itself (bin/rocx), built again from its Roc when it is older than rocx-cli/ (but its
	## JavaScript), the CLI platform's modules or its host, or was built with another optimization
	## (`ROCX_OPT`: `dev`, else `speed`), as server/build.mjs's rocxBinary does, and taking the same
	## lock (bin/.rocx-building), since the tests build it in several processes at once; the host
	## too is built holding it, or each would run cargo and copy its library while another's cargo
	## was writing it: whether it was built. It says on stderr that it builds (a minute or so under
	## --opt=speed) or waits, since `just dev` and every recipe wait on it before anything else.
	rocx_binary! : Str, Str => Try(Bool, [Failed(Str)])
	rocx_binary! = |rocx, target| {
		out = Fs.join([rocx, "bin", "rocx"])
		opt = if (Env.var!("ROCX_OPT") == Ok("dev")) "dev" else "speed"
		if Hosts.rocx_fresh!(rocx, target, opt) {
			return Ok(Bool.False)
		}
		lock = Fs.join([rocx, "bin", ".rocx-building"])
		var $waiting = Bool.True
		var $told = Bool.False
		while $waiting {
			match File.create_new!(lock, "${Env.pid!({}).to_str()}") {
				Ok({}) => {
					$waiting = Bool.False
				}
				Err(CantWrite(why)) => return Err(Failed("rocx: can't take bin/.rocx-building: ${why}"))
				Err(Exists) => {
					# Another process is building it: wait for it. A lock whose process is gone (a build
					# stopped with ^C) is taken at once; one with no pid in it (server/build.mjs makes a
					# directory) after ten minutes.
					holder = U32.from_str(Text.trim(Fs.read_or_empty!(lock))) ?? 0
					if holder > 0 and !Env.alive!(holder) {
						_ = File.delete!(lock)
					} else if File.modified!(lock) > 0 and Time.now_ns!({}) - File.modified!(lock) > 10 * 60 * 1_000_000_000 {
						_ = File.delete!(lock)
					} else {
						if !$told {
							who = if (holder > 0) "process ${holder.to_str()}" else "another process"
							_ = Stderr.line!("rocx: ${who} is building bin/rocx; waiting for it")
							$told = Bool.True
						}
						Time.sleep!(200)
					}
					if Hosts.rocx_fresh!(rocx, target, opt) {
						return Ok(Bool.False)
					}
				}
			}
		}
		started = Time.now_ms!({})
		_ = Stderr.line!("rocx: building bin/rocx again, as its sources changed (--opt=${opt}: a minute or so)")
		built = Hosts.build_locked!(rocx, target, out, opt)
		_ = File.delete!(lock)
		match built {
			Ok(Bool.True) => {
				_ = Stderr.line!("rocx: built bin/rocx in ${((Time.now_ms!({}) - started) // 1000).to_str()} s")
			}
			_ => {}
		}
		built
	}

	## Holding bin/.rocx-building: the CLI platform's host, then rocx, unless another process built
	## it meanwhile.
	build_locked! : Str, Str, Str, Str => Try(Bool, [Failed(Str)])
	build_locked! = |rocx, target, out, opt| {
		Hosts.cli_host!(rocx, target)?
		if Hosts.rocx_fresh!(rocx, target, opt) {
			return Ok(Bool.False)
		}
		Hosts.build_rocx!(rocx, out, opt)?
		Ok(Bool.True)
	}

	build_rocx! : Str, Str, Str => Try({}, [Failed(Str)])
	build_rocx! = |rocx, out, opt| {
		roc = Hosts.roc!(rocx)?
		building = "${out}.building-${Env.pid!({}).to_str()}"
		ran =
			match Cmd.new(roc).args(["build", "--opt=${opt}", "--output=${building}", Fs.join([rocx, "rocx-cli", "main.roc"])]).output!() {
				Ok(done) => done
				Err(CantStart(why)) => return Err(Failed("building rocx (rocx-cli/main.roc) failed: ${why}"))
			}
		# 1: errors (the binary would crash where they are); 2: warnings only.
		if ran.code == 1 or !File.exists!(building) {
			return Err(Failed("building rocx (rocx-cli/main.roc) failed:\n${ran.stdout}${ran.stderr}"))
		}
		if ran.code == 2 {
			_ = Stderr.line!("rocx (rocx-cli/main.roc) built with warnings:\n${ran.stdout}${ran.stderr}")
		}
		match File.rename!(building, out) {
			Ok({}) => {}
			Err(CantRename(why)) => return Err(Failed(why))
		}
		_ = Fs.write!(Fs.join([rocx, "bin", ".rocx-opt"]), opt)
		Ok({})
	}

	## Whether bin/rocx is newer than everything it is built from, and was built with `opt`.
	rocx_fresh! : Str, Str, Str => Bool
	rocx_fresh! = |rocx, target, opt| {
		built = File.modified!(Fs.join([rocx, "bin", "rocx"]))
		sources = Fs.entries!(Fs.join([rocx, "rocx-cli"])).keep_if(|name| !name.ends_with(".mjs")).map(|name| Fs.join([rocx, "rocx-cli", name]))
		modules = Fs.entries!(Fs.join([rocx, "cli", "platform"])).keep_if(|name| name.ends_with(".roc")).map(|name| Fs.join([rocx, "cli", "platform", name]))
		# The packages rocx imports: qr (`rocx qr`, and rocx dev --android --lan's code).
		packaged = Fs.entries!(Fs.join([rocx, "packages", "qr"])).keep_if(|name| name.ends_with(".roc")).map(|name| Fs.join([rocx, "packages", "qr", name]))
		library = Fs.join([rocx, "cli", "platform", "targets", target, "libhost.a"])
		built > 0
			and Hosts.cli_host_fresh!(rocx, target)
			and Fs.read_or_empty!(Fs.join([rocx, "bin", ".rocx-opt"])) == opt
			and Hosts.all_older!(sources.concat(modules).concat(packaged).append(library), built)
	}

	all_older! : List(Str), U64 => Bool
	all_older! = |files, time| {
		for file in files {
			if File.modified!(file) > time {
				return Bool.False
			}
		}
		Bool.True
	}
}

expect Hosts.env_file([], Bool.True) == ["--env-file", ".env"]
expect Hosts.env_file(["--debug"], Bool.False) == []
expect Hosts.env_file(["--env-file", "staging.env"], Bool.True) == []
expect Hosts.env_file(["--env-file=staging.env"], Bool.True) == []
expect Hosts.engines_of("app [program] { pf: platform \"x\" }\n\nprogram = App.program({\n\tinit!: |_| Ok({}),\n\tdatabase: Sqlite(\"data/app.db\"),\n})\n") == []
expect Hosts.engines_of("program = App.program({\n\tdatabase: Turso(\"data/app.db\"),\n})\n") == ["turso"]
expect Hosts.engines_of("program = App.program({\n\tdatabase: Postgres,\n})\n") == ["postgres"]
expect Hosts.engines_of("program = App.program({ init!: |_| Ok({}), database: Postgres })\n") == ["postgres"]
expect Hosts.engines_of("## App.program also takes `plugins`, `openapi`, `database` and `cross_site`.\nprogram = App.program({ init!: |_| Ok({}) })\n") == []
expect Hosts.engines_of("# database: Turso(\"x\") on a comment's line\nprogram = App.program({ database: Sqlite(\"a.db\") })\n") == []
expect Hosts.engines_of("program = App.program({ database: chosen, sql_database: Turso(\"x\") })\n") == Hosts.all_engines
expect Hosts.engines_of("a = { database: Sqlite(\"a\") }\nb = { database: Turso(\"b\") }\n") == Hosts.all_engines
expect Hosts.engines_of("import Config\n\nprogram = App.program(Config.app)\n") == Hosts.all_engines
