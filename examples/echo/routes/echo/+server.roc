import pf.Server
import pf.Endpoint

## POST /echo: the JSON string it was sent, sent back.
post! : { request : Server.Request, params : {}, context : c, body : Str } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }| Ok(body)
