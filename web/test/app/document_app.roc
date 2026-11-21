## A whole document, a whole app, for the tests (`Document.rocx`): the server's copy renders it, from
## the answers its endpoint reads got (recorded); the browser's (built from `rocx build --client`)
## hydrates the document (`hydrateDocument`, from start.js).
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Document

main! : {} => Html
main! = |{}| Document.view!({})
