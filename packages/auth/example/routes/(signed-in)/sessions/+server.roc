import pf.Server
import pf.Endpoint
import auth.Auth
import ../../../Middlewares

## GET /sessions: the signed-in user's sessions, each with whether it is this one.
get! : { request : Server.Request, params : {}, context : Middlewares.Me } => Try(List({ id : Str, current : Bool }), Endpoint.Refusal)
get! = |{ context, .. }|
	match Auth.sessions!(context.user) {
		Ok(sessions) => Ok(sessions.map(|session| { id: session.id, current: session.id == context.session }))
		Err(DbErr(why)) => Err(Status(503, why))
		Err(BadRow(why)) => Err(Status(503, why))
	}

## POST /sessions: one session of the signed-in user's ended (`revoke`, its id), or every one
## (`everywhere`): how many ended.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : { revoke : Str, everywhere : Bool } } => Try({ ended : U64 }, Endpoint.Refusal)
post! = |{ context, body, .. }| {
	ended = if body.everywhere {
		Auth.sign_out_everywhere!(context.user)
	} else {
		Auth.revoke!(context.user, body.revoke)
	}
	match ended {
		Ok(count) => Ok({ ended: count })
		Err(DbErr(why)) => Err(Status(503, why))
	}
}
