import Host
import Html
import Show

## `<Match>`, a case of a `<Switch>` (Solid 2.0's): what is inside, while `when!` holds, if no
## `<Match>` above it in the `<Switch>` holds. Its forms are `<Show>`'s:
##
##     <Match when!={count!() > 9}><p>Many</p></Match>                     # a Bool
##     <Match when!={user!()}>{|user!| <p>{user!().name}</p>}</Match>       # a Try; an accessor
##     <Match when!={user!()} keyed><Profile /></Match>                     # made anew per value
##     <Match when!={user!()} keyed>{|user| <p>{user.name}</p>}</Match>    # the value itself
##
## rocx refuses a `<Match>` that isn't a `<Switch>`'s child.
Match := [].{
	Props := { when! : () => Bool, children : List(Html) }

	## What `<Match when!={…}>` is: its children while `when!` holds.
	view! : Props => Html
	view! = |props| {
		when! = props.when!
		children = props.children
		Html.matched(|| if (when!()) Ok("") else Err(None), || Html.join(children))
	}

	PropsWith(a, e) := { when! : () => Try(a, e), children : (() => a) => Html }

	## What `<Match when!={…}>` with a function child is: while `when!` is `Ok`, the child, given an
	## accessor of the value inside, which follows it (the part stays while the value changes).
	view_with! : PropsWith(a, e) => Html
	view_with! = |props| {
		when! = props.when!
		children = props.children
		value! = ||
			match when!() {
				Ok(value) => value
				Err(_) => {
					Host.fail!("<Match>'s value is gone")
					crash "unreachable: fail! doesn't return"
				}
			}
		Html.matched(|| Match.holding(when!()), || children(value!))
	}

	PropsKeyed(a, e) := { when! : () => Try(a, e), children : List(Html) }

	## What `<Match when!={…} keyed>` is: its children while `when!` is `Ok`, made anew each time the
	## value inside changes.
	view_keyed! : PropsKeyed(a, e) => Html
	view_keyed! = |props| {
		when! = props.when!
		children = props.children
		Html.matched(|| Show.identity(when!()), || Html.join(children))
	}

	PropsWithKeyed(a, e) := { when! : () => Try(a, e), children : a => Html }

	## What `<Match when!={…} keyed>` with a function child is: while `when!` is `Ok`, the child given
	## the value inside, made anew each time it changes.
	view_with_keyed! : PropsWithKeyed(a, e) => Html
	view_with_keyed! = |props| {
		when! = props.when!
		children = props.children
		made! = ||
			match when!() {
				Ok(value) => children(value)
				Err(_) => Html.empty({})
			}
		Html.matched(|| Show.identity(when!()), made!)
	}

	## A non-keyed case: the same name while it holds, whatever the value.
	holding : Try(a, e) -> Try(Str, [None])
	holding = |value|
		match value {
			Ok(_) => Ok("")
			Err(_) => Err(None)
		}
}
