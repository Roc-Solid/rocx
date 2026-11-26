app [main!] { pf: platform "../cli/platform/main.roc", qr: "../packages/qr/main.roc" }

import pf.Stdin
import pf.Stdout
import pf.Stderr
import pf.Env
import Text
import Value
import Fs
import Transpile
import Styles
import Format
import Routes
import Stories
import Remap
import Commands
import Build
import CheckSql
import Sql
import Dev
import Agents
import Site
import Hosts
import SiteDev
import Static
import Release
import Image
import Versions
import New
import Help
import BuildArgs
import Term
import qr.Qr

main! = |args| {
	words = args
	home = Hosts.home!({})
	# An app's command runs on the version of rocx the app names (`.rocx-version`), through its
	# `.rocx` link: another version runs it in this one's place.
	if Versions.app_commands.contains(words.first() ?? "") {
		Versions.dispatch!(home, Fs.resolve(Fs.cwd!(), [Versions.app_dir(words.drop_first(1))]), words)?
	}
	# `rocx <command> --help` (before any `--`, past which the words are another program's).
	asked_help = BuildArgs.until_dashes(words).any(|word| word == "--help" or word == "-h")
	match words.first() {
		Err(_) => {
			Help.show!("")
			Ok({})
		}
		Ok("help") | Ok("--help") | Ok("-h") => {
			Help.show!(words.get(1) ?? "")
			Ok({})
		}
		Ok(command) if asked_help => {
			Help.show!(command)
			Ok({})
		}
		Ok("internal") => internal!({})
		Ok("--version") => {
			Stdout.line!(Versions.line!(home))?
			Ok({})
		}
		Ok("upgrade") => Versions.upgrade!(words.drop_first(1), home)
		Ok("new") => New.run!(words.drop_first(1), home)
		Ok("agents") => Agents.run!(words.drop_first(1), home)
		Ok("check") if words.get(1) == Ok("--sql") => CheckSql.run!(words.drop_first(2), home)
		# `rocx check [dir]`: an app, checked from its sources; `rocx check -- <command>`, a command's
		# reports pointed into .rocx files.
		Ok("check") if words.len() == 1 or (words.len() == 2 and words.get(1) != Ok("--")) => Dev.check_app!(words.drop_first(1), home)
		Ok("check") => {
			given = words.drop_first(1)
			exit_with(Commands.check!(if (given.first() == Ok("--")) given.drop_first(1) else given))
		}
		Ok("test") => Dev.test_app!(words.drop_first(1), home)
		Ok("lint") if words.len() > 1 => exit_with(Commands.lint!(words.drop_first(1)))
		Ok("routes") if words.len() == 2 => routes!(words.get(1) ?? ".")
		Ok("build") => build_command!(words.drop_first(1), home)
		Ok("generate") => build!(words.drop_first(1), home)
		Ok("dev") => Dev.app!(words.drop_first(1), home)
		Ok("site") if !Hosts.is_clone!(home) => clone_only!("rocx site", home)
		Ok("site") if words.get(1) == Ok("prepare") => site_prepare!(words.drop_first(2), home)
		Ok("site") if words.get(1) == Ok("dev") => SiteDev.run!(words.drop_first(2), home)
		Ok("self-build") if !Hosts.is_clone!(home) => clone_only!("rocx self-build", home)
		Ok("self-build") => self_build!(home)
		Ok("qr") if words.len() >= 2 => qr!(words.drop_first(1))
		Ok("fmt") if words.drop_first(1).any(|arg| arg != "--check") => fmt!(words.drop_first(1), home)
		Ok(command) => usage!(command)
	}
}

## A command it can't take (`command` the first word): what to read, on standard error; exit 2.
usage! = |command| {
	styled = Term.styled!({})
	said = if (Help.knows(command)) "rocx ${command}: not with those words" else "rocx: no command `${command}`"
	Stderr.line!("${Term.red(styled, said)}. ${if (Help.knows(command)) "rocx help ${command}" else "rocx --help"} says what it takes.")?
	Err(Exit(2))
}

