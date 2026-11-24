import pf.Server
import pf.Endpoint

## GET /api/hello: a word, as JSON; the front page links to it, so the copy has it as a file.
get! : { request : Server.Request, params : {}, context : c } => Try(Str, Endpoint.Refusal)
get! = |_| Ok("hello")
