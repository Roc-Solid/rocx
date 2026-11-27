## The cause, in one module: `roc check Shared.roc` fails. `show` stores a callback in a list
## whose items are `() => Str`; the callback calls `f`, which `show` takes. `show` should be
## generic in `f`'s argument, so `small` (U8) and `large` (U16) should both check. They don't:
## the callback's effect formula (it depends on `f`) is kept on the type it meets, `keep`'s
## list item, which every use of `keep` shares, so `f` and `n` are held at that type's rank
## and `show` doesn't generalize over them. The first caller fixes `n` for the second.
Shared := [].{
	keep : List(() => Str) -> Str
	keep = |_| "kept"

	show = |f, n| keep([|| f(n)])

	small : (U8 -> Str), U8 -> Str
	small = |g, x| show(g, x)

	large : (U16 -> Str), U16 -> Str
	large = |g, x| show(g, x)
}
