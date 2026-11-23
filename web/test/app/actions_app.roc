## D-054's actions and head elements (`Actions.rocx`), a whole app, for the tests: the server's app
## renders it, the head elements before `</head>`; the browser's (built from `rocx build --client`)
## hydrates it, and sends what it sends.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Actions

main! : {} => Html
main! = |{}| Actions.view!({})
