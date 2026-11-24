## `rocx check --sql [dir] [--engine sqlite|turso] [--verbose] [-- server options…]` (D-058): the
## app's SQL checked by its own database engine, and its rows by the compiler. rocx finds each
## `Db.all!`/`Db.run!` whose SQL is a string literal at the call (`Sql.scan!`); the app's server,
## built as `rocx dev` builds it, describes them (`--describe-sql`) on a scratch database it builds
## from the program's migrations: a SQLite or Turso file it removes after, or a Postgres database it
## makes on the server `--database-url` (DATABASE_URL) names and drops after, unless
## `--sql-database URL` (ROCX_SQL_DATABASE) names one it may migrate. What follows `--` goes to the
## server as it is. Then rocx writes a check app beside a copy of the app (build/sql/check): a
## `DbCheck.Rows(T, Tags)` for each `Db.all!` whose row type it read, its string the statement's
## columns, which packages/dbcheck checks when `roc check` compiles it. Exits 1 when the engine
## refuses a statement, a call's parameters don't match it, or a row doesn't fit its columns, and
## when the check app doesn't compile (so no row would be checked), saying why.
##
## `rocx dev` runs it after each build with `--server` (the server it built, none built here) and
## `--quiet` (nothing said when there is nothing to check).
import pf.Cmd
import pf.File
import pf.Stdout
import pf.Stderr
import Build
import Commands
import Fs
import Hosts
import Sql
import Text
import Value

