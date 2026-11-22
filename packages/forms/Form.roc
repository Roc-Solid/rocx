import Value
import Issues
import Date

## A form's schema, written once in Roc and run on both sides: a browser checks what is typed as
## it is typed, and an endpoint reads what was posted with the very same rules, into a typed
## record, or refuses it with the same issues. Fields are put together with Roc's record builder,
## each under the name the form posts it as:
##
##     signup : Form({ name : Str, email : Str, age : I64, terms : Bool })
##     signup = {
##         name: Form.text("name", [Trim, Required, MaxLength(80)]),
##         email: Form.text("email", [Trim, Lowercase, Required, Email]),
##         age: Form.int("age", [Min(18), Max(130)]),
##         terms: Form.checkbox("terms", [Required]),
##     }.Form
##
##     signup.parse(posted) # Ok({ name: "Ada", … }), or Err(issues), each at its field
Form(a) := { read : Posted -> Parsed(a), fields : List(Field), at : Str }.{

	## What a browser posts: each field's name and value, in order, a name once for each value
	## (a list's, a group of checkboxes'), as `Server.form_fields` reads a form's body.
	Posted : List({ name : Str, value : Str })

	## A list's checks: at least, at most so many items.
	ListCheck : [MinItems(U64), MaxItems(U64)]

	## Two forms as one, for Roc's record builder: `{ a: …, b: … }.Form`. Both are read, and the
	## issues of each are kept.
	map2 : Form(x), Form(y), (x, y -> z) -> Form(z)
	map2 = |first, second, combine| {
		read_first = first.read
		read_second = second.read
		{
			read: |posted| {
				one = read_first(posted)
				two = read_second(posted)
				value =
					match (one.value, two.value) {
						(Ok(x), Ok(y)) => Ok(combine(x, y))
						_ => Err(Unread)
					}
				{ value, issues: one.issues.concat(two.issues) }
			},
			fields: first.fields.concat(second.fields),
			at: "",
		}
	}

	## A form of no fields that reads as `value`: a constant in a record builder.
	always : a -> Form(a)
	always = |value| { read: |_| { value: Ok(value), issues: [] }, fields: [], at: "" }

	## The field posted as `name`, read as `value` says: its first value, or `""` when there is
	## none (an empty text box sends `""`; an unticked box, nothing).
	field : Str, Value(a) -> Form(a)
	field = |name, value| {
		read_value = value.reader()
		{
			read: |posted| {
				got = read_value(first_of(posted, name))
				{ value: got.value, issues: got.codes.map(|code| Issues.at_field(name, code)) }
			},
			fields: [{ name, attributes: value.attributes(), schema: value.schema(), required: value.is_required(), many: Bool.False }],
			at: name,
		}
	}

	## A field that may be left empty: `Err(Missing)` when it is (nothing, or only white space),
	## and otherwise read as `value` says. `Form.optional("age", Value.int([Min(18)]))`.
	optional : Str, Value(a) -> Form(Try(a, [Missing]))
	optional = |name, value| {
		read_value = value.reader()
		{
			read: |posted| {
				raw = first_of(posted, name)
				if raw.trim().is_empty() {
					{ value: Ok(Err(Missing)), issues: [] }
				} else {
					got = read_value(raw)
					{ value: got.value.map_ok(|read| Ok(read)), issues: got.codes.map(|code| Issues.at_field(name, code)) }
				}
			},
			fields: [{ name, attributes: { ..value.attributes(), required: Bool.False }, schema: value.schema(), required: Bool.False, many: Bool.False }],
			at: name,
		}
	}

	## Every value posted as `name` (checkboxes that share a name, a `<select multiple>`, several
	## inputs), each read as `value` says; the empty ones left out. An item's issues are at
	## `name[i]` (`tags[2]`: the third posted), the list's own (`TooFew`, `TooMany`) at `name`.
	list : Str, Value(a), List(Form.ListCheck) -> Form(List(a))
	list = |name, value, checks| {
		read_value = value.reader()
		least = checks.fold(
			0,
			|found, rule| match rule {
				MinItems(n) => n
				_ => found
			},
		)
		{
			read: |posted| {
				raws = posted.keep_if(|each| each.name == name).map(|each| each.value)
				var $items = []
				var $issues = []
				var $readable = Bool.True
				var $index = 0.U64
				for raw in raws {
					if !raw.trim().is_empty() {
						got = read_value(raw)
						$issues = $issues.concat(got.codes.map(|code| Issues.at_field("${name}[${$index.to_str()}]", code)))
						match got.value {
							Ok(item) => {
								$items = $items.append(item)
							}
							Err(Unread) => {
								$readable = Bool.False
							}
						}
					}
					$index = $index + 1
				}
				count = $items.len()
				counted = checks.keep_oks(
					|rule|
						match rule {
							MinItems(min) => if (count < min) Ok(Issues.at_field(name, TooFew(min))) else Err(Fine)
							MaxItems(max) => if (count > max) Ok(Issues.at_field(name, TooMany(max))) else Err(Fine)
						},
				)
				{ value: if ($readable) Ok($items) else Err(Unread), issues: $issues.concat(counted) }
			},
			fields: [
				{
					name,
					attributes: { ..value.attributes(), required: Bool.False },
					schema: list_schema(value.schema(), checks),
					required: least > 0,
					many: Bool.True,
				},
			],
			at: name,
		}
	}

	## `Form.field(name, Value.text(checks))`: text.
	text : Str, List(Value.TextCheck) -> Form(Str)
	text = |name, checks| Form.field(name, Value.text(checks))

	## `Form.field(name, Value.int(checks))`: a whole number.
	int : Str, List(Value.IntCheck) -> Form(I64)
	int = |name, checks| Form.field(name, Value.int(checks))

	## `Form.field(name, Value.dec(checks))`: a decimal.
	dec : Str, List(Value.DecCheck) -> Form(Dec)
	dec = |name, checks| Form.field(name, Value.dec(checks))

	## `Form.field(name, Value.checkbox(checks))`: a box, ticked or not.
	checkbox : Str, List([Required]) -> Form(Bool)
	checkbox = |name, checks| Form.field(name, Value.checkbox(checks))

	## `Form.field(name, Value.choice(options))`: one of the options.
	choice : Str, List((Str, a)) -> Form(a)
	choice = |name, options| Form.field(name, Value.choice(options))

	## `Form.field(name, Value.date(checks))`: a day.
	date : Str, List(Value.DateCheck) -> Form(Date)
	date = |name, checks| Form.field(name, Value.date(checks))

	## A check of what was read, with its issue at the form's own field: a field's name, or `""`
	## for a whole form (an issue to show above it). It runs when every field could be read, even
	## if some are wrong, so it says what it has to say along with them.
	check : Form(a), (a -> Bool), Issues.Code -> Form(a)
	check = |form, ok, code| Form.check_at(form, form.at, ok, code)

	## A check across fields, its issue at `field`: a password typed twice, a day after another.
	##
	##     ({ password: …, confirm: … }.Form).check_at("confirm", |p| p.password == p.confirm, NotSame("password"))
	check_at : Form(a), Str, (a -> Bool), Issues.Code -> Form(a)
	check_at = |form, field_name, ok, code| {
		read_form = form.read
		{
			read: |posted| {
				got = read_form(posted)
				match got.value {
					Ok(read) => if (ok(read)) got else { ..got, issues: got.issues.append(Issues.at_field(field_name, code)) }
					Err(Unread) => got
				}
			},
			fields: form.fields,
			at: form.at,
		}
	}

	## What was read, made into another.
	map : Form(a), (a -> b) -> Form(b)
	map = |form, change| {
		read_form = form.read
		{
			read: |posted| {
				got = read_form(posted)
				{ value: got.value.map_ok(change), issues: got.issues }
			},
			fields: form.fields,
			at: form.at,
		}
	}

	## What was read, made into another, or an issue at the form's own field.
	try_map : Form(a), (a -> Try(b, Issues.Code)) -> Form(b)
	try_map = |form, change| {
		read_form = form.read
		at = form.at
		{
			read: |posted| {
				got = read_form(posted)
				match got.value {
					Ok(read) =>
						if got.issues.is_empty() {
							match change(read) {
								Ok(changed) => { value: Ok(changed), issues: [] }
								Err(code) => { value: Err(Unread), issues: [Issues.at_field(at, code)] }
							}
						} else {
							{ value: Err(Unread), issues: got.issues }
						}
					Err(Unread) => { value: Err(Unread), issues: got.issues }
				}
			},
			fields: form.fields,
			at,
		}
	}

	## Its issues, each with this message instead of its own (the code stays): for a field,
	## `Form.text("zip", [Matches("\\d{5}")]).message("Enter five digits")`.
	message : Form(a), Str -> Form(a)
	message = |form, said| {
		read_form = form.read
		{
			read: |posted| {
				got = read_form(posted)
				{ ..got, issues: got.issues.map(|issue| { ..issue, message: said }) }
			},
			fields: form.fields,
			at: form.at,
		}
	}

	## Reads what was posted: the record, or every issue, each at its field.
	parse : Form(a), Form.Posted -> Try(a, List(Issues.Issue))
	parse = |form, posted| {
		read_form = form.read
		got = read_form(posted)
		match got.value {
			Ok(read) => if (got.issues.is_empty()) Ok(read) else Err(got.issues)
			Err(Unread) => Err(got.issues)
		}
	}

	## Reads a form's body as a browser posts it (`name=Ada&plan=pro`,
	## `application/x-www-form-urlencoded`): `form.parse_body(Server.text_of(request))`.
	parse_body : Form(a), Str -> Try(a, List(Issues.Issue))
	parse_body = |form, body| Form.parse(form, Form.decode(body))

	## What is wrong with what was posted: none when it reads.
	issues : Form(a), Form.Posted -> List(Issues.Issue)
	issues = |form, posted|
		match Form.parse(form, posted) {
			Ok(_) => []
			Err(found) => found
		}

	## The names of its fields, in order.
	names : Form(a) -> List(Str)
	names = |form| form.fields.map(|each| each.name)

	## The fields that are `Secret` (passwords): what a page that comes back after a post doesn't
	## fill in again. The platform doesn't either: it never writes a `value` into an
	## `<input type="password">`, and leaves such a field out of the page's note of the flash.
	secrets : Form(a) -> List(Str)
	secrets = |form| form.fields.keep_if(|each| each.attributes.type == "password").map(|each| each.name)

	## Whether the field `name` takes several values (`Form.list`).
	is_list : Form(a), Str -> Bool
	is_list = |form, name| form.fields.any(|each| each.name == name and each.many)

	## What a browser's constraint attributes say of the field `name` (`Value.Attributes`), for its
	## input: `required?={attributes.required} minlength??={attributes.minlength}`. A browser then
	## checks it as this does, without the runtime too.
	attributes : Form(a), Str -> Value.Attributes
	attributes = |form, name|
		match form.fields.find_first(|each| each.name == name) {
			Ok(found) => found.attributes
			Err(_) => Value.text([]).attributes()
		}

	## Its JSON Schema: an object with a property for each field (its type and its checks:
	## `minLength`, `pattern`, `minimum`, `enum`…), and the ones that must be given `required`.
	## For an OpenAPI document of the endpoint the form posts to.
	json_schema : Form(a) -> Str
	json_schema = |form| {
		unique = form.fields.fold([], |kept, each| if (kept.any(|other| other.name == each.name)) kept else kept.append(each))
		properties = Str.join_with(unique.map(|each| "${Json.to_str(each.name)}:${each.schema}"), ",")
		required = unique.keep_if(|each| each.required).map(|each| each.name)
		"{\"type\":\"object\",\"properties\":{${properties}},\"required\":${Json.to_str(required)}}"
	}

	## A form's body (`name=Ada+L&tag=a&tag=b`) as its fields, decoded (`+` is a space, `%XX` a
	## byte), in order.
	decode : Str -> Form.Posted
	decode = |body|
		body.split_on("&").keep_if(|pair| !pair.is_empty()).map(
			|pair|
				match pair.split_first("=") {
					Ok({ before, after }) => { name: form_decoded(before), value: form_decoded(after) }
					Err(_) => { name: form_decoded(pair), value: "" }
				},
		)
}

