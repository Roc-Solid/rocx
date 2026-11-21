import Host

## Postgres, the platform's one database (`--database-url`, or `DATABASE_URL`).
##
## A statement's parameters are `$1`, `$2`, …, given as `Value`s; Postgres reads each as the type
## its place wants (`where id = $1` reads `Int(7)` as an integer). Rows come back as records:
## `all!` decodes each row's columns, by name, into the record its caller wants.
Db := [].{

	## A parameter.
	Value : [Null, Text(Str), Int(I64), Bool(Bool)]

	## Every row a statement reads, each a record of its columns.
	all! : Str, List(Value) => Try(List(row), [DbErr(Str), BadRow(Str)])
		where [row.Json.Parseable([InvalidJson(Str)])]
	all! = |sql, params|
		match Host.db_query!(sql, encoded(params)) {
			Ok(rows) =>
				match Json.parse(rows) {
					Ok(decoded) => Ok(decoded)
					Err(InvalidJson(why)) => Err(BadRow(why))
				}
			Err(why) => Err(DbErr(why))
		}

	## How many rows a statement changed (`insert`, `update`, `delete`), or the statement's
	## error.
	run! : Str, List(Value) => Try(U64, [DbErr(Str)])
	run! = |sql, params|
		match Host.db_execute!(sql, encoded(params)) {
			Ok(count) => Ok(count)
			Err(why) => Err(DbErr(why))
		}

	## Runs `sql`, one statement after another (`;` between them), with no parameters: a schema,
	## a migration. They run as one transaction: if one fails, none stays.
	script! : Str => Try({}, [DbErr(Str)])
	script! = |sql|
		match Host.db_script!(sql) {
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
