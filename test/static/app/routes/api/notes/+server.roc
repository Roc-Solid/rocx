import pf.Server
import pf.Endpoint

## POST /api/notes: only a server answers it (a note says so).
post! : { request : Server.Request, params : {}, context : c, body : Str } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }| Ok(body)
