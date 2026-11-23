## D-053's `<Show keyed>` and `<Switch>`/`<Match>`, for the tests: rendered as the server would,
## hydrated strictly in the browser, each case from the page's query.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Control

main! : {} => Html
main! = |{}| Html.component(|| Control.view!({}))