## What a form knows of each field: its name, a browser's attributes for it, its JSON Schema,
## whether it must be given, and whether it takes several values.
Field : { name : Str, attributes : Value.Attributes, schema : Str, required : Bool, many : Bool }

## What reading a form comes to: its value, unless a field couldn't be read, and its issues.
Parsed(a) : { value : Try(a, [Unread]), issues : List(Issues.Issue) }

## The first value posted as `name`, or `""`.
first_of : List({ name : Str, value : Str }), Str -> Str
first_of = |posted, name|
	match posted.find_first(|each| each.name == name) {
		Ok(found) => found.value
		Err(_) => ""
	}

list_schema : Str, List([MinItems(U64), MaxItems(U64)]) -> Str
list_schema = |item, checks| {
	counts = checks.map(
		|rule|
			match rule {
				MinItems(n) => ",\"minItems\":${n.to_str()}"
				MaxItems(n) => ",\"maxItems\":${n.to_str()}"
			},
	)
	"{\"type\":\"array\",\"items\":${item}${Str.join_with(counts, "")}}"
}

## `+` as a space, `%XX` as its byte; a `%` without two hex digits as it is.
form_decoded : Str -> Str
form_decoded = |text| {
	bytes = text.to_utf8()
	var $out = List.with_capacity(bytes.len())
	var $i = 0
	while $i < bytes.len() {
		byte = bytes.get($i) ?? 0
		if byte == '+' {
			$out = $out.append(' ')
			$i = $i + 1
		} else if byte == '%' {
			match (hex_digit(bytes.get($i + 1) ?? 0), hex_digit(bytes.get($i + 2) ?? 0)) {
				(Ok(high), Ok(low)) => {
					$out = $out.append(high * 16 + low)
					$i = $i + 3
				}
				_ => {
					$out = $out.append(byte)
					$i = $i + 1
				}
			}
		} else {
			$out = $out.append(byte)
			$i = $i + 1
		}
	}
	Str.from_utf8_lossy($out)
}

