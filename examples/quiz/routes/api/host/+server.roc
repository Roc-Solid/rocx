import pf.Server
import pf.Endpoint
import ../../../Draft
import ../../../Sets
import ../../../Visitor

## GET /api/host: the question sets a room can be opened for, the newest made first.
get! : { request : Server.Request, params : {}, context : Visitor.Context } => Try(List(Draft.Summary), Endpoint.Refusal)
get! = |_|
	match Sets.all!({}) {
		Ok(sets) => Ok(sets)
		Err(_) => Err(Status(503, "The question sets couldn't be read."))
	}
