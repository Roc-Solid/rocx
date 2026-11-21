## What is wrong with what was typed, field by field: each issue says where (`field`, the name the
## form posts it under; `tags[2]` for a list's third item; `""` for the form as a whole), what
## (`code`, a tag with what it needs to be said: `TooShort(3)`), and the English for it
## (`message`). The same issues come from a browser checking as someone types and from an endpoint
## refusing what was posted, so a page shows either the same way.
##
## A code is a plain value: to say it in another language, match on it, or look it up by its
## `key` (`"too_short"`) and `params` (`min: 3`).
Issues := [].{

	## What is wrong. A number in a code is a `Dec`, whole numbers' too, so it says the same
	## whether the field reads an `I64` or a `Dec`.
	##
	## - `Required`: nothing typed, or nothing chosen.
	## - `Unchecked`: a box that must be ticked.
	## - `TooShort(min)`, `TooLong(max)`: characters (code points), as a browser's `minlength`
	##   counts them.
	## - `NoMatch(pattern)`: not in the pattern's format.
	## - `NotEmail`, `NotUrl`, `NotDate`: not an email address, a web address, a date.
	## - `NotOneOf(options)`: none of the options it may be.
	## - `NotInteger`, `NotNumber`: not a whole number; not a number.
	## - `TooSmall(min)`, `TooLarge(max)`: a number out of range.
	## - `NotStep(below, above)`: between two that fit the step; the nearest.
	## - `TooEarly(min)`, `TooLate(max)`: a date out of range (`2026-01-01`).
	## - `TooFew(min)`, `TooMany(max)`: items in a list.
	## - `NotSame(other)`: not the same as the field `other` (a password, typed twice).
	## - `Custom(key, message)`: the app's own: its key, and its English.
	Code : [
		Required,
		Unchecked,
		TooShort(U64),
		TooLong(U64),
		NoMatch(Str),
		NotEmail,
		NotUrl,
		NotDate,
		NotOneOf(List(Str)),
		NotInteger,
		NotNumber,
		TooSmall(Dec),
		TooLarge(Dec),
		NotStep(Dec, Dec),
		TooEarly(Str),
		TooLate(Str),
		TooFew(U64),
		TooMany(U64),
		NotSame(Str),
		Custom(Str, Str),
	]

	## One thing wrong: where, what, and the English for it.
	Issue : { field : Str, code : Issues.Code, message : Str }

	## The status an endpoint refuses invalid input with: 422, Unprocessable Content.
	status : U16
	status = 422

	## An issue at `field`, with the code's English.
	at_field : Str, Issues.Code -> Issues.Issue
	at_field = |field, code| { field, code, message: Issues.english(code) }

	## A code in English, as a sentence to show beside its field (with no full stop):
	## `Issues.english(TooShort(3))` is `"Use at least 3 characters"`.
	english : Issues.Code -> Str
	english = |code|
		match code {
			Required => "Fill this in"
			Unchecked => "Tick this box to go on"
			TooShort(min) => "Use at least ${min.to_str()} ${characters(min)}"
			TooLong(max) => "Use ${max.to_str()} ${characters(max)} or fewer"
			NoMatch(_) => "Use the format asked for"
			NotEmail => "Enter an email address, like name@example.com"
			NotUrl => "Enter a web address, like https://example.com"
			NotDate => "Enter a date, like 2026-01-31"
			NotOneOf(_) => "Choose one of the options"
			NotInteger => "Enter a whole number"
			NotNumber => "Enter a number"
			TooSmall(min) => "Enter ${Issues.number(min)} or more"
			TooLarge(max) => "Enter ${Issues.number(max)} or less"
			NotStep(below, above) => "Enter ${Issues.number(below)} or ${Issues.number(above)}, the nearest allowed"
			TooEarly(min) => "Enter ${min} or later"
			TooLate(max) => "Enter ${max} or earlier"
			TooFew(min) => "Choose at least ${min.to_str()}"
			TooMany(max) => "Choose ${max.to_str()} or fewer"
			NotSame(_) => "These don't match"
			Custom(_, message) => message
		}

	## A code's name, for a table of translations: `"too_short"`; a custom code's own key.
	key : Issues.Code -> Str
	key = |code|
		match code {
			Required => "required"
			Unchecked => "unchecked"
			TooShort(_) => "too_short"
			TooLong(_) => "too_long"
			NoMatch(_) => "no_match"
			NotEmail => "not_email"
			NotUrl => "not_url"
			NotDate => "not_date"
			NotOneOf(_) => "not_one_of"
			NotInteger => "not_integer"
			NotNumber => "not_number"
			TooSmall(_) => "too_small"
			TooLarge(_) => "too_large"
			NotStep(_, _) => "not_step"
			TooEarly(_) => "too_early"
			TooLate(_) => "too_late"
			TooFew(_) => "too_few"
			TooMany(_) => "too_many"
			NotSame(_) => "not_same"
			Custom(own, _) => own
		}

	## What a code says beyond its name, by name, as text, for a translation to put in its place:
	## `TooShort(3)` has `min: "3"`; `NotStep(5, 10)` has `below: "5"` and `above: "10"`.
	params : Issues.Code -> List({ name : Str, value : Str })
	params = |code| {
		one = |name, value| [{ name, value }]
		match code {
			TooShort(min) => one("min", min.to_str())
			TooLong(max) => one("max", max.to_str())
			NoMatch(pattern) => one("pattern", pattern)
			NotOneOf(options) => one("options", Str.join_with(options, ", "))
			TooSmall(min) => one("min", Issues.number(min))
			TooLarge(max) => one("max", Issues.number(max))
			NotStep(below, above) => [{ name: "below", value: Issues.number(below) }, { name: "above", value: Issues.number(above) }]
			TooEarly(min) => one("min", min)
			TooLate(max) => one("max", max)
			TooFew(min) => one("min", min.to_str())
			TooMany(max) => one("max", max.to_str())
			NotSame(other) => one("other", other)
			_ => []
		}
	}

	## The issues at `field`, exactly: `Issues.at(issues, "email")`.
	at : List(Issues.Issue), Str -> List(Issues.Issue)
	at = |issues, field| issues.keep_if(|issue| issue.field == field)

	## The issues at `field` and at its items (`tags`, `tags[0]`, `tags[1]`…).
	under : List(Issues.Issue), Str -> List(Issues.Issue)
	under = |issues, field| issues.keep_if(|issue| issue.field == field or issue.field.starts_with("${field}["))

	## The messages at `field`, in order.
	messages : List(Issues.Issue), Str -> List(Str)
	messages = |issues, field| Issues.at(issues, field).map(|issue| issue.message)

	## The issues as JSON, an array of `{"code":…,"field":…,"message":…}`: what an endpoint refuses
	## with (`refusal`), and what a page reads back (`from_problem`).
	to_json : List(Issues.Issue) -> Str
	to_json = |issues| Json.to_str(issues)

	## Issues from their JSON (`to_json`).
	from_json : Str -> Try(List(Issues.Issue), [NotIssues])
	from_json = |json| {
		parsed : Try(List(Issues.Issue), [InvalidJson(Str)])
		parsed = Json.parse(json)
		match parsed {
			Ok(issues) => Ok(issues)
			Err(InvalidJson(_)) => Err(NotIssues)
		}
	}

	## An endpoint's refusal of input with these issues: 422, and them as JSON. A handler answers
	## `Err(Issues.refusal(issues))`.
	refusal : List(Issues.Issue) -> [Status(U16, Str)]
	refusal = |issues| Status(Issues.status, Issues.to_json(issues))

	## The issues an endpoint refused with, from what a submission's `error!()` or `Endpoint.send!`
	## says went wrong (`Server.Problem`): a 422's issues. Any other problem has none.
	from_problem : [HttpErr(Str), Refused(U16, Str), BadAnswer(Str)] -> List(Issues.Issue)
	from_problem = |problem|
		match problem {
			Refused(422, body) => Issues.from_json(body) ?? []
			_ => []
		}

	## A number as a person writes it: `18`, not `18.0`; `0.5`.
	number : Dec -> Str
	number = |x| {
		text = x.to_str()
		if text.contains(".") {
			var $text = text
			while $text.ends_with("0") {
				$text = $text.drop_suffix("0")
			}
			short = $text.drop_suffix(".")
			if (short == "-0") "0" else short
		} else {
			text
		}
	}
}

