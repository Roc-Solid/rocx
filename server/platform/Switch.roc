import Html

## `<Switch>`, as Solid 2.0 has it: of the `<Match>`es inside, the first whose `when!` holds shows,
## and the fallback while none does.
##
##     <Switch fallback={<p>Not found</p>}>
##         <Match when!={tab!() == Home}><Home /></Match>
##         <Match when!={user!()}>{|user!| <Profile name={user!().name} />}</Match>
##     </Switch>
##
## A `<Match>`'s conditions are read in order, up to the first that holds, so one further down is
## read only while those above don't hold. What shows is made when it shows, as a `<Show>`'s part is
## (where it is rendered, once, its reads untracked), and made anew when another `<Match>` holds
## first, or, for a keyed one, when its value changes. A non-keyed one with a function child gets an
## accessor of the value (Solid's narrowing), and stays while that value changes.
Switch := [].{
	Props := { fallback : Html ?? Html.empty({}), children : List(Html) }

	## What `<Switch>` is: the first of its `<Match>`es that holds, or the fallback.
	view! : Props => Html
	view! = |props| Html.switch(props.children, props.fallback)
}
