import Host

## What happens now, told to whoever is listening, in the server's memory: messages on topics, and
## rooms that count who is in them. A stream (`Events.stream`) waits for the next message with
## `next!`; a request, a job or an actor publishes one.
##
## ```roc
## Events.stream(|{ send!, .. }| {
##     Live.join!("online")
##     var $open = Bool.True
##     while $open {
##         send!({ online: Live.count!("online") })?
##         $open = Live.next!(15_000) != Gone
##     }
##     Ok({})
## })
## ```
##
## What a call joins or listens to lasts until it ends: a stream's, until its client goes (or it
## crashes).
Live := [].{

	## Sends `message` to every call listening to `topic`.
	publish! : Str, Str => {}
	publish! = |topic, message| Host.live_publish!(topic, message)

	## From now on, this call hears what is published on `topic` (`next!`).
	listen! : Str => {}
	listen! = |topic| Host.live_listen!(topic)

	## This call is in `room` until it ends, and listens to it; whoever listens to `room` hears
	## `join` when one joins, and `leave` when one leaves.
	join! : Str => {}
	join! = |room| Host.live_join!(room)

	## How many are in `room`.
	count! : Str => U64
	count! = |room| Host.live_count!(room)

	## The next message on a topic this call listens to, or `Quiet` if none comes within `ms`
	## milliseconds, or `Gone` if the client of the stream this call is sending has gone.
	next! : U64 => [Heard({ topic : Str, message : Str }), Quiet, Gone]
	next! = |ms| {
		heard = Host.live_next!(ms)
		match heard.status {
			0 => Heard({ topic: heard.topic, message: heard.message })
			1 => Quiet
			_ => Gone
		}
	}
}
