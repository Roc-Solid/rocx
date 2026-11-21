import Plural
import NumberFormat
import DateFormat
import Locales
import Date

## A translated message, in a subset of ICU MessageFormat (what translators' tools read and write):
##
##     Hello, {name}!
##     {count, plural, =0 {No files} one {# file} other {# files}}
##     {count, selectordinal, one {#st} two {#nd} few {#rd} other {#th}} place
##     {role, select, admin {Administrator} other {Member}}
##     {total, number}  {share, number, percent}  {n, number, integer}
##     {when, date, short|medium|long|full}  {when, time, short|medium}
##
## A text argument written in ASCII digits (`"3"`) is read as a number by `plural` and `number`, and
## one written as an ISO date (`"2026-01-31"`) as a day by `date`: what a form's params are.
## In a plural, `#` is the number (less the `offset:`), written as the locale writes numbers; an
## `=2` case is that exact number, tried before the categories; `other` is required. Branches nest.
## An apostrophe quotes: `'{'` is a brace, `''` an apostrophe, and one before anything else is
## itself (so "l'heure" needs nothing).
Message := [
	Parts(List(Message)),
	Literal(Str),
	Value(Str),
	Number(Str, [Plain, Integer, Percent]),
	Dated(Str, DateFormat.Style),
	Timed(Str, [Short, Medium]),
	Plural({ name : Str, ordinal : Bool, offset : I64, cases : List((Str, Message)) }),
	Select({ name : Str, cases : List((Str, Message)) }),
	Pound,
].{

	## What a message is given: `[("name", Text("Ada")), ("count", Int(3))]`. A `Moment` is
	## milliseconds since the epoch, for `date` and `time`. It is a plain tag union, so a package that
	## doesn't depend on this one can build the same arguments.
	Arg : [Text(Str), Int(I64), Num(Dec), Moment(I64)]

	## The message `source` says, or where and why it can't be read (`at` is a byte offset).
	parse : Str -> Try(Message, [BadMessage({ at : U64, why : Str })])
	parse = |source| {
		bytes = source.to_utf8()
		match parts(bytes, 0, Bool.False, 0) {
			Ok({ found, next }) =>
				if next < bytes.len() {
					Err(BadMessage({ at: next, why: "a `}` with no `{` before it" }))
				} else {
					Ok(found)
				}
			Err(problem) => Err(BadMessage(problem))
		}
	}

	## A message that is only its text, braces and all.
	literal : Str -> Message
	literal = |text| Literal(text)

	## The message with its arguments put in, as `data`'s locale writes them; a moment's date and
	## time `offset_minutes` east of UTC. An argument it isn't given is left as `{name}`, so it shows.
	format : Message, Locales.Data, I64, List((Str, Arg)) -> Str
	format = |message, data, offset_minutes, args| written(message, { data, offset: offset_minutes, args, pound: Err(NoPlural) })

	## The arguments the message reads, each once, in the order it first reads them.
	names : Message -> List(Str)
	names = |message| {
		add = |known, name| if (known.contains(name)) known else known.append(name)
		inside = |known, cases| cases.fold(known, |so_far, (_, branch)| Message.names(branch).fold(so_far, add))
		match message {
			Parts(each) => each.fold([], |known, part| Message.names(part).fold(known, add))
			Literal(_) => []
			Pound => []
			Value(name) => [name]
			Number(name, _) => [name]
			Dated(name, _) => [name]
			Timed(name, _) => [name]
			Plural(plural) => inside([plural.name], plural.cases)
			Select(select) => inside([select.name], select.cases)
		}
	}
}

Problem : { at : U64, why : Str }

Scope : { data : Locales.Data, offset : I64, args : List((Str, Message.Arg)), pound : Try(Dec, [NoPlural]) }

