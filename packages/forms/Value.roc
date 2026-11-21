import Regex
import Issues
import Date

## How one value is read from what was typed, and checked: as text, a whole number, a decimal, a
## box, one of some choices, a day. Each kind takes a list of checks, run in order, and reads the
## text a browser sends into a Roc value, or says what is wrong with it (several things, when
## several are). `Form` puts a value under a field's name.
##
##     Value.text([Trim, Required, MaxLength(80)])
##     Value.int([Min(18), Max(130)])
##     Value.choice([("free", Free), ("pro", Pro)])
##
## A text check other than `Required` passes an empty value, as a browser's `minlength` and
## `pattern` do: `Value.text([Email])` takes `""` or an email address.
Value(a) := { read : Str -> Read(a), facts : List(Fact) }.{

	## Text's checks, in order. `Trim`, `Lowercase` and `CollapseSpaces` change the text for those
	## after them (and for what is read); the rest check it.
	##
	## - `Trim`: white space off both ends. `CollapseSpaces`: each run of white space inside one space.
	## - `Lowercase`: A to Z as a to z (an email address, a username).
	## - `Required`: not empty (`Required` if it is).
	## - `MinLength(n)`, `MaxLength(n)`: at least, at most `n` characters (code points).
	## - `Matches(pattern)`: the whole text matches the pattern (`Regex`), as a browser's `pattern`
	##   attribute checks it. A bad pattern crashes where the value is made: in a top-level value,
	##   that stops the build.
	## - `Email`: an email address, as `<input type="email">` checks one.
	## - `Url`: an `http` or `https` address, with a host and no spaces.
	## - `OneOf(options)`: one of them, exactly.
	## - `Secret`: a password, never shown again: its input is `type="password"`, and a page that
	##   comes back after a post doesn't fill it in.
	TextCheck : [Trim, Lowercase, CollapseSpaces, Required, MinLength(U64), MaxLength(U64), Matches(Str), Email, Url, OneOf(List(Str)), Secret]

	## A whole number's checks: at least, at most, and a step (from the `Min`, if there is one, or
	## from 0, as a browser's `step` goes).
	IntCheck : [Min(I64), Max(I64), Step(I64)]

	## A decimal's checks, as a whole number's.
	DecCheck : [Min(Dec), Max(Dec), Step(Dec)]

	## A day's checks: no earlier, no later than a day (`"2026-01-01"`).
	DateCheck : [Min(Str), Max(Str)]

	## What a browser's constraint attributes say of a value: the input's `type`, and `required`,
	## `minlength`, `maxlength`, `pattern`, `min`, `max` and `step`, each `""` when it has none, so
	## a component writes them with `??=` (`minlength??={attributes.minlength}`).
	Attributes : { type : Str, required : Bool, minlength : Str, maxlength : Str, pattern : Str, min : Str, max : Str, step : Str }

	## Text, as typed, checked in order.
	text : List(Value.TextCheck) -> Value(Str)
	text = |checks| {
		steps = checks.map(text_step)
		facts = checks.keep_oks(
			|rule|
				match rule {
					Required => Ok(Required)
					MinLength(n) => Ok(MinLength(n))
					MaxLength(n) => Ok(MaxLength(n))
					Matches(pattern) => Ok(Pattern(pattern))
					Email => Ok(Email)
					Url => Ok(Url)
					OneOf(options) => Ok(OneOf(options))
					Secret => Ok(Secret)
					_ => Err(NoFact)
				},
		)
		{
			read: |raw| {
				var $value = raw
				var $codes = []
				for step in steps {
					if $codes.contains(Required) {
						{}
					} else {
						match step {
							Change(change) => {
								$value = change($value)
							}
							Need => {
								if $value.is_empty() {
									$codes = $codes.append(Required)
								}
							}
							Test(ok, code) => {
								if !$value.is_empty() and !ok($value) {
									$codes = $codes.append(code)
								}
							}
						}
					}
				}
				if $codes.contains(Required) {
					{ value: Err(Unread), codes: $codes }
				} else {
					{ value: Ok($value), codes: $codes }
				}
			},
			facts: [Text].concat(facts),
		}
	}

	## A whole number (`-12`, `+3`, ` 42 `: white space around it is fine), as an `I64`. Empty is
	## `Required`; anything else that isn't one, `NotInteger`.
	int : List(Value.IntCheck) -> Value(I64)
	int = |checks| {
		base = checks.fold(
			0,
			|found, rule|
				match rule {
					Min(min) => min
					_ => found
				},
		)
		{
			read: |raw| {
				typed = raw.trim()
				if typed.is_empty() {
					{ value: Err(Unread), codes: [Required] }
				} else if !integer.matches(typed) {
					{ value: Err(Unread), codes: [NotInteger] }
				} else {
					match I64.from_str(typed.drop_prefix("+")) {
						Ok(n) => {
							value = n.to_dec()
							codes = checks.keep_oks(
								|rule|
									match rule {
										Min(min) => if (n < min) Ok(TooSmall(min.to_dec())) else Err(Fine)
										Max(max) => if (n > max) Ok(TooLarge(max.to_dec())) else Err(Fine)
										Step(step) => stepped(value, base.to_dec(), step.to_dec())
									},
							)
							{ value: Ok(n), codes }
						}
						Err(_) => { value: Err(Unread), codes: [NotInteger] }
					}
				}
			},
			facts: [Integer].concat(
				checks.map(
					|rule|
						match rule {
							Min(min) => Min(min.to_str())
							Max(max) => Max(max.to_str())
							Step(step) => Step(step.to_str())
						},
				),
			),
		}
	}

	## A decimal number (`2.5`, `-0.75`, `.5`, `3`), as a `Dec`: a `.` before the decimals, and no
	## exponent. Empty is `Required`; anything else that isn't one, `NotNumber`.
	dec : List(Value.DecCheck) -> Value(Dec)
	dec = |checks| {
		base = checks.fold(
			0.0,
			|found, rule|
				match rule {
					Min(min) => min
					_ => found
				},
		)
		{
			read: |raw| {
				typed = raw.trim()
				if typed.is_empty() {
					{ value: Err(Unread), codes: [Required] }
				} else if !decimal.matches(typed) {
					{ value: Err(Unread), codes: [NotNumber] }
				} else {
					match Dec.from_str(plain_decimal(typed)) {
						Ok(x) => {
							codes = checks.keep_oks(
								|rule|
									match rule {
										Min(min) => if (x < min) Ok(TooSmall(min)) else Err(Fine)
										Max(max) => if (x > max) Ok(TooLarge(max)) else Err(Fine)
										Step(step) => stepped(x, base, step)
									},
							)
							{ value: Ok(x), codes }
						}
						Err(_) => { value: Err(Unread), codes: [NotNumber] }
					}
				}
			},
			facts: [Decimal].concat(
				checks.map(
					|rule|
						match rule {
							Min(min) => Min(Issues.number(min))
							Max(max) => Max(Issues.number(max))
							Step(step) => Step(Issues.number(step))
						},
				),
			),
		}
	}

	## A checkbox: ticked (sent, with any value) or not (not sent at all, which a form reads as
	## `""`). `[Required]`: it must be ticked (`Unchecked` if it isn't), as `required` on a
	## checkbox means.
	checkbox : List([Required]) -> Value(Bool)
	checkbox = |checks| {
		required = !checks.is_empty()
		{
			read: |raw| {
				ticked = !raw.is_empty()
				{ value: Ok(ticked), codes: if (required and !ticked) [Unchecked] else [] }
			},
			facts: if (required) [Checkbox, Required] else [Checkbox],
		}
	}

	## One of some choices, by the value a `<select>`'s option or a radio button sends, read as
	## what it stands for: `Value.choice([("free", Free), ("pro", Pro)])` reads `"pro"` as `Pro`.
	## Empty (a select's "Choose…" option, or no radio button picked) is `Required`; any other
	## value, `NotOneOf` the options.
	choice : List((Str, a)) -> Value(a)
	choice = |options| {
		keys = options.map(|(key, _)| key)
		{
			read: |raw|
				if raw.is_empty() {
					{ value: Err(Unread), codes: [Required] }
				} else {
					match options.find_first(|(key, _)| key == raw) {
						Ok((_, chosen)) => { value: Ok(chosen), codes: [] }
						Err(_) => { value: Err(Unread), codes: [NotOneOf(keys)] }
					}
				},
			facts: [Choice, OneOf(keys)],
		}
	}

	## A day, as `<input type="date">` sends it (`2026-11-21`). Empty is `Required`; anything else
	## that isn't one, `NotDate`. A bad `Min` or `Max` crashes where the value is made.
	date : List(Value.DateCheck) -> Value(Date)
	date = |checks| {
		bounds = checks.map(
			|rule|
				match rule {
					Min(iso) => Min(must_date(iso), iso)
					Max(iso) => Max(must_date(iso), iso)
				},
		)
		{
			read: |raw| {
				typed = raw.trim()
				if typed.is_empty() {
					{ value: Err(Unread), codes: [Required] }
				} else {
					match Date.from_str(typed) {
						Ok(day) => {
							codes = bounds.keep_oks(
								|bound|
									match bound {
										Min(min, iso) => if (day.is_before(min)) Ok(TooEarly(iso)) else Err(Fine)
										Max(max, iso) => if (day.is_after(max)) Ok(TooLate(iso)) else Err(Fine)
									},
							)
							{ value: Ok(day), codes }
						}
						Err(NotDate) => { value: Err(Unread), codes: [NotDate] }
					}
				}
			},
			facts: [Day].concat(
				checks.map(
					|rule|
						match rule {
							Min(iso) => Min(iso)
							Max(iso) => Max(iso)
						},
				),
			),
		}
	}

	## A check of the value read: `code` unless `ok(value)`.
	##
	##     Value.text([Trim, Required]).check(|name| !reserved.contains(name), Custom("reserved", "That name is taken"))
	check : Value(a), (a -> Bool), Issues.Code -> Value(a)
	check = |value, ok, code| {
		inner = value.read
		{
			read: |raw| {
				got = inner(raw)
				match got.value {
					Ok(read) => if (ok(read)) got else { ..got, codes: got.codes.append(code) }
					Err(Unread) => got
				}
			},
			facts: value.facts,
		}
	}

	## The value read, made into another: `Value.text([Trim, Required]).map(Username)`.
	map : Value(a), (a -> b) -> Value(b)
	map = |value, change| {
		inner = value.read
		{
			read: |raw| {
				got = inner(raw)
				{ value: got.value.map_ok(change), codes: got.codes }
			},
			facts: value.facts,
		}
	}

	## The value read, made into another, or what is wrong: parse, don't validate.
	##
	##     Value.text([Trim]).try_map(|typed| Isbn.from_str(typed) ?? Err(Custom("isbn", "Enter an ISBN")))
	try_map : Value(a), (a -> Try(b, Issues.Code)) -> Value(b)
	try_map = |value, change| {
		inner = value.read
		{
			read: |raw| {
				got = inner(raw)
				match got.value {
					Ok(read) =>
						if got.codes.is_empty() {
							match change(read) {
								Ok(changed) => { value: Ok(changed), codes: [] }
								Err(code) => { value: Err(Unread), codes: [code] }
							}
						} else {
							{ value: Err(Unread), codes: got.codes }
						}
					Err(Unread) => { value: Err(Unread), codes: got.codes }
				}
			},
			facts: value.facts,
		}
	}

	## Reads `raw`, as a browser sends it: the value, or each thing wrong with it.
	##
	##     Value.int([Min(18)]).parse("16") == Err([TooSmall(18)])
	parse : Value(a), Str -> Try(a, List(Issues.Code))
	parse = |value, raw| {
		inner = value.read
		got = inner(raw)
		match got.value {
			Ok(read) => if (got.codes.is_empty()) Ok(read) else Err(got.codes)
			Err(Unread) => Err(got.codes)
		}
	}

	## The value's reading and checks, for `Form`: a value as read, and the codes of what is
	## wrong (a value can be read and still be wrong: too short).
	reader : Value(a) -> (Str -> { value : Try(a, [Unread]), codes : List(Issues.Code) })
	reader = |value| value.read

	## Whether a value must be given: a `Required` text or box, a number, a choice, a day.
	is_required : Value(a) -> Bool
	is_required = |value| value.facts.any(|fact| fact == Required or fact == Integer or fact == Decimal or fact == Choice or fact == Day)

	## What a browser's constraint attributes say of it (`Attributes`), so it checks as this does,
	## without the runtime too. Only the first `Matches` has a `pattern`; `OneOf`, `check` and
	## `try_map` have none.
	attributes : Value(a) -> Value.Attributes
	attributes = |value|
		value.facts.fold(
			{ type: "text", required: Bool.False, minlength: "", maxlength: "", pattern: "", min: "", max: "", step: "" },
			|so_far, fact|
				match fact {
					Required => { ..so_far, required: Bool.True }
					Integer => { ..so_far, type: "number", required: Bool.True }
					Decimal => { ..so_far, type: "number", required: Bool.True, step: "any" }
					Day => { ..so_far, type: "date", required: Bool.True }
					Choice => { ..so_far, required: Bool.True }
					Checkbox => { ..so_far, type: "checkbox" }
					Email => { ..so_far, type: "email" }
					Url => { ..so_far, type: "url" }
					Secret => { ..so_far, type: "password" }
					MinLength(n) => { ..so_far, minlength: n.to_str() }
					MaxLength(n) => { ..so_far, maxlength: n.to_str() }
					Pattern(pattern) => if (so_far.pattern.is_empty()) { ..so_far, pattern } else so_far
					Min(min) => { ..so_far, min }
					Max(max) => { ..so_far, max }
					Step(step) => { ..so_far, step }
					_ => so_far
				},
		)

	## Its JSON Schema, as an OpenAPI document describes a body: `{"type":"string","minLength":3}`.
	## Its pattern is anchored (`^(?:…)$`), since JSON Schema's matches anywhere.
	schema : Value(a) -> Str
	schema = |value| {
		var $type = "string"
		var $keywords = []
		var $min_length = 0
		for fact in value.facts {
			match fact {
				Integer => {
					$type = "integer"
				}
				Decimal => {
					$type = "number"
				}
				Checkbox => {
					$type = "boolean"
				}
				Day => {
					$keywords = $keywords.append("\"format\":\"date\"")
				}
				Required => {
					$min_length = U64.max($min_length, 1)
				}
				MinLength(n) => {
					$min_length = U64.max($min_length, n)
				}
				MaxLength(n) => {
					$keywords = $keywords.append("\"maxLength\":${n.to_str()}")
				}
				Pattern(pattern) => {
					$keywords = $keywords.append("\"pattern\":${Json.to_str("^(?:${pattern})$")}")
				}
				Email => {
					$keywords = $keywords.append("\"format\":\"email\"")
				}
				Url => {
					$keywords = $keywords.append("\"format\":\"uri\"")
				}
				Secret => {
					$keywords = $keywords.append("\"format\":\"password\"")
				}
				OneOf(options) => {
					$keywords = $keywords.append("\"enum\":${Json.to_str(options)}")
				}
				Min(min) => {
					$keywords = $keywords.append(if ($type == "string") "\"formatMinimum\":${Json.to_str(min)}" else "\"minimum\":${min}")
				}
				Max(max) => {
					$keywords = $keywords.append(if ($type == "string") "\"formatMaximum\":${Json.to_str(max)}" else "\"maximum\":${max}")
				}
				Step(step) => {
					if !value.facts.any(|other| is_min(other)) {
						$keywords = $keywords.append("\"multipleOf\":${step}")
					}
				}
				_ => {}
			}
		}
		lengths = if ($min_length == 0 or $type != "string") [] else ["\"minLength\":${$min_length.to_str()}"]
		"{${Str.join_with(["\"type\":\"${$type}\""].concat(lengths).concat($keywords), ",")}}"
	}
}

