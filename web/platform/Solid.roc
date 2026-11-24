import Host
import Context
import Store

## Solid 2.0's primitives, as Roc names them: `createSignal` is `create_signal!`, and so on. A read
## is an accessor (`count!()`), and it is tracked: a computation that reads it runs again when it
## changes. The browser's timers are here too (`set_interval!`, `set_timeout!`), each stopped by
## the `clear!` it answers, or when what started it goes.
##
##     import pf.Solid exposing [create_signal!, create_memo!, create_optimistic!, create_store!, create_effect!, create_render_effect!, create_effect_with!, on_cleanup!, on_settled!, refresh!, is_pending!, latest!, untrack!, use_context!, set_interval!]
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

	## A store (Solid 2.0's `createStore`): state of many parts in one value, read by parts
	## (`store.get!(|s| s.filter)`, tracked by the part it selects), and its setter, which takes a
	## function of the state, Solid's draft setter: `set_todos!(|s| { ..s, filter: Done })`. Writes
	## apply when the handler making them is done, as a signal's do, and two in one handler compose:
	## the second is given what the first made. See `Store`.
	create_store! : s => (Store(s), ((s -> s) => {}))
	create_store! = |value| {
		id = Host.signal_new!(Box.box(|| value))
		read! = || {
			current = Box.unbox(Host.signal_get!(id))
			current()
		}
		write! = |update| {
			latest = Box.unbox(Host.signal_latest!(id))
			next = update(latest())
			Host.signal_set!(id, Box.box(|| next))
		}
		(Store.of(read!), write!)
	}

	## A value computed from others, computed again when they change: its accessor. It is async when
	## it calls the server: until the answer is in, reading it makes the reader wait (it runs again
	## once the answer is in); a failure shows the nearest <Errored>.
	create_memo! : (() => a) => (() => a)
	create_memo! = |compute| {
		run! = || {
			value = compute()
			Host.memo_done!(Box.box(|| value), Bool.False)
			""
		}
		id = Host.memo_new!(Box.box(run!))
		|| {
			value = Box.unbox(Host.memo_get!(id))
			value()
		}
	}

	## A value the page shows ahead of the server (Solid 2.0's `createOptimistic`): its accessor and
	## its setter. It is `compute`'s, a memo (the server's data, say: `|| Endpoint.get!(board)`),
	## until a handler writes it: the write shows once the handler is done, and is held until the
	## submissions that handler sent are done (an action's, `Router.use_action!`; or the form its
	## `submit` sends), the page's reads read again by then, so the server's data takes its place
	## with no frame of the old. A refusal ends it too: the value is the server's again, the refusal
	## the submission's `error`. With nothing sent, the write is undone at once, as Solid 2.0
	## undoes one outside a transition. Several held at once: the latest still held shows.
	##
	##     (cards!, set_cards!) = create_optimistic!(|| Endpoint.get!(board))
	##     move! = use_action!(Api.post_move({}))
	##     on_drop! = |day| {
	##         set_cards!(moved(cards!(), dragged!(), day))
	##         move!({ card: dragged!(), day })
	##     }
	##
	## On the server there are no handlers: it is `compute`'s. Where several submissions may be on
	## their way and each should apply to the server's latest data, derive it instead from what they
	## sent (`Submissions.pending_inputs!`, D-030).
	create_optimistic! : (() => a) => ((() => a), (a => {}))
	create_optimistic! = |compute| {
		source! = Solid.create_memo!(compute)
		held : [Held(a), Unheld]
		held = Unheld
		id = Host.signal_new!(Box.box(|| held))
		read! = || {
			current = Box.unbox(Host.signal_get!(id))
			match current() {
				Held(value) => value
				Unheld => source!()
			}
		}
		write! = |next| {
			written : [Held(a), Unheld]
			written = Held(next)
			Host.optimistic_set!(id, Box.box(|| written))
		}
		(read!, write!)
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

	## Whether what the accessor reads is being computed again while it shows its last value
	## (Solid 2.0's `isPending`): true while a memo it reads (or a memo that one reads, all the way
	## up) has a value and waits for a new one, after a `refresh!` or after what it reads changed.
	## False while there is no value yet, the first load, which `<Loading>` covers; and false for a
	## memo that failed, which `<Errored>` covers. Calling it never waits or fails, and doesn't make
	## the caller depend on the values the accessor reads: a hole, a memo or an effect that calls it
	## runs again when the answer changes. On the server it is false: the server renders final values.
	##
	##     <p class:stale={is_pending!(user!)}>{user!().name}</p>
	##     {if is_pending!(|| (user!(), posts!())) { <p>Refreshing…</p> }}
	is_pending! : (() => a) => Bool
	is_pending! = |read!| {
		probe! = || {
			_ = read!()
			""
		}
		Host.is_pending!(Box.box(probe!))
	}

	## The last value of what the accessor reads (Solid 2.0's `latest`): a memo being computed again
	## (a `refresh!`, or a change of what it reads) gives the value it last settled at, and doesn't
	## make the caller wait. Every read here does that already: a memo shows its last value while it
	## is read again (`is_pending!` says it is), since nothing holds a write back until a change is
	## done, as Solid 2.0's transitions do. So `latest!(read!)` is `read!()`, written as Solid code
	## writes it; it would differ only if writes were held back. A memo with no value yet still makes
	## the caller wait (`<Loading>`'s), and one that failed still fails (`<Errored>`'s).
	##
	##     <input value={latest!(query!)} />
	latest! : (() => a) => a
	latest! = |read!| read!()

	## Runs `read!` without tracking what it reads (Solid's `untrack`): its answer, and what it read
	## doesn't make the hole, memo or effect running it run again. A computation made inside it
	## (`create_memo!`) tracks its own reads. A read that waits still waits.
	##
	##     create_effect!(|| room!(), |room| log!(room, untrack!(|| user!().name)))
	##
	## In a component's body, a read is made once, as the component runs, so what shows doesn't
	## follow it; a dev build (`rocx dev`, `rocx build --dev`) says so in the browser's console, once
	## for each place (Solid 2.0's dev warning). `untrack!` says the one read is meant, a start value:
	##
	##     (drawn!, set_drawn!) = create_signal!(untrack!(|| goal))
	untrack! : (() => a) => a
	untrack! = |read!| {
		Host.untrack!(Bool.True)
		value = read!()
		Host.untrack!(Bool.False)
		value
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

	## A render effect (Solid 2.0's `createRenderEffect`): as `create_effect!`, but its `apply` runs
	## at once, as soon as `compute` has: during the render, before the page is settled, where an
	## effect's waits until the flush is done and the markup is on the page. Made in a component, it
	## runs before the component's markup is built (nothing of it is on the page yet); run again in
	## a flush, its `apply` comes before the effects' and before what the flush moves glides. As
	## Solid's, it is for what must be in step with the render (a value derived into a signal the
	## same flush reads, with no frame between); what reads the page wants `create_effect!`. On the
	## server neither half runs (Solid's server runs both), so what its first `apply` writes is
	## patched in as the page hydrates: keep what a page shows from the server's render.
	##
	##     create_render_effect!(|| query!(), |_| set_page!(1))
	create_render_effect! : (() => a), (a => {}) => {}
	create_render_effect! = |compute, apply| effect_with!(compute, apply, Bool.True, 0)

	## An effect whose `compute` may fail (Solid 2.0's `createEffect(compute, { effect, error })`):
	## as `create_effect!`, with `apply` and `error` in a record. A `compute` that fails (a read that
	## failed, a context nothing provides) calls `error` with why, instead of showing the nearest
	## <Errored>: after the flush, as `apply` runs (a handler: it may write signals; its
	## `on_cleanup!`s run before the next `apply` or `error`), and only if it is still failed then.
	## When `compute` answers again, `apply` runs as before. What fails in `apply` or `error`
	## themselves is theirs, as a handler's is.
	##
	##     create_effect_with!(|| Endpoint.get!(Api.get_room({ room: room!() })), { apply: |room| set_topic!(room.topic), error: |why| set_problem!(why) })
	create_effect_with! : (() => a), { apply : a => {}, error : Str => {} } => {}
	create_effect_with! = |compute, handlers| {
		error = handlers.error
		failed! = || handled!(|| error(Host.event_value!({})))
		effect_with!(compute, handlers.apply, Bool.False, Host.keep!(Box.box(failed!)))
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
	## goes (the part an `if` hides); in a computation (an effect's `compute` too), before it runs
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

## An effect with options (`create_render_effect!`, `create_effect_with!`): its `compute` tells the
## runtime them first, each time it runs.
effect_with! : (() => a), (a => {}), Bool, U64 => {}
effect_with! = |compute, apply, render, error| {
	run! = || {
		Host.effect_options!(render, error)
		value = compute()
		applied! = || {
			apply(value)
			""
		}
		Host.keep!(Box.box(applied!)).to_str()
	}
	Host.effect_new!(Box.box(run!))
}
