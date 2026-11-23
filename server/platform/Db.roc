import Host

## The app's database: Postgres, SQLite or Turso, as its program says (`database`, D-045, D-046).
## Its SQL is the app's, in its database's flavor: nothing is translated.
##
## - Postgres is at `--database-url` (or `DATABASE_URL`); without one the app has no database.
## - SQLite is a file in the server's process, at the program's `Sqlite(path)` (or a `sqlite:<path>`
##   `--database-url`), made when missing. Reads go on while a write does; writes take turns. So keep
##   anything slow (`Http.fetch!`, a wait) out of a transaction: on SQLite it holds every other write
##   back until it ends.
## - Turso is SQLite written again in Rust: the same SQL, at the program's `Turso(path)` (or a
##   `turso:<path>` `--database-url`, which runs a SQLite app on Turso too). Its writes go on at
##   once (MVCC, D-049): each transaction on a snapshot of its own, one that loses to another's
##   write to the same row run again (`transaction!`). The server keeps the file to itself while it
##   runs, and in MVCC mode it is Turso's alone (`turso:<path>?mvcc=off` once gives it back to
##   SQLite, its writes then taking turns); no FTS5.
##
## A statement's parameters are `$1`, `$2`, …, given as `Value`s, in both. Postgres reads each as the
## type its place wants (`where id = $1` reads `Int(7)` as an integer); SQLite is given each as it
## is (a `Bool` as 1 or 0). Rows come back as records: `all!` decodes each row's columns, by name,
## into the record its caller wants. A column that may be null is read as `Nullable(a)`:
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
## SQLite has no types of its own for a boolean, a time or JSON: a column declared `boolean` is read
## as a `Bool`, one declared `json` as its JSON, and a boolean worked out in a statement
## (`exists (…)`) is 0 or 1, an `I64`. A time is best kept as milliseconds (`Time.now_millis!`).
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

	## A list as one parameter, on Postgres: an array, sent as Postgres writes one in text
	## (`{"work","to do",NULL}`), which it reads as the array its place wants, of text or of numbers
	## alike: `where tag = any($1)`, `where tags @> $1`, `$1::bigint[]`, `unnest($1::text[])` (a
	## place that doesn't say which array, as `unnest($1)` alone, needs the cast). Each `Text` is
	## quoted, its `"` and `\` escaped, so a comma, a brace, a space or the word NULL in one stays
	## text; `Null` is a null; an `Int` and a `Bool` are as Postgres writes them (`-7`, `t`, `f`); an
	## empty list is `{}`.
	##
	## ```roc
	## tagged : Try(List({ id : I64 }), [DbErr(Str), BadRow(Str)])
	## tagged = Db.all!("select id from notes where tags @> $1", [Db.array(tags.map(|tag| Text(tag)))])
	## ```
	##
	## SQLite has no arrays: a list is JSON text there, read with `json_each`
	## (`where tag in (select value from json_each($1))`).
	array : List(Value) -> Value
	array = |items| {
		each = items.map(
			|item|
				match item {
					Null => "NULL"
					Text(text) => "\"${text.replace_each("\\", "\\\\").replace_each("\"", "\\\"")}\""
					Int(number) => number.to_str()
					Bool(yes) => if (yes) "t" else "f"
				},
		)
		Text("{${Str.join_with(each, ",")}}")
	}

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

	## Whether the server has a database: a plugin that works without one (the job workers) does
	## nothing instead.
	connected! : {} => Bool
	connected! = |{}| !Host.db_flavor!({}).is_empty()

	## The database the server has, as its SQL: a package with SQL for both runs its flavor's.
	## Turso's SQL is SQLite's, so a Turso app's answer is `Sqlite` (`engine!` tells them apart).
	backend! : {} => [Postgres, Sqlite, None]
	backend! = |{}|
		match Host.db_flavor!({}) {
			"postgres" => Postgres
			"sqlite" => Sqlite
			"turso" => Sqlite
			_ => None
		}

	## The engine the server runs its statements on (D-046): Postgres, SQLite, or Turso (SQLite's SQL,
	## Turso's engine). For what one engine has and the other hasn't (SQLite's FTS5), and for saying
	## which: the SQL to run is `backend!`'s.
	engine! : {} => [Postgres, Sqlite, Turso, None]
	engine! = |{}|
		match Host.db_flavor!({}) {
			"postgres" => Postgres
			"sqlite" => Sqlite
			"turso" => Turso
			_ => None
		}

	## Tells `channel`'s listeners (`listen!`) `payload`: when this call's transaction commits (never,
	## if it rolls back), or at once outside one. On Postgres it is `pg_notify`, which other
	## processes hear too; on SQLite it is the server's own.
	notify! : Str, Str => Try({}, [DbErr(Str), ..others])
	notify! = |channel, payload|
		match Host.db_notify!(channel, payload) {
			Ok({}) => Ok({})
			Err(why) => Err(DbErr(why))
		}

	## From now until this call ends, it hears what is notified on `channel` (`notify!`, or
	## Postgres's `pg_notify` from anywhere) as messages on the topic `db:<channel>` (`Live.next!`):
	## how a background loop sleeps until there is work.
	listen! : Str => Try({}, [DbErr(Str), ..others])
	listen! = |channel|
		match Host.db_listen!(channel) {
			Ok({}) => Ok({})
			Err(why) => Err(DbErr(why))
		}

	## Runs `body!` in a transaction: what it writes, and the jobs it queues, stay only if it
	## returns `Ok`; an `Err` (or a crash) rolls all of it back. Its error is the body's, or the
	## database's. On SQLite it holds the write lock from its start (`begin immediate`): keep it
	## short. On Turso (D-049) transactions write at once, each on its own snapshot: one that loses
	## to another's write to the same row rolls back, and its body runs again after a short random
	## pause (up to 100 times), so keep what isn't the database's (a fetch, a message) out of it.
	transaction! : ({} => Try(a, [DbErr(Str), ..others])) => Try(a, [DbErr(Str), ..others])
	transaction! = |body!| attempted!(body!, 1)
}

