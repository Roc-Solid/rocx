## `roc check Pure.roc` passes: the same body, its getter checked against `() -> Str`.
import ErrorPage

Pure := [].{
	root : U16 -> Str
	root = |code| ErrorPage.pure_view({ status: || code })
}
