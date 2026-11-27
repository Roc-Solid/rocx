import pf.Db

## packages/auth's statements, the same on SQLite and on Postgres (its tables keep times as
## milliseconds, given here, so no statement needs `now()`): sessions, sign-in links, the
## identities that signed in before, and two-factor sign-in (authenticators, recovery codes, and
## sign-ins waiting for a code). Each is a statement, so inside `Db.transaction!` it is part of
## the transaction. Errors are open unions, so a body can `?` them beside the app's own.
AuthStore := [].{

	## A session as its row has it: its id (the token's hash), whose it is, and until when; and,
	## while an admin acts as someone else, as whom and until when (`Null` otherwise).
	Row : { id : Str, user_id : Str, created_at : I64, expires_at : I64, acting_as : Db.Nullable(Str), acting_until : Db.Nullable(I64) }

	## Starts a session for `user`, kept by `id` (its token's hash) until `expires`; and sweeps out
	## the sessions and links that have expired, so the tables don't grow without end.
	start! : { id : Str, user : Str, now : I64, expires : I64 } => Try({}, [DbErr(Str), ..others])
	start! = |session| {
		_ = Db.run!("delete from auth_sessions where expires_at <= $1", [Int(session.now)])?
		_ = Db.run!("delete from auth_links where expires_at <= $1", [Int(session.now)])?
		_ = Db.run!("delete from auth_waiting where expires_at <= $1", [Int(session.now)])?
		_ = Db.run!("insert into auth_sessions (id, user_id, created_at, expires_at) values ($1, $2, $3, $4)", [Text(session.id), Text(session.user), Int(session.now), Int(session.expires)])?
		Ok({})
	}

	## The session kept by `id`, if it hasn't expired by `now`.
	find! : Str, I64 => Try([Found(AuthStore.Row), Missing], [DbErr(Str), BadRow(Str), ..others])
	find! = |id, now| {
		rows : List(AuthStore.Row)
		rows = Db.all!("select id, user_id, created_at, expires_at, acting_as, acting_until from auth_sessions where id = $1 and expires_at > $2", [Text(id), Int(now)])?
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

	## Ends every session of `user`, and every sign-in of theirs waiting for a code: how many
	## sessions ended.
	end_all! : Str => Try(U64, [DbErr(Str), ..others])
	end_all! = |user| {
		_ = Db.run!("delete from auth_waiting where user_id = $1", [Text(user)])?
		Db.run!("delete from auth_sessions where user_id = $1", [Text(user)])
	}

	## `user`'s sessions that haven't expired by `now`, the newest first.
	of_user! : Str, I64 => Try(List(AuthStore.Row), [DbErr(Str), BadRow(Str), ..others])
	of_user! = |user, now| Db.all!("select id, user_id, created_at, expires_at, acting_as, acting_until from auth_sessions where user_id = $1 and expires_at > $2 order by created_at desc", [Text(user), Int(now)])

	## The session kept by `id` acts as `user` until `until` (impersonation), or, with `Null`, as
	## its own user again: how many changed (0 or 1).
	act! : Str, Db.Value, Db.Value => Try(U64, [DbErr(Str), ..others])
	act! = |id, user, until| Db.run!("update auth_sessions set acting_as = $2, acting_until = $3 where id = $1", [Text(id), user, until])

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

	## Where the link kept by `id` was going, expired or not (a link that has gone by keeps its row
	## until the next sweep): for the sign-in page a failed link goes to.
	return_to! : Str => Try([Found(Str), Missing], [DbErr(Str), BadRow(Str), ..others])
	return_to! = |id| {
		rows : List({ return_to : Str })
		rows = Db.all!("select return_to from auth_links where id = $1", [Text(id)])?
		match rows.get(0) {
			Ok(row) => Ok(Found(row.return_to))
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

	## A user's authenticator, as its row has it: its secret, sealed; when it was turned on (`Null`
	## while it waits for its first code); the last step a code was taken at; how many wrong codes
	## it has had in a row, and when the last was (`Rules.locked`).
	Authenticator : { secret : Str, enabled_at : Db.Nullable(I64), last_step : I64, misses : I64, missed_at : I64 }

	## `user`'s authenticator, on or waiting, if they have one.
	authenticator! : Str => Try([Found(AuthStore.Authenticator), Missing], [DbErr(Str), BadRow(Str), ..others])
	authenticator! = |user| {
		rows : List(AuthStore.Authenticator)
		rows = Db.all!("select secret, enabled_at, last_step, misses, missed_at from auth_two_factor where user_id = $1", [Text(user)])?
		match rows.get(0) {
			Ok(row) => Ok(Found(row))
			Err(_) => Ok(Missing)
		}
	}

	## Whether `user`'s two-factor sign-in is on (a row read wrongly is a database error, so a
	## sign-in's errors stay `DbErr`).
	two_factor_on! : Str => Try(Bool, [DbErr(Str), ..others])
	two_factor_on! = |user| {
		read : Try(List({ user_id : Str }), [DbErr(Str), BadRow(Str)])
		read = Db.all!("select user_id from auth_two_factor where user_id = $1 and enabled_at is not null", [Text(user)])
		match read {
			Ok(rows) => Ok(!rows.is_empty())
			Err(DbErr(why)) => Err(DbErr(why))
			Err(BadRow(why)) => Err(DbErr(why))
		}
	}

	## How many unused recovery codes `user` has.
	recovery_left! : Str => Try(U64, [DbErr(Str), BadRow(Str), ..others])
	recovery_left! = |user| {
		rows : List({ n : I64 })
		rows = Db.all!("select count(*) as n from auth_recovery_codes where user_id = $1", [Text(user)])?
		Ok((rows.get(0).map_ok(|row| row.n) ?? 0).to_u64_wrap())
	}

	## Keeps a new authenticator for `user`, waiting for its first code, in place of one that was
	## waiting: `Ok(0)` when theirs is on already, and nothing changes.
	pending! : { user : Str, secret : Str, now : I64 } => Try(U64, [DbErr(Str), BadRow(Str), ..others])
	pending! = |made| {
		on = AuthStore.two_factor_on!(made.user)?
		if on {
			Ok(0)
		} else {
			_ = Db.run!("delete from auth_two_factor where user_id = $1", [Text(made.user)])?
			Db.run!("insert into auth_two_factor (user_id, secret, enabled_at, last_step, created_at) values ($1, $2, null, 0, $3)", [Text(made.user), Text(made.secret), Int(made.now)])
		}
	}

	## Turns on `user`'s waiting authenticator, its first code taken at `step`: how many changed (0
	## or 1).
	enable! : Str, I64, I64 => Try(U64, [DbErr(Str), ..others])
	enable! = |user, now, step| Db.run!("update auth_two_factor set enabled_at = $2, last_step = $3 where user_id = $1 and enabled_at is null", [Text(user), Int(now), Int(step)])

	## Takes a code of `user`'s at `step`, if no code has been taken at it or later, in one
	## statement (two posts of one code at once: one is taken): how many changed (0 or 1).
	used_step! : Str, I64 => Try(U64, [DbErr(Str), ..others])
	used_step! = |user, step| Db.run!("update auth_two_factor set last_step = $2 where user_id = $1 and last_step < $2 and enabled_at is not null", [Text(user), Int(step)])

	## Counts a code given for `user` at `now` as wrong until it is found right (`right_code!`), if
	## their authenticator has had `misses` wrong ones in a row, as it was read: how many changed (0
	## or 1). 0 when another code of theirs was counted meanwhile, so two at once can't both go by
	## the count one read.
	tried_code! : Str, I64, I64 => Try(U64, [DbErr(Str), ..others])
	tried_code! = |user, misses, now| Db.run!("update auth_two_factor set misses = misses + 1, missed_at = $3 where user_id = $1 and misses = $2 and enabled_at is not null", [Text(user), Int(misses), Int(now)])

	## A right code of `user`'s: no wrong ones in a row.
	right_code! : Str => Try(U64, [DbErr(Str), ..others])
	right_code! = |user| Db.run!("update auth_two_factor set misses = 0 where user_id = $1", [Text(user)])

	## Turns `user`'s two-factor sign-in off: their authenticator and recovery codes gone.
	disable! : Str => Try({}, [DbErr(Str), ..others])
	disable! = |user| {
		_ = Db.run!("delete from auth_recovery_codes where user_id = $1", [Text(user)])?
		_ = Db.run!("delete from auth_two_factor where user_id = $1", [Text(user)])?
		Ok({})
	}

	## `user`'s recovery codes, by their hashes (`ids`), in place of any they had.
	recovery_codes! : Str, List(Str), I64 => Try({}, [DbErr(Str), ..others])
	recovery_codes! = |user, ids, now| {
		_ = Db.run!("delete from auth_recovery_codes where user_id = $1", [Text(user)])?
		for id in ids {
			_ = Db.run!("insert into auth_recovery_codes (user_id, id, created_at) values ($1, $2, $3)", [Text(user), Text(id), Int(now)])?
		}
		Ok({})
	}

	## Uses `user`'s recovery code kept by `id` (its hash), deleting it in one statement, so it
	## works once: how many were used (0 or 1).
	use_recovery! : Str, Str => Try(U64, [DbErr(Str), ..others])
	use_recovery! = |user, id| Db.run!("delete from auth_recovery_codes where user_id = $1 and id = $2", [Text(user), Text(id)])

	## A sign-in waiting for its code, as its row has it: whose, where it goes after, how many wrong
	## codes it has had.
	Waiting : { user_id : Str, return_to : Str, attempts : I64 }

	## Keeps a sign-in of `user`'s waiting for its code, by `id` (its token's hash), going on to
	## `then`, until `expires`; and sweeps out those that have expired.
	wait! : { id : Str, user : Str, then : Str, now : I64, expires : I64 } => Try({}, [DbErr(Str), ..others])
	wait! = |waiting| {
		_ = Db.run!("delete from auth_waiting where expires_at <= $1", [Int(waiting.now)])?
		_ = Db.run!("insert into auth_waiting (id, user_id, return_to, attempts, expires_at) values ($1, $2, $3, 0, $4)", [Text(waiting.id), Text(waiting.user), Text(waiting.then), Int(waiting.expires)])?
		Ok({})
	}

	## The sign-in waiting by `id`, if it hasn't expired by `now`.
	waiting! : Str, I64 => Try([Found(AuthStore.Waiting), Missing], [DbErr(Str), BadRow(Str), ..others])
	waiting! = |id, now| {
		rows : List(AuthStore.Waiting)
		rows = Db.all!("select user_id, return_to, attempts from auth_waiting where id = $1 and expires_at > $2", [Text(id), Int(now)])?
		match rows.get(0) {
			Ok(row) => Ok(Found(row))
			Err(_) => Ok(Missing)
		}
	}

	## A wrong code for the sign-in waiting by `id`: how many it has had now.
	missed! : Str => Try(I64, [DbErr(Str), BadRow(Str), ..others])
	missed! = |id| {
		rows : List({ attempts : I64 })
		rows = Db.all!("update auth_waiting set attempts = attempts + 1 where id = $1 returning attempts", [Text(id)])?
		Ok(rows.get(0).map_ok(|row| row.attempts) ?? 0)
	}

	## Takes the sign-in waiting by `id` (a right code came), in one statement, so two posts at
	## once can't both make a session: whose it was, and where it goes.
	done_waiting! : Str => Try([Found({ user_id : Str, return_to : Str }), Missing], [DbErr(Str), BadRow(Str), ..others])
	done_waiting! = |id| {
		rows : List({ user_id : Str, return_to : Str })
		rows = Db.all!("delete from auth_waiting where id = $1 returning user_id, return_to", [Text(id)])?
		match rows.get(0) {
			Ok(row) => Ok(Found(row))
			Err(_) => Ok(Missing)
		}
	}

	## Ends the sign-in waiting by `id`: how many ended (0 or 1).
	end_waiting! : Str => Try(U64, [DbErr(Str), ..others])
	end_waiting! = |id| Db.run!("delete from auth_waiting where id = $1", [Text(id)])

	# ---- Roles (D-127, `Roles`): the app's tags kept as their JSON ----

	## A grant's row: its role and reason (the app's tags, as JSON), who gave it and when, until when
	## (`Null`: for good), its note, and once it stopped being the open one, when, and who revoked
	## it (`Null` when it ran out).
	RoleRow : { id : Str, role : Str, via : Str, granted_by : Str, granted_at : I64, ends_at : Db.Nullable(I64), note : Str, closed_at : Db.Nullable(I64), revoked_by : Db.Nullable(Str) }

	## `user` holds `role` because of `via` (each its JSON), given `by`, until `ends` (`Null`: for
	## good). The open row for the three (`auth_roles_open`), if it lasts at `now`, gets the new end,
	## `by` and note; one that ran out is closed first (at its end), and a row opened, `id` its id.
	## Each is one statement, so two grants at once can't open two rows: the second changes the row
	## the first opened. Run it in a transaction, so the two go together (`Roles.grant!` does).
	grant_role! : { id : Str, user : Str, role : Str, via : Str, by : Str, now : I64, ends : Db.Value, note : Str } => Try({}, [DbErr(Str), ..others])
	grant_role! = |grant| {
		_ = Db.run!("update auth_roles set closed_at = ends_at where user_id = $1 and role = $2 and via = $3 and closed_at is null and ends_at is not null and ends_at <= $4", [Text(grant.user), Text(grant.role), Text(grant.via), Int(grant.now)])?
		_ = Db.run!(
			"insert into auth_roles (id, user_id, role, via, granted_by, granted_at, ends_at, note) values ($1, $2, $3, $4, $5, $6, $7, $8) on conflict (user_id, role, via) where closed_at is null do update set ends_at = excluded.ends_at, granted_by = excluded.granted_by, note = excluded.note",
			[Text(grant.id), Text(grant.user), Text(grant.role), Text(grant.via), Text(grant.by), Int(grant.now), grant.ends, Text(grant.note)],
		)?
		Ok({})
	}

	## Ends `user`'s grant of `role` because of `via` at `now`, `by` whoever ends it, if it lasts
	## then (one that ran out stays as it ended): how many ended (0 or 1).
	revoke_role! : { user : Str, role : Str, via : Str, by : Str, now : I64 } => Try(U64, [DbErr(Str), ..others])
	revoke_role! = |revoked| Db.run!("update auth_roles set closed_at = $5, revoked_by = $4 where user_id = $1 and role = $2 and via = $3 and closed_at is null and (ends_at is null or ends_at > $5)", [Text(revoked.user), Text(revoked.role), Text(revoked.via), Text(revoked.by), Int(revoked.now)])

	## Whether `user` holds `role` (its JSON) at `now`, for any reason.
	holds_role! : Str, Str, I64 => Try(Bool, [DbErr(Str), BadRow(Str), ..others])
	holds_role! = |user, role, now| {
		rows : List({ id : Str })
		rows = Db.all!("select id from auth_roles where user_id = $1 and role = $2 and closed_at is null and (ends_at is null or ends_at > $3) limit 1", [Text(user), Text(role), Int(now)])?
		Ok(!rows.is_empty())
	}

	## Every grant `user` has had, the latest given first.
	roles_of! : Str => Try(List(AuthStore.RoleRow), [DbErr(Str), BadRow(Str), ..others])
	roles_of! = |user| Db.all!("select id, role, via, granted_by, granted_at, ends_at, note, closed_at, revoked_by from auth_roles where user_id = $1 order by granted_at desc, id", [Text(user)])

	## Forgets every grant `user` has had (the user is gone): how many.
	forget_roles! : Str => Try(U64, [DbErr(Str), ..others])
	forget_roles! = |user| Db.run!("delete from auth_roles where user_id = $1", [Text(user)])
}
