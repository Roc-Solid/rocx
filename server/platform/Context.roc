import Host
import Html

## Solid 2.0's context: a value given to everything under its provider, however deep, without
## passing it down.
##
##     picks_context : Context(Store)
##     picks_context = create_context()        # or create_context(default)
##
##     <PicksContext value={store!({})}>…</PicksContext>
##     store = use_context!(picks_context)     # import pf.Solid exposing [use_context!]
##
## rocx names a context after its module and definition (`Picks.picks_context`): Roc's values have
## no identity to tell two contexts apart. It writes `create_context(…)`
## as `Context.define` or `Context.required`, and a provider's tag as `Context.provide!`. A context
## with no default fails, when nothing above provides it, and the nearest <Errored> shows why.
Context(a) := { name : Str, default : [Given(a), NotGiven] }.{

	## A context, and what it is where nothing provides it.
	define : Str, a -> Context(a)
	define = |name, default| { name: name, default: Given(default) }

	## A context that must be provided.
	required : Str -> Context(a)
	required = |name| { name: name, default: NotGiven }

	## What is inside, given `value` for the context.
	provide! : Context(a), a, List(Html) => Html
	provide! = |context, value, children| Html.provided(context.name, Host.context_value!(Box.box(|| value)), children)

	## The value the nearest provider above gives; with none, the default.
	use! : Context(a) => a
	use! = |context| {
		found = Host.context_find!(context.name)
		if found != 0 {
			value = Box.unbox(Host.context_get!(found))
			value()
		} else {
			match context.default {
				Given(value) => value
				NotGiven => {
					Host.fail!("nothing above provides ${context.name}: render this under its provider")
					crash "unreachable: fail! doesn't return"
				}
			}
		}
	}
}
