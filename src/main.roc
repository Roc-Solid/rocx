app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst" }

import pf.Stdin
import pf.Stdout
import pf.Stderr
import pf.OsStr
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

main! = |args| {
	words = args.map(|arg| OsStr.to_str_try(arg) ?? "")
	match words.first() {
		Ok("internal") => internal!({})
		Ok("check") => {
			given = words.drop_first(1)
			exit_with(Commands.check!(if (given.first() == Ok("--")) given.drop_first(1) else given))
		}
		Ok("lint") if words.len() > 1 => exit_with(Commands.lint!(words.drop_first(1)))
		_ => {
			Stderr.line!("usage: rocx build <dir>… [--client <out>] [--dev] | rocx check -- <command>… | rocx lint <dir>… | rocx routes <dir> | rocx fmt [--check] <path>…")?
			Err(Exit(2))
		}
	}
}

## Ends with `code`: 0 is success.
exit_with : I32 -> Try({}, [Exit(I32)])
exit_with = |code| if (code == 0) Ok({}) else Err(Exit(code))

## `rocx internal`: a call from the repo's JavaScript (src/rocx.mjs), `{ "fn": …, "args": […] }` on
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

## A function of rocx's, by the name src/rocx.mjs calls it.
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
