## D-039: a component's value props are getters, as Solid's props are. `<Child label={word!()} />`
## passes `label: || word!()`, and rocx writes the child so its author writes nothing new: its props'
## type `label : Str` is `label : () => Str`, its pattern `|{ label }|` is `|{ label: label! }|`, and
## each read of `label` in its definition is `label!()` where it is written (Transpile does that,
## as it reads the code). This is what rocx must know of a file before it reads it: which of its
## components take getters, where their definitions' bodies are, and what of their code it writes
## otherwise.
import Text

Getters := [].{

	## A component whose value props are getters: its definition's body (from the end of its pattern
	## to where its definition ends), the names its pattern binds them to (`label`, read as
	## `label!()`), or the name of the whole record (`props`, whose value fields are read as
	## `(props.label)()`) and those fields (empty when the type isn't known: then every field but a `!`
	## one and `children`).
	View : { from : U64, to : U64, props : List(Str), record : [Some(Str), None], fields : List(Str) }

	## Code written otherwise: the source from `from` to `to`, `text` instead (as many lines).
	Swap : { from : U64, to : U64, text : Str }

	## What a file's components are: the views whose props are getters, the code written otherwise,
	## the function components of the file's that take getters (their tags: `Answer` for
	## `answer! = |{ said }| …`), and those that keep values, being called directly too.
	Found : { views : List(View), swaps : List(Swap), fns : List(Str), plain_fns : List(Str) }

	## A problem in the file, at a byte.
	Problem : { reason : Str, at : U64 }

	## A prop that is a getter: not an effect's name (`label!`, already an accessor or a function), and
	## not `children` (markup, whose holes are already live).
	is_value : Str -> Bool
	is_value = |name| !name.ends_with("!") and name != "children" and name != ""

	is_name_byte : U8 -> Bool
	is_name_byte = |b| Text.is_alnum(b) or b == '_'

	## Where the string, character or comment at `i` ends, or `i` when there is none.
	skip_literal : List(U8), U64 -> U64
	skip_literal = |src, i| {
		c = Text.at(src, i)
		if c == '"' {
			var $j = i + 1
			while $j < src.len() and Text.at(src, $j) != '"' and Text.at(src, $j) != '\n' {
				$j = $j + (if (Text.at(src, $j) == '\\') 2 else 1)
			}
			$j + 1
		} else if c == '\'' {
			var $j = i + 1
			while $j < src.len() and Text.at(src, $j) != '\'' and Text.at(src, $j) != '\n' {
				$j = $j + (if (Text.at(src, $j) == '\\') 2 else 1)
			}
			$j + 1
		} else if c == '#' {
			Text.line_end(src, i)
		} else {
			i
		}
	}

	## The closer that matches the opener (`{`, `(`, `[`) at `open`, strings and comments passed over;
	## the source's end when there is none.
	matching : List(U8), U64 -> U64
	matching = |src, open| {
		var $depth = 0.U64
		var $i = open
		while $i < src.len() {
			c = Text.at(src, $i)
			skipped = Getters.skip_literal(src, $i)
			if skipped > $i {
				$i = skipped
			} else {
				if c == '{' or c == '(' or c == '[' {
					$depth = $depth + 1
				} else if c == '}' or c == ')' or c == ']' {
					$depth = $depth - 1
					if $depth == 0 {
						return $i
					}
				}
				$i = $i + 1
			}
		}
		src.len()
	}

	## Where `needle` is first at the top level of `from`..`to` (outside brackets, strings, comments),
	## or `to`.
	top_level : List(U8), U64, U64, List(U8) -> U64
	top_level = |src, from, to, needle| {
		var $depth = 0.U64
		var $i = from
		while $i < to {
			c = Text.at(src, $i)
			if $depth == 0 and Text.starts_with_at(src, needle, $i) {
				return $i
			}
			skipped = if (c == '#' and needle == ['#']) $i else Getters.skip_literal(src, $i)
			if skipped > $i {
				$i = if (skipped < to) skipped else to
			} else {
				if c == '{' or c == '(' or c == '[' {
					$depth = $depth + 1
				} else if (c == '}' or c == ')' or c == ']') and $depth > 0 {
					$depth = $depth - 1
				}
				$i = $i + 1
			}
		}
		to
	}

	## The stretches of `from`..`to` between its top-level commas.
	segments : List(U8), U64, U64 -> List({ from : U64, to : U64 })
	segments = |src, from, to| {
		var $out = []
		var $start = from
		var $at = Getters.top_level(src, from, to, [','])
		while $at < to {
			$out = $out.append({ from: $start, to: $at })
			$start = $at + 1
			$at = Getters.top_level(src, $start, to, [','])
		}
		$out.append({ from: $start, to })
	}

	## Where the spaces, tabs, newlines and comments at `i` end.
	skip_blank : List(U8), U64, U64 -> U64
	skip_blank = |src, i, to| {
		var $i = i
		var $going = Bool.True
		while $going and $i < to {
			c = Text.at(src, $i)
			if c == ' ' or c == '\t' or c == '\n' or c == '\r' {
				$i = $i + 1
			} else if c == '#' {
				$i = Text.line_end(src, $i)
			} else {
				$going = Bool.False
			}
		}
		$i
	}

	## Where the spaces and tabs (and newlines) before `end` start, down to `from`.
	trim_back : List(U8), U64, U64 -> U64
	trim_back = |src, from, end| {
		var $end = end
		while $end > from and (Text.at(src, $end - 1) == ' ' or Text.at(src, $end - 1) == '\t' or Text.at(src, $end - 1) == '\n' or Text.at(src, $end - 1) == '\r') {
			$end = $end - 1
		}
		$end
	}

	## A prop's type as its getter's: `Str` → `() => Str`; a function's in parentheses.
	getter_type : Str -> Str
	getter_type = |ty| {
		bytes = ty.to_utf8()
		arrow = Getters.top_level(bytes, 0, bytes.len(), "->".to_utf8()) < bytes.len() or Getters.top_level(bytes, 0, bytes.len(), "=>".to_utf8()) < bytes.len()
		if (arrow) "() => (${ty})" else "() => ${ty}"
	}

	## A record type of props (`{ label : Str, max : U64 ?? 5, faces! : () => List(Face) }`, `open`
	## its `{` and `close` its `}`), with each value prop a getter: `label : () => Str`,
	## `max : (() => U64) ?? (|| 5)`. Its lines and comments kept. With the names of its fields.
	getter_record : List(U8), U64, U64 -> { text : Str, names : List(Str) }
	getter_record = |src, open, close| {
		var $text = "{"
		var $names = []
		var $first = Bool.True
		for seg in Getters.segments(src, open + 1, close) {
			if !$first {
				$text = $text.concat(",")
			}
			$first = Bool.False
			n0 = Getters.skip_blank(src, seg.from, seg.to)
			name_end = Text.run_end(src, n0, Getters.is_name_byte)
			bang_end = if (Text.at(src, name_end) == '!' and name_end < seg.to) name_end + 1 else name_end
			name = Text.cut(src, n0, if (bang_end < seg.to) bang_end else seg.to)
			colon = Text.run_end(src, bang_end, |b| b == ' ' or b == '\t')
			if name != "" and Text.at(src, colon) == ':' and colon < seg.to {
				$names = $names.append(name)
			}
			if Getters.is_value(name) and Text.at(src, colon) == ':' and colon < seg.to and Text.at(src, colon + 1) != ':' and Text.at(src, colon + 1) != '=' {
				t0 = Text.run_end(src, colon + 1, |b| b == ' ' or b == '\t')
				comment = Getters.top_level(src, t0, seg.to, ['#'])
				defaulted = Getters.top_level(src, t0, comment, "??".to_utf8())
				t_end = Getters.trim_back(src, t0, defaulted)
				ty = Text.cut(src, t0, t_end)
				if defaulted < comment {
					d0 = Text.run_end(src, defaulted + 2, |b| b == ' ' or b == '\t')
					d_end = Getters.trim_back(src, d0, comment)
					default = Text.cut(src, d0, d_end)
					$text = $text.concat(Text.cut(src, seg.from, t0)).concat("(() => ${ty}) ?? (|| ${default})").concat(Text.cut(src, d_end, seg.to))
				} else {
					$text = $text.concat(Text.cut(src, seg.from, t0)).concat(Getters.getter_type(ty)).concat(Text.cut(src, t_end, seg.to))
				}
			} else {
				$text = $text.concat(Text.cut(src, seg.from, seg.to))
			}
		}
		{ text: $text.concat("}"), names: $names }
	}

	## A view's pattern, `bar` and `close` its two `|`s: the names it binds its value props to, as
	## getters (`|{ label, faces! }|` → `|{ label: label!, faces! }|`, binding `label`), or the name it
	## binds the whole record to (`|props|`).
	pattern : List(U8), U64, U64 -> Try({ text : Str, props : List(Str), record : [Some(Str), None] }, [Problem(Problem)])
	pattern = |src, bar, close| {
		as_written = Text.cut(src, bar, close + 1)
		p0 = Getters.skip_blank(src, bar + 1, close)
		p_end = Getters.trim_back(src, p0, close)
		first = Text.at(src, p0)
		if p0 >= p_end {
			return Ok({ text: as_written, props: [], record: None })
		}
		if (Text.is_lower(first) or first == '_') and Text.run_end(src, p0, Getters.is_name_byte) == p_end {
			name = Text.cut(src, p0, p_end)
			return Ok({ text: as_written, props: [], record: if (name.starts_with("_")) None else Some(name) })
		}
		if first != '{' or Getters.matching(src, p0) + 1 != p_end {
			return Ok({ text: as_written, props: [], record: None })
		}
		var $text = Text.cut(src, bar, p0 + 1)
		var $props = []
		var $first = Bool.True
		for seg in Getters.segments(src, p0 + 1, p_end - 1) {
			if !$first {
				$text = $text.concat(",")
			}
			$first = Bool.False
			n0 = Getters.skip_blank(src, seg.from, seg.to)
			n_end = Getters.trim_back(src, n0, seg.to)
			name_end = Text.run_end(src, n0, Getters.is_name_byte)
			field = Text.cut(src, n0, name_end)
			after = Text.run_end(src, name_end, |b| b == ' ' or b == '\t')
			if !Getters.is_value(field) or Text.at(src, name_end) == '!' or Text.starts_with_at(src, "..".to_utf8(), n0) {
				$text = $text.concat(Text.cut(src, seg.from, seg.to))
			} else if name_end == n_end {
				# `label` binds the getter as `label!`; reads of `label` call it.
				$props = $props.append(field)
				$text = $text.concat(Text.cut(src, seg.from, n_end)).concat(": ${field}!").concat(Text.cut(src, n_end, seg.to))
			} else if Text.at(src, after) == ':' {
				l0 = Text.run_end(src, after + 1, |b| b == ' ' or b == '\t')
				l_end = Text.run_end(src, l0, Getters.is_name_byte)
				local = Text.cut(src, l0, l_end)
				if l_end != n_end or !(Text.is_lower(Text.at(src, l0)) or Text.at(src, l0) == '_') {
					return Err(Problem({ reason: "${field} is a prop, which rocx makes a getter (D-039): bind it to a name here (`${field}`) and destructure it in the view's body", at: n0 }))
				}
				$props = $props.append(local)
				$text = $text.concat(Text.cut(src, seg.from, l_end)).concat("!").concat(Text.cut(src, l_end, seg.to))
			} else {
				$text = $text.concat(Text.cut(src, seg.from, seg.to))
			}
		}
		Ok({ text: $text.concat(Text.cut(src, p_end - 1, close + 1)), props: $props, record: None })
	}

	## The indentation's length of the line starting at `ls`, and where its first character is.
	indent_of : List(U8), U64 -> U64
	indent_of = |src, ls| Text.run_end(src, ls, |b| b == ' ' or b == '\t') - ls

	## Where a definition whose line is indented by `indent` ends, its code continuing past `from`: the
	## start of the first line after that is indented no deeper and doesn't begin with a closer.
	definition_end : List(U8), U64, U64 -> U64
	definition_end = |src, from, indent| {
		var $i = from
		while $i < src.len() {
			match Text.index_of_byte(src, '\n', $i) {
				Ok(nl) => {
					ls = nl + 1
					first = Text.run_end(src, ls, |b| b == ' ' or b == '\t')
					c = Text.at(src, first)
					blank = first >= src.len() or c == '\n' or c == '\r'
					if !blank and first - ls <= indent and c != ')' and c != ']' and c != '}' {
						return ls
					}
					$i = ls
				}
				Err(_) => return src.len()
			}
		}
		src.len()
	}

	## Whether `src` uses `name` anywhere but at the start of a line (its definition and annotation):
	## a call, or a value passed on.
	used_elsewhere : List(U8), Str -> Bool
	used_elsewhere = |src, name| {
		needle = name.to_utf8()
		var $i = 0
		while $i < src.len() {
			match Text.index_of(src, needle, $i) {
				Ok(k) => {
					before = if (k == 0) ' ' else Text.at(src, k - 1)
					after = Text.at(src, k + needle.len())
					line_first = Text.run_end(src, Text.line_start(src, k), |b| b == ' ' or b == '\t') == k
					if !line_first and !Getters.is_name_byte(before) and before != '.' and !Getters.is_name_byte(after) and after != '!' {
						return Bool.True
					}
					$i = k + 1
				}
				Err(_) => return Bool.False
			}
		}
		Bool.False
	}

	## The tags the file writes (`<Answer`), its markup's or not.
	tags_used : List(U8) -> List(Str)
	tags_used = |src| {
		var $out = []
		var $i = 0
		while $i < src.len() {
			match Text.index_of_byte(src, '<', $i) {
				Ok(k) => {
					if Text.is_upper(Text.at(src, k + 1)) {
						e = Text.run_end(src, k + 1, Text.is_alnum)
						tag = Text.cut(src, k + 1, e)
						if !$out.contains(tag) {
							$out = $out.append(tag)
						}
					}
					$i = k + 1
				}
				Err(_) => {
					$i = src.len()
				}
			}
		}
		$out
	}

	## The block a definition at line `ls`, indented by `indent`, is a direct member of: the innermost
	## type block opened before it whose indentation is less than its own (as `views_defined` has it).
	owner : List({ name : Str, at : U64, indent : Str }), U64, Str -> [Some({ name : Str, at : U64, indent : Str }), None]
	owner = |blocks, ls, indent|
		blocks.fold(
			None,
			|best, b|
				if b.at < ls and indent.to_utf8().len() > b.indent.to_utf8().len() and indent.starts_with(b.indent) {
					match best {
						Some(chosen) => if (b.indent.to_utf8().len() >= chosen.indent.to_utf8().len()) Some(b) else best
						None => Some(b)
					}
				} else {
					best
				},
		)

	## A record type a view's annotation names: `Props` (or `Card.Props`) defined with `:=` or `:` in
	## the view's block (at the view's indentation), or at the file's top level for a top-level view.
	named_record : List(U8), List(U64), U64, Str, Str -> [Some({ open : U64, close : U64 }), None]
	named_record = |src, starts, block_at, indent, name| {
		for ls in starts {
			if ls > block_at and Text.starts_with_at(src, indent.concat(name).to_utf8(), ls) {
				e = ls + indent.to_utf8().len() + name.to_utf8().len()
				p = Text.run_end(src, e, |b| b == ' ' or b == '\t')
				if Getters.indent_of(src, ls) == indent.to_utf8().len() and Text.at(src, p) == ':' and Text.at(src, p + 1) != ':' {
					after = if (Text.at(src, p + 1) == '=') p + 2 else p + 1
					open = Getters.skip_blank(src, after, src.len())
					if Text.at(src, open) == '{' {
						return Some({ open, close: Getters.matching(src, open) })
					}
					return None
				}
			}
		}
		None
	}

	## A file's components whose value props are getters, and what of their code is written otherwise
	## (`blocks`: its type blocks, `Transpile.type_blocks`).
	find : List(U8), List({ name : Str, at : U64, indent : Str }) -> Try(Found, [Problem(Problem)])
	find = |src, blocks| {
		starts = Getters.line_starts(src)
		tags = Getters.tags_used(src)
		var $views = []
		var $swaps = []
		var $fns = []
		var $plain = []
		# Each view's annotated record (its value fields), by the view's line indentation and block.
		for ls in starts {
			i0 = ls + Getters.indent_of(src, ls)
			indent = Text.cut(src, ls, i0)
			name_end = Text.run_end(src, i0, Getters.is_name_byte)
			named = Text.cut(src, i0, name_end)
			bang = Text.at(src, name_end) == '!' and name_end < src.len()
			p = Text.run_end(src, name_end + 1, |b| b == ' ' or b == '\t')
			starts_lower = Text.is_lower(Text.at(src, i0))
			if bang and starts_lower and (Text.at(src, p) == '=' or Text.at(src, p) == ':') and Text.at(src, p + 1) != '=' and Text.at(src, p + 1) != ':' and Text.at(src, p + 1) != '>' {
				name = "${named}!"
				is_view = named == "view" or named.starts_with("view_")
				block = Getters.owner(blocks, ls, indent)
				in_place = indent == "" or block != None
				tag = Getters.tag_of(named)
				as_tag = !is_view and indent == "" and tags.contains(tag)
				fn_kept = as_tag and Getters.used_elsewhere(src, name)
				if as_tag and fn_kept and !$plain.contains(tag) {
					$plain = $plain.append(tag)
				}
				if as_tag and !fn_kept and !$fns.contains(tag) {
					$fns = $fns.append(tag)
				}
				if in_place and (is_view or (as_tag and !fn_kept)) {
					block_at = match block {
						Some(b) => b.at
						None => 0
					}
					if Text.at(src, p) == ':' {
						# The annotation: its props' type, written with getters.
						t0 = Getters.skip_blank(src, p + 1, src.len())
						if Text.at(src, t0) == '{' {
							close = Getters.matching(src, t0)
							rewritten = Getters.getter_record(src, t0, close)
							$swaps = $swaps.append({ from: t0, to: close + 1, text: rewritten.text })
						} else if Text.is_upper(Text.at(src, t0)) {
							t_end = Text.run_end(src, t0, |b| Getters.is_name_byte(b) or b == '.')
							type_name = Text.cut(src, t0, t_end).split_on(".").last() ?? ""
							match Getters.named_record(src, starts, block_at, indent, type_name) {
								Some(rec) => {
									if !$swaps.any(|s| s.from == rec.open) {
										$swaps = $swaps.append({ from: rec.open, to: rec.close + 1, text: Getters.getter_record(src, rec.open, rec.close).text })
									}
								}
								None => return Err(Problem({ reason: "${name}'s props are getters (D-039), so rocx writes their type: give it as a record here, or as `${type_name} := { … }` beside it", at: t0 }))
							}
						}
					} else {
						bar = Getters.skip_blank(src, p + 1, src.len())
						if Text.at(src, bar) == '|' {
							close = Getters.top_level(src, bar + 1, src.len(), ['|'])
							read = Getters.pattern(src, bar, close)?
							fields =
								match read.record {
									Some(_) => Getters.record_fields(src, starts, block_at, ls, indent, name)
									None => []
								}
							$swaps = $swaps.append({ from: bar, to: close + 1, text: read.text })
							to = Getters.definition_end(src, close + 1, indent.to_utf8().len())
							$views = $views.append({ from: close + 1, to, props: read.props, record: read.record, fields })
						}
					}
				}
			}
		}
		Ok({ views: $views, swaps: $swaps, fns: $fns, plain_fns: $plain })
	}

	## Where each line starts: 0, and after each newline.
	line_starts : List(U8) -> List(U64)
	line_starts = |src| {
		var $starts = [0]
		var $i = 0
		while $i < src.len() {
			if Text.at(src, $i) == '\n' {
				$starts = $starts.append($i + 1)
			}
			$i = $i + 1
		}
		$starts
	}

	## `answer` → `Answer`: the tag a function component is written with.
	tag_of : Str -> Str
	tag_of = |snake| {
		bytes = snake.to_utf8()
		var $out = []
		var $up = Bool.True
		for b in bytes {
			if b == '_' {
				$up = Bool.True
			} else {
				$out = $out.append(if ($up and Text.is_lower(b)) b - 32 else b)
				$up = Bool.False
			}
		}
		Str.from_utf8_lossy($out)
	}

	## The value fields of a view's annotated props (for a view whose pattern names the whole record):
	## none when its type isn't written.
	record_fields : List(U8), List(U64), U64, U64, Str, Str -> List(Str)
	record_fields = |src, starts, block_at, def_at, indent, name| {
		for ls in starts {
			if ls > block_at and ls < def_at and Text.starts_with_at(src, indent.concat(name).to_utf8(), ls) and Getters.indent_of(src, ls) == indent.to_utf8().len() {
				p = Text.run_end(src, ls + indent.to_utf8().len() + name.to_utf8().len(), |b| b == ' ' or b == '\t')
				if Text.at(src, p) == ':' and Text.at(src, p + 1) != '=' {
					t0 = Getters.skip_blank(src, p + 1, src.len())
					rec =
						if Text.at(src, t0) == '{' {
							Some({ open: t0, close: Getters.matching(src, t0) })
						} else {
							t_end = Text.run_end(src, t0, |b| Getters.is_name_byte(b) or b == '.')
							Getters.named_record(src, starts, block_at, indent, Text.cut(src, t0, t_end).split_on(".").last() ?? "")
						}
					return
						match rec {
							Some(r) => Getters.getter_record(src, r.open, r.close).names.keep_if(Getters.is_value)
							None => []
						}
				}
			}
		}
		[]
	}
}

