import pf.Server
import pf.Endpoint
import ../../Middlewares

## POST /login: 5 a minute for each client.
post! : { request : Server.Request, params : {}, context : Middlewares.Context, body : {} } => Try(Str, Endpoint.Refusal)
post! = |_| Ok("signed in")
