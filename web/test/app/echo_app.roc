## The echo alone, a whole app, for the tests: the server's copy renders it, from the answer its
## endpoint read got (recorded); the browser's (built from `rocx build --client`) hydrates it.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Echo

main! : {} => Html
main! = |{}| Echo.view!({})
