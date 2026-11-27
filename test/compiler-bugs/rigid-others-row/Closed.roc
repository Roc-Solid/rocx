## Control: the same as Callback.roc with both rows closed. Passes on every compiler tried (the
## `?` includes a closed row's tags in the wider result).
Closed := [].{
	save : (I64 -> Try({}, [DbErr(Str)])) -> Try({}, [NotFound, DbErr(Str)])
	save = |step| {
		step(1)?
		Err(NotFound)
	}
}
