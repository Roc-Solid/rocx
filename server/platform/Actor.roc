import ActorTimers
import Host

## State that outlives a request, changed one turn at a time: an actor is a kind and a key (the
## cart of member 7, the counter called `visits`). Nobody makes one or ends one: a call to any key
## finds it as its last turn left it, or new (`initial(key)`), and it takes its turns one at a time,
## in the order they came. With a database, its state is kept in it (`rocx_actors`), and so are its
## timers (`rocx_actor_timers`), so both are there after a restart.
##
## A kind is a type of the app's (D-068): one with `name` and `initial` (`Actor.Kind`). What its
## actors do is its methods, each its own input and its own reply, typed (D-066); its key is any
## type with `to_str` and `from_quote` (`Actor.Keyed`): text, or one of the app's (D-067).
##
## ```roc
## Carts := [].{
##     State : { items : List(Str) }
##
##     ## The kind: its name (its actors' state is kept under it) and a new cart.
##     name = |{}| "cart"
##     initial = |_member| { items: [] }
##
##     ## Its methods' type, once: the kind, the app's context (its `init!`'s), the key, the state.
##     Method(input, reply) : Actor.Method(Carts, {}, Str, Carts.State, input, reply)
##
##     add : Carts.Method(Str, U64)
##     add = Actor.method("add", |{ state, input, .. }| { state: { items: state.items.append(input) }, reply: state.items.len() + 1 })
##
##     clear : Carts.Method({}, {})
##     clear = Actor.method("clear", |{ .. }| { state: { items: [] }, reply: {} })
## }
##
## count = Carts.add.ask!(member, "a book")?   # a U64
## Carts.clear.tell!(member, {})
## ```
##
## A key of the app's own type names its actor by its `to_str` (in the database too) and is read
## back by its `from_quote`, which also lets a string literal be a key, checked when the app is
## built:
##
## ```roc
## Key := [YouTube, Instagram(Str)].{
##     to_str = |key| match key { YouTube => "youtube"  Instagram(id) => "instagram:${id}" }
##     from_quote = |written| …   # Try(Key, [BadQuotedBytes(Str)])
## }
## ```
##
## `rocx build` lists the methods an app's modules define (`program.actors`, each `Actor.handler`), so
## the server can run an actor when nobody waits on it: a tell, a timer. Each actor has a mailbox in
## the host, and its turns, whichever method each is, run one after another, each in a call of its
## own. Inputs, replies and state go to the host as JSON: an input a method doesn't take, or a crash
## in it, is logged as an error and told to its asker, and the actor goes on, its state as it was.
Actor := [].{

	## What a kind of actor is: a type of the app's with `name`, unique in the app (its actors' state
	## is kept under it), and `initial`, the state of one that is new, from its key.
	kind.Kind(key, state) : where [kind.name : {} -> Str, kind.initial : key -> state]

	## What a key is: a type with `to_str`, which names its actor (in the host, the log and the
	## database: what it makes of a key is the key, for as long as the actor's state is kept), and
	## `from_quote`, which reads that back, and lets a string literal be a key (checked as the app is
	## built). `Str` has both.
	key.Keyed : where [key.to_str : key -> Str, key.from_quote : Str -> Try(key, [BadQuotedBytes(Str)])]

	## The actor whose turn it is (a method's `me`), of the kind `kind`: its key (`me.key()`), and
	## the calls it makes to itself later (`me.after!`), to methods of its own kind. `named` is its
	## key's text.
	Me(kind, key, state) := { key : key, named : Str }.{

		## The key of the actor whose turn it is, as it is typed.
		key : Actor.Me(kind, key, state) -> key
		key = |Actor.Me.({ key: found, .. })| found

		## Calls `called`, a method of its own kind (another kind's doesn't compile), with `input` in
		## `ms` milliseconds (a sweep, a reminder, a tick): the timer, to stop it with
		## (`Actor.cancel!`). A timer every so often is one that sets the next. With a database it
		## outlives a restart (`Timer`).
		after! : Actor.Me(kind, key, state), U64, Actor.Method(kind, context, key, state, input, reply), input => Actor.Timer
			where [kind.Kind(key, state), input.Json.Encodable([])]
		after! = |Actor.Me.({ named, .. }), ms, called, input| {
			Kind : kind
			ActorTimers.set!(Kind.name({}), named, ms, Actor.call_of(called.name_of(), input))
		}
	}

	## What a method is given on a turn: the actor (`me`), the app's context (what its `init!` made),
	## the actor's state, and the method's input.
	Turn(kind, context, key, state, input) : { me : Actor.Me(kind, key, state), context : context, state : state, input : input }

	## A method of the kind `kind`: its name, unique in its kind, and what a turn of it does: the
	## actor's next state, and the reply (`ask!`'s; a tell's goes nowhere). A kind names its methods'
	## type once (`Method(input, reply) : Actor.Method(Carts, {}, Str, Carts.State, input, reply)`,
	## the app's context second); a package, which doesn't know the app's context, keeps it a
	## parameter of its own (`Otel.Method(_, …)`). Its annotation says whose method it is.
	Method(kind, context, key, state, input, reply) := { name : Str, run! : Actor.Turn(kind, context, key, state, input) => { state : state, reply : reply } }.{

		## Its name.
		name_of : Actor.Method(kind, context, key, state, input, reply) -> Str
		name_of = |Actor.Method.({ name, .. })| name

		## Its reply, from the actor called `key`, to `input`, once it has taken the turns before it;
		## or `ActorErr` with why there is none: it doesn't take the input, it crashed, it is waiting
		## on the asker's answer (an actor asking itself, or one up its chain of asks: refused at
		## once), or it hasn't answered in 30 s.
		ask! : Actor.Method(kind, context, key, state, input, reply), key, input => Try(reply, [ActorErr(Str)])
			where [kind.Kind(key, state), key.Keyed, input.Json.Encodable([]), reply.Json.Parseable([InvalidJson(Str)])]
		ask! = |Actor.Method.({ name, .. }), key, input| {
			Kind : kind
			match Host.actor_ask!(Kind.name({}), key.to_str(), Actor.call_of(name, input)) {
				Ok(replied) =>
					match Json.parse(replied) {
						Ok(reply) => Ok(reply)
						Err(InvalidJson(why)) => Err(ActorErr("${Kind.name({})} ${key.to_str()}: its ${name}'s reply isn't what was asked for: ${why}"))
					}
				Err(why) => Err(ActorErr(why))
			}
		}

		## Calls it on the actor called `key` with `input`, and goes on: its turn comes after the ones
		## before it, its reply goes nowhere, and what goes wrong is logged.
		tell! : Actor.Method(kind, context, key, state, input, reply), key, input => {}
			where [kind.Kind(key, state), key.Keyed, input.Json.Encodable([])]
		tell! = |Actor.Method.({ name, .. }), key, input| {
			Kind : kind
			Host.actor_tell!(Kind.name({}), key.to_str(), Actor.call_of(name, input))
		}

		## Calls it on the actor called `key` with `input` in `ms` milliseconds, as `tell!` would then:
		## the timer, to stop it with (`Actor.cancel!`). With a database it outlives a restart
		## (`Timer`). It is set at once, as a tell is sent at once: a transaction the caller has open,
		## rolled back, doesn't stop it.
		tell_after! : Actor.Method(kind, context, key, state, input, reply), key, U64, input => Actor.Timer
			where [kind.Kind(key, state), key.Keyed, input.Json.Encodable([])]
		tell_after! = |Actor.Method.({ name, .. }), key, ms, input| {
			Kind : kind
			ActorTimers.set!(Kind.name({}), key.to_str(), ms, Actor.call_of(name, input))
		}
	}

	## A timer's number (`me.after!`, `tell_after!`), to stop it with (`cancel!`); an actor may keep it
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

	## A method called `name` (unique in its kind: the server won't start with two), whose turn
	## `run!` takes. Its annotation says whose it is (`Carts.Method(Str, U64)`).
	method : Str, (Actor.Turn(kind, context, key, state, input) => { state : state, reply : reply }) -> Actor.Method(kind, context, key, state, input, reply)
	method = |name, run!| Actor.Method.({ name, run! })

	## Stops a timer whose call hasn't been taken: one that is waiting, or one that has fired but
	## whose turn hasn't come (its call is dropped). One that has been taken, or never was, is
	## nothing to stop.
	cancel! : Timer => {}
	cancel! = |timer| ActorTimers.cancel!(timer)

	## `called`, as the platform runs it: what `rocx build` lists in `program.actors`.
	handler : Actor.Method(kind, context, key, state, input, reply) -> Handler(context)
		where [kind.Kind(key, state), key.Keyed, state.Json.Encodable([]), state.Json.Parseable([InvalidJson(Str)]), input.Json.Parseable([InvalidJson(Str)]), reply.Json.Encodable([])]
	handler = |called| {
		Kind : kind
		{ kind: Kind.name({}), method: called.name_of(), run!: |context, named, kept, sent| turn!(called, context, named, kept, sent) }
	}

	## A call as the host carries it (`actor_for_host!` splits it): the method's name, a newline,
	## and its input as JSON.
	call_of : Str, input -> Str
		where [input.Json.Encodable([])]
	call_of = |name, input| "${name}\n${Json.to_str(input)}"
}

