## The one-module form: `roc check Shared.roc` should pass, `v` serving a U8 and a U16 caller.
## Before the fix both callers fail: `v` wants a `Dec -> _ret`.
Shared := [].{
	v = |f| {
		k = || f(1)
		k()
	}

	small : (U8 -> Str) -> Str
	small = |g| v(g)

	large : (U16 -> Str) -> Str
	large = |g| v(g)
}
