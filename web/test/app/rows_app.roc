## A long `.map`, its rows compared (D-053, D-071), for the tests: what one changed item, and every item
## changed, runs.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Rows

main! : {} => Html
main! = |{}| Html.component(|| Rows.view!({}))
