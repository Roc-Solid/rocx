## An app's side of push, as small as it gets: a page with `<PushButton>` and a button that notifies
## every browser (`routes/push/announce`), and the routes the button asks (routes/push/key/,
## subscribe/, unsubscribe/: the package's handlers, D-116). The push plugin brings the rest (D-051):
## the table, the job that delivers, the service worker at the site's root and the page's script.
## The jobs plugin (packages/jobs) runs its job. It names no database, so the table is in SQLite's
## `data/app.db` (D-105).
app [program] { jobs: "../../jobs/main.roc", pf: platform "../../../server/platform/main.roc", push: "../main.roc" }

import jobs.Job
import push.Push
import Generated/App

program = App.program({
	init!: |_started| Ok({}),
	plugins: [Job.plugin({ jobs: App.jobs }), Push.plugin({})],
})
