import Host
import Endpoint
import Submission
import Submissions
import Server

## Solid Router's, on both sides. Where the page is (`useLocation`): on the server, the request's
## path and query; in the browser, `location.pathname` and `location.search`. A trailing slash is
## dropped (`/syntax/` is `/syntax`), as the server drops it from what it answers. And submissions to
## an endpoint: the latest (`useSubmission`), all of them (`useSubmissions`), and a handler's own,
## without a form (`useAction`).
Router := [].{

	## The page's path (`/blog/rocx`) and its query (`page=2`, with no `?`; "" with none).
	Location : { path : Str, query : Str }

	## Where the page is: on the server, the request's path and query; in the browser,
	## `location`'s.
	location! : {} => Location
	location! = |{}| Router.parse(Host.location!({}))

	## A target (`/blog/rocx?page=2`) as a location.
	parse : Str -> Location
	parse = |target| {
		(path, query) =
			match target.split_first("?") {
				Ok({ before, after }) => (before, after)
				Err(_) => (target, "")
			}
		{ path: if (path.is_empty()) "/" else path, query }
	}

	## The latest submission of a form to `endpoint` (Solid Router's `useSubmission(action)`): its
	## `pending!()`, `input!()` (`field!(name)`), `result!()` and `error!()`. While the component that
	## asks is there, the runtime sends a `method="post"` form whose `action` is the endpoint's URL
	## (`Endpoint.url_of`) with `fetch`, and the page stays; without the runtime, the form posts,
	## and the endpoint sends the browser back to the page with a flash, which the submission is.
	##
	##     join = Api.post_members_join({})
	##     submission = use_submission!(join)
	##     <form method="post" action={Endpoint.url_of(join)}>…</form>
	use_submission! : Endpoint(context, arg, result) => Submission(arg, result)
	use_submission! = |endpoint| {
		url = Endpoint.base_of(endpoint)
		Host.action!(url)
		Submission.of(url, Endpoint.form_of(endpoint))
	}

	## Every submission to `endpoint`, each its own (Solid Router's `useSubmissions(action)`): its
	## forms' (sent with `fetch` while the component that asks is there, as `use_submission!`'s are)
	## and its actions' (`use_action!`). See `Submissions`.
	##
	##     moves = use_submissions!(Api.post_planner_move({}))
	##     <p class:saving={moves.pending!()}>…</p>
	use_submissions! : Endpoint(context, arg, result) => Submissions(arg, result)
	use_submissions! = |endpoint| {
		url = Endpoint.base_of(endpoint)
		Host.action!(url)
		Submissions.of(url, Endpoint.form_of(endpoint))
	}

	## Sends `endpoint` from a handler, without a form, and without the handler waiting for its
	## answer (Solid Router's `useAction(action)`): each call is a submission of its own, which
	## `use_submissions!` lists, sent once the handler is done (so a handler that waits for the server
	## and runs again sends it once). Its arg goes as JSON (`Endpoint.send!`'s request). A result
	## (200) has the page's reads read again before the submission is done; a refusal is its error
	## (the `error` of its record in `Submissions.all!`, or `Submission.error!` of the latest).
	##
	##     move! = use_action!(Api.post_planner_move({}))
	##     <li on:drop={|| move!({ card: dragged!(), day })}>…</li>
	##
	## Called from anywhere but a handler, its function fails; on the server, no handler runs.
	##
	## A top-level field of its arg holding the URL of a file the page has (one `on:drop.files`,
	## `on:paste.files` or `on:change.files` gave, `Html.File`'s `url`), or a list of them, sends the
	## file: the action goes as a form with files (`multipart/form-data`), its other fields as a
	## form's, and the endpoint reads the field as the file's name, its bytes with `Server.file`.
	use_action! : Endpoint(context, arg, result) => (arg => {}) where [arg.Json.Encodable(e)]
	use_action! = |endpoint| |arg| {
		request = Endpoint.to_request(endpoint, arg)
		input =
			match Json.to_str_try(arg) {
				Ok(json) => json
				Err(_) => crash "${request.method} ${request.url}: its arg ${Server.unwritable}"
			}
		Host.submit!(request.method, request.url, request.body, input)
	}

	## Which of the page's reads a submission's result reads again (Solid Router's `revalidate`
	## keys), each a URL (`Endpoint.url_of(Api.get_board({}))`): a GET the page read is read again
	## when its URL is one of them, or begins with one and a `/` or a `?` (`"/api/notes"`: every
	## note). Without it, a result reads every GET the page read again, as before; with `[]`, none, and
	## the submission is done at once.
	##
	## - In an endpoint's handler, on the server: said in its answer (`x-rocx-revalidate`), for the
	##   runtime that sent the submission (a form's, or an action's).
	##
	##       post! = |{ body, .. }| {
	##           Router.revalidate!([Endpoint.url_of(Api.get_board({}))])
	##           Ok(Board.moved!(body))
	##       }
	##
	## - In a handler, in the browser: those reads, read again now (Solid Router's `revalidate(keys)`),
	##   once the handler is done. Anywhere else in the browser it fails.
	revalidate! : List(Str) => {}
	revalidate! = |keys| Host.revalidate!(Json.to_str(keys))
}

expect Router.parse("/blog/rocx?page=2") == { path: "/blog/rocx", query: "page=2" }
expect Router.parse("/") == { path: "/", query: "" }
expect Router.parse("") == { path: "/", query: "" }
expect Router.parse("?q") == { path: "/", query: "q" }