## `rocx build [dir] [--image|--static] [--out PATH] …` (D-107): the release, the image or the
## static copy, by `BuildArgs`; the words before D-107 too.
build_command! = |args, home| {
	read = BuildArgs.read(args)
	cwd = Fs.cwd!()
	match read.mode {
		Generate => build!(args, home)
		Release => Release.run!([read.dir, "--release", if (read.out.is_empty()) Fs.join([read.dir, "dist"]) else read.out].concat(read.rest), home)
		Static => Static.run!([read.dir, "--static", if (read.out.is_empty()) Fs.join([read.dir, "dist"]) else read.out].concat(read.rest), home)
		Image => {
			name = Image.name_of(Fs.basename(Fs.real!(Fs.resolve(cwd, [read.dir]))))
			Image.run!([read.dir, "--image", if (read.out.is_empty()) Fs.join([read.dir, "${name}.tar"]) else read.out].concat(read.rest), home)
		}
	}
}

## A command for working on rocx itself (`what`), which an installed version (`home`) doesn't have:
## it needs a clone of the repo.
clone_only! : Str, Str => Try({}, [Exit(I32)])
clone_only! = |what, home| {
	_ = Stderr.line!("${what} works on rocx itself, in a clone of its repo; this rocx is installed (${home})")
	Err(Exit(2))
}

## `rocx qr [--pbm] <text>`: `text` as a QR code in the terminal (what `rocx dev --android --lan`
## prints), or as a PBM image (`--pbm`), for checking it with a reader.
qr! = |args| {
	pbm = args.contains("--pbm")
	text = Str.join_with(args.keep_if(|arg| arg != "--pbm"), " ")
	match Qr.encode(text, Medium) {
		Ok(code) => {
			Stdout.line!(if (pbm) Qr.pbm(code) else Qr.terminal(code))?
			Ok({})
		}
		Err(TooLong) => {
			Stderr.line!("rocx qr: a QR code here holds 2,331 bytes at most")?
			Err(Exit(2))
		}
	}
}

## `rocx self-build`, for the repo's Justfile: rocx itself (bin/rocx) built again when its Roc, the
## CLI platform's modules or its host changed, or it was built with another optimization
## (`ROCX_OPT`), as server/build.mjs's rocxBinary does; then its path. The rocx running this is the
## one before.
self_build! = |home| {
	match Hosts.rocx_binary!(home, Hosts.native_target!({})) {
		Ok(_) => {
			Stdout.line!(Fs.join([home, "bin", "rocx"]))?
			Ok({})
		}
		Err(Failed(message)) => {
			Stderr.line!(message)?
			Err(Exit(1))
		}
	}
}

## `rocx generate [dir]… [--client <out>] [--dev]` (what `rocx build <dir>…` was before D-107): the
## apps' Generated/ and browser's copies, with the root of the first app (`Hosts.root_of!`).
build! = |rest, home| {
	dev = rest.contains("--dev")
	client_at = rest.find_first_index(|arg| arg == "--client")
	client =
		match client_at {
			Ok(at) =>
				match rest.get(at + 1) {
					Ok(out) if !out.is_empty() => Given(out)
					_ => Missing
				}
			Err(_) => NotAsked
		}
	dirs = rest.map_with_index(|arg, i| { arg, i }).keep_if(
		|each|
			each.arg != "--dev"
				and (
					match client_at {
						Ok(at) => each.i != at and each.i != at + 1
						Err(_) => Bool.True
					}
				),
	).map(|each| each.arg)
	match client {
		Given(_) if dirs.len() > 1 => {
			Stderr.line!("rocx generate --client: one directory, the app's")?
			Err(Exit(2))
		}
		Missing => usage!("generate")
		_ if dirs.is_empty() => build!(rest.append("."), home)
		_ => {
			given = match client {
				Given(out) => Some(out)
				_ => None
			}
			cwd = Fs.cwd!()
			root = Hosts.root_of!(Fs.resolve(cwd, [dirs.first() ?? "."]), home)
			match Build.build!(dirs, { client: given, cwd, dev, rocx: root }) {
				Ok(built) => {
					for message in built.said {
						Stderr.line!(message)?
					}
					if (built.ok) Ok({}) else Err(Exit(1))
				}
				Err(Problem(message)) => {
					Stderr.line!("Error: ${message}")?
					Err(Exit(1))
				}
			}
		}
	}
}

