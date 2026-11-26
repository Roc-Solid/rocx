import pf.Server
import pf.Endpoint
import ../../../../../Incident
import ../../../../../Jobs
import ../../../../../Middlewares
import ../../../../../News
import ../../../../../Store

middleware = Middlewares.admin

## POST /api/admin/incidents/<id>: an update on an open incident, from the admin's page: its stage
## (`investigating`, `identified`, `monitoring`, `resolved`) and what to say. `resolved` closes it,
## and mails the subscribers that it did. Open pages hear of it on the live channel.
post! : { request : Server.Request, params : { id : I64 }, context : {}, body : { state : Str, body : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ params, body, .. }| {
	said = body.body.trim()
	id = params.id
	match Incident.stage_of(body.state) {
		Err(Unknown) => Err(BadRequest("Pick a stage: investigating, identified, monitoring or resolved."))
		Ok(stage) =>
			if said.is_empty() or said.to_utf8().len() > 2000 {
				Err(BadRequest("Say what is happening, in 2000 characters at most."))
			} else {
				match Store.post_update!(id, stage, said, "Status team", Jobs.alerts!) {
					Ok({}) => {
						incident = Store.incident!(id)
						match incident {
							Ok(found) => News.tell!({ monitor: found.incident.monitor, name: found.incident.monitor_name, what: if (stage == Resolved) "closed" else "updated" })
							Err(_) => {}
						}
						Ok("Posted.")
					}
					Err(NotFound) => Err(Conflict("That incident is closed already."))
					Err(problem) => Err(Store.refused!(problem))
				}
			}
	}
}
