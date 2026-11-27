## `v` takes a function and calls it with the numeral `1` from inside a local closure `k`. `v`
## should be generic in that number: `(a -> b) -> b where a is a number`. Before the fix it is
## `(Dec -> b) -> b`: the numeral was defaulted at `k`'s generalization boundary, though its type is
## the argument type of `f`, a parameter of `v`. With no caller in this module, `roc check
## Nested.roc` passes either way; Caller.roc, in another module, shows the type.
Nested := [].{
	v = |f| {
		k = || f(1)
		k()
	}

	## The same with effectful functions.
	v! = |f!| {
		k! = || f!(1)
		k!()
	}

	## Control: the numeral is the receiver of `to_str`, so nothing outside `k` reaches its type.
	## It is still defaulted to Dec at `k`'s boundary, and `local` is `(Str -> b) -> b`.
	local = |f| {
		k = || f(1.to_str())
		k()
	}
}
