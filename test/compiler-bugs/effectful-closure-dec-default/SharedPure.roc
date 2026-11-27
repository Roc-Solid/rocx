## `roc check SharedPure.roc` passes: Shared.roc with the list's items pure, `() -> Str`.
SharedPure := [].{
	keep : List(() -> Str) -> Str
	keep = |_| "kept"

	show = |f, n| keep([|| f(n)])

	small : (U8 -> Str), U8 -> Str
	small = |g, x| show(g, x)

	large : (U16 -> Str), U16 -> Str
	large = |g, x| show(g, x)
}
