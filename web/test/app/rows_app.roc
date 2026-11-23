## A long `<For>`, plain and compared, for the tests (D-053): what one changed item, and every item
## changed, runs.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Rows

main! : {} => Html
main! = |{}| Html.component(|| Rows.view!({}))
