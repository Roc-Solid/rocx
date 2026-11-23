import Host
import Html

## `<Show>`, as Solid 2.0 has it: what is inside while `when!` holds, the fallback otherwise. Only a
## change of whether it holds switches between them.
##
##     <Show when!={count!() > 0} fallback={<p>None yet</p>}><p>Some</p></Show>
##
## Each is made when it shows, as Solid makes them: as a component is, where it is rendered, once,
## its reads untracked, and made again each time it shows again. So a value prop inside
## (`<Podium players={game!().players} />`), a getter (D-039), is read where the component reads
## it, as the part shows and while it does.
##
## With a function child, `when!` is a Try, and the child gets an accessor of the value inside it
## (Solid's narrowing, non-keyed): `<Show when!={users!().first()}>{|first!| <p>{first!().name}</p>}</Show>`.
## The child runs when the part shows, and may do what a component does there: hold a `<For>` or
## another `<Show>` (effects), or be plain markup.
##
## Keyed (Solid 2.0's `keyed`), the part is made anew each time the value inside changes, not only
## when it turns `Ok`, and a function child gets the value itself: `<Show when!={selected!()} keyed>{|card| <Editor card={card} />}</Show>`
## starts a new `<Editor>`, its signals new, for each card selected. Roc's values have no identity:
## two values are the same one when `Str.inspect` says the same of them (a function inside prints
## as `<function>`, so a change of one alone isn't one).
Show := [].{
	Props := { when! : () => Bool, fallback : Html ?? Html.empty({}), children : List(Html) }

	## What `<Show when!={…}>` is: the children while `when!` holds, the fallback otherwise.
	view! : Props => Html
	view! = |props| Html.shown(props.when!, props.children, props.fallback)

	PropsWith(a, e) := { when! : () => Try(a, e), fallback : Html ?? Html.empty({}), children : (() => a) => Html }

	## What `<Show>` with a function child is: `when!` is a Try, and while it is `Ok`, the child
	## gets an accessor of the value inside; the fallback otherwise. The child is effectful (`=>`),
	## run when the part is made, so it may hold `<For>`s and `<Show>`s; a pure one is fine too.
	view_with! : PropsWith(a, e) => Html
	view_with! = |props| {
		when! = props.when!
		children = props.children
		holds! = ||
			match when!() {
				Ok(_) => Bool.True
				Err(_) => Bool.False
			}
		value! = ||
			match when!() {
				Ok(value) => value
				Err(_) => {
					Host.fail!("<Show>'s value is gone")
					crash "unreachable: fail! doesn't return"
				}
			}
		Html.shown_with(holds!, || children(value!), props.fallback)
	}

	PropsKeyed(a, e) := { when! : () => Try(a, e), fallback : Html ?? Html.empty({}), children : List(Html) }

	## What `<Show when!={…} keyed>` is: the children while `when!` is `Ok`, made anew each time the
	## value inside changes; the fallback otherwise.
	view_keyed! : PropsKeyed(a, e) => Html
	view_keyed! = |props| {
		when! = props.when!
		children = props.children
		Html.switched(|| Show.identity(when!()), || Html.join(children), props.fallback)
	}

	PropsWithKeyed(a, e) := { when! : () => Try(a, e), fallback : Html ?? Html.empty({}), children : a => Html }

	## What `<Show when!={…} keyed>` with a function child is: while `when!` is `Ok`, the child given
	## the value inside, made anew each time that value changes; the fallback otherwise.
	view_with_keyed! : PropsWithKeyed(a, e) => Html
	view_with_keyed! = |props| {
		when! = props.when!
		children = props.children
		made! = ||
			match when!() {
				Ok(value) => children(value)
				Err(_) => Html.empty({})
			}
		Html.switched(|| Show.identity(when!()), made!, props.fallback)
	}

	## A keyed part's case: the value's text while it is `Ok` (another text, another part).
	identity : Try(a, e) -> Try(Str, [None])
	identity = |value|
		match value {
			Ok(inside) => Ok(Str.inspect(inside))
			Err(_) => Err(None)
		}
}
