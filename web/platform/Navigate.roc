import Html
import Solid
import Router

## `<Navigate>`, Solid Router's: rendering it sends the visitor to `href` (D-040). In the browser it
## navigates there after the flush that rendered it, replacing the history entry (in place when
## `href` is one of the app's pages, as `Router.navigate_with!` does); on the server, the page
## answers with a 303 to `href` instead, as a redirect met while it renders does (D-019). So a page
## can decide where the visitor goes as it renders, which a handler's `Router.navigate!` can't:
##
##     <Show when!={signed_in!()} fallback={<Navigate href={Paths.sign_in} />}>…</Show>
##
## A guard that must hold is the server's middleware's: `<Navigate>` is for what the page decides.
## This is the browser's; the server platform's is its own (`server/platform/Navigate.roc`).
Navigate := [].{

	## What `<Navigate href={…} />` is: nothing on the page, and the visitor sent to `href`.
	view! : { href : Str } => Html
	view! = |{ href }| {
		Solid.create_effect!(|| href, |to| Router.navigate_with!(to, { replace: Bool.True, scroll: Bool.True }))
		Html.empty({})
	}
}
