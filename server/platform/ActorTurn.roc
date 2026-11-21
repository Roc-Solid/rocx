import Actor
import Db
import Setting

## An actor's turn, as the host runs it (`actor_for_host!`): its state read from Postgres the first
## time (after that, the host keeps it as the last turn left it), its message handled
## (`Actor.Handler`), and its next state written, if it changed (an ask that only reads writes
## nothing). Without a database, its state is the host's alone.
ActorTurn := [].{

	## The turn of `actor` called `key`: `loaded` when `kept` is its state as its last turn left it
	## (else it is read here); `message`, as JSON. Its next state and its reply, or why there are
	## none (and nothing is written).
	run! : Actor.Handler, Str, Bool, Str, Str => Try({ state : Str, reply : Str }, Str)
	run! = |actor, key, loaded, kept, message| {
		state = if (loaded) Ok(kept) else load!(actor.name, key)
		match state {
			Err(why) => Err("${actor.name} ${key}: its state couldn't be read: ${why}")
			Ok(now) =>
				match (actor.run!)(key, now, message) {
					Err(why) => Err(why)
					Ok(answer) =>
						if answer.state == now {
							Ok(answer)
						} else {
							match save!(actor.name, key, answer.state) {
								Ok({}) => Ok(answer)
								Err(why) => Err("${actor.name} ${key}: its state couldn't be written: ${why}")
							}
						}
				}
		}
	}
}

## The state Postgres keeps for the actor ("" when it is new, or there is no database).
load! : Str, Str => Try(Str, Str)
load! = |kind, key|
	if Setting.database!({}) {
		found : Try(List({ state : Str }), [DbErr(Str), BadRow(Str)])
		found = Db.all!("select state from rocx_actors where kind = $1 and key = $2", [Text(kind), Text(key)])
		match found {
			Ok([row]) => Ok(row.state)
			Ok(_) => Ok("")
			Err(DbErr(why)) => Err(why)
			Err(BadRow(why)) => Err(why)
		}
	} else {
		Ok("")
	}

save! : Str, Str, Str => Try({}, Str)
save! = |kind, key, state|
	if Setting.database!({}) {
		saved = Db.run!(
			"insert into rocx_actors (kind, key, state) values ($1, $2, $3) on conflict (kind, key) do update set state = excluded.state, updated_at = now()",
			[Text(kind), Text(key), Text(state)],
		)
		match saved {
			Ok(_) => Ok({})
			Err(DbErr(why)) => Err(why)
		}
	} else {
		Ok({})
	}
