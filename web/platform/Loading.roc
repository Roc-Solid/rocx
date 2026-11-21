import Html

## `<Loading fallback={…}>…</Loading>`: the fallback, until everything inside has its first values.
## Later, a change that waits keeps what is shown.
Loading := [].{
	view! : { fallback : Html, children : List(Html) } => Html
	view! = |{ fallback, children }| Html.loading(fallback, children)
}
