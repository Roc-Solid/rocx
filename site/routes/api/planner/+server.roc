import pf.Server
import pf.Endpoint
import ../../../Plans

## GET /api/planner: the reader's week, which the planner demo (`Demos/Planner.rocx`) reads as the
## page renders, and again once a move is in: kept in a cookie of theirs (`planner`), so each
## reader moves their own plans.
get! : { request : Server.Request, params : {}, context : c } => Try(List({ id : Str, title : Str, day : Str }), Endpoint.Refusal)
get! = |{ request, .. }| Ok(Plans.of(request))
