## `roc check Bad.roc` fails: ErrorPage.view! takes `{ status : () -> Dec }`, not a `U16`'s.
import ErrorPage

Bad := [].{
	root! : U16 => Str
	root! = |code| ErrorPage.view!({ status: || code })
}
