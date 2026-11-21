import Host
import Server

## The latest submission of a form to an endpoint, as Solid Router's `useSubmission` gives it
## (`Router.use_submission!(endpoint)`): whether it is on its way, what was typed, and the endpoint's
## result or refusal. Its fields are methods: `submission.pending!()`.
##
## With the runtime, a form posting to the endpoint is sent with `fetch`, and the submission is the
## latest the runtime sent. Without it (before it loads, or with no JavaScript), the form posts as a
## form does, and the endpoint sends the browser back with a flash (`Server.flash!`): until the
## runtime sends one, the submission is that flash, when it is the endpoint's. On the server it is
## the flash, or none.
Submission(arg, result) :: { url : Str }.{

	## The submission to the endpoint at `url`: `Router.use_submission!` makes one.
	of : Str -> Submission(arg, result)
	of = |to| { url: to }

	## The URL of the endpoint it is to: what the form's `action` is.
	url_of : Submission(arg, result) -> Str
	url_of = |submission| submission.url

	## Whether it is on its way: sent, and no answer yet.
	pending! : Submission(arg, result) => Bool
	pending! = |submission|
		match latest!(submission) {
			Pending(_) => Bool.True
			_ => Bool.False
		}

	## What was typed, as the endpoint reads it (its arg: a record of the form's fields).
	## `Err(NoInput)` with no submission, or fields it doesn't read.
	input! : Submission(arg, result) => Try(arg, [NoInput]) where [arg.Json.Parseable([InvalidJson(Str)])]
	input! = |submission|
		match fields_of(latest!(submission)) {
			Ok(fields) =>
				match Json.parse(fields_json(fields)) {
					Ok(parsed) => Ok(parsed)
					Err(InvalidJson(_)) => Err(NoInput)
				}
			Err(NoInput) => Err(NoInput)
		}

	## A field as it was typed (`FormData.get`): "" with no submission, or no such field.
	field! : Submission(arg, result), Str => Str
	field! = |submission, name|
		match fields_of(latest!(submission)) {
			Ok(fields) =>
				match fields.find_first(|field| field.name == name) {
					Ok(found) => found.value
					Err(_) => ""
				}
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

	## Forgets it (Solid's `clear`), the flash too: from a handler.
	clear! : Submission(arg, result) => {}
	clear! = |submission| Host.submission_clear!(submission.url)
}

## The latest submission to the endpoint: the runtime's, or with none the flash, if it is the
## endpoint's. Its input (a form's body, as posted), and its answer's status and body.
latest! : Submission(arg, result) => [Idle, Pending(Str), Done(Str, U16, Str)]
latest! = |submission| {
	live = Host.submission!(Submission.url_of(submission))
	if live.is_empty() {
		match Server.flash!({}) {
			Ok(flash) => if (flash.url == Submission.url_of(submission)) Done(form_body(flash.fields), flash.status, flash.body) else Idle
			Err(NoFlash) => Idle
		}
	} else {
		match parsed(live) {
			Ok(found) =>
				if found.state == "pending" {
					Pending(found.input)
				} else if found.state == "done" {
					Done(found.input, found.status, found.body)
				} else {
					Idle
				}
			Err(_) => Idle
		}
	}
}

## The runtime's submission, as it gives it.
parsed : Str -> Try({ state : Str, input : Str, status : U16, body : Str }, [InvalidJson(Str)])
parsed = |live| Json.parse(live)

## A submission's fields, as typed.
fields_of : [Idle, Pending(Str), Done(Str, U16, Str)] -> Try(List({ name : Str, value : Str }), [NoInput])
fields_of = |latest|
	match latest {
		Pending(input) => Ok(Server.form_fields(input))
		Done(input, _, _) => Ok(Server.form_fields(input))
		Idle => Err(NoInput)
	}

## Fields as a form's body again (`name=Ada%20L`), as the runtime keeps one.
form_body : List({ name : Str, value : Str }) -> Str
form_body = |fields| Str.join_with(fields.map(|field| "${Server.encode_segment(field.name)}=${Server.encode_segment(field.value)}"), "&")

## Fields as a JSON object of strings, as an endpoint reads a form.
fields_json : List({ name : Str, value : Str }) -> Str
fields_json = |fields| "{${Str.join_with(fields.map(|field| "${Json.to_str(field.name)}:${Json.to_str(field.value)}"), ",")}}"

expect form_body([{ name: "name", value: "Ada L" }, { name: "plan", value: "a&b" }]) == "name=Ada%20L&plan=a%26b"
expect Server.form_fields(form_body([{ name: "name", value: "Ada L" }, { name: "plan", value: "a&b" }])) == [{ name: "name", value: "Ada L" }, { name: "plan", value: "a&b" }]
expect fields_json([{ name: "name", value: "Ada \"L\"" }]) == "{\"name\":\"Ada \\\"L\\\"\"}"
expect parsed("{\"state\":\"done\",\"input\":\"name=\",\"status\":400,\"body\":\"no\"}") == Ok({ state: "done", input: "name=", status: 400, body: "no" })
