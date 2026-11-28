import pf.Server
import pf.Endpoint
import pf.Time
import auth.Roles
import auth.Auth
import ../../../../Accounts
import ../../../../Middlewares
import ../../../../Policy

## POST /roles/grant: an admin (`Policy`'s `Grant`: on `ADMIN_EMAILS`, as who really signed in)
## gives the user with address `email` Pro as a gift, for `days` days (0: for good), with a note.
## A gift of theirs that lasts now ends then instead. Anyone else is refused (403).
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : { email : Str, days : U64, note : Str } } => Try({ granted : Str }, Endpoint.Refusal)
post! = |{ context, body, .. }| {
	Policy.need(context, Grant)?
	match Auth.user_by_email!(body.email) {
		Ok(user) => {
			ends = if (body.days == 0) Never else At(Time.now_millis!({}).to_i64_wrap() + body.days.to_i64_wrap() * 24 * 60 * 60 * 1000)
			granted : Accounts.Role
			granted = Pro
			match Roles.grant!({ user: user.id, role: granted, via: Gift, by: context.real_user, ends, note: body.note }) {
				Ok({}) => Ok({ granted: user.email })
				Err(DbErr(why)) => Err(Status(503, why))
			}
		}
		Err(NotFound) => Err(NotFound)
		Err(DbErr(why)) | Err(BadRow(why)) => Err(Status(503, why))
	}
}
