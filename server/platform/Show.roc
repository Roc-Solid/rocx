import Host
import Html

## `<Show>`, as Solid 2.0 has it: what is inside while `when!` holds, the fallback otherwise. Only a
## change of whether it holds switches between them.
##
##     <Show when!={count!() > 0} fallback={<p>None yet</p>}><p>Some</p></Show>
##
## With a function child, `when!` is a Try, and the child gets an accessor of the value inside it
## (Solid's narrowing, non-keyed): `<Show when!={users!().first()}>{|first!| <p>{first!().name}</p>}</Show>`.
## The child runs when the part shows, and may do what a component does there: hold a `<For>` or
## another `<Show>` (effects), or be plain markup.
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
}
