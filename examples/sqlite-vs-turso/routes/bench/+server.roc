import pf.Server
import pf.Endpoint
import ../../Bench

## POST /bench: every workload, timed in Roc on the server's database (SQLite or Turso, as
## `--database-url` says), on fresh tables; `size` scales how much each does (100 for the docs'
## numbers, 1 for a test). A 500 says which workload failed, or which check of what they wrote.
post! : { request : Server.Request, params : {}, context : c, body : { size : U64 } } => Try(Bench.Report, Endpoint.Refusal)
post! = |{ body, .. }|
	match Bench.run!(body.size) {
		Ok(report) => Ok(report)
		Err(why) => Err(Status(500, why))
	}
