import pf.Server
import pf.Endpoint
import jobs.Job
import ../../../../../../Jobs
import ../../../../../../Middlewares

middleware = Middlewares.admin

## POST /api/admin/monitors/<id>/check: "Check now". Queues a check of the monitor at once, the job
## the sweep would queue (keyed by the monitor, so one already waiting isn't queued twice).
post! : { request : Server.Request, params : { id : I64 }, context : {}, body : {} } => Try(Str, Endpoint.Refusal)
post! = |{ params, .. }|
	match Job.enqueue_keyed!(Jobs.check, { monitor: params.id }, { key: "check:${params.id.to_str()}" }) {
		Ok(_) => Ok("A check is on its way.")
		Err(JobErr(why)) => Err(Status(503, why))
	}
