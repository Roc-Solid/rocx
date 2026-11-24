import pf.Db

## packages/auth's statements, the same on SQLite and on Postgres (its tables keep times as
## milliseconds, given here, so no statement needs `now()`): sessions, sign-in links, and the
## identities that signed in before. Each is a statement, so inside `Db.transaction!` it is part of
## the transaction. Errors are open unions, so a body can `?` them beside the app's own.
AuthStore := [].{

	## A session as its row has it: its id (the token's hash), whose it is, and until when.
	Row : { id : Str, user_id : Str, created_at : I64, expires_at : I64 }

	## Starts a session for `user`, kept by `id` (its token's hash) until `expires`; and sweeps out
	## the sessions and links that have expired, so the tables don't grow without end.
	start! : { id : Str, user : Str, now : I64, expires : I64 } => Try({}, [DbErr(Str), ..others])
	start! = |session| {
		_ = Db.run!("delete from auth_sessions where expires_at <= $1", [Int(session.now)])?
		_ = Db.run!("delete from auth_links where expires_at <= $1", [Int(session.now)])?
		_ = Db.run!("insert into auth_sessions (id, user_id, created_at, expires_at) values ($1, $2, $3, $4)", [Text(session.id), Text(session.user), Int(session.now), Int(session.expires)])?
		Ok({})
	}

	## The session kept by `id`, if it hasn't expired by `now`.
	find! : Str, I64 => Try([Found(AuthStore.Row), Missing], [DbErr(Str), BadRow(Str), ..others])
	find! = |id, now| {
		rows : List(AuthStore.Row)
		rows = Db.all!("select id, user_id, created_at, expires_at from auth_sessions where id = $1 and expires_at > $2", [Text(id), Int(now)])?
		match rows.get(0) {
			Ok(row) => Ok(Found(row))
			Err(_) => Ok(Missing)
		}
	}

	## Keeps the session kept by `id` until `expires`.
	renew! : Str, I64 => Try(U64, [DbErr(Str), ..others])
	renew! = |id, expires| Db.run!("update auth_sessions set expires_at = $2 where id = $1", [Text(id), Int(expires)])

	## Ends the session kept by `id`: how many ended (0 or 1).
	end! : Str => Try(U64, [DbErr(Str), ..others])
	end! = |id| Db.run!("delete from auth_sessions where id = $1", [Text(id)])

	## Ends `user`'s session kept by `id`, and no one else's: how many ended (0 or 1).
	revoke! : Str, Str => Try(U64, [DbErr(Str), ..others])
	revoke! = |user, id| Db.run!("delete from auth_sessions where id = $1 and user_id = $2", [Text(id), Text(user)])

	## Ends every session of `user`: how many ended.
	end_all! : Str => Try(U64, [DbErr(Str), ..others])
	end_all! = |user| Db.run!("delete from auth_sessions where user_id = $1", [Text(user)])

	## `user`'s sessions that haven't expired by `now`, the newest first.
	of_user! : Str, I64 => Try(List(AuthStore.Row), [DbErr(Str), BadRow(Str), ..others])
	of_user! = |user, now| Db.all!("select id, user_id, created_at, expires_at from auth_sessions where user_id = $1 and expires_at > $2 order by created_at desc", [Text(user), Int(now)])

	## Keeps a sign-in link on its way, by its token's hash (`id`): whose address it signs in, where
	## it goes after, until when.
	link! : { id : Str, email : Str, then : Str, expires : I64 } => Try({}, [DbErr(Str), ..others])
	link! = |made| {
		_ = Db.run!("insert into auth_links (id, email, return_to, expires_at) values ($1, $2, $3, $4)", [Text(made.id), Text(made.email), Text(made.then), Int(made.expires)])?
		Ok({})
	}

	## The link kept by `id`, if it hasn't expired by `now`, left as it is: what a page that asks
	## first shows.
	peek_link! : Str, I64 => Try([Found({ email : Str, return_to : Str }), Missing], [DbErr(Str), BadRow(Str), ..others])
	peek_link! = |id, now| {
		rows : List({ email : Str, return_to : Str })
		rows = Db.all!("select email, return_to from auth_links where id = $1 and expires_at > $2", [Text(id), Int(now)])?
		match rows.get(0) {
			Ok(row) => Ok(Found(row))
			Err(_) => Ok(Missing)
		}
	}

	## Uses the link kept by `id`, if it hasn't expired by `now`: the address it signs in and where
	## it goes, and it is gone, in one statement, so two clicks at once can't both use it.
	use_link! : Str, I64 => Try([Found({ email : Str, return_to : Str }), Missing], [DbErr(Str), BadRow(Str), ..others])
	use_link! = |id, now| {
		rows : List({ email : Str, return_to : Str })
		rows = Db.all!("delete from auth_links where id = $1 and expires_at > $2 returning email, return_to", [Text(id), Int(now)])?
		match rows.get(0) {
			Ok(row) => Ok(Found(row))
			Err(_) => Ok(Missing)
		}
	}

	## The user an identity (`provider`, `subject`) signed in as before, if it has.
	known! : Str, Str => Try([Known(Str), New], [DbErr(Str), BadRow(Str), ..others])
	known! = |provider, subject| {
		rows : List({ user_id : Str })
		rows = Db.all!("select user_id from auth_identities where provider = $1 and subject = $2", [Text(provider), Text(subject)])?
		match rows.get(0) {
			Ok(row) => Ok(Known(row.user_id))
			Err(_) => Ok(New)
		}
	}

	## Records that an identity signed in as `user` (its address as it is now), or moves it to them.
	linked! : { provider : Str, subject : Str, user : Str, email : Str, now : I64 } => Try({}, [DbErr(Str), ..others])
	linked! = |identity| {
		_ = Db.run!(
			"insert into auth_identities (provider, subject, user_id, email, created_at) values ($1, $2, $3, $4, $5) on conflict (provider, subject) do update set user_id = excluded.user_id, email = excluded.email",
			[Text(identity.provider), Text(identity.subject), Text(identity.user), Text(identity.email), Int(identity.now)],
		)?
		Ok({})
	}

	## The identities `user` signs in with: each provider, and the address it gave.
	identities! : Str => Try(List({ provider : Str, subject : Str, email : Str }), [DbErr(Str), BadRow(Str), ..others])
	identities! = |user| Db.all!("select provider, subject, email from auth_identities where user_id = $1 order by provider, subject", [Text(user)])
}
