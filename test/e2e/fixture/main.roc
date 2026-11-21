## The fixture page as an app on the web platform, for the e2e tests: `roc test` runs its module's
## expects; `roc check` reports a mistake in it at its .rocx line.
app [main!] { pf: platform "../../../web/platform/main.roc" }

import pf.Html
import Page

main! : {} => Html
main! = |{}| Page.view({ title: "Posts", posts: [] })
