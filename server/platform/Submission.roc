import Host
import Server

## A submission to an endpoint, as Solid Router's `useSubmission` gives it: whether it is on its
## way, what was sent, and the endpoint's result or refusal. Its fields are methods:
## `submission.pending!()`. `Router.use_submission!(endpoint)` is the latest one;
## `Router.use_submissions!(endpoint)` lists them all, each its own (`Submissions`).
##
## With the runtime, a form posting to the endpoint is sent with `fetch`, as is an action
## (`Router.use_action!`), and the submission is one the runtime sent. Without it (before it loads,
## or with no JavaScript), the form posts as a form does, and the endpoint sends the browser back
## with a flash (`Server.flash!`): until the runtime sends one, the latest submission is that flash,
## when it is the endpoint's. On the server it is the flash, or none.
##
## A submission the endpoint answers with its result (200) stays pending until the page's reads
## (`Endpoint.get!`) have been read again, so what the page shows next is the server's, all at once.
Submission(arg, result) :: { url : Str, form : List({ name : Str, value : Str }) -> Try(arg, Str) }.{

	## The latest submission to the endpoint at `url`, whose arg a form's fields are read as by
	## `form` (the endpoint's reader, `Endpoint.form_of`: by the arg's type, D-038):
	## `Router.use_submission!` makes one.
	of : Str, (List({ name : Str, value : Str }) -> Try(arg, Str)) -> Submission(arg, result)
	of = |to, form| { url: to, form: form }

	## The URL of the endpoint it is to: what the form's `action` is.
	url_of : Submission(arg, result) -> Str
	url_of = |submission| submission.url

	## Whether it is on its way: sent, and not yet answered (or answered, and the page's reads being
	## read again).
	pending! : Submission(arg, result) => Bool
	pending! = |submission|
		match latest!(submission) {
			Pending(_) => Bool.True
			_ => Bool.False
		}

	## What was sent, as the endpoint reads it (its arg: a form's fields, as a record, or an
	## action's arg). `Err(NoInput)` with no submission, or fields it doesn't read.
	input! : Submission(arg, result) => Try(arg, [NoInput]) where [arg.Json.Parseable([InvalidJson(Str)])]
	input! = |submission|
		match sent_of(latest!(submission)) {
			Ok(Form(fields)) => Submission.parse_input(submission.form, fields, Bool.False)
			Ok(Json(json)) => Submission.parse_input(submission.form, json, Bool.True)
			Err(NoInput) => Err(NoInput)
		}

	## A field as it was typed (`FormData.get`): "" with no submission, no such field, or for an
	## action's (its arg isn't a form's fields: `input!` reads it).
	field! : Submission(arg, result), Str => Str
	field! = |submission, name|
		match sent_of(latest!(submission)) {
			Ok(Form(body)) =>
				match Server.form_fields(body).find_first(|field| field.name == name) {
					Ok(found) => found.value
					Err(_) => ""
				}
			Ok(Json(_)) => ""
			Err(NoInput) => ""
		}

	## The endpoint's result, once it is in. `Err(NoResult)` before, without one, or after a refusal.
	result! : Submission(arg, result) => Try(result, [NoResult]) where [result.Json.Parseable([InvalidJson(Str)])]
	result! = |submission|
		match latest!(submission) {
			Done(_, 200, body) =>
				match Json.parse(body) {
					Ok(parsed) => Ok(parsed)
					Err(InvalidJson(_)) => Err(NoResult)
				}
			_ => Err(NoResult)
		}

	## What went wrong, once the answer is in: the endpoint's refusal (`Refused(status, why)`), or
	## none at all (`HttpErr`). `Err(NoError)` before, without one, or after a result.
	error! : Submission(arg, result) => Try(Server.Problem, [NoError])
	error! = |submission|
		match latest!(submission) {
			Done(_, 0, why) => Ok(HttpErr(why))
			Done(_, 200, _) => Err(NoError)
			Done(_, status, why) => Ok(Refused(status, why))
			_ => Err(NoError)
		}

	## Forgets it (Solid's `clear`), the flash too, from a handler: it leaves the endpoint's
	## submissions, and there is none until the next is sent.
	clear! : Submission(arg, result) => {}
	clear! = |submission| Host.submission_clear!(submission.url)

	## Sends it again (Solid's `retry`), from a handler, with what it sent before: pending again, its
	## answer to come. One still on its way isn't sent twice; with none (or the flash: a plain form's,
	## which the runtime never had), nothing.
	##
	##     <Show when!={|| submission.error!().is_ok()}><button on:click={|| submission.retry!()}>Try again</button></Show>
	retry! : Submission(arg, result) => {}
	retry! = |submission| Host.submission_retry!(submission.url, 0)

	## A form's fields as its body again (`name=Ada%20L`), as the runtime keeps one.
	form_body : List({ name : Str, value : Str }) -> Str
	form_body = |fields| Str.join_with(fields.map(|field| "${Server.encode_segment(field.name)}=${Server.encode_segment(field.value)}"), "&")

	## The arg a submission's input is, as its endpoint reads it: a form's body (`name=Ada`), read by
	## `form`, the endpoint's reader (its arg's types: a number from its text, a box left unticked
	## `Bool.False`); or, `json`, an action's arg as JSON. `Err(NoInput)` when it isn't one.
	parse_input : (List({ name : Str, value : Str }) -> Try(arg, Str)), Str, Bool -> Try(arg, [NoInput]) where [arg.Json.Parseable([InvalidJson(Str)])]
	parse_input = |form, input, json|
		if json {
			match Json.parse(input) {
				Ok(parsed) => Ok(parsed)
				Err(InvalidJson(_)) => Err(NoInput)
			}
		} else {
			match form(Server.form_fields(input)) {
				Ok(parsed) => Ok(parsed)
				Err(_) => Err(NoInput)
			}
		}
}

