## `rocx check --sql` (D-058): an app's SQL checked by its own database engine. rocx finds each
## `Db.all!` and `Db.run!` whose SQL is a string literal at the call (`scan`), the app's server
## describes those statements on a scratch database built from its migrations (`--describe-sql`,
## which rocx-cli/check-sql.mjs runs), and rocx reports what the engine refused and parameters that
## don't match what the call gives (`report`). What it can't check (SQL interpolated, in a
## variable, or marked `Db.unchecked`) is counted, and listed with `--verbose`.
import Value
import Text
import Fs
import Remap

Sql := [].{

	## A call as the scan finds it: where it is (its file as given, its line and column from 1), its
	## function (`all!`, `run!`), its SQL (a literal's text, unescaped; or why there is none to
	## check), and how many parameters it gives, when they are a list literal.
	Found : { file : Str, line : U64, column : U64, call : Str, sql : [Literal(Str), Interpolated, Variable, Unchecked], given : [Count(U64), Unknown] }

	## The directories under an app that hold no source of its own: rocx's output, the build's, and
	## its tests'.
	skipped_dirs : List(Str)
	skipped_dirs = ["Generated", "build", "dist", "test", "node_modules"]

	## Every call in the app at `dir`: its .roc and .rocx files outside `skipped_dirs`, but those rocx
	## wrote (a component's .roc beside its .rocx), each file named as `dir` joined with its path.
	scan! : Str => List(Found)
	scan! = |dir| {
		skip = |path| Sql.skipped_dirs.contains(Fs.basename(path))
		var $found = []
		for path in Fs.files!(dir, ".roc", skip).concat(Fs.files!(dir, ".rocx", skip)) {
			text = Fs.read_or_empty!(path)
			if !Sql.is_generated(text) {
				$found = $found.concat(Sql.scan_text(path, text))
			}
		}
		$found
	}

	## Whether rocx wrote `text`: its last line is the marker.
	is_generated : Str -> Bool
	is_generated = |text| (Remap.trim_end(text).split_on("\n").last() ?? "").starts_with(Remap.marker)

	## The calls in one file's `text`. A call is `Db.all!(` or `Db.run!(` not inside a comment or a
	## string, nor after a letter, a digit, `_` or `.`.
	scan_text : Str, Str -> List(Found)
	scan_text = |file, text| {
		bytes = text.to_utf8()
		var $found = []
		var $from = 0
		var $going = Bool.True
		while $going {
			next = Sql.next_call(bytes, $from)
			match next {
				Ok({ at, call, open }) => {
					if Sql.is_code(bytes, at) {
						$found = $found.append(Sql.found_at(file, bytes, at, call, open))
					}
					$from = open + 1
				}
				Err(NotFound) => {
					$going = Bool.False
				}
			}
		}
		$found
	}

	## The next `Db.all!(` or `Db.run!(` at or after `from`: where it starts, its function, and where
	## its `(` is.
	next_call : List(U8), U64 -> Try({ at : U64, call : Str, open : U64 }, [NotFound])
	next_call = |bytes, from| {
		var $i = from
		while $i < bytes.len() {
			at = Text.index_of(bytes, "Db.".to_utf8(), $i)?
			before = if (at == 0) ' ' else Text.at(bytes, at - 1)
			bare = !(Text.is_word(before) or before == '.')
			if bare and Text.starts_with_at(bytes, "Db.all!(".to_utf8(), at) {
				return Ok({ at, call: "all!", open: at + 7 })
			}
			if bare and Text.starts_with_at(bytes, "Db.run!(".to_utf8(), at) {
				return Ok({ at, call: "run!", open: at + 7 })
			}
			$i = at + 3
		}
		Err(NotFound)
	}

	## Whether the byte at `at` is code: not in a comment (`#` before it on its line, outside a
	## string) nor in a string on its line.
	is_code : List(U8), U64 -> Bool
	is_code = |bytes, at| {
		var $i = Text.line_start(bytes, at)
		var $quoted = Bool.False
		while $i < at {
			c = Text.at(bytes, $i)
			if $quoted {
				if c == '\\' {
					$i = $i + 1
				} else if c == '"' {
					$quoted = Bool.False
				}
			} else if c == '"' {
				$quoted = Bool.True
			} else if c == '#' {
				return Bool.False
			}
			$i = $i + 1
		}
		!$quoted
	}

	## The call at `at`, its `(` at `open`: its SQL, and the parameters it gives.
	found_at : Str, List(U8), U64, Str, U64 -> Found
	found_at = |file, bytes, at, call, open| {
		start = Text.skip_space(bytes, open + 1)
		line = Text.line_of(bytes, at)
		column = Text.column(bytes, at)
		place = |sql, given| { file, line, column, call, sql, given }
		if Text.starts_with_at(bytes, "Db.unchecked(".to_utf8(), start) {
			return place(Unchecked, Unknown)
		}
		if Text.at(bytes, start) != '"' or Text.starts_with_at(bytes, "\"\"\"".to_utf8(), start) {
			return place(Variable, Unknown)
		}
		quoted = Sql.literal(bytes, start + 1)
		after = Text.skip_space(bytes, quoted.end)
		given =
			if Text.at(bytes, after) == ',' and Text.at(bytes, Text.skip_space(bytes, after + 1)) == '[' {
				match Sql.list_items(bytes, Text.skip_space(bytes, after + 1)) {
					Ok(count) => Count(count)
					Err(Unclosed) => Unknown
				}
			} else {
				Unknown
			}
		place(if (quoted.interpolated) Interpolated else Literal(quoted.text), given)
	}

	## The string literal whose text starts at `start` (just after its `"`): its text, unescaped
	## (`\"`, `\\`, `\$`, `\n`, `\r`, `\t`), whether it interpolates (`${…}`), and where it ends
	## (after its closing `"`).
	literal : List(U8), U64 -> { text : Str, interpolated : Bool, end : U64 }
	literal = |bytes, start| {
		var $out = []
		var $interpolated = Bool.False
		var $i = start
		while $i < bytes.len() and Text.at(bytes, $i) != '"' {
			c = Text.at(bytes, $i)
			if c == '\\' {
				escaped = Text.at(bytes, $i + 1)
				$out = $out.append(
					if escaped == 'n' {
						'\n'
					} else if escaped == 'r' {
						'\r'
					} else if escaped == 't' {
						'\t'
					} else {
						escaped
					},
				)
				$i = $i + 2
			} else if c == '$' and Text.at(bytes, $i + 1) == '{' {
				$interpolated = Bool.True
				$i = Sql.interpolation_end(bytes, $i + 2)
			} else {
				$out = $out.append(c)
				$i = $i + 1
			}
		}
		{ text: Str.from_utf8_lossy($out), interpolated: $interpolated, end: $i + 1 }
	}

	## Where an interpolation that starts at `start` (after its `${`) ends: after its `}`, braces and
	## strings inside it counted.
	interpolation_end : List(U8), U64 -> U64
	interpolation_end = |bytes, start| {
		var $depth = 1
		var $i = start
		while $i < bytes.len() and $depth > 0 {
			c = Text.at(bytes, $i)
			if c == '"' {
				$i = Sql.literal(bytes, $i + 1).end
			} else {
				if c == '{' {
					$depth = $depth + 1
				} else if c == '}' {
					$depth = $depth - 1
				}
				$i = $i + 1
			}
		}
		$i
	}

	## How many items the list literal at `open` (its `[`) has: its commas outside brackets and
	## strings, a trailing comma not counted.
	list_items : List(U8), U64 -> Try(U64, [Unclosed])
	list_items = |bytes, open| {
		var $depth = 0
		var $items = 0
		var $pending = Bool.False
		var $i = open
		while $i < bytes.len() {
			c = Text.at(bytes, $i)
			if c == '"' {
				$pending = Bool.True
				$i = Sql.literal(bytes, $i + 1).end
			} else {
				if c == '[' or c == '(' or c == '{' {
					$depth = $depth + 1
					if $depth > 1 {
						$pending = Bool.True
					}
				} else if c == ']' or c == ')' or c == '}' {
					$depth = $depth - 1
					if $depth == 0 {
						return Ok(if ($pending) $items + 1 else $items)
					}
				} else if c == ',' and $depth == 1 {
					$items = $items + 1
					$pending = Bool.False
				} else if c == '#' {
					$i = Text.line_end(bytes, $i) - 1
				} else if !Text.is_space_at(bytes, $i) {
					$pending = Bool.True
				}
				$i = $i + 1
			}
		}
		Err(Unclosed)
	}

	## The statements to describe: each literal's SQL, in the order found.
	statements : List(Found) -> List(Str)
	statements = |found|
		found.keep_oks(
			|each|
				match each.sql {
					Literal(text) => Ok(text)
					_ => Err(NoSql)
				},
		)

	## An engine as people write it.
	engine_name : Str -> Str
	engine_name = |engine|
		match engine {
			"sqlite" => "SQLite"
			"turso" => "Turso"
			"postgres" => "Postgres"
			other => other
		}

	## What is wrong with each literal statement, given what the engine said of each (`described`,
	## the server's answer to `--describe-sql`: `{ engine, statements }`, in the order of
	## `statements`): a line for each problem, `file:line:column: what`, and a last line that sums
	## up (with `verbose`, the calls not checked listed before it). `ok` when there is no problem.
	report : List(Found), Value, Bool -> { lines : List(Str), ok : Bool }
	report = |found, described, verbose| {
		engine = Sql.engine_name(Value.str(Value.field(described, "engine")))
		answers = Value.items(Value.field(described, "statements"))
		var $problems = []
		var $unchecked = []
		var $index = 0
		var $checked = 0
		for each in found {
			at = "${each.file}:${each.line.to_str()}:${each.column.to_str()}"
			match each.sql {
				Literal(_) => {
					answer = answers.get($index) ?? Null
					$index = $index + 1
					$checked = $checked + 1
					for problem in Sql.problems(answer, each.given, engine) {
						$problems = $problems.append("${at}: ${problem}")
					}
				}
				Interpolated => {
					$unchecked = $unchecked.append("${at}: not checked: its SQL is interpolated")
				}
				Variable => {
					$unchecked = $unchecked.append("${at}: not checked: its SQL isn't a string literal at the call")
				}
				Unchecked => {
					$unchecked = $unchecked.append("${at}: not checked: Db.unchecked")
				}
			}
		}
		wrong = $problems.len()
		said = if (wrong == 0) "no problems" else Sql.counted(wrong, "problem", "problems")
		left = if ($unchecked.is_empty()) "" else ", ${Sql.counted($unchecked.len(), "call", "calls")} not checked (--verbose lists them)"
		summary = if ($checked == 0) "rocx check --sql: no statements to check${left}" else "rocx check --sql: ${Sql.counted($checked, "statement", "statements")} checked on ${engine}: ${said}${left}"
		listed = if (verbose) $unchecked else []
		{ lines: $problems.concat(listed).append(summary), ok: wrong == 0 }
	}

	## `n` things: `1 call`, `2 calls`.
	counted : U64, Str, Str -> Str
	counted = |n, one, many| "${n.to_str()} ${if (n == 1) one else many}"

	## What is wrong with one statement, from what the engine said of it (`answer`) and the
	## parameters its call gives: the engine's error, parameters not named `$1`, `$2`…, one given
	## and not used, one used and not given, or one skipped.
	problems : Value, [Count(U64), Unknown], Str -> List(Str)
	problems = |answer, given, engine| {
		error = Value.field(answer, "error")
		if !Value.is_null(error) {
			return ["${engine} refuses it: ${Value.str(error)}"]
		}
		names = Value.items(Value.field(answer, "params")).map(Value.str)
		var $numbers = []
		var $said = []
		for name in names {
			match U64.from_str(name.drop_prefix("$").drop_prefix("?")) {
				Ok(n) if n >= 1 and (name.starts_with("$") or name.starts_with("?")) => {
					$numbers = $numbers.append(n)
				}
				_ => {
					$said = $said.append("parameter `${name}`: name the parameters $1, $2, …")
				}
			}
		}
		used = $numbers
		highest = used.fold(0, |most, n| if (n > most) n else most)
		match given {
			Count(k) => {
				plural = if (k == 1) "1 parameter is" else "${k.to_str()} parameters are"
				var $out = $said
				for n in used {
					if n > k {
						$out = $out.append("the statement uses $${n.to_str()}, and ${plural} given")
					}
				}
				var $n = 1
				while $n <= k {
					if !used.contains($n) {
						$out = $out.append("parameter $${$n.to_str()} is given, and the statement doesn't use it")
					}
					$n = $n + 1
				}
				$out
			}
			Unknown => {
				var $out = $said
				var $n = 1
				while $n < highest {
					if !used.contains($n) {
						$out = $out.append("the statement uses $${highest.to_str()} and not $${$n.to_str()}: every parameter is given up to the last, and each must be used")
					}
					$n = $n + 1
				}
				$out
			}
		}
	}

	## `found` as JSON, for rocx-cli/check-sql.mjs.
	found_value : Found -> Value
	found_value = |each| {
		sql =
			match each.sql {
				Literal(text) => Object([{ key: "literal", value: Text(text) }])
				Interpolated => Text("interpolated")
				Variable => Text("variable")
				Unchecked => Text("unchecked")
			}
		given =
			match each.given {
				Count(n) => Value.count(n)
				Unknown => Null
			}
		Object([
			{ key: "file", value: Text(each.file) },
			{ key: "line", value: Value.count(each.line) },
			{ key: "column", value: Value.count(each.column) },
			{ key: "call", value: Text(each.call) },
			{ key: "sql", value: sql },
			{ key: "given", value: given },
		])
	}

	## A call back from JSON (`found_value`).
	found_of : Value -> Found
	found_of = |value| {
		sql_value = Value.field(value, "sql")
		sql =
			match Value.str(sql_value) {
				"interpolated" => Interpolated
				"variable" => Variable
				"unchecked" => Unchecked
				_ => Literal(Value.str(Value.field(sql_value, "literal")))
			}
		given = if (Value.is_null(Value.field(value, "given"))) Unknown else Count(Value.int_or(Value.field(value, "given"), 0).to_u64_wrap())
		{
			file: Value.str(Value.field(value, "file")),
			line: Value.int_or(Value.field(value, "line"), 0).to_u64_wrap(),
			column: Value.int_or(Value.field(value, "column"), 0).to_u64_wrap(),
			call: Value.str(Value.field(value, "call")),
			sql,
			given,
		}
	}

	## `rocx internal`'s calls: `sqlScan(dir)` (the calls, and the statements to describe) and
	## `sqlReport(found, described, { verbose })`.
	rpc! : Str, List(Value) => Try(Value, [Failed(Value), Unknown(Str)])
	rpc! = |name, args| {
		arg = |i| args.get(i) ?? Null
		match name {
			"sqlScan" => {
				found = Sql.scan!(Value.str(arg(0)))
				Ok(Object([{ key: "found", value: Array(found.map(Sql.found_value)) }, { key: "statements", value: Value.strs(Sql.statements(found)) }]))
			}
			"sqlScanText" => Ok(Array(Sql.scan_text(Value.str(arg(0)), Value.str(arg(1))).map(Sql.found_value)))
			"sqlReport" => {
				reported = Sql.report(Value.items(arg(0)).map(Sql.found_of), arg(1), Value.bool_or(Value.field(arg(2), "verbose"), Bool.False))
				Ok(Object([{ key: "lines", value: Value.strs(reported.lines) }, { key: "ok", value: Boolean(reported.ok) }]))
			}
			_ => Err(Unknown(name))
		}
	}
}