## What `Value(a)` reads: the value, unless it couldn't be read, and what is wrong with it.
Read(a) : { value : Try(a, [Unread]), codes : List(Issues.Code) }

## What a value says of itself, for the attributes a browser checks it by and its JSON Schema.
Fact : [Text, Integer, Decimal, Checkbox, Choice, Day, Required, MinLength(U64), MaxLength(U64), Pattern(Str), Email, Url, OneOf(List(Str)), Secret, Min(Str), Max(Str), Step(Str)]

## A text check as a step: a change, `Required`, or a test of a non-empty text.
text_step : Value.TextCheck -> [Change(Str -> Str), Need, Test(Str -> Bool, Issues.Code)]
text_step = |rule|
	match rule {
		Trim => Change(Str.trim)
		Lowercase => Change(Str.with_ascii_lowercased)
		CollapseSpaces => Change(collapse_spaces)
		Required => Need
		MinLength(min) => Test(|typed| length(typed) >= min, TooShort(min))
		MaxLength(max) => Test(|typed| length(typed) <= max, TooLong(max))
		Matches(pattern) => {
			regex = Regex.must(pattern)
			Test(|typed| regex.matches(typed), NoMatch(pattern))
		}
		Email => Test(|typed| email.matches(typed), NotEmail)
		Url => Test(|typed| url.matches(typed), NotUrl)
		OneOf(options) => Test(|typed| options.contains(typed), NotOneOf(options))
		Secret => Change(|typed| typed)
	}

