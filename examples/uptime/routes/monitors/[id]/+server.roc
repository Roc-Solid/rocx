import pf.Server
import pf.Endpoint
import ../../../Report
import ../../../Status
import ../../../Store

## GET /monitors/<id>, as JSON: a monitor's page's data. 404 for a monitor that isn't there (an
## id that isn't a number is no route at all: its params are typed, D-092).
get! : { request : Server.Request, params : { id : I64 }, context : {} } => Try(Report.Detail, Endpoint.Refusal)
get! = |{ params, .. }|
	match Status.detail!(params.id) {
		Ok(detail) => Ok(detail)
		Err(problem) => Err(Store.refused!(problem))
	}