written : Message, Scope -> Str
written = |message, scope|
	match message {
		Parts(each) => Str.join_with(each.map(|part| written(part, scope)), "")
		Literal(text) => text
		Pound =>
			match scope.pound {
				Ok(value) => NumberFormat.format(scope.data.number, value, NumberFormat.defaults)
				Err(NoPlural) => "#"
			}
		Value(name) =>
			match argument(scope, name) {
				Ok(Text(text)) => text
				Ok(Int(n)) => NumberFormat.format(scope.data.number, n.to_dec(), NumberFormat.defaults)
				Ok(Num(x)) => NumberFormat.format(scope.data.number, x, NumberFormat.defaults)
				Ok(Moment(ms)) => DateFormat.date_time(scope.data.dates, DateFormat.fields(ms, scope.offset), Short, Short)
				Err(Missing) => "{${name}}"
			}
		Number(name, style) =>
			match number_of(scope, name) {
				Ok(x) =>
					match style {
						Plain => NumberFormat.format(scope.data.number, x, NumberFormat.defaults)
						Integer => NumberFormat.format(scope.data.number, x, { ..NumberFormat.defaults, max_fraction: 0 })
						Percent => NumberFormat.percent(scope.data.number, x, 0)
					}
				Err(NotANumber(text)) => text
			}
		Dated(name, style) =>
			match argument(scope, name) {
				Ok(Moment(ms)) => DateFormat.date(scope.data.dates, DateFormat.fields(ms, scope.offset), style)
				Ok(Text(text)) =>
					match Date.parse_iso(text) {
						Ok(day) => DateFormat.date(scope.data.dates, DateFormat.of_date(day), style)
						Err(_) => text
					}
				_ => "{${name}}"
			}
		Timed(name, style) =>
			match argument(scope, name) {
				Ok(Moment(ms)) => DateFormat.time(scope.data.dates, DateFormat.fields(ms, scope.offset), style)
				_ => "{${name}}"
			}
		Plural(plural) =>
			match number_of(scope, plural.name) {
				Ok(value) => {
					shown = value - plural.offset.to_dec()
					exact = plural.cases.find_first(|(key, _)| key.starts_with("=") and Dec.from_str(key.drop_prefix("=")) == Ok(value))
					chosen =
						match exact {
							Ok((_, branch)) => branch
							Err(_) => {
								rule = if (plural.ordinal) scope.data.ordinal else scope.data.cardinal
								case_for(plural.cases, Plural.name(rule(Plural.of_dec(shown))))
							}
						}
					written(chosen, { ..scope, pound: Ok(shown) })
				}
				Err(_) => written(case_for(plural.cases, "other"), scope)
			}
		Select(select) => {
			key =
				match argument(scope, select.name) {
					Ok(Text(text)) => text
					Ok(Int(n)) => n.to_str()
					_ => "other"
				}
			written(case_for(select.cases, key), scope)
		}
	}

argument : Scope, Str -> Try(Message.Arg, [Missing])
argument = |scope, name|
	match scope.args.find_first(|(each, _)| each == name) {
		Ok((_, value)) => Ok(value)
		Err(_) => Err(Missing)
	}

## An argument as a number (a text of ASCII digits too: `"1500.5"`, as a form's params have it), or
## the text to show instead.
number_of : Scope, Str -> Try(Dec, [NotANumber(Str)])
number_of = |scope, name|
	match argument(scope, name) {
		Ok(Int(n)) => Ok(n.to_dec())
		Ok(Num(x)) => Ok(x)
		Ok(Text(text)) =>
			match Dec.from_str(text.trim()) {
				Ok(x) => Ok(x)
				Err(_) => Err(NotANumber(text))
			}
		Ok(Moment(ms)) => Err(NotANumber(ms.to_str()))
		Err(Missing) => Err(NotANumber("{${name}}"))
	}

case_for : List((Str, Message)), Str -> Message
case_for = |cases, key|
	match cases.find_first(|(each, _)| each == key) {
		Ok((_, branch)) => branch
		Err(_) =>
			match cases.find_first(|(each, _)| each == "other") {
				Ok((_, branch)) => branch
				Err(_) => Parts([])
			}
	}

# --- The parser: bytes, an index, and how deep in braces it is.

at : List(U8), U64 -> U8
at = |bytes, i| bytes.get(i) ?? 0

is_space : U8 -> Bool
is_space = |b| b == ' ' or b == '\t' or b == '\n' or b == '\r'

is_name : U8 -> Bool
is_name = |b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_' or b == '-' or b == '.'

skip_space : List(U8), U64 -> U64
skip_space = |bytes, from| {
	var $i = from
	while $i < bytes.len() and is_space(at(bytes, $i)) {
		$i = $i + 1
	}
	$i
}

word : List(U8), U64 -> { text : Str, next : U64 }
word = |bytes, from| {
	var $i = from
	while $i < bytes.len() and is_name(at(bytes, $i)) {
		$i = $i + 1
	}
	{ text: Str.from_utf8_lossy(bytes.sublist({ start: from, len: $i - from })), next: $i }
}