CheckSql := [].{

	usage : Str
	usage = "usage: rocx check --sql [dir] [--engine sqlite|turso] [--verbose] [-- server options…]"

	## The directories of an app the check app's copy leaves out: output, data, tests.
	left_out : List(Str)
	left_out = ["build", "dist", "data", "test", "node_modules", ".git"]

	## `rocx check --sql …` (the words after `--sql`), with the builds of the clone rocx is in
	## (`rocx`): what the check found on stdout, a line each; exit 1 when something is wrong, 2 for
	## arguments it can't take.
	run! : List(Str), Str => Try({}, [Exit(I32)])
	run! = |args, rocx| {
		var $own = []
		var $flags = []
		var $after = Bool.False
		for arg in args {
			if $after {
				$flags = $flags.append(arg)
			} else if arg == "--" {
				$after = Bool.True
			} else {
				$own = $own.append(arg)
			}
		}
		cwd = Fs.cwd!()
		var $engine = ""
		var $verbose = Bool.False
		# rocx dev's: the server it built (none built here), and nothing said when there is nothing to check.
		var $built = ""
		var $quiet = Bool.False
		var $dirs = []
		var $i = 0
		while $i < $own.len() {
			arg = $own.get($i) ?? ""
			next = $own.get($i + 1) ?? ""
			if arg == "--engine" and (next == "sqlite" or next == "turso") {
				$engine = next
				$i = $i + 2
			} else if arg == "--verbose" {
				$verbose = Bool.True
				$i = $i + 1
			} else if arg == "--server" and !next.is_empty() {
				$built = Fs.resolve(cwd, [next])
				$i = $i + 2
			} else if arg == "--quiet" {
				$quiet = Bool.True
				$i = $i + 1
			} else if arg.starts_with("-") {
				_ = Stderr.line!(CheckSql.usage)
				return Err(Exit(2))
			} else {
				$dirs = $dirs.append(arg)
				$i = $i + 1
			}
		}
		if $dirs.len() > 1 {
			_ = Stderr.line!(CheckSql.usage)
			return Err(Exit(2))
		}
		named = $dirs.first() ?? "."
		given = Fs.resolve(cwd, [named])
		if !Fs.exists!(Fs.join([given, "main.roc"])) {
			_ = Stderr.line!("rocx check --sql: ${named} has no main.roc: give the app's directory")
			return Err(Exit(2))
		}
		dir_path = Fs.real!(given)
		options = { engine: $engine, verbose: $verbose, built: $built, quiet: $quiet, flags: $flags, cwd, rocx }
		match CheckSql.checked!(dir_path, options) {
			Ok(Quiet) => Ok({})
			Ok(Said(said)) => {
				for line in said.lines {
					_ = Stdout.line!(line)
				}
				if (said.ok) Ok({}) else Err(Exit(1))
			}
			Err(Failed(message)) => {
				_ = Stderr.line!("rocx check --sql: ${message}")
				Err(Exit(1))
			}
		}
	}

	Options : { engine : Str, verbose : Bool, built : Str, quiet : Bool, flags : List(Str), cwd : Str, rocx : Str }

	## The app at `app` (its real path) checked: its server built first unless `options.built` names
	## one (and none when it has no statement to describe); `Quiet` when it has none and `quiet`
	## says to say nothing.
	checked! : Str, Options => Try([Quiet, Said({ lines : List(Str), ok : Bool })], [Failed(Str)])
	checked! = |dir_path, options| {
		server = if (options.built.is_empty()) Fs.join([dir_path, "build", "sql", "server"]) else options.built
		found = Sql.scan!(CheckSql.shown(options.cwd, dir_path))
		statements = Sql.statements(found)
		if statements.is_empty() and options.quiet {
			return Ok(Quiet)
		}
		# No statement to describe, no server to build.
		if !statements.is_empty() and options.built.is_empty() {
			CheckSql.build_server!(dir_path, server, options)?
		}
		said = CheckSql.check!(dir_path, server, found, statements, options)?
		Ok(Said(said))
	}

	## A path as `cwd` names it: relative, `.` for `cwd` itself.
	shown : Str, Str -> Str
	shown = |cwd, path| {
		way = Fs.relative(cwd, path)
		if (way.is_empty()) "." else way
	}

	## The server of the app at `app` (its main.roc), built with Roc's dev backend into `output`, as
	## `rocx dev` builds it: rocx build first, then the server's host (when it changed), then the app,
	## through `rocx check`, its reports pointed into the .rocx files. Silent unless a step fails.
	build_server! : Str, Str, Options => Try({}, [Failed(Str)])
	build_server! = |dir_path, output, options| {
		match Build.build!([dir_path], { client: None, cwd: options.cwd, dev: Bool.False, rocx: options.rocx }) {
			Ok(built) if built.ok => {}
			Ok(built) => return Err(Failed("${Text.trim_end(Str.join_with(built.said, "\n"))}\nrocx build failed"))
			Err(Problem(message)) => return Err(Failed("Error: ${message}\nrocx build failed"))
		}
		target = Hosts.native_target!({})
		Hosts.server_host!(options.rocx, target)?
		Fs.make_dirs!(Fs.dirname(output))
		roc = Hosts.roc!(options.rocx)?
		match Commands.checked!(roc, ["build", "--target=${target}", "--opt=dev", "--output=${output}", Fs.join([dir_path, "main.roc"])]) {
			Ok(ran) if ran.code == 0 => Ok({})
			Ok(ran) => Err(Failed("${Text.trim_end(ran.said)}\nthe server's build failed"))
			Err(CantStart(why)) => Err(Failed("✗ rocx check: ${why}\nthe server's build failed"))
		}
	}

	## The app at `app` checked with its server `server` (built): what to print, and whether nothing
	## is wrong. `options.engine` runs a SQLite app's check on Turso, or a Turso app's on SQLite;
	## `options.flags` go to the server. Files are named as `options.cwd` sees them.
	check! : Str, Str, List(Sql.Found), List(Str), Options => Try({ lines : List(Str), ok : Bool }, [Failed(Str)])
	check! = |dir_path, server, found, statements, options| {
		if statements.is_empty() {
			return Ok(Sql.report(found, Object([{ key: "statements", value: Array([]) }]), Sql.no_rows, options.verbose))
		}
		dir = Fs.join([dir_path, "build", "sql"])
		Fs.make_dirs!(dir)
		list = Fs.join([dir, "statements.json"])
		_ = Fs.write!(list, Value.encode(Value.strs(statements)))
		# The URL's scheme picks the engine; the check makes its own file, wherever this one says.
		engine_flags = if (options.engine.is_empty()) [] else ["--database-url", "${options.engine}:check.db"]
		ran =
			match Cmd.new(server).args(["--describe-sql", list].concat(engine_flags).concat(options.flags)).cwd(options.cwd).env("ROCX_LOG", "json").output!() {
				Ok(done) => done
				Err(CantStart(why)) => return Err(Failed(why))
			}
		if ran.code != 0 {
			return Ok({ lines: CheckSql.errors_of(ran.stderr).append("rocx check --sql: the app's server couldn't describe its statements"), ok: Bool.False })
		}
		described =
			match Value.parse(ran.stdout) {
				Ok(value) => value
				Err(BadJson(why)) => return Err(Failed("the app's server's description isn't JSON: ${why}"))
			}
		_ = Fs.write!(Fs.join([dir, "described.json"]), CheckSql.pretty(described, 0))
		rows = CheckSql.check_rows!(dir_path, found, described, options)?
		Ok(Sql.report(found, described, rows, options.verbose))
	}

	## The rows of `found` (the scan of the app at `app`) checked against `described` (what the
	## server said of their statements): rocx writes the check app (build/sql/check/main.roc) beside
	## a copy of the app's sources, and `roc check` compiles it, each `DbCheck.Rows` checked as it
	## does; rocx reads what it said. A check app that doesn't compile fails the check (`Sql.rows`'s
	## `failed`): its rows weren't checked.
	check_rows! : Str, List(Sql.Found), Value, Options => Try(Sql.Rows, [Failed(Str)])
	check_rows! = |dir_path, found, described, options| {
		made = Sql.check_app!(CheckSql.shown(options.cwd, dir_path), found, described, Fs.relative(dir_path, Fs.join([options.rocx, "packages", "dbcheck", "main.roc"])))
		if made.entries.is_empty() {
			return Ok(Sql.no_rows)
		}
		check = Fs.join([dir_path, "build", "sql", "check"])
		Fs.delete_all!(check)
		Fs.make_dirs!(check)
		for entry in Fs.entries!(dir_path) {
			if !CheckSql.left_out.contains(entry) and entry != "main.roc" {
				match File.copy!(Fs.join([dir_path, entry]), Fs.join([check, entry])) {
					Ok({}) => {}
					Err(CantCopy(why)) => return Err(Failed(why))
				}
			}
		}
		_ = Fs.write!(Fs.join([check, "main.roc"]), made.text)
		roc = Hosts.roc!(options.rocx)?
		match Cmd.new(roc).args(["check", "main.roc"]).cwd(check).env("NO_COLOR", "1").output!() {
			Ok(ran) => Ok(Sql.rows("${ran.stdout}${ran.stderr}", ran.code, CheckSql.shown(options.cwd, check), made.entries))
			Err(CantStart(why)) => Err(Failed(why))
		}
	}

	## The errors in a server's log (JSON lines), each as a line: its message, then why. A line that
	## isn't JSON is kept as it is.
	errors_of : Str -> List(Str)
	errors_of = |log| {
		var $out = []
		for line in log.split_on("\n") {
			if !Text.trim(line).is_empty() {
				match Value.parse(line) {
					Ok(event) =>
						if Value.str(Value.field(event, "level")) == "error" {
							why = Value.str(Value.field(event, "error"))
							$out = $out.append("${Value.str(Value.field(event, "msg"))}${if (why.is_empty()) "" else ": ${why}"}")
						}
					Err(_) => {
						$out = $out.append(line)
					}
				}
			}
		}
		$out
	}

	## The value as `JSON.stringify(value, null, 1)` writes it: a space of indentation a level.
	pretty : Value, U64 -> Str
	pretty = |value, level| {
		inner = Str.repeat(" ", level + 1)
		outer = Str.repeat(" ", level)
		match value {
			Array(items) if !items.is_empty() => "[\n${Str.join_with(items.map(|item| "${inner}${CheckSql.pretty(item, level + 1)}"), ",\n")}\n${outer}]"
			Object(pairs) if !pairs.is_empty() => "{\n${Str.join_with(pairs.map(|pair| "${inner}${Value.json_string(pair.key)}: ${CheckSql.pretty(pair.value, level + 1)}"), ",\n")}\n${outer}}"
			_ => Value.encode(value)
		}
	}
}

expect CheckSql.errors_of("{\"level\":\"info\",\"msg\":\"x\"}\n\nnot json\n{\"level\":\"error\",\"msg\":\"starting failed\",\"error\":\"no table\"}\n{\"level\":\"error\",\"msg\":\"bare\"}\n") == ["not json", "starting failed: no table", "bare"]

expect CheckSql.pretty(Object([{ key: "a", value: Array([Number(1), Object([])]) }, { key: "b", value: Array([]) }]), 0) == "{\n \"a\": [\n  1,\n  {}\n ],\n \"b\": []\n}"
