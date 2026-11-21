## Regular expressions in plain Roc, matched in linear time: a pattern compiles once to a program
## (a Thompson NFA), and a Pike VM runs it over the text, every way it could match at once, a step
## per character. No pattern and no text can make it slow: matching costs the text's length times
## the program's, at most. So there is nothing a backtracking engine has that needs one:
## no backreferences, no lookaround.
##
## The syntax is JavaScript's, so a pattern means the same in a browser's `pattern` attribute:
##
## | Syntax | Matches |
## |---|---|
## | `a`, `\.`, `\\`, `\n`, `\t`, `\xE9`, `é`, `\u{1F600}` | that character |
## | `.` | any character but a line break |
## | `[abc]`, `[a-z0-9_]`, `[^,;]` | one of them; one that isn't |
## | `\d` `\w` `\s`, `\D` `\W` `\S` | a digit, a word character (`[A-Za-z0-9_]`), white space; and their opposites |
## | `^`, `$` | the start, the end of the text |
## | `\b`, `\B` | a word's edge; anywhere else |
## | `(…)`, `(?:…)` | a group |
## | `a\|b` | either |
## | `*`, `+`, `?`, `{2}`, `{2,}`, `{2,5}` | so many times; with `?` after (`*?`), as few as can be |
##
## A character is a Unicode code point, not a byte: `.` matches `é` whole. A repeat is at most
## 1000 times, and a program at most 20000 steps long.
Regex := { source : Str, program : List(Inst) }.{

	## A pattern's program, or what is wrong with it, and where: `Err(InvalidRegex("at 3: nothing
	## to repeat"))`.
	compile : Str -> Try(Regex, [InvalidRegex(Str)])
	compile = |pattern| {
		points = decode(pattern).points
		match alternation(points, 0, 0) {
			Ok(parsed) =>
				if parsed.at < points.len() {
					Err(InvalidRegex("at ${(parsed.at + 1).to_str()}: a ) with no ( before it"))
				} else if parsed.frag.len() >= max_program {
					Err(InvalidRegex("too big: a program of over ${max_program.to_str()} steps; repeat less"))
				} else {
					Ok({ source: pattern, program: parsed.frag.append(Match) })
				}
			Err(Invalid(at, why)) => Err(InvalidRegex("at ${(at + 1).to_str()}: ${why}"))
		}
	}

	## A pattern written in the code: `Regex.must("^\\d{5}$")`. A bad one crashes, and since a
	## top-level value is computed as the app compiles, a bad pattern there stops the build.
	must : Str -> Regex
	must = |pattern|
		match Regex.compile(pattern) {
			Ok(regex) => regex
			Err(InvalidRegex(why)) => crash "Regex.must(${Str.inspect(pattern)}): ${why}"
		}

	## The pattern, as it was written.
	source : Regex -> Str
	source = |regex| regex.source

	## Whether the whole of `text` matches, as a browser's `pattern` attribute checks a field:
	## `Regex.must("\\d+").matches("12")`, but not `"12a"`.
	matches : Regex, Str -> Bool
	matches = |regex, text| pike(regex.program, decode(text).points, Whole).is_ok()

	## Whether it matches anywhere in `text`, as JavaScript's `test`: `Regex.must("\\d").found_in("a1")`.
	found_in : Regex, Str -> Bool
	found_in = |regex, text| pike(regex.program, decode(text).points, Anywhere).is_ok()

	## Where it first matches in `text`, as JavaScript's `exec` finds it (the leftmost match; of
	## those, the one the pattern prefers: `a+` as long as it goes, `a+?` as short): its start and
	## end, in UTF-8 bytes, and the text matched.
	find : Regex, Str -> Try({ start : U64, end : U64, text : Str }, [NotFound])
	find = |regex, text| {
		decoded = decode(text)
		match pike(regex.program, decoded.points, Anywhere) {
			Ok(span) => {
				start = decoded.starts.get(span.start) ?? text.count_utf8_bytes()
				end = decoded.starts.get(span.end) ?? text.count_utf8_bytes()
				found = Str.from_utf8_lossy(text.to_utf8().sublist({ start, len: end - start }))
				Ok({ start, end, text: found })
			}
			Err(NotFound) => Err(NotFound)
		}
	}

	## Each match in `text`, left to right, none overlapping: the text of each.
	find_all : Regex, Str -> List(Str)
	find_all = |regex, text| {
		decoded = decode(text)
		bytes = text.to_utf8()
		size = bytes.len()
		var $found = []
		var $from = 0
		var $going = Bool.True
		while $going {
			rest = decoded.points.drop_first($from)
			match pike(regex.program, rest, Anywhere) {
				Ok(span) => {
					start = decoded.starts.get($from + span.start) ?? size
					end = decoded.starts.get($from + span.end) ?? size
					$found = $found.append(Str.from_utf8_lossy(bytes.sublist({ start, len: end - start })))
					# An empty match moves on a character, so the search ends.
					$from = $from + (if (span.end == span.start) span.end + 1 else span.end)
					$going = $from <= decoded.points.len()
				}
				Err(NotFound) => {
					$going = Bool.False
				}
			}
		}
		$found
	}
}

