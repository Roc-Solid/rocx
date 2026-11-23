## An app that reports its errors to PostHog (packages/posthog): every 5xx answer (`/boom`), an
## error it dealt with (`/refund`), a job that failed for good (`charge`, through the jobs plugin's
## `on_failed!`), and a page's errors (`/rocx-errors.js`). Who asks is the `x-user` header, for the
## middleware to name. Without POSTHOG_KEY nothing is sent.
app [program] { jobs: "../../jobs/main.roc", pf: platform "../../../server/platform/main.roc", posthog: "../main.roc" }

import pf.Middleware
import pf.Server
import jobs.Job
import posthog.PostHog
import Generated/App

## Who asks, from the `x-user` header ("" for nobody).
who : Middleware({ started : Str }, { started : Str, user : Str })
who = Middleware.make(|request, context, next!| next!(request, { started: context.started, user: Server.header(request, "x-user") ?? "" }))

program = App.program({
	init!: |started| Ok({ started: started }),
	middleware: Middleware.same_origin({}).then(who).then(PostHog.middleware(|context| context.user)),
	plugins: [Job.plugin({ jobs: App.jobs, on_failed!: PostHog.job_failed! }), PostHog.plugin({ interval_ms: 200 })],
})
