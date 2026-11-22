import pf.Server
import pf.Endpoint
import ../../Account

## Signs out: the session cookie goes, and on to the sign-in page.
post! : { request : Server.Request, params : {}, context : {}, body : {} } => Try(Str, Endpoint.Refusal)
post! = |_| Err(Answer(Account.signed_out(Server.redirect("/sign-in"))))
