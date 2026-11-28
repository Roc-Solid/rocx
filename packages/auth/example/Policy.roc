import pf.Endpoint
import Accounts

## What a signed-in user may do (D-132): worked out from what the request knows of them, never
## stored. Roles are stored (`Roles.grant!`), and the middleware reads the ones held now once
## (`Roles.current!`) into `Middlewares.Me`; whether someone is an admin comes from `ADMIN_EMAILS`.
## Each check is a rule here, so a route asks for an action (`need(context, UsePro)?`), not for the
## roles behind it, and a rule that changes changes here alone.
##
## `roles` are the user the routes see (behind impersonation, the user acted as); `admin` is who
## really signed in, so what only an admin may do stays theirs while they act as someone.
Policy := [].{

	## What a route asks to do: open `/pro`, see `/admin`, act as someone, give or end a grant.
	Action : [UsePro, Administer, Impersonate, Grant]

	## Whether `me` may do `action`.
	can : { roles : List(Accounts.Role), admin : Bool, .. }, Policy.Action -> Bool
	can = |me, action|
		match action {
			UsePro => me.roles.contains(Pro)
			Administer => me.admin
			Impersonate => me.admin
			Grant => me.admin
		}

	## `can`, as a route's answer: nothing to do when `me` may, else a 403.
	need : { roles : List(Accounts.Role), admin : Bool, .. }, Policy.Action -> Try({}, Endpoint.Refusal)
	need = |me, action| if (Policy.can(me, action)) Ok({}) else Err(Forbidden)
}

expect Policy.can({ roles: [Pro], admin: Bool.False }, UsePro)
expect !Policy.can({ roles: [], admin: Bool.True }, UsePro)
expect Policy.can({ roles: [], admin: Bool.True }, Grant)
expect !Policy.can({ roles: [Pro], admin: Bool.False }, Impersonate)
expect Policy.need({ roles: [Pro], admin: Bool.False }, Administer).is_err()
