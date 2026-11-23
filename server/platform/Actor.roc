import ActorTimers
import Host

## State that outlives a request, changed one turn at a time: an actor is a kind and a key (the
## cart of member 7, the counter called `visits`). Nobody makes one or ends one: a call to any key
## finds it as its last turn left it, or new (`initial(key)`), and it takes its turns one at a time,
## in the order they came. With a database, its state is kept in it (`rocx_actors`), and so are its
## timers (`rocx_actor_timers`), so both are there after a restart.
##
## What an actor does is its kind's methods: each its own input and its own reply, typed (D-066).
##
## ```roc
## cart : Actor.Kind({ items : List(Str) })
## cart = Actor.define({ name: "cart", initial: |_key| { items: [] } })
##
## add : Actor.Method(_, { items : List(Str) }, Str, U64)
## add = Actor.method(cart, "add", |{ state, input, .. }| { state: { items: state.items.append(input) }, reply: state.items.len() + 1 })
##
## clear = Actor.method(cart, "clear", |{ .. }| { state: { items: [] }, reply: {} })
##
## count = Actor.ask!(add, member, "a book")?   # a U64
## Actor.tell!(clear, member, {})
## ```
##
## `rocx build` lists the methods an app's modules define (`program.actors`, each `Actor.handler`), so
## the server can run an actor when nobody waits on it: a tell, a timer. Each actor has a mailbox in
## the host, and its turns, whichever method each is, run one after another, each in a call of its
## own. Inputs, replies and state go to the host as JSON: an input a method doesn't take, or a crash
## in it, is logged as an error and told to its asker, and the actor goes on, its state as it was.
Actor := [].{

	## A kind of actor: its name, unique in the app (its actors' state is kept under it), and the
	## state of one that is new, from its key. What its actors do is its methods (`method`).
	Kind(state) : { name : Str, initial : Str -> state }

	## The actor whose turn it is (a method's `me`): its key (`key_of`), and the calls it makes to
	## itself later (`after!`), to methods of its kind.
	Me(state) := { kind : Str, key : Str }

	## What a method is given on a turn: the actor (`me`), the app's context (what its `init!` made),
	## the actor's state, and the method's input.
	Turn(context, state, input) : { me : Me(state), context : context, state : state, input : input }

	## A method of a kind: its name, unique in its kind, and what a turn of it does: the actor's next
	## state, and the reply (`ask!`'s; a tell's goes nowhere). A method defined without an annotation,
	## or annotated `Actor.Method(_, …)`, takes the app's context as the app has it.
	Method(context, state, input, reply) : { kind : Kind(state), name : Str, run! : Turn(context, state, input) => { state : state, reply : reply } }

	## A timer's number (`after!`, `tell_after!`), to stop it with (`cancel!`); an actor may keep it
	## in its state. With a database a timer is a row (`rocx_actor_timers`) until the turn that
	## handled it has ended, so a restart doesn't lose it: the server sets it again as it starts.
	## Its call is made at least once: a server killed in the middle of that turn makes it again
	## after its restart. Without a database, timers are in the server's memory, and a restart
	## loses them. A timer's number is random, so one kept in an actor's state from before a
	## restart still names its own timer.
	Timer : U64

	## A method as the platform runs it, its types erased (`handler`): its kind's name, its own, and
	## its turn on JSON: the actor's key, its state ("" when it is new) and the input, to its next
	## state and the reply.
	Handler(context) : { kind : Str, method : Str, run! : context, Str, Str, Str => Try({ state : Str, reply : Str }, Str) }

	## A kind of actor: `name`, unique in the app; `initial`, the state of one that is new, from its
	## key.
	define : Kind(state) -> Kind(state)
	define = |kind| kind

	## A method of `kind` called `name` (unique in the kind: the server won't start with two), whose
	## turn `run!` takes.
	method : Kind(state), Str, (Turn(context, state, input) => { state : state, reply : reply }) -> Method(context, state, input, reply)
	method = |kind, name, run!| { kind, name, run! }

	## The key of the actor whose turn it is.
	key_of : Me(state) -> Str
	key_of = |me| {
		{ key, kind: _ } = me
		key
	}

	## The reply of `method` of the actor called `key` to `input`, once it has taken the turns before
	## it; or `ActorErr` with why there is none: it doesn't take the input, it crashed, it is waiting
	## on the asker's answer (an actor asking itself, or one up its chain of asks: refused at once),
	## or it hasn't answered in 30 s.
	ask! : Method(context, state, input, reply), Str, input => Try(reply, [ActorErr(Str)])
		where [input.Json.Encodable([]), reply.Json.Parseable([InvalidJson(Str)])]
	ask! = |called, key, input|
		match Host.actor_ask!(called.kind.name, key, call_of(called.name, input)) {
			Ok(replied) =>
				match Json.parse(replied) {
					Ok(reply) => Ok(reply)
					Err(InvalidJson(why)) => Err(ActorErr("${called.kind.name} ${key}: its ${called.name}'s reply isn't what was asked for: ${why}"))
				}
			Err(why) => Err(ActorErr(why))
		}

	## Calls `method` of the actor called `key` with `input`, and goes on: it is taken after the turns
	## before it, its reply goes nowhere, and what goes wrong is logged.
	tell! : Method(context, state, input, reply), Str, input => {}
		where [input.Json.Encodable([])]
	tell! = |called, key, input| Host.actor_tell!(called.kind.name, key, call_of(called.name, input))

	## Calls `method` of the actor called `key` with `input` in `ms` milliseconds, as `tell!` would
	## then: the timer, to stop it with (`cancel!`). With a database it outlives a restart (`Timer`).
	## It is set at once, as a tell is sent at once: a transaction the caller has open, rolled back,
	## doesn't stop it.
	tell_after! : Method(context, state, input, reply), Str, U64, input => Timer
		where [input.Json.Encodable([])]
	tell_after! = |called, key, ms, input| ActorTimers.set!(called.kind.name, key, ms, call_of(called.name, input))

	## Calls `method` of the actor whose turn it is, a method of its own kind, with `input` in `ms`
	## milliseconds (a sweep, a reminder, a tick): the timer, to stop it with (`cancel!`). A timer
	## every so often is one that sets the next. With a database it outlives a restart (`Timer`).
	## Another kind's method (which only its state's type could let through) crashes the turn.
	after! : Me(state), U64, Method(context, state, input, reply), input => Timer
		where [input.Json.Encodable([])]
	after! = |me, ms, called, input| {
		{ kind, key } = me
		if called.kind.name != kind {
			crash "Actor.after!: ${called.kind.name}'s ${called.name} isn't a method of ${kind}, whose turn this is"
		}
		ActorTimers.set!(kind, key, ms, call_of(called.name, input))
	}

	## Stops a timer whose call hasn't been taken: one that is waiting, or one that has fired but
	## whose turn hasn't come (its call is dropped). One that has been taken, or never was, is
	## nothing to stop.
	cancel! : Timer => {}
	cancel! = |timer| ActorTimers.cancel!(timer)

	## `method`, as the platform runs it: what `rocx build` lists in `program.actors`.
	handler : Method(context, state, input, reply) -> Handler(context)
		where [state.Json.Encodable([]), state.Json.Parseable([InvalidJson(Str)]), input.Json.Parseable([InvalidJson(Str)]), reply.Json.Encodable([])]
	handler = |called| { kind: called.kind.name, method: called.name, run!: |context, key, kept, sent| turn!(called, context, key, kept, sent) }

	## A call as the host carries it (`actor_for_host!` splits it): the method's name, a newline,
	## and its input as JSON.
	call_of : Str, input -> Str
		where [input.Json.Encodable([])]
	call_of = |name, input| "${name}\n${Json.to_str(input)}"
}