## The latest submission, as the runtime has it, or, when it has none, the flash, if it is the
## endpoint's: what was sent (a form's body, or an action's arg as JSON), and its answer's status
## and body.
latest! : Submission(arg, result) => [Idle, Pending([Form(Str), Json(Str)]), Done([Form(Str), Json(Str)], U16, Str)]
latest! = |submission| {
	url = Submission.url_of(submission)
	live = Host.submission!(url)
	if live.is_empty() {
		match Server.flash!({}) {
			Ok(flash) => if (flash.url == url) Done(Form(Submission.form_body(flash.fields)), flash.status, flash.body) else Idle
			Err(NoFlash) => Idle
		}
	} else {
		match parsed(live) {
			Ok(found) => {
				sent = if (found.json) Json(found.input) else Form(found.input)
				if found.state == "pending" {
					Pending(sent)
				} else if found.state == "done" {
					Done(sent, found.status, found.body)
				} else {
					Idle
				}
			}
			Err(_) => Idle
		}
	}
}

## The runtime's submission, as it gives it.
parsed : Str -> Try({ state : Str, input : Str, json : Bool, status : U16, body : Str }, [InvalidJson(Str)])
parsed = |live| Json.parse(live)

## What a submission sent.
sent_of : [Idle, Pending([Form(Str), Json(Str)]), Done([Form(Str), Json(Str)], U16, Str)] -> Try([Form(Str), Json(Str)], [NoInput])
sent_of = |latest|
	match latest {
		Pending(sent) => Ok(sent)
		Done(sent, _, _) => Ok(sent)
		Idle => Err(NoInput)
	}

expect Submission.form_body([{ name: "name", value: "Ada L" }, { name: "plan", value: "a&b" }]) == "name=Ada%20L&plan=a%26b"
expect Server.form_fields(Submission.form_body([{ name: "name", value: "Ada L" }, { name: "plan", value: "a&b" }])) == [{ name: "name", value: "Ada L" }, { name: "plan", value: "a&b" }]
expect parsed("{\"state\":\"done\",\"input\":\"name=\",\"json\":false,\"status\":400,\"body\":\"no\"}") == Ok({ state: "done", input: "name=", json: Bool.False, status: 400, body: "no" })
