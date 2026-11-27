## `roc check Hoisted.roc` passes: `to_str` called in the body, outside the getter.
import ErrorPage

Hoisted := [].{
	root! : U16 => Str
	root! = |code| ErrorPage.hoisted_view!({ status: || code })
}
