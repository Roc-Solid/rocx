import pf.Server
import pf.Endpoint
import guard.Flags
import ../../../FlagStore
import ../../../Middlewares

middleware = Middlewares.admins

## POST /admin/flags: a flag `on` or `off` for everyone, in place of the code's rule, or `reset`
## to the code's rule again. For admins only.
post! : { request : Server.Request, params : {}, context : Middlewares.Context, body : { name : Str, state : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }| {
	done =
		match body.state {
			"on" => FlagStore.set!(body.name, Flags.on)
			"off" => FlagStore.set!(body.name, Flags.off)
			_ => FlagStore.reset!(body.name)
		}
	match done {
		Ok({}) => Ok(body.state)
		Err(FlagErr(why)) => Err(Status(500, why))
	}
}
