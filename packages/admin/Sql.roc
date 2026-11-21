import Catalog

## The statements the admin runs, built from the catalog's tables and columns, never from a
## request's text: a table or a column a request names is looked up in the catalog first
## (`Catalog.table`, `Catalog.column`), and only the catalog's names are written into SQL, quoted.
## Every value is a parameter (`$1`), which Postgres reads as the type its place wants.
Sql := [].{

	## A parameter, as `Db.Value` has it.
	Param : [Null, Text(Str), Int(I64), Bool(Bool)]

	## A statement and its parameters, for `Db.all!` or `Db.run!`.
	Statement : { sql : Str, params : List(Param) }

	## What rows must be: a column equal to a value (as Postgres reads the value for its type),
	## null, or not null; or one of several columns containing a text, in any case.
	Condition : [Equals(Catalog.Column, Str), IsNull(Catalog.Column), NotNull(Catalog.Column), Search(List(Catalog.Column), Str)]

	## A column to sort by.
	Order : { column : Catalog.Column, descending : Bool }

	## A name as SQL writes one, in double quotes: `"order"`, `"say ""hi"""`. Any text is safe in
	## them but a zero byte, which Postgres's names can't hold, and which is dropped.
	ident : Str -> Str
	ident = |name| "\"${Str.from_utf8_lossy(name.to_utf8().keep_if(|byte| byte != 0)).replace_each("\"", "\"\"")}\""

	## A table in a schema: `"public"."users"`.
	qualified : Str, Str -> Str
	qualified = |schema, table| "${Sql.ident(schema)}.${Sql.ident(table)}"

	## A text as `ilike` finds it anywhere in another: `%`, `_` and `\` in it stand for themselves.
	contains : Str -> Str
	contains = |text| "%${text.replace_each("\\", "\\\\").replace_each("%", "\\%").replace_each("_", "\\_")}%"

	## `expression` (a column's value) as text, as a page shows it and an input takes it: a moment
	## as `2026-11-21T14:05:03` (in UTC, for a `timestamptz`), a day as `2026-11-21`, bytes as
	## how many there are; the rest as Postgres writes it.
	text_of : Catalog.Column, Str -> Str
	text_of = |column, expression|
		match column.base {
			"timestamptz" => "to_char(${expression} at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS')"
			"timestamp" => "to_char(${expression}, 'YYYY-MM-DD\"T\"HH24:MI:SS')"
			"date" => "to_char(${expression}, 'YYYY-MM-DD')"
			"bytea" => "'(' || octet_length(${expression})::text || ' bytes)'"
			_ => "${expression}::text"
		}

	## The `cells` and `nulls` of a row of `columns` (`Catalog.Row`), each cell at most `longest`
	## characters (0: all of it).
	cells : List(Catalog.Column), U64 -> Str
	cells = |columns, longest| Sql.cells_cut(columns.map(|column| (column, longest)))

	## The `cells` and `nulls` of a row of columns, each cut to its own length (0: whole).
	cells_cut : List((Catalog.Column, U64)) -> Str
	cells_cut = |columns|
		if columns.is_empty() {
			"'[]'::json as \"cells\", '[]'::json as \"nulls\""
		} else {
			texts = columns.map(
				|(column, longest)| {
					whole = "coalesce(${Sql.text_of(column, Sql.ident(column.name))}, '')"
					if (longest == 0) whole else "left(${whole}, ${longest.to_str()})"
				},
			)
			nulls = columns.map(|(column, _)| "${Sql.ident(column.name)} is null")
			"array_to_json(array[${Str.join_with(texts, ", ")}]) as \"cells\", array_to_json(array[${Str.join_with(nulls, ", ")}]) as \"nulls\""
		}

	## A page of rows: `columns` of those of `table` that meet `conditions`, in `order`, each cell
	## at most `longest` characters, then the `whole` columns (the key's), as they are.
	rows : Str, Catalog.Table, { columns : List(Catalog.Column), whole : List(Catalog.Column), conditions : List(Condition), order : List(Order), limit : U64, offset : U64, longest : U64 } -> Statement
	rows = |schema, table, asked| {
		filtered = where_clause(asked.conditions, 1)
		next = filtered.params.len() + 1
		sorted = if (asked.order.is_empty()) "" else " order by ${Str.join_with(asked.order.map(|each| "${Sql.ident(each.column.name)}${if (each.descending) " desc" else ""}"), ", ")}"
		{
			sql: "select ${Sql.cells_cut(asked.columns.map(|column| (column, asked.longest)).concat(asked.whole.map(|column| (column, 0))))} from ${Sql.qualified(schema, table.name)}${filtered.sql}${sorted} limit $${next.to_str()} offset $${(next + 1).to_str()}",
			params: filtered.params.concat([Int(asked.limit.to_i64_wrap()), Int(asked.offset.to_i64_wrap())]),
		}
	}

	## How many rows of `table` meet `conditions`: a row with one cell.
	count : Str, Catalog.Table, List(Condition) -> Statement
	count = |schema, table, conditions| {
		filtered = where_clause(conditions, 1)
		{ sql: "select array_to_json(array[count(*)::text]) as \"cells\", '[]'::json as \"nulls\" from ${Sql.qualified(schema, table.name)}${filtered.sql}", params: filtered.params }
	}

	## The row of `table` whose key is `key` (each key column and its value), whole.
	one : Str, Catalog.Table, List(Catalog.Column), List((Catalog.Column, Str)) -> Statement
	one = |schema, table, columns, key| {
		filtered = where_clause(key.map(|(column, value)| Equals(column, value)), 1)
		{ sql: "select ${Sql.cells(columns, 0)} from ${Sql.qualified(schema, table.name)}${filtered.sql} limit 2", params: filtered.params }
	}

	## A new row of `table` with `values` (its other columns take their defaults), answering with
	## its key's columns (`key`).
	insert : Str, Catalog.Table, List((Catalog.Column, Param)), List(Catalog.Column) -> Statement
	insert = |schema, table, values, key| {
		into = Sql.qualified(schema, table.name)
		returning = " returning ${Sql.cells(key, 0)}"
		if values.is_empty() {
			{ sql: "insert into ${into} default values${returning}", params: [] }
		} else {
			names = values.map(|(column, _)| Sql.ident(column.name))
			places = values.map_with_index(|_, at| "$${(at + 1).to_str()}")
			{ sql: "insert into ${into} (${Str.join_with(names, ", ")}) values (${Str.join_with(places, ", ")})${returning}", params: values.map(|(_, param)| param) }
		}
	}

	## `values` written to the row of `table` whose key is `key`.
	update : Str, Catalog.Table, List((Catalog.Column, Param)), List((Catalog.Column, Str)) -> Statement
	update = |schema, table, values, key| {
		set = values.map_with_index(|(column, _), at| "${Sql.ident(column.name)} = $${(at + 1).to_str()}")
		filtered = where_clause(key.map(|(column, value)| Equals(column, value)), values.len() + 1)
		{ sql: "update ${Sql.qualified(schema, table.name)} set ${Str.join_with(set, ", ")}${filtered.sql}", params: values.map(|(_, param)| param).concat(filtered.params) }
	}

	## The row of `table` whose key is `key`, deleted.
	delete : Str, Catalog.Table, List((Catalog.Column, Str)) -> Statement
	delete = |schema, table, key| {
		filtered = where_clause(key.map(|(column, value)| Equals(column, value)), 1)
		{ sql: "delete from ${Sql.qualified(schema, table.name)}${filtered.sql}", params: filtered.params }
	}

	## The values `column` of `table` has (not null), in order, at most `limit` of them: a filter's
	## choices.
	distinct : Str, Catalog.Table, Catalog.Column, U64 -> Statement
	distinct = |schema, table, column, limit| {
		name = Sql.ident(column.name)
		{
			sql: "select array_to_json(array[${Sql.text_of(column, "value")}]) as \"cells\", '[]'::json as \"nulls\" from (select distinct ${name} as value from ${Sql.qualified(schema, table.name)} where ${name} is not null order by 1 limit $1) as found",
			params: [Int(limit.to_i64_wrap())],
		}
	}

	## Each row of `table` as `key` (its value) and `title` (what names it), in order of their
	## titles, at most `limit` of them: the choices of a foreign key.
	titles : Str, Catalog.Table, Catalog.Column, Catalog.Column, U64 -> Statement
	titles = |schema, table, key, title, limit| {
		key_text = Sql.text_of(key, Sql.ident(key.name))
		title_text = "coalesce(${Sql.text_of(title, Sql.ident(title.name))}, ${key_text})"
		{
			sql: "select array_to_json(array[${key_text}, ${title_text}]) as \"cells\", '[]'::json as \"nulls\" from ${Sql.qualified(schema, table.name)} order by ${title_text}, ${Sql.ident(key.name)} limit $1",
			params: [Int(limit.to_i64_wrap())],
		}
	}
}

