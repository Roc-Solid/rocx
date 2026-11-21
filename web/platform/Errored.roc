import Html

## `<Errored fallback={|problem, retry| …}>…</Errored>`: when something inside fails, the fallback,
## given why and a handler that tries again.
Errored := [].{
	view! : { fallback : Str, (() => {}) -> Html, children : List(Html) } => Html
	view! = |{ fallback, children }| Html.errored(fallback, children)
}
