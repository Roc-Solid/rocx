import pf.Db
import pf.Random
import pf.Time
import crypto.Base64
import auth.Auth

## The app's people, and who gets in (`admit!`, which the auth plugin asks at every sign-in).
Accounts := [].{

	## Someone who has signed in.
	User : { id : Str, email : Str, name : Str }

	## Who gets in: anyone with a verified address, but nobody at refused.example (the example's
	## stand-in for an address an app turns away). An identity that signed in before is its user
	## again; a new one is the user with its address, or a new user. It runs inside the sign-in's
	## transaction, so a new user's row stays only if the session starts.
	admit! : Auth.Identity => Try(Str, Str)
	admit! = |identity|
		if identity.email.ends_with("@refused.example") {
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
