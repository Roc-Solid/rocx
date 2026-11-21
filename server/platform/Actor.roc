import Db
import Host
import Setting

## State that outlives a request: an actor is called by its kind and a key (`cart` and a member's
## id), handles one message at a time, and keeps its state in Postgres, so it is there after a
## restart. There is no making one: the first message to a key finds it new (`init(key)`).
##
## ```roc
## cart : Actor.Kind({ items : List(Str) }, [Add(Str), Clear], U64)
## cart = Actor.define("cart", |_key| { items: [] }, |state, message|
##     match message {
##         Add(item) => { state: { items: state.items.append(item) }, reply: state.items.len() + 1 }
##         Clear => { state: { items: [] }, reply: 0 }
##     })
##
## count = Actor.ask!(cart, member, Add("a book"))?
## ```
##
## An app doesn't list its kinds of actor: `ask!` is given the kind, and runs it. It takes the
## actor's lock (`Host.lock!`: one message at a time; an actor asking itself is refused, and one
## busy for 30 s is an error, not a hang), reads its state (from the server's memory, or Postgres,
## or `init(key)`), runs its `receive!` in a call of its own (`Host.isolated_call!`, so a crash in it
## is the asker's error and the state stays as it was), writes the next state to Postgres and to
## memory, and lets the lock go. Without a database, the state is in memory only. State, messages
## and replies are kept and passed as JSON.
Actor := [].{

	## A kind of actor: its name, its state when new, and how it answers a message: its next state,
	## and a reply.
	Kind(state, message, reply) : {
		name : Str,
		init : Str -> state,
		receive! : state, message => { state : state, reply : reply },
	}

	define : Str, (Str -> state), (state, message => { state : state, reply : reply }) -> Kind(state, message, reply)
	define = |name, init, receive!| { name, init, receive! }

	## The reply of the actor of `kind` called `key` to `message`, once it has handled the ones
	## before it.
	ask! : Kind(state, message, reply), Str, message => Try(reply, [ActorErr(Str)])
		where [state.Json.Encodable([]), state.Json.Parseable([InvalidJson(Str)]), message.Json.Encodable([]), message.Json.Parseable([InvalidJson(Str)]), reply.Json.Encodable([]), reply.Json.Parseable([InvalidJson(Str)])]
	ask! = |kind, key, message| {
		who = "${kind.name} ${key}"
		lock = "actor:${kind.name}:${key}"
		match Host.lock!(lock, 30000) {
			2 => Err(ActorErr("${who} asked itself: it would wait for its own answer forever"))
			1 => Err(ActorErr("${who} has been busy for 30 s (is it waiting on one that is waiting on it?)"))
			_ => {
				answered = answer!(kind.name, key, lock, Json.to_str(message), Box.box(|input| receive!(kind, input)))
				Host.unlock!(lock)
				match answered {
					Ok(replied) =>
						match Json.parse(replied) {
							Ok(reply) => Ok(reply)
							Err(InvalidJson(why)) => Err(ActorErr("${kind.name}: its reply isn't what was asked for: ${why}"))
						}
					Err(why) => Err(ActorErr(why))
				}
			}
		}
	}
}

## The actor's reply (JSON) to `message` (JSON), its lock held: its state read, `receives!` (its
## kind's `receive!`, as `receive!` runs it) run in a call of its own, its next state kept.
answer! : Str, Str, Str, Str, Box(Str => Try(Str, Str)) => Try(Str, Str)
answer! = |kind, key, lock, message, receives!| {
	kept =
		match Host.store_get!(lock) {
			Ok(state) => Ok(state)
			Err(_) => load!(kind, key)
		}
	match kept {
		Err(why) => Err(why)
		Ok(state) => {
			ran = Host.isolated_call!(receives!, Json.to_str({ key, state, message }))
			match ran.status {
				0 => {
					answered : Try({ state : Str, reply : Str }, [InvalidJson(Str)])
					answered = Json.parse(ran.out)
					match answered {
						Ok(answer) =>
							match save!(kind, key, answer.state) {
								Ok({}) => {
									Host.store_set!(lock, answer.state)
									Ok(answer.reply)
								}
								Err(why) => Err(why)
							}
						Err(InvalidJson(why)) => Err("${kind} ${key}: ${why}")
					}
				}
				1 => Err(ran.out)
				_ => Err("${kind} ${key} crashed: ${ran.out}")
			}
		}
	}
}

## How an actor of `kind` answers a message, in the call of its own `answer!` runs it in: `input`
## is the key, the state it keeps and the message, as JSON (passed in, rather than captured, so
## that what a crash leaves is that call's to free); its answer is its next state and its reply, as
## JSON.
receive! : Actor.Kind(state, message, reply), Str => Try(Str, Str)
	where [state.Json.Encodable([]), state.Json.Parseable([InvalidJson(Str)]), message.Json.Parseable([InvalidJson(Str)]), reply.Json.Encodable([])]
receive! = |kind, input| {
	asked : Try({ key : Str, state : Str, message : Str }, [InvalidJson(Str)])
	asked = Json.parse(input)
	match asked {
		Err(InvalidJson(why)) => Err("${kind.name}: ${why}")
		Ok({ key, state: kept, message: sent }) => {
			state =
				if kept.is_empty() {
					Ok((kind.init)(key))
				} else {
					match Json.parse(kept) {
						Ok(parsed) => Ok(parsed)
						Err(InvalidJson(why)) => Err("${kind.name} ${key}: its state isn't what it keeps: ${why}")
					}
				}
			message =
				match Json.parse(sent) {
					Ok(parsed) => Ok(parsed)
					Err(InvalidJson(why)) => Err("${kind.name}: the message isn't one it takes: ${why}")
				}
			match (state, message) {
				(Ok(now), Ok(said)) => {
					answered = (kind.receive!)(now, said)
					Ok(Json.to_str({ state: Json.to_str(answered.state), reply: Json.to_str(answered.reply) }))
				}
				(Err(why), _) => Err(why)
				(_, Err(why)) => Err(why)
			}
		}
	}
}

## The state Postgres keeps for the actor (empty when it is new, or there is no database).
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
