import pf.Server
import pf.Endpoint
import ../../../Middlewares
import ../../../Report
import ../../../Status
import ../../../Store

middleware = Middlewares.admin

## GET /api/admin, as JSON: every monitor with its URL, the open incidents, how many subscribers there
## are and whether the flaky demo is broken on purpose. Only with the admin's session.
get! : { request : Server.Request, params : {}, context : {} } => Try(Report.Admin, Endpoint.Refusal)
get! = |_|
	match Status.admin!({}) {
		Ok(admin) => Ok(admin)
		Err(problem) => Err(Store.refused!(problem))
	}
