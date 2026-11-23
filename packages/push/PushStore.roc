import pf.Db
import pf.Time
import Subscription

## The subscriptions table (`migrations/0001_push_subscriptions.sql` on Postgres,
## `0001_push_subscriptions_sqlite.sql` on SQLite): a row for each browser that subscribed, by its
## endpoint, and whose it is (`owner`: the app's id for a user, "" for a visitor). Its statements
## work on both databases (D-045) but one, which asks `Db.backend!` which to run: on SQLite a moment
## is milliseconds, given from here. Server-only: it imports the server platform's `Db`.
PushStore := [].{

	## A row: its id, the subscription's texts, and whose it is.
	Row : { id : I64, endpoint : Str, p256dh : Str, auth : Str, owner : Str }

	## Keeps a subscription for `owner`. A browser that subscribes again (new keys, or another
	## owner signed in) updates its row: an endpoint is one browser's.
	save! : Subscription, Str => Try({}, [DbErr(Str)])
	save! = |subscription, owner| {
		text = Subscription.to_text(subscription)
		saved = Db.run!(
			"insert into push_subscriptions (endpoint, p256dh, auth, owner) values ($1, $2, $3, $4) on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth, owner = excluded.owner, last_error = null",
			[Text(text.endpoint), Text(text.p256dh), Text(text.auth), Text(owner)],
		)
		saved.map_ok(|_| {})
	}

	## Forgets the subscription at `endpoint`, if it is `owner`'s: how many there were (0 or 1).
	remove! : Str, Str => Try(U64, [DbErr(Str)])
	remove! = |endpoint, owner| Db.run!("delete from push_subscriptions where endpoint = $1 and owner = $2", [Text(endpoint), Text(owner)])

	## Forgets subscription `id`: a push service said it is gone.
	remove_id! : I64 => Try(U64, [DbErr(Str)])
	remove_id! = |id| Db.run!("delete from push_subscriptions where id = $1", [Int(id)])

	## Subscription `id`, or `Missing` (it was removed since a message for it was queued).
	find! : I64 => Try([Found(Row), Missing], [DbErr(Str), BadRow(Str)])
	find! = |id| {
		found : Try(List(Row), [DbErr(Str), BadRow(Str)])
		found = Db.all!("${columns} where id = $1", [Int(id)])
		match found {
			Ok([row]) => Ok(Found(row))
			Ok(_) => Ok(Missing)
			Err(problem) => Err(problem)
		}
	}

	## The ids of `owner`'s subscriptions: a browser each.
	of_owner! : Str => Try(List(I64), [DbErr(Str), BadRow(Str)])
	of_owner! = |owner| ids!("select id from push_subscriptions where owner = $1 order by id", [Text(owner)])

	## The ids of every subscription.
	everyone! : {} => Try(List(I64), [DbErr(Str), BadRow(Str)])
	everyone! = |{}| ids!("select id from push_subscriptions order by id", [])

	## Notes that a message reached subscription `id`'s push service.
	delivered! : I64 => Try(U64, [DbErr(Str)])
	delivered! = |id|
		if Db.backend!({}) == Sqlite {
			Db.run!("update push_subscriptions set last_sent_at = $2, last_error = null where id = $1", [Int(id), Int(Time.now_millis!({}).to_i64_wrap())])
		} else {
			Db.run!("update push_subscriptions set last_sent_at = now(), last_error = null where id = $1", [Int(id)])
		}

	## Notes why a push service refused a message for subscription `id`.
	refused! : I64, Str => Try(U64, [DbErr(Str)])
	refused! = |id, why| Db.run!("update push_subscriptions set last_error = $2 where id = $1", [Int(id), Text(why)])
}

columns : Str
columns = "select id, endpoint, p256dh, auth, owner from push_subscriptions"

ids! : Str, List(Db.Value) => Try(List(I64), [DbErr(Str), BadRow(Str)])
ids! = |sql, params| {
	rows : Try(List({ id : I64 }), [DbErr(Str), BadRow(Str)])
	rows = Db.all!(sql, params)
	rows.map_ok(|each| each.map(|row| row.id))
}
