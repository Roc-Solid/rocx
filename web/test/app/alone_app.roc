## The tally alone, with nothing to provide its store (`Alone.rocx`), for the tests.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Alone

main! : {} => Html
main! = |{}| Alone.view!({})
