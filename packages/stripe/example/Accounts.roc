import pf.Db
import pf.Random
import pf.Time
import crypto.Base64
import auth.Auth

## The app's people, and who gets in (`admit!`, which the auth routes ask at every sign-in).
Accounts := [].{

	## Someone who has signed in.
	User : { id : Str, email : Str }

	## Who gets in: anyone with an address. An identity that signed in before is its user again; a
	## new one is the user with its address, or a new user.
	admit! : Auth.Identity => Try(Str, Str)
	admit! = |identity|
		match identity.user {
			Known(user) => Ok(user)
			New =>
				if identity.email.is_empty() {
					Err("${identity.provider} didn't give a verified address.")
				} else {
					match made!(identity.email) {
						Ok(user) => Ok(user)
						Err(DbErr(why)) | Err(BadRow(why)) => Err("Signing in failed: ${why}")
					}
				}
		}

	## The user with id `id`.
	user! : Str => Try([Found(Accounts.User), Missing], [DbErr(Str), BadRow(Str)])
	user! = |id| {
		rows : List(Accounts.User)
		rows = Db.all!("select id, email from users where id = $1", [Text(id)])?
		match rows.get(0) {
			Ok(found) => Ok(Found(found))
			Err(_) => Ok(Missing)
		}
	}
}

## The user with address `email`, made if there is none.
made! : Str => Try(Str, [DbErr(Str), BadRow(Str)])
made! = |email| {
	rows : List({ id : Str })
	rows = Db.all!("select id from users where email = $1", [Text(email)])?
	match rows.get(0) {
		Ok(found) => Ok(found.id)
		Err(_) => {
			id = Base64.url_encode(Random.bytes!(12))
			_ = Db.run!("insert into users (id, email, created_at) values ($1, $2, $3)", [Text(id), Text(email), Int(Time.now_millis!({}).to_i64_wrap())])?
			Ok(id)
		}
	}
}
