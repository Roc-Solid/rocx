## The scroller alone, for the tests: rendered on the server, hydrated in the browser.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Scroller

main! : {} => Html
main! = |{}| Html.component(|| Scroller.view!({}))
