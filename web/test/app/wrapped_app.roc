## The document inside an `<Errored>` (`Wrapped.rocx`), a whole app, for the tests: the server's copy
## renders it, from recorded answers; the browser's (built from `rocx build --client`) hydrates it.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Wrapped

main! : {} => Html
main! = |{}| Wrapped.view!({})