## A turn of `method` of the actor called `key`: its state (`kept`: JSON, "" when it is new) and the
## input (JSON), to its next state and the reply (JSON); or why not, and it stays as it was.
turn! : Actor.Method(context, state, input, reply), context, Str, Str, Str => Try({ state : Str, reply : Str }, Str)
	where [state.Json.Encodable([]), state.Json.Parseable([InvalidJson(Str)]), input.Json.Parseable([InvalidJson(Str)]), reply.Json.Encodable([])]
turn! = |method, context, key, kept, sent| {
	state =
		if kept.is_empty() {
			Ok((method.kind.initial)(key))
		} else {
			match Json.parse(kept) {
				Ok(parsed) => Ok(parsed)
				Err(InvalidJson(why)) => Err("${method.kind.name} ${key}: its state isn't what its kind keeps: ${why}")
			}
		}
	input =
		match Json.parse(sent) {
			Ok(parsed) => Ok(parsed)
			Err(InvalidJson(why)) => Err("${method.kind.name} ${key}: an input its ${method.name} doesn't take: ${why}")
		}
	match (state, input) {
		(Ok(now), Ok(given)) => {
			me : Actor.Me(state)
			me = { kind: method.kind.name, key }
			answered = (method.run!)({ me, context, state: now, input: given })
			Ok({ state: Json.to_str(answered.state), reply: Json.to_str(answered.reply) })
		}
		(Err(why), _) => Err(why)
		(_, Err(why)) => Err(why)
	}
}
