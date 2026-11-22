## An app's side of push, as small as it gets: a page with `<PushButton>` and a button that notifies
## every browser, the three endpoints the button asks, and the layout that loads the page's script.
## The docs show it. Like any app until a package can give it server-only modules (PROPOSALS.md,
## section 2), it needs the glue beside it: copy `../server/Push.roc` and `../server/PushStore.roc`
## here, and `../migrations/0001_push_subscriptions.sql` into `migrations/`. Then `rocx build`
## finds the `push.deliver` job and the table, and the server's program has both.
app [program] { pf: platform "../../../server/platform/main.roc", push: "../main.roc" }

import pf.Middleware
import Generated/App

program = App.program({
	context: |_started| {},
	middleware: Middleware.same_origin({}),
})
