import Catalog
import Sql
import Widget

## What the app says about its admin: where it is, who may use it and how, and which tables it
## shows, each with its options. Only `name` is needed for a table, `mount` and `access` for the
## admin; the rest have defaults.
##
## ```roc
## admin : Admin.Config({ user : Str, staff : Bool })
## admin = {
##     mount: "/admin/db",
##     access: |context| if (context.staff) Edit else Refused,
##     tables: [
##         { name: "books", list: ["id", "title", "state", "price"], search: ["title"], ordering: ["-id"] },
##         { name: "authors", title: "name", hidden: ["password_hash"] },
##     ],
## }
## ```
Admin := [].{

	## A table's options. Columns are named as the table names them; a name it doesn't have stops
	## the admin, which shows only what is wrong (`problems`) until it is mended: a misspelt
	## `hidden` would otherwise show the column it was meant to hide.
	##
	## - `label`: what the pages call it ("" — its name, readable: `book_tags` is "Book tags").
	## - `list`: the columns its list of rows shows ([] — the first seven it has), each with a
	##   filter under its heading, chosen from its type (`Listing.kind`).
	## - `search`: the columns the search box looks in, for the text anywhere, in any case ([] — no
	##   search box).
	## - `ordering`: the list's order, `"-created_at"` descending ([] — its primary key, newest
	##   first). A click on a column's heading sorts by it instead.
	## - `read_only`: shown on its form, never written; `hidden`: never read, shown or written
	##   (a password's hash).
	## - `labels`: what to call its columns (`[("email", "Email address")]`).
	## - `title`: the column that names a row: its page's heading, and a foreign key's choice ("" —
	##   its first text column that isn't its key, else its key).
	## - `per_page`: rows a page (50).
	## - `widgets`: another widget for a column than its type's (`[("body", LongText)]`).
	## - `create`, `delete`: whether rows may be added or deleted here (yes).
	Table := {
		name : Str,
		label : Str ?? "",
		list : List(Str) ?? [],
		search : List(Str) ?? [],
		ordering : List(Str) ?? [],
		read_only : List(Str) ?? [],
		hidden : List(Str) ?? [],
		labels : List((Str, Str)) ?? [],
		title : Str ?? "",
		per_page : U64 ?? 50,
		widgets : List((Str, Widget.Kind)) ?? [],
		create : Bool ?? Bool.True,
		delete : Bool ?? Bool.True,
	}

	## What someone may do here, as the app decides from its middleware's context: `Edit` (add,
	## change, delete), `ReadOnly` (look), or nothing (`Refused`: a 403).
	Access : [Edit, ReadOnly, Refused]

	## The admin:
	##
	## - `mount`: the path it is at (the route file's: `routes/admin/db/+server.roc` is
	##   `"/admin/db"`). Its pages are that path and a query (`?table=books&k.id=7`).
	## - `access`: what someone may do, from the context the route's middleware hands on.
	## - `tables`: the tables it shows, in order, with their options; `include: All` shows every
	##   other table of the schema too, with no options (but the platform's own, `rocx_…`, unless
	##   listed). `Listed` by default: a table no one listed (one of passwords) stays out.
	## - `schema`: the tables' schema (`public`); `title`: what its pages call it (`Database`).
	## - `back`: a link back to the app's own pages, first in every page's sidebar
	##   (`{ label: "Status", href: "/admin" }`); none unless the app says (`href` "").
	Config(context) := {
		mount : Str,
		access : context -> Access,
		tables : List(Table) ?? [],
		include : [Listed, All] ?? Listed,
		schema : Str ?? "public",
		title : Str ?? "Database",
		back : { label : Str, href : Str } ?? { label: "", href: "" },
	}

	## A table the admin shows: what the catalog says of it, and the app's options.
	Shown : { table : Catalog.Table, options : Table }

	## What the app's options name that the schema doesn't have, each a sentence: a table in
	## `tables` that isn't there, and a column a table's options name (`list`, `search`,
	## `ordering`, `read_only`, `hidden`, `labels`, `widgets`, `title`) that it doesn't have. While
	## there are any, the admin's pages say so and show nothing else.
	problems : Config(context), List(Catalog.Table) -> List(Str)
	problems = |config, tables|
		config.tables.join_map(
			|options|
				match Catalog.table(tables, options.name) {
					Err(NotFound) => ["`${options.name}`, in `tables`, isn't a table of the schema."]
					Ok(table) => {
						named = [
							("list", options.list),
							("search", options.search),
							("ordering", options.ordering.map(|each| each.drop_prefix("-"))),
							("read_only", options.read_only),
							("hidden", options.hidden),
							("labels", options.labels.map(|(name, _)| name)),
							("widgets", options.widgets.map(|(name, _)| name)),
							("title", if (options.title.is_empty()) [] else [options.title]),
						]
						named.join_map(|(field, names)| names.drop_if(|name| table.columns.any(|column| column.name == name)).map(|name| "`${name}`, in ${options.name}'s `${field}`, isn't a column of ${options.name}."))
					}
				},
		)

	## The tables the admin shows: those listed that the schema has, in order; with `include: All`,
	## then every other table of the schema, but the platform's (`rocx_…`), by name.
	showing : Config(context), List(Catalog.Table) -> List(Shown)
	showing = |config, tables| {
		named = config.tables.keep_oks(
			|options|
				match Catalog.table(tables, options.name) {
					Ok(table) => Ok({ table, options })
					Err(NotFound) => Err(NotFound)
				},
		)
		match config.include {
			Listed => named
			All => {
				others = tables.keep_if(|table| !table.name.starts_with("rocx_") and !config.tables.any(|options| options.name == table.name))
				named.concat(others.map(|table| Admin.pair(table, { name: table.name })))
			}
		}
	}

	## A table and its options.
	pair : Catalog.Table, Table -> Shown
	pair = |table, options| { table, options }

	## The table the admin shows called `name`.
	find : List(Shown), Str -> Try(Shown, [NotFound])
	find = |all, name|
		match all.find_first(|each| each.table.name == name) {
			Ok(found) => Ok(found)
			Err(_) => Err(NotFound)
		}

	## What the pages call a table.
	label : Shown -> Str
	label = |shown| if (shown.options.label.is_empty()) readable(shown.table.name) else shown.options.label

	## What the pages call a column of a table.
	column_label : Shown, Str -> Str
	column_label = |shown, name|
		match shown.options.labels.find_first(|(column, _)| column == name) {
			Ok((_, said)) => said
			Err(_) => readable(name)
		}

	## The columns of a table that may be read: all but the `hidden`.
	visible : Shown -> List(Catalog.Column)
	visible = |shown| shown.table.columns.keep_if(|column| !shown.options.hidden.contains(column.name))

	## The columns a table's list of rows shows, each with its filter.
	listed : Shown -> List(Catalog.Column)
	listed = |shown| {
		chosen = picked(shown, shown.options.list)
		if (chosen.is_empty()) Admin.visible(shown).take_first(7) else chosen
	}

	## The columns a table's search looks in.
	searchable : Shown -> List(Catalog.Column)
	searchable = |shown| picked(shown, shown.options.search)

	## The columns of a table's primary key, in order ([] if it has none: its rows can be listed,
	## not opened).
	key : Shown -> List(Catalog.Column)
	key = |shown| shown.table.key.keep_oks(|name| Catalog.column(shown.table, name))

	## A column's widget: the app's choice, else its type's.
	widget : Shown, Catalog.Column -> Widget.Kind
	widget = |shown, column|
		match shown.options.widgets.find_first(|(name, _)| name == column.name) {
			Ok((_, kind)) => kind
			Err(_) => Widget.of(column)
		}

	## Whether a column is written by a table's form: someone who may `Edit`, a column that isn't
	## read only (the app's `read_only`, or its widget's), and a key's column only in a new row.
	writable : Shown, Access, Catalog.Column, [Creating, Editing] -> Bool
	writable = |shown, access, column, doing|
		access == Edit
			and !shown.options.read_only.contains(column.name)
			and !shown.options.hidden.contains(column.name)
			and Admin.widget(shown, column) != ReadOnly
			and (doing == Creating or !shown.table.key.contains(column.name))

	## The column that names a row of a table.
	title : Shown -> Try(Catalog.Column, [NoTitle])
	title = |shown| {
		readable_columns = Admin.visible(shown)
		named = readable_columns.find_first(|column| column.name == shown.options.title)
		text = readable_columns.find_first(|column| ["text", "varchar", "citext", "bpchar"].contains(column.base) and !shown.table.key.contains(column.name))
		match (named, text, Admin.key(shown).first()) {
			(Ok(column), _, _) => Ok(column)
			(_, Ok(column), _) => Ok(column)
			(_, _, Ok(column)) => Ok(column)
			_ => Err(NoTitle)
		}
	}

	## A table's list's order when it isn't sorted by a column: the app's `ordering`, else its key,
	## newest first (else its first column).
	ordering : Shown -> List(Sql.Order)
	ordering = |shown| {
		asked = shown.options.ordering.keep_oks(
			|each| {
				descending = each.starts_with("-")
				match Catalog.column(shown.table, each.drop_prefix("-")) {
					Ok(column) if !shown.options.hidden.contains(column.name) => Ok({ column, descending })
					_ => Err(NotFound)
				}
			},
		)
		if !asked.is_empty() {
			asked
		} else if !shown.table.key.is_empty() {
			Admin.key(shown).map(|column| { column, descending: Bool.True })
		} else {
			Admin.visible(shown).take_first(1).map(|column| { column, descending: Bool.False })
		}
	}
}

