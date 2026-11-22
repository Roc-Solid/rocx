import Html

## `<Errored fallback={|problem, retry| …}>…</Errored>`: when something inside fails, the fallback,
## given why and a handler that tries again.
Errored := [].{

	## What `<Errored>` is: its children, or, once something inside fails, the fallback, given why
	## and a handler that renders the children again.
	view! : { fallback : Str, (() => {}) -> Html, children : List(Html) } => Html
	view! = |{ fallback, children }| Html.errored(fallback, children)

	## The HTTP status a failure stands for: a read an endpoint refused with a status from 400 to 499
	## (`Endpoint.get!`'s failure, `GET /notes/9: 404: Not found`) is that status; anything else
	## (a 5xx, no answer, an answer that isn't the type, a failure of the page's own) is 500. The
	## app's root `<Errored>` (rocx writes it) answers its error page with it, so a page whose data
	## isn't there is a 404, as a path no page has is.
	status_of : Str -> U16
	status_of = |problem|
		match problem.split_first(" ") {
			Ok({ before: method, after }) =>
				if method.is_empty() or !method.to_utf8().all(|byte| byte >= 'A' and byte <= 'Z') or !after.starts_with("/") {
					500
				} else {
					match after.split_first(": ") {
						Ok({ after: rest, .. }) =>
							match rest.split_first(": ") {
								Ok({ before: code, .. }) => refused_status(code)
								Err(_) => 500
							}
						Err(_) => 500
					}
				}
			Err(_) => 500
		}
}

## A refusal's status, when it is three digits from 400 to 499; 500 otherwise.
refused_status : Str -> U16
refused_status = |code| {
	status = if (code.count_utf8_bytes() == 3) U16.from_str(code) ?? 500 else 500
	if (status >= 400 and status <= 499) status else 500
}

expect Errored.status_of("GET /api/notes/9: 404: Not found") == 404
expect Errored.status_of("GET /lists/7?view=all: 403: Forbidden: not yours") == 403
expect Errored.status_of("GET /api/likes: 500: the database is down") == 500
expect Errored.status_of("GET /api/likes: 503: down") == 500
expect Errored.status_of("GET /api/likes: connection refused") == 500
expect Errored.status_of("nothing above provides Generated/BrokenPage.missing") == 500
expect Errored.status_of("a 404: Not found") == 500
expect Errored.status_of("") == 500
