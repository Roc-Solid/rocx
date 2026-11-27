## Must stay rejected: the callback may fail with any tag its caller chose (`..others`), and this
## result lists only NotFound and DbErr.
Unlisted := [].{
	save : (I64 -> Try({}, [DbErr(Str), ..others])) -> Try({}, [NotFound, DbErr(Str)])
	save = |step| {
		step(1)?
		Err(NotFound)
	}
}
