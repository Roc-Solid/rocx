import pf.Db
import pf.Log
import pf.Random
import pf.Time
import AuthStore
import Rules

## Roles (D-127): what a user holds, and why. A role is one of the app's own tags (`[Pro, Admin]`),
## and so is the reason it is held (`via`: `[Paid, Trial, Gift]`), so a misspelt one is the
## compiler's to catch; the table keeps each as its JSON. A user holds a role while any of their
## grants of it lasts: one grant for each reason, so a subscription that ends never takes away a
## gift, and a gift isn't cut short by a payment.
##
## ```roc
## Roles.grant!({ user, role: Pro, via: Gift, by: admin })                       # for good
## Roles.grant!({ user, role: Pro, via: Paid, by: "stripe", ends: At(period_end) })
## Roles.revoke!({ user, role: Pro, via: Gift, by: admin })
## Roles.has!(user, Pro)                                                         # Bool
## Roles.of!(user)                                                               # every grant, past ones too
## ```
##
## Granting again while a grant lasts changes its end (and its `by` and note): a row is one
## unbroken stretch, so a monthly payment that grants until the next period's end keeps one row.
## Nothing is deleted but by `forget!`: a grant that ran out or was revoked stays, for `of!` to
## show (what ended when, and who ended it) and for the app to ask (has this user had a trial?).
## Who may grant and revoke is the app's to decide before it calls, as with `Auth.impersonate!`;
## the package puts each on the log. The tables come with `Auth.plugin` (`auth/0005_roles`).
Roles := [].{

	## How long a grant lasts: for good, or until a time (milliseconds since 1970).
	Ends : [Never, At(I64)]

	## A grant: `user` holds `role` because of `via`, given `by` (an admin's id, or what gave it:
	## `"stripe"`, `"trial"`), for as long as `ends` says (for good unless it says), with a `note`
	## for whoever reads `of!` (why it was given).
	Grant(role, via) := {
		user : Str,
		role : role,
		via : via,
		by : Str,
		ends : Roles.Ends ?? Never,
		note : Str ?? "",
	}

	## A grant ended before its time: `user`'s `role` held because of `via`, ended `by` whoever
	## ends it.
	Revoke(role, via) : { user : Str, role : role, via : via, by : Str }

	## Where a grant stands: lasting, run out (its end has come), or revoked (when, and by whom).
	State : [Current, Ended, Revoked({ at_ms : I64, by : Str })]

	## A grant as `of!` reads it: the role, the reason, who gave it and when, its end, its note, and
	## where it stands now.
	Held(role, via) : { role : role, via : via, by : Str, since_ms : I64, ends : Roles.Ends, note : Str, state : Roles.State }

	## `grant.user` holds `grant.role` because of `grant.via` until `grant.ends`. If a grant of the
	## same role for the same reason lasts, it now ends then (sooner or later than before), given by
	## `grant.by`, with `grant.note`; else a grant starts now. Two at once give one grant.
	grant! : Roles.Grant(role, via) => Try({}, [DbErr(Str), ..others]) where [role.Json.Encodable([]), via.Json.Encodable([])]
	grant! = |grant| {
		now = now!({})
		role = Json.to_str(grant.role)
		via = Json.to_str(grant.via)
		ends =
			match grant.ends {
				Never => Null
				At(ms) => Int(ms)
			}
		id = Rules.token(Random.bytes!(16))
		Db.transaction!(|{}| AuthStore.grant_role!({ id, user: grant.user, role, via, by: grant.by, now, ends, note: grant.note }))?
		Log.info!("auth: role granted", { user: grant.user, role, via, by: grant.by, ends_ms: Roles.ends_ms(grant.ends) })
		Ok({})
	}

	## Ends `revoked.user`'s grant of `revoked.role` because of `revoked.via` now, if it lasts:
	## whether one did. Their grants of it for other reasons stay.
	revoke! : Roles.Revoke(role, via) => Try(Bool, [DbErr(Str), ..others]) where [role.Json.Encodable([]), via.Json.Encodable([])]
	revoke! = |revoked| {
		role = Json.to_str(revoked.role)
		via = Json.to_str(revoked.via)
		ended = AuthStore.revoke_role!({ user: revoked.user, role, via, by: revoked.by, now: now!({}) })?
		if ended > 0 {
			Log.info!("auth: role revoked", { user: revoked.user, role, via, by: revoked.by })
		}
		Ok(ended > 0)
	}

	## Whether `user` holds `role` now, for any reason. No when the database can't be read (and an
	## error on the log), so what it guards stays shut.
	has! : Str, role => Bool where [role.Json.Encodable([])]
	has! = |user, role|
		match AuthStore.holds_role!(user, Json.to_str(role), now!({})) {
			Ok(held) => held
			Err(DbErr(why)) | Err(BadRow(why)) => {
				Log.error!("auth: roles couldn't be read", { user, error: why })
				Bool.False
			}
		}

	## Every grant `user` has had, the latest given first, with where each stands now. A row whose
	## role or reason the app's tags no longer read (one renamed since) is left out, and said on the
	## log.
	of! : Str => Try(List(Roles.Held(role, via)), [DbErr(Str), BadRow(Str), ..others]) where [role.Json.Parseable([InvalidJson(Str)]), via.Json.Parseable([InvalidJson(Str)])]
	of! = |user| {
		now = now!({})
		rows = AuthStore.roles_of!(user)?
		var $held = []
		for row in rows {
			match (Json.parse(row.role), Json.parse(row.via)) {
				(Ok(role), Ok(via)) => {
					$held = $held.append({ role, via, by: row.granted_by, since_ms: row.granted_at, ends: Roles.ends_of(row.ends_at), note: row.note, state: Roles.state(row, now) })
				}
				_ => Log.warn!("auth: a role the app's tags don't read, left out", { user, role: row.role, via: row.via })
			}
		}
		Ok($held)
	}

	## Forgets every grant `user` has had, as the app deletes them: how many.
	forget! : Str => Try(U64, [DbErr(Str), ..others])
	forget! = |user| AuthStore.forget_roles!(user)

	## An end as a column has it: `Null` for good.
	ends_of : Db.Nullable(I64) -> Roles.Ends
	ends_of = |column|
		match column {
			Some(ms) => At(ms)
			Null => Never
		}

	## An end as the log writes it: 0 for good.
	ends_ms : Roles.Ends -> I64
	ends_ms = |ends|
		match ends {
			Never => 0
			At(ms) => ms
		}

	## Where a grant's row stands at `now`: revoked (it says who), or open and lasting, or else ended.
	state : { ends_at : Db.Nullable(I64), closed_at : Db.Nullable(I64), revoked_by : Db.Nullable(Str), .. }, I64 -> Roles.State
	state = |row, now|
		match (row.closed_at, row.revoked_by) {
			(Some(at), Some(by)) => Revoked({ at_ms: at, by })
			(Some(_), Null) => Ended
			(Null, _) =>
				match row.ends_at {
					Some(ends) if ends <= now => Ended
					_ => Current
				}
		}
}

## Now, in milliseconds since 1970.
now! : {} => I64
now! = |{}| Time.now_millis!({}).to_i64_wrap()

expect Roles.state({ ends_at: Null, closed_at: Null, revoked_by: Null }, 5) == Current
expect Roles.state({ ends_at: Some(10), closed_at: Null, revoked_by: Null }, 5) == Current
expect Roles.state({ ends_at: Some(10), closed_at: Null, revoked_by: Null }, 10) == Ended
expect Roles.state({ ends_at: Some(10), closed_at: Some(10), revoked_by: Null }, 20) == Ended
expect Roles.state({ ends_at: Null, closed_at: Some(7), revoked_by: Some("ana") }, 20) == Revoked({ at_ms: 7, by: "ana" })
expect Roles.ends_of(Some(3)) == At(3)
expect Roles.ends_of(Null) == Never
expect Roles.ends_ms(Never) == 0
