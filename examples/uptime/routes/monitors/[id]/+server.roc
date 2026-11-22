import pf.Server
import pf.Endpoint
import ../../../Report
import ../../../Status
import ../../../Store

## GET /monitors/<id>, as JSON: a monitor's page's data. 404 for a monitor that isn't there.
get! : { request : Server.Request, params : { id : Str }, context : {} } => Try(Report.Detail, Endpoint.Refusal)
get! = |{ params, .. }|
	match I64.from_str(params.id) {
		Ok(id) =>
			match Status.detail!(id) {
				Ok(detail) => Ok(detail)
				Err(problem) => Err(Store.refused!(problem))
			}
		Err(_) => Err(NotFound)
	}