## A turn of `called` of the actor called `named` (its key's text, read back by its type's
## `from_quote`): its state (`kept`: JSON, "" when it is new) and the input (JSON), to its next
## state and the reply (JSON); or why not, and it stays as it was.
turn! : Actor.Method(kind, context, key, state, input, reply), context, Str, Str, Str => Try({ state : Str, reply : Str }, Str)
	where [kind.Kind(key, state), key.Keyed, state.Json.Encodable([]), state.Json.Parseable([InvalidJson(Str)]), input.Json.Parseable([InvalidJson(Str)]), reply.Json.Encodable([])]
turn! = |Actor.Method.({ name, run! }), context, named, kept, sent| {
	Kind : kind
	Key : key
	kind_name = Kind.name({})
	key =
		match Key.from_quote(named) {
			Ok(read) => read
			Err(BadQuotedBytes(why)) => return Err("${kind_name} ${named}: not one of its keys: ${why}")
		}
	state =
		if kept.is_empty() {
			Ok(Kind.initial(key))
		} else {
			match Json.parse(kept) {
				Ok(parsed) => Ok(parsed)
				Err(InvalidJson(why)) => Err("${kind_name} ${named}: its state isn't what its kind keeps: ${why}")
			}
		}
	input =
		match Json.parse(sent) {
			Ok(parsed) => Ok(parsed)
			Err(InvalidJson(why)) => Err("${kind_name} ${named}: an input its ${name} doesn't take: ${why}")
		}
	match (state, input) {
		(Ok(now), Ok(given)) => {
			me : Actor.Me(kind, key, state)
			me = Actor.Me.({ key, named })
			answered = run!({ me, context, state: now, input: given })
			Ok({ state: Json.to_str(answered.state), reply: Json.to_str(answered.reply) })
		}
		(Err(why), _) => Err(why)
		(_, Err(why)) => Err(why)
	}
}
