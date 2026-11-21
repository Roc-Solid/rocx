## The tables of a schema as Postgres's catalog describes them, read when a page is asked for, so
## the admin needs no generated code: each table's columns, their types, which may be null, which
## have defaults or are computed, the primary key, foreign keys, enums, and a check that a column
## is one of a few values (`check (state in ('draft', 'sent'))`), which is a choice as an enum is.
##
## Every statement the admin runs answers with rows of one shape (`Row`: each cell as text, and
## whether it was null), so one `Db.all!` reads them all.
Catalog := [].{

	## A row as every statement of the admin's answers it: `array_to_json(array[…]) as "cells"`, and
	## which of them were null (`"nulls"`; `[]` when none can be).
	Row : { cells : List(Str), nulls : List(Bool) }

	## A column of a table.
	##
	## - `type`: as Postgres writes it (`character varying(80)`, `timestamp with time zone`);
	##   `base`: its type's name, a domain's base type's (`varchar`, `timestamptz`, `int8`);
	##   `category`: Postgres's letter for the type's kind (`N` a number, `S` text, `B` a boolean,
	##   `D` a date or a time, `E` an enum, `A` an array, `U` json, uuid and others).
	## - `defaulted`: it has a default (or is an identity), so an insert may leave it out;
	##   `generated`: Postgres computes it (`generated always`), so nothing writes it.
	## - `default`: its default, as Postgres writes it (`'draft'::text`, `now()`; "" for none).
	## - `labels`: an enum's, in order; `choices`: the values a check allows it.
	## - `refers`: the column of another table of the schema it is a foreign key to.
	Column : {
		name : Str,
		type : Str,
		base : Str,
		category : Str,
		nullable : Bool,
		defaulted : Bool,
		generated : Bool,
		comment : Str,
		default : Str,
		labels : List(Str),
		choices : List(Str),
		refers : [Nothing, To({ table : Str, column : Str })],
	}

	## A table: its name, its comment (`comment on table`), about how many rows it has (Postgres's
	## estimate; -1 before it has looked), its columns in order, and its primary key's columns.
	Table : { name : Str, comment : Str, estimate : I64, columns : List(Column), key : List(Str) }

	## The schema's tables (`$1`: the schema): its name, estimated rows, comment.
	tables_sql : Str
	tables_sql =
		Str.join_with(
			[
				"select array_to_json(array[c.relname::text, c.reltuples::int8::text, coalesce(obj_description(c.oid, 'pg_class'), '')]) as \"cells\", '[]'::json as \"nulls\"",
				"from pg_class c join pg_namespace n on n.oid = c.relnamespace",
				"where n.nspname = $1 and c.relkind in ('r', 'p') and not c.relispartition",
				"order by c.relname",
			],
			"\n",
		)

	## Every column of the schema's tables (`$1`: the schema), in order.
	columns_sql : Str
	columns_sql =
		Str.join_with(
			[
				"select array_to_json(array[c.relname::text, a.attname::text, format_type(a.atttypid, a.atttypmod), coalesce(bt.typname, t.typname)::text, coalesce(bt.typcategory, t.typcategory)::text,",
				"    (not a.attnotnull)::text, (a.atthasdef or a.attidentity <> '')::text, (a.attidentity = 'a' or a.attgenerated <> '')::text, coalesce(col_description(c.oid, a.attnum), ''),",
				"    coalesce(pg_get_expr(d.adbin, d.adrelid), '')]) as \"cells\", '[]'::json as \"nulls\"",
				"from pg_attribute a",
				"join pg_class c on c.oid = a.attrelid",
				"join pg_namespace n on n.oid = c.relnamespace",
				"join pg_type t on t.oid = a.atttypid",
				"left join pg_type bt on t.typtype = 'd' and bt.oid = t.typbasetype",
				"left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum",
				"where n.nspname = $1 and c.relkind in ('r', 'p') and not c.relispartition and a.attnum > 0 and not a.attisdropped",
				"order by c.relname, a.attnum",
			],
			"\n",
		)

	## Each label of each enum column of the schema's tables (`$1`: the schema), in order.
	enums_sql : Str
	enums_sql =
		Str.join_with(
			[
				"select array_to_json(array[c.relname::text, a.attname::text, e.enumlabel::text]) as \"cells\", '[]'::json as \"nulls\"",
				"from pg_attribute a",
				"join pg_class c on c.oid = a.attrelid",
				"join pg_namespace n on n.oid = c.relnamespace",
				"join pg_enum e on e.enumtypid = a.atttypid",
				"where n.nspname = $1 and c.relkind in ('r', 'p') and not c.relispartition and a.attnum > 0 and not a.attisdropped",
				"order by c.relname, a.attnum, e.enumsortorder",
			],
			"\n",
		)

	## The primary keys, foreign keys and checks of the schema's tables (`$1`: the schema): a row
	## for each column each names, in order, with the table and column it refers to (a foreign
	## key's), its schema, how many columns it names, and its definition (a check's).
	constraints_sql : Str
	constraints_sql =
		Str.join_with(
			[
				"select array_to_json(array[c.relname::text, k.conname::text, k.contype::text, a.attname::text, coalesce(fc.relname::text, ''), coalesce(fn.nspname::text, ''),",
				"    coalesce(fa.attname::text, ''), cardinality(k.conkey)::text, pg_get_constraintdef(k.oid)]) as \"cells\", '[]'::json as \"nulls\"",
				"from pg_constraint k",
				"join pg_class c on c.oid = k.conrelid",
				"join pg_namespace n on n.oid = c.relnamespace",
				"cross join lateral unnest(k.conkey) with ordinality as named(attnum, place)",
				"join pg_attribute a on a.attrelid = k.conrelid and a.attnum = named.attnum",
				"left join pg_class fc on fc.oid = k.confrelid",
				"left join pg_namespace fn on fn.oid = fc.relnamespace",
				"left join pg_attribute fa on fa.attrelid = k.confrelid and fa.attnum = k.confkey[named.place]",
				"where n.nspname = $1 and k.contype in ('p', 'f', 'c') and c.relkind in ('r', 'p')",
				"order by c.relname, k.conname, named.place",
			],
			"\n",
		)

	## The tables of `schema`, from the rows of `tables_sql`, `columns_sql`, `enums_sql` and
	## `constraints_sql`. A foreign key or a check over several columns is left out: a column's
	## widget is its own.
	read : Str, { tables : List(Row), columns : List(Row), enums : List(Row), constraints : List(Row) } -> List(Table)
	read = |schema, rows|
		rows.tables.map(
			|table_row| {
				name = Catalog.cell(table_row, 0)
				constraints = rows.constraints.keep_if(|row| Catalog.cell(row, 0) == name)
				key = constraints.keep_if(|row| Catalog.cell(row, 2) == "p").map(|row| Catalog.cell(row, 3))
				single = |kind| constraints.keep_if(|row| Catalog.cell(row, 2) == kind and Catalog.cell(row, 7) == "1")
				foreign = single("f")
				checks = single("c")
				labels_of = |wanted| rows.enums.keep_if(|row| Catalog.cell(row, 0) == name and Catalog.cell(row, 1) == wanted).map(|row| Catalog.cell(row, 2))
				columns = rows.columns.keep_if(|row| Catalog.cell(row, 0) == name).map(
					|row| {
						called = Catalog.cell(row, 1)
						refers =
							match foreign.find_first(|each| Catalog.cell(each, 3) == called and Catalog.cell(each, 5) == schema) {
								Ok(each) => To({ table: Catalog.cell(each, 4), column: Catalog.cell(each, 6) })
								Err(_) => Nothing
							}
						choices =
							match checks.find_first(|each| Catalog.cell(each, 3) == called and !Catalog.choices_in(Catalog.cell(each, 8)).is_empty()) {
								Ok(each) => Catalog.choices_in(Catalog.cell(each, 8))
								Err(_) => []
							}
						{
							name: called,
							type: Catalog.cell(row, 2),
							base: Catalog.cell(row, 3),
							category: Catalog.cell(row, 4),
							nullable: Catalog.cell(row, 5) == "true",
							defaulted: Catalog.cell(row, 6) == "true",
							generated: Catalog.cell(row, 7) == "true",
							comment: Catalog.cell(row, 8),
							default: Catalog.cell(row, 9),
							labels: labels_of(called),
							choices,
							refers,
						}
					},
				)
				{ name, comment: Catalog.cell(table_row, 2), estimate: I64.from_str(Catalog.cell(table_row, 1)) ?? -1, columns, key }
			},
		)

	## The table called `name`, if the catalog has it.
	table : List(Table), Str -> Try(Table, [NotFound])
	table = |tables, name|
		match tables.find_first(|each| each.name == name) {
			Ok(found) => Ok(found)
			Err(_) => Err(NotFound)
		}

	## The column called `name`, if the table has it.
	column : Table, Str -> Try(Column, [NotFound])
	column = |of, name|
		match of.columns.find_first(|each| each.name == name) {
			Ok(found) => Ok(found)
			Err(_) => Err(NotFound)
		}

	## Cell `at` of a row ("" past its end).
	cell : Row, U64 -> Str
	cell = |row, at| row.cells.get(at) ?? ""

	## Whether cell `at` of a row was null.
	null_at : Row, U64 -> Bool
	null_at = |row, at| row.nulls.get(at) ?? Bool.False

	## The values a check allows a column, if it allows a few and nothing else, as Postgres writes
	## `check (state in ('draft', 'sent'))`: `CHECK ((state = ANY (ARRAY['draft'::text,
	## 'sent'::text])))`; `[]` for any other check.
	choices_in : Str -> List(Str)
	choices_in = |definition|
		if !definition.contains(" = ANY (") or definition.contains(" AND ") or definition.contains(" OR ") or definition.contains("NOT ") {
			[]
		} else {
			match definition.split_first("ARRAY[") {
				Ok({ after, .. }) => listed(after.to_utf8())
				Err(_) => []
			}
		}
}

