## `<Title>`s (`Titles.rocx`), a whole app, for the tests: the server's app renders it, the title in
## its `<head>`; the browser's (built from `rocx build --client`) hydrates it, and keeps the title.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Titles

main! : {} => Html
main! = |{}| Titles.view!({})
