import pf.Server
import pf.Endpoint
import pf.Time
import auth.Roles
import ../../../Accounts
import ../../../Middlewares

## POST /trial: the signed-in user starts their trial of Pro, two weeks (`Accounts.trial_ms`), once:
## someone who has had one, lasting or not, is refused (409). Their history of grants says
## (`Roles.of!`), which is why the package keeps it.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : {} } => Try({ ends_ms : I64 }, Endpoint.Refusal)
post! = |{ context, .. }|
	match Accounts.grants!(context.user) {
		Ok(grants) if grants.any(|grant| grant.via == "trial") => Err(Status(409, "You have had your trial."))
		Ok(_) => {
			ends_ms = Time.now_millis!({}).to_i64_wrap() + Accounts.trial_ms
			role : Accounts.Role
			role = Pro
			match Roles.grant!({ user: context.user, role, via: Trial, by: "trial", ends: At(ends_ms) }) {
				Ok({}) => Ok({ ends_ms: ends_ms })
				Err(DbErr(why)) => Err(Status(503, why))
			}
		}
		Err(DbErr(why)) | Err(BadRow(why)) => Err(Status(503, why))
	}
