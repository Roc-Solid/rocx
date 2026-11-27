## The shape a real app met (an uptime monitor's `post_update!`): a transaction's body `?`s a
## database call, an alert callback typed with the annotation's `..others`, and returns its own
## `NotFound`. Should pass, for the same reason as Callback.roc.
Transaction := [].{
	run! : Str => Try(U64, [DbErr(Str), ..others])
	run! = |sql| if sql.is_empty() Err(DbErr("empty")) else Ok(1)

	transaction! : ({} => Try(a, [DbErr(Str), ..others])) => Try(a, [DbErr(Str), ..others])
	transaction! = |body!| body!({})

	post_update! : I64, (I64 => Try({}, [DbErr(Str), BadRow(Str), ..others])) => Try({}, [NotFound, DbErr(Str), BadRow(Str), ..others])
	post_update! = |id, alert!|
		transaction!(|{}| {
			changed = run!("update incidents set closed = 1 where id = ?")?
			if changed == 0 {
				Err(NotFound)
			} else {
				alert!(id)?
				Ok({})
			}
		})
}
