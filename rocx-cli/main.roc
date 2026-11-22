app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst" }

import pf.Stdin
import pf.Stdout
import pf.Stderr
import pf.OsStr
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

main! = |args| {
	words = args.map(|arg| OsStr.to_str_try(arg) ?? "")
	match words.first() {
		Ok("internal") => internal!({})
		Ok("check") => {
			given = words.drop_first(1)
			exit_with(Commands.check!(if (given.first() == Ok("--")) given.drop_first(1) else given))
		}
		Ok("lint") if words.len() > 1 => exit_with(Commands.lint!(words.drop_first(1)))
		Ok("routes") if words.len() == 2 => routes!(words.get(1) ?? ".")
		Ok("build") => build!(words.drop_first(1))
		Ok("fmt") if words.drop_first(1).any(|arg| arg != "--check") => fmt!(words.drop_first(1))
		_ => usage!({})
	}
}

usage! = |{}| {
	Stderr.line!("usage: rocx build <dir>… [--client <out>] [--dev] | rocx check -- <command>… | rocx lint <dir>… | rocx routes <dir> | rocx fmt [--check] <path>…")?
	Err(Exit(2))
}

## Where rocx is: the repo bin/rocx was built in (web/platform, web/start.js and web/runtime.js are there).
rocx_home! : {} => Str
rocx_home! = |{}| {
	match Env.exe_path!() {
		Ok(path) => Fs.dirname(Fs.dirname(Fs.real!(path.display())))
		Err(_) => Fs.cwd!()
	}
}

## `rocx build <dir>… [--client <out>] [--dev]`.
build! = |rest| {
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
			Stderr.line!("rocx build --client: one directory, the app's")?
			Err(Exit(2))
		}
		Missing => usage!({})
		_ if dirs.is_empty() => usage!({})
		_ => {
			given = match client {
				Given(out) => Some(out)
				_ => None
			}
			match Build.build!(dirs, { client: given, cwd: Fs.cwd!(), dev, rocx: rocx_home!({}) }) {
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

## `rocx fmt [--check] <path>…`: each .rocx file, and each .roc file but rocx's (generated, or
## under build/, dist/ or Generated/), under the directories or named, through `roc fmt`; a .rocx
## file's markup as written. Its `roc` is $ROC, else the `roc` on PATH.
fmt! = |args| {
	check = args.contains("--check")
	roc = Env.var_str!(OsStr.from_str("ROC")) ?? "roc"
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
	input = Str.from_utf8_lossy(Stdin.read_to_end!()?)
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
		built = Build.build!(
			Value.items(arg(0)).map(Value.str),
			{
				client: Value.maybe_str(Value.field(options, "client")),
				cwd: Value.str_or(Value.field(options, "cwd"), Fs.cwd!()),
				dev: Value.bool_or(Value.field(options, "dev"), Bool.False),
				rocx: rocx_home!({}),
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
