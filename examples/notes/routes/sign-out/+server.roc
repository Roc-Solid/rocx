import pf.Server
import pf.Endpoint
import auth.Auth

## Signs out: the session ended (packages/auth's `Auth.sign_out!`), its cookie gone, and on to the
## sign-in page.
post! : { request : Server.Request, params : {}, context : {}, body : {} } => Try(Str, Endpoint.Refusal)
post! = |{ request, .. }| Err(Answer(Auth.sign_out!(request, Server.redirect("/sign-in"))))
