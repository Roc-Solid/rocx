## Control flow inside control flow (`Nested.rocx`), for the tests.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Nested

main! : {} => Html
main! = |{}| Nested.view!({})
