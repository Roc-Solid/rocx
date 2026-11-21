import pf.Server
import pf.Endpoint
import pf.Time
import ../../../../Plans

## POST /api/planner/move: a plan to another day (`{ plan, day }`), slowly on purpose (800 ms), as a
## far server would be, so the demo's moves are seen on their way. A day holds three plans, and the
## dentist doesn't move: those are refused (409, and why). The week is kept in the reader's cookie.
post! : { request : Server.Request, params : {}, context : c, body : { plan : Str, day : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ request, body, .. }| {
	Time.sleep!(800)
	match Plans.moved(Plans.of(request), body) {
		Ok(plans) => Err(Answer(Server.with_cookie(Server.response(200, [{ name: "content-type", value: "application/json" }], "\"moved\""), "planner", Plans.kept(plans))))
		Err(why) => Err(Conflict(why))
	}
}
