## An error page in the shape rocx writes one: its props are getters, and it hands a page
## component a getter of its own. `status!` is any number: the page compares it with `404` and
## calls `to_str` on it. Each `view` below should be generic in that number. The callers are in
## other modules (Bad.roc, Pure.roc, Hoisted.roc): a caller in this one fixes the number's type
## before it is defaulted, and passes.
ErrorPage := [].{

	## A page component whose prop is an effectful getter, `() => Str`, as rocx types a `view!`
	## component's props.
	page! : { kicker : () => Str } => Str
	page! = |{ kicker: kicker! }| kicker!()

	## The same component, its prop a pure function, `() -> Str`.
	pure_page : { kicker : () -> Str } -> Str
	pure_page = |{ kicker }| kicker()

	## The bug: the closure reads the number and calls `to_str` on it inside a getter checked
	## against `() => Str`. The number is defaulted to `Dec`: this is
	## `{ status : () -> Dec } => Str`, and a caller with a `U16` fails (Bad.roc).
	view! = |{ status: status! }| {
		_missing = status!() == 404
		page!({ kicker: || "Error ${status!().to_str()}" })
	}

	## The same body, given to the pure component: generic, so a `U16` passes (Pure.roc).
	pure_view = |{ status }| {
		_missing = status() == 404
		pure_page({ kicker: || "Error ${status().to_str()}" })
	}

	## The workaround: `to_str` is called in the body, and the closure holds a `Str`. Generic, so
	## a `U16` passes (Hoisted.roc).
	hoisted_view! = |{ status: status! }| {
		_missing = status!() == 404
		code = status!().to_str()
		page!({ kicker: || "Error ${code}" })
	}
}
