import Db
import Host
import Log
import Setting

## Actors' timers (`Actor.tell_after!`, `Actor.after!`), kept so a restart doesn't lose them
## (D-057, Orleans' reminders): with a database, each is a row of `rocx_actor_timers` until the
## turn that handled its message has ended, and the platform's start sets again every row it finds.
## The host keeps the timers that are waiting (`actors.rs`), and, once a timer's turn has ended,
## however it ended, deletes its row (`rocx:actor-timer-done`, here). Without a database they are
## in the host's memory alone.
##
## A row is written at once, in a call of its own (`Host.isolated!`), outside any transaction the
## caller has open, as a tell is sent at once: a transaction that rolls back doesn't take its timers
## with it. Delivery is at least once: a server killed in the middle of a timer's turn, or before
## its row was deleted, tells it again after its restart.
##
## A timer's number is random (63 bits), not counted from the start, so a number an actor keeps in
## its state still names its own timer after a restart, and never another's.
ActorTimers := [].{

	## Sends the actor of `kind` called `key` its message (JSON) in `ms` milliseconds: the timer's
	## number. With a database, its row is written first; if it can't be, the timer is kept in
	## memory alone, and the log says so.
	set! : Str, Str, U64, Str => U64
	set! = |kind, key, ms, message| {
		timer = Host.random_u64!({}) // 2
		if Setting.database!({}) {
			kept = { timer: timer.to_str(), kind, key, message, at: (Host.now_millis!({}) + ms).to_str() }
			ran = Host.isolated!("rocx:actor-timer-set", Json.to_str(kept), 0)
			if ran.status != 0 {
				Log.error!("rocx actor: a timer kept in memory alone: its row couldn't be written", { actor: kind, key, error: ran.out })
			}
		}
		Host.actor_after!(kind, key, ms, message, timer)
		timer
	}

	## Stops a timer, in memory and in the database: one that has fired but whose turn hasn't come
	## is stopped too. One that has been handled, or never was, is nothing to stop.
	cancel! : U64 => {}
	cancel! = |timer| {
		Host.actor_cancel!(timer)
		if Setting.database!({}) {
			ran = Host.isolated!("rocx:actor-timer-done", timer.to_str(), 0)
			if ran.status != 0 {
				Log.error!("rocx actor: a timer's row couldn't be deleted: it is told again after a restart", { timer: timer.to_str(), error: ran.out })
			}
		}
	}

	## The platform's start: each timer the database keeps, set again for the time it has left (or
	## now, if that has passed).
	load! : {} => Try({}, Str)
	load! = |{}|
		if Setting.database!({}) {
			found : Try(List({ id : I64, kind : Str, key : Str, message : Str, at_ms : I64 }), [DbErr(Str), BadRow(Str)])
			found = Db.all!("select id, kind, key, message, at_ms from rocx_actor_timers order by at_ms", [])
			match found {
				Ok(rows) => {
					now = Host.now_millis!({}).to_i64_wrap()
					for row in rows {
						left = if (row.at_ms > now) (row.at_ms - now).to_u64_wrap() else 0
						Host.actor_after!(row.kind, row.key, left, row.message, row.id.to_u64_wrap())
					}
					if !rows.is_empty() {
						Log.info!("rocx actor: timers kept from before the start, set again", { timers: rows.len() })
					}
					Ok({})
				}
				Err(DbErr(why)) => Err("actors' timers: ${why}")
				Err(BadRow(why)) => Err("actors' timers: ${why}")
			}
		} else {
			Ok({})
		}

	## The calls the platform runs for its timers, each in a call of its own (`Host.isolated!`, from
	## here and from the host): `rocx:actor-timer-set`, a row written; `rocx:actor-timer-done`, a
	## timer handled or stopped, its row deleted.
	isolated! : Str, Str => Try(Str, Str)
	isolated! = |what, input|
		if what == "rocx:actor-timer-set" {
			parsed : Try({ timer : Str, kind : Str, key : Str, message : Str, at : Str }, [InvalidJson(Str)])
			parsed = Json.parse(input)
			match parsed {
				Ok(given) => {
					written = Db.run!(
						"insert into rocx_actor_timers (id, kind, key, message, at_ms) values ($1, $2, $3, $4, $5)",
						[Int(number(given.timer)), Text(given.kind), Text(given.key), Text(given.message), Int(number(given.at))],
					)
					match written {
						Ok(_) => Ok("")
						Err(DbErr(why)) => Err(why)
					}
				}
				Err(InvalidJson(why)) => Err("a timer: ${why}")
			}
		} else if what == "rocx:actor-timer-done" {
			match Db.run!("delete from rocx_actor_timers where id = $1", [Int(number(input))]) {
				Ok(_) => Ok("")
				Err(DbErr(why)) => Err(why)
			}
		} else {
			Err("nothing in the platform is called ${what}")
		}
}

## A timer's number, or a time, as an integer (both under 2^63).
number : Str -> I64
number = |text| (U64.from_str(text) ?? 0).to_i64_wrap()
