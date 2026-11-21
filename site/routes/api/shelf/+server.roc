import pf.Server
import pf.Endpoint

## GET /api/shelf: what is on the shelf, from wherever a shop keeps it (here, a list). The shelf
## demo reads it as the page renders.
get! : { request : Server.Request, params : {}, context : c } => Try(List({ name : Str, price : U64 }), Endpoint.Refusal)
get! = |_|
	Ok([
		{ name: "Roc bird sticker", price: 2 },
		{ name: "rocx mug", price: 9 },
		{ name: "Lambda pin", price: 3 },
	])
