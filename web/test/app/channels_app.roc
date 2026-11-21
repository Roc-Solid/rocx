## Channels (`Channels.rocx`), a whole app, for the tests: the server's app renders it (no
## subscription runs there); the browser's (built from `rocx build --client`) hydrates it, and its
## feeds subscribe, on the tab's one stream.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Channels

main! : {} => Html
main! = |{}| Channels.view!({})
