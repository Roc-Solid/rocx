## A doctype and raw text in a component (`RawText.rocx`), for the tests.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import RawText

main! : {} => Html
main! = |{}| RawText.view!({})