## The visible columns of `names`, in that order.
picked : Admin.Shown, List(Str) -> List(Catalog.Column)
picked = |shown, names| names.keep_oks(|name| if (shown.options.hidden.contains(name)) Err(NotFound) else Catalog.column(shown.table, name))

## `book_tags` as `Book tags`.
readable : Str -> Str
readable = |name| {
	spaced = name.replace_each("_", " ").trim()
	bytes = spaced.to_utf8()
	match bytes.first() {
		Ok(first) if first >= 'a' and first <= 'z' => Str.from_utf8_lossy(bytes.drop_first(1).prepend(first - 32))
		_ => spaced
	}
}

test_column : Catalog.Column
test_column = { name: "", type: "", base: "", category: "", nullable: Bool.False, defaulted: Bool.False, generated: Bool.False, comment: "", default: "", labels: [], choices: [], refers: Nothing }

column_of : Str, Str -> Catalog.Column
column_of = |name, base| { ..test_column, name, type: base, base }

books : Catalog.Table
books = {
	name: "books",
	comment: "",
	estimate: 10,
	columns: [column_of("id", "int8"), column_of("title", "text"), column_of("secret", "text"), column_of("state", "text"), { ..column_of("len", "int4"), generated: Bool.True }],
	key: ["id"],
}

