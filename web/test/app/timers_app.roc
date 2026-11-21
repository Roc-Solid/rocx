## The timers alone, for the tests: rendered as the server would (no timer runs), hydrated in the
## browser (they start).
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Timers

main! : {} => Html
main! = |{}| Html.component(|| Timers.view!({}))
