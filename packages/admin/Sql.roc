import Catalog

## The statements the admin runs, built from the catalog's tables and columns, never from a
## request's text: a table or a column a request names is looked up in the catalog first
## (`Catalog.table`, `Catalog.column`), and only the catalog's names are written into SQL, quoted.
## Every value is a parameter (`$1`): Postgres reads it as the type its place wants; SQLite
## compares and stores it as its column's affinity says (a boolean's `true` and `false` are 1 and
## 0 there). Each is written for the database the app has (`On`, D-045).
Sql := [].{

	## A parameter, as `Db.Value` has it.
	Param : [Null, Text(Str), Int(I64), Bool(Bool)]

	## A statement and its parameters, for `Db.all!` or `Db.run!`.
	Statement : { sql : Str, params : List(Param) }

	## Where the statements run: the tables' schema (`public`; `main` on SQLite) and the app's
	## database (D-045).
	On : { schema : Str, dialect : [Postgres, Sqlite] }

	## What rows must be: a column equal to a value (as Postgres reads the value for its type),
	## null, not null, containing a text (in any case), at least a value or at most one (the
	## value cast to the column's type, for a number, a date or a time); or one of several columns
	## containing a text, in any case.
	Condition : [Equals(Catalog.Column, Str), IsNull(Catalog.Column), NotNull(Catalog.Column), Contains(Catalog.Column, Str), AtLeast(Catalog.Column, Str), AtMost(Catalog.Column, Str), Search(List(Catalog.Column), Str)]

	## A column to sort by.
	Order : { column : Catalog.Column, descending : Bool }

	## A name as SQL writes one, in double quotes: `"order"`, `"say ""hi"""`. Any text is safe in
	## them but a zero byte, which Postgres's names can't hold, and which is dropped.
	ident : Str -> Str
	ident = |name| "\"${Str.from_utf8_lossy(name.to_utf8().keep_if(|byte| byte != 0)).replace_each("\"", "\"\"")}\""

	## A table in a schema: `"public"."users"`.
	qualified : Str, Str -> Str
	qualified = |schema, table| "${Sql.ident(schema)}.${Sql.ident(table)}"

	## A text as `ilike` (and SQLite's `like … escape '\'`) finds it anywhere in another: `%`, `_`
	## and `\` in it stand for themselves.
	contains : Str -> Str
	contains = |text| "%${text.replace_each("\\", "\\\\").replace_each("%", "\\%").replace_each("_", "\\_")}%"

	## `expression` (a column's value) as text, as a page shows it and an input takes it: a moment
	## as `2026-11-21T14:05:03` (in UTC, for a `timestamptz`), a day as `2026-11-21`, bytes as
	## how many there are; the rest as Postgres writes it. On SQLite, a boolean as `true` or
	## `false`, bytes as how many, the rest as SQLite's text of it.
	text_of : [Postgres, Sqlite], Catalog.Column, Str -> Str
	text_of = |dialect, column, expression|
		match dialect {
			Postgres =>
				match column.base {
					"timestamptz" => "to_char(${expression} at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS')"
					"timestamp" => "to_char(${expression}, 'YYYY-MM-DD\"T\"HH24:MI:SS')"
					"date" => "to_char(${expression}, 'YYYY-MM-DD')"
					"bytea" => "'(' || octet_length(${expression})::text || ' bytes)'"
					_ => "${expression}::text"
				}
			Sqlite =>
				match column.base {
					"bool" => "case when ${expression} is null then null when ${expression} then 'true' else 'false' end"
					"bytea" => "'(' || length(${expression}) || ' bytes)'"
					_ => "cast(${expression} as text)"
				}
		}

	## The `cells` and `nulls` of a row of `columns` (`Catalog.Raw`: each a JSON array, as text),
	## each cell at most `longest` characters (0: all of it).
	cells : [Postgres, Sqlite], List(Catalog.Column), U64 -> Str
	cells = |dialect, columns, longest| Sql.cells_cut(dialect, columns.map(|column| (column, longest)))

	## The `cells` and `nulls` of a row of columns, each cut to its own length (0: whole).
	cells_cut : [Postgres, Sqlite], List((Catalog.Column, U64)) -> Str
	cells_cut = |dialect, columns|
		if columns.is_empty() {
			none(dialect)
		} else {
			texts = columns.map(
				|(column, longest)| {
					whole = "coalesce(${Sql.text_of(dialect, column, Sql.ident(column.name))}, '')"
					if longest == 0 {
						whole
					} else {
						match dialect {
							Postgres => "left(${whole}, ${longest.to_str()})"
							Sqlite => "substr(${whole}, 1, ${longest.to_str()})"
						}
					}
				},
			)
			match dialect {
				Postgres => {
					nulls = columns.map(|(column, _)| "${Sql.ident(column.name)} is null")
					"array_to_json(array[${Str.join_with(texts, ", ")}])::text as \"cells\", array_to_json(array[${Str.join_with(nulls, ", ")}])::text as \"nulls\""
				}
				Sqlite => {
					nulls = columns.map(|(column, _)| "iif(${Sql.ident(column.name)} is null, json('true'), json('false'))")
					"json_array(${Str.join_with(texts, ", ")}) as \"cells\", json_array(${Str.join_with(nulls, ", ")}) as \"nulls\""
				}
			}
		}

	## A page of rows: `columns` of those of `table` that meet `conditions`, in `order`, each cell
	## at most `longest` characters, then the `whole` columns (the key's), as they are.
	rows : On, Catalog.Table, { columns : List(Catalog.Column), whole : List(Catalog.Column), conditions : List(Condition), order : List(Order), limit : U64, offset : U64, longest : U64 } -> Statement
	rows = |on, table, asked| {
		filtered = where_clause(on.dialect, asked.conditions, 1)
		next = filtered.params.len() + 1
		sorted = if (asked.order.is_empty()) "" else " order by ${Str.join_with(asked.order.map(|each| "${Sql.ident(each.column.name)}${if (each.descending) " desc" else ""}"), ", ")}"
		{
			sql: "select ${Sql.cells_cut(on.dialect, asked.columns.map(|column| (column, asked.longest)).concat(asked.whole.map(|column| (column, 0))))} from ${Sql.qualified(on.schema, table.name)}${filtered.sql}${sorted} limit $${next.to_str()} offset $${(next + 1).to_str()}",
			params: filtered.params.concat([Int(asked.limit.to_i64_wrap()), Int(asked.offset.to_i64_wrap())]),
		}
	}

	## How many rows of `table` meet `conditions`: a row with one cell.
	count : On, Catalog.Table, List(Condition) -> Statement
	count = |on, table, conditions| {
		filtered = where_clause(on.dialect, conditions, 1)
		counted =
			match on.dialect {
				Postgres => "array_to_json(array[count(*)::text])::text as \"cells\", '[]'::text as \"nulls\""
				Sqlite => "json_array(cast(count(*) as text)) as \"cells\", '[]' as \"nulls\""
			}
		{ sql: "select ${counted} from ${Sql.qualified(on.schema, table.name)}${filtered.sql}", params: filtered.params }
	}

	## The row of `table` whose key is `key` (each key column and its value), whole.
	one : On, Catalog.Table, List(Catalog.Column), List((Catalog.Column, Str)) -> Statement
	one = |on, table, columns, key| {
		filtered = where_clause(on.dialect, key.map(|(column, value)| Equals(column, value)), 1)
		{ sql: "select ${Sql.cells(on.dialect, columns, 0)} from ${Sql.qualified(on.schema, table.name)}${filtered.sql} limit 2", params: filtered.params }
	}

	## A new row of `table` with `values` (its other columns take their defaults), answering with
	## its key's columns (`key`).
	insert : On, Catalog.Table, List((Catalog.Column, Param)), List(Catalog.Column) -> Statement
	insert = |on, table, values, key| {
		into = Sql.qualified(on.schema, table.name)
		returning = " returning ${Sql.cells(on.dialect, key, 0)}"
		if values.is_empty() {
			{ sql: "insert into ${into} default values${returning}", params: [] }
		} else {
			names = values.map(|(column, _)| Sql.ident(column.name))
			places = values.map_with_index(|_, at| "$${(at + 1).to_str()}")
			{ sql: "insert into ${into} (${Str.join_with(names, ", ")}) values (${Str.join_with(places, ", ")})${returning}", params: values.map(|(column, param)| written(on.dialect, column, param)) }
		}
	}

	## `values` written to the row of `table` whose key is `key`.
	update : On, Catalog.Table, List((Catalog.Column, Param)), List((Catalog.Column, Str)) -> Statement
	update = |on, table, values, key| {
		set = values.map_with_index(|(column, _), at| "${Sql.ident(column.name)} = $${(at + 1).to_str()}")
		filtered = where_clause(on.dialect, key.map(|(column, value)| Equals(column, value)), values.len() + 1)
		{ sql: "update ${Sql.qualified(on.schema, table.name)} set ${Str.join_with(set, ", ")}${filtered.sql}", params: values.map(|(column, param)| written(on.dialect, column, param)).concat(filtered.params) }
	}

	## The row of `table` whose key is `key`, deleted.
	delete : On, Catalog.Table, List((Catalog.Column, Str)) -> Statement
	delete = |on, table, key| {
		filtered = where_clause(on.dialect, key.map(|(column, value)| Equals(column, value)), 1)
		{ sql: "delete from ${Sql.qualified(on.schema, table.name)}${filtered.sql}", params: filtered.params }
	}

	## Each row of `table` as `key` (its value) and `title` (what names it), in order of their
	## titles, at most `limit` of them: the choices of a foreign key.
	titles : On, Catalog.Table, Catalog.Column, Catalog.Column, U64 -> Statement
	titles = |on, table, key, title, limit| {
		key_text = Sql.text_of(on.dialect, key, Sql.ident(key.name))
		title_text = "coalesce(${Sql.text_of(on.dialect, title, Sql.ident(title.name))}, ${key_text})"
		pair =
			match on.dialect {
				Postgres => "array_to_json(array[${key_text}, ${title_text}])::text as \"cells\", '[]'::text as \"nulls\""
				Sqlite => "json_array(${key_text}, ${title_text}) as \"cells\", '[]' as \"nulls\""
			}
		{
			sql: "select ${pair} from ${Sql.qualified(on.schema, table.name)} order by ${title_text}, ${Sql.ident(key.name)} limit $1",
			params: [Int(limit.to_i64_wrap())],
		}
	}
}

