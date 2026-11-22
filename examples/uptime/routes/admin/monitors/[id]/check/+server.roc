import pf.Server
import pf.Endpoint
import jobs.Job
import ../../../../../Jobs
import ../../../../../Middlewares

middleware = Middlewares.admin

## POST /admin/monitors/<id>/check: "Check now". Queues a check of the monitor at once, the job
## the sweep would queue (keyed by the monitor, so one already waiting isn't queued twice).
post! : { request : Server.Request, params : { id : Str }, context : {}, body : {} } => Try(Str, Endpoint.Refusal)
post! = |{ params, .. }|
	match I64.from_str(params.id) {
		Ok(id) =>
			match Job.enqueue_keyed!(Jobs.check, { monitor: id }, { when: Now, key: "check:${id.to_str()}" }) {
				Ok(_) => Ok("A check is on its way.")
				Err(JobErr(why)) => Err(Status(503, why))
			}
		Err(_) => Err(NotFound)
	}
