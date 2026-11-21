import Admin
import Catalog
import Form
import Sql
import Widget

## What a table's list of rows shows, as its URL's query says: `q` (a search); a filter on any
## column the list shows: `f.<column>=<value>` (equal to it), `has.<column>=<text>` (containing it,
## in any case), `from.<column>=<value>` and `to.<column>=<value>` (at least, at most), and
## `is.<column>=null` or `is.<column>=set` (empty or not); `sort=<column>` or `sort=-<column>`
## (descending); and `page`. A column the query names is one only if the list shows it (the search's,
## if the list searches it): anything else in a query is ignored. So is a value that isn't one of its
## column's type (a number's `from` that isn't a number), which the state keeps, to say so.
Listing := [].{

	## A filter: a column, and what it must be: equal to a value, null, not null, containing a
	## text (in any case), at least a value, or at most one.
	Filter : { column : Str, is : [Equal(Str), Null, Set, Contains(Str), AtLeast(Str), AtMost(Str)] }

	## A filter's value that isn't one of its column's type, so it is ignored: the column, the
	## query's field (`from.price`), the value, and what it should have been (`"a number"`).
	Invalid : { column : Str, field : Str, value : Str, expected : Str }

	## A list's state.
	State : { search : Str, filters : List(Filter), invalid : List(Invalid), sort : List({ column : Str, descending : Bool }), page : U64 }

	## How a column of the list is filtered, from its type:
	##
	## - `Contains`: a text it contains, in any case (text, varchar, uuid, json and any other type);
	## - `Range(scale)`: from a value, to a value, or both, inclusive (`Integer` and `Decimal`
	##   numbers, a `Day`, a `Moment`, a `Time` of day);
	## - `YesNo`: a boolean's;
	## - `OneOf(values)`: an enum's labels, a check's values, or the app's `Choice` widget's;
	## - `Exact`: a value it is (a foreign key).
	##
	## A column that may be null can be asked to be empty (null) or not, too.
	Kind : [Contains, Range([Integer, Decimal, Day, Moment, Time]), YesNo, OneOf(List(Str)), Exact]

	## The state a query asks for, of what the table's options allow.
	read : Admin.Shown, List(Form.Field) -> State
	read = |shown, query| {
		search = if (Admin.searchable(shown).is_empty()) "" else Form.get(query, "q").trim()
		var $filters = []
		var $invalid = []
		for column in Admin.listed(shown) {
			asked = column_filters(shown, column, query)
			$filters = $filters.concat(asked.filters)
			$invalid = $invalid.concat(asked.invalid)
		}
		sortable = Admin.listed(shown).map(|column| column.name)
		sorted = Form.get(query, "sort")
		sort =
			if sortable.contains(sorted.drop_prefix("-")) {
				[{ column: sorted.drop_prefix("-"), descending: sorted.starts_with("-") }]
			} else {
				[]
			}
		{ search, filters: $filters, invalid: $invalid, sort, page: U64.from_str(Form.get(query, "page")) ?? 1 }
	}

	## The state as a query's params, the table's first; the first page isn't said, and neither is
	## a value that was ignored.
	params : Str, State -> List((Str, Str))
	params = |table, state| {
		filters = state.filters.map(
			|each|
				match each.is {
					Equal(value) => ("f.${each.column}", value)
					Null => ("is.${each.column}", "null")
					Set => ("is.${each.column}", "set")
					Contains(text) => ("has.${each.column}", text)
					AtLeast(value) => ("from.${each.column}", value)
					AtMost(value) => ("to.${each.column}", value)
				},
		)
		sort = state.sort.map(|each| ("sort", "${if (each.descending) "-" else ""}${each.column}"))
		[("table", table), ("q", state.search)].concat(filters).concat(sort).append(("page", if (state.page <= 1) "" else state.page.to_str()))
	}

	## What the rows must be, for the statements. A moment of a `timestamptz` is in UTC, as the
	## admin shows it.
	conditions : Admin.Shown, State -> List(Sql.Condition)
	conditions = |shown, state| {
		search = if (state.search.is_empty()) [] else [Search(Admin.searchable(shown), state.search)]
		listed = Admin.listed(shown)
		filters = state.filters.keep_oks(
			|each|
				match listed.find_first(|column| column.name == each.column) {
					Ok(column) => {
						utc = |value| if (column.base == "timestamptz") "${value}+00" else value
						match each.is {
							Equal(value) => Ok(Equals(column, utc(value)))
							Null => Ok(IsNull(column))
							Set => Ok(NotNull(column))
							Contains(text) => Ok(Contains(column, text))
							AtLeast(value) => Ok(AtLeast(column, utc(value)))
							AtMost(value) => Ok(AtMost(column, utc(value)))
						}
					}
					Err(_) => Err(NotFound)
				},
		)
		search.concat(filters)
	}

	## How a column is filtered: from its type (a generated column's too), or a select of the
	## values of the app's `Choice` widget for it.
	kind : Admin.Shown, Catalog.Column -> Kind
	kind = |shown, column| {
		typed = Widget.of({ ..column, generated: Bool.False })
		chosen =
			match Admin.widget(shown, column) {
				Choice(values) => Choice(values)
				_ => typed
			}
		match chosen {
			Reference(_) => Exact
			Choice(values) => OneOf(values)
			Checkbox | MaybeBool => YesNo
			Integer => Range(Integer)
			Decimal => Range(Decimal)
			Day => Range(Day)
			Moment | MomentUtc => Range(Moment)
			TimeOfDay => Range(Time)
			_ => Contains
		}
	}

	## A filter's value, if it is one of its column's type, as Postgres will read it; else what it
	## should be. A whole number (in the type's range) for an integer, a number (`-12.5`) for a
	## decimal, `2026-11-21` for a date, `2026-11-21T14:05` (seconds if wanted) for a moment,
	## `14:05` for a time, `true` or `false` for a boolean, a UUID's 36 characters, one of an enum's
	## labels; any text for any other type.
	check : Catalog.Column, Str -> Try(Str, [Expected(Str)])
	check = |column, value|
		if !column.labels.is_empty() {
			if (column.labels.contains(value)) Ok(value) else Err(Expected("one of its values"))
		} else {
			match column.base {
				"int2" => whole(value, -32768, 32767)
				"int4" => whole(value, -2147483648, 2147483647)
				"int8" => whole(value, -9223372036854775807, 9223372036854775807)
				"oid" => whole(value, 0, 4294967295)
				"numeric" | "float4" | "float8" => if (decimal(value)) Ok(value) else Err(Expected("a number"))
				"date" => if (day(value)) Ok(value) else Err(Expected("a date: YYYY-MM-DD"))
				"timestamp" | "timestamptz" => moment(value)
				"time" => if (clock(value)) Ok(value) else Err(Expected("a time: HH:MM"))
				"bool" => if (value == "true" or value == "false") Ok(value) else Err(Expected("true or false"))
				"uuid" => if (uuid(value)) Ok(value) else Err(Expected("a UUID"))
				_ => Ok(value)
			}
		}

	## The key of the row a query or a form names (`k.id=7`; `k.<column>` for each of the key's
	## columns), if it names each, and the table has a key.
	key : Admin.Shown, List(Form.Field) -> Try(List((Catalog.Column, Str)), [NoKey])
	key = |shown, given| {
		columns = Admin.key(shown)
		if columns.is_empty() or !columns.all(|column| Form.asks(given, "k.${column.name}")) {
			Err(NoKey)
		} else {
			Ok(columns.map(|column| (column, Form.get(given, "k.${column.name}"))))
		}
	}

	## The rows' order: the column sorted by, else the table's ordering; then the key's columns, so
	## the rows of a page are always the same.
	order : Admin.Shown, State -> List(Sql.Order)
	order = |shown, state| {
		asked = state.sort.keep_oks(
			|each|
				match Catalog.column(shown.table, each.column) {
					Ok(column) => Ok({ column, descending: each.descending })
					Err(NotFound) => Err(NotFound)
				},
		)
		first = if (asked.is_empty()) Admin.ordering(shown) else asked
		ties = Admin.key(shown).keep_if(|column| !first.any(|each| each.column.name == column.name)).map(|column| { column, descending: Bool.False })
		first.concat(ties)
	}

	## The state sorted by `column`: ascending, or descending if it is sorted ascending by it now;
	## back on the first page.
	sorted_by : State, Str -> State
	sorted_by = |state, column| {
		descending =
			match state.sort.first() {
				Ok(now) => now.column == column and !now.descending
				Err(_) => Bool.False
			}
		{ ..state, sort: [{ column, descending }], page: 1 }
	}
}