## One step of a program. `Set` matches a character in its ranges (or, negated, one that isn't);
## `Split` goes both ways, the first preferred; `Jump` goes on elsewhere; `Start`, `End`,
## `Boundary` and `NotBoundary` go on only where they hold; `Match` is a match.
Inst : [Char(U32), Set(List((U32, U32)), Bool), Split(U64, U64), Jump(U64), Start, End, Boundary, NotBoundary, Match]

## A piece of a program, its jumps counted from its own start; its end is just past its last step.
Parsed : { frag : List(Inst), at : U64 }

## Where a pattern goes wrong, and why.
Invalid : [Invalid(U64, Str)]

max_repeat : U64
max_repeat = 1000

max_program : U64
max_program = 20000

## How deep groups may nest.
max_depth : U64
max_depth = 200

## `a|b|c`: one or more sequences, the first preferred.
alternation : List(U32), U64, U64 -> Try(Parsed, Invalid)
alternation = |points, at, depth| {
	first = sequence(points, at, depth)?
	var $frag = first.frag
	var $at = first.at
	while points.get($at) == Ok('|') {
		next = sequence(points, $at + 1, depth)?
		$frag = either($frag, next.frag)
		$at = next.at
		if $frag.len() > max_program {
			return Err(Invalid($at, "too big: a program of over ${max_program.to_str()} steps; repeat less"))
		}
	}
	Ok({ frag: $frag, at: $at })
}

## Pieces one after another, up to a `|`, a `)` or the end.
sequence : List(U32), U64, U64 -> Try(Parsed, Invalid)
sequence = |points, at, depth| {
	var $frag = []
	var $at = at
	var $going = Bool.True
	while $going {
		match points.get($at) {
			Ok('|') => {
				$going = Bool.False
			}
			Ok(')') => {
				$going = Bool.False
			}
			Ok(_) => {
				piece = repeated(points, $at, depth)?
				$frag = $frag.concat(shift(piece.frag, $frag.len()))
				$at = piece.at
				if $frag.len() > max_program {
					return Err(Invalid($at, "too big: a program of over ${max_program.to_str()} steps; repeat less"))
				}
			}
			Err(_) => {
				$going = Bool.False
			}
		}
	}
	Ok({ frag: $frag, at: $at })
}

## An atom and its quantifier, if it has one.
repeated : List(U32), U64, U64 -> Try(Parsed, Invalid)
repeated = |points, at, depth| {
	piece = atom(points, at, depth)?
	match quantifier(points, piece.at)? {
		Once => Ok(piece)
		Times(low, high, after) => {
			(lazy, end) = if (points.get(after) == Ok('?')) (Bool.True, after + 1) else (Bool.False, after)
			if is_quantifier(points, end) {
				Err(Invalid(end, "a quantifier after a quantifier: put the first in a group, (a*)+"))
			} else if assertion_only(points, at) {
				Err(Invalid(piece.at, "nothing to repeat"))
			} else {
				Ok({ frag: repeat(piece.frag, low, high, lazy), at: end })
			}
		}
	}
}

## Whether the atom at `at` is an assertion (`^`, `$`, `\b`, `\B`), which can't be repeated.
assertion_only : List(U32), U64 -> Bool
assertion_only = |points, at|
	match points.get(at) {
		Ok('^') => Bool.True
		Ok('$') => Bool.True
		Ok('\\') => points.get(at + 1) == Ok('b') or points.get(at + 1) == Ok('B')
		_ => Bool.False
	}

## Whether a quantifier starts at `at`.
is_quantifier : List(U32), U64 -> Bool
is_quantifier = |points, at|
	match points.get(at) {
		Ok('*') => Bool.True
		Ok('+') => Bool.True
		Ok('?') => Bool.True
		Ok('{') => Bool.True
		_ => Bool.False
	}

