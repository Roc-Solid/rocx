## D-053's stores, for the tests: rendered as the server would, hydrated strictly in the browser.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Stores

main! : {} => Html
main! = |{}| Html.component(|| Stores.view!({}))
