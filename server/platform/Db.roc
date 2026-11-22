import Host

## Postgres, the platform's one database (`--database-url`, or `DATABASE_URL`).
##
## A statement's parameters are `$1`, `$2`, …, given as `Value`s; Postgres reads each as the type
## its place wants (`where id = $1` reads `Int(7)` as an integer). Rows come back as records:
## `all!` decodes each row's columns, by name, into the record its caller wants. A column that may
## be null is read as `Nullable(a)`:
##
## ```roc
## notes : Try(List({ id : I64, body : Str, note : Db.Nullable(Str) }), [DbErr(Str), BadRow(Str)])
## notes = Db.all!("select id, body, note from notes", [])
##
## match note.note {
##     Null => "-"
##     Some(text) => text
## }
## ```
##
## Each function's error is an open union (`[DbErr(Str), ..others]`), so a function `?`s a statement
## beside other errors (packages/jobs' `JobErr`, the app's own) with nothing mapped, and its caller
## matches each.
Db := [].{

	## A column that may be null: `Null`, or `Some(value)`. In JSON, `null` or the value as it is,
	## both ways, so a row (or anything else) holding one is read and written as JSON has it.
	Nullable(a) := [Null, Some(a)].{

		parser_for : encoding -> (state -> Try({ value : Nullable(a), rest : state }, err))
			where [
				a.parser_for : encoding -> (state -> Try({ value : a, rest : state }, err)),
				encoding.parse_null : encoding, state -> Try(state, err),
			]
		parser_for = |encoding| {
			Format : encoding
			Inner : a
			inner = Inner.parser_for(encoding)
			|state|
				match Format.parse_null(encoding, state) {
					Ok(rest) => Ok({ value: Null, rest })
					Err(_) => {
						parsed = inner(state)?
						Ok({ value: Some(parsed.value), rest: parsed.rest })
					}
				}
		}

		## Both `Null`, or both `Some` of equal values.
		is_eq : Nullable(a), Nullable(a) -> Bool
			where [a.is_eq : a, a -> Bool]
		is_eq = |one, other|
			match (one, other) {
				(Null, Null) => Bool.True
				(Some(x), Some(y)) => x == y
				_ => Bool.False
			}

		encoder_for : encoding -> (Nullable(a), state -> Try(state, err))
			where [
				a.encoder_for : encoding -> (a, state -> Try(state, err)),
				encoding.encode_null : state -> Try(state, err),
			]
		encoder_for = |encoding| {
			Format : encoding
			Inner : a
			inner = Inner.encoder_for(encoding)
			|value, state|
				match value {
					Null => Format.encode_null(state)
					Some(present) => inner(present, state)
				}
		}
	}

	## A parameter.
	Value : [Null, Text(Str), Int(I64), Bool(Bool)]

	## Every row a statement reads, each a record of its columns, by name. `BadRow` when a row
	## doesn't fit the record: a column it lacks, a value of another type, or a null in a column the
	## record doesn't read as `Nullable(a)` (the error names it).
	all! : Str, List(Value) => Try(List(row), [DbErr(Str), BadRow(Str), ..others])
		where [row.Json.Parseable([InvalidJson(Str)])]
	all! = |sql, params|
		match Host.db_query!(sql, encoded(params)) {
			Ok(rows) =>
				match Json.parse(rows) {
					Ok(decoded) => Ok(decoded)
					Err(InvalidJson(why)) => Err(BadRow(misread(rows, why)))
				}
			Err(why) => Err(DbErr(why))
		}

	## How many rows a statement changed (`insert`, `update`, `delete`), or the statement's
	## error.
	run! : Str, List(Value) => Try(U64, [DbErr(Str), ..others])
	run! = |sql, params|
		match Host.db_execute!(sql, encoded(params)) {
			Ok(count) => Ok(count)
			Err(why) => Err(DbErr(why))
		}

	## Runs `sql`, one statement after another (`;` between them), with no parameters: a schema,
	## a migration. They run as one transaction: if one fails, none stays.
	script! : Str => Try({}, [DbErr(Str), ..others])
	script! = |sql|
		match Host.db_script!(sql) {
			Ok({}) => Ok({})
			Err(why) => Err(DbErr(why))
		}

	## Whether the server has a database (`--database-url`, or `DATABASE_URL`): a plugin that
	## works without one (the job workers) does nothing instead.
	connected! : {} => Bool
	connected! = |{}| !Host.setting!("database").is_empty()

	## From now until this call ends, it hears Postgres's notifications on `channel` (`notify`,
	## sent when the transaction that sent them commits) as messages on the topic `pg:<channel>`
	## (`Live.next!`): how a background loop sleeps until there is work.
	listen! : Str => Try({}, [DbErr(Str), ..others])
	listen! = |channel|
		match Host.db_listen!(channel) {
			Ok({}) => Ok({})
			Err(why) => Err(DbErr(why))
		}

	## Runs `body!` in a transaction: what it writes, and the jobs it queues, stay only if it
	## returns `Ok`; an `Err` (or a crash) rolls all of it back. Its error is the body's, or the
	## database's.
	transaction! : ({} => Try(a, [DbErr(Str), ..others])) => Try(a, [DbErr(Str), ..others])
	transaction! = |body!|
		match Host.db_begin!({}) {
			Err(why) => Err(DbErr(why))
			Ok({}) =>
				match body!({}) {
					Ok(done) =>
						match Host.db_commit!({}) {
							Ok({}) => Ok(done)
							Err(why) => Err(DbErr(why))
						}
					Err(problem) => {
						Host.db_rollback!({})
						Err(problem)
					}
				}
		}
}

## Why the rows (as the host wrote them: compact JSON) didn't decode: `why`, and, when a column was
## null in some row, which, since a column read as a plain value can't be.
misread : Str, Str -> Str
misread = |rows, why| {
	segments = rows.split_on("\":null")
	nulls = segments.take_first(segments.len() - 1).keep_oks(
		|segment| {
			quoted = segment.split_on("\"")
			quoted.get(quoted.len() - 1)
		},
	)
	unique = nulls.fold([], |seen, name| if (seen.contains(name)) seen else seen.append(name))
	if unique.is_empty() {
		why
	} else {
		named = Str.join_with(unique.map(|name| "`${name}`"), ", ")
		"${why}: ${named} is null in a row; a column that may be null is read as Db.Nullable(a)"
	}
}

## The parameters as the host takes them: a JSON array of strings and nulls.
encoded : List(Db.Value) -> Str
encoded = |params| {
	each = params.map(
		|param|
			match param {
				Null => "null"
				Text(text) => Json.to_str(text)
				Int(number) => Json.to_str(number.to_str())
				Bool(yes) => if (yes) "\"true\"" else "\"false\""
			},
	)
	"[${Str.join_with(each, ",")}]"
}