hex_digit : U8 -> Try(U8, [NotHex])
hex_digit = |byte|
	if byte >= '0' and byte <= '9' {
		Ok(byte - '0')
	} else if byte >= 'a' and byte <= 'f' {
		Ok(byte - 'a' + 10)
	} else if byte >= 'A' and byte <= 'F' {
		Ok(byte - 'A' + 10)
	} else {
		Err(NotHex)
	}

## What a test posts.
posted : List((Str, Str)) -> List({ name : Str, value : Str })
posted = |pairs| pairs.map(|(name, value)| { name, value })

codes : Try(a, List(Issues.Issue)) -> List((Str, Issues.Code))
codes = |parsed|
	match parsed {
		Ok(_) => []
		Err(found) => found.map(|issue| (issue.field, issue.code))
	}

signup : Form({ name : Str, email : Str, age : I64, plan : [Free, Pro], terms : Bool })
signup = {
	name: Form.text("name", [Trim, Required, MaxLength(20)]),
	email: Form.text("email", [Trim, Lowercase, Required, Email]),
	age: Form.int("age", [Min(18), Max(130)]),
	plan: Form.choice("plan", [("free", Free), ("pro", Pro)]),
	terms: Form.checkbox("terms", [Required]),
}.Form

good : List({ name : Str, value : Str })
good = posted([("name", " Ada "), ("email", "Ada@Example.com"), ("age", "36"), ("plan", "pro"), ("terms", "on")])

