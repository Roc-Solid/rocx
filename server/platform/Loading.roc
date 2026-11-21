import Html

## `<Loading fallback={…}>…</Loading>`: the fallback, until everything inside has its first values.
## Later, a change that waits keeps what is shown.
Loading := [].{

	## What `<Loading>` is: the fallback until everything inside has its first values, then the
	## children.
	view! : { fallback : Html, children : List(Html) } => Html
	view! = |{ fallback, children }| Html.loading(fallback, children)
}