## "character", or "characters".
characters : U64 -> Str
characters = |count| if (count == 1) "character" else "characters"

sample : List(Issues.Issue)
sample = [
	Issues.at_field("name", Required),
	Issues.at_field("name", TooShort(3)),
	Issues.at_field("age", TooSmall(18.0)),
	Issues.at_field("tags[1]", NotOneOf(["a", "b"])),
	Issues.at_field("", Custom("closed", "Sign-ups are closed")),
]

expect Issues.english(TooShort(1)) == "Use at least 1 character"
expect Issues.english(TooLong(80)) == "Use 80 characters or fewer"
expect Issues.english(TooSmall(18.0)) == "Enter 18 or more"
expect Issues.english(TooLarge(2.50)) == "Enter 2.5 or less"
expect Issues.english(NotStep(5.0, 10.0)) == "Enter 5 or 10, the nearest allowed"
expect Issues.english(Custom("taken", "That name is taken")) == "That name is taken"
expect Issues.key(TooShort(3)) == "too_short"
expect Issues.key(Custom("taken", "That name is taken")) == "taken"
expect Issues.params(TooShort(3)) == [{ name: "min", value: "3" }]
expect Issues.params(NotStep(-0.5, 0.5)) == [{ name: "below", value: "-0.5" }, { name: "above", value: "0.5" }]
expect Issues.params(Required) == []
expect Issues.at(sample, "name").map(|issue| issue.code) == [Required, TooShort(3)]
expect Issues.messages(sample, "age") == ["Enter 18 or more"]
expect Issues.under(sample, "tags").len() == 1
expect Issues.at(sample, "tags") == []
expect Issues.number(-0.0) == "0"
expect Issues.number(1200.0) == "1200"
expect Issues.to_json([Issues.at_field("age", TooSmall(18.0))]) == "[{\"code\":{\"TooSmall\":18.0},\"field\":\"age\",\"message\":\"Enter 18 or more\"}]"
expect Issues.from_json(Issues.to_json(sample)) == Ok(sample)
expect Issues.from_json("nope") == Err(NotIssues)
expect Issues.from_problem(Refused(422, Issues.to_json(sample))) == sample
expect Issues.from_problem(Refused(400, Issues.to_json(sample))) == []
expect Issues.from_problem(HttpErr("offline")) == []
expect Issues.refusal(sample) == Status(422, Issues.to_json(sample))