## No cells, and no nulls.
none : [Postgres, Sqlite] -> Str
none = |dialect|
	match dialect {
		Postgres => "'[]'::text as \"cells\", '[]'::text as \"nulls\""
		Sqlite => "'[]' as \"cells\", '[]' as \"nulls\""
	}

## A value as the column takes it: on SQLite, a boolean's `true` or `false` is 1 or 0 (its column
## would keep the text as it is); anything else as it came.
written : [Postgres, Sqlite], Catalog.Column, Sql.Param -> Sql.Param
written = |dialect, column, param|
	match (dialect, param) {
		(Sqlite, Text("true")) if column.base == "bool" => Int(1)
		(Sqlite, Text("false")) if column.base == "bool" => Int(0)
		_ => param
	}

## ` where …` for `conditions` (nothing for none), its parameters numbered from `first`.
where_clause : [Postgres, Sqlite], List(Sql.Condition), U64 -> { sql : Str, params : List(Sql.Param) }
where_clause = |dialect, conditions, first| {
	var $parts = []
	var $params = []
	like = |text_column, place|
		match dialect {
			Postgres => "${text_column} ilike ${place}"
			# SQLite's `like` is in any case for ASCII letters, and has no escape unless it is named.
			Sqlite => "${text_column} like ${place} escape '\\'"
		}
	for condition in conditions {
		at = "$${(first + $params.len()).to_str()}"
		match condition {
			Equals(column, value) => {
				# JSON has no equality (json), or one Postgres reads the value for (jsonb): its text.
				json = column.base == "json" or column.base == "jsonb"
				compared = if (json and dialect == Postgres) "${Sql.ident(column.name)}::text" else Sql.ident(column.name)
				$parts = $parts.append("${compared} = ${at}")
				$params = $params.append(written(dialect, column, Text(value)))
			}
			IsNull(column) => {
				$parts = $parts.append("${Sql.ident(column.name)} is null")
			}
			NotNull(column) => {
				$parts = $parts.append("${Sql.ident(column.name)} is not null")
			}
			Contains(column, text) => {
				$parts = $parts.append(like(as_text(dialect, column), at))
				$params = $params.append(Text(Sql.contains(text)))
			}
			AtLeast(column, value) => {
				$parts = $parts.append("${Sql.ident(column.name)} >= ${at}${cast(dialect, column)}")
				$params = $params.append(Text(value))
			}
			AtMost(column, value) => {
				$parts = $parts.append("${Sql.ident(column.name)} <= ${at}${cast(dialect, column)}")
				$params = $params.append(Text(value))
			}
			Search(columns, text) =>
				if !columns.is_empty() {
					found = columns.map(|column| like(as_text(dialect, column), at))
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

## A column as `ilike` (or `like`) reads it: a text as it is, anything else as its text.
as_text : [Postgres, Sqlite], Catalog.Column -> Str
as_text = |dialect, column|
	if is_text(column) {
		Sql.ident(column.name)
	} else {
		match dialect {
			Postgres => "${Sql.ident(column.name)}::text"
			Sqlite => "cast(${Sql.ident(column.name)} as text)"
		}
	}

## The cast of a range's value to its column's type (` ::numeric`), for the types a range is for;
## none for any other (Postgres reads the value as the column's type). Only these names are written.
## None on SQLite, which compares a value with a column of numbers as the number it spells.
cast : [Postgres, Sqlite], Catalog.Column -> Str
cast = |dialect, column|
	if dialect == Sqlite {
		""
	} else {
		match column.base {
			"int2" => "::int2"
			"int4" => "::int4"
			"int8" => "::int8"
			"oid" => "::oid"
			"numeric" => "::numeric"
			"float4" => "::float4"
			"float8" => "::float8"
			"date" => "::date"
			"timestamp" => "::timestamp"
			"timestamptz" => "::timestamptz"
			"time" => "::time"
			_ => ""
		}
	}

test_column : Str, Str -> Catalog.Column
test_column = |name, base| { name, type: base, base, category: "S", nullable: Bool.True, defaulted: Bool.False, generated: Bool.False, comment: "", default: "", labels: [], choices: [], refers: Nothing }

test_table : Catalog.Table
test_table = { name: "books", comment: "", estimate: 0, columns: [test_column("id", "int8"), test_column("title", "text")], key: ["id"] }

public : Sql.On
public = { schema: "public", dialect: Postgres }

lite : Sql.On
lite = { schema: "main", dialect: Sqlite }

expect Sql.ident("users") == "\"users\""
expect Sql.ident("say \"hi\"") == "\"say \"\"hi\"\"\""
expect Sql.ident("a\u(0)b") == "\"ab\""
expect Sql.qualified("public", "order") == "\"public\".\"order\""
expect Sql.contains("50%_off\\") == "%50\\%\\_off\\\\%"
expect Sql.text_of(Postgres, test_column("at", "timestamptz"), "\"at\"") == "to_char(\"at\" at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS')"
expect Sql.cells(Postgres, [], 0) == "'[]'::text as \"cells\", '[]'::text as \"nulls\""
expect Sql.cells(Postgres, [test_column("id", "int8"), test_column("on", "date")], 80) == "array_to_json(array[left(coalesce(\"id\"::text, ''), 80), left(coalesce(to_char(\"on\", 'YYYY-MM-DD'), ''), 80)])::text as \"cells\", array_to_json(array[\"id\" is null, \"on\" is null])::text as \"nulls\""
expect {
	statement = Sql.rows(
		public,
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
	statement.sql == "select array_to_json(array[left(coalesce(\"id\"::text, ''), 81), coalesce(\"id\"::text, '')])::text as \"cells\", array_to_json(array[\"id\" is null, \"id\" is null])::text as \"nulls\" from \"public\".\"books\" where (\"title\" ilike $1 or \"id\"::text ilike $1) and \"state\" = $2 and \"note\" is null order by \"title\" desc, \"id\" limit $3 offset $4"
		and statement.params == [Text("%a\\_b%"), Text("x"), Int(50), Int(100)]
}
expect {
	statement = Sql.count(public, test_table, [Search([], "x")])
	statement.sql == "select array_to_json(array[count(*)::text])::text as \"cells\", '[]'::text as \"nulls\" from \"public\".\"books\"" and statement.params == []
}
expect {
	statement = Sql.insert(public, test_table, [(test_column("title", "text"), Text("Dune")), (test_column("note", "text"), Null)], [test_column("id", "int8")])
	statement.sql == "insert into \"public\".\"books\" (\"title\", \"note\") values ($1, $2) returning array_to_json(array[coalesce(\"id\"::text, '')])::text as \"cells\", array_to_json(array[\"id\" is null])::text as \"nulls\"" and statement.params == [Text("Dune"), Null]
}
expect Sql.insert({ schema: "s", dialect: Postgres }, test_table, [], []).sql == "insert into \"s\".\"books\" default values returning '[]'::text as \"cells\", '[]'::text as \"nulls\""
expect {
	statement = Sql.update(public, test_table, [(test_column("title", "text"), Text("Dune"))], [(test_column("id", "int8"), "7"), (test_column("lang", "text"), "en")])
	statement.sql == "update \"public\".\"books\" set \"title\" = $1 where \"id\" = $2 and \"lang\" = $3" and statement.params == [Text("Dune"), Text("7"), Text("en")]
}
expect Sql.delete(public, test_table, [(test_column("id", "int8"), "7")]) == { sql: "delete from \"public\".\"books\" where \"id\" = $1", params: [Text("7")] }
expect Sql.one(public, test_table, [test_column("id", "int8")], [(test_column("id", "int8"), "7")]).params == [Text("7")]
# A filter's conditions: a text it contains (its `%`, `_` and `\` as themselves), a range's ends cast to the column's type.
expect {
	statement = Sql.count(
		public,
		test_table,
		[
			Contains(test_column("title", "text"), "50%_off\\"),
			Contains(test_column("isbn", "uuid"), "0e5f"),
			AtLeast(test_column("price", "numeric"), "1.5"),
			AtMost(test_column("price", "numeric"), "20"),
			AtLeast(test_column("published_at", "timestamptz"), "2026-11-01T09:30+00"),
			AtMost(test_column("born", "date"), "2026-02-28"),
			AtLeast(test_column("pages", "int2"), "100"),
			AtMost(test_column("odd", "inet"), "x"),
			Equals(test_column("details", "jsonb"), "{}"),
			NotNull(test_column("mood", "mood")),
		],
	)
	statement.sql
		== "select array_to_json(array[count(*)::text])::text as \"cells\", '[]'::text as \"nulls\" from \"public\".\"books\" where \"title\" ilike $1 and \"isbn\"::text ilike $2 and \"price\" >= $3::numeric and \"price\" <= $4::numeric and \"published_at\" >= $5::timestamptz and \"born\" <= $6::date and \"pages\" >= $7::int2 and \"odd\" <= $8 and \"details\"::text = $9 and \"mood\" is not null"
		and statement.params == [Text("%50\\%\\_off\\\\%"), Text("%0e5f%"), Text("1.5"), Text("20"), Text("2026-11-01T09:30+00"), Text("2026-02-28"), Text("100"), Text("x"), Text("{}")]
}
# A column's name, quoted, in a range too.
expect Sql.count({ schema: "s", dialect: Postgres }, test_table, [AtLeast(test_column("a\"b", "int4"), "1")]).sql == "select array_to_json(array[count(*)::text])::text as \"cells\", '[]'::text as \"nulls\" from \"s\".\"books\" where \"a\"\"b\" >= $1::int4"
expect Sql.titles(public, test_table, test_column("id", "int8"), test_column("title", "text"), 201).sql == "select array_to_json(array[\"id\"::text, coalesce(\"title\"::text, \"id\"::text)])::text as \"cells\", '[]'::text as \"nulls\" from \"public\".\"books\" order by coalesce(\"title\"::text, \"id\"::text), \"id\" limit $1"

# On SQLite: the same statements, as SQLite writes them.
expect Sql.cells(Sqlite, [], 0) == "'[]' as \"cells\", '[]' as \"nulls\""
expect Sql.text_of(Sqlite, test_column("done", "bool"), "\"done\"") == "case when \"done\" is null then null when \"done\" then 'true' else 'false' end"
expect Sql.text_of(Sqlite, test_column("raw", "bytea"), "\"raw\"") == "'(' || length(\"raw\") || ' bytes)'"
expect {
	statement = Sql.rows(
		lite,
		test_table,
		{
			columns: [test_column("id", "int8")],
			whole: [test_column("id", "int8")],
			conditions: [Search([test_column("title", "text"), test_column("id", "int8")], "a_b"), Equals(test_column("done", "bool"), "true"), AtLeast(test_column("price", "float8"), "1.5")],
			order: [{ column: test_column("title", "text"), descending: Bool.True }],
			limit: 50,
			offset: 0,
			longest: 81,
		},
	)
	statement.sql == "select json_array(substr(coalesce(cast(\"id\" as text), ''), 1, 81), coalesce(cast(\"id\" as text), '')) as \"cells\", json_array(iif(\"id\" is null, json('true'), json('false')), iif(\"id\" is null, json('true'), json('false'))) as \"nulls\" from \"main\".\"books\" where (\"title\" like $1 escape '\\' or cast(\"id\" as text) like $1 escape '\\') and \"done\" = $2 and \"price\" >= $3 order by \"title\" desc limit $4 offset $5"
		and statement.params == [Text("%a\\_b%"), Int(1), Text("1.5"), Int(50), Int(0)]
}
expect Sql.count(lite, test_table, []).sql == "select json_array(cast(count(*) as text)) as \"cells\", '[]' as \"nulls\" from \"main\".\"books\""
# A boolean is written as 1 or 0 on SQLite, as the text Postgres reads on Postgres.
expect Sql.insert(lite, test_table, [(test_column("done", "bool"), Text("false")), (test_column("title", "text"), Text("true"))], []).params == [Int(0), Text("true")]
expect Sql.update(public, test_table, [(test_column("done", "bool"), Text("true"))], [(test_column("id", "int8"), "7")]).params == [Text("true"), Text("7")]
expect Sql.titles(lite, test_table, test_column("id", "int8"), test_column("title", "text"), 201).sql == "select json_array(cast(\"id\" as text), coalesce(cast(\"title\" as text), cast(\"id\" as text))) as \"cells\", '[]' as \"nulls\" from \"main\".\"books\" order by coalesce(cast(\"title\" as text), cast(\"id\" as text)), \"id\" limit $1"
