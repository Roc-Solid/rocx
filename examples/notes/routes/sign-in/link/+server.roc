import pf.Server
import pf.Endpoint
import ../../../Account
import ../../../Query
import ../../../Store

## Who `?token=` signs in, while the link is good: what its page asks you to confirm. Reading this
## doesn't use the link. Used or expired: 410.
get! : { request : Server.Request, params : {}, context : {} } => Try({ email : Str }, Endpoint.Refusal)
get! = |{ request, .. }|
	match Account.link_for!(Query.value(request.query, "token")) {
		Ok(link) => Ok({ email: link.email })
		Err(Gone) => Err(gone)
	}

## Uses the link (`token`): signed in, with a session cookie, and on to where you were going. Only
## once; a link used already, or expired, is refused (410).
post! : { request : Server.Request, params : {}, context : {}, body : { token : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }|
	match Account.use_link!(body.token) {
		Err(Gone) => Err(gone)
		Ok(link) =>
			match Store.person_for!(link.email) {
				Ok(person) => Err(Answer(Account.signed_in!(Server.redirect(link.then), person)))
				Err(problem) => Err(Store.refused!(problem))
			}
	}

gone : Endpoint.Refusal
gone = Status(410, "This sign-in link has been used, or it has expired. Ask for another.")
