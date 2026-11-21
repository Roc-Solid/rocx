app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import Profile

main! : {} => Html
main! = |{}| Profile.view!({})