## The quantifier at `at`: none (`Once`), or how few and how many times (`Err(Unbounded)` for no
## limit) and where it ends.
quantifier : List(U32), U64 -> Try([Once, Times(U64, Try(U64, [Unbounded]), U64)], Invalid)
quantifier = |points, at|
	match points.get(at) {
		Ok('*') => Ok(Times(0, Err(Unbounded), at + 1))
		Ok('+') => Ok(Times(1, Err(Unbounded), at + 1))
		Ok('?') => Ok(Times(0, Ok(1), at + 1))
		Ok('{') => {
			low = digits(points, at + 1)
			if low.count == 0 {
				Err(Invalid(at, "a { that doesn't start {2}, {2,} or {2,5}: write \\{ for the character"))
			} else {
				(high, end) =
					match points.get(low.at) {
						Ok('}') => (Ok(Ok(low.value)), low.at + 1)
						Ok(',') =>
							if points.get(low.at + 1) == Ok('}') {
								(Ok(Err(Unbounded)), low.at + 2)
							} else {
								top = digits(points, low.at + 1)
								if top.count > 0 and points.get(top.at) == Ok('}') {
									(Ok(Ok(top.value)), top.at + 1)
								} else {
									(Err(Invalid(at, "a { that doesn't end {2}, {2,} or {2,5}")), at)
								}
							}
						_ => (Err(Invalid(at, "a { that doesn't end {2}, {2,} or {2,5}")), at)
					}
				match high {
					Ok(Ok(most)) =>
						if most < low.value {
							Err(Invalid(at, "{${low.value.to_str()},${most.to_str()}}: the most is less than the least"))
						} else if most > max_repeat {
							Err(Invalid(at, "a repeat of over ${max_repeat.to_str()} times"))
						} else {
							Ok(Times(low.value, Ok(most), end))
						}
					Ok(Err(Unbounded)) =>
						if low.value > max_repeat {
							Err(Invalid(at, "a repeat of over ${max_repeat.to_str()} times"))
						} else {
							Ok(Times(low.value, Err(Unbounded), end))
						}
					Err(invalid) => Err(invalid)
				}
			}
		}
		_ => Ok(Once)
	}

## The decimal number at `at`, how many digits it has, and where it ends (capped, so a long one
## is still too big rather than wrapping).
digits : List(U32), U64 -> { value : U64, count : U64, at : U64 }
digits = |points, at| {
	var $value = 0
	var $at = at
	var $going = Bool.True
	while $going {
		match points.get($at) {
			Ok(c) =>
				if c >= '0' and c <= '9' {
					$value = U64.min($value * 10 + (c - '0').to_u64(), 1000000)
					$at = $at + 1
				} else {
					$going = Bool.False
				}
			Err(_) => {
				$going = Bool.False
			}
		}
	}
	{ value: $value, count: $at - at, at: $at }
}

## One thing to match: a character, a class, a group, an assertion.
atom : List(U32), U64, U64 -> Try(Parsed, Invalid)
atom = |points, at, depth|
	match points.get(at) {
		Ok('(') => group(points, at, depth)
		Ok('[') => {
			parsed = class(points, at + 1)?
			Ok({ frag: [Set(parsed.ranges, parsed.negated)], at: parsed.at })
		}
		Ok('.') => Ok({ frag: [Set(line_breaks, Bool.True)], at: at + 1 })
		Ok('^') => Ok({ frag: [Start], at: at + 1 })
		Ok('$') => Ok({ frag: [End], at: at + 1 })
		Ok('\\') => {
			escaped = escape(points, at + 1, Outside)?
			match escaped.got {
				One(c) => Ok({ frag: [Char(c)], at: escaped.at })
				Ranges(ranges, negated) => Ok({ frag: [Set(ranges, negated)], at: escaped.at })
				Edge => Ok({ frag: [Boundary], at: escaped.at })
				NotEdge => Ok({ frag: [NotBoundary], at: escaped.at })
			}
		}
		Ok('*') => Err(Invalid(at, "nothing to repeat"))
		Ok('+') => Err(Invalid(at, "nothing to repeat"))
		Ok('?') => Err(Invalid(at, "nothing to repeat"))
		Ok('{') => Err(Invalid(at, "nothing to repeat: write \\{ for the character"))
		Ok('}') => Err(Invalid(at, "a } with no {: write \\} for the character"))
		Ok(']') => Err(Invalid(at, "a ] with no [: write \\] for the character"))
		Ok(c) => Ok({ frag: [Char(c)], at: at + 1 })
		Err(_) => Err(Invalid(at, "the pattern ends where it needs more"))
	}

## `(…)` or `(?:…)`: a group. Lookaround and named groups aren't here.
group : List(U32), U64, U64 -> Try(Parsed, Invalid)
group = |points, at, depth|
	if depth >= max_depth {
		Err(Invalid(at, "groups nested over ${max_depth.to_str()} deep"))
	} else {
		inner =
			if points.get(at + 1) == Ok('?') {
				if points.get(at + 2) == Ok(':') {
					Ok(at + 3)
				} else if points.get(at + 2) == Ok('=') or points.get(at + 2) == Ok('!') or points.get(at + 2) == Ok('<') {
					Err(Invalid(at, "lookaround and named groups aren't supported: matching stays linear without them"))
				} else {
					Err(Invalid(at, "(? that isn't (?:"))
				}
			} else {
				Ok(at + 1)
			}
		body = alternation(points, inner?, depth + 1)?
		if points.get(body.at) == Ok(')') {
			Ok({ frag: body.frag, at: body.at + 1 })
		} else {
			Err(Invalid(at, "a ( with no ) after it"))
		}
	}