expect {
	found = Sql.scan_text("Store.roc", "rows = Db.all!(\"select id from notes where author = $1\", [Int(author)])?")
	found == [{ file: "Store.roc", line: 1, column: 8, call: "all!", sql: Literal("select id from notes where author = $1"), given: Count(1) }]
}

# A literal's escapes; a list over lines with a trailing comma, a comma inside a string, a call inside.
expect {
	text = "\t_ = Db.run!(\n\t\t\"update t set a = $1 where b = \\\"x\\\" and c = $2\",\n\t\t[\n\t\t\tText(\"a, b\"),\n\t\t\tdec(grams),\n\t\t],\n\t)?\n"
	found = Sql.scan_text("S.roc", text)
	found == [{ file: "S.roc", line: 1, column: 6, call: "run!", sql: Literal("update t set a = $1 where b = \"x\" and c = $2"), given: Count(2) }]
}

# Interpolated, in a variable, Db.unchecked, a comment, a string, another module's Db.
expect {
	text = "a = Db.all!(\"select \${cols} from t\", [])\nb = Db.all!(sql, params)\nc = Db.run!(Db.unchecked(\"delete from orders\"), [])\n# Db.all!(\"select 1\", [])\nd = \"Db.all!(\"\ne = MyDb.all!(\"x\", [])\n"
	found = Sql.scan_text("S.roc", text)
	found.map(|each| each.sql) == [Interpolated, Variable, Unchecked]
}

