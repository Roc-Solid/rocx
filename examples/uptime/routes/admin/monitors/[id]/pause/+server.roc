import pf.Server
import pf.Endpoint
import ../../../../../Middlewares
import ../../../../../News
import ../../../../../Store

middleware = Middlewares.admin

## POST /admin/monitors/<id>/pause: pauses a monitor that runs, or runs one that is paused (checked
## at the next sweep). Open pages hear of it on the live channel.
post! : { request : Server.Request, params : { id : Str }, context : {}, body : {} } => Try(Str, Endpoint.Refusal)
post! = |{ params, .. }|
	match I64.from_str(params.id) {
		Ok(id) =>
			match (Store.toggle_pause!(id), Store.monitor!(id)) {
				(Ok(paused), Ok(monitor)) => {
					News.tell!({ monitor: id, name: monitor.name, what: if (paused) "paused" else "resumed" })
					Ok(if (paused) "Paused." else "Running again.")
				}
				(Err(problem), _) | (_, Err(problem)) => Err(Store.refused!(problem))
			}
		Err(_) => Err(NotFound)
	}
