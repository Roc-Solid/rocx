## `roc check Caller.roc` should pass: `Nested.v` is generic in the number it passes to `f`. Before
## the fix the first two calls fail: `Nested.v` and `Nested.v!` want a `Dec -> _ret`.
import Nested

Caller := [].{
	small : (U8 -> Str) -> Str
	small = |g| Nested.v(g)

	small! : (U8 => Str) => Str
	small! = |g!| Nested.v!(g!)

	shown : (Str -> Str) -> Str
	shown = |g| Nested.local(g)
}