## A class's ranges, from just after its `[` to just after its `]`.
class : List(U32), U64 -> Try({ ranges : List((U32, U32)), negated : Bool, at : U64 }, Invalid)
class = |points, at| {
	negated = points.get(at) == Ok('^')
	var $at = if (negated) at + 1 else at
	var $ranges = []
	var $going = Bool.True
	while $going {
		match points.get($at) {
			Ok(']') => {
				$going = Bool.False
			}
			Ok(_) => {
				low = class_atom(points, $at)?
				dash = points.get(low.at) == Ok('-')
				ends = points.get(low.at + 1) == Ok(']') or points.get(low.at + 1).is_err()
				match low.got {
					One(first) =>
						if dash and !ends {
							high = class_atom(points, low.at + 1)?
							match high.got {
								One(last) =>
									if last < first {
										return Err(Invalid($at, "a range from a character to one before it"))
									} else {
										$ranges = $ranges.append((first, last))
										$at = high.at
									}
								_ => return Err(Invalid(low.at, "a range to a class (\\d, \\w, \\s): write \\- for the character"))
							}
						} else {
							$ranges = $ranges.append((first, first))
							$at = low.at
						}
					Ranges(ranges, negated_class) => {
						if dash and !ends {
							return Err(Invalid(low.at, "a range from a class (\\d, \\w, \\s): write \\- for the character"))
						}
						$ranges = $ranges.concat(if (negated_class) complement(ranges) else ranges)
						$at = low.at
					}
					_ => return Err(Invalid($at, "\\b in a class"))
				}
			}
			Err(_) => return Err(Invalid(at - 1, "a [ with no ] after it"))
		}
	}
	Ok({ ranges: merged($ranges), negated, at: $at + 1 })
}

## One character in a class, or a class escape (`\d`).
class_atom : List(U32), U64 -> Try({ got : [One(U32), Ranges(List((U32, U32)), Bool), Edge, NotEdge], at : U64 }, Invalid)
class_atom = |points, at|
	match points.get(at) {
		Ok('\\') => escape(points, at + 1, Inside)
		Ok(c) => Ok({ got: One(c), at: at + 1 })
		Err(_) => Err(Invalid(at, "a [ with no ] after it"))
	}

## What follows a `\`.
escape : List(U32), U64, [Inside, Outside] -> Try({ got : [One(U32), Ranges(List((U32, U32)), Bool), Edge, NotEdge], at : U64 }, Invalid)
escape = |points, at, place|
	match points.get(at) {
		Ok('d') => Ok({ got: Ranges(digit, Bool.False), at: at + 1 })
		Ok('D') => Ok({ got: Ranges(digit, Bool.True), at: at + 1 })
		Ok('w') => Ok({ got: Ranges(word, Bool.False), at: at + 1 })
		Ok('W') => Ok({ got: Ranges(word, Bool.True), at: at + 1 })
		Ok('s') => Ok({ got: Ranges(space, Bool.False), at: at + 1 })
		Ok('S') => Ok({ got: Ranges(space, Bool.True), at: at + 1 })
		Ok('b') =>
			match place {
				Outside => Ok({ got: Edge, at: at + 1 })
				Inside => Ok({ got: One(8), at: at + 1 })
			}
		Ok('B') =>
			match place {
				Outside => Ok({ got: NotEdge, at: at + 1 })
				Inside => Err(Invalid(at - 1, "\\B in a class"))
			}
		Ok('n') => Ok({ got: One(10), at: at + 1 })
		Ok('r') => Ok({ got: One(13), at: at + 1 })
		Ok('t') => Ok({ got: One(9), at: at + 1 })
		Ok('f') => Ok({ got: One(12), at: at + 1 })
		Ok('v') => Ok({ got: One(11), at: at + 1 })
		Ok('0') =>
			match points.get(at + 1) {
				Ok(c) if c >= '0' and c <= '9' => Err(Invalid(at - 1, "a backreference: there are none, so matching stays linear"))
				_ => Ok({ got: One(0), at: at + 1 })
			}
		Ok('x') => {
			code = hex(points, at + 1, 2)?
			Ok({ got: One(code), at: at + 3 })
		}
		Ok('u') =>
			if points.get(at + 1) == Ok('{') {
				var $end = at + 2
				while (points.get($end) ?? '}') != '}' {
					$end = $end + 1
				}
				count = $end - (at + 2)
				if count == 0 or count > 6 or points.get($end).is_err() {
					Err(Invalid(at - 1, "\\u{…} with one to six hex digits"))
				} else {
					code = hex(points, at + 2, count)?
					if code > 0x10FFFF {
						Err(Invalid(at - 1, "\\u{…} past the last code point, 10FFFF"))
					} else {
						Ok({ got: One(code), at: $end + 1 })
					}
				}
			} else {
				code = hex(points, at + 1, 4)?
				Ok({ got: One(code), at: at + 5 })
			}
		Ok(c) =>
			if c >= '1' and c <= '9' {
				Err(Invalid(at - 1, "a backreference: there are none, so matching stays linear"))
			} else if is_syntax(c) or (place == Inside and c == '-') {
				Ok({ got: One(c), at: at + 1 })
			} else {
				Err(Invalid(at - 1, "\\${Str.from_utf8_lossy(encode(c))} isn't an escape: write the character alone"))
			}
		Err(_) => Err(Invalid(at - 1, "a \\ at the end"))
	}

