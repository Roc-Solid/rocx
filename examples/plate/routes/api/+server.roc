import pf.Server
import pf.Endpoint
import ../../Plate
import ../../Store

## GET /api, for JSON: today's page of the diary (today in the profile's time zone), as `Store.day!`
## reads any day.
get! : { request : Server.Request, params : {}, context : {} } => Try(Plate.Day, Endpoint.Refusal)
get! = |_| {
	today = Store.today!({}).map_err!(Store.refusal!)?
	Store.day!(today).map_err!(Store.refusal!)
}
