import pf.Server
import pf.Endpoint
import ../../../Generated/Paths

## POST /members/leave: the `member` cookie gone, and back to the joining page.
post! : { request : Server.Request, params : {}, context : c, body : {} } => Try({}, Endpoint.Refusal)
post! = |_| Err(Answer(Server.without_cookie(Server.redirect(Paths.members_join), "member")))
