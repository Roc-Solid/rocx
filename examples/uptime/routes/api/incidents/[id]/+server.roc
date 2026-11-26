import pf.Server
import pf.Endpoint
import ../../../../Report
import ../../../../Status
import ../../../../Store

## GET /api/incidents/<id>, as JSON: an incident and its updates. 404 for one that isn't there, or an
## id that isn't a number (D-092).
get! : { request : Server.Request, params : { id : I64 }, context : {} } => Try(Report.Incident, Endpoint.Refusal)
get! = |{ params, .. }|
	match Status.incident!(params.id) {
		Ok(incident) => Ok(incident)
		Err(problem) => Err(Store.refused!(problem))
	}
