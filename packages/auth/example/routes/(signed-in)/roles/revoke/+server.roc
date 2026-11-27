import pf.Server
import pf.Endpoint
import auth.Roles
import ../../../../Accounts
import ../../../../Middlewares

## POST /roles/revoke: an admin ends the gift of Pro the user with address `email` holds, if one
## lasts: whether one did. A trial of theirs stays. Anyone else is refused (403).
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : { email : Str } } => Try({ revoked : Bool }, Endpoint.Refusal)
post! = |{ context, body, .. }|
	if !Accounts.admin!(context.real_user) {
		Err(Forbidden)
	} else {
		match Accounts.by_email!(body.email) {
			Ok(Found(user)) => {
				revoked : Accounts.Role
				revoked = Pro
				match Roles.revoke!({ user: user.id, role: revoked, via: Gift, by: context.real_user }) {
					Ok(ended) => Ok({ revoked: ended })
					Err(DbErr(why)) => Err(Status(503, why))
				}
			}
			Ok(Missing) => Err(NotFound)
			Err(DbErr(why)) | Err(BadRow(why)) => Err(Status(503, why))
		}
	}
