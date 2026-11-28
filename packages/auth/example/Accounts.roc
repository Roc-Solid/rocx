import pf.Db
import pf.Env
import pf.Random
import pf.Time
import crypto.Base64
import auth.Auth
import auth.Roles

## The app's people, and who gets in (`admit!`, which the auth routes ask at every sign-in).
Accounts := [].{

	## Someone who has signed in.
	User : { id : Str, email : Str, name : Str }

	## Who gets in: anyone with a verified address, but nobody at refused.example (the example's
	## stand-in for an address an app turns away), whose attempt is written down (`turned_away`, as
	## a waiting list would keep its requests). An identity that signed in before is its user
	## again; a new one is the user with its address, or a new user. It runs inside the sign-in's
	## transaction, which commits what it wrote whether it lets them in or not.
	## Where else one may sign in: the plugin's list, and routes/auth/[provider]/'s.
	providers : List(Auth.Provider)
	providers = [Auth.google, Auth.github]

	admit! : Auth.Identity => Try(Str, Str)
	admit! = |identity|
		if identity.email.ends_with("@refused.example") {
			_ = Db.run!("insert into turned_away (email, at) values ($1, $2)", [Text(identity.email), Int(Time.now_millis!({}).to_i64_wrap())])
			Err("This address isn't allowed in.")
		} else {
			match identity.user {
				Known(user) => Ok(user)
				New =>
					if identity.email.is_empty() {
						Err("${identity.provider} didn't give a verified address.")
					} else {
						match made!(identity.email, identity.name) {
							Ok(user) => Ok(user)
							Err(DbErr(why)) => Err("Signing in failed: ${why}")
							Err(BadRow(why)) => Err("Signing in failed: ${why}")
						}
					}
			}
		}

	## Whether user `id` is an admin: their address is on `ADMIN_EMAILS` (`listed!`).
	admin! : Str => Bool
	admin! = |id|
		match Accounts.user!(id) {
			Ok(Found(user)) => Accounts.listed!(user.email)
			_ => Bool.False
		}

	## Whether `email` is on `ADMIN_EMAILS` (commas between). Read each time, so taking someone off
	## the list ends what only an admin may do at their next request.
	listed! : Str => Bool
	listed! = |email| (Env.var!("ADMIN_EMAILS") ?? "").split_on(",").map(|each| each.trim().with_ascii_lowercased()).contains(email)

	## What a user may hold (packages/auth's `Roles`, D-127): Pro, which the `/pro` page asks for.
	Role : [Pro]

	## Why they hold it: an admin's gift (`/roles/grant`), or the trial anyone may start once
	## (`/trial`).
	Via : [Gift, Trial]

	## How long a trial lasts: two weeks.
	trial_ms : I64
	trial_ms = 14 * 24 * 60 * 60 * 1000

	## A grant as the routes answer it: its role and reason by name, who gave it and when, when it
	## ends (0: never), its note, and where it stands (`current`, `ended`, or `revoked` and by whom).
	Shown : { role : Str, via : Str, by : Str, since_ms : I64, ends_ms : I64, note : Str, state : Str, revoked_by : Str }

	## Every grant user `id` has had, the latest given first, as the routes show them.
	grants! : Str => Try(List(Accounts.Shown), [DbErr(Str), BadRow(Str)])
	grants! = |id| {
		held : List(Roles.Held(Accounts.Role, Accounts.Via))
		held = Roles.of!(id)?
		Ok(
			held.map(
				|grant| {
					role: (
						match grant.role {
							Pro => "pro"
						}
					),
					via: (
						match grant.via {
							Gift => "gift"
							Trial => "trial"
						}
					),
					by: grant.by,
					since_ms: grant.since_ms,
					ends_ms: Roles.ends_ms(grant.ends),
					note: grant.note,
					state: (
						match grant.state {
							Current => "current"
							Ended => "ended"
							Revoked(_) => "revoked"
						}
					),
					revoked_by: (
						match grant.state {
							Revoked(revoked) => revoked.by
							_ => ""
						}
					),
				},
			),
		)
	}

	## The user with address `email`, if there is one.
	by_email! : Str => Try([Found(Accounts.User), Missing], [DbErr(Str), BadRow(Str)])
	by_email! = |email| {
		rows : List(Accounts.User)
		rows = Db.all!("select id, email, name from users where email = $1", [Text(email.trim().with_ascii_lowercased())])?
		match rows.get(0) {
			Ok(found) => Ok(Found(found))
			Err(_) => Ok(Missing)
		}
	}

	## The user with id `id`.
	user! : Str => Try([Found(Accounts.User), Missing], [DbErr(Str), BadRow(Str)])
	user! = |id| {
		rows : List(Accounts.User)
		rows = Db.all!("select id, email, name from users where id = $1", [Text(id)])?
		match rows.get(0) {
			Ok(found) => Ok(Found(found))
			Err(_) => Ok(Missing)
		}
	}
}

## The user with address `email`, made if there is none.
made! : Str, Str => Try(Str, [DbErr(Str), BadRow(Str)])
made! = |email, name| {
	rows : List({ id : Str })
	rows = Db.all!("select id from users where email = $1", [Text(email)])?
	match rows.get(0) {
		Ok(found) => Ok(found.id)
		Err(_) => {
			id = Base64.url_encode(Random.bytes!(12))
			_ = Db.run!("insert into users (id, email, name, created_at) values ($1, $2, $3, $4)", [Text(id), Text(email), Text(name), Int(Time.now_millis!({}).to_i64_wrap())])?
			Ok(id)
		}
	}
}
