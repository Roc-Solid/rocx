app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Generated/Root

## The navigation app's server half, for the tests: its pages rendered as the server renders them
## (`renderToString`, from the answers the tests give), with what is inside each `<NoHydration>`.
main! : {} => Html
main! = |{}| Root.view!({})