## Text and arguments up to the `}` that closes this level (not taken) or the end. In a plural's
## branch `#` is the number.
parts : List(U8), U64, Bool, U64 -> Try({ found : Message, next : U64 }, Problem)
parts = |bytes, from, in_plural, depth| {
	var $found = []
	var $text = []
	var $i = from
	var $problem = Ok({})
	var $going = Bool.True
	while $going and $i < bytes.len() {
		b = at(bytes, $i)
		next_byte = at(bytes, $i + 1)
		if b == '}' {
			$going = Bool.False
		} else if b == '{' {
			match argument_at(bytes, $i + 1, in_plural, depth + 1) {
				Ok({ found, next }) => {
					$found = flush($found, $text).append(found)
					$text = []
					$i = next
				}
				Err(problem) => {
					$problem = Err(problem)
					$going = Bool.False
				}
			}
		} else if b == '#' and in_plural {
			$found = flush($found, $text).append(Pound)
			$text = []
			$i = $i + 1
		} else if b == '\'' and next_byte == '\'' {
			$text = $text.append('\'')
			$i = $i + 2
		} else if b == '\'' and (next_byte == '{' or next_byte == '}' or (next_byte == '#' and in_plural)) {
			# Quoted text: to the next lone apostrophe ('' inside it is one), or the end.
			var $j = $i + 1
			var $quoting = Bool.True
			while $quoting and $j < bytes.len() {
				c = at(bytes, $j)
				if c == '\'' and at(bytes, $j + 1) == '\'' {
					$text = $text.append('\'')
					$j = $j + 2
				} else if c == '\'' {
					$quoting = Bool.False
					$j = $j + 1
				} else {
					$text = $text.append(c)
					$j = $j + 1
				}
			}
			$i = $j
		} else {
			$text = $text.append(b)
			$i = $i + 1
		}
	}
	match $problem {
		Err(problem) => Err(problem)
		Ok(_) =>
			if depth > 0 and $i >= bytes.len() {
				Err({ at: $i, why: "a `{` that is never closed" })
			} else {
				all = flush($found, $text)
				Ok({ found: if (all.len() == 1) (all.first() ?? Parts([])) else Parts(all), next: $i })
			}
	}
}

flush : List(Message), List(U8) -> List(Message)
flush = |found, text| if (text.is_empty()) found else found.append(Literal(Str.from_utf8_lossy(text)))

## After a `{`: a name, then `}` or a type (and its style or cases), then the `}` (taken).
argument_at : List(U8), U64, Bool, U64 -> Try({ found : Message, next : U64 }, Problem)
argument_at = |bytes, from, in_plural, depth| {
	start = skip_space(bytes, from)
	{ text: name, next: after_name } = word(bytes, start)
	i = skip_space(bytes, after_name)
	if name == "" {
		Err({ at: start, why: "an argument with no name" })
	} else if at(bytes, i) == '}' {
		Ok({ found: Value(name), next: i + 1 })
	} else if at(bytes, i) != ',' {
		Err({ at: i, why: "`${name}` followed by neither `}` nor `,`" })
	} else {
		kind_at = skip_space(bytes, i + 1)
		{ text: kind, next: after_kind } = word(bytes, kind_at)
		j = skip_space(bytes, after_kind)
		has_style = at(bytes, j) == ','
		style_at = if (has_style) skip_space(bytes, j + 1) else j
		if kind == "plural" or kind == "selectordinal" or kind == "select" {
			if has_style {
				cases_at(bytes, style_at, name, kind, if (kind == "select") in_plural else Bool.True, depth)
			} else {
				Err({ at: j, why: "`${name}`'s ${kind} has no cases" })
			}
		} else {
			{ text: style, next: after_style } = if (has_style) word(bytes, style_at) else { text: "", next: j }
			end = skip_space(bytes, after_style)
			made =
				if kind == "number" {
					match style {
						"" => Ok(Number(name, Plain))
						"integer" => Ok(Number(name, Integer))
						"percent" => Ok(Number(name, Percent))
						_ => Err({ at: style_at, why: "a number style must be `integer` or `percent`, not `${style}`" })
					}
				} else if kind == "date" {
					match style {
						"short" => Ok(Dated(name, Short))
						"" | "medium" => Ok(Dated(name, Medium))
						"long" => Ok(Dated(name, Long))
						"full" => Ok(Dated(name, Full))
						_ => Err({ at: style_at, why: "a date style must be `short`, `medium`, `long` or `full`, not `${style}`" })
					}
				} else if kind == "time" {
					match style {
						"short" => Ok(Timed(name, Short))
						"" | "medium" => Ok(Timed(name, Medium))
						_ => Err({ at: style_at, why: "a time style must be `short` or `medium`, not `${style}`" })
					}
				} else {
					Err({ at: kind_at, why: "`${kind}` isn't a type: `number`, `date`, `time`, `plural`, `selectordinal` or `select`" })
				}
			match made {
				Ok(found) => if (at(bytes, end) == '}') Ok({ found, next: end + 1 }) else Err({ at: end, why: "expected `}` after `${name}`'s ${kind}" })
				Err(problem) => Err(problem)
			}
		}
	}
}

