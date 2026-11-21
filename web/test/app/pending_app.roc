## A slow read and is_pending!, a whole app, for the tests: mounted in the browser, and rendered as
## the server would (from the GET it answered) then hydrated.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Pending

main! : {} => Html
main! = |{}| Pending.view!({})
