## A form posting to an endpoint (`Form.rocx`), a whole app, for the tests: the server's app renders it
## (its submission the flash in the request's cookie, if any); the browser's (built from `rocx build
## --client`) hydrates it, and sends the form with fetch.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Form

main! : {} => Html
main! = |{}| Form.view!({})