record_text : Str -> Str
record_text = |text| {
	bytes = text.to_utf8()
	Getters.getter_record(bytes, 0, Getters.matching(bytes, 0)).text
}

pattern_of : Str -> Try({ text : Str, props : List(Str), record : [Some(Str), None] }, [Problem(Getters.Problem)])
pattern_of = |text| {
	bytes = text.to_utf8()
	Getters.pattern(bytes, 0, Getters.top_level(bytes, 1, bytes.len(), ['|']))
}

expect record_text("{ label : Str, max : U64 ?? 5, faces! : () => List(Face), children : List(Html) }") == "{ label : () => Str, max : (() => U64) ?? (|| 5), faces! : () => List(Face), children : List(Html) }"
expect record_text("{\n\tformat : Dec -> Str, # how\n\tlabel : Str ?? \"\",\n}") == "{\n\tformat : () => (Dec -> Str), # how\n\tlabel : (() => Str) ?? (|| \"\"),\n}"
expect record_text("{}") == "{}"
expect pattern_of("|{ label, faces!, day: today, children, .. }|") == Ok({ text: "|{ label: label!, faces!, day: today!, children, .. }|", props: ["label", "today"], record: None })
expect pattern_of("|props|") == Ok({ text: "|props|", props: [], record: Some("props") })
expect pattern_of("|{}|") == Ok({ text: "|{}|", props: [], record: None })
expect Getters.tag_of("status_pill") == "StatusPill"
