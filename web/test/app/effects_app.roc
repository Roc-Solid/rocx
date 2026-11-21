## Effects, cleanups and timers (`Effects.rocx`), a whole app, for the tests: the server's app renders
## it (none of them runs there); the browser's (built from `rocx build --client`) hydrates it.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Effects

main! : {} => Html
main! = |{}| Effects.view!({})
