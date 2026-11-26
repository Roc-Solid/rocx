import pf.Server
import pf.Endpoint

## POST /items/<id>: a note on an item, as the tests' server answers it. This file says the endpoint
## is there, for the route table (D-095): a path with a param.
post! : { request : Server.Request, params : { id : Str }, context : c, body : { note : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }| Ok(body.note)
