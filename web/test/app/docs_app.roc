## The docs' demos, a whole document, a whole app, for the tests (`Docs.rocx`): the server's copy
## renders it, from the answers its endpoint reads got (recorded); the browser's (built from
## `rocx build --client`) hydrates it.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Docs

main! : {} => Html
main! = |{}| Docs.view!({})
