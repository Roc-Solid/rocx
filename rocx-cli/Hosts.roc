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
	shared_modules = ["Html", "Solid", "Store", "Repeat", "Loading", "Errored", "Call", "Server", "Context", "Endpoint", "FormBody", "Middleware", "Events", "OpenApi", "Router", "HttpStatusCode", "Transition", "Browser", "Submission", "Submissions", "Title", "Channel", "A", "Search", "Leave"]

	## The Roc compiler: the one `just setup` links in .tools (the fork rocx builds with), as the file
	## it links to; else $ROC; never the `roc` on PATH, which may lack the fork's fixes.
	roc! : Str => Try(Str, [Failed(Str)])
	roc! = |rocx| {
		active = Fs.join([rocx, ".tools", "roc-active"])
		if File.exists!(active) {
			return Ok(Fs.real!(active))
		}
		match Env.var!("ROC") {
			Ok(given) => Ok(given)
			Err(NotFound) => Err(Failed("no Roc compiler: run `just setup` (or set ROC)"))
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
	server_host! : Str, Str => Try({}, [Failed(Str)])
	server_host! = |rocx, target| {
		Hosts.sync_shared!(rocx)
		triple = Hosts.rust_target(target)
		musl = target.ends_with("musl")
		host_dir = Fs.join([rocx, "server", "host"])
		var $cargo = Hosts.rust_env!(Cmd.new("cargo").args(["build", "--release", "--target", triple]).cwd(host_dir), rocx, musl)
		if musl {
			zig = Hosts.zig!(rocx)
			under = Str.join_with(triple.split_on("-"), "_")
			$cargo =
				$cargo
					.env("CC_${under}", "${zig} cc -target ${triple.replace_each("-unknown-", "-")}")
					.env("AR_${under}", "${zig} ar")
					.env("CRATE_CC_NO_DEFAULTS", "1")
					.env("CFLAGS_${under}", "-O2 -fPIC -fno-sanitize=all")
			_ = Hosts.run!(Hosts.rust_env!(Cmd.new("rustup").args(["target", "add", triple]), rocx, musl), "rustup target add ${triple}")?
		}
		dir = Fs.join([rocx, "server", "platform", "targets", target])
		# Nothing under server/host newer than the library Roc links: cargo would do nothing, and
		# takes a tenth of a second to say so, on every build.
		if !musl and Hosts.not_newer!(host_dir, File.modified!(Fs.join([dir, "libhost.a"]))) {
			return Ok({})
		}
		_ = Hosts.run!($cargo, "cargo build --release --target ${triple}")?
		Hosts.copy_if_changed!(Fs.join([host_dir, "target", triple, "release", "librocx_server_host.a"]), Fs.join([dir, "libhost.a"]))?
		if musl {
			sysroot = Text.trim(Hosts.run!(Hosts.rust_env!(Cmd.new("rustc").args(["--print", "sysroot"]), rocx, musl), "rustc --print sysroot")?)
			crt = Fs.join([sysroot, "lib", "rustlib", triple, "lib", "self-contained"])
			for file in ["rcrt1.o", "libunwind.a", "libc.a"] {
				Hosts.copy_if_changed!(Fs.join([crt, file]), Fs.join([dir, file]))?
			}
		}
		Ok({})
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
