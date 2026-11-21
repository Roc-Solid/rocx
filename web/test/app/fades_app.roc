## The transitions alone, for the tests: rendered as the server would (nothing plays), hydrated in
## the browser (rows and parts that come and go play theirs).
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Fades

main! : {} => Html
main! = |{}| Html.component(|| Fades.view!({}))
