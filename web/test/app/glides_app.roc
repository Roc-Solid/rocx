## Glides across boxes that scroll (`Glides.rocx`), for the tests: rendered as the server would,
## hydrated.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Glides

main! : {} => Html
main! = |{}| Html.component(|| Glides.view!({}))