## A plural's or a select's cases, each `key {message}`, to the `}` that closes the argument (taken).
cases_at : List(U8), U64, Str, Str, Bool, U64 -> Try({ found : Message, next : U64 }, Problem)
cases_at = |bytes, from, name, kind, in_plural, depth| {
	var $i = from
	var $offset = 0
	if kind != "select" and Str.from_utf8_lossy(bytes.sublist({ start: from, len: 7 })) == "offset:" {
		after = skip_space(bytes, from + 7)
		{ text: digits, next } = word(bytes, after)
		$offset = I64.from_str(digits) ?? 0
		$i = next
	}
	var $cases = []
	var $problem = Ok({})
	var $going = Bool.True
	while $going {
		$i = skip_space(bytes, $i)
		b = at(bytes, $i)
		if $i >= bytes.len() {
			$problem = Err({ at: $i, why: "`${name}`'s ${kind} is never closed" })
			$going = Bool.False
		} else if b == '}' {
			$going = Bool.False
		} else {
			exact = b == '='
			{ text: key, next: after_key } = word(bytes, if (exact) $i + 1 else $i)
			open = skip_space(bytes, after_key)
			if key == "" {
				$problem = Err({ at: $i, why: "a case of `${name}`'s ${kind} with no key" })
				$going = Bool.False
			} else if kind != "select" and !exact and Plural.from_name(key).is_err() {
				$problem = Err({ at: $i, why: "`${key}` isn't a plural category: zero, one, two, few, many, other, or `=` and a number" })
				$going = Bool.False
			} else if at(bytes, open) != '{' {
				$problem = Err({ at: open, why: "expected `{` after the case `${key}`" })
				$going = Bool.False
			} else {
				match parts(bytes, open + 1, in_plural, depth + 1) {
					Ok({ found, next }) => {
						$cases = $cases.append((if (exact) "=${key}" else key, found))
						$i = next + 1
					}
					Err(problem) => {
						$problem = Err(problem)
						$going = Bool.False
					}
				}
			}
		}
	}
	match $problem {
		Err(problem) => Err(problem)
		Ok(_) =>
			if !$cases.any(|(key, _)| key == "other") {
				Err({ at: $i, why: "`${name}`'s ${kind} has no `other` case" })
			} else if kind == "select" {
				Ok({ found: Select({ name, cases: $cases }), next: $i + 1 })
			} else {
				Ok({ found: Plural({ name, ordinal: kind == "selectordinal", offset: $offset, cases: $cases }), next: $i + 1 })
			}
	}
}

# --- Tests, in English, Polish, French and Arabic.

say : Locales.Data, Str, List((Str, Message.Arg)) -> Str
say = |data, source, args|
	match Message.parse(source) {
		Ok(message) => Message.format(message, data, 0, args)
		Err(BadMessage({ at: offset, why })) => "!! at ${offset.to_str()}: ${why}"
	}

files : Str
files = "{count, plural, =0 {No files} one {# file} other {# files}}"

pliki : Str
pliki = "{count, plural, =0 {Brak plików} one {# plik} few {# pliki} many {# plików} other {# pliku}}"