is_min : Fact -> Bool
is_min = |fact|
	match fact {
		Min(_) => Bool.True
		_ => Bool.False
	}

## The code a step adds: none when `value` is `base` plus a whole number of steps; otherwise the
## nearest that are, below and above.
stepped : Dec, Dec, Dec -> Try(Issues.Code, [Fine])
stepped = |value, base, step|
	if step <= 0.0 {
		Err(Fine)
	} else {
		below = base + (value - base).div_floor_by(step) * step
		if (below == value) Err(Fine) else Ok(NotStep(below, below + step))
	}

## How many characters (code points) a text has: its bytes but the ones that continue a character.
length : Str -> U64
length = |typed| typed.to_utf8().count_if(|byte| byte < 0x80 or byte >= 0xC0)

## Each run of white space, a space; none at either end.
collapse_spaces : Str -> Str
collapse_spaces = |typed| {
	spaced = typed.replace_each("\t", " ").replace_each("\n", " ").replace_each("\r", " ")
	Str.join_with(spaced.split_on(" ").keep_if(|part| !part.is_empty()), " ")
}

must_date : Str -> Date
must_date = |iso|
	match Date.from_str(iso) {
		Ok(day) => day
		Err(NotDate) => crash "Value.date: ${Str.inspect(iso)} isn't a day: write one as 2026-01-31"
	}

