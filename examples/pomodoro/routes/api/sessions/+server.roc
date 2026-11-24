import pf.Server
import pf.Endpoint
import ../../../Pomodoro
import ../../../Store

## POST /api/sessions: a focus session done, `{ minutes }`; today's count after it. A session of no
## minutes, or of more than a day's, is refused.
post! : { request : Server.Request, params : {}, context : {}, body : Pomodoro.Done } => Try(Pomodoro.Today, Endpoint.Refusal)
post! = |{ body, .. }|
	if body.minutes == 0 or body.minutes > 24 * 60 {
		Err(BadRequest("a session is 1 to 1,440 minutes long"))
	} else {
		Store.record!(body.minutes)
	}
