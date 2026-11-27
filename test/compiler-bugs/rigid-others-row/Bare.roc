## Control: the same as Callback.roc with DbErr dropped from both rows, so the callback's whole
## row is the rigid `e`. Passes on every compiler tried.
Bare := [].{
	save : (I64 -> Try({}, e)) -> Try({}, [NotFound, ..e])
	save = |step| {
		step(1)?
		Err(NotFound)
	}
}