## The characters a `\` makes plain.
is_syntax : U32 -> Bool
is_syntax = |c| ['^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/'].contains(c)

## `count` hex digits at `at`, as a code point.
hex : List(U32), U64, U64 -> Try(U32, Invalid)
hex = |points, at, count| {
	var $value = 0
	var $i = 0
	while $i < count {
		c = points.get(at + $i) ?? 'g'
		value =
			if c >= '0' and c <= '9' {
				Ok(c - '0')
			} else if c >= 'a' and c <= 'f' {
				Ok(c - 'a' + 10)
			} else if c >= 'A' and c <= 'F' {
				Ok(c - 'A' + 10)
			} else {
				Err(Invalid(at - 2, "\\x takes two hex digits, \\u four"))
			}
		$value = $value * 16 + value?
		$i = $i + 1
	}
	Ok($value)
}

digit : List((U32, U32))
digit = [('0', '9')]

word : List((U32, U32))
word = [('0', '9'), ('A', 'Z'), ('_', '_'), ('a', 'z')]

## JavaScript's white space: `\s`.
space : List((U32, U32))
space = [(9, 13), (32, 32), (0xA0, 0xA0), (0x1680, 0x1680), (0x2000, 0x200A), (0x2028, 0x2029), (0x202F, 0x202F), (0x205F, 0x205F), (0x3000, 0x3000), (0xFEFF, 0xFEFF)]

## What `.` doesn't match.
line_breaks : List((U32, U32))
line_breaks = [(10, 10), (13, 13), (0x2028, 0x2029)]

## Ranges in order, those that touch or overlap made one.
merged : List((U32, U32)) -> List((U32, U32))
merged = |ranges|
	ranges.sort_with(|(a, _), (b, _)| if (a < b) Before else if (a > b) After else Same).fold(
		[],
		|out, (low, high)|
			match out.last() {
				Ok((last_low, last_high)) =>
					if low <= last_high + 1 {
						out.drop_last(1).append((last_low, U32.max(last_high, high)))
					} else {
						out.append((low, high))
					}
				Err(_) => [(low, high)]
			},
	)

## Every code point the ranges don't have.
complement : List((U32, U32)) -> List((U32, U32))
complement = |ranges| {
	var $out = []
	var $next = 0
	for (low, high) in merged(ranges) {
		if low > $next {
			$out = $out.append(($next, low - 1))
		}
		$next = high + 1
	}
	if $next <= 0x10FFFF {
		$out = $out.append(($next, 0x10FFFF))
	}
	$out
}

## A program's jumps moved on by `by`, for it to go `by` steps into another.
shift : List(Inst), U64 -> List(Inst)
shift = |frag, by|
	if by == 0 {
		frag
	} else {
		frag.map(
			|inst|
				match inst {
					Split(x, y) => Split(x + by, y + by)
					Jump(to) => Jump(to + by)
					other => other
				},
		)
	}

## `a|b`: `a` preferred.
either : List(Inst), List(Inst) -> List(Inst)
either = |a, b| {
	after_a = a.len() + 2
	end = after_a + b.len()
	[Split(1, after_a)].concat(shift(a, 1)).append(Jump(end)).concat(shift(b, after_a))
}

## `a?`, or lazily `a??`.
optional : List(Inst), Bool -> List(Inst)
optional = |a, lazy| {
	end = a.len() + 1
	[if (lazy) Split(end, 1) else Split(1, end)].concat(shift(a, 1))
}

## `a*`, or lazily `a*?`.
star : List(Inst), Bool -> List(Inst)
star = |a, lazy| {
	end = a.len() + 2
	[if (lazy) Split(end, 1) else Split(1, end)].concat(shift(a, 1)).append(Jump(0))
}