## As `<input type="email">` checks an address (the HTML standard's own pattern).
email : Regex
email = Regex.must("^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$")

## An `http` or `https` address: a host, then a path, a query or a fragment, if any; no spaces.
url : Regex
url = Regex.must("^[hH][tT][tT][pP][sS]?://[^\\s/?#@]+(?:[/?#]\\S*)?$")

integer : Regex
integer = Regex.must("^[+-]?\\d+$")

decimal : Regex
decimal = Regex.must("^[+-]?(?:\\d+(?:\\.\\d*)?|\\.\\d+)$")

## A decimal as `Dec.from_str` reads one: `+.5` as `0.5`, `3.` as `3`.
plain_decimal : Str -> Str
plain_decimal = |typed| {
	unsigned = typed.drop_prefix("+")
	(sign, digits) = if (unsigned.starts_with("-")) ("-", unsigned.drop_prefix("-")) else ("", unsigned)
	whole = if (digits.starts_with(".")) "0${digits}" else digits
	"${sign}${whole.drop_suffix(".")}"
}

name : Value(Str)
name = Value.text([Trim, Required, MinLength(2), MaxLength(5)])

# Text.
expect name.parse("  Ada ") == Ok("Ada")
expect name.parse("   ") == Err([Required])
expect name.parse("A") == Err([TooShort(2)])
expect name.parse("Adelaide") == Err([TooLong(5)])
expect Value.text([MinLength(2)]).parse("") == Ok("")
expect Value.text([]).parse(" as typed ") == Ok(" as typed ")
expect Value.text([MinLength(2), Matches("[a-z]+")]).parse("7") == Err([TooShort(2), NoMatch("[a-z]+")])
expect Value.text([MaxLength(2)]).parse("élé") == Err([TooLong(2)])
expect Value.text([MaxLength(3)]).parse("élé") == Ok("élé")
expect Value.text([Trim, Lowercase, Email]).parse(" Ada@Example.COM ") == Ok("ada@example.com")
expect Value.text([Email]).parse("ada@example") == Ok("ada@example")
expect Value.text([Email]).parse("ada@") == Err([NotEmail])
expect Value.text([Email]).parse("ada lovelace@example.com") == Err([NotEmail])
expect Value.text([Email]).parse("a.b+c@sub-domain.example.org") == Ok("a.b+c@sub-domain.example.org")
expect Value.text([Email]).parse("ada@-example.com") == Err([NotEmail])
expect Value.text([Url]).parse("https://example.com/a?b=c#d") == Ok("https://example.com/a?b=c#d")
expect Value.text([Url]).parse("http://localhost:8080") == Ok("http://localhost:8080")
expect Value.text([Url]).parse("example.com") == Err([NotUrl])
expect Value.text([Url]).parse("https://exa mple.com") == Err([NotUrl])
expect Value.text([Url]).parse("javascript:alert(1)") == Err([NotUrl])
expect Value.text([OneOf(["a", "b"])]).parse("c") == Err([NotOneOf(["a", "b"])])
expect Value.text([CollapseSpaces]).parse("  Ada \t  King  ") == Ok("Ada King")
expect Value.text([Matches("\\d{2}-\\d{3}")]).parse("12-345") == Ok("12-345")
expect Value.text([Matches("\\d{2}-\\d{3}")]).parse("12-3456") == Err([NoMatch("\\d{2}-\\d{3}")])

