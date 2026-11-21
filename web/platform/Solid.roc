import Host
import Context

## Solid 2.0's primitives, as Roc names them: `createSignal` is `create_signal!`, and so on. A read
## is an accessor (`count!()`), and it is tracked: a computation that reads it runs again when it
## changes. The browser's timers are here too (`set_interval!`, `set_timeout!`), each stopped by
## the `clear!` it answers, or when what started it goes.
##
##     import pf.Solid exposing [create_signal!, create_memo!, create_effect!, on_cleanup!, on_settled!, refresh!, use_context!, set_interval!]
##
##     (count!, set_count!) = create_signal!(0.U64)
##     doubled! = create_memo!(|| count!() * 2)
##     create_effect!(|| room!(), |room| Endpoint.listen!(Api.events_room({ room }), Call.listen!, heard!))
Solid := [].{

	## A value that changes: its accessor and its setter (a tuple: Roc's list patterns may not
	## match). Writes apply when the handler making them is done, as in Solid 2.0.
	create_signal! : a => ((() => a), (a => {}))
	create_signal! = |value| {
		id = Host.signal_new!(Box.box(|| value))
		read! = || {
			current = Box.unbox(Host.signal_get!(id))
			current()
		}
		write! = |next| Host.signal_set!(id, Box.box(|| next))
		(read!, write!)
	}

	## A value computed from others, computed again when they change: its accessor. It is async when
	## it calls the server: until the answer is in, reading it makes the reader wait (it runs again
	## once the answer is in); a failure shows the nearest <Errored>.
	create_memo! : (() => a) => (() => a)
	create_memo! = |compute| {
		run! = || {
			value = compute()
			Host.memo_done!(Box.box(|| value))
			""
		}
		id = Host.memo_new!(Box.box(run!))
		|| {
			value = Box.unbox(Host.memo_get!(id))
			value()
		}
	}

	## Computes again, asking the server again, every memo the accessor reads: `refresh!(user!)`.
	## Functions can't be compared, so the runtime finds them by running it once, noting what it reads.
	refresh! : (() => a) => {}
	refresh! = |read!| {
		probe! = || {
			_ = read!()
			""
		}
		Host.refresh!(Box.box(probe!))
	}

	## The value of a context (`useContext`): what the nearest provider above gives, or its default.
	## In a component, or a computation; a handler is above nothing.
	use_context! : Context(a) => a
	use_context! = |context| Context.use!(context)

	## An effect, Solid 2.0's split one (`createEffect(compute, apply)`): `compute` runs now, its
	## reads tracked; `apply` runs once the markup is on the page (after the flush), untracked, given
	## what `compute` answered, as a handler does (it may write signals, applied when it is done).
	## When what `compute` read changes, it runs again, then the last `apply`'s cleanups
	## (`on_cleanup!`), then `apply`; values aren't compared. It belongs to the component or
	## computation that made it, and goes with it, its cleanups run. On the server neither half runs.
	##
	##     create_effect!(|| room!(), |room| Endpoint.listen!(Api.events_room({ room }), Call.listen!, heard!))
	##
	## Solid's `apply` returns its cleanup: here it calls `on_cleanup!`, since Roc has no "nothing" a
	## function may return. Neither half is given the previous value. A listen or a timer started in
	## `apply` stops before the next `apply`, and when the effect goes.
	create_effect! : (() => a), (a => {}) => {}
	create_effect! = |compute, apply| {
		run! = || {
			value = compute()
			applied! = || {
				apply(value)
				""
			}
			Host.keep!(Box.box(applied!)).to_str()
		}
		Host.effect_new!(Box.box(run!))
	}

	## Runs `cleanup` when what is running now is done with (Solid's `onCleanup`): a component, when
	## it goes; a computation (a hole, a memo, an effect's `compute`), before it runs again and when
	## it goes; an effect's `apply`, before the next and when the effect goes. What it owns goes
	## first, then its cleanups, the last first. As a handler: it may write signals. In an event
	## handler it fails: nothing would ever run it. On the server it never runs.
	on_cleanup! : (() => {}) => {}
	on_cleanup! = |cleanup| {
		run! = || {
			cleanup()
			""
		}
		Host.cleanup!(Box.box(run!))
	}

	## Runs `settled` once, in the browser, once the markup of what is running now (a component, say)
	## is on the page: Solid 2.0's `onSettled` (`onMount`, before it). It is an effect whose `compute`
	## reads nothing, so it never runs again. It runs as a handler (it may write signals, call the
	## browser, start a timer), and an `on_cleanup!` in it runs when the component goes. The server
	## never runs it, so it is where what only makes sense in a browser goes: reading what the page
	## kept, focusing a field, measuring.
	##
	##     on_settled!(|| set_awake!(Bool.True))
	on_settled! : (() => {}) => {}
	on_settled! = |settled| Solid.create_effect!(|| {}, |_| settled())

	## Runs `tick!` every `ms` milliseconds, as a handler runs (its writes applied together when it
	## is done): its `clear!`, which stops it. Solid leaves timers to the browser, with
	## `onCleanup(() => clearInterval(id))` to stop one; here that is built in: an interval stops
	## with the cleanups of what started it. Started in a component, it stops when the component
	## goes (the part a <Show> hides); in a computation (an effect's `compute` too), before it runs
	## again; in an effect's `apply`, before the next `apply`; in an event handler, when the element
	## whose handler started it goes. Only the browser runs one: while the server renders, it never
	## ticks.
	##
	##     (seconds!, set_seconds!) = create_signal!(0)
	##     stop! = set_interval!(1000, || set_seconds!(seconds!() + 1))
	##
	## An interval while a signal says so, stopped by the effect's cleanup when it says otherwise:
	##
	##     create_effect!(
	##         || running!(),
	##         |running|
	##             if running {
	##                 _ = set_interval!(1000, tick!)
	##                 {}
	##             } else {
	##                 {}
	##             },
	##     )
	set_interval! : U64, (() => {}) => (() => {})
	set_interval! = |ms, tick!| {
		id = Host.interval!(ms, Box.box(|| handled!(tick!)))
		|| Host.clear_timer!(id)
	}

	## Runs `done!` once, `ms` milliseconds from now, as a handler runs: its `clear!`, which calls
	## it off if it hasn't run yet. Like an interval, it is called off with the cleanups of what
	## started it, and only the browser runs one.
	##
	##     cancel! = set_timeout!(400, || set_query!(draft!()))
	set_timeout! : U64, (() => {}) => (() => {})
	set_timeout! = |ms, done!| {
		id = Host.timeout!(ms, Box.box(|| handled!(done!)))
		|| Host.clear_timer!(id)
	}
}

handled! : (() => {}) => Str
handled! = |handler| {
	handler()
	""
}
