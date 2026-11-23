import Host
import Endpoint
import Submission
import Submissions
import Server
import Search
import Leave

## Solid Router's, on both sides. Where the page is (`useLocation`): on the server, the request's
## path and query; in the browser, the location the page on screen was rendered for, which each
## navigation in place changes (D-040). A trailing slash is dropped (`/syntax/` is `/syntax`), as the
## server drops it from what it answers. Navigating (`useNavigate`, `useIsRouting`); and submissions
## to an endpoint: the latest (`useSubmission`), all of them (`useSubmissions`), and a handler's own,
## without a form (`useAction`).
Router := [].{

	## The page's path (`/blog/rocx`) and its query (`page=2`, with no `?`; "" with none).
	Location : { path : Str, query : Str }

	## Where the page is: on the server, the request's path and query; in the browser, the location
	## the page on screen was rendered for (`location.pathname` without the site's base, and
	## `location.search`). Tracked: a hole or a memo that reads it runs again when a navigation in
	## place changes it.
	location! : {} => Location
	location! = |{}| Router.parse(Host.location!({}))

	## Navigates to `to` (Solid Router's `useNavigate`), from a handler: a path (`Paths` makes them),
	## a path with a query, or a query alone (`?days=30`, on the page's own path). One of the app's
	## pages is rendered in place, the old page staying until the new one's document is in
	## (`is_routing!`); anything else (another site, a path no page has) the browser loads. Queued
	## with the handler's writes, so a handler that waits for the server and runs again navigates
	## once. Called while computing, it fails: rendering mustn't navigate. On the server no handler
	## runs, and it does nothing.
	##
	##     <button on:click={|| navigate!(Paths.tasks_id({ id: task!().id }))}>Open</button>
	navigate! : Str => {}
	navigate! = |to| Host.navigate!(to, Bool.False, Bool.True)

	## `navigate!` with Solid Router's options: `replace` replaces the history entry instead of
	## pushing one; `scroll: Bool.False` leaves the scroll where it is (else the new page starts at
	## the top, or at the element its hash names).
	##
	##     navigate_with!(Paths.lists_id({ id: list.id }), { replace: Bool.True, scroll: Bool.True })
	navigate_with! : Str, { replace : Bool, scroll : Bool } => {}
	navigate_with! = |to, options| Host.navigate!(to, options.replace, options.scroll)

	## Whether a navigation in place is on its way (Solid Router's `useIsRouting`), tracked: true
	## from the click until the new page is on screen, or the navigation fails or is overtaken;
	## false on the server and while hydrating.
	##
	##     <div class="progress" class:on={Router.is_routing!({})} aria-hidden="true"></div>
	is_routing! : {} => Bool
	is_routing! = |{}| Host.is_routing!({})

	## Runs `listener!` before each navigation away from the page (Solid Router's `useBeforeLeave`,
	## D-040), as a handler: a link, `navigate!`, `<Navigate>`, a GET form, a submission's redirect,
	## a change of the query alone, back and forward. It is given the navigation (`Leave`: `to`,
	## `from`, `options`, `delta`), which it may stop (`leave.prevent!()`), and let go later
	## (`leave.retry!(force)`, from another handler: an app's own dialog). Called in a component (or
	## a computation), it listens while that is there, and stops when it goes. Listeners are asked in
	## the order they came.
	##
	##     use_before_leave!(|leave|
	##         if dirty!() {
	##             leave.prevent!()
	##             set_leaving!(Ok(leave))
	##         }
	##     )
	##
	## A listener decides from what the page has (a signal, a memo already in): the navigation is
	## decided once each has run, and one that waits for the server can't hold it (it isn't run again
	## when the answer is in; a dev build says so). A load (leaving the site, reloading, closing the
	## tab) the page can't hold: the runtime asks each listener ahead of time, with `to` "" (and its
	## writes dropped), again whenever what it read changes, and while one would stop it, the browser
	## asks the visitor first, with its own words (`beforeunload`). On the server no navigation
	## happens, and it does nothing.
	use_before_leave! : (Leave => {}) => {}
	use_before_leave! = |listener!| {
		run! = || {
			listener!(Leave.of(Host.event_value!({})))
			""
		}
		Host.before_leave!(Box.box(run!))
	}

	## The page's query (Solid Router's `useSearchParams`, D-040): `get!` and `all!` read it, tracked;
	## `set!` and `set_with!` change it in place, from a handler. See `Search`.
	##
	##     search = use_search_params!({})
	##     days! = || search.get!("days") ?? "7"
	##     <button on:click={|| search.set!([("days", "30")])}>30 days</button>
	use_search_params! : {} => Search
	use_search_params! = |{}| Search.here

	## The app, told to the runtime as its page renders: `Generated/Root.roc` calls it first, and an
	## app never does. `build` is the build's id (rocx build's hash of the app's sources): the server
	## writes it on the page's bootstrap (`data-build`), and the browser loads a page of another
	## build instead of rendering it. `dev`: rocx built it with `--dev`. `routes`: the app's pages,
	## as JSON rocx build wrote (each page's path, `/lists/[id]`, and its levels' code, from the root
	## layout to the page), which the browser navigates in place to.
	app! : { build : Str, dev : Bool, routes : Str } => {}
	app! = |told| Host.app!(told.build, told.dev, told.routes)

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