## ` where …` for `conditions` (nothing for none), its parameters numbered from `first`.
where_clause : List(Sql.Condition), U64 -> { sql : Str, params : List(Sql.Param) }
where_clause = |conditions, first| {
	var $parts = []
	var $params = []
	for condition in conditions {
		at = "$${(first + $params.len()).to_str()}"
		match condition {
			Equals(column, value) => {
				compared = if (column.base == "json") "${Sql.ident(column.name)}::text" else Sql.ident(column.name)
				$parts = $parts.append("${compared} = ${at}")
				$params = $params.append(Text(value))
			}
			IsNull(column) => {
				$parts = $parts.append("${Sql.ident(column.name)} is null")
			}
			NotNull(column) => {
				$parts = $parts.append("${Sql.ident(column.name)} is not null")
			}
			Search(columns, text) =>
				if !columns.is_empty() {
					found = columns.map(|column| "${if (is_text(column)) Sql.ident(column.name) else "${Sql.ident(column.name)}::text"} ilike ${at}")
					$parts = $parts.append("(${Str.join_with(found, " or ")})")
					$params = $params.append(Text(Sql.contains(text)))
				} else {
					{}
				}
		}
	}
	{ sql: if ($parts.is_empty()) "" else " where ${Str.join_with($parts, " and ")}", params: $params }
}