# Numbers.
expect Value.int([]).parse(" 42 ") == Ok(42)
expect Value.int([]).parse("+3") == Ok(3)
expect Value.int([]).parse("-12") == Ok(-12)
expect Value.int([]).parse("") == Err([Required])
expect Value.int([]).parse("4.5") == Err([NotInteger])
expect Value.int([]).parse("1_000") == Err([NotInteger])
expect Value.int([]).parse("0x10") == Err([NotInteger])
expect Value.int([]).parse("99999999999999999999") == Err([NotInteger])
expect Value.int([Min(18), Max(130)]).parse("16") == Err([TooSmall(18.0)])
expect Value.int([Min(18), Max(130)]).parse("131") == Err([TooLarge(130.0)])
expect Value.int([Step(5)]).parse("15") == Ok(15)
expect Value.int([Step(5)]).parse("17") == Err([NotStep(15.0, 20.0)])
expect Value.int([Step(5)]).parse("-3") == Err([NotStep(-5.0, 0.0)])
expect Value.int([Min(1), Step(5)]).parse("11") == Ok(11)
expect Value.int([Min(1), Step(5)]).parse("10") == Err([NotStep(6.0, 11.0)])
expect Value.dec([]).parse("2.5") == Ok(2.5)
expect Value.dec([]).parse(".5") == Ok(0.5)
expect Value.dec([]).parse("-.5") == Ok(-0.5)
expect Value.dec([]).parse("3.") == Ok(3.0)
expect Value.dec([]).parse("+7") == Ok(7.0)
expect Value.dec([]).parse("1e3") == Err([NotNumber])
expect Value.dec([]).parse("1,5") == Err([NotNumber])
expect Value.dec([]).parse(".") == Err([NotNumber])
expect Value.dec([Min(0.5), Max(10.0)]).parse("0.25") == Err([TooSmall(0.5)])
expect Value.dec([Step(0.25)]).parse("1.75") == Ok(1.75)
expect Value.dec([Step(0.25)]).parse("1.8") == Err([NotStep(1.75, 2.0)])

