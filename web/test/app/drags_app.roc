## Drags by touch, a pen and a mouse (`Drags.rocx`, D-055), for the tests: rendered as the server
## would, hydrated.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Drags

main! : {} => Html
main! = |{}| Html.component(|| Drags.view!({}))
