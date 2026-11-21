## A planner (`Planner.rocx`), a whole app, for the tests: the server's copy renders it from the
## board the server read (recorded); the browser's (built from `rocx build --client`) hydrates it,
## and moves its cards by drag and drop, optimistically, against a slow endpoint.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Planner

main! : {} => Html
main! = |{}| Planner.view!({})