# A list that isn't a literal gives no count; an empty one is 0.
expect {
	found = Sql.scan_text("S.roc", "Db.all!(\"select 1\", params)\nDb.run!(\"delete from t\", [])")
	found.map(|each| each.given) == [Unknown, Count(0)]
}

expect Sql.problems(Object([{ key: "error", value: Text("no such column: x") }]), Unknown, "SQLite") == ["SQLite refuses it: no such column: x"]

# Parameters: one too many given, one used and not given, one skipped, one misnamed.
expect {
	described = |names| Object([{ key: "params", value: Value.strs(names) }, { key: "columns", value: Array([]) }])
	Sql.problems(described(["$1"]), Count(2), "SQLite")
		== ["parameter $2 is given, and the statement doesn't use it"]
		and Sql.problems(described(["$1", "$2"]), Count(1), "SQLite")
			== ["the statement uses $2, and 1 parameter is given"]
		and Sql.problems(described(["$1", "$3"]), Unknown, "SQLite")
			== ["the statement uses $3 and not $2: every parameter is given up to the last, and each must be used"]
		and Sql.problems(described([":name"]), Unknown, "SQLite")
			== ["parameter `:name`: name the parameters $1, $2, …"]
		and Sql.problems(described(["$1", "$2"]), Count(2), "Postgres")
			== []
}

# A report: the engine's refusal at its call, a parameter count off, what wasn't checked summed up.
expect {
	found = Sql.scan_text("S.roc", "a = Db.all!(\"select kcals from foods\", [])\nb = Db.run!(\"delete from t where id = $1\", [Int(1), Int(2)])\nc = Db.all!(sql, [])\nd = Db.all!(\"select 1 as one\", [])\n")
	described = Object([
		{ key: "engine", value: Text("sqlite") },
		{
			key: "statements",
			value: Array([
				Object([{ key: "error", value: Text("no such column: kcals") }]),
				Object([{ key: "params", value: Value.strs(["$1"]) }, { key: "columns", value: Array([]) }]),
				Object([{ key: "params", value: Array([]) }, { key: "columns", value: Array([]) }]),
			]),
		},
	])
	Sql.report(found, described, Bool.False)
		== {
			lines: [
				"S.roc:1:5: SQLite refuses it: no such column: kcals",
				"S.roc:2:5: parameter $2 is given, and the statement doesn't use it",
				"rocx check --sql: 3 statements checked on SQLite: 2 problems, 1 call not checked (--verbose lists them)",
			],
			ok: Bool.False,
		}
}
