## Controls that pass on every compiler: the numeral passed to `f` directly in `v`'s body, and the
## local `k` holding the call's result rather than a closure.
Direct := [].{
	direct = |f| f(1)

	held = |f| {
		k = f(1)
		k
	}

	small : (U8 -> Str) -> Str
	small = |g| direct(g)

	large : (U16 -> Str) -> Str
	large = |g| held(g)
}
