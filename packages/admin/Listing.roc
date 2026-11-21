import Admin
import Catalog
import Form
import Sql

## What a table's list of rows shows, as its URL's query says: `q` (a search), `f.<column>=<value>`
## (a filter: the column is that value), `is.<column>=null` or `is.<column>=set`, `sort=<column>` or
## `sort=-<column>` (descending), and `page`. A column the query names is one only if the app lets
## the list search, filter or sort by it: anything else in a query is ignored.
Listing := [].{

	## A filter: a column, and what it must be.
	Filter : { column : Str, is : [Equal(Str), Null, Set] }

	## A list's state.
	State : { search : Str, filters : List(Filter), sort : List({ column : Str, descending : Bool }), page : U64 }

	## The state a query asks for, of what the table's options allow.
	read : Admin.Shown, List(Form.Field) -> State
	read = |shown, query| {
		search = if (Admin.searchable(shown).is_empty()) "" else Form.get(query, "q").trim()
		filterable = Admin.filterable(shown).map(|column| column.name)
		equal = Form.prefixed(query, "f.").keep_if(|(name, _)| filterable.contains(name)).map(|(name, value)| { column: name, is: Equal(value) })
		nulls = Form.prefixed(query, "is.").keep_oks(
			|(name, value)|
				if !filterable.contains(name) or equal.any(|each| each.column == name) {
					Err(NotAsked)
				} else {
					match value {
						"null" => Ok({ column: name, is: Null })
						"set" => Ok({ column: name, is: Set })
						_ => Err(NotAsked)
					}
				},
		)
		sortable = Admin.listed(shown).map(|column| column.name)
		sorted = Form.get(query, "sort")
		sort =
			if sortable.contains(sorted.drop_prefix("-")) {
				[{ column: sorted.drop_prefix("-"), descending: sorted.starts_with("-") }]
			} else {
				[]
			}
		{ search, filters: equal.concat(nulls), sort, page: U64.from_str(Form.get(query, "page")) ?? 1 }
	}

	## The state as a query's params, the table's first; the first page isn't said.
	params : Str, State -> List((Str, Str))
	params = |table, state| {
		filters = state.filters.map(
			|each|
				match each.is {
					Equal(value) => ("f.${each.column}", value)
					Null => ("is.${each.column}", "null")
					Set => ("is.${each.column}", "set")
				},
		)
		sort = state.sort.map(|each| ("sort", "${if (each.descending) "-" else ""}${each.column}"))
		[("table", table), ("q", state.search)].concat(filters).concat(sort).append(("page", if (state.page <= 1) "" else state.page.to_str()))
	}

	## What the rows must be, for the statements.
	conditions : Admin.Shown, State -> List(Sql.Condition)
	conditions = |shown, state| {
		search = if (state.search.is_empty()) [] else [Search(Admin.searchable(shown), state.search)]
		filters = state.filters.keep_oks(
			|each|
				match Catalog.column(shown.table, each.column) {
					Ok(column) =>
						match each.is {
							Equal(value) => Ok(Equals(column, value))
							Null => Ok(IsNull(column))
							Set => Ok(NotNull(column))
						}
					Err(NotFound) => Err(NotFound)
				},
		)
		search.concat(filters)
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

	## The state with a filter on `column` set to `is` (or none: `Err(All)`), back on the first page.
	filtered : State, Str, Try([Equal(Str), Null, Set], [All]) -> State
	filtered = |state, column, is| {
		others = state.filters.keep_if(|each| each.column != column)
		kept =
			match is {
				Ok(wanted) => others.append({ column, is: wanted })
				Err(All) => others
			}
		{ ..state, filters: kept, page: 1 }
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

column_of : Str, Str -> Catalog.Column
column_of = |name, base| { name, type: base, base, category: "", nullable: Bool.True, defaulted: Bool.False, generated: Bool.False, comment: "", default: "", labels: [], choices: [], refers: Nothing }

books : Catalog.Table
books = { name: "books", comment: "", estimate: 0, columns: [column_of("id", "int8"), column_of("title", "text"), column_of("state", "text"), column_of("secret", "text")], key: ["id"] }

shown_books : Admin.Shown
shown_books = Admin.pair(books, { name: "books", list: ["id", "title", "state"], search: ["title", "secret"], filters: ["state", "secret"], hidden: ["secret"] })

expect {
	state = Listing.read(shown_books, Form.fields("table=books&q=+dune+&f.state=draft&f.secret=x&f.id=1&is.title=null&sort=-title&page=3"))
	state == { search: "dune", filters: [{ column: "state", is: Equal("draft") }], sort: [{ column: "title", descending: Bool.True }], page: 3 }
}
expect Listing.read(shown_books, Form.fields("is.state=null&sort=secret&page=x")) == { search: "", filters: [{ column: "state", is: Null }], sort: [], page: 1 }
expect Listing.read(shown_books, Form.fields("f.state=a&is.state=set")).filters == [{ column: "state", is: Equal("a") }]
expect Listing.read(Admin.pair(books, { name: "books" }), Form.fields("q=x")).search == ""
expect {
	state = { search: "a b", filters: [{ column: "state", is: Equal("x") }, { column: "note", is: Set }], sort: [{ column: "title", descending: Bool.False }], page: 2 }
	Form.link("/db", Listing.params("books", state)) == "/db?table=books&q=a%20b&f.state=x&is.note=set&sort=title&page=2"
}
expect Form.link("/db", Listing.params("books", { search: "", filters: [], sort: [], page: 1 })) == "/db?table=books"
expect {
	state = Listing.read(shown_books, Form.fields("q=dune&f.state=draft&is.state=set"))
	Listing.conditions(shown_books, state) == [Search([column_of("title", "text")], "dune"), Equals(column_of("state", "text"), "draft")]
}
expect Listing.order(shown_books, { search: "", filters: [], sort: [], page: 1 }) == [{ column: column_of("id", "int8"), descending: Bool.True }]
expect Listing.order(shown_books, { search: "", filters: [], sort: [{ column: "title", descending: Bool.False }], page: 1 }) == [{ column: column_of("title", "text"), descending: Bool.False }, { column: column_of("id", "int8"), descending: Bool.False }]
expect {
	state = { search: "", filters: [{ column: "state", is: Equal("x") }], sort: [], page: 4 }
	Listing.filtered(state, "state", Ok(Null)).filters == [{ column: "state", is: Null }] and Listing.filtered(state, "state", Err(All)).filters == [] and Listing.filtered(state, "state", Err(All)).page == 1
}
expect {
	state = { search: "", filters: [], sort: [{ column: "title", descending: Bool.False }], page: 4 }
	Listing.sorted_by(state, "title").sort == [{ column: "title", descending: Bool.True }] and Listing.sorted_by(state, "id").sort == [{ column: "id", descending: Bool.False }] and Listing.sorted_by(Listing.sorted_by(state, "title"), "title").sort == [{ column: "title", descending: Bool.False }]
}
expect Listing.key(shown_books, Form.fields("table=books&k.id=7")) == Ok([(column_of("id", "int8"), "7")])
expect Listing.key(shown_books, Form.fields("table=books&k.title=7")) == Err(NoKey)
expect Listing.key(Admin.pair({ ..books, key: [] }, { name: "books" }), Form.fields("k.id=7")) == Err(NoKey)
