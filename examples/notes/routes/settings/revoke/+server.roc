import pf.Server
import pf.Endpoint
import ../../../Middlewares
import ../../../Store

middleware = Middlewares.signed_in

## POST /settings/revoke, from a token's Revoke button (`id`): the token gone, so the next request
## with it is refused.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : { id : Str } } => Try({ revoked : Str }, Endpoint.Refusal)
post! = |{ context, body, .. }|
	match Store.revoke_token!(context.person.id, body.id) {
		Ok({}) => Ok({ revoked: body.id })
		Err(problem) => Err(Store.refused!(problem))
	}