# Boxes, choices, days.
expect Value.checkbox([]).parse("") == Ok(Bool.False)
expect Value.checkbox([]).parse("on") == Ok(Bool.True)
expect Value.checkbox([Required]).parse("") == Err([Unchecked])
expect Value.choice([("free", Free), ("pro", Pro)]).parse("pro") == Ok(Pro)
expect Value.choice([("free", Free), ("pro", Pro)]).parse("") == Err([Required])
expect Value.choice([("free", Free), ("pro", Pro)]).parse("gold") == Err([NotOneOf(["free", "pro"])])
expect Value.date([]).parse("2026-11-21").map_ok(Date.to_str) == Ok("2026-11-21")
expect Value.date([]).parse("2026-02-30") == Err([NotDate])
expect Value.date([Min("2026-01-01"), Max("2026-12-31")]).parse("2025-12-31") == Err([TooEarly("2026-01-01")])
expect Value.date([Min("2026-01-01"), Max("2026-12-31")]).parse("2027-01-01") == Err([TooLate("2026-12-31")])

# Checks and changes of the value read.
expect Value.text([Trim]).check(|typed| typed != "admin", Custom("reserved", "That name is taken")).parse(" admin ") == Err([Custom("reserved", "That name is taken")])
expect Value.text([Required]).check(|_| Bool.False, NotSame("x")).parse("") == Err([Required])
expect Value.int([]).map(|n| n * 2).parse("21") == Ok(42)
expect Value.text([Trim, Required]).try_map(|typed| if (typed.starts_with("#")) Ok(typed.drop_prefix("#")) else Err(Custom("tag", "Start with #"))).parse("#roc") == Ok("roc")
expect Value.text([Trim, Required]).try_map(|typed| if (typed.starts_with("#")) Ok(typed.drop_prefix("#")) else Err(Custom("tag", "Start with #"))).parse("roc") == Err([Custom("tag", "Start with #")])
expect Value.text([MinLength(5)]).try_map(|typed| Ok(typed.count_utf8_bytes())).parse("abc") == Err([TooShort(5)])

