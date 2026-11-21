## Props alone, for the tests: rendered as the server would, hydrated in the browser.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Props

main! : {} => Html
main! = |{}| Html.component(|| Props.view!({}))
