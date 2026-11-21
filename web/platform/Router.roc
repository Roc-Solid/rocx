import Host
import Endpoint
import Submission

## Solid Router's, on both sides. Where the page is (`useLocation`): on the server, the request's
## path and query; in the browser, `location.pathname` and `location.search`. A trailing slash is
## dropped (`/syntax/` is `/syntax`), as the server drops it from what it answers. And the latest
## submission of a form to an endpoint (`useSubmission`).
Router := [].{

	## The page's path (`/blog/rocx`) and its query (`page=2`, with no `?`; "" with none).
	Location : { path : Str, query : Str }

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
		url = Endpoint.url_of(endpoint)
		Host.action!(url)
		Submission.of(url)
	}
}

expect Router.parse("/blog/rocx?page=2") == { path: "/blog/rocx", query: "page=2" }
expect Router.parse("/") == { path: "/", query: "" }
expect Router.parse("") == { path: "/", query: "" }
expect Router.parse("?q") == { path: "/", query: "q" }
