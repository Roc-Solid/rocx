## untrack!, latest! and static holes, for the tests (D-052): rendered as the server would, hydrated in
## the browser; built with --dev too, for the warning of a read in a component's body.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Untracked

main! : {} => Html
main! = |{}| Html.component(|| Untracked.view!({}))
