import pf.Server
import pf.Endpoint
import pf.Time

## GET /api/greeting: what the screen says once the server answers, and the server's clock then
## (milliseconds since the epoch), so each read shows a new value.
get! : { request : Server.Request, params : {}, context : c } => Try({ message : Str, at : U64 }, Endpoint.Refusal)
get! = |_| Ok({ message: "Hello from the rocx server", at: Time.now_millis!({}) })