## How many times `Db.transaction!` runs its body, each run lost to another's write (Turso).
attempts : U64
attempts = 100

## `Db.transaction!`'s run `tries` of `body!`, in a transaction of its own: again after one that
## lost to another's write (`Host.db_conflicted!`), while there are tries left.
attempted! : ({} => Try(a, [DbErr(Str), ..others])), U64 => Try(a, [DbErr(Str), ..others])
attempted! = |body!, tries|
	match Host.db_begin!({}) {
		Err(why) => Err(DbErr(why))
		Ok({}) => {
			ended =
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
			match ended {
				Ok(done) => Ok(done)
				Err(problem) => {
					again = tries < attempts and Host.db_conflicted!({})
					if again {
						attempted!(body!, tries + 1)
					} else {
						Err(problem)
					}
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

## The parameters as the host takes them: a JSON array of text, integers, booleans and nulls.
encoded : List(Db.Value) -> Str
encoded = |params| {
	each = params.map(
		|param|
			match param {
				Null => "null"
				Text(text) => Json.to_str(text)
				Int(number) => number.to_str()
				Bool(yes) => if (yes) "true" else "false"
			},
	)
	"[${Str.join_with(each, ",")}]"
}

expect Db.array([]) == Text("{}")
expect Db.array([Text("work"), Text("to do")]) == Text("{\"work\",\"to do\"}")
# A quote and a backslash are escaped; a comma, braces and a space stay inside the quotes.
expect Db.array([Text("say \"hi\""), Text("C:\\dir"), Text("a,b"), Text("{x}"), Text(" ")]) == Text("{\"say \\\"hi\\\"\",\"C:\\\\dir\",\"a,b\",\"{x}\",\" \"}")
# An empty text, a null, and the word NULL as text.
expect Db.array([Text(""), Null, Text("NULL")]) == Text("{\"\",NULL,\"NULL\"}")
expect Db.array([Text("zażółć ✓ 日本")]) == Text("{\"zażółć ✓ 日本\"}")
expect Db.array([Int(7), Int(-12), Int(9_000_000_000), Null]) == Text("{7,-12,9000000000,NULL}")
expect Db.array([Bool(Bool.True), Bool(Bool.False)]) == Text("{t,f}")
