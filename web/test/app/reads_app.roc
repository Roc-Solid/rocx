## A page's data from a GET endpoint, a whole app, for the tests: the server's copy renders it from
## the GET the server answered (recorded); the browser's (built from `rocx build --client`) hydrates
## it, and reads the endpoint again when told.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Reads

main! : {} => Html
main! = |{}| Reads.view!({})