## The values of an array's items (`'a'::text, 'it''s'::text]…`, or `1, 2]…`), up to its `]`.
listed : List(U8) -> List(Str)
listed = |bytes| {
	var $found = []
	var $at = 0
	var $going = Bool.True
	while $going {
		# Spaces and parentheses before an item.
		while (bytes.get($at) ?? ']') == ' ' or (bytes.get($at) ?? ']') == '(' {
			$at = $at + 1
		}
		if (bytes.get($at) ?? ']') == '\'' {
			# A quoted item, `''` a quote within it.
			var $item = []
			var $inside = Bool.True
			$at = $at + 1
			while $inside {
				byte = bytes.get($at) ?? '\''
				if byte == '\'' and (bytes.get($at + 1) ?? ' ') == '\'' {
					$item = $item.append('\'')
					$at = $at + 2
				} else if byte == '\'' {
					$inside = Bool.False
					$at = $at + 1
				} else {
					$item = $item.append(byte)
					$at = $at + 1
				}
			}
			$found = $found.append(Str.from_utf8_lossy($item))
		} else {
			# A bare item: up to its cast, a comma or the end.
			var $item = []
			while !([',', ']', ':', ')'].contains(bytes.get($at) ?? ']')) {
				$item = $item.append(bytes.get($at) ?? ' ')
				$at = $at + 1
			}
			text = Str.from_utf8_lossy($item).trim()
			$found = if (text.is_empty()) $found else $found.append(text)
		}
		# Past the item's cast and closing parentheses, to the next item or the end.
		while !([',', ']'].contains(bytes.get($at) ?? ']')) {
			$at = $at + 1
		}
		if (bytes.get($at) ?? ']') == ',' {
			$at = $at + 1
		} else {
			$going = Bool.False
		}
	}
	$found
}

