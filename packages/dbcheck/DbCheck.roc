import Probe

## A statement's rows checked against what the database said of its columns, when the app is
## compiled (D-058): `rocx check --sql` writes a line for each `Db.all!` or `Db.one!` (D-096)
## whose row type it can name,
##
## ```roc
## ## examples/plate/Store.roc:122:11
## q1 : DbCheck.Rows({ id : I64, fiber : Db.Nullable(Dec) }, Tags)
## q1 = "examples/plate/Store.roc:122:11\tsqlite\nid\tinteger\tINTEGER\tfoods.id\tyes\nfiber\treal\tREAL\tfoods.fiber\tno"
## ```
##
## and the compiler runs `Rows.from_quote` on the string: the row's fields (`Probe`) against the
## columns, a refusal a compile error that names the call.
DbCheck := [].{

	## A column as the engine described it: its name, how the host reads it (`integer`, `real`,
	## `text`, `boolean`, `json`, `any`, `blob`, `unreadable`, or `` for an expression the engine
	## doesn't type), its type as the engine names it, the table column it comes from (`notes.body`,
	## or ``) and whether that is `not null` (`yes`, `no`, or ``).
	Column : { name : Str, kind : Str, type : Str, origin : Str, not_null : Str }

	## What the database said of a statement, as rocx writes it: where its call is and the engine on
	## its first line, then a line a column, its parts between tabs.
	Description : { at : Str, engine : Str, columns : List(Column) }

	## The rows of the call at `at`, checked. `tags`'s `names` are the names a tag union in the row is
	## tried with (`Probe`): the capitalized words in the app's code.
	Rows(rows, tags) :: { at : Str }.{

		## The check, at compile time: `Err` names the call and says what is wrong with each field.
		from_quote : Str -> Try(Rows(rows, tags), [BadQuotedBytes(Str)])
			where [
				rows.parser_for : Probe -> (Probe.State -> Try({ value : rows, rest : Probe.State }, Probe.Problem)),
				tags.names : {} -> List(Str),
			]
		from_quote = |text| {
			Row : rows
			Tags : tags
			names = Tags.names({})
			described = DbCheck.description(text)
			nulls = Row.parser_for(Probe.Nulls)(Probe.start(names))
			kinds = Row.parser_for(Probe.Kinds)(Probe.start(names))
			# A row the probe can't read (a tag union none of the names are tags of) isn't checked.
			fields = Probe.fields(nulls, kinds) ?? []
			wrong = DbCheck.problems(fields, described.columns, described.engine)
			if wrong.is_empty() {
				Ok(Rows.{ at: described.at })
			} else {
				Err(BadQuotedBytes("${described.at}: ${Str.join_with(wrong, "; ")}"))
			}
		}

		## Where the call is.
		at : Rows(rows, tags) -> Str
		at = |checked| checked.at
	}

	## A description, from rocx's text.
	description : Str -> Description
	description = |text| {
		lines = text.split_on("\n")
		head = (lines.first() ?? "").split_on("\t")
		columns = lines.drop_first(1).keep_if(|line| !line.is_empty()).map(
			|line| {
				part = |i| line.split_on("\t").get(i) ?? ""
				{ name: part(0), kind: part(1), type: part(2), origin: part(3), not_null: part(4) }
			},
		)
		{ at: head.first() ?? "", engine: head.get(1) ?? "", columns }
	}

	## What is wrong with each of `fields` (the row's) read from `columns` (the statement's): a field
	## the statement doesn't return, a type its column's values can't decode into, or a plain field
	## over a column that may be null.
	problems : List(Probe.Field), List(Column), Str -> List(Str)
	problems = |fields, columns, engine| {
		returned = Str.join_with(columns.map(|column| column.name), ", ")
		fields.join_map(
			|field|
				match columns.find_first(|column| column.name == field.name) {
					Err(_) => ["`${field.name}` isn't a column the statement returns (it returns ${returned})"]
					Ok(column) => {
						shown = if (column.origin.is_empty()) "the column" else column.origin
						typed =
							if DbCheck.fits(field.kind, column.kind) {
								[]
							} else if column.kind == "blob" or column.kind == "unreadable" {
								["`${field.name}`: ${shown} is ${DbCheck.article(column.type)}, which Db can't read: cast it (${if (engine == "postgres") "`::text`" else "`hex(…)`"})"]
							} else {
								["`${field.name}` is read as ${DbCheck.reads(field.kind)}, and ${shown} is ${DbCheck.article(column.type)} (${DbCheck.holds(column.kind)})"]
							}
						nulls =
							if !field.nullable and column.not_null == "no" {
								["`${field.name}` is read as a plain value, and ${shown} may be null (it has no `not null`): read it as Db.Nullable(…)"]
							} else {
								[]
							}
						typed.concat(nulls)
					}
				},
		)
	}

	## Whether a field whose type reads `field` (a `Probe.Field`'s kind) decodes a column of `column`
	## (a `Column`'s kind): what the host writes for it as JSON, Json reads into it.
	fits : Str, Str -> Bool
	fits = |field, column|
		if field.is_empty() or column.is_empty() or column == "json" or column == "any" {
			Bool.True
		} else {
			match column {
				"integer" => field == "integer" or field == "float"
				"real" => field == "float"
				"text" => field == "string" or field == "tags"
				"boolean" => field == "boolean"
				_ => Bool.False
			}
		}

	## What a field of a kind reads, in words.
	reads : Str -> Str
	reads = |field|
		match field {
			"integer" => "an integer"
			"float" => "a number"
			"string" => "text"
			"boolean" => "a Bool"
			"tags" => "a tag union"
			"json" => "a record or a list"
			other => other
		}

	## What a column of a kind holds, in words.
	holds : Str -> Str
	holds = |column|
		match column {
			"integer" => "integers"
			"real" => "numbers that may have a fraction"
			"text" => "text"
			"boolean" => "booleans"
			other => other
		}

	## A type with its article: `an INTEGER`, `a TEXT`.
	article : Str -> Str
	article = |name| {
		first = name.to_utf8().first() ?? 0
		vowel = [Str.to_utf8("a"), Str.to_utf8("e"), Str.to_utf8("i"), Str.to_utf8("o"), Str.to_utf8("u"), Str.to_utf8("A"), Str.to_utf8("E"), Str.to_utf8("I"), Str.to_utf8("O"), Str.to_utf8("U")].any(|bytes| bytes.first() == Ok(first))
		if (name.is_empty()) "an expression" else if (vowel) "an ${name}" else "a ${name}"
	}
}

