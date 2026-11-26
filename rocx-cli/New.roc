import pf.File
import pf.Stdin
import pf.Stdout
import pf.Stderr
import Agents
import Fs
import Term
import Text
import Versions

## `rocx new [dir] [--db sqlite|postgres|turso]` (D-078, D-107: the directory asked for at a terminal
## when not given): a new app made from rocx's template
## (`templates/app/` beside this rocx, in a clone or an install), its placeholders filled in: where
## the platform and packages are (`./.rocx`, the app's link to this version of rocx), its name as
## code writes it and as people read it, and its database (SQLite unless `--db` says otherwise, or
## the answer to the question, at a terminal). Then the app's `.rocx-version` (an installed rocx's
## version; a clone has none to write) and its `.rocx` link, its AGENTS.md and CLAUDE.md (rocx's
## rules for coding agents, `Agents`), and how to start it.
New := [].{

	## A database an app may start on.
	Database : [Sqlite, Postgres, Turso]

	## `rocx new`'s words (after `new`), at the rocx at `home`.
	run! : List(Str), Str => Try({}, [Exit(I32)])
	run! = |args, home|
		match New.parse(args) {
			Err(why) => Versions.failed!("rocx new: ${why}\nusage: rocx new [dir] [--db sqlite|postgres|turso]")
			Ok({ dir: given, db }) => {
				styled = Term.styled!({})
				dir = if (given.is_empty()) ask_name!(styled)? else given
				template = Fs.join([home, "templates", "app"])
				if !Fs.is_dir!(template) {
					return Versions.failed!("rocx new: this rocx has no template (${template})")
				}
				target = Fs.resolve(Fs.cwd!(), [dir])
				if Fs.exists!(target) and !Fs.entries!(target).is_empty() {
					return Versions.failed!("rocx new: ${dir} isn't empty: give a new directory")
				}
				database =
					match db {
						Given(chosen) => chosen
						Ask => ask!(styled)
					}
				named = Fs.basename(target)
				Term.header!(styled, "rocx new", [named, New.database_name(database)])
				filled = { root: "./.rocx", name: New.code_name(named), title: New.title(named) }
				match made!(template, target, "", filled, database) {
					Ok({}) => Term.ok!(styled, "${dir}/ made from the template")
					Err(why) => return Versions.failed!("rocx new: ${why}")
				}
				version = Versions.own!(home)
				if !version.is_empty() {
					_ = Fs.write!(Fs.join([target, ".rocx-version"]), "${version}\n")
				}
				match Versions.link!(target, home) {
					Ok(_) => Term.ok!(styled, if (version.is_empty()) "on this clone of rocx (.rocx links to it)" else "on rocx ${version} (.rocx-version: commit it)")
					Err(Failed(why)) => return Versions.failed!(why)
				}
				# rocx's rules for coding agents (D-108), which `rocx agents` keeps up to date.
				match Agents.write!(target, home, Bool.False) {
					Ok(_) => Term.ok!(styled, "AGENTS.md and CLAUDE.md: rocx's rules for coding agents")
					Err(why) => Term.warn!(styled, "AGENTS.md: ${why}")
				}
				Term.next!(styled, "Next", New.next_lines(styled, dir, database))
				Ok({})
			}
		}

	## The words after `new`: the directory, and the database `--db` names (else ask).
	parse : List(Str) -> Try({ dir : Str, db : [Given(New.Database), Ask] }, Str)
	parse = |args| {
		var $dir = ""
		var $db = Ask
		var $i = 0
		while $i < args.len() {
			word = args.get($i) ?? ""
			if word == "--db" {
				named = args.get($i + 1) ?? ""
				match New.database_of(named) {
					Ok(found) => {
						$db = Given(found)
					}
					Err(Unknown) => return Err("--db takes sqlite, postgres or turso, not \"${named}\"")
				}
				$i = $i + 2
			} else if word.starts_with("-") {
				return Err("no such option: ${word}")
			} else if $dir.is_empty() {
				$dir = word
				$i = $i + 1
			} else {
				return Err("one directory, not \"${$dir}\" and \"${word}\"")
			}
		}
		Ok({ dir: $dir, db: $db })
	}

	## A database by the name `--db` gives it.
	database_of : Str -> Try(New.Database, [Unknown])
	database_of = |named|
		match named.with_ascii_lowercased() {
			"sqlite" => Ok(Sqlite)
			"postgres" | "postgresql" => Ok(Postgres)
			"turso" => Ok(Turso)
			_ => Err(Unknown)
		}

	## The app's name as code writes it (its session cookie is `<name>_session`): lower-case letters,
	## digits and `_`, starting with a letter (`My-App` is `my_app`, `2048` is `app_2048`).
	code_name : Str -> Str
	code_name = |named| {
		var $out = []
		for byte in named.to_utf8() {
			lower = if (Text.is_upper(byte)) byte + 32 else byte
			next = if (Text.is_lower(lower) or Text.is_digit(lower)) lower else '_'
			$out = if (next == '_' and ($out.last() ?? '_') == '_') $out else $out.append(next)
		}
		trimmed = Str.from_utf8_lossy($out).drop_prefix("_").drop_suffix("_")
		if trimmed.is_empty() {
			"app"
		} else if Text.is_letter(trimmed.to_utf8().first() ?? 0) {
			trimmed
		} else {
			"app_${trimmed}"
		}
	}

	## The app's name as people read it (the pages' titles, the bar, the mail): words of letters and
	## digits, the first capitalized (`my-app` is `My app`).
	title : Str -> Str
	title = |named| {
		words = New.code_name(named).split_on("_").keep_if(|word| !word.is_empty())
		joined = Str.join_with(words, " ")
		bytes = joined.to_utf8()
		match bytes.first() {
			Ok(first) if Text.is_lower(first) => Str.from_utf8_lossy(bytes.drop_first(1).prepend(first - 32))
			_ => joined
		}
	}

	## A template file's text with its placeholders filled in; in `main.roc`, the database chosen.
	fill : Str, Str, { root : Str, name : Str, title : Str }, New.Database -> Try(Str, Str)
	fill = |path, text, filled, database| {
		done = text.replace_each("{{root}}", filled.root).replace_each("{{name}}", filled.name).replace_each("{{title}}", filled.title)
		chosen =
			if path == "main.roc" {
				if !done.contains(sqlite_line) {
					return Err("the template's main.roc has no `${sqlite_line}` line to choose the database on")
				}
				done.replace_first(sqlite_line, "database: ${New.database_expr(database)},")
			} else {
				done
			}
		if (chosen.contains("{{")) Err("${path} still has a placeholder") else Ok(chosen)
	}

	## What main.roc says for a database.
	database_expr : New.Database -> Str
	database_expr = |database|
		match database {
			Sqlite => "Sqlite(\"data/app.db\")"
			Postgres => "Postgres"
			Turso => "Turso(\"data/app.db\")"
		}

	## A database's name, as people read it.
	database_name : New.Database -> Str
	database_name = |database|
		match database {
			Sqlite => "SQLite"
			Postgres => "Postgres"
			Turso => "Turso"
		}

	## What to do once the app is made: go there, start it, and what then.
	next_lines : Bool, Str, New.Database -> List(Str)
	next_lines = |styled, dir, database|
		["cd ${dir}"]
			.concat(if (database == Postgres) ["export DATABASE_URL=postgres://…"] else [])
			.concat(["rocx dev", Term.dim(styled, "then sign in with any address (rocx dev's sign-in); README.md says what to change first")])
}