## A column's filters, as the query asks: `f.` (equal) first, then `is.` (`null`, `set`, or a value
## it equals), then, unless one of those says it all, `has.` (a text column's) or `from.` and `to.`
## (a range's). Empty fields ask nothing; a value that isn't of the column's type is invalid.
column_filters : Admin.Shown, Catalog.Column, List(Form.Field) -> { filters : List(Listing.Filter), invalid : List(Listing.Invalid) }
column_filters = |shown, column, query| {
	name = column.name
	given = |prefix| Form.get(query, "${prefix}${name}").trim()
	checked = |prefix| {
		value = given(prefix)
		if value.is_empty() {
			Err(Unasked)
		} else {
			match Listing.check(column, value) {
				Ok(good) => Ok(good)
				Err(Expected(what)) => Err(Bad({ column: name, field: "${prefix}${name}", value, expected: what }))
			}
		}
	}
	equal = checked("f.")
	nulls =
		match given("is.") {
			"" => Err(Unasked)
			"null" => Ok(Null)
			"set" => Ok(Set)
			_ =>
				match checked("is.") {
					Ok(value) => Ok(Equal(value))
					Err(why) => Err(why)
				}
		}
	kind = Listing.kind(shown, column)
	contains =
		match kind {
			Contains => if (given("has.").is_empty()) Err(Unasked) else Ok(Contains(given("has.")))
			_ => Err(Unasked)
		}
	(from, to) =
		match kind {
			Range(_) => (checked("from."), checked("to."))
			_ => (Err(Unasked), Err(Unasked))
		}
	bad = |asked|
		match asked {
			Err(Bad(invalid)) => [invalid]
			_ => []
		}
	invalid = bad(equal).concat(bad(nulls)).concat(bad(from)).concat(bad(to))
	filters =
		match (equal, nulls) {
			(Ok(value), _) => [Equal(value)]
			(_, Ok(Equal(value))) => [Equal(value)]
			(_, Ok(Null)) => [Null]
			_ => {
				set = if (nulls == Ok(Set)) [Set] else []
				texts =
					match contains {
						Ok(wanted) => [wanted]
						Err(_) => []
					}
				least =
					match from {
						Ok(value) => [AtLeast(value)]
						Err(_) => []
					}
				most =
					match to {
						Ok(value) => [AtMost(value)]
						Err(_) => []
					}
				set.concat(texts).concat(least).concat(most)
			}
		}
	{ filters: filters.map(|wanted| { column: name, is: wanted }), invalid }
}