tables : List(Catalog.Table)
tables = [books, { ..books, name: "authors" }, { ..books, name: "rocx_jobs" }, { ..books, name: "tags" }]

expect {
	config : Admin.Config({})
	config = { mount: "/db", access: |_| Edit, tables: [{ name: "tags" }, { name: "nope" }, { name: "books", label: "Our books" }] }
	Admin.showing(config, tables).map(|each| each.table.name) == ["tags", "books"]
}
expect {
	config : Admin.Config({})
	config = { mount: "/db", access: |_| Edit, tables: [{ name: "books", list: ["id", "title"], ordering: ["-id"], hidden: ["secret"], labels: [("len", "Length")], title: "title" }, { name: "tags" }] }
	Admin.problems(config, tables) == []
}
expect {
	config : Admin.Config({})
	config = { mount: "/db", access: |_| Edit, tables: [{ name: "books", hidden: ["secrett"], ordering: ["-nope"], widgets: [("body", LongText)] }, { name: "athors" }] }
	Admin.problems(config, tables)
		== [
			"`nope`, in books's `ordering`, isn't a column of books.",
			"`secrett`, in books's `hidden`, isn't a column of books.",
			"`body`, in books's `widgets`, isn't a column of books.",
			"`athors`, in `tables`, isn't a table of the schema.",
		]
}
expect {
	config : Admin.Config({})
	config = { mount: "/db", access: |_| Edit, tables: [{ name: "tags" }], include: All }
	Admin.showing(config, tables).map(|each| each.table.name) == ["tags", "books", "authors"]
}
expect {
	shown = Admin.pair(books, { name: "books", label: "Our books", labels: [("len", "Title's length")] })
	Admin.label(shown) == "Our books" and Admin.label(Admin.pair({ ..books, name: "book_tags" }, { name: "book_tags" })) == "Book tags" and Admin.column_label(shown, "len") == "Title's length" and Admin.column_label(shown, "created_at") == "Created at"
}
expect {
	shown = Admin.pair(books, { name: "books", hidden: ["secret"], list: ["title", "secret", "nope", "id"], search: ["secret", "title"] })
	Admin.listed(shown).map(|c| c.name) == ["title", "id"] and Admin.searchable(shown).map(|c| c.name) == ["title"] and Admin.visible(shown).len() == 4
}
expect {
	shown = Admin.pair(books, { name: "books", hidden: ["secret"] })
	Admin.listed(shown).map(|c| c.name) == ["id", "title", "state", "len"] and Admin.key(shown).map(|c| c.name) == ["id"]
}
expect {
	shown = Admin.pair(books, { name: "books", read_only: ["state"], widgets: [("title", LongText)] })
	title = column_of("title", "text")
	Admin.writable(shown, Edit, title, Editing)
		and !Admin.writable(shown, ReadOnly, title, Editing)
		and !Admin.writable(shown, Edit, column_of("state", "text"), Editing)
		and !Admin.writable(shown, Edit, column_of("id", "int8"), Editing)
		and Admin.writable(shown, Edit, column_of("id", "int8"), Creating)
		and !Admin.writable(shown, Edit, { ..column_of("len", "int4"), generated: Bool.True }, Creating)
		and Admin.widget(shown, title) == LongText
}
expect Admin.title(Admin.pair(books, { name: "books" })).map_ok(|c| c.name) == Ok("title")
expect Admin.title(Admin.pair(books, { name: "books", title: "state" })).map_ok(|c| c.name) == Ok("state")
expect Admin.title(Admin.pair({ ..books, columns: [column_of("id", "int8")] }, { name: "books" })).map_ok(|c| c.name) == Ok("id")
expect Admin.ordering(Admin.pair(books, { name: "books" })) == [{ column: column_of("id", "int8"), descending: Bool.True }]
expect Admin.ordering(Admin.pair({ ..books, key: [] }, { name: "books", hidden: ["id"] })) == [{ column: column_of("title", "text"), descending: Bool.False }]
expect Admin.ordering(Admin.pair(books, { name: "books", ordering: ["-state", "nope", "title"] })) == [{ column: column_of("state", "text"), descending: Bool.True }, { column: column_of("title", "text"), descending: Bool.False }]
