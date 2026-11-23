## Render effects and an effect's error handler, for the tests (D-052): mounted in the browser.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import RenderEffects

main! : {} => Html
main! = |{}| Html.component(|| RenderEffects.view!({}))