## A whole number from `low` to `high`: digits, perhaps after a `-`.
whole : Str, I64, I64 -> Try(Str, [Expected(Str)])
whole = |text, low, high| {
	bytes = text.to_utf8()
	numeral = if (bytes.first() == Ok('-')) bytes.drop_first(1) else bytes
	if numeral.is_empty() or numeral.len() > 19 or !numeral.all(is_digit) {
		Err(Expected("a whole number"))
	} else {
		match I64.from_str(text) {
			Ok(n) if n >= low and n <= high => Ok(text)
			_ => Err(Expected("a whole number from ${low.to_str()} to ${high.to_str()}"))
		}
	}
}

## A number as Postgres reads one: digits, perhaps a `-` before them and a `.` among them, at most
## 30 characters (so a `real` holds it too).
decimal : Str -> Bool
decimal = |text| {
	bytes = text.to_utf8()
	numeral = if (bytes.first() == Ok('-')) bytes.drop_first(1) else bytes
	digits = numeral.keep_if(is_digit).len()
	dots = numeral.keep_if(|byte| byte == '.').len()
	bytes.len() <= 30 and digits > 0 and dots <= 1 and digits + dots == numeral.len()
}

## `2026-11-21`: a day that is (the 30th of February isn't), from year 1.
day : Str -> Bool
day = |text| {
	bytes = text.to_utf8()
	if bytes.len() != 10 or bytes.get(4) != Ok('-') or bytes.get(7) != Ok('-') {
		Bool.False
	} else {
		match (number_at(bytes, 0, 4), number_at(bytes, 5, 2), number_at(bytes, 8, 2)) {
			(Ok(year), Ok(month), Ok(date)) => year >= 1 and month >= 1 and month <= 12 and date >= 1 and date <= days_in(year, month)
			_ => Bool.False
		}
	}
}

## How many days a month of a year has.
days_in : U64, U64 -> U64
days_in = |year, month|
	match month {
		2 => if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 29 else 28
		4 | 6 | 9 | 11 => 30
		_ => 31
	}