expect DbCheck.description("S.roc:1:5\tsqlite\nid\tinteger\tINTEGER\tnotes.id\tyes\nmore\t\t\t\t\n") == { at: "S.roc:1:5", engine: "sqlite", columns: [{ name: "id", kind: "integer", type: "INTEGER", origin: "notes.id", not_null: "yes" }, { name: "more", kind: "", type: "", origin: "", not_null: "" }] }

expect {
	columns = DbCheck.description("S.roc:1:5\tsqlite\nid\tinteger\tINTEGER\tnotes.id\tyes\nbody\ttext\tTEXT\tnotes.body\tyes\nnote\ttext\tTEXT\tnotes.note\tno\nscore\treal\tREAL\tnotes.score\tno\nn\t\t\t\t").columns
	field = |name, kind, nullable| { name, kind, nullable }
	DbCheck.problems([field("id", "integer", Bool.False), field("body", "string", Bool.False), field("note", "string", Bool.True), field("score", "float", Bool.True), field("n", "integer", Bool.False)], columns, "sqlite")
		== []
		and DbCheck.problems([field("bodyy", "string", Bool.False)], columns, "sqlite")
			== ["`bodyy` isn't a column the statement returns (it returns id, body, note, score, n)"]
		and DbCheck.problems([field("body", "integer", Bool.False)], columns, "sqlite")
			== ["`body` is read as an integer, and notes.body is a TEXT (text)"]
		and DbCheck.problems([field("note", "string", Bool.False)], columns, "sqlite")
			== ["`note` is read as a plain value, and notes.note may be null (it has no `not null`): read it as Db.Nullable(…)"]
		and DbCheck.problems([field("score", "integer", Bool.True)], columns, "sqlite")
			== ["`score` is read as an integer, and notes.score is a REAL (numbers that may have a fraction)"]
}

expect {
	columns = DbCheck.description("S.roc:1:5\tpostgres\nprice\tunreadable\tnumeric\tbooks.price\tno").columns
	DbCheck.problems([{ name: "price", kind: "float", nullable: Bool.True }], columns, "postgres")
		== ["`price`: books.price is a numeric, which Db can't read: cast it (`::text`)"]
}
