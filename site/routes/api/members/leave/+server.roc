import pf.Server
import pf.Endpoint
import ../../../../Generated/Paths

## POST /api/members/leave: the `member` cookie gone, and back to the joining page (D-106).
post! : { request : Server.Request, params : {}, context : c, body : {} } => Try(Server.Response, Endpoint.Refusal)
post! = |_| Ok(Server.without_cookie(Server.redirect(Paths.members_join), "member"))