## `14:05` or `14:05:30`.
clock : Str -> Bool
clock = |text| {
	bytes = text.to_utf8()
	minutes = bytes.len() == 5 or (bytes.len() == 8 and bytes.get(5) == Ok(':') and (number_at(bytes, 6, 2) ?? 60) <= 59)
	minutes and bytes.get(2) == Ok(':') and (number_at(bytes, 0, 2) ?? 24) <= 23 and (number_at(bytes, 3, 2) ?? 60) <= 59
}

## A day and a time of it, `2026-11-21T14:05` (a space for the `T` will do), as Postgres reads it.
moment : Str -> Try(Str, [Expected(Str)])
moment = |text| {
	parts =
		match text.split_first("T") {
			Ok(found) => Ok(found)
			Err(_) => text.split_first(" ")
		}
	match parts {
		Ok({ before, after }) if day(before) and clock(after) => Ok("${before}T${after}")
		_ => Err(Expected("a date and time: YYYY-MM-DDTHH:MM"))
	}
}

## `0e5f6a2c-…`: 36 characters, hex digits and four dashes where a UUID has them.
uuid : Str -> Bool
uuid = |text| {
	bytes = text.to_utf8()
	dashes = [8, 13, 18, 23]
	bytes.len() == 36 and bytes.map_with_index(|byte, at| if (dashes.contains(at)) byte == '-' else is_hex(byte)).all(|fits| fits)
}

## The number `length` digits at `start` say.
number_at : List(U8), U64, U64 -> Try(U64, [NotDigits])
number_at = |bytes, start, length| {
	digits = bytes.drop_first(start).take_first(length)
	if digits.len() == length and digits.all(is_digit) {
		Ok(digits.fold(0, |total, byte| total * 10 + (byte - '0').to_u64()))
	} else {
		Err(NotDigits)
	}
}

is_digit : U8 -> Bool
is_digit = |byte| byte >= '0' and byte <= '9'

is_hex : U8 -> Bool
is_hex = |byte| is_digit(byte) or (byte >= 'a' and byte <= 'f') or (byte >= 'A' and byte <= 'F')

column_of : Str, Str -> Catalog.Column
column_of = |name, base| { name, type: base, base, category: "", nullable: Bool.True, defaulted: Bool.False, generated: Bool.False, comment: "", default: "", labels: [], choices: [], refers: Nothing }

books : Catalog.Table
books = {
	name: "books",
	comment: "",
	estimate: 0,
	columns: [
		{ ..column_of("id", "int8"), nullable: Bool.False },
		{ ..column_of("title", "text"), nullable: Bool.False },
		{ ..column_of("state", "text"), choices: ["draft", "published"] },
		column_of("secret", "text"),
		column_of("price", "numeric"),
		column_of("pages", "int2"),
		column_of("published_at", "timestamptz"),
		column_of("born", "date"),
		column_of("opens", "time"),
		column_of("in_print", "bool"),
		{ ..column_of("mood", "mood"), labels: ["happy", "sad"] },
		{ ..column_of("author_id", "int8"), refers: To({ table: "authors", column: "id" }) },
		column_of("isbn", "uuid"),
		column_of("note", "text"),
	],
	key: ["id"],
}

shown_books : Admin.Shown
shown_books = Admin.pair(books, { name: "books", list: ["id", "title", "state", "price", "pages", "published_at", "born", "opens", "in_print", "mood", "author_id", "isbn"], search: ["title", "secret"], hidden: ["secret"] })

no_filters : Listing.State
no_filters = { search: "", filters: [], invalid: [], sort: [], page: 1 }

column_named : Str -> Catalog.Column
column_named = |name| Catalog.column(books, name) ?? column_of(name, "text")

