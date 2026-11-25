import pf.Db
import pf.Log
import pf.Random
import pf.Time
import crypto.Base64
import auth.Auth

## The app's users (the `users` table), and who may sign in.
Accounts := [].{

	## A user: their id, their address and their name ("" until they say).
	User : { id : Str, email : Str, name : Str }

	## Who gets in: packages/auth asks at every sign-in. Someone who signed in before is their user
	## again. Someone new is the user with their address, or a new user. An address-less sign-in
	## (a provider that didn't vouch for one) is refused, with the words the sign-in page shows.
	## It runs inside the sign-in's transaction: a new user's row is kept only if the session starts.
	admit! : Auth.Identity => Try(Str, Str)
	admit! = |identity|
		match identity.user {
			Known(user) => Ok(user)
			New =>
				if identity.email.is_empty() {
					Err("${identity.provider} didn't give us a verified email address.")
				} else {
					match made!(identity.email, identity.name) {
						Ok(user) => Ok(user)
						Err(DbErr(why)) | Err(BadRow(why)) => {
							Log.error!("accounts: a user couldn't be made", { error: why })
							Err("Signing in failed just now. Try again in a minute.")
						}
					}
				}
		}

	## The user with id `id`, if there is one.
	user! : Str => Try([Found(Accounts.User), Missing], [DbErr(Str), BadRow(Str)])
	user! = |id| {
		rows : List(Accounts.User)
		rows = Db.all!("select id, email, name from users where id = $1", [Text(id)])?
		match rows.get(0) {
			Ok(found) => Ok(Found(found))
			Err(_) => Ok(Missing)
		}
	}

	## How long ago `then_ms` was at `now_ms`, in days, as a person says it.
	ago : I64, I64 -> Str
	ago = |now_ms, then_ms| {
		days = (now_ms - then_ms) // 86_400_000
		if days <= 0 {
			"today"
		} else if days == 1 {
			"yesterday"
		} else {
			"${days.to_str()} days ago"
		}
	}
}

## The user with address `email`, made if there is none. Ids are random text, so the one migration
## serves SQLite, Postgres and Turso.
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

expect Accounts.ago(86_400_000 * 10, 86_400_000 * 10 - 5_000) == "today"
expect Accounts.ago(86_400_000 * 10, 86_400_000 * 9) == "yesterday"
expect Accounts.ago(86_400_000 * 10, 86_400_000 * 6 - 1) == "4 days ago"
