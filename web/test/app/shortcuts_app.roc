## Key handlers alone (`Shortcuts.rocx`), for the tests: rendered as the server would, hydrated.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Shortcuts

main! : {} => Html
main! = |{}| Html.component(|| Shortcuts.view!({}))
