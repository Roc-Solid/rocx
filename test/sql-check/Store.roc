import pf.Db

## What the check's tests read: each statement right, or wrong in the one way its comment says.
Store := [].{

	## Every statement run, and what each said: something for the server to answer.
	all! : {} => Str
	all! = |{}| {
		said = [
			Store.notes!(1).is_ok(),
			Store.typo!({}).is_ok(),
			Store.extra!(1).is_ok(),
			Store.later!({}).is_ok(),
			Store.picked!(["body"]).is_ok(),
			Store.listed!({}).is_ok(),
			Store.numbers!({}).is_ok(),
			Store.notes_plain!({}).is_ok(),
			Store.titled!({}).is_ok(),
		]
		Str.join_with(said.map(|ok| if (ok) "ok" else "failed"), " ")
	}

	## Right.
	notes! : I64 => Try(List({ id : I64, body : Str, note : Db.Nullable(Str), done : Bool }), [DbErr(Str), BadRow(Str)])
	notes! = |author| Db.all!("select id, body, note, done from notes where author = $1", [Int(author)])

	## Wrong: a column the table hasn't.
	typo! : {} => Try(List({ body : Str }), [DbErr(Str), BadRow(Str)])
	typo! = |{}| Db.all!("select bodyy as body from notes", [])

	## Wrong: two parameters given, one used.
	extra! : I64 => Try(U64, [DbErr(Str)])
	extra! = |id| Db.run!("delete from notes where id = $1", [Int(id), Int(id)])

	## Not checked: a table the app would make as it runs.
	later! : {} => Try(U64, [DbErr(Str)])
	later! = |{}| Db.run!(Db.unchecked("delete from made_later"), [])

	## Right: a row of the module's own type, read by the function's result.
	listed! : {} => Try(List(Row), [DbErr(Str), BadRow(Str)])
	listed! = |{}| Db.all!("select id, done, count(*) as n from notes group by id", [])

	## A row: its done, and something worked out (an expression, which the check can't type).
	Row : { id : I64, done : Bool, n : I64 }

	## Wrong: text read as a number.
	numbers! : {} => Try(List({ body : I64 }), [DbErr(Str), BadRow(Str)])
	numbers! = |{}| {
		rows : List({ body : I64 })
		rows = Db.all!("select body from notes", [])?
		Ok(rows)
	}

	## Wrong: a column that may be null read as a plain value.
	notes_plain! : {} => Try(List({ note : Str }), [DbErr(Str), BadRow(Str)])
	notes_plain! = |{}| {
		rows : List({ note : Str })
		rows = Db.all!("select note from notes", [])?
		Ok(rows)
	}

	## Wrong: a field the statement doesn't return.
	titled! : {} => Try(List({ id : I64, title : Str }), [DbErr(Str), BadRow(Str)])
	titled! = |{}| {
		rows : List({ id : I64, title : Str })
		rows = Db.all!("select id from notes", [])?
		Ok(rows)
	}

	## Not checked: its SQL is put together.
	picked! : List(Str) => Try(List({ body : Str }), [DbErr(Str), BadRow(Str)])
	picked! = |columns| Db.all!("select ${Str.join_with(columns, ", ")} from notes", [])
}
