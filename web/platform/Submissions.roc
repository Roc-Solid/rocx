import Host
import Server
import Submission

## Every submission to an endpoint, each its own, as Solid Router's `useSubmissions` gives them
## (`Router.use_submissions!(endpoint)`): several may be on their way at once (two cards dragged
## quickly), and each is answered, refused or forgotten on its own.
##
## An optimistic value is the server's, with what the submissions on their way sent applied to it:
## shown at once, kept while they are on their way, and gone with them. One the endpoint answers
## with its result stays on its way until the page's reads have been read again, so the server's
## data takes its place all at once; one it refuses goes at once, and the value is the server's
## again, the refusal in its `error`.
##
##     moves = use_submissions!(Api.post_planner_move({}))
##     cards! = create_memo!(|| moves.pending_inputs!().fold(Endpoint.get!(Api.get_planner({})), moved))
##
## Submissions are kept by the endpoint's URL: an endpoint with params in its path has a list for
## each URL, so what varies goes in its body. Their types are the endpoint's, from the app's
## contract (`Generated/Api`, D-037), in the browser's copy as on the server.
Submissions(arg, result) :: { url : Str, form : List({ name : Str, value : Str }) -> Try(arg, Str) }.{

	## A submission as it is now, Solid's fields: whether it is on its way (`pending`), what it sent,
	## as the endpoint reads it (`input`), and the endpoint's result or refusal; its `id`, unique on
	## the page, keys it (`<For keyed={|move| move.id}>`) and forgets it (`clear!`).
	Sent(arg, result) : { id : U64, pending : Bool, input : Try(arg, [NoInput]), result : Try(result, [NoResult]), error : Try(Server.Problem, [NoError]) }

	## The submissions to the endpoint at `url`, whose arg a form's fields are read as by `form` (the
	## endpoint's reader, `Endpoint.form_of`): `Router.use_submissions!` makes them.
	of : Str, (List({ name : Str, value : Str }) -> Try(arg, Str)) -> Submissions(arg, result)
	of = |to, form| { url: to, form: form }

	## Each one, oldest first, as it is now: those on their way, and those answered, until forgotten
	## (`clear!`). A computation that reads them runs again when one changes. Without the runtime,
	## the flash of a plain form's post, when it is the endpoint's (its id 0); on the server, that
	## flash, or none.
	all! : Submissions(arg, result) => List(Sent(arg, result))
		where [arg.Json.Parseable([InvalidJson(Str)]), result.Json.Parseable([InvalidJson(Str)])]
	all! = |submissions|
		match listed!(Submissions.url_of(submissions)) {
			Listed(entries) => entries.map(|entry| sent_of(entry.id, entry.state == "pending", Submission.parse_input(submissions.form, entry.input, entry.json), entry.status, entry.body))
			Flashed(flash) => [sent_of(0, Bool.False, Submission.parse_input(submissions.form, Submission.form_body(flash.fields), Bool.False), flash.status, flash.body)]
			Unlisted => []
		}

	## Whether any is on its way (Solid's `submissions.pending`).
	pending! : Submissions(arg, result) => Bool
	pending! = |submissions|
		match listed!(Submissions.url_of(submissions)) {
			Listed(entries) => entries.any(|entry| entry.state == "pending")
			_ => Bool.False
		}

	## What the submissions on their way sent, oldest first, as the endpoint reads it: what an
	## optimistic value applies to the server's. None on the server.
	pending_inputs! : Submissions(arg, result) => List(arg) where [arg.Json.Parseable([InvalidJson(Str)])]
	pending_inputs! = |submissions|
		match listed!(Submissions.url_of(submissions)) {
			Listed(entries) => entries.keep_if(|entry| entry.state == "pending").keep_oks(|entry| Submission.parse_input(submissions.form, entry.input, entry.json))
			_ => []
		}

	## Forgets one, by its id (Solid's `submission.clear()`), from a handler: it leaves the list. Its
	## answer, should it come later, is dropped. Id 0, the flash, forgets the latest too
	## (`Submission.clear!`).
	clear! : Submissions(arg, result), U64 => {}
	clear! = |submissions, id| {
		url = Submissions.url_of(submissions)
		if (id == 0) Host.submission_clear!(url) else Host.submission_drop!(url, id)
	}

	## Sends one again, by its id (Solid's `submission.retry()`), from a handler, with what it sent
	## before: pending again, its answer to come. One still on its way, or forgotten, isn't sent.
	retry! : Submissions(arg, result), U64 => {}
	retry! = |submissions, id| Host.submission_retry!(Submissions.url_of(submissions), id)

	## The URL of the endpoint they are to.
	url_of : Submissions(arg, result) -> Str
	url_of = |submissions| submissions.url
}

## A submission as the runtime has it: its result once it is answered with one (200), its refusal
## otherwise (`HttpErr` with no answer at all).
sent_of : U64, Bool, Try(arg, [NoInput]), U16, Str -> { id : U64, pending : Bool, input : Try(arg, [NoInput]), result : Try(result, [NoResult]), error : Try(Server.Problem, [NoError]) }
	where [result.Json.Parseable([InvalidJson(Str)])]
sent_of = |id, pending, input, status, body| {
	result =
		if pending or status != 200 {
			Err(NoResult)
		} else {
			match Json.parse(body) {
				Ok(parsed) => Ok(parsed)
				Err(InvalidJson(_)) => Err(NoResult)
			}
		}
	error =
		if pending or status == 200 {
			Err(NoError)
		} else if status == 0 {
			Ok(HttpErr(body))
		} else {
			Ok(Refused(status, body))
		}
	{ id, pending, input, result, error }
}

## The runtime's submissions to the URL; or, with none (and none forgotten), the flash, if it is the
## endpoint's.
listed! : Str => [Listed(List({ id : U64, state : Str, input : Str, json : Bool, status : U16, body : Str })), Flashed(Server.Flash), Unlisted]
listed! = |url| {
	live = Host.submissions!(url)
	if live.is_empty() {
		match Server.flash!({}) {
			Ok(flash) => if (flash.url == url) Flashed(flash) else Unlisted
			Err(NoFlash) => Unlisted
		}
	} else {
		match parsed(live) {
			Ok(found) => Listed(found.list)
			Err(_) => Unlisted
		}
	}
}

## The runtime's submissions, as it gives them.
parsed : Str -> Try({ cleared : Bool, list : List({ id : U64, state : Str, input : Str, json : Bool, status : U16, body : Str }) }, [InvalidJson(Str)])
parsed = |live| Json.parse(live)

expect parsed("{\"cleared\":false,\"list\":[{\"id\":3,\"state\":\"pending\",\"input\":\"{}\",\"json\":true,\"status\":0,\"body\":\"\"}]}") == Ok({ cleared: Bool.False, list: [{ id: 3, state: "pending", input: "{}", json: Bool.True, status: 0, body: "" }] })
