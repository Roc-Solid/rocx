import pf.Server
import pf.Endpoint
import ../../../Shop

## POST /echo/json: the order it was sent (Shop.Order), read into a record and written back. A body
## that isn't one is refused with a 400 before this runs.
post! : { request : Server.Request, params : {}, context : c, body : Shop.Order } => Try(Shop.Order, Endpoint.Refusal)
post! = |{ body, .. }| Ok(body)
