import pf.Server
import pf.Endpoint
import ../../../Report
import ../../../Status
import ../../../Store

## GET /incidents/<id>, as JSON: an incident and its updates. 404 for one that isn't there.
get! : { request : Server.Request, params : { id : Str }, context : {} } => Try(Report.Incident, Endpoint.Refusal)
get! = |{ params, .. }|
	match I64.from_str(params.id) {
		Ok(id) =>
			match Status.incident!(id) {
				Ok(incident) => Ok(incident)
				Err(problem) => Err(Store.refused!(problem))
			}
		Err(_) => Err(NotFound)
	}
