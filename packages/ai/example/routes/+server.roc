import pf.Server
import pf.Endpoint
import pf.Random
import crypto.Hex

## GET /: a new chat's id, for the page's chat to keep its conversation under.
get! : { request : Server.Request, params : {}, context : c } => Try({ chat : Str }, Endpoint.Refusal)
get! = |_input| Ok({ chat: Hex.encode(Random.bytes!(8)) })
