import pf.Server
import pf.Endpoint
import pf.Channel
import ../../News

## The live channel (D-020): every status, monitor, incident and admin page subscribes, and reads
## its data again when it hears that something changed (`News.tell!`, after each check and each of
## the admin's changes). It is public, as the status page is: anyone may listen.
channel! : { request : Server.Request, params : {}, context : {} } => Try(Channel(Str, News.Said, []), Endpoint.Refusal)
channel! = |_| Ok(Channel.allow("visitor"))