## `rocx site prepare [--dev] [--no-lock]`: the docs site's generated modules and its rocx build, in
## the clone rocx is in (Site.roc), before its wasm and server are built; for `just dev`, and
## site/build.mjs (which holds site/build's lock already: `--no-lock`).
site_prepare! = |flags, home| {
	exe = Env.exe_path!({})
	match Site.prepare!(home, if (exe.is_empty()) "rocx" else exe, flags) {
		Ok({}) => Ok({})
		Err(Problem(message)) => {
			Stderr.line!("rocx site: ${message}")?
			Err(Exit(1))
		}
	}
}

## `rocx fmt [--check] <path>…`: each .rocx file, and each .roc file but rocx's (generated, or
## under build/, dist/ or Generated/), under the directories or named, through `roc fmt`; a .rocx
## file's markup as written. Its `roc` is the compiler of the root of the app here
## (`Hosts.root_of!`, `Hosts.roc!`: an installed version's, a clone's, $ROC), else the `roc` on PATH.
fmt! = |args, home| {
	check = args.contains("--check")
	roc = Hosts.roc!(Hosts.root_of!(Fs.cwd!(), home)) ?? "roc"
	skip = |path| {
		last = Fs.basename(path)
		last == "build" or last == "dist" or last == "Generated"
	}
	var $failed = Bool.False
	for given in args.keep_if(|arg| arg != "--check") {
		named = if (Fs.is_dir!(given)) Fs.files!(given, ".rocx", skip).concat(Fs.files!(given, ".roc", skip)) else [given]
		for path in named {
			generated = path.ends_with(".roc") and Build.is_generated!(path)
			if !generated {
				source = Fs.read_or_empty!(path)
				formatted =
					if path.ends_with(".rocx") {
						Format.format_rocx!(source, path, roc)
					} else {
						match Format.roc_fmt!(source, roc, path) {
							Ok(text) => Ok(text)
							Err(FormatError(message)) => Err(FormatError(message))
							Err(NoRoc(command)) => Err(NoRoc(command))
							Err(CantRun(message)) => Err(CantRun(message))
						}
					}
				match formatted {
					Ok(text) if text == source => {}
					Ok(text) =>
						if check {
							Stderr.line!("✗ ${path}: not formatted (rocx fmt formats it)")?
							$failed = Bool.True
						} else {
							_ = Fs.write!(path, text)
							Stdout.line!("formatted ${path}")?
						}
					Err(NoRoc(_)) => {
						Stderr.line!("✗ rocx fmt runs roc fmt, and there is no ${roc}: put roc on the PATH, or set ROC")?
						return Err(Exit(2))
					}
					Err(Rocx(problem)) => {
						Stderr.line!("✗ ${problem.file}:${problem.line.to_str()}:${problem.column.to_str()}: ${problem.reason}")?
						$failed = Bool.True
					}
					Err(FormatError(message)) => {
						Stderr.line!("✗ ${message}")?
						$failed = Bool.True
					}
					Err(Lost(message)) | Err(Crash(message)) | Err(CantRun(message)) => {
						Stderr.line!("Error: ${message}")?
						return Err(Exit(1))
					}
				}
			}
		}
	}
	if ($failed) Err(Exit(1)) else Ok({})
}

## `rocx routes <dir>`: every route the app's routes/ has: the methods each answers, and the
## middleware each file names.
routes! = |dir| {
	match Routes.routes_table!(Fs.resolve(Fs.cwd!(), [dir])) {
		Ok(table) => {
			Stdout.line!(table)?
			Ok({})
		}
		Err(Problem(message)) => {
			Stderr.line!("Error: ${message}")?
			Err(Exit(1))
		}
	}
}

## Ends with `code`: 0 is success.
exit_with : I32 -> Try({}, [Exit(I32)])
exit_with = |code| if (code == 0) Ok({}) else Err(Exit(code))

## `rocx internal`: a call from the repo's JavaScript (rocx-cli/rocx.mjs), `{ "fn": …, "args": […] }` on
## stdin, answered on stdout with `{ "ok": … }` or `{ "error": { "kind", "message", … } }`.
internal! = |{}| {
	input = Stdin.read_to_end!({})
	answer =
		match Value.parse(input) {
			Ok(request) =>
				match call!(Value.str(Value.field(request, "fn")), Value.items(Value.field(request, "args"))) {
					Ok(value) => Object([{ key: "ok", value }])
					Err(Failed(error)) => Object([{ key: "error", value: error }])
					Err(Unknown(name)) => Object([{ key: "error", value: Object([{ key: "kind", value: Text("Error") }, { key: "message", value: Text("rocx internal: no function ${name}") }]) }])
				}
			Err(BadJson(why)) => Object([{ key: "error", value: Object([{ key: "kind", value: Text("Error") }, { key: "message", value: Text("rocx internal: ${why}") }]) }])
		}
	Stdout.write!(Value.encode(answer))?
	Ok({})
}

