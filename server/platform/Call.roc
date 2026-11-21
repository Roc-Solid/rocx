import Host

## A server function, called from the browser: its answer, read as a plain value. While it is on
## its way, the computation or handler that called stops, and runs again once it is in; if the
## call fails, the nearest <Errored> shows why.
Call := [].{

	## An HTTP request from the browser (an endpoint's, say: `Endpoint.send!`): its answer, read as a
	## plain value. A handler or computation that asks stops until it is in, and runs again then; no
	## answer at all (offline) shows the nearest <Errored>. On the server it fails: a request is a
	## handler's.
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

	server! : Str, arg => result where [arg.Json.Encodable([Infinity, NaN, NegativeInfinity, ..]), result.Json.Parseable([InvalidJson(Str)])]
	server! = |name, arg| {
		input =
			match Json.to_str_try(arg) {
				Ok(json) => json
				Err(_) => {
					Host.fail!("${name}: its input holds a number JSON can't write (an F64 that is NaN or an infinity)")
					crash "unreachable: fail! doesn't return"
				}
			}
		answer = Host.call!(name, input)
		match Json.parse(answer) {
			Ok(result) => result
			Err(InvalidJson(why)) => {
				Host.fail!("${name} answered something else: ${why}")
				crash "unreachable: fail! doesn't return"
			}
		}
	}
}
