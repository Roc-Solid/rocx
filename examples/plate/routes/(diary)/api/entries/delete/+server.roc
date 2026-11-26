import pf.Server
import pf.Endpoint
import ../../../../../Store

## POST /api/entries/delete: an entry off the diary. Each entry's remove button is a form that
## posts here. Without JavaScript the browser posts it, and goes back to the day (a 303, which
## `Endpoint.respond!` sends a plain form); with it, the runtime sends it with fetch, and the entry
## is gone from the page before the answer is in. Deleting one that's gone already is no problem.
post! : { request : Server.Request, params : {}, context : {}, body : { id : Str } } => Try({}, Endpoint.Refusal)
post! = |{ body, .. }| {
	_ = Store.unlog!(body.id).map_err!(Store.refusal!)?
	Ok({})
}