## A function of rocx's, by the name rocx-cli/rocx.mjs calls it.
call! : Str, List(Value) => Try(Value, [Failed(Value), Unknown(Str)])
call! = |name, args| {
	known = |result|
		match result {
			Err(Unknown(_)) => Bool.False
			_ => Bool.True
		}
	answers = [Transpile.rpc(name, args), Styles.rpc(name, args), Stories.rpc(name, args)]
	match answers.find_first(known) {
		Ok(answer) => return answer
		Err(_) => {}
	}
	routed = Routes.rpc!(name, args)
	if known(routed) {
		return routed
	}
	remapped = Remap.rpc!(name, args)
	if known(remapped) {
		return remapped
	}
	formatted = Format.rpc!(name, args)
	if known(formatted) {
		return formatted
	}
	checked = Sql.rpc!(name, args)
	if known(checked) {
		return checked
	}
	site = Site.rpc!(Hosts.home!({}), name, args)
	if known(site) {
		return site
	}
	# Many calls in one process (rocx-cli/rocx.mjs callMany): each `{ fn, args }`, their answers in order.
	if name == "batch" {
		var $answers = []
		for each in Value.items(args.get(0) ?? Null) {
			answer = call!(Value.str(Value.field(each, "fn")), Value.items(Value.field(each, "args")))?
			$answers = $answers.append(answer)
		}
		return Ok(Array($answers))
	}
	if name == "build" {
		arg = |i| args.get(i) ?? Null
		options = arg(1)
		dirs = Value.items(arg(0)).map(Value.str)
		cwd = Value.str_or(Value.field(options, "cwd"), Fs.cwd!())
		built = Build.build!(
			dirs,
			{
				client: Value.maybe_str(Value.field(options, "client")),
				cwd,
				dev: Value.bool_or(Value.field(options, "dev"), Bool.False),
				rocx: Hosts.root_of!(Fs.resolve(cwd, [dirs.first() ?? "."]), Hosts.home!({})),
			},
		)
		return
			match built {
				Ok({ ok, said }) => Ok(Object([{ key: "ok", value: Boolean(ok) }, { key: "said", value: Value.strs(said) }]))
				Err(Problem(message)) => Err(Failed(Value.problem(message)))
			}
	}
	helper(name, args)
}

## The helpers' own calls, for checking them against Node's.
helper : Str, List(Value) -> Try(Value, [Failed(Value), Unknown(Str)])
helper = |name, args| {
	arg = |i| args.get(i) ?? Null
	match name {
		"rocString" => Ok(Text(Text.roc_string(Value.str(arg(0)))))
		"jsonString" => Ok(Text(Text.json_string(Value.str(arg(0)))))
		"path.join" => Ok(Text(Fs.join(Value.items(arg(0)).map(Value.str))))
		"path.resolve" => Ok(Text(Fs.resolve(Value.str(arg(0)), Value.items(arg(1)).map(Value.str))))
		"path.relative" => Ok(Text(Fs.relative(Value.str(arg(0)), Value.str(arg(1)))))
		"path.dirname" => Ok(Text(Fs.dirname(Value.str(arg(0)))))
		"path.basename" => Ok(Text(Fs.basename(Value.str(arg(0)))))
		"path.normalize" => Ok(Text(Fs.normalize(Value.str(arg(0)))))
		"text.localeSort" => Ok(Value.strs(Value.items(arg(0)).map(Value.str).sort_with(Text.locale_order)))
		"text.column" => Ok(Value.count(Text.column(Value.str(arg(0)).to_utf8(), Value.int_or(arg(1), 0).to_u64_wrap())))
		"text.trim" => Ok(Text(Text.trim(Value.str(arg(0)))))
		_ => Err(Unknown(name))
	}
}
