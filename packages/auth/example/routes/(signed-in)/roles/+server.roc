import pf.Server
import pf.Endpoint
import auth.Roles
import ../../../Accounts
import ../../../Middlewares

## GET /roles: whether the signed-in user holds Pro now (for any reason), and every grant they have
## had, the latest given first (packages/auth's `Roles.of!`: past ones too).
## (Each grant as `Accounts.Shown` has it, written out: the browser's copy of the contract can't
## name Accounts, which reads the database.)
get! : { request : Server.Request, params : {}, context : Middlewares.Me } => Try({ pro : Bool, grants : List({ role : Str, via : Str, by : Str, since_ms : I64, ends_ms : I64, note : Str, state : Str, revoked_by : Str }) }, Endpoint.Refusal)
get! = |{ context, .. }|
	match Accounts.grants!(context.user) {
		Ok(grants) => Ok({ pro: Roles.has!(context.user, Pro), grants })
		Err(DbErr(why)) | Err(BadRow(why)) => Err(Status(503, why))
	}
