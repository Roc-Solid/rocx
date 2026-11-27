## The callback's call is the body's value, after a `?` of the function's own. Should pass.
TailCall := [].{
	lookup : I64 -> Try(I64, [NotFound])
	lookup = |n| if n == 0 Err(NotFound) else Ok(n)

	save : (I64 -> Try({}, [DbErr(Str), ..others])) -> Try({}, [NotFound, DbErr(Str), ..others])
	save = |step| {
		n = lookup(1)?
		step(n)
	}
}