## `a{low,high}`: `a` `low` times, then up to `high - low` more, each inside the last
## (`a{1,3}` is `a(a(a)?)?`), or, with no limit, `a*`.
repeat : List(Inst), U64, Try(U64, [Unbounded]), Bool -> List(Inst)
repeat = |a, low, high, lazy| {
	var $out = []
	var $i = 0
	while $i < low {
		$out = $out.concat(shift(a, $out.len()))
		$i = $i + 1
	}
	rest =
		match high {
			Err(Unbounded) => star(a, lazy)
			Ok(most) => {
				var $more = []
				var $j = low
				while $j < most {
					$more = optional(a.concat(shift($more, a.len())), lazy)
					$j = $j + 1
				}
				$more
			}
		}
	$out.concat(shift(rest, $out.len()))
}

## A thread of the VM: where it is in the program, and where its match began.
Thread : { pc : U64, start : U64 }

## The threads for this character, in order (the first preferred), and the generation each step of
## the program was last added in, so none is added twice.
Threads : { list : List(Thread), seen : List(U64) }

## The VM: each thread one step through the program per character, all at once, none twice at
## the same step. `Whole` matches the whole text; `Anywhere` finds the leftmost match, the one a
## backtracking engine would find, by cutting the threads it prefers less once one matches.
pike : List(Inst), List(U32), [Whole, Anywhere] -> Try({ start : U64, end : U64 }, [NotFound])
pike = |program, points, mode| {
	n = points.len()
	var $gen = 1
	var $threads = add({ list: [], seen: List.repeat(0, program.len()) }, program, points, 0, 0, 0, $gen)
	var $found = Err(NotFound)
	var $pos = 0
	var $going = Bool.True
	while $going {
		$gen = $gen + 1
		char = points.get($pos)
		var $next = { list: [], seen: $threads.seen }
		for thread in $threads.list {
			if $going {
				match program.get(thread.pc) {
					Ok(Match) =>
						match mode {
							Whole =>
								if $pos == n {
									return Ok({ start: thread.start, end: $pos })
								}
							Anywhere => {
								$found = Ok({ start: thread.start, end: $pos })
								# Those after it are preferred less: they go.
								$going = Bool.False
							}
						}
					Ok(Char(c)) =>
						if char == Ok(c) {
							$next = add($next, program, points, thread.pc + 1, thread.start, $pos + 1, $gen)
						}
					Ok(Set(ranges, negated)) =>
						match char {
							Ok(c) =>
								if in_ranges(ranges, c) != negated {
									$next = add($next, program, points, thread.pc + 1, thread.start, $pos + 1, $gen)
								}
							Err(_) => {}
						}
					_ => {}
				}
			}
		}
		$going = Bool.True
		if $pos >= n {
			$going = Bool.False
		} else {
			$pos = $pos + 1
			# Not found yet: a match may start here too, preferred least.
			if mode == Anywhere and $found.is_err() {
				$next = add($next, program, points, 0, $pos, $pos, $gen)
			}
			if $next.list.is_empty() {
				$going = Bool.False
			}
		}
		$threads = $next
	}
	$found
}

## A thread at `pc`, and every thread it goes on to without reading a character (its jumps and its
## splits, the first way first; past the assertions that hold at `pos`), each once a generation.
add : Threads, List(Inst), List(U32), U64, U64, U64, U64 -> Threads
add = |threads, program, points, pc, start, pos, gen| {
	var $list = threads.list
	var $seen = threads.seen
	var $stack = [pc]
	while !$stack.is_empty() {
		at = $stack.last() ?? 0
		$stack = $stack.drop_last(1)
		if ($seen.get(at) ?? gen) != gen {
			$seen = $seen.set(at, gen) ?? $seen
			match program.get(at) {
				Ok(Jump(to)) => {
					$stack = $stack.append(to)
				}
				Ok(Split(x, y)) => {
					$stack = $stack.append(y).append(x)
				}
				Ok(Start) =>
					if pos == 0 {
						$stack = $stack.append(at + 1)
					}
				Ok(End) =>
					if pos == points.len() {
						$stack = $stack.append(at + 1)
					}
				Ok(Boundary) =>
					if is_word_at(points, pos) != (pos > 0 and is_word_at(points, pos - 1)) {
						$stack = $stack.append(at + 1)
					}
				Ok(NotBoundary) =>
					if is_word_at(points, pos) == (pos > 0 and is_word_at(points, pos - 1)) {
						$stack = $stack.append(at + 1)
					}
				Ok(_) => {
					$list = $list.append({ pc: at, start })
				}
				Err(_) => {}
			}
		}
	}
	{ list: $list, seen: $seen }
}

in_ranges : List((U32, U32)), U32 -> Bool
in_ranges = |ranges, c| ranges.any(|(low, high)| c >= low and c <= high)

## Whether the character at `pos` is a word character (`\w`); past the end, no.
is_word_at : List(U32), U64 -> Bool
is_word_at = |points, pos|
	match points.get(pos) {
		Ok(c) => in_ranges(word, c)
		Err(_) => Bool.False
	}

