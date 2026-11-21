## The picks alone, for the tests: rendered on the server, hydrated in the browser, given a store
## of their own (what `<PicksContext value={…}><Picks /></PicksContext>` writes).
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import pf.Context
import Picks

main! : {} => Html
main! = |{}| Context.provide!(Picks.picks_context, Picks.store!({}), [Html.component(|| Picks.view!({}))])
