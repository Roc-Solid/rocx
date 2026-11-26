import pf.Server
import pf.Endpoint
import forms.Issues
import ../../../PlateForm
import ../../../Store
import ../../../Query
import ../../../Session

## What POST /api/sign-in is sent: the password, read and checked by `PlateForm.password` (D-093).
post_body = PlateForm.password

## POST /api/sign-in, from its form: with the right password, a session's cookie (packages/auth's)
## and on to where you were going (`then`, a path of this site's); a wrong one is refused under the
## field. A diary with no password has nothing to sign in to, and sends you to it.
post! : { request : Server.Request, params : {}, context : {}, body : Str } => Try({}, Endpoint.Refusal)
post! = |{ request, body, .. }| {
	# Where to go after: the form's own field, beside the password.
	then = Query.value(Server.text_of(request), "then")
	match Session.sign_in!(body, then) {
		Ok(answer) => Err(Answer(answer))
		Err(Open) => Err(Answer(Server.redirect("/")))
		Err(Wrong) => refused("That isn't the password")
		Err(TooMany) => refused("Too many tries: wait a minute, then try again")
		Err(DbErr(why)) => Err(Store.refusal!(DbErr(why)))
	}
}

refused : Str -> Try({}, Endpoint.Refusal)
refused = |why| Err(Issues.refusal([{ field: "password", code: Custom("wrong", why), message: why }]))
