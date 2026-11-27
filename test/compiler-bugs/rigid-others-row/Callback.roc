## A `?` on a callback whose error row ends in the annotation's `..others`, in a function whose
## result adds its own `NotFound` beside that row. Should pass: every error the callback can
## return is in the result (DbErr is listed, and `..others` is the result's own tail).
Callback := [].{
	save : (I64 -> Try({}, [DbErr(Str), ..others])) -> Try({}, [NotFound, DbErr(Str), ..others])
	save = |step| {
		step(1)?
		Err(NotFound)
	}
}