is_text : Catalog.Column -> Bool
is_text = |column| ["text", "varchar", "bpchar", "citext"].contains(column.base)

test_column : Str, Str -> Catalog.Column
test_column = |name, base| { name, type: base, base, category: "S", nullable: Bool.True, defaulted: Bool.False, generated: Bool.False, comment: "", default: "", labels: [], choices: [], refers: Nothing }

test_table : Catalog.Table
test_table = { name: "books", comment: "", estimate: 0, columns: [test_column("id", "int8"), test_column("title", "text")], key: ["id"] }

expect Sql.ident("users") == "\"users\""
expect Sql.ident("say \"hi\"") == "\"say \"\"hi\"\"\""
expect Sql.ident("a\u(0)b") == "\"ab\""
expect Sql.qualified("public", "order") == "\"public\".\"order\""
expect Sql.contains("50%_off\\") == "%50\\%\\_off\\\\%"
expect Sql.text_of(test_column("at", "timestamptz"), "\"at\"") == "to_char(\"at\" at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS')"
expect Sql.cells([], 0) == "'[]'::json as \"cells\", '[]'::json as \"nulls\""
expect Sql.cells([test_column("id", "int8"), test_column("on", "date")], 80) == "array_to_json(array[left(coalesce(\"id\"::text, ''), 80), left(coalesce(to_char(\"on\", 'YYYY-MM-DD'), ''), 80)]) as \"cells\", array_to_json(array[\"id\" is null, \"on\" is null]) as \"nulls\""
expect {
	statement = Sql.rows(
		"public",
		test_table,
		{
			columns: [test_column("id", "int8")],
			whole: [test_column("id", "int8")],
			conditions: [Search([test_column("title", "text"), test_column("id", "int8")], "a_b"), Equals(test_column("state", "text"), "x"), IsNull(test_column("note", "text"))],
			order: [{ column: test_column("title", "text"), descending: Bool.True }, { column: test_column("id", "int8"), descending: Bool.False }],
			limit: 50,
			offset: 100,
			longest: 81,
		},
	)
	statement.sql == "select array_to_json(array[left(coalesce(\"id\"::text, ''), 81), coalesce(\"id\"::text, '')]) as \"cells\", array_to_json(array[\"id\" is null, \"id\" is null]) as \"nulls\" from \"public\".\"books\" where (\"title\" ilike $1 or \"id\"::text ilike $1) and \"state\" = $2 and \"note\" is null order by \"title\" desc, \"id\" limit $3 offset $4"
		and statement.params == [Text("%a\\_b%"), Text("x"), Int(50), Int(100)]
}
expect {
	statement = Sql.count("public", test_table, [Search([], "x")])
	statement.sql == "select array_to_json(array[count(*)::text]) as \"cells\", '[]'::json as \"nulls\" from \"public\".\"books\"" and statement.params == []
}
expect {
	statement = Sql.insert("public", test_table, [(test_column("title", "text"), Text("Dune")), (test_column("note", "text"), Null)], [test_column("id", "int8")])
	statement.sql == "insert into \"public\".\"books\" (\"title\", \"note\") values ($1, $2) returning array_to_json(array[coalesce(\"id\"::text, '')]) as \"cells\", array_to_json(array[\"id\" is null]) as \"nulls\"" and statement.params == [Text("Dune"), Null]
}
expect Sql.insert("s", test_table, [], []).sql == "insert into \"s\".\"books\" default values returning '[]'::json as \"cells\", '[]'::json as \"nulls\""
expect {
	statement = Sql.update("public", test_table, [(test_column("title", "text"), Text("Dune"))], [(test_column("id", "int8"), "7"), (test_column("lang", "text"), "en")])
	statement.sql == "update \"public\".\"books\" set \"title\" = $1 where \"id\" = $2 and \"lang\" = $3" and statement.params == [Text("Dune"), Text("7"), Text("en")]
}
expect Sql.delete("public", test_table, [(test_column("id", "int8"), "7")]) == { sql: "delete from \"public\".\"books\" where \"id\" = $1", params: [Text("7")] }
expect Sql.one("public", test_table, [test_column("id", "int8")], [(test_column("id", "int8"), "7")]).params == [Text("7")]
expect Sql.distinct("public", test_table, test_column("state", "text"), 50).sql == "select array_to_json(array[value::text]) as \"cells\", '[]'::json as \"nulls\" from (select distinct \"state\" as value from \"public\".\"books\" where \"state\" is not null order by 1 limit $1) as found"
expect Sql.titles("public", test_table, test_column("id", "int8"), test_column("title", "text"), 201).sql == "select array_to_json(array[\"id\"::text, coalesce(\"title\"::text, \"id\"::text)]) as \"cells\", '[]'::json as \"nulls\" from \"public\".\"books\" order by coalesce(\"title\"::text, \"id\"::text), \"id\" limit $1"
