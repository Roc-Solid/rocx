## An app that reports its errors to PostHog (packages/posthog): every 5xx answer (`/boom`), an
## error it dealt with (`/refund`), a job that failed for good (`charge`, through the jobs plugin's
## `on_failed!`), and a page's errors (`/rocx-errors.js`). Who asks is the `x-user` header, for the
## middleware (routes/+middleware.roc) to name. Without POSTHOG_KEY nothing is sent.
app [program] { jobs: "../../jobs/main.roc", pf: platform "../../../server/platform/main.roc", posthog: "../main.roc" }

import jobs.Job
import posthog.PostHog
import Generated/App

program = App.program({
	init!: |started| Ok({ started: started }),
	plugins: [Job.plugin({ jobs: App.jobs, on_failed!: PostHog.job_failed! }), PostHog.plugin({ interval_ms: 200 })],
})