expect say(Locales.en, "Hello, {name}!", [("name", Text("Ada"))]) == "Hello, Ada!"
expect say(Locales.en, "Hello, {name}!", []) == "Hello, {name}!"
expect say(Locales.en, files, [("count", Int(0))]) == "No files"
expect say(Locales.en, files, [("count", Int(1))]) == "1 file"
expect say(Locales.en, files, [("count", Int(1234))]) == "1,234 files"
expect say(Locales.en, files, [("count", Num(1.5))]) == "1.5 files"
expect say(Locales.pl, pliki, [("count", Int(1))]) == "1 plik"
expect say(Locales.pl, pliki, [("count", Int(3))]) == "3 pliki"
expect say(Locales.pl, pliki, [("count", Int(5))]) == "5 plików"
expect say(Locales.pl, pliki, [("count", Int(22))]) == "22 pliki"
expect say(Locales.pl, pliki, [("count", Int(12))]) == "12 plików"
expect say(Locales.pl, pliki, [("count", Num(2.5))]) == "2,5 pliku"
expect say(Locales.pl, pliki, [("count", Int(12345))]) == "12\u(A0)345 plików"
expect say(Locales.ar, "{n, plural, zero {لا ملفات} one {ملف واحد} two {ملفان} few {# ملفات} many {# ملفًا} other {# ملف}}", [("n", Int(2))]) == "ملفان"
expect say(Locales.ar, "{n, plural, zero {لا ملفات} one {ملف واحد} two {ملفان} few {# ملفات} many {# ملفًا} other {# ملف}}", [("n", Int(11))]) == "11 ملفًا"
expect say(Locales.en, "{place, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}", [("place", Int(22))]) == "22nd"
expect say(Locales.en, "{place, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}", [("place", Int(13))]) == "13th"
expect say(Locales.fr, "{place, selectordinal, one {#er} other {#e}}", [("place", Int(1))]) == "1er"
expect say(Locales.en, "{guests, plural, offset:1 =0 {Nobody} =1 {{host}} one {{host} and # other} other {{host} and # others}}", [("guests", Int(3)), ("host", Text("Ada"))]) == "Ada and 2 others"
expect say(Locales.en, "{guests, plural, offset:1 =0 {Nobody} =1 {{host}} one {{host} and # other} other {{host} and # others}}", [("guests", Int(2)), ("host", Text("Ada"))]) == "Ada and 1 other"
expect say(Locales.en, "{guests, plural, offset:1 =0 {Nobody} =1 {{host}} one {{host} and # other} other {{host} and # others}}", [("guests", Int(1)), ("host", Text("Ada"))]) == "Ada"
expect say(Locales.en, "{role, select, admin {Administrator} other {Member}}", [("role", Text("admin"))]) == "Administrator"
expect say(Locales.en, "{role, select, admin {Administrator} other {Member}}", [("role", Text("guest"))]) == "Member"
expect say(Locales.en, "{role, select, admin {{n, plural, one {# admin} other {# admins}}} other {#}}", [("role", Text("admin")), ("n", Int(2))]) == "2 admins"
expect say(Locales.de, "{total, number} · {share, number, percent} · {n, number, integer}", [("total", Num(1234.5)), ("share", Num(0.25)), ("n", Num(2.5))]) == "1.234,5 · 25\u(A0)% · 3"
expect say(Locales.en, "{when, date, long} at {when, time, short}", [("when", Moment(1795273445000))]) == "November 21, 2026 at 3:04 PM"
expect say(Locales.pl, "{when, date, long}", [("when", Moment(1795273445000))]) == "21 listopada 2026"
expect say(Locales.fr, "l'heure est venue", []) == "l'heure est venue"
expect say(Locales.en, "It''s '{literal}' and '#' and {n, plural, other {'#' is #}}", [("n", Int(5))]) == "It's {literal} and '#' and # is 5"
expect say(Locales.en, "  spaced {  name  }  ", [("name", Text("x"))]) == "  spaced x  "
expect say(Locales.en, "{n, plural, one {# file}}", []) == "!! at 24: `n`'s plural has no `other` case"
expect say(Locales.en, "{n, plural, lots {#} other {#}}", []) == "!! at 12: `lots` isn't a plural category: zero, one, two, few, many, other, or `=` and a number"
expect say(Locales.en, "Hello {name", []) == "!! at 11: `name` followed by neither `}` nor `,`"
expect say(Locales.en, "{n, plural, one {# file", []) == "!! at 23: a `{` that is never closed"
expect say(Locales.en, "Oops }", []) == "!! at 5: a `}` with no `{` before it"
expect say(Locales.en, "{n, money}", []) == "!! at 4: `money` isn't a type: `number`, `date`, `time`, `plural`, `selectordinal` or `select`"
expect say(Locales.en, "{}", []) == "!! at 1: an argument with no name"
expect Message.parse(files).map_ok(Message.names) == Ok(["count"])
expect Message.parse("{a} {b, plural, one {{c}} other {{a}}} {d, select, x {{e}} other {}}").map_ok(Message.names) == Ok(["a", "b", "c", "d", "e"])
expect say(Locales.pl, pliki, [("count", Text("22"))]) == "22 pliki"
expect say(Locales.de, "{n, number}", [("n", Text("1500.5"))]) == "1.500,5"
expect say(Locales.de, "{n, number}", [("n", Text("lots"))]) == "lots"
expect say(Locales.pl, "{d, date, long}", [("d", Text("2026-01-05"))]) == "5 stycznia 2026"
expect say(Locales.pl, "{d, date, long}", [("d", Text("soon"))]) == "soon"