# The query's search, sort and page; a filter on a hidden column, or one the list doesn't show, is ignored.
expect {
	state = Listing.read(shown_books, Form.fields("table=books&q=+dune+&f.state=draft&f.secret=x&has.note=x&is.title=null&sort=-title&page=3"))
	state == { search: "dune", filters: [{ column: "title", is: Null }, { column: "state", is: Equal("draft") }], invalid: [], sort: [{ column: "title", descending: Bool.True }], page: 3 }
}
expect Listing.read(shown_books, Form.fields("is.state=null&sort=secret&page=x")) == { ..no_filters, filters: [{ column: "state", is: Null }] }
expect Listing.read(Admin.pair(books, { name: "books" }), Form.fields("q=x")).search == ""
# Equal wins: `f.` over `is.`, and either over a column's other filters.
expect Listing.read(shown_books, Form.fields("f.state=a&is.state=set")).filters == [{ column: "state", is: Equal("a") }]
expect Listing.read(shown_books, Form.fields("is.mood=sad&is.state=draft")).filters == [{ column: "state", is: Equal("draft") }, { column: "mood", is: Equal("sad") }]
expect Listing.read(shown_books, Form.fields("f.price=3&from.price=1&to.price=9")).filters == [{ column: "price", is: Equal("3") }]
# Null says it all; not null goes with the others.
expect Listing.read(shown_books, Form.fields("is.price=null&from.price=1")).filters == [{ column: "price", is: Null }]
expect Listing.read(shown_books, Form.fields("is.price=set&from.price=1")).filters == [{ column: "price", is: Set }, { column: "price", is: AtLeast("1") }]
# Contains: a text's, and only a text's; trimmed; an empty field asks nothing.
expect Listing.read(shown_books, Form.fields("has.title=+Du_ne%25+&has.price=3&has.isbn=0e5f&from.title=a&f.pages=&has.mood=")).filters == [{ column: "title", is: Contains("Du_ne%") }, { column: "isbn", is: Contains("0e5f") }]
# Ranges: numbers, a date, a moment (a space for its T), a time; either end.
expect {
	state = Listing.read(shown_books, Form.fields("from.price=-1.5&to.price=20&from.pages=100&to.born=2026-02-28&from.published_at=2026-11-01+09%3A30&to.published_at=2026-11-30T23%3A59%3A59&from.opens=08%3A00"))
	state.filters
		== [
			{ column: "price", is: AtLeast("-1.5") },
			{ column: "price", is: AtMost("20") },
			{ column: "pages", is: AtLeast("100") },
			{ column: "published_at", is: AtLeast("2026-11-01T09:30") },
			{ column: "published_at", is: AtMost("2026-11-30T23:59:59") },
			{ column: "born", is: AtMost("2026-02-28") },
			{ column: "opens", is: AtLeast("08:00") },
		]
		and state.invalid == []
}
# A boolean's, an enum's, a check's and a foreign key's values: equal.
expect Listing.read(shown_books, Form.fields("f.in_print=false&f.mood=happy&f.state=published&f.author_id=2&f.isbn=0E5F6A2C-1B2C-4D3E-8F90-A1B2C3D4E5F6")).filters == [{ column: "state", is: Equal("published") }, { column: "in_print", is: Equal("false") }, { column: "mood", is: Equal("happy") }, { column: "author_id", is: Equal("2") }, { column: "isbn", is: Equal("0E5F6A2C-1B2C-4D3E-8F90-A1B2C3D4E5F6") }]
# A value that isn't its column's: ignored, and said.
expect {
	state = Listing.read(shown_books, Form.fields("from.price=lots&to.price=1e5&from.pages=40000&to.pages=1.5&from.born=2026-02-30&to.born=2026-1-1&from.published_at=2026-11-01&to.published_at=2026-11-01T24%3A00&from.opens=9%3A00&f.in_print=yes&f.mood=angry&f.author_id=abc&f.isbn=nope&is.id=x"))
	state.filters == []
		and state.invalid.map(|each| (each.field, each.expected))
			== [
				("is.id", "a whole number"),
				("from.price", "a number"),
				("to.price", "a number"),
				("from.pages", "a whole number from -32768 to 32767"),
				("to.pages", "a whole number"),
				("from.published_at", "a date and time: YYYY-MM-DDTHH:MM"),
				("to.published_at", "a date and time: YYYY-MM-DDTHH:MM"),
				("from.born", "a date: YYYY-MM-DD"),
				("to.born", "a date: YYYY-MM-DD"),
				("from.opens", "a time: HH:MM"),
				("f.in_print", "true or false"),
				("f.mood", "one of its values"),
				("f.author_id", "a whole number"),
				("f.isbn", "a UUID"),
			]
		and state.invalid.first() == Ok({ column: "id", field: "is.id", value: "x", expected: "a whole number" })
}
# One end invalid, the other kept.
expect {
	state = Listing.read(shown_books, Form.fields("from.price=x&to.price=9"))
	state.filters == [{ column: "price", is: AtMost("9") }] and state.invalid.map(|each| each.field) == ["from.price"]
}
expect Listing.check(column_named("born"), "2024-02-29") == Ok("2024-02-29") and Listing.check(column_named("born"), "2100-02-29") != Ok("2100-02-29") and Listing.check(column_named("born"), "0000-01-01") != Ok("0000-01-01")
expect Listing.check(column_named("price"), ".5") == Ok(".5") and Listing.check(column_named("price"), "-") != Ok("-") and Listing.check(column_named("price"), "1.2.3") != Ok("1.2.3") and Listing.check(column_named("price"), "1234567890123456789012345678901") != Ok("1234567890123456789012345678901")
expect Listing.check(column_named("id"), "-9223372036854775807") == Ok("-9223372036854775807") and Listing.check(column_named("id"), "99999999999999999999") != Ok("99999999999999999999")
expect Listing.check(column_named("title"), "anything at all") == Ok("anything at all")
# Each column's kind, from its type.
expect {
	kinds = Admin.listed(shown_books).map(|column| Listing.kind(shown_books, column))
	kinds == [Range(Integer), Contains, OneOf(["draft", "published"]), Range(Decimal), Range(Integer), Range(Moment), Range(Day), Range(Time), YesNo, OneOf(["happy", "sad"]), Exact, Contains]
}
expect Listing.kind(Admin.pair(books, { name: "books", widgets: [("title", Choice(["a", "b"])), ("price", Text)] }), column_named("title")) == OneOf(["a", "b"])
expect Listing.kind(Admin.pair(books, { name: "books", widgets: [("price", Text)] }), column_named("price")) == Range(Decimal)
expect Listing.kind(shown_books, { ..column_of("length", "int4"), generated: Bool.True }) == Range(Integer)
expect Listing.kind(shown_books, column_of("details", "jsonb")) == Contains
# Back to a query: each kind's field; ignored values aren't kept.
expect {
	state = {
		search: "a b",
		filters: [{ column: "state", is: Equal("x") }, { column: "note", is: Set }, { column: "mood", is: Null }, { column: "title", is: Contains("50%") }, { column: "price", is: AtLeast("1") }, { column: "price", is: AtMost("9.5") }],
		invalid: [{ column: "pages", field: "from.pages", value: "x", expected: "a whole number" }],
		sort: [{ column: "title", descending: Bool.False }],
		page: 2,
	}
	Form.link("/db", Listing.params("books", state)) == "/db?table=books&q=a%20b&f.state=x&is.note=set&is.mood=null&has.title=50%25&from.price=1&to.price=9.5&sort=title&page=2"
}
expect Form.link("/db", Listing.params("books", no_filters)) == "/db?table=books"
# And to the statements' conditions: a timestamptz's moments in UTC.
expect {
	state = Listing.read(shown_books, Form.fields("q=dune&f.state=draft&has.title=x&from.price=1&to.price=2&from.published_at=2026-11-01T09%3A30&f.author_id=3&is.isbn=set&is.mood=null"))
	Listing.conditions(shown_books, state)
		== [
			Search([column_named("title")], "dune"),
			Contains(column_named("title"), "x"),
			Equals(column_named("state"), "draft"),
			AtLeast(column_named("price"), "1"),
			AtMost(column_named("price"), "2"),
			AtLeast(column_named("published_at"), "2026-11-01T09:30+00"),
			IsNull(column_named("mood")),
			Equals(column_named("author_id"), "3"),
			NotNull(column_named("isbn")),
		]
}
# A state made by hand names a column the list doesn't show: no condition.
expect Listing.conditions(shown_books, { ..no_filters, filters: [{ column: "secret", is: Equal("x") }, { column: "note", is: Null }] }) == []
expect Listing.order(shown_books, no_filters) == [{ column: column_named("id"), descending: Bool.True }]
expect Listing.order(shown_books, { ..no_filters, sort: [{ column: "title", descending: Bool.False }] }) == [{ column: column_named("title"), descending: Bool.False }, { column: column_named("id"), descending: Bool.False }]
expect {
	state = { ..no_filters, sort: [{ column: "title", descending: Bool.False }], page: 4 }
	Listing.sorted_by(state, "title").sort == [{ column: "title", descending: Bool.True }] and Listing.sorted_by(state, "id").sort == [{ column: "id", descending: Bool.False }] and Listing.sorted_by(Listing.sorted_by(state, "title"), "title").sort == [{ column: "title", descending: Bool.False }]
}
expect Listing.key(shown_books, Form.fields("table=books&k.id=7")) == Ok([(column_named("id"), "7")])
expect Listing.key(shown_books, Form.fields("table=books&k.title=7")) == Err(NoKey)
expect Listing.key(Admin.pair({ ..books, key: [] }, { name: "books" }), Form.fields("k.id=7")) == Err(NoKey)
