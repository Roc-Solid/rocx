import pf.Server
import pf.Endpoint
import ../../../Bench

## POST /bench/big: a million orders (`orders`, 1,000 to 5,000,000) of a hundredth as many
## customers, in tables made afresh, loaded, checkpointed, then fetched one and a hundred at a time,
## joined to their customers and summed, each workload timed in Roc. A 500 says which failed.
post! : { request : Server.Request, params : {}, context : c, body : { orders : U64 } } => Try(Bench.BigReport, Endpoint.Refusal)
post! = |{ body, .. }|
	match Bench.big!(body.orders) {
		Ok(report) => Ok(report)
		Err(why) => Err(Status(500, why))
	}
