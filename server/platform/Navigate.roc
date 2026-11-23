import Host
import Html

## `<Navigate>`, Solid Router's: rendering it sends the visitor to `href` (D-040). On the server, the
## page answers with a 303 to `href` instead of itself, as a redirect met while it renders does
## (D-019: the first one the render meets); in the browser it navigates there after the flush that
## rendered it, replacing the history entry (`web/platform/Navigate.roc`, the browser's own).
##
##     <Show when!={signed_in!()} fallback={<Navigate href={Paths.sign_in} />}>…</Show>
##
## A guard that must hold is the server's middleware's: `<Navigate>` is for what the page decides.
Navigate := [].{

	## What `<Navigate href={…} />` is: nothing on the page, and the page a 303 to `href`.
	view! : { href : Str } => Html
	view! = |{ href }| {
		Host.redirect_page!(href)
		Html.empty({})
	}
}
