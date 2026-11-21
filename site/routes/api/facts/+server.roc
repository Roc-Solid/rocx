import pf.Server
import pf.Endpoint

## GET /api/facts: what the build measured, as `key=value` lines (`site/build.mjs`), which the
## site's default middleware hands on from the server's context. The layout reads it as each page
## renders (`Facts.facts!`), so the page carries the facts and the browser asks nothing.
get! : { request : Server.Request, params : {}, context : { facts : Str } } => Try(Str, Endpoint.Refusal)
get! = |{ context, .. }| Ok(context.facts)
