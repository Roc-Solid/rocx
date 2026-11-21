## Events a server sends a page as they happen, over one response (server-sent events): what an
## endpoint's `events!` answers, and a component listens to (`Endpoint.listen!`).
##
## A stream is a loop: it sends an event (`send!`), sleeps (`sleep!`), and goes round again.
##
## ```roc
## Events.stream(|{ send!, sleep! }| {
##     var $count = 1
##     while $count <= 3 {
##         send!($count)?
##         sleep!(300)
##         $count = $count + 1
##     }
##     Ok({})
## })
## ```
##
## Nothing in it runs until the server sends it, as a call of its own that pauses while it sleeps,
## so a sleep holds up no other request. `send!` says when the page has gone
## (`Err(Gone)`): with `?`, the loop ends there, and nothing more runs.
Events(a) :: [Ended, Open({ send! : a => Try({}, [Gone]), sleep! : U64 => {} } => Try({}, [Gone]))].{

	## No events: the stream of an answer that isn't one.
	none : {} -> Events(a)
	none = |{}| Ended

	## A stream that `loop!` sends: each event with `send!`, a pause with `sleep!` (milliseconds).
	## It ends when `loop!` returns, or when `send!` says the page has gone.
	stream : ({ send! : a => Try({}, [Gone]), sleep! : U64 => {} } => Try({}, [Gone])) -> Events(a)
	stream = |loop!| Open(loop!)

	## Each of `items`, `wait` milliseconds apart.
	from_list : List(a), U64 -> Events(a)
	from_list = |items, wait|
		if items.is_empty() {
			Ended
		} else {
			Open(
				|{ send!, sleep! }| {
					var $sent = 0
					for item in items {
						send!(item)?
						$sent = $sent + 1
						if ($sent < items.len()) sleep!(wait) else {}
					}
					Ok({})
				},
			)
		}

	## Each event as `f` makes it.
	map : Events(a), (a -> b) -> Events(b)
	map = |events, f|
		match events {
			Ended => Ended
			Open(loop!) => Open(|{ send!, sleep! }| loop!({ send!: |item| send!(f(item)), sleep! }))
		}

	## Whether the stream has ended: nothing will be sent.
	is_ended : Events(a) -> Bool
	is_ended = |events|
		match events {
			Ended => Bool.True
			Open(_) => Bool.False
		}

	## Sends the stream with `send!` and `sleep!`, to its end or until the page goes: what the feed
	## `Server.for_host` gives a platform runs, on the thread the platform gives the stream.
	run! : Events(a), { send! : a => Try({}, [Gone]), sleep! : U64 => {} } => Try({}, [Gone])
	run! = |events, io|
		match events {
			Ended => Ok({})
			Open(loop!) => loop!(io)
		}
}

expect Events.is_ended(Events.none({}))
expect !Events.is_ended(Events.from_list([1, 2], 10))
expect Events.is_ended(Events.from_list([], 10))
expect !Events.is_ended(Events.map(Events.from_list(["a"], 10), |text| text.concat("!")))
expect !Events.is_ended(Events.stream(|_| Ok({})))
