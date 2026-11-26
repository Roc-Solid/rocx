import pf.Server
import pf.Endpoint
import forms.Issues
import ../../PlateForm
import ../../Store
import ../../Query
import ../../Session

## POST /sign-in, from its form: with the right password, a session's cookie (packages/auth's) and
## on to where you were going (`then`, a path of this site's); a wrong one is refused under the
## field. A diary with no password has nothing to sign in to, and sends you to it.
post! : { request : Server.Request, params : {}, context : {}, body : { password : Str } } => Try({}, Endpoint.Refusal)
post! = |{ request, .. }| {
	posted = Server.text_of(request)
	match PlateForm.password.parse_body(posted) {
		Ok(password) =>
			match Session.sign_in!(password, Query.value(posted, "then")) {
				Ok(answer) => Err(Answer(answer))
				Err(Open) => Err(Answer(Server.redirect("/")))
				Err(Wrong) => refused("That isn't the password")
				Err(TooMany) => refused("Too many tries: wait a minute, then try again")
				Err(DbErr(why)) => Err(Store.refusal!(DbErr(why)))
			}
		Err(issues) => Err(Issues.refusal(issues))
	}
}

refused : Str -> Try({}, Endpoint.Refusal)
refused = |why| Err(Issues.refusal([{ field: "password", code: Custom("wrong", why), message: why }]))
