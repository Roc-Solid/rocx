## The tables of a schema as the database's catalog describes them, read when a page is asked for,
## so the admin needs no generated code: each table's columns, their types, which may be null, which
## have defaults or are computed, the primary key, foreign keys, enums, and a check that a column
## is one of a few values (`check (state in ('draft', 'sent'))`), which is a choice as an enum is.
## Postgres's catalog (`pg_class`, `pg_attribute`, …), or SQLite's (`pragma_table_list`,
## `pragma_table_xinfo`, `pragma_foreign_key_list`, and the checks read from each table's
## `create table`), its declared types read as Postgres's names (`integer` is `int8`), so the rest
## of the admin is the same on both (D-045).
##
## Every statement the admin runs answers with rows of one shape (`Raw`: each cell as text, and
## whether it was null, as JSON text), so one `Db.all!` reads them all; `parsed` makes each a `Row`.
Catalog := [].{

	## A row as every statement of the admin's answers it: `array_to_json(array[…])::text as "cells"`
	## (SQLite's `json_array(…)`), and which of them were null (`"nulls"`; `[]` when none can be),
	## each a JSON array, as text.
	Raw : { cells : Str, nulls : Str }

	## A row, read: each cell as text, and whether it was null.
	Row : { cells : List(Str), nulls : List(Bool) }

	## A row as the statement gave it, read (an array that isn't one is none).
	parsed : Raw -> Row
	parsed = |raw| {
		cells : List(Str)
		cells = Json.parse(raw.cells) ?? []
		nulls : List(Bool)
		nulls = Json.parse(raw.nulls) ?? []
		{ cells, nulls }
	}

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
				"select array_to_json(array[c.relname::text, c.reltuples::int8::text, coalesce(obj_description(c.oid, 'pg_class'), '')])::text as \"cells\", '[]'::text as \"nulls\"",
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
				"    coalesce(pg_get_expr(d.adbin, d.adrelid), '')])::text as \"cells\", '[]'::text as \"nulls\"",
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
				"select array_to_json(array[c.relname::text, a.attname::text, e.enumlabel::text])::text as \"cells\", '[]'::text as \"nulls\"",
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
				"    coalesce(fa.attname::text, ''), cardinality(k.conkey)::text, pg_get_constraintdef(k.oid)])::text as \"cells\", '[]'::text as \"nulls\"",
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

	## SQLite's tables (`$1`: the schema, `main`), but its own (`sqlite_…`, and Turso's
	## `__turso_internal_…`) and a full-text index's (virtual, and their shadows): its name, no
	## estimate (-1), no comment, and its `create table`, whose checks `read_sqlite` reads.
	sqlite_tables_sql : Str
	sqlite_tables_sql =
		Str.join_with(
			[
				"select json_array(t.name, '-1', '', coalesce(m.sql, '')) as \"cells\", '[]' as \"nulls\"",
				"from pragma_table_list t join sqlite_schema m on m.name = t.name and m.type = 'table'",
				"where t.schema = $1 and t.type = 'table' and t.name not like 'sqlite\\_%' escape '\\' and t.name not like '\\_\\_turso\\_internal\\_%' escape '\\'",
				"order by t.name",
			],
			"\n",
		)

	## Every column of SQLite's tables (`$1`: the schema), in order, in `columns_sql`'s cells: its
	## declared type for its type, base and category alike (`read_sqlite` reads them), whether it
	## may be null (not a key's), has a default (or is the table's integer key, its rowid), is
	## generated; no comment; its default as SQLite wrote it.
	sqlite_columns_sql : Str
	sqlite_columns_sql =
		Str.join_with(
			[
				"select json_array(t.name, c.name, c.type, c.type, '',",
				"    iif(c.\"notnull\" = 0 and c.pk = 0, 'true', 'false'),",
				"    iif(c.dflt_value is not null or (c.pk = 1 and lower(c.type) = 'integer' and (select count(*) from pragma_table_info(t.name) k where k.pk > 0) = 1), 'true', 'false'),",
				"    iif(c.hidden in (2, 3), 'true', 'false'), '', coalesce(c.dflt_value, '')) as \"cells\", '[]' as \"nulls\"",
				"from pragma_table_list t join pragma_table_xinfo(t.name) c",
				"where t.schema = $1 and t.type = 'table' and t.name not like 'sqlite\\_%' escape '\\' and t.name not like '\\_\\_turso\\_internal\\_%' escape '\\' and c.hidden <> 1",
				"order by t.name, c.cid",
			],
			"\n",
		)

	## SQLite's primary keys and foreign keys (`$1`: the schema), in `constraints_sql`'s cells: a
	## key's columns in its order; a foreign key's column, the table it refers to and that table's
	## column ("" for its primary key), and how many columns it names.
	sqlite_constraints_sql : Str
	sqlite_constraints_sql =
		Str.join_with(
			[
				"select cells, '[]' as \"nulls\" from (",
				"    select json_array(t.name, t.name || '_pkey', 'p', c.name, '', '', '', '1', '') as cells, t.name as named, 0 as kind, c.pk as place",
				"    from pragma_table_list t join pragma_table_info(t.name) c",
				"    where t.schema = $1 and t.type = 'table' and t.name not like 'sqlite\\_%' escape '\\' and t.name not like '\\_\\_turso\\_internal\\_%' escape '\\' and c.pk > 0",
				"    union all",
				"    select json_array(t.name, t.name || '_fkey' || f.id, 'f', f.\"from\", f.\"table\", $1, coalesce(f.\"to\", ''),",
				"        cast((select count(*) from pragma_foreign_key_list(t.name) g where g.id = f.id) as text), '') as cells, t.name as named, 1 as kind, f.id * 1000 + f.seq as place",
				"    from pragma_table_list t join pragma_foreign_key_list(t.name) f",
				"    where t.schema = $1 and t.type = 'table' and t.name not like 'sqlite\\_%' escape '\\' and t.name not like '\\_\\_turso\\_internal\\_%' escape '\\'",
				") order by named, kind, place",
			],
			"\n",
		)

	## The tables of a SQLite schema, from the rows of `sqlite_tables_sql`, `sqlite_columns_sql`
	## and `sqlite_constraints_sql`, read as `read` reads Postgres's: each declared type as
	## Postgres's base and category (`sqlite_type`), a foreign key to a table's primary key named,
	## and each table's checks that a column is one of a few values (`checks_in`).
	read_sqlite : Str, { tables : List(Row), columns : List(Row), constraints : List(Row) } -> List(Table)
	read_sqlite = |schema, rows| {
		columns = rows.columns.map(
			|row| {
				typed = Catalog.sqlite_type(Catalog.cell(row, 2))
				{ ..row, cells: put(put(row.cells, 3, typed.base), 4, typed.category) }
			},
		)
		keys = rows.constraints.keep_if(|row| Catalog.cell(row, 2) == "p")
		foreign = rows.constraints.keep_if(|row| Catalog.cell(row, 2) == "f").map(
			|row|
				if Catalog.cell(row, 6).is_empty() {
					# No column named: the table's primary key's (its first, as the key is one column).
					target = Catalog.cell(row, 4)
					keyed = keys.find_first(|key| Catalog.cell(key, 0) == target).map_ok(|key| Catalog.cell(key, 3)) ?? ""
					{ ..row, cells: put(row.cells, 6, keyed) }
				} else {
					row
				},
		)
		checks = rows.tables.join_map(
			|each|
				Catalog.checks_in(Catalog.cell(each, 3)).map(
					|(checked, values)| {
						quoted = values.map(|value| "'${value.replace_each("'", "''")}'::text")
						{ cells: [Catalog.cell(each, 0), "${Catalog.cell(each, 0)}_${checked}_check", "c", checked, "", "", "", "1", "CHECK ((${checked} = ANY (ARRAY[${Str.join_with(quoted, ", ")}])))"], nulls: [] }
					},
				),
		)
		Catalog.read(schema, { tables: rows.tables, columns, enums: [], constraints: keys.concat(foreign).concat(checks) })
	}

	## A SQLite column's declared type (`integer`, `varchar(80)`, `boolean`, `json`) as the base and
	## category Postgres would give it, so a widget, a filter and a check read it as they read
	## Postgres's: by SQLite's own rules (a type with `int` in it is an integer; `char`, `clob` or
	## `text`, text; `real`, `floa` or `doub`, a real), and the names it has no rule for (`boolean`,
	## `date`, `datetime`, `timestamp`, `time`, `json`, `uuid`, `blob`); no type is text.
	sqlite_type : Str -> { base : Str, category : Str }
	sqlite_type = |declared| {
		named = (declared.split_first("(").map_ok(|parts| parts.before) ?? declared).trim().with_ascii_lowercased()
		holds = |part| named.contains(part)
		if named == "boolean" or named == "bool" {
			{ base: "bool", category: "B" }
		} else if named == "date" {
			{ base: "date", category: "D" }
		} else if named == "datetime" or named.starts_with("timestamp") {
			{ base: "timestamp", category: "D" }
		} else if named == "time" {
			{ base: "time", category: "D" }
		} else if named == "json" or named == "jsonb" {
			{ base: "json", category: "U" }
		} else if named == "uuid" {
			{ base: "uuid", category: "U" }
		} else if holds("int") {
			{ base: "int8", category: "N" }
		} else if named.is_empty() or holds("char") or holds("clob") or holds("text") {
			{ base: "text", category: "S" }
		} else if holds("blob") {
			{ base: "bytea", category: "U" }
		} else if holds("real") or holds("floa") or holds("doub") {
			{ base: "float8", category: "N" }
		} else {
			{ base: "numeric", category: "N" }
		}
	}

	## The columns a SQLite `create table` checks are one of a few values, each with its values:
	## `state text check (state in ('draft', 'sent'))`, or the same as a table's check. Any other
	## check (`price > 0`, an `in` of numbers, one of several columns) isn't one.
	checks_in : Str -> List((Str, List(Str)))
	checks_in = |sql| {
		bytes = sql.to_utf8()
		lower = bytes.map(|byte| if (byte >= 'A' and byte <= 'Z') byte + 32 else byte)
		var $found = []
		var $at = 0
		while $at < bytes.len() {
			before = if ($at == 0) ' ' else lower.get($at - 1) ?? ' '
			if starts_with_at(lower, $at, "check") and !is_word(before) {
				match check_at(bytes, lower, $at + 5) {
					Ok(found) => {
						$found = $found.append(found)
					}
					Err(_) => {}
				}
			} else {
				{}
			}
			$at = $at + 1
		}
		$found
	}

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

## `list` with `value` at `at` (as it was, past its end).
put : List(Str), U64, Str -> List(Str)
put = |list, at, value| list.set(at, value) ?? list

## Whether `bytes` has `word` (lower case) at `at`.
starts_with_at : List(U8), U64, Str -> Bool
starts_with_at = |bytes, at, word| {
	wanted = word.to_utf8()
	bytes.sublist({ start: at, len: wanted.len() }) == wanted
}

## Whether a byte may be in a name (a letter, a digit, `_`, or any of UTF-8's past ASCII).
is_word : U8 -> Bool
is_word = |byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '_' or byte >= 128

## Past spaces (and newlines, tabs) from `at`.
spaced : List(U8), U64 -> U64
spaced = |bytes, at| {
	var $at = at
	while [' ', '\n', '\t', '\r'].contains(bytes.get($at) ?? 'x') {
		$at = $at + 1
	}
	$at
}

## After `check` at `at`: `(column in ('a', 'b'))`, the column and its values; or not one.
check_at : List(U8), List(U8), U64 -> Try((Str, List(Str)), [NotOne])
check_at = |bytes, lower, start| {
	open = spaced(bytes, start)
	if (bytes.get(open) ?? ' ') != '(' {
		return Err(NotOne)
	}
	named = spaced(bytes, open + 1)
	# The column: a name, or a quoted one (`"state"`, its `""` a quote).
	(column, after_name) =
		if (bytes.get(named) ?? ' ') == '"' {
			var $item = []
			var $at = named + 1
			var $inside = Bool.True
			while $inside and $at < bytes.len() {
				byte = bytes.get($at) ?? '"'
				if byte == '"' and (bytes.get($at + 1) ?? ' ') == '"' {
					$item = $item.append('"')
					$at = $at + 2
				} else if byte == '"' {
					$inside = Bool.False
					$at = $at + 1
				} else {
					$item = $item.append(byte)
					$at = $at + 1
				}
			}
			(Str.from_utf8_lossy($item), $at)
		} else {
			var $at = named
			while is_word(bytes.get($at) ?? ' ') {
				$at = $at + 1
			}
			(Str.from_utf8_lossy(bytes.sublist({ start: named, len: $at - named })), $at)
		}
	keyword = spaced(bytes, after_name)
	if column.is_empty() or !starts_with_at(lower, keyword, "in") or is_word(bytes.get(keyword + 2) ?? ' ') {
		return Err(NotOne)
	}
	list = spaced(bytes, keyword + 2)
	if (bytes.get(list) ?? ' ') != '(' {
		return Err(NotOne)
	}
	# Quoted values, a comma between each, to the list's `)`.
	var $values = []
	var $at = spaced(bytes, list + 1)
	var $going = Bool.True
	var $whole = Bool.True
	while $going {
		if (bytes.get($at) ?? ' ') != '\'' {
			$going = Bool.False
			$whole = Bool.False
		} else {
			var $item = []
			var $inside = Bool.True
			$at = $at + 1
			while $inside and $at < bytes.len() {
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
			$values = $values.append(Str.from_utf8_lossy($item))
			$at = spaced(bytes, $at)
			if (bytes.get($at) ?? ' ') == ',' {
				$at = spaced(bytes, $at + 1)
			} else {
				$going = Bool.False
			}
		}
	}
	closed = spaced(bytes, $at + 1)
	if $whole and (bytes.get($at) ?? ' ') == ')' and (bytes.get(closed) ?? ' ') == ')' and !$values.is_empty() {
		Ok((column, $values))
	} else {
		Err(NotOne)
	}
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

expect Catalog.sqlite_type("INTEGER") == { base: "int8", category: "N" }
expect Catalog.sqlite_type("varchar(80)") == { base: "text", category: "S" }
expect Catalog.sqlite_type("boolean") == { base: "bool", category: "B" }
expect Catalog.sqlite_type("real") == { base: "float8", category: "N" }
expect Catalog.sqlite_type("json") == { base: "json", category: "U" }
expect Catalog.sqlite_type("timestamptz") == { base: "timestamp", category: "D" }
expect Catalog.sqlite_type("") == { base: "text", category: "S" }
expect Catalog.sqlite_type("numeric(8, 2)") == { base: "numeric", category: "N" }
expect Catalog.checks_in("create table t (\n\tid integer primary key,\n\tstate text not null default 'draft' CHECK (state IN ('draft', 'it''s')),\n\tprice real check (price > 0),\n\tsize integer check (size in (1, 2)),\n\t\"kind\" text,\n\tcheck(\"kind\" in ('a,b'))\n)") == [("state", ["draft", "it's"]), ("kind", ["a,b"])]
expect Catalog.checks_in("create table t (x text) -- unchecked") == []
expect Catalog.parsed({ cells: "[\"1\",\"a\"]", nulls: "[false,true]" }) == { cells: ["1", "a"], nulls: [Bool.False, Bool.True] }
expect Catalog.parsed({ cells: "not json", nulls: "[]" }) == { cells: [], nulls: [] }

expect {
	row = |cells| { cells, nulls: [] }
	tables = Catalog.read_sqlite(
		"main",
		{
			tables: [row(["authors", "-1", "", "create table authors (id integer primary key, name text not null)"]), row(["books", "-1", "", "create table books (id integer primary key, author_id integer references authors, state text not null default 'draft' check (state in ('draft', 'sold')), done boolean not null default false)"])],
			columns: [
				row(["authors", "id", "integer", "integer", "", "false", "true", "false", "", ""]),
				row(["authors", "name", "text", "text", "", "false", "false", "false", "", ""]),
				row(["books", "id", "integer", "integer", "", "false", "true", "false", "", ""]),
				row(["books", "author_id", "integer", "integer", "", "true", "false", "false", "", ""]),
				row(["books", "state", "text", "text", "", "false", "true", "false", "", "'draft'"]),
				row(["books", "done", "boolean", "boolean", "", "false", "true", "false", "", "false"]),
			],
			constraints: [
				row(["authors", "authors_pkey", "p", "id", "", "", "", "1", ""]),
				row(["books", "books_pkey", "p", "id", "", "", "", "1", ""]),
				row(["books", "books_fkey0", "f", "author_id", "authors", "main", "", "1", ""]),
			],
		},
	)
	books = Catalog.table(tables, "books") ?? { name: "", comment: "", estimate: 0, columns: [], key: [] }
	author_id = Catalog.column(books, "author_id") ?? { name: "", type: "", base: "", category: "", nullable: Bool.False, defaulted: Bool.False, generated: Bool.False, comment: "", default: "", labels: [], choices: [], refers: Nothing }
	state = Catalog.column(books, "state") ?? author_id
	done = Catalog.column(books, "done") ?? author_id
	id = Catalog.column(books, "id") ?? author_id
	tables.len() == 2 and books.key == ["id"] and author_id.refers == To({ table: "authors", column: "id" }) and author_id.base == "int8" and state.choices == ["draft", "sold"] and done.base == "bool" and done.category == "B" and id.defaulted and !id.nullable
}
