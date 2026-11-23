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

	## Not checked: its SQL is put together.
	picked! : List(Str) => Try(List({ body : Str }), [DbErr(Str), BadRow(Str)])
	picked! = |columns| Db.all!("select ${Str.join_with(columns, ", ")} from notes", [])
}
