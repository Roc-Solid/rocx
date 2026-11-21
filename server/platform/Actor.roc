import Host

## State that outlives a request, changed one message at a time: an actor is a kind and a key (the
## cart of member 7, the counter called `visits`). Nobody makes one or ends one: a message to any
## key finds it as its last message left it, or new (`initial(key)`), and it handles its messages
## one at a time, in the order they came. With a database, its state is kept in Postgres
## (`rocx_actors`), so it is there after a restart.
##
## ```roc
## cart : Actor.Kind({ items : List(Str) }, [Add(Str), Clear], U64)
## cart = Actor.define({
##     name: "cart",
##     initial: |_key| { items: [] },
##     receive!: |_me, state, message|
##         match message {
##             Add(item) => { state: { items: state.items.append(item) }, reply: state.items.len() + 1 }
##             Clear => { state: { items: [] }, reply: 0 }
##         },
## })
##
## count = Actor.ask!(cart, member, Add("a book"))?
## Actor.tell!(cart, member, Clear)
## ```
##
## `rocx build` lists the kinds an app's modules define (`program.actors`, each `Actor.handler`), so
## the server can run an actor when nobody waits on it: a tell, a timer. Each actor has a mailbox in
## the host, and its turns run one after another, each in a call of its own. Messages, replies and
## state go to the host as JSON: a message an actor doesn't take, or a crash in its `receive!`, is
## logged as an error and told to its asker, and the actor goes on, its state as it was.
Actor := [].{

	## A kind of actor: its name, its state when it is new (from its key), and how it handles a
	## message: its next state, and its reply (`ask!`'s; a tell's goes nowhere). `receive!` is given
	## the actor itself (`Me`), for its key and the timers it sets.
	Kind(state, message, reply) : {
		name : Str,
		initial : Str -> state,
		receive! : Me(message), state, message => { state : state, reply : reply },
	}

	## The actor whose turn it is, as its `receive!` is given it: its key (`key_of`), and the messages
	## it sends itself later (`after!`), typed as its kind takes them.
	Me(message) := { kind : Str, key : Str }

	## A timer's number (`after!`, `tell_after!`), to stop it with (`cancel!`); an actor may keep it
	## in its state. Timers are in the server's memory: a restart loses them (a job is for what must
	## happen even so).
	Timer : U64

	## A kind of actor as the platform runs it, its types erased (`handler`): its name, and its turn
	## on JSON: its key, its state ("" when it is new) and the message, to its next state and its
	## reply.
	Handler : { name : Str, run! : Str, Str, Str => Try({ state : Str, reply : Str }, Str) }

	## A kind of actor, by name: `name`, unique in the app (its actors' state is kept under it);
	## `initial`, the state of one that is new, from its key; `receive!`, what it does with a message.
	define : Kind(state, message, reply) -> Kind(state, message, reply)
	define = |kind| kind

	## The key of the actor whose turn it is.
	key_of : Me(message) -> Str
	key_of = |me| {
		{ key, kind: _ } = me
		key
	}

	## The reply of the actor of `kind` called `key` to `message`, once it has handled the messages
	## before it; or `ActorErr` with why there is none: it doesn't take the message, it crashed, it
	## is waiting on the asker's answer (an actor asking itself, or one up its chain of asks: refused
	## at once), or it hasn't answered in 30 s.
	ask! : Kind(state, message, reply), Str, message => Try(reply, [ActorErr(Str)])
		where [message.Json.Encodable([]), reply.Json.Parseable([InvalidJson(Str)])]
	ask! = |kind, key, message|
		match Host.actor_ask!(kind.name, key, Json.to_str(message)) {
			Ok(replied) =>
				match Json.parse(replied) {
					Ok(reply) => Ok(reply)
					Err(InvalidJson(why)) => Err(ActorErr("${kind.name} ${key}: its reply isn't what was asked for: ${why}"))
				}
			Err(why) => Err(ActorErr(why))
		}

	## Sends the actor of `kind` called `key` a message, and goes on: it is handled after the ones
	## before it, its reply goes nowhere, and what goes wrong is logged.
	tell! : Kind(state, message, reply), Str, message => {}
		where [message.Json.Encodable([])]
	tell! = |kind, key, message| Host.actor_tell!(kind.name, key, Json.to_str(message))

	## Sends the actor of `kind` called `key` a message in `ms` milliseconds, as `tell!` would then:
	## the timer, to stop it with (`cancel!`).
	tell_after! : Kind(state, message, reply), Str, U64, message => Timer
		where [message.Json.Encodable([])]
	tell_after! = |kind, key, ms, message| Host.actor_after!(kind.name, key, ms, Json.to_str(message))

	## Sends the actor whose turn it is a message in `ms` milliseconds (a sweep, a reminder, a tick):
	## the timer, to stop it with (`cancel!`). A timer every so often is one that sets the next.
	after! : Me(message), U64, message => Timer
		where [message.Json.Encodable([])]
	after! = |me, ms, message| {
		{ kind, key } = me
		Host.actor_after!(kind, key, ms, Json.to_str(message))
	}

	## Stops a timer that hasn't fired. One that has, or never was, is nothing to stop.
	cancel! : Timer => {}
	cancel! = |timer| Host.actor_cancel!(timer)

	## `kind`, as the platform runs it: what `rocx build` lists in `program.actors`.
	handler : Kind(state, message, reply) -> Handler
		where [state.Json.Encodable([]), state.Json.Parseable([InvalidJson(Str)]), message.Json.Parseable([InvalidJson(Str)]), reply.Json.Encodable([])]
	handler = |kind| { name: kind.name, run!: |key, kept, sent| turn!(kind, key, kept, sent) }
}

## A turn of an actor of `kind` called `key`: its state (`kept`: JSON, "" when it is new) and the
## message (JSON), to its next state and its reply (JSON); or why not, and it stays as it was.
turn! : Actor.Kind(state, message, reply), Str, Str, Str => Try({ state : Str, reply : Str }, Str)
	where [state.Json.Encodable([]), state.Json.Parseable([InvalidJson(Str)]), message.Json.Parseable([InvalidJson(Str)]), reply.Json.Encodable([])]
turn! = |kind, key, kept, sent| {
	state =
		if kept.is_empty() {
			Ok((kind.initial)(key))
		} else {
			match Json.parse(kept) {
				Ok(parsed) => Ok(parsed)
				Err(InvalidJson(why)) => Err("${kind.name} ${key}: its state isn't what its kind keeps: ${why}")
			}
		}
	message =
		match Json.parse(sent) {
			Ok(parsed) => Ok(parsed)
			Err(InvalidJson(why)) => Err("${kind.name} ${key}: a message it doesn't take: ${why}")
		}
	match (state, message) {
		(Ok(now), Ok(said)) => {
			me : Actor.Me(message)
			me = { kind: kind.name, key }
			answered = (kind.receive!)(me, now, said)
			Ok({ state: Json.to_str(answered.state), reply: Json.to_str(answered.reply) })
		}
		(Err(why), _) => Err(why)
		(_, Err(why)) => Err(why)
	}
}