# What a browser and a JSON Schema are told.
expect name.attributes() == { type: "text", required: Bool.True, minlength: "2", maxlength: "5", pattern: "", min: "", max: "", step: "" }
expect Value.text([Email]).attributes().type == "email"
expect Value.int([Min(18), Step(2)]).attributes() == { type: "number", required: Bool.True, minlength: "", maxlength: "", pattern: "", min: "18", max: "", step: "2" }
expect Value.dec([]).attributes().step == "any"
expect Value.checkbox([Required]).attributes() == { type: "checkbox", required: Bool.True, minlength: "", maxlength: "", pattern: "", min: "", max: "", step: "" }
expect Value.date([Min("2026-01-01")]).attributes().min == "2026-01-01"
expect Value.text([Matches("[a-z]+"), Matches("x.*")]).attributes().pattern == "[a-z]+"
expect name.schema() == "{\"type\":\"string\",\"minLength\":2,\"maxLength\":5}"
expect Value.text([Trim, Lowercase, Email]).schema() == "{\"type\":\"string\",\"format\":\"email\"}"
expect Value.text([Matches("\\d+")]).schema() == "{\"type\":\"string\",\"pattern\":\"^(?:\\\\d+)$\"}"
expect Value.int([Min(18), Max(130)]).schema() == "{\"type\":\"integer\",\"minimum\":18,\"maximum\":130}"
expect Value.int([Step(5)]).schema() == "{\"type\":\"integer\",\"multipleOf\":5}"
expect Value.dec([Min(0.5)]).schema() == "{\"type\":\"number\",\"minimum\":0.5}"
expect Value.checkbox([]).schema() == "{\"type\":\"boolean\"}"
expect Value.choice([("free", Free), ("pro", Pro)]).schema() == "{\"type\":\"string\",\"enum\":[\"free\",\"pro\"]}"
expect Value.date([Min("2026-01-01")]).schema() == "{\"type\":\"string\",\"format\":\"date\",\"formatMinimum\":\"2026-01-01\"}"
expect Value.text([Required, MinLength(8), Secret]).attributes().type == "password"
expect Value.text([Required, Secret]).schema() == "{\"type\":\"string\",\"minLength\":1,\"format\":\"password\"}"
expect Value.text([Secret]).parse("hunter2") == Ok("hunter2")
expect Value.int([]).is_required()
expect !Value.text([]).is_required()
expect Value.text([Required]).is_required()