expect signup.parse(good) == Ok({ name: "Ada", email: "ada@example.com", age: 36, plan: Pro, terms: Bool.True })
expect codes(signup.parse(posted([("name", ""), ("email", "ada@"), ("age", "12"), ("plan", "gold")]))) == [("name", Required), ("email", NotEmail), ("age", TooSmall(18.0)), ("plan", NotOneOf(["free", "pro"])), ("terms", Unchecked)]
expect codes(signup.parse(good.drop_last(1))) == [("terms", Unchecked)]
expect signup.issues(good) == []
expect signup.issues(posted([("age", "x")])).map(|issue| issue.message).first() == Ok("Fill this in")
expect signup.names() == ["name", "email", "age", "plan", "terms"]
expect signup.parse_body("name=Ada+L&email=ada%40example.com&age=36&plan=free&terms=on") == Ok({ name: "Ada L", email: "ada@example.com", age: 36, plan: Free, terms: Bool.True })

# A form inside a form: its fields' names are as posted, its record a record's field.
Passwords : { password : Str, confirm : Str }

passwords : Form(Passwords)
passwords = ({ password: Form.text("password", [Required, MinLength(8)]), confirm: Form.text("confirm", []) }.Form).check_at("confirm", |p| p.password == p.confirm, NotSame("password"))

