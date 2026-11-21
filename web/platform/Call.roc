import Host

## Requests from a component: an HTTP request (`fetch!`), its answer read as a plain value, and a
## stream of events (`listen!`). While an answer is on its way, the computation or handler that
## asked stops, and runs again once it is in; if there is none, the nearest <Errored> shows why.
## `Endpoint` reads and sends an app's endpoints with them.
Call := [].{

	## An HTTP request from the browser (an endpoint's, say: `Endpoint.send!`): its answer, read as a
	## plain value. A handler or computation that asks stops until it is in, and runs again then; no
	## answer at all (offline) shows the nearest <Errored>. On the server, while a page renders, a
	## GET of one of the app's own paths is answered in-process and noted for the page
	## (`Endpoint.get!`); any other request is a handler's, and fails there.
	fetch! : { method : Str, url : Str, headers : List({ name : Str, value : Str }), body : Str } => { status : U16, body : Str }
	fetch! = |request| {
		lines = Str.join_with(request.headers.map(|header| "${header.name}: ${header.value}"), "\n")
		answer = Host.fetch!(request.method, request.url, lines, request.body)
		match Json.parse(answer) {
			Ok(answered) => answered
			Err(InvalidJson(why)) => {
				Host.fail!("${request.method} ${request.url}: ${why}")
				crash "unreachable: fail! doesn't return"
			}
		}
	}

	## Listens to a stream of events (server-sent events: an endpoint's `events!`) at `url`, from a
	## handler: `heard!` runs, as a handler does, for each event's data as it comes, then once with
	## `Ended`; or `Refused(status, why)` (an answer that isn't a stream), or `Failed(why)` (offline,
	## or a stream cut off).
	listen! : Str, ([Event(Str), Ended, Refused(U16, Str), Failed(Str)] => {}) => {}
	listen! = |url, heard!| {
		each! = || {
			heard =
				match Json.parse(Host.event_value!({})) {
					Ok(said) => said
					Err(InvalidJson(why)) => Failed("${url}: ${why}")
				}
			heard!(heard)
			""
		}
		Host.listen!(url, Box.box(each!))
	}
}
