import pf.Server
import pf.Endpoint
import ../../Plate
import ../../Query
import ../../Store

## GET /trends, for JSON: each of the last 7, 30 or 90 days (`?days=30`; a week otherwise) with
## what was eaten, today's targets, and the weights logged in that time.
get! : { request : Server.Request, params : {}, context : {} } => Try(Plate.Trends, Endpoint.Refusal)
get! = |{ request, .. }| {
	range = Plate.range_of(Query.value(request.query, "days"))
	totals = Store.totals!(range).map_err(Store.refusal)?
	weights = Store.weights!(range).map_err(Store.refusal)?
	target = Store.aim!({}).map_err(Store.refusal)?
	today = Store.today!({}).map_err(Store.refusal)?
	Ok({ range, today, totals, target, weights })
}