## A text's code points, and the UTF-8 byte each starts at (and one more: the text's length).
decode : Str -> { points : List(U32), starts : List(U64) }
decode = |text| {
	bytes = text.to_utf8()
	n = bytes.len()
	var $points = List.with_capacity(n)
	var $starts = List.with_capacity(n + 1)
	var $i = 0
	while $i < n {
		b0 = (bytes.get($i) ?? 0).to_u32()
		b1 = (bytes.get($i + 1) ?? 0x80).to_u32()
		b2 = (bytes.get($i + 2) ?? 0x80).to_u32()
		b3 = (bytes.get($i + 3) ?? 0x80).to_u32()
		(point, width) =
			if b0 < 0x80 {
				(b0, 1)
			} else if b0 < 0xE0 {
				((b0 - 0xC0) * 64 + (b1 - 0x80), 2)
			} else if b0 < 0xF0 {
				((b0 - 0xE0) * 4096 + (b1 - 0x80) * 64 + (b2 - 0x80), 3)
			} else {
				((b0 - 0xF0) * 262144 + (b1 - 0x80) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80), 4)
			}
		$points = $points.append(point)
		$starts = $starts.append($i)
		$i = $i + width
	}
	{ points: $points, starts: $starts.append(n) }
}

## A code point as UTF-8.
encode : U32 -> List(U8)
encode = |c|
	if c < 0x80 {
		[c.to_u8_wrap()]
	} else if c < 0x800 {
		[(0xC0 + c // 64).to_u8_wrap(), (0x80 + c % 64).to_u8_wrap()]
	} else if c < 0x10000 {
		[(0xE0 + c // 4096).to_u8_wrap(), (0x80 + (c // 64) % 64).to_u8_wrap(), (0x80 + c % 64).to_u8_wrap()]
	} else {
		[(0xF0 + c // 262144).to_u8_wrap(), (0x80 + (c // 4096) % 64).to_u8_wrap(), (0x80 + (c // 64) % 64).to_u8_wrap(), (0x80 + c % 64).to_u8_wrap()]
	}

ok : Str -> Regex
ok = |pattern| Regex.must(pattern)

bad : Str -> Str
bad = |pattern|
	match Regex.compile(pattern) {
		Ok(_) => "compiled"
		Err(InvalidRegex(why)) => why
	}

# Literals, `.`, and the whole text.
expect ok("abc").matches("abc")
expect !ok("abc").matches("abcd")
expect !ok("abc").matches("ab")
expect ok("").matches("")
expect !ok("").matches("a")
expect ok("a.c").matches("abc")
expect ok("a.c").matches("a.c")
expect !ok("a.c").matches("a\nc")
expect ok("a\\.c").matches("a.c")
expect !ok("a\\.c").matches("abc")
expect ok("caf.").matches("café")
expect ok("^.$").matches("😀")
expect ok("\\u00e9").matches("é")
expect ok("\\u{1F600}").matches("😀")
expect ok("\\x41").matches("A")

# Classes.
expect ok("[abc]").matches("b")
expect !ok("[abc]").matches("d")
expect ok("[a-z]+").matches("hello")
expect !ok("[a-z]+").matches("Hello")
expect ok("[^,;]+").matches("a b")
expect !ok("[^,;]+").matches("a,b")
expect ok("[a-]").matches("-")
expect ok("[-a]").matches("-")
expect ok("[\\-a]").matches("-")
expect ok("[\\]]").matches("]")
expect ok("[\\d.]+").matches("3.14")
expect ok("[^\\d]").matches("x")
expect !ok("[^\\d]").matches("5")
expect ok("[\\D]").matches("x")
expect !ok("[\\D]").matches("7")
expect ok("[à-ÿ]").matches("é")
expect !ok("[]").matches("a")
expect ok("[^]").matches("\n")
expect ok("[.]").matches(".")
expect !ok("[.]").matches("a")

# Escapes.
expect ok("\\d+").matches("2026")
expect !ok("\\d+").matches("20x6")
expect ok("\\D").matches("x")
expect ok("\\w+").matches("snake_case_9")
expect !ok("\\w").matches("-")
expect ok("\\W").matches("-")
expect ok("a\\sb").matches("a b")
expect ok("a\\sb").matches("a\tb")
expect ok("a\\sb").matches("a\u(00A0)b")
expect !ok("\\S").matches(" ")
expect ok("\\(\\)\\[\\]\\{\\}\\*\\+\\?\\|\\^\\$\\/\\\\").matches("()[]{}*+?|^$/\\")

# Anchors and edges.
expect ok("^abc$").matches("abc")
expect ok("^abc").found_in("abcdef")
expect !ok("^abc").found_in("xabc")
expect ok("abc$").found_in("xabc")
expect !ok("abc$").found_in("abcx")
expect ok("a^b").matches("a^b") == Bool.False
expect ok("\\bcat\\b").found_in("a cat sat")
expect !ok("\\bcat\\b").found_in("concatenate")
expect ok("\\Bcat\\B").found_in("concatenate")
expect !ok("\\Bcat").found_in("cat")

# Groups and alternation.
expect ok("cat|dog").matches("dog")
expect !ok("cat|dog").matches("catdog")
expect ok("(cat|dog)+").matches("catdogcat")
expect ok("(?:ab)+").matches("ababab")
expect !ok("(?:ab)+").matches("aba")
expect ok("a(b|)c").matches("ac")
expect ok("a(b|)c").matches("abc")
expect ok("|a").matches("")
expect ok("()").matches("")
expect ok("(a|ab)(c|bcd)(d*)").matches("abcd")

# Quantifiers.
expect ok("a*").matches("")
expect ok("a*").matches("aaaa")
expect ok("a+").matches("a")
expect !ok("a+").matches("")
expect ok("colou?r").matches("color")
expect ok("colou?r").matches("colour")
expect ok("a{3}").matches("aaa")
expect !ok("a{3}").matches("aa")
expect !ok("a{3}").matches("aaaa")
expect ok("a{2,}").matches("aaaaa")
expect !ok("a{2,}").matches("a")
expect ok("a{2,4}").matches("aaaa")
expect !ok("a{2,4}").matches("aaaaa")
expect ok("a{0}b").matches("b")
expect ok("(ab){1,2}").matches("abab")
expect ok("\\d{2}-\\d{3}").matches("12-345")
expect ok("x{0,1000}").matches("xxxx")
expect ok("(a*)*").matches("aaa")
expect ok("(a*)+b").matches("b")
expect ok("(a|b)*?c").matches("abac")

# Finding: the leftmost match, the one the pattern prefers.
expect ok("\\d+").find("ab 123 45") == Ok({ start: 3, end: 6, text: "123" })
expect ok("\\d+?").find("ab 123") == Ok({ start: 3, end: 4, text: "1" })
expect ok("a|ab").find("ab") == Ok({ start: 0, end: 1, text: "a" })
expect ok("ab|a").find("ab") == Ok({ start: 0, end: 2, text: "ab" })
expect ok("a*").find("baa") == Ok({ start: 0, end: 0, text: "" })
expect ok("é+").find("café é") == Ok({ start: 3, end: 5, text: "é" })
expect ok("x").find("abc") == Err(NotFound)
expect ok("<.+>").find("<a><b>") == Ok({ start: 0, end: 6, text: "<a><b>" })
expect ok("<.+?>").find("<a><b>") == Ok({ start: 0, end: 3, text: "<a>" })
expect ok("\\d+").find_all("1 22 333") == ["1", "22", "333"]
expect ok("a*").find_all("ba") == ["", "a", ""]
expect ok("[aeiou]").find_all("rhythm") == []
expect ok("😀|é").find_all("é😀x") == ["é", "😀"]

# Errors, and where.
expect bad("(ab") == "at 1: a ( with no ) after it"
expect bad("ab)") == "at 3: a ) with no ( before it"
expect bad("[ab") == "at 1: a [ with no ] after it"
expect bad("*a") == "at 1: nothing to repeat"
expect bad("a**") == "at 3: a quantifier after a quantifier: put the first in a group, (a*)+"
expect bad("^*") == "at 2: nothing to repeat"
expect bad("a{2") == "at 2: a { that doesn't end {2}, {2,} or {2,5}"
expect bad("a{x}") == "at 2: a { that doesn't start {2}, {2,} or {2,5}: write \\{ for the character"
expect bad("a{3,2}") == "at 2: {3,2}: the most is less than the least"
expect bad("a{1001}") == "at 2: a repeat of over 1000 times"
expect bad("[z-a]") == "at 2: a range from a character to one before it"
expect bad("[a-\\d]") == "at 3: a range to a class (\\d, \\w, \\s): write \\- for the character"
expect bad("(?=a)") == "at 1: lookaround and named groups aren't supported: matching stays linear without them"
expect bad("(a)\\1") == "at 4: a backreference: there are none, so matching stays linear"
expect bad("\\q") == "at 1: \\q isn't an escape: write the character alone"
expect bad("a\\") == "at 2: a \\ at the end"
expect bad("\\x4") == "at 1: \\x takes two hex digits, \\u four"
expect bad("a]") == "at 2: a ] with no [: write \\] for the character"
expect bad("(x{1000}){1000}").starts_with("at ")
expect Regex.compile("a{2}").is_ok()

# Linear: what would take a backtracking engine years is a step per character here.
expect !ok("(a+)+$").matches("${Str.repeat("a", 40)}!")
expect !ok("(a|a)*b").matches(Str.repeat("a", 60))
expect !ok("(x+x+)+y").found_in(Str.repeat("x", 50))
expect ok("(a|aa)*").matches(Str.repeat("a", 200))
