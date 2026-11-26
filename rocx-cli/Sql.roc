## `rocx check --sql` (D-058): an app's SQL checked by its own database engine. rocx finds each
## `Db.all!`, `Db.one!` and `Db.run!` whose SQL is a string literal at the call (`scan`), the app's server
## describes those statements on a scratch database built from its migrations (`--describe-sql`,
## which rocx-cli/CheckSql.roc runs), and rocx reports what the engine refused and parameters that
## don't match what the call gives (`report`). What it can't check (SQL interpolated, in a
## variable, or marked `Db.unchecked`) is counted, and listed with `--verbose`.
import Value
import Text
import Fs
import Remap
import Build
import Routes

Sql := [].{

	## A call as the scan finds it: where it is (its file as given, its line and column from 1), its
	## function (`all!`, `one!`, `run!`), its SQL (a literal's text, unescaped; or why there is none to
	## check), how many parameters it gives, when they are a list literal, and the type of its rows
	## when its annotation can be read (`row_type`: `""` when not), with whether that names a type
	## of the call's own module, `Store.Row` for `Row` (`qualified`).
	Found : { file : Str, line : U64, column : U64, call : Str, sql : [Literal(Str), Interpolated, Variable, Unchecked], given : [Count(U64), Unknown], row : Str, qualified : Bool }

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

	## The calls in one file's `text`. A call is `Db.all!(`, `Db.one!(` or `Db.run!(` not inside a
	## comment or a string, nor after a letter, a digit, `_` or `.`.
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

	## The next `Db.all!(`, `Db.one!(` or `Db.run!(` at or after `from`: where it starts, its
	## function, and where its `(` is.
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
			if bare and Text.starts_with_at(bytes, "Db.one!(".to_utf8(), at) {
				return Ok({ at, call: "one!", open: at + 7 })
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
		place = |sql, given| { file, line, column, call, sql, given, row: "", qualified: Bool.False }
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
		if quoted.interpolated {
			place(Interpolated, given)
		} else if call == "all!" or call == "one!" {
			typed = Sql.row_type(file, bytes, at, open, call)
			{ ..place(Literal(quoted.text), given), row: typed.row, qualified: typed.qualified }
		} else {
			place(Literal(quoted.text), given)
		}
	}

	## The type of the rows of the `Db.all!` or `Db.one!` (`call`) at `at` (its `(` at `open`) in the
	## file `file`, `bytes`: `T` in the `List(T)` (or `Try(List(T), …)`) of the binding's
	## annotation, `rows : List(T)` before `rows = Db.all!(…)`; for `one!`, the row's own
	## (`row : T` before `row = Db.one!(…)?`, or `Try(T, …)`, `one_item`); or of the result of the
	## function whose whole body the call is (`name! = |…| Db.all!(…)`, or the last expression of
	## its `{ … }`). A name the module declares (`Row` in `Store := [].{ Row : … }`) is qualified
	## with the module's (`Store.Row`). `""` when there is none to read, or it names a type the
	## module keeps to itself.
	row_type : Str, List(U8), U64, U64, Str -> { row : Str, qualified : Bool }
	row_type = |file, bytes, at, open, call| {
		item = |typed| if (call == "one!") Sql.one_item(typed) else Sql.list_item(typed)
		none = { row: "", qualified: Bool.False }
		line_start = Text.line_start(bytes, at)
		prefix = Text.trim(Text.cut(bytes, line_start, at))
		indent = Sql.indent_of(bytes, line_start)
		annotated =
			if prefix.is_empty() {
				# The last expression of a block: the block is a function's body when the line it
				# opens on is `name = |…| {`.
				match Sql.enclosing_def(bytes, line_start, indent) {
					Ok(def) if Sql.ends_block(bytes, open) => item(Sql.result_of(Sql.annotation(bytes, def.start, def.indent, def.name)))
					_ => ""
				}
			} else if prefix.ends_with("=") and !prefix.contains("|") {
				name = Text.trim(prefix.drop_suffix("="))
				if (Text.all_of(name, |c| Text.is_word(c)) and Sql.ends_expression(bytes, open)) item(Sql.annotation(bytes, line_start, indent, name)) else ""
			} else if prefix.ends_with("|") and prefix.contains("= |") and Sql.ends_expression(bytes, open) {
				name = Text.trim((prefix.split_first("=") ?? { before: "", after: "" }).before)
				item(Sql.result_of(Sql.annotation(bytes, line_start, indent, name)))
			} else {
				""
			}
		if annotated.is_empty() {
			return none
		}
		owner = Fs.basename(file).drop_suffix(".roc").drop_suffix(".rocx")
		local = Sql.declared(bytes)
		var $out = []
		var $qualified = Bool.False
		for word in Sql.words(annotated) {
			match word {
				Name(name) if local.inside.contains(name) => {
					$out = $out.append("${owner}.${name}")
					$qualified = Bool.True
				}
				Name(name) if local.outside.contains(name) => return none
				Name(name) => {
					$out = $out.append(name)
				}
				Other(text) => {
					$out = $out.append(text)
				}
			}
		}
		row = Str.join_with($out, "")
		# The module may name its own types qualified already (`Store.Person` in Store.roc).
		itself = $qualified or Sql.words(row).any(|word| word == Other(owner))
		if itself and !(file.ends_with(".roc") and Text.all_of(owner, |c| Text.is_word(c))) {
			return none
		}
		{ row, qualified: itself }
	}

	## How many spaces and tabs start the line at `start`.
	indent_of : List(U8), U64 -> U64
	indent_of = |bytes, start| {
		var $i = start
		while Text.at(bytes, $i) == ' ' or Text.at(bytes, $i) == '\t' {
			$i = $i + 1
		}
		$i - start
	}

	## The start of the line before the one at `start` (none before the first).
	previous_line : List(U8), U64 -> Try(U64, [None])
	previous_line = |bytes, start| if (start == 0) Err(None) else Ok(Text.line_start(bytes, start - 1))

	## Whether the line at `start` holds no code: blank, or a comment.
	is_blank_line : List(U8), U64 -> Bool
	is_blank_line = |bytes, start| {
		text = Text.trim(Text.cut(bytes, start, Text.line_end(bytes, start)))
		text.is_empty() or text.starts_with("#")
	}

	## The annotation of `name` in the block whose lines start at `indent`, looking up from the line
	## at `start`: what follows `name :`, over as many lines as its brackets take; `""` if the block
	## begins first.
	annotation : List(U8), U64, U64, Str -> Str
	annotation = |bytes, start, indent, name| {
		var $at = Sql.previous_line(bytes, start)
		while Bool.True {
			match $at {
				Err(None) => return ""
				Ok(line) => {
					if !Sql.is_blank_line(bytes, line) {
						here = Sql.indent_of(bytes, line)
						if here < indent {
							return ""
						}
						text = Text.trim(Text.cut(bytes, line, Text.line_end(bytes, line)))
						if here == indent and text.starts_with("${name} :") {
							return Sql.balanced(bytes, line + here + name.count_utf8_bytes() + 2)
						}
					}
					$at = Sql.previous_line(bytes, line)
				}
			}
		}
	}

	## The text from `start` to the end of its line, or further while its brackets stay open.
	balanced : List(U8), U64 -> Str
	balanced = |bytes, start| {
		var $depth = 0
		var $i = start
		while $i < bytes.len() {
			c = Text.at(bytes, $i)
			if c == '(' or c == '[' or c == '{' {
				$depth = $depth + 1
			} else if c == ')' or c == ']' or c == '}' {
				$depth = $depth - 1
			} else if c == '\n' and $depth <= 0 {
				return Text.trim(Text.cut(bytes, start, $i))
			}
			$i = $i + 1
		}
		Text.trim(Text.cut(bytes, start, $i)).replace_each("\n", " ")
	}

	## The definition a block opens on, looking up from its line at `start` (indented `indent`): the
	## first line above it indented less, when that is `name = |…| {`.
	enclosing_def : List(U8), U64, U64 -> Try({ start : U64, indent : U64, name : Str }, [None])
	enclosing_def = |bytes, start, indent| {
		var $at = Sql.previous_line(bytes, start)
		while Bool.True {
			line = $at?
			if !Sql.is_blank_line(bytes, line) and Sql.indent_of(bytes, line) < indent {
				text = Text.trim(Text.cut(bytes, line, Text.line_end(bytes, line)))
				if text.contains("= |") and text.ends_with("{") {
					name = Text.trim((text.split_first("=") ?? { before: "", after: "" }).before)
					if Text.all_of(name, |c| Text.is_word(c) or c == '!') {
						return Ok({ start: line, indent: Sql.indent_of(bytes, line), name })
					}
				}
				return Err(None)
			}
			$at = Sql.previous_line(bytes, line)
		}
	}

	## Where the call whose `(` is at `open` ends: after its `)`, strings and brackets inside counted.
	call_end : List(U8), U64 -> U64
	call_end = |bytes, open| {
		var $depth = 0
		var $i = open
		while $i < bytes.len() {
			c = Text.at(bytes, $i)
			if c == '"' {
				$i = Sql.literal(bytes, $i + 1).end
			} else {
				if c == '(' or c == '[' or c == '{' {
					$depth = $depth + 1
				} else if c == ')' or c == ']' or c == '}' {
					$depth = $depth - 1
					if $depth == 0 {
						return $i + 1
					}
				}
				$i = $i + 1
			}
		}
		$i
	}

	## Whether the expression the call whose `(` is at `open` starts gives its rows as they are: what
	## follows it, on its line or the lines after, is only `?` and `.map_err(…)`, which leave its
	## `Ok` alone.
	ends_expression : List(U8), U64 -> Bool
	ends_expression = |bytes, open| {
		var $i = Sql.call_end(bytes, open)
		while Bool.True {
			$i = Text.skip_space(bytes, $i)
			if Text.at(bytes, $i) == '?' {
				$i = $i + 1
			} else if Text.starts_with_at(bytes, ".map_err(".to_utf8(), $i) {
				$i = Sql.call_end(bytes, $i + 8)
			} else if Text.at(bytes, $i) == '#' {
				$i = Text.line_end(bytes, $i)
			} else {
				return !(Text.at(bytes, $i) == '.' or Text.at(bytes, $i) == '(' or Text.at(bytes, $i) == '[')
			}
		}
	}

	## Whether the call whose `(` is at `open` is its block's last expression: `ends_expression`,
	## and the next line with code closes the block (`}`).
	ends_block : List(U8), U64 -> Bool
	ends_block = |bytes, open| {
		if !Sql.ends_expression(bytes, open) {
			return Bool.False
		}
		var $i = Sql.call_end(bytes, open)
		while Bool.True {
			$i = Text.skip_space(bytes, $i)
			if Text.at(bytes, $i) == '?' {
				$i = $i + 1
			} else if Text.starts_with_at(bytes, ".map_err(".to_utf8(), $i) {
				$i = Sql.call_end(bytes, $i + 8)
			} else if Text.at(bytes, $i) == '#' {
				$i = Text.line_end(bytes, $i)
			} else {
				return Text.at(bytes, $i) == '}'
			}
		}
	}

	## `T` in an annotation `List(T)`, or `Try(List(T), …)`; `""` for another.
	list_item : Str -> Str
	list_item = |typed| {
		text = Text.trim(typed)
		inner = |wrapper|
			if text.starts_with("${wrapper}(") and text.ends_with(")") {
				Ok(text.drop_prefix("${wrapper}(").drop_suffix(")"))
			} else {
				Err(None)
			}
		match inner("Try") {
			Ok(args) => Sql.list_item(Sql.top_level(args).first() ?? "")
			Err(_) =>
				match inner("List") {
					Ok(item) if Sql.top_level(item).len() == 1 => Text.trim(item)
					_ => ""
				}
		}
	}

	## `T` in the annotation of a `Db.one!`'s row: `T` itself (`row : T`, before `row =
	## Db.one!(…)?`), or `Try(T, …)`; `""` for a `List(…)`, which no row is.
	one_item : Str -> Str
	one_item = |typed| {
		text = Text.trim(typed)
		if text.starts_with("Try(") and text.ends_with(")") {
			Sql.top_level(text.drop_prefix("Try(").drop_suffix(")")).first() ?? ""
		} else if text.starts_with("List(") {
			""
		} else {
			text
		}
	}

	## A function's result type, from its annotation: what follows its last `=>` or `->` (outside
	## brackets); `""` for an annotation that isn't a function's.
	result_of : Str -> Str
	result_of = |typed| {
		bytes = typed.to_utf8()
		var $depth = 0
		var $after = Err(None)
		var $i = 0
		while $i + 1 < bytes.len() {
			c = Text.at(bytes, $i)
			if c == '(' or c == '[' or c == '{' {
				$depth = $depth + 1
			} else if c == ')' or c == ']' or c == '}' {
				$depth = $depth - 1
			} else if $depth == 0 and (c == '=' or c == '-') and Text.at(bytes, $i + 1) == '>' {
				$after = Ok($i + 2)
			}
			$i = $i + 1
		}
		match $after {
			Ok(at) => Text.trim(Text.rest(bytes, at))
			Err(_) => ""
		}
	}

	## `text` split at its commas outside brackets, each part trimmed.
	top_level : Str -> List(Str)
	top_level = |text| {
		bytes = text.to_utf8()
		var $parts = []
		var $depth = 0
		var $start = 0
		var $i = 0
		while $i < bytes.len() {
			c = Text.at(bytes, $i)
			if c == '(' or c == '[' or c == '{' {
				$depth = $depth + 1
			} else if c == ')' or c == ']' or c == '}' {
				$depth = $depth - 1
			} else if c == ',' and $depth == 0 {
				$parts = $parts.append(Text.trim(Text.cut(bytes, $start, $i)))
				$start = $i + 1
			}
			$i = $i + 1
		}
		$parts.append(Text.trim(Text.rest(bytes, $start))).keep_if(|part| !part.is_empty())
	}

	## The type names a module declares: inside its nominal type's `.{ … }` (indented once: `Row :`,
	## `Kind :=`), which others name `Module.Row`; and at its top level, which only it can name.
	declared : List(U8) -> { inside : List(Str), outside : List(Str) }
	declared = |bytes| {
		var $inside = []
		var $outside = []
		for line in Str.from_utf8_lossy(bytes).split_on("\n") {
			once = line.starts_with("\t") and !line.starts_with("\t\t")
			text = Text.trim(line)
			name = Str.from_utf8_lossy(text.to_utf8().take_first(Text.run_end(text.to_utf8(), 0, Text.is_word)))
			after = Text.trim(text.drop_prefix(name))
			type_like = Text.is_upper(text.to_utf8().first() ?? 0) and (after.starts_with(":") or after.starts_with("("))
			if type_like and once {
				$inside = $inside.append(name)
			} else if type_like and !line.starts_with("\t") and !line.starts_with(" ") {
				$outside = $outside.append(name)
			}
		}
		{ inside: $inside, outside: $outside }
	}

	## A type's text as words: each capitalized name not after a `.` (`Row`, `Db`), and what is
	## between them.
	words : Str -> List([Name(Str), Other(Str)])
	words = |text| {
		bytes = text.to_utf8()
		var $out = []
		var $i = 0
		var $start = 0
		while $i < bytes.len() {
			c = Text.at(bytes, $i)
			starts = Text.is_upper(c) and ($i == 0 or !(Text.is_word(Text.at(bytes, $i - 1)) or Text.at(bytes, $i - 1) == '.'))
			if starts {
				end = Text.run_end(bytes, $i, Text.is_word)
				if $i > $start {
					$out = $out.append(Other(Text.cut(bytes, $start, $i)))
				}
				$out = $out.append(if (Text.at(bytes, end) == '.') Other(Text.cut(bytes, $i, end)) else Name(Text.cut(bytes, $i, end)))
				$i = end
				$start = end
			} else {
				$i = $i + 1
			}
		}
		if $start < bytes.len() {
			$out = $out.append(Other(Text.rest(bytes, $start)))
		}
		$out
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
	## up (with `verbose`, the calls not checked listed before it). `ok` when there is no problem,
	## and the check app (`checked_rows`) compiled.
	report : List(Found), Value, Rows, Bool -> { lines : List(Str), ok : Bool }
	report = |found, described, checked_rows, verbose| {
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
					for refused in checked_rows.refused.keep_if(|row| row.at == at) {
						$problems = $problems.append("${at}: ${refused.said}")
					}
					for skipped in checked_rows.skipped.keep_if(|row| row.at == at) {
						$unchecked = $unchecked.append("${at}: rows not checked: ${skipped.said}")
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
		read = checked_rows.checked - checked_rows.skipped.len()
		failed = checked_rows.failed
		against =
			if !failed.is_empty() {
				" (not every row checked: the check app didn't compile)"
			} else if read == 0 {
				""
			} else {
				" (the rows of ${read.to_str()} against their records)"
			}
		summary = if ($checked == 0) "rocx check --sql: no statements to check${left}" else "rocx check --sql: ${Sql.counted($checked, "statement", "statements")} checked on ${engine}${against}: ${said}${left}"
		listed = if (verbose) $unchecked else []
		# rocx's own app not compiling is an error, whatever the app's statements are: a check that
		# can't run says so, and fails, so that no app's rows go unchecked unseen.
		broken = failed.map(|why| "rocx check --sql: the check app didn't compile, so not every row was checked: ${why}")
		{ lines: $problems.concat(broken).concat(listed).append(summary), ok: wrong == 0 and failed.is_empty() }
	}

	## What the check app said of the rows (`rows`): how many it checked, those it refused and why,
	## those it couldn't check and why (each at its call), and what stopped it compiling (`failed`),
	## which leaves its rows unchecked.
	Rows : { checked : U64, refused : List({ at : Str, said : Str }), skipped : List({ at : Str, said : Str }), failed : List(Str) }

	## No rows checked.
	no_rows : Rows
	no_rows = { checked: 0, refused: [], skipped: [], failed: [] }

	## The check app (D-058, `build/sql/check/main.roc` beside a copy of the app): the app's header
	## (`dir`'s main.roc) with dbcheck added (`dbcheck`: packages/dbcheck/main.roc's path from the
	## app's directory, worked out from where both really are, since from two paths named from the
	## working directory it can't be when the app's starts with more `..` than rocx's), the imports
	## of the modules each call is in, the names a tag union is tried with (`Tags`), and for each
	## `Db.all!` whose row type the scan read and whose statement the engine described
	## (`described`), a constant `DbCheck.Rows(T, Tags)` whose string is the description, which the
	## compiler checks (`packages/dbcheck`). `entries`: the line of each constant's string, and its
	## call.
	check_app! : Str, List(Found), Value, Str => { text : Str, entries : List({ line : U64, at : Str }) }
	check_app! = |dir, found, described, dbcheck| {
		main_path = Fs.join([dir, "main.roc"])
		check_path = Fs.join([dir, "build", "sql", "check", "main.roc"])
		deps =
			match Build.app_header(Fs.read_or_empty!(main_path), Bool.True) {
				Ok(text) => Text.trim(text).drop_suffix(",")
				Err(NotFound) => return { text: "", entries: [] }
			}
		shown = Fs.dotted(dbcheck)
		header = Build.move_header("app [program] { ${deps}, dbcheck: ${Text.roc_string(shown)} }", main_path, check_path)
		engine = Value.str(Value.field(described, "engine"))
		answers = Value.items(Value.field(described, "statements"))
		var $index = 0
		var $imports = ["import pf.Server", "import dbcheck.DbCheck"]
		var $named = ["Server", "DbCheck"]
		var $lines = []
		var $entries = []
		var $read = []
		for each in found {
			match each.sql {
				Literal(_) => {
					answer = answers.get($index) ?? Null
					$index = $index + 1
					if !each.row.is_empty() and Value.is_null(Value.field(answer, "error")) {
						relative = Fs.relative(dir, each.file)
						if !$read.contains((relative, each.qualified)) {
							$read = $read.append((relative, each.qualified))
							for line in Sql.imports_of(relative, Fs.read_or_empty!(each.file), each.qualified) {
								named = Sql.import_name(line)
								if !$imports.contains(line) and !$named.contains(named) {
									$imports = $imports.append(line)
									$named = $named.append(named)
								}
							}
						}
						at = "${each.file}:${each.line.to_str()}:${each.column.to_str()}"
						n = $entries.len() + 1
						$lines = $lines.concat(["", "## ${at}", "q${n.to_str()} : DbCheck.Rows(${each.row}, Tags)", "q${n.to_str()} = ${Text.roc_string(Sql.description(at, engine, answer))}"])
						$entries = $entries.append({ line: $lines.len(), at })
					}
				}
				_ => {}
			}
		}
		if $entries.is_empty() {
			return { text: "", entries: [] }
		}
		var $codes = []
		for path in Sql.sources!(dir) {
			$codes = $codes.append(Fs.read_or_empty!(path))
		}
		tags = Routes.tag_names($codes)
		quoted = Str.join_with(tags.map(Text.roc_string), ", ")
		before = [
			"## Written by rocx check --sql (D-058): each constant below is a call's rows, its string what",
			"## the database said of the statement's columns, which DbCheck.Rows checks when this compiles.",
			header,
			"",
		].concat($imports).concat([
			"",
			"## The names a tag union in a row is tried with: the capitalized words in the app's code.",
			"Tags := [].{",
			"\tnames : {} -> List(Str)",
			"\tnames = |{}| [${quoted}]",
			"}",
		])
		used = Str.join_with($entries.map_with_index(|_, i| "DbCheck.Rows.at(q${(i + 1).to_str()})"), ", ")
		after = [
			"",
			"program = {",
			"\tinit!: |_started| Ok({}),",
			"\trespond!: |_, _| Server.response(200, [], Str.join_with([${used}], \"\\n\")),",
			"\tdatabase: Sqlite(\"check.db\"),",
			"\tmigrations: [],",
			"\tactors: [],",
			"\tlogs: { format: Auto },",
			"\tplugins: [],",
			"\troutes: [],",
			"}",
			"",
		]
		header_lines = Str.join_with(before, "\n").split_on("\n").len()
		{
			text: Str.join_with(before.concat($lines).concat(after), "\n"),
			entries: $entries.map(|entry| { ..entry, line: entry.line + header_lines }),
		}
	}

	## The app's own .roc and .rocx files (not those under `skipped_dirs`).
	sources! : Str => List(Str)
	sources! = |dir| {
		skip = |path| Sql.skipped_dirs.contains(Fs.basename(path))
		Fs.files!(dir, ".roc", skip).concat(Fs.files!(dir, ".rocx", skip))
	}

	## A statement's description as `DbCheck.description` reads it: where its call is and the
	## engine, then a line a column (its name, kind, type, origin, `yes`/`no`/`` not null).
	description : Str, Str, Value -> Str
	description = |at, engine, answer| {
		columns = Value.items(Value.field(answer, "columns")).map(
			|column| {
				text = |key| if (Value.is_null(Value.field(column, key))) "" else Value.str(Value.field(column, key))
				table = text("table")
				origin = if (table.is_empty()) "" else "${table}.${text("column")}"
				not_null =
					match Value.field(column, "not_null") {
						Boolean(yes) => if (yes) "yes" else "no"
						_ => ""
					}
				Str.join_with([text("name"), text("kind"), text("type"), origin, not_null], "\t")
			},
		)
		Str.join_with(["${at}\t${engine}"].concat(columns), "\n")
	}

	## The imports the check app takes from the module at `relative` (from the app's directory),
	## `code`: its package imports as they are, its modules' with their paths from the app's
	## directory; the module itself too when the row names its types (`qualified`). A file's
	## (`import "…" as … : Str`) and an import that renames (`as`, `exposing`) are left out.
	imports_of : Str, Str, Bool -> List(Str)
	imports_of = |relative, code, qualified| {
		here = Fs.dirname(relative)
		path_of = |target| {
			joined = Fs.normalize(if (here == "." or here.is_empty()) target else "${here}/${target}")
			if (joined.starts_with("..")) Err(Outside) else Ok("import ${joined}")
		}
		var $out = []
		for line in code.split_on("\n") {
			if line.starts_with("import ") and !line.starts_with("import \"") and !line.contains(" as ") and !line.contains(" exposing") {
				target = Text.trim(line.drop_prefix("import "))
				first = (target.split_on("/").first() ?? "")
				is_package = !target.contains("/") and target.contains(".") and !target.starts_with(".")
				if is_package {
					$out = $out.append("import ${target}")
				} else if first != "" {
					match path_of(target) {
						Ok(imported) => {
							$out = $out.append(imported)
						}
						Err(Outside) => {}
					}
				}
			}
		}
		if qualified {
			match path_of(Fs.basename(relative).drop_suffix(".roc")) {
				Ok(itself) => $out.append(itself)
				Err(Outside) => $out
			}
		} else {
			$out
		}
	}

	## The name an import line brings in: `Store` for `import ../Store`, `Db` for `import pf.Db`.
	import_name : Str -> Str
	import_name = |line| {
		target = line.drop_prefix("import ")
		last = target.split_on("/").last() ?? target
		last.split_on(".").last() ?? last
	}

	## What `roc check` said of the check app (`output`; `code`, its exit code; `check`, the check
	## app's directory as the report names it; its `entries`): each constant whose string
	## `DbCheck.Rows` refused, with what it said; each the compiler couldn't check (a type the app
	## can't name there); and `failed`, what stopped the check app compiling, so that its rows
	## weren't checked: an error that isn't a row's (in the check app, or in the copy of the app's
	## modules beside it), its title and place and then what the compiler said, indented; or an
	## exit that isn't `roc check`'s 0, 2 (warnings) or 1 with an error rocx read.
	rows : Str, I32, Str, List({ line : U64, at : Str }) -> Rows
	rows = |output, code, check, entries| {
		var $refused = []
		var $skipped = []
		var $failed = []
		var $errors = 0
		for said_of in ("\n${output}").split_on("\n── ") {
			lines = said_of.split_on("\n")
			title_line = (lines.first() ?? "").drop_prefix("── ")
			if title_line.starts_with("✗") {
				$errors = $errors + 1
				said_words = title_line.split_on(" ").keep_if(|word| !word.is_empty() and !word.starts_with("─")).drop_first(1)
				# The last word is where, unless the compiler said nowhere (a package it couldn't load).
				last = said_words.last() ?? ""
				place = if (last.contains(":")) last else ""
				title = Str.join_with(if (place.is_empty()) said_words else said_words.drop_last(1), " ")
				parts = place.split_on(":")
				file = parts.first() ?? ""
				line = U64.from_str(parts.get(1) ?? "") ?? 0
				entry = if (file == "main.roc") entries.find_first(|each| line == each.line or line + 1 == each.line) else Err(NotFound)
				match entry {
					Ok(at) => {
						said = Sql.returned(lines)
						if said.is_empty() {
							$skipped = $skipped.append({ at: at.at, said: "the check couldn't name their type (${title})" })
						} else {
							$refused = $refused.append({ at: at.at, said: Sql.without_place(said, at.at) })
						}
					}
					Err(_) => {
						located = if (place.is_empty()) "" else " at ${check}/${place}"
						$failed = $failed.append(Str.join_with(["${title}${located}"].concat(Sql.indented(lines.drop_first(1))), "\n"))
					}
				}
			}
		}
		if code != 0 and code != 1 and code != 2 {
			$failed = $failed.append(Str.join_with(["roc check stopped (exit code ${code.to_str()})"].concat(Sql.indented(output.split_on("\n").take_last(20))), "\n"))
		} else if code == 1 and $errors == 0 {
			$failed = $failed.append(Str.join_with(["roc check failed, and said no error rocx could read"].concat(Sql.indented(output.split_on("\n").take_last(20))), "\n"))
		}
		{ checked: entries.len(), refused: $refused, skipped: $skipped, failed: $failed }
	}

	## What DbCheck said of a row (`said`, the compiler's wrapped lines joined with a space) without
	## the place it starts with (`place`, the call's) and the `: ` after it. The compiler wraps a long
	## place too, at a `-` as well as a space, so a space in `said` where `place` has none is passed
	## over; `said` as it is when it doesn't start with `place`.
	without_place : Str, Str -> Str
	without_place = |said, place| {
		bytes = said.to_utf8()
		want = "${place}:".to_utf8()
		var $i = 0
		var $j = 0
		while $j < want.len() {
			if $i >= bytes.len() {
				return said
			} else if Text.at(bytes, $i) == Text.at(want, $j) {
				$i = $i + 1
				$j = $j + 1
			} else if Text.at(bytes, $i) == ' ' {
				$i = $i + 1
			} else {
				return said
			}
		}
		Text.trim_start(Text.rest(bytes, $i))
	}

	## A compiler's report's lines, two spaces in, without the blank lines it starts and ends with.
	indented : List(Str) -> List(Str)
	indented = |lines| {
		var $kept = lines
		while ($kept.first() ?? "x").trim().is_empty() and !$kept.is_empty() {
			$kept = $kept.drop_first(1)
		}
		while ($kept.last() ?? "x").trim().is_empty() and !$kept.is_empty() {
			$kept = $kept.drop_last(1)
		}
		$kept.map(|line| if (line.trim().is_empty()) "" else "  ${line}")
	}

	## The message a report quotes after "It returned this error message:", its lines joined.
	returned : List(Str) -> Str
	returned = |lines| {
		var $in = Bool.False
		var $out = []
		for line in lines {
			if $in {
				text = Text.trim(line)
				if !text.is_empty() {
					$out = $out.append(text)
				} else if !$out.is_empty() {
					return Str.join_with($out, " ")
				}
			} else if Text.trim(line) == "It returned this error message:" {
				$in = Bool.True
			}
		}
		Str.join_with($out, " ")
	}

	## `rows` as JSON, and back.
	rows_value : Rows -> Value
	rows_value = |checked| {
		pairs = |list| Array(list.map(|each| Object([{ key: "at", value: Text(each.at) }, { key: "said", value: Text(each.said) }])))
		Object([{ key: "checked", value: Value.count(checked.checked) }, { key: "refused", value: pairs(checked.refused) }, { key: "skipped", value: pairs(checked.skipped) }, { key: "failed", value: Value.strs(checked.failed) }])
	}

	rows_of : Value -> Rows
	rows_of = |value| {
		pairs = |key| Value.items(Value.field(value, key)).map(|each| { at: Value.str(Value.field(each, "at")), said: Value.str(Value.field(each, "said")) })
		{ checked: Value.int_or(Value.field(value, "checked"), 0).to_u64_wrap(), refused: pairs("refused"), skipped: pairs("skipped"), failed: Value.items(Value.field(value, "failed")).map(Value.str) }
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

	## `found` as JSON, for `rocx internal`.
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
			{ key: "row", value: Text(each.row) },
			{ key: "qualified", value: Boolean(each.qualified) },
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
			row: Value.str(Value.field(value, "row")),
			qualified: Value.bool_or(Value.field(value, "qualified"), Bool.False),
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
			"sqlCheckApp" => {
				made = Sql.check_app!(Value.str(arg(0)), Value.items(arg(1)).map(Sql.found_of), arg(2), Fs.relative(Value.str(arg(0)), Fs.join([Value.str(arg(3)), "packages", "dbcheck", "main.roc"])))
				Ok(Object([{ key: "text", value: Text(made.text) }, { key: "entries", value: Array(made.entries.map(|entry| Object([{ key: "line", value: Value.count(entry.line) }, { key: "at", value: Text(entry.at) }]))) }]))
			}
			"sqlRows" => {
				entries = Value.items(arg(1)).map(|entry| { line: Value.int_or(Value.field(entry, "line"), 0).to_u64_wrap(), at: Value.str(Value.field(entry, "at")) })
				Ok(Sql.rows_value(Sql.rows(Value.str(arg(0)), Value.int_or(arg(2), 1).to_i32_wrap(), Value.str(arg(3)), entries)))
			}
			"sqlScanText" => Ok(Array(Sql.scan_text(Value.str(arg(0)), Value.str(arg(1))).map(Sql.found_value)))
			"sqlReport" => {
				reported = Sql.report(Value.items(arg(0)).map(Sql.found_of), arg(1), Sql.rows_of(Value.field(arg(2), "rows")), Value.bool_or(Value.field(arg(2), "verbose"), Bool.False))
				Ok(Object([{ key: "lines", value: Value.strs(reported.lines) }, { key: "ok", value: Boolean(reported.ok) }]))
			}
			_ => Err(Unknown(name))
		}
	}
}

expect {
	found = Sql.scan_text("Store.roc", "rows = Db.all!(\"select id from notes where author = $1\", [Int(author)])?")
	found == [{ file: "Store.roc", line: 1, column: 8, call: "all!", sql: Literal("select id from notes where author = $1"), given: Count(1), row: "", qualified: Bool.False }]
}

# A literal's escapes; a list over lines with a trailing comma, a comma inside a string, a call inside.
expect {
	text = "\t_ = Db.run!(\n\t\t\"update t set a = $1 where b = \\\"x\\\" and c = $2\",\n\t\t[\n\t\t\tText(\"a, b\"),\n\t\t\tdec(grams),\n\t\t],\n\t)?\n"
	found = Sql.scan_text("S.roc", text)
	found == [{ file: "S.roc", line: 1, column: 6, call: "run!", sql: Literal("update t set a = $1 where b = \"x\" and c = $2"), given: Count(2), row: "", qualified: Bool.False }]
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
	Sql.report(found, described, Sql.no_rows, Bool.False)
		== {
			lines: [
				"S.roc:1:5: SQLite refuses it: no such column: kcals",
				"S.roc:2:5: parameter $2 is given, and the statement doesn't use it",
				"rocx check --sql: 3 statements checked on SQLite: 2 problems, 1 call not checked (--verbose lists them)",
			],
			ok: Bool.False,
		}
}

# Row types: a binding's annotation (a List, a Try of one), a function's result when the call is its
# body (one line, or a block's last expression), a module's own type qualified; none for a call
# whose rows something else takes, or a type the module keeps to itself.
expect {
	text =
		\\Store := [].{
		\\	Row : { id : I64, kind : Kind }
		\\	Kind : [Small, Large]
		\\
		\\	one! = |{}| {
		\\		rows : List({ id : I64, note : Db.Nullable(Str) })
		\\		rows = Db.all!("select id, note from notes", [])?
		\\		tried : Try(List(Plate.Entry), [DbErr(Str), BadRow(Str)])
		\\		tried = Db.all!("select * from entries", [])
		\\		mapped : List(I64)
		\\		mapped = Db.all!("select id from notes", [])?.map(|row| row.id)
		\\		Ok(rows)
		\\	}
		\\
		\\	listed! : {} => Try(List(Row), [DbErr(Str), BadRow(Str)])
		\\	listed! = |{}| Db.all!("select id, kind from things", [])
		\\
		\\	last! : Str => Try(List({ kind : Kind }), [DbErr(Str), BadRow(Str)])
		\\	last! = |slug| {
		\\		_ = Db.run!("update things set seen = 1", [])?
		\\		Db.all!(
		\\			"select kind from things where slug = $1",
		\\			[Text(slug)],
		\\		)
		\\			.map_err(|problem| problem)
		\\	}
		\\
		\\	hidden! : {} => Try(List(Secret), [DbErr(Str), BadRow(Str)])
		\\	hidden! = |{}| Db.all!("select 1 as one", [])
		\\}
		\\
		\\Secret : { one : I64 }
	found = Sql.scan_text("app/Store.roc", text)
	found.map(|each| (each.row, each.qualified))
		== [
			("{ id : I64, note : Db.Nullable(Str) }", Bool.False),
			("Plate.Entry", Bool.False),
			("", Bool.False),
			("Store.Row", Bool.True),
			("", Bool.False),
			("{ kind : Store.Kind }", Bool.True),
			("", Bool.False),
		]
}

# `Db.one!`'s row (D-096): a binding's annotation, the row itself (the call `?`d) or a `Try` of it;
# a function's result, `Try(T, …)`, a module's own type qualified; none for a list, which no row is.
expect {
	text =
		\\Store := [].{
		\\	Row : { id : I64 }
		\\
		\\	one! = |{}| {
		\\		row : { id : I64, note : Db.Nullable(Str) }
		\\		row = Db.one!("select id, note from notes where id = 1", [])?
		\\		tried : Try(Plate.Entry, [NotFound, DbErr(Str), BadRow(Str)])
		\\		tried = Db.one!("select * from entries limit 1", [])
		\\		listed : List({ id : I64 })
		\\		listed = Db.one!("select id from notes", [])?
		\\		Ok(row)
		\\	}
		\\
		\\	first! : {} => Try(Row, [NotFound, DbErr(Str), BadRow(Str)])
		\\	first! = |{}| Db.one!("select id from things order by id limit 1", [])
		\\}
	found = Sql.scan_text("app/Store.roc", text)
	found.map(|each| (each.call, each.row, each.qualified))
		== [
			("one!", "{ id : I64, note : Db.Nullable(Str) }", Bool.False),
			("one!", "Plate.Entry", Bool.False),
			("one!", "", Bool.False),
			("one!", "Store.Row", Bool.True),
		]
}

# A module that names its own type qualified already needs itself imported all the same.
# What roc check said of a check app: a row refused (DbCheck's words, after the error message line),
# a row whose type it couldn't name, and an error that is no row's (the check app not compiling, in
# a module of the copy here), its place from the check app's directory and the compiler's words;
# one with no place (a package it couldn't load); a crash, an error said in no way rocx reads; and a
# clean check, warnings only.
expect {
	entries = [{ line: 10, at: "S.roc:1:5" }, { line: 14, at: "S.roc:2:5" }]
	output = Str.join_with(
		[
			"── ✗ invalid string ─────────── main.roc:10:6",
			"",
			"It returned this error message:",
			"",
			"    S.roc:1:5: `id` isn't a column the statement returns (it returns n)",
			"",
			"── ✗ unknown type ─────────── main.roc:13:20",
			"",
			"Nothing is named Person here.",
			"",
			"── ✗ type mismatch ─────────── Store.roc:7:11",
			"",
			"This number is being used where a non-number type is needed.",
			"",
			"broken = 1",
			"         ^",
			"",
			"── ● unused variable ─────────── main.roc:3:2",
			"",
			"Variable x is defined here and then never used.",
			"",
			"── 3 errors and 1 warning ─────────── main.roc",
			"",
		],
		"\n",
	)
	Sql.rows(output, 1, "app/build/sql/check", entries)
		== {
			checked: 2,
			refused: [{ at: "S.roc:1:5", said: "`id` isn't a column the statement returns (it returns n)" }],
			skipped: [{ at: "S.roc:2:5", said: "the check couldn't name their type (unknown type)" }],
			failed: ["type mismatch at app/build/sql/check/Store.roc:7:11\n  This number is being used where a non-number type is needed.\n\n  broken = 1\n           ^"],
		}
}

# A long place, wrapped by the compiler where a `-` is, dropped all the same.
expect Sql.without_place("../far/rocx-sql -check-x/S.roc:1:5: `id` isn't a column", "../far/rocx-sql-check-x/S.roc:1:5") == "`id` isn't a column"
expect Sql.without_place("S.roc:1:5: `id` isn't a column", "S.roc:1:5") == "`id` isn't a column"
expect Sql.without_place("Elsewhere: `id`", "S.roc:1:5") == "Elsewhere: `id`"

expect Sql.rows("── ✗ invalid package dependency ──────────\n\nCould not load the package at\nx/main.roc:\nFileNotFound.\n\n── 1 error and 0 warnings ───── main.roc\n", 1, "c", []).failed
	== ["invalid package dependency\n  Could not load the package at\n  x/main.roc:\n  FileNotFound."]

expect Sql.rows("thread 'main' panicked\n", 134, "c", [{ line: 10, at: "S.roc:1:5" }]).failed == ["roc check stopped (exit code 134)\n  thread 'main' panicked"]

expect Sql.rows("Something went wrong.\n", 1, "c", []).failed == ["roc check failed, and said no error rocx could read\n  Something went wrong."]

expect Sql.rows("── ● unused variable ─── main.roc:3:2\n\nVariable x is defined here and then never used.\n", 2, "c", [{ line: 10, at: "S.roc:1:5" }]) == { checked: 1, refused: [], skipped: [], failed: [] }

# A check app that didn't compile: said before the summary, which says its rows weren't all
# checked, and the check fails, though every statement is right.
expect {
	found = Sql.scan_text("S.roc", "rows : List({ id : I64 })\nrows = Db.all!(\"select 1 as id\", [])?\n")
	described = Object([{ key: "engine", value: Text("sqlite") }, { key: "statements", value: Array([Object([{ key: "params", value: Array([]) }, { key: "columns", value: Array([]) }])]) }])
	Sql.report(found, described, { checked: 1, refused: [], skipped: [], failed: ["type mismatch at c/main.roc:9:3\n  Why."] }, Bool.False)
		== {
			lines: [
				"rocx check --sql: the check app didn't compile, so not every row was checked: type mismatch at c/main.roc:9:3\n  Why.",
				"rocx check --sql: 1 statement checked on SQLite (not every row checked: the check app didn't compile): no problems",
			],
			ok: Bool.False,
		}
}

expect {
	text = "Store := [].{\n\tPerson : { id : Str }\n\n\tperson! = |{}| {\n\t\tfound : Try(List(Store.Person), [DbErr(Str)])\n\t\tfound = Db.all!(\"select id from people\", [])\n\t\tfound\n\t}\n}\n"
	Sql.scan_text("app/Store.roc", text).map(|each| (each.row, each.qualified)) == [("Store.Person", Bool.True)]
}