expect Catalog.choices_in("CHECK ((state = ANY (ARRAY['queued'::text, 'running'::text, 'it''s'::text])))") == ["queued", "running", "it's"]
expect Catalog.choices_in("CHECK (((kind)::text = ANY ((ARRAY['a'::character varying, 'b, c'::character varying])::text[])))") == ["a", "b, c"]
expect Catalog.choices_in("CHECK ((size = ANY (ARRAY[1, 2, 3])))") == ["1", "2", "3"]
expect Catalog.choices_in("CHECK ((size = ANY (ARRAY[(1)::numeric, (2.5)::numeric])))") == ["1", "2.5"]
expect Catalog.choices_in("CHECK ((price > (0)::numeric))") == []
expect Catalog.choices_in("CHECK ((NOT (state = ANY (ARRAY['x'::text]))))") == []
expect Catalog.choices_in("CHECK (((state = ANY (ARRAY['a'::text])) OR (n > 1)))") == []
expect Catalog.choices_in("CHECK ((tag = ANY (ARRAY['a]b'::text])))") == ["a]b"]

expect {
	row = |cells| { cells, nulls: [] }
	tables = Catalog.read(
		"public",
		{
			tables: [row(["authors", "-1", ""]), row(["books", "12", "What we sell"])],
			columns: [
				row(["authors", "id", "bigint", "int8", "N", "false", "true", "false", ""]),
				row(["authors", "name", "text", "text", "S", "false", "false", "false", ""]),
				row(["books", "id", "bigint", "int8", "N", "false", "true", "false", ""]),
				row(["books", "author_id", "bigint", "int8", "N", "true", "false", "false", "Who wrote it"]),
				row(["books", "state", "text", "text", "S", "false", "true", "false", "", "'draft'::text"]),
				row(["books", "mood", "mood", "mood", "E", "true", "false", "false", ""]),
			],
			enums: [row(["books", "mood", "happy"]), row(["books", "mood", "sad"])],
			constraints: [
				row(["authors", "authors_pkey", "p", "id", "", "", "", "1", "PRIMARY KEY (id)"]),
				row(["books", "books_author_id_fkey", "f", "author_id", "authors", "public", "id", "1", "FOREIGN KEY (author_id) REFERENCES authors(id)"]),
				row(["books", "books_pkey", "p", "id", "", "", "", "1", "PRIMARY KEY (id)"]),
				row(["books", "books_state_check", "c", "state", "", "", "", "1", "CHECK ((state = ANY (ARRAY['draft'::text, 'sold'::text])))"]),
			],
		},
	)
	books = Catalog.table(tables, "books") ?? { name: "", comment: "", estimate: 0, columns: [], key: [] }
	author_id = Catalog.column(books, "author_id") ?? { name: "", type: "", base: "", category: "", nullable: Bool.False, defaulted: Bool.False, generated: Bool.False, comment: "", default: "", labels: [], choices: [], refers: Nothing }
	state = Catalog.column(books, "state") ?? author_id
	mood = Catalog.column(books, "mood") ?? author_id
	authors = Catalog.table(tables, "authors") ?? books
	tables.len() == 2 and books.key == ["id"] and books.estimate == 12 and books.comment == "What we sell" and authors.estimate == -1 and author_id.refers == To({ table: "authors", column: "id" }) and author_id.nullable and author_id.comment == "Who wrote it" and state.choices == ["draft", "sold"] and state.defaulted and state.default == "'draft'::text" and author_id.default == "" and mood.labels == ["happy", "sad"] and books.columns.len() == 4 and Catalog.column(books, "nope").is_err()
}
