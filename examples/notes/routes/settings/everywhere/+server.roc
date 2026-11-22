import pf.Server
import pf.Endpoint
import ../../../Account
import ../../../Middlewares
import ../../../Store

middleware = Middlewares.signed_in

## POST /settings/everywhere: signed out on every browser, this one too (every session cookie
## signed before now is refused: Session.roc), and on to signing in again. Tokens stay: revoke
## those one by one.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : {} } => Try(Str, Endpoint.Refusal)
post! = |{ context, .. }|
	match Store.sign_out_everywhere!(context.person.id) {
		Ok(_) => Err(Answer(Account.signed_out(Server.redirect("/sign-in"))))
		Err(problem) => Err(Store.refused!(problem))
	}
