import pf.Server
import pf.Endpoint

## POST /notes: a note, as the tests' server answers it (web/test/navigation.test.mjs). This file
## says the endpoint is there, for the route table (D-095).
post! : { request : Server.Request, params : {}, context : c, body : { note : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }| Ok(body.note)
