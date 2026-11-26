import pf.Server
import pf.Endpoint
import ../../../../Plate
import ../../../../Store

## GET /api/days/:day, for JSON: that day of the diary (`2026-11-21`); 404 when it isn't a day.
get! : { request : Server.Request, params : { day : Str }, context : {} } => Try(Plate.Day, Endpoint.Refusal)
get! = |{ params, .. }| Store.day!(params.day).map_err!(Store.refusal!)
