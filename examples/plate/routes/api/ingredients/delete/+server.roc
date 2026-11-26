import pf.Server
import pf.Endpoint
import ../../../../Store

## POST /api/ingredients/delete: an ingredient out of its recipe, which its food then follows.
## Gone already is no problem.
post! : { request : Server.Request, params : {}, context : {}, body : { id : Str } } => Try({}, Endpoint.Refusal)
post! = |{ body, .. }| {
	_ = Store.remove_ingredient!(body.id).map_err!(Store.refusal!)?
	Ok({})
}