account : Form({ email : Str, passwords : Passwords })
account = { email: Form.text("email", [Required, Email]), passwords }.Form

expect account.parse(posted([("email", "a@b.c"), ("password", "longenough"), ("confirm", "longenough")])) == Ok({ email: "a@b.c", passwords: { password: "longenough", confirm: "longenough" } })
expect codes(account.parse(posted([("email", "a@b.c"), ("password", "longenough"), ("confirm", "longenuff")]))) == [("confirm", NotSame("password"))]
# Too short and not the same: said together, the record being readable.
expect codes(account.parse(posted([("email", ""), ("password", "short"), ("confirm", "shirt")]))) == [("email", Required), ("password", TooShort(8)), ("confirm", NotSame("password"))]
expect Form.issues(passwords, posted([("password", "longenough"), ("confirm", "x")])).map(|issue| issue.message) == ["These don't match"]

# Days, one after another.
trip : Form({ start : Date, end : Date })
trip = ({ start: Form.date("start", []), end: Form.date("end", []) }.Form).check_at("end", |t| t.end.is_after(t.start), Custom("end_after_start", "End after the start"))

expect codes(trip.parse(posted([("start", "2026-11-21"), ("end", "2026-11-20")]))) == [("end", Custom("end_after_start", "End after the start"))]
expect trip.parse(posted([("start", "2026-11-21"), ("end", "2026-11-28")])).is_ok()
expect codes(trip.parse(posted([("start", "2026-11-21"), ("end", "")]))) == [("end", Required)]

# Optional fields and lists.
profile : Form({ age : Try(I64, [Missing]), site : Str, topics : List([Roc, Zig, Rust]), tags : List(Str) })
profile = {
	age: Form.optional("age", Value.int([Min(18)])),
	site: Form.text("site", [Trim, Url]),
	topics: Form.list("topics", Value.choice([("roc", Roc), ("zig", Zig), ("rust", Rust)]), [MinItems(1), MaxItems(2)]),
	tags: Form.list("tags", Value.text([Trim, MaxLength(5)]), []),
}.Form

