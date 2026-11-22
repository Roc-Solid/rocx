import pf.Server
import pf.Endpoint
import ../Report
import ../Status
import ../Store

## GET /, as JSON (`accept: application/json`): the status page's data, which the page reads as
## the server renders it and again whenever the live channel says something changed. Anyone may
## read it; a script or another dashboard can poll it too.
get! : { request : Server.Request, params : {}, context : {} } => Try(Report.Overview, Endpoint.Refusal)
get! = |_|
	match Status.overview!({}) {
		Ok(overview) => Ok(overview)
		Err(problem) => Err(Store.refused!(problem))
	}