## The line main.roc chooses the database on, as the template writes it (SQLite).
sqlite_line : Str
sqlite_line = "database: Sqlite(\"data/app.db\"),"

## The directory, asked at a terminal (`my-app` when the answer is empty); off one, an error.
ask_name! : Bool => Try(Str, [Exit(I32)])
ask_name! = |styled|
	if Stdin.is_terminal!({}) {
		_ = Stderr.write!("  ${Term.bold(styled, "Name")} ${Term.dim(styled, "(the app's directory: my-app)")} ")
		answer = Stdin.line!({}) ?? ""
		_ = Stderr.line!("")
		Ok(if (Text.trim(answer).is_empty()) "my-app" else Text.trim(answer))
	} else {
		Versions.failed!("rocx new: which directory? rocx new my-app")
	}

## The database, asked at a terminal; off one, SQLite, said.
ask! : Bool => New.Database
ask! = |styled|
	if Stdin.is_terminal!({}) {
		choices = [
			"  ${Term.bold(styled, "Database")}",
			"    1  SQLite    ${Term.dim(styled, "a file beside the server (the default)")}",
			"    2  Postgres  ${Term.dim(styled, "a server of its own, at DATABASE_URL")}",
			"    3  Turso     ${Term.dim(styled, "SQLite's format, writes at the same time")}",
		]
		_ = Stderr.line!(Str.join_with(choices, "\n"))
		_ = Stderr.write!("  ${Term.dim(styled, "›")} ")
		answer = Stdin.line!({}) ?? ""
		_ = Stderr.line!("")
		match Text.trim(answer) {
			"2" => Postgres
			"3" => Turso
			other => New.database_of(other) ?? Sqlite
		}
	} else {
		_ = Stderr.line!("rocx new: no terminal to ask at, so SQLite (--db postgres or --db turso for another)")
		Sqlite
	}

## The template at `from` copied to `to`, every file (dotfiles too) filled in; `under` is where in
## the template it is (`""` at its top, where `main.roc` chooses the database).
made! : Str, Str, Str, { root : Str, name : Str, title : Str }, New.Database => Try({}, Str)
made! = |from, to, under, filled, database| {
	Fs.make_dirs!(to)
	for entry in File.list!(from) ?? [] {
		source = Fs.join([from, entry])
		target = Fs.join([to, entry])
		path = if (under.is_empty()) entry else "${under}/${entry}"
		if File.is_dir!(source) {
			made!(source, target, path, filled, database)?
		} else {
			text = Fs.read!(source).map_err(|_| "can't read ${source}")?
			written = New.fill(path, text, filled, database)?
			Fs.write!(target, written).map_err(|_| "can't write ${target}")?
		}
	}
	Ok({})
}

expect New.code_name("My-App") == "my_app"
expect New.code_name("2048") == "app_2048"
expect New.code_name("--") == "app"
expect New.code_name("acme  books") == "acme_books"
expect New.title("my-app") == "My app"
expect New.title("acme") == "Acme"
expect New.title("2048") == "App 2048"
expect New.parse(["shop"]) == Ok({ dir: "shop", db: Ask })
expect New.parse(["shop", "--db", "Postgres"]) == Ok({ dir: "shop", db: Given(Postgres) })
expect New.parse(["--db", "mysql", "shop"]).is_err()
expect New.parse([]) == Ok({ dir: "", db: Ask })
expect New.parse(["a", "b"]).is_err()
expect New.fill("main.roc", "pf: platform \"{{root}}/server/platform/main.roc\"\ndatabase: Sqlite(\"data/app.db\"),\ncookie: \"{{name}}_session\"", { root: "./.rocx", name: "shop", title: "Shop" }, Turso) == Ok("pf: platform \"./.rocx/server/platform/main.roc\"\ndatabase: Turso(\"data/app.db\"),\ncookie: \"shop_session\"")
expect New.fill("main.roc", "no database here", { root: "./.rocx", name: "shop", title: "Shop" }, Sqlite).is_err()
expect New.fill("README.md", "{{other}}", { root: "./.rocx", name: "shop", title: "Shop" }, Sqlite).is_err()