expect profile.parse(posted([("age", " "), ("topics", "roc")])) == Ok({ age: Err(Missing), site: "", topics: [Roc], tags: [] })
expect profile.parse(posted([("age", "40"), ("site", "https://roc-lang.org"), ("topics", "roc"), ("topics", "zig"), ("tags", "a"), ("tags", ""), ("tags", "b")])) == Ok({ age: Ok(40), site: "https://roc-lang.org", topics: [Roc, Zig], tags: ["a", "b"] })
expect codes(profile.parse(posted([("age", "9"), ("site", "roc-lang.org")]))) == [("age", TooSmall(18.0)), ("site", NotUrl), ("topics", TooFew(1))]
expect codes(profile.parse(posted([("topics", "roc"), ("topics", "go"), ("topics", "zig"), ("topics", "rust")]))) == [("topics[1]", NotOneOf(["roc", "zig", "rust"])), ("topics", TooMany(2))]
expect codes(profile.parse(posted([("topics", "roc"), ("tags", ""), ("tags", "toolong")]))) == [("tags[1]", TooLong(5))]

# Checks, changes, messages.
username : Form(Str)
username = Form.text("username", [Trim, Required]).check(|name| name != "admin", Custom("taken", "That name is taken"))

expect codes(username.parse(posted([("username", "admin")]))) == [("username", Custom("taken", "That name is taken"))]
expect codes(username.parse(posted([]))) == [("username", Required)]
expect Form.text("zip", [Matches("\\d{5}")]).message("Enter five digits").issues(posted([("zip", "123")])) == [{ field: "zip", code: NoMatch("\\d{5}"), message: "Enter five digits" }]
expect Form.int("n", []).map(|n| n + 1).parse(posted([("n", "1")])) == Ok(2)
expect codes(Form.int("n", []).try_map(|n| if (n % 2 == 0) Ok(n // 2) else Err(Custom("even", "Enter an even number"))).parse(posted([("n", "3")]))) == [("n", Custom("even", "Enter an even number"))]
expect codes(({ a: Form.always(1), b: Form.always(2) }.Form).check(|r| r.a > r.b, Custom("order", "a after b")).parse([])) == [("", Custom("order", "a after b"))]

# What a browser and an OpenAPI document are told.
expect signup.attributes("email") == { type: "email", required: Bool.True, minlength: "", maxlength: "", pattern: "", min: "", max: "", step: "" }
expect signup.attributes("age").min == "18"
expect profile.attributes("topics").required == Bool.False
expect profile.attributes("age").required == Bool.False
expect account.secrets() == []
expect Form.text("pin", [Secret]).secrets() == ["pin"]
expect profile.is_list("topics")
expect !profile.is_list("age")
expect signup.json_schema() == "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":20},\"email\":{\"type\":\"string\",\"minLength\":1,\"format\":\"email\"},\"age\":{\"type\":\"integer\",\"minimum\":18,\"maximum\":130},\"plan\":{\"type\":\"string\",\"enum\":[\"free\",\"pro\"]},\"terms\":{\"type\":\"boolean\"}},\"required\":[\"name\",\"email\",\"age\",\"plan\",\"terms\"]}"
expect profile.json_schema() == "{\"type\":\"object\",\"properties\":{\"age\":{\"type\":\"integer\",\"minimum\":18},\"site\":{\"type\":\"string\",\"format\":\"uri\"},\"topics\":{\"type\":\"array\",\"items\":{\"type\":\"string\",\"enum\":[\"roc\",\"zig\",\"rust\"]},\"minItems\":1,\"maxItems\":2},\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\",\"maxLength\":5}}},\"required\":[\"topics\"]}"

# A form's body.
expect Form.decode("name=Ada+L&plan=a%26b&empty=&bare&x=%E2%9C%93") == posted([("name", "Ada L"), ("plan", "a&b"), ("empty", ""), ("bare", ""), ("x", "✓")])
expect Form.decode("") == []
expect Form.decode("pct=100%25&odd=%zz") == posted([("pct", "100%"), ("odd", "%zz")])
