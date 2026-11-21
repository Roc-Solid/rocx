import Host
import Html

## `<Show>`, as Solid 2.0 has it: what is inside while `when!` holds, the fallback otherwise. Only a
## change of whether it holds switches between them.
##
##     <Show when!={count!() > 0} fallback={<p>None yet</p>}><p>Some</p></Show>
##
## With a function child, `when!` is a Try, and the child gets an accessor of the value inside it
## (Solid's narrowing, non-keyed): `<Show when!={users!().first()}>{|first!| <p>{first!().name}</p>}</Show>`.
Show := [].{
	Props := { when! : () => Bool, fallback : Html ?? Html.empty({}), children : List(Html) }

	view! : Props => Html
	view! = |props| Html.shown(props.when!, props.children, props.fallback)

	PropsWith(a, e) := { when! : () => Try(a, e), fallback : Html ?? Html.empty({}), children : (() => a) -> Html }

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
