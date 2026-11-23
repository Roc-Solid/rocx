## Points the Roc compiler's reports into .rocx files. Generated files keep the .rocx file's
## lines, so a report at `Page.roc:22:48` is about line 22 of Page.rocx; this rewrites the
## location, prints the .rocx line instead of the generated one, and moves the caret onto the
## same code there (a hole's expression is copied as written, so it can be found again).
## Columns are counted in UTF-16 units.
import Value
import Text
import Fs

Remap := [].{

	## The last lines of every generated file start with this.
	marker : Str
	marker = "# rocx: generated from"

	## What `rocx check` adds to a report about a line where a component is given a record's fields
	## (`<Base {...rest} />`, D-052), which rocx wrote as Roc's record update, `{ ..rest, size: … }`,
	## since it doesn't know the record's fields.
	spread_hint : Str
	spread_hint = "Hint: rocx passes {...record} on as Roc's record update ({ ..record, … }) when it doesn't know the record's fields: the component's props must then be the record's type, and each attribute beside it one of its fields. Annotate the props of the view that names the record (view! : { … } => Html, or Props := { … }), so rocx writes its fields out one by one, and attributes may add some."

	## What it adds when it wrote the fields out (`label: rest.label`): the component takes each.
	fields_hint : Str
	fields_hint = "Hint: rocx passes {...record} on field by field (label: record.label, …), each as it is (a getter stays one): the component must take each field the record has, or leave it out of the record first (|{ unwanted, ..record }|)."

	## A generated file's lines and its .rocx file's, and the .rocx file's path as reports name it.
	Entry : { rocx : Str, generated : List(Str), source : List(Str) }

	## A location in a line (`Page.roc:22:48`: `([^\s:()]+\.roc):(\d+):(\d+)`, the first): the file,
	## the line and column as written, and where it starts and ends in the line's bytes.
	Location : { file : Str, line_number : U64, column : I64, start : U64, end : U64 }

	## JavaScript's `trim()`. (Text.trim reads before the start of a blank string: it is guarded here.)
	trim : Str -> Str
	trim = |line| if (Text.is_blank(line)) "" else Text.trim(line)

	## JavaScript's `trimEnd()`, guarded as `trim` is.
	trim_end : Str -> Str
	trim_end = |line| if (Text.is_blank(line)) "" else Text.trim_end(line)

	## Whether the byte at `i` ends a location's file: JavaScript's whitespace, `:`, `(` or `)`.
	stops_file : List(U8), U64 -> Bool
	stops_file = |bytes, i| {
		b = Text.at(bytes, i)
		Text.is_space_at(bytes, i) or b == ':' or b == '(' or b == ')'
	}

	## The first location in a line.
	location : Str -> Try(Location, [NoLocation])
	location = |line| {
		bytes = line.to_utf8()
		var $i = 0
		while $i < bytes.len() {
			if Remap.stops_file(bytes, $i) {
				$i = $i + 1
			} else {
				start = $i
				var $end = $i
				while $end < bytes.len() and !Remap.stops_file(bytes, $end) {
					$end = $end + 1
				}
				file = Text.cut(bytes, start, $end)
				if Text.at(bytes, $end) == ':' and $end - start >= 5 and file.ends_with(".roc") {
					first_end = Text.run_end(bytes, $end + 1, Text.is_digit)
					if first_end > $end + 1 and Text.at(bytes, first_end) == ':' {
						second_end = Text.run_end(bytes, first_end + 1, Text.is_digit)
						if second_end > first_end + 1 {
							return Ok({
								file,
								line_number: Remap.number(Text.cut(bytes, $end + 1, first_end)).to_u64_wrap(),
								column: Remap.number(Text.cut(bytes, first_end + 1, second_end)),
								start,
								end: second_end,
							})
						}
					}
				}
				$i = if ($end > $i) $end else $i + 1
			}
		}
		Err(NoLocation)
	}

	## Digits as a number.
	number : Str -> I64
	number = |digits| digits.to_utf8().fold(0, |n, d| n * 10 + (d - '0').to_i64())

	## A line's UTF-16 units: what a JavaScript string's indices count.
	units : Str -> List(U32)
	units = |line|
		Text.code_points(line).fold(
			[],
			|out, code|
				if code < 0x10000 {
					out.append(code)
				} else {
					out.concat([0xD800 + (code - 0x10000) // 0x400, 0xDC00 + (code - 0x10000) % 0x400])
				},
		)

	## Whether a UTF-16 unit is JavaScript's whitespace.
	is_space_unit : U32 -> Bool
	is_space_unit = |u|
		(u >= 0x09 and u <= 0x0D) or u == 0x20 or u == 0xA0 or u == 0x1680 or (u >= 0x2000 and u <= 0x200A) or u == 0x2028 or u == 0x2029 or u == 0x202F or u == 0x205F or u == 0x3000 or u == 0xFEFF

	## How many UTF-16 units of whitespace a line starts with:
	## `line.length - line.trimStart().length`.
	indent_units : Str -> I64
	indent_units = |line| (Text.length(line) - Text.length(Text.trim_start(line))).to_i64_wrap()

	## JavaScript's `slice(start, end)` of a list: negative indices count from the end.
	js_slice : List(U32), I64, I64 -> List(U32)
	js_slice = |list, start, end| {
		len = list.len().to_i64_wrap()
		clamp = |i| if (i < 0) (if (len + i < 0) 0 else len + i) else if (i > len) len else i
		from = clamp(start)
		to = clamp(end)
		if (to <= from) [] else list.sublist({ start: from.to_u64_wrap(), len: (to - from).to_u64_wrap() })
	}

	## JavaScript's `indexOf(needle, from)`: where `needle` is at `from` or after, or -1.
	index_of : List(U32), List(U32), I64 -> I64
	index_of = |hay, needle, from| {
		len = hay.len().to_i64_wrap()
		n = needle.len().to_i64_wrap()
		var $at = if (from < 0) 0 else if (from > len) len else from
		while $at + n <= len {
			if hay.sublist({ start: $at.to_u64_wrap(), len: n.to_u64_wrap() }) == needle {
				return $at
			}
			$at = $at + 1
		}
		-1
	}

	## The column in `source_line` of the code under the caret in `generated_line` (both untrimmed).
	map_column : Str, Str, I64, I64 -> I64
	map_column = |generated_line, source_line, column, width| {
		generated = Remap.units(generated_line)
		source = Remap.units(source_line)
		snippet = Remap.js_slice(generated, column - 1, column - 1 + (if (width > 1) width else 1))
		if snippet.any(|u| !Remap.is_space_unit(u)) {
			# The k-th occurrence of the snippet in the generated line is the k-th in the source line.
			var $occurrence = 0
			var $seen = Remap.index_of(generated, snippet, 0)
			while $seen >= 0 and $seen < column - 1 {
				$occurrence = $occurrence + 1
				$seen = Remap.index_of(generated, snippet, $seen + 1)
			}
			var $at = -1
			var $k = 0
			var $lost = Bool.False
			while $k <= $occurrence and !$lost {
				$at = Remap.index_of(source, snippet, $at + 1)
				if $at < 0 {
					$lost = Bool.True
				}
				$k = $k + 1
			}
			if $at >= 0 {
				return $at + 1
			}
		}
		Remap.indent_units(source_line) + 1
	}

	## Whether a line is a caret line: `/^\s*\^+\s*$/`.
	is_caret_line : Str -> Bool
	is_caret_line = |line| {
		bytes = line.to_utf8()
		start = Text.skip_space(bytes, 0)
		carets = Text.run_end(bytes, start, |b| b == '^')
		carets > start and Text.skip_space(bytes, carets) == bytes.len()
	}

	## The generated file's lines and its source's: the .rocx beside it, or, for a route's module
	## (Generated/ShowcasePage.roc), the route file its last line names (a `+page.rocx`, or a
	## `+server.roc`, whose module's line may share a line with its first definition). None for a file
	## rocx didn't write.
	entry! : Str, Str => [Some(Entry), None]
	entry! = |file, cwd| {
		text = if (Fs.exists!(file)) Fs.read_or_empty!(file) else ""
		last = Remap.trim_end(text).split_on("\n").last() ?? ""
		named_rocx = Remap.named(last)
		besides = file.drop_suffix(".roc").concat(".rocx")
		rocx =
			if Fs.exists!(besides) {
				Some(besides)
			} else {
				match named_rocx {
					Some(name) => Some(Fs.join([Fs.dirname(file), name]))
					None => None
				}
			}
		shown = |path| {
			relative = Fs.relative(cwd, Fs.resolve(cwd, [path]))
			if (relative.is_empty()) path else relative
		}
		match rocx {
			Some(path) if last.starts_with(Remap.marker) and Fs.exists!(path) =>
				Some({
					rocx: shown(path),
					generated: text.split_on("\n"),
					source: Fs.read_or_empty!(path).split_on("\n"),
				})
			_ =>
			# A file of a browser's copy (`rocx build --client`), which has no .rocx files: the app's,
			# where the copy's `.rocx-client` says the app is. A file rocx wrote there for a .rocx file
			# keeps its lines; any other is the app's, copied as it is.
				match Remap.app_of!(Fs.resolve(cwd, [file])) {
					None => None
					Some(twin) =>
						match named_rocx {
							Some(name) if last.starts_with(Remap.marker) => {
								source = Fs.join([Fs.dirname(twin), name])
								if (Fs.exists!(source)) Some({ rocx: shown(source), generated: text.split_on("\n"), source: Fs.read_or_empty!(source).split_on("\n") }) else None
							}
							_ =>
								if Fs.exists!(twin) and Fs.read_or_empty!(twin) == text {
									lines = text.split_on("\n")
									Some({ rocx: shown(twin), generated: lines, source: lines })
								} else {
									None
								}
						}
				}
		}
	}

	## The app's file a file of a browser's copy is a copy of: at the same place under the app, which
	## the copy's `.rocx-client` names (`app: ../..`). None for a file of no copy.
	app_of! : Str => [Some(Str), None]
	app_of! = |file| {
		var $at = Fs.dirname(file)
		var $looking = Bool.True
		while $looking {
			ours = Fs.join([$at, ".rocx-client"])
			if Fs.exists!(ours) {
				said = Fs.read_or_empty!(ours).split_on("\n").find_first(|line| line.starts_with("app: "))
				return
					match said {
						Ok(line) => Some(Fs.resolve($at, [line.drop_prefix("app: "), Fs.relative($at, file)]))
						Err(_) => None
					}
			}
			up = Fs.dirname($at)
			$looking = up != $at
			$at = up
		}
		None
	}

	## The file a generated file's last line names (`# rocx: generated from (\S+\.rocx):`), or a
	## route file's Roc (`… from ../routes/feed/+server.roc:`).
	named : Str -> [Some(Str), None]
	named = |last| {
		lead = "${Remap.marker} "
		if !last.starts_with(lead) {
			return None
		}
		bytes = last.drop_prefix(lead).to_utf8()
		var $token_end = 0
		while $token_end < bytes.len() and !Text.is_space_at(bytes, $token_end) {
			$token_end = $token_end + 1
		}
		# The last `.rocx:` in the first word, after something.
		var $found = None
		var $i = 1
		while $i + 6 <= $token_end {
			if Text.starts_with_at(bytes, ".rocx:".to_utf8(), $i) {
				$found = Some($i)
			}
			$i = $i + 1
		}
		match $found {
			Some(at) => Some(Text.cut(bytes, 0, at + 5))
			None =>
				if $token_end > 5 and Text.starts_with_at(bytes, ".roc:".to_utf8(), $token_end - 5) {
					Some(Text.cut(bytes, 0, $token_end - 1))
				} else {
					None
				}
		}
	}

	## Rewrites the compiler's output; text about other files passes through unchanged.
	remap! : Str => Str
	remap! = |output| {
		cwd = Fs.cwd!()
		lines = output.split_on("\n")
		line_at = |n| lines.get(n) ?? ""
		var $cache = []
		var $out = []
		var $i = 0
		while $i < lines.len() {
			line = line_at($i)
			found =
				match Remap.location(line) {
					Ok(at) => {
						cached = $cache.find_first(|each| each.file == at.file)
						entry =
							match cached {
								Ok(each) => each.entry
								Err(_) => {
									made = Remap.entry!(at.file, cwd)
									$cache = $cache.append({ file: at.file, entry: made })
									made
								}
							}
						match entry {
							Some(e) => Some({ at, e })
							None => None
						}
					}
					Err(_) => None
				}
			match found {
				None => {
					$out = $out.append(line)
					$i = $i + 1
				}
				Some({ at, e }) => {
					generated_line = if (at.line_number == 0) "" else e.generated.get(at.line_number - 1) ?? ""
					source_line = if (at.line_number == 0) "" else e.source.get(at.line_number - 1) ?? ""
					trimmed_generated = Remap.trim(generated_line)
					# The compiler quotes the line trimmed, then a caret line under the code it means.
					var $quoted = None
					var $j = $i + 1
					while $j < $i + 12 and $j < lines.len() and $quoted == None {
						if trimmed_generated != "" and Remap.trim(line_at($j)) == trimmed_generated {
							$quoted = Some($j)
						}
						$j = $j + 1
					}
					var $column = at.column
					var $caret_width = 1
					match $quoted {
						Some(q) if Remap.is_caret_line(line_at(q + 1)) => {
							caret_line = line_at(q + 1)
							caret_bytes = caret_line.to_utf8()
							caret_start = Text.utf16_units(Text.slice(caret_bytes, 0, Text.index_of_byte(caret_bytes, '^', 0) ?? 0)).to_i64_wrap()
							$caret_width = Text.length(Remap.trim(caret_line)).to_i64_wrap()
							$column = Remap.indent_units(generated_line) + (caret_start - Remap.indent_units(line_at(q))) + 1
						}
						_ => {}
					}
					source_column = Remap.map_column(generated_line, source_line, $column, $caret_width)
					bytes = line.to_utf8()
					$out = $out.append(Text.cut(bytes, 0, at.start).concat("${e.rocx}:${at.line_number.to_str()}:${source_column.to_str()}").concat(Text.rest(bytes, at.end)))
					match $quoted {
						Some(q) => {
							var $k = $i + 1
							while $k < q {
								$out = $out.append(line_at($k))
								$k = $k + 1
							}
							source_indent = Remap.indent_units(source_line)
							quoted_indent = Remap.indent_units(line_at(q))
							# A record spread on a component (D-052): its hint, at the end of the report.
							if source_line.contains("{...") and !generated_line.contains("{...") {
								$out = $out.append(if (generated_line.contains("({ ..") or Remap.passes_record(generated_line)) Remap.spread_mark else Remap.fields_mark)
							}
							$out = $out.append(" ".repeat(quoted_indent.to_u64_wrap()).concat(Remap.trim(source_line)))
							caret_line = line_at(q + 1)
							if Remap.is_caret_line(caret_line) {
								shift = source_column - 1 - source_indent
								$out = $out.append(" ".repeat((quoted_indent + (if (shift > 0) shift else 0)).to_u64_wrap()).concat("^".repeat($caret_width.to_u64_wrap())))
								$i = q + 2
							} else {
								$i = q + 1
							}
						}
						None => {
							$i = $i + 1
						}
					}
				}
			}
		}
		Str.join_with(Remap.hint_spread($out), "\n")
	}

	## Where a spread's hint goes (`hint_spread`): lines no report has.
	spread_mark : Str
	spread_mark = "<rocx: the spread hint>"

	fields_mark : Str
	fields_mark = "<rocx: the fields hint>"

	## Whether a generated line passes a record as it is to a view (`Base.view!(rest)`).
	passes_record : Str -> Bool
	passes_record = |line|
		match line.split_first(".view!(") {
			Ok(split) => {
				bytes = split.after.to_utf8()
				name_end = Text.run_end(bytes, 0, |b| Text.is_alnum(b) or b == '_' or b == '.')
				name_end > 0 and Text.at(bytes, name_end) == ')'
			}
			Err(_) => Bool.False
		}

	## Moves each spread's mark to the end of its report (before the next `── ` line, or the end), as
	## its hint.
	hint_spread : List(Str) -> List(Str)
	hint_spread = |lines| {
		var $out = []
		var $pending = []
		for line in lines {
			if line == Remap.spread_mark or line == Remap.fields_mark {
				hint = if (line == Remap.spread_mark) Remap.spread_hint else Remap.fields_hint
				if !$pending.contains(hint) {
					$pending = $pending.append(hint)
				}
			} else {
				if line.starts_with("── ") and !$pending.is_empty() {
					$out = $out.concat($pending.fold([], |shown, hint| shown.concat(["", hint, ""])))
					$pending = []
				}
				$out = $out.append(line)
			}
		}
		$out.concat($pending.fold([], |shown, hint| shown.concat(["", hint])))
	}

	## `rocx internal`'s calls of this module's functions (rocx-cli/rocx.mjs names them), by name.
	rpc! : Str, List(Value) => Try(Value, [Failed(Value), Unknown(Str)])
	rpc! = |name, args| {
		match name {
			"remap" => Ok(Text(Remap.remap!(Value.str(args.get(0) ?? Null))))
			_ => Err(Unknown(name))
		}
	}
}
