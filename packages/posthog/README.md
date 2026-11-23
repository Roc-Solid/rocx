# packages/posthog

A Roc Solid app's errors, sent to [PostHog's error tracking](https://posthog.com/docs/error-tracking).
Everything happens in the app: a middleware, a plugin's routes and a background loop. It needs nothing
from the platform beyond what any plugin has.

It reports four kinds of error:

| What | How | Type | Handled |
| --- | --- | --- | --- |
| An answer with a 5xx status | `PostHog.middleware(user)` | `ServerError` | no |
| An error the app dealt with but wants seen | `PostHog.capture!(message, fields)` | `Error` | yes |
| A job that failed for good | the jobs plugin's `on_failed!: PostHog.job_failed!` | `JobFailed` | no |
| An error nothing caught in a browser, or a rejected promise | the page's script, `/rocx-errors.js` | the error's own (`TypeError`) | no |

Each error is kept in the server's memory (`Kv`). A loop sends what has been kept every 10 seconds,
and once more as the server stops. Each one goes as an `$exception` event to PostHog's batch endpoint.
Without a project key nothing is kept or sent, so development costs nothing.

**Not reported:**
- **A crash in Roc.** It ends its call before the middleware sees an answer: the host answers 500 and
  logs `rocx server: Roc crashed`. Crashes show up in the server's log (`docker logs`), not here.
- **Some browser failures.** A computation that fails with no `<Errored>` around it, and a handler that
  fails, are only written to the browser's console by the runtime, so the script never sees them.

## Setting up

```roc
app [program] { jobs: "…/packages/jobs/main.roc", posthog: "…/packages/posthog/main.roc", pf: platform "…" }

import jobs.Job
import posthog.PostHog
import Generated/App

program = App.program({
	init!: |started| Ok({ facts: started }),
	# After the middleware that knows who is signed in, so an error says who it reached.
	middleware: Middlewares.member.then(PostHog.middleware(|context| context.member.id)),
	plugins: [
		Job.plugin({ jobs: App.jobs, on_failed!: PostHog.job_failed! }),
		PostHog.plugin({}),
	],
})
```

And in the layout, so pages send their errors too:

```html
<script src="/rocx-errors.js" defer></script>
```

`PostHog.middleware` takes a function from the context it is given to who asked (`""` for nobody
known). Put it first, with `|_| ""`, if no middleware knows who asked. Errors from nobody known each
get their own id as their distinct id, with `$process_person_profile: false`, so they create no person
in PostHog.

An error the app handles, with fields (a record, as `Log.error!` takes them):

```roc
PostHog.capture!("the payment provider refused a refund", { order: order.id, why: why })
PostHog.capture_for!(member.id, "the payment provider refused a refund", { order: order.id })
```

## Where errors go

| Option | Environment | Default |
| --- | --- | --- |
| `key` | `POSTHOG_KEY` | none: off |
| `host` | `POSTHOG_HOST` | `https://us.i.posthog.com` (`https://eu.i.posthog.com` for EU Cloud) |
| `release` | `POSTHOG_RELEASE` | none (set it to the commit a build is from) |
| `at` | | `/rocx-errors` (its script at `/rocx-errors.js`) |
| `interval_ms` | | `10000` |

An option given in `PostHog.plugin({ … })` wins over the environment. Once started, the server logs
where errors go, or `off: no POSTHOG_KEY` (`posthog.reporting`).

## The events

Each error is one `$exception` event:

- `$exception_list`: one exception, with its `type`, its message as `value`, and `mechanism.handled`.
  When it happened somewhere with a name (a route's pattern, a job's kind, a page's path), the
  exception also gets one frame (`platform: custom`, `lang: roc` or `javascript`) naming that place.
- `$exception_fingerprint`: which issue it belongs to (below).
- `source` (`server`, `browser`, `job`), `place`, `method`, `status`, `release`, and `fields` (the
  app's, or a job's id and attempts). A browser's error also has its `stack`.
- `uuid`: the event's id, so an event sent twice is counted once.

**Fingerprints.** Roc has no stack traces, so PostHog's own grouping has little to go on, and the
package sets the fingerprint itself:
- a 5xx answer: its route's pattern and its message;
- `capture!`: its message only, so it is one issue wherever it happens;
- a job: its kind and its error;
- a browser's error: its type and message.

Each part is normalized: a word with a digit in it becomes `<n>` or `<id>`, and text in double quotes
or backticks becomes `<s>`. So `user 1234 not found` and `user 77 not found` are one issue.

**Limits:**
- the newest 1,000 errors are kept while PostHog can't be reached;
- one issue is sent at most 20 times a minute;
- all browsers together send at most 120 errors a minute, and each page at most 10;
- a page's report may be at most 16 KiB.

A 5xx answer from PostHog, or no answer at all, puts the batch back to be sent next time. A 4xx (a
wrong key) drops it, and says so on the log.

## Tests

- `roc test packages/posthog/main.roc`: the fingerprints and the events' JSON.
- `test/posthog.test.mjs` builds `example/`, starts it against a fake PostHog, and checks every kind
  of error arrives, in Chromium too. The checks also cover the per-issue cap, a resend after a 503,
  and a server with no key, which sends nothing. The job's test needs `DATABASE_URL`.

## A daily digest that fixes what it can

The point of sending errors somewhere is a loop that reads them. PostHog's MCP server
(`https://mcp.posthog.com/mcp`, with a personal API key) lists the issues:
`query-error-tracking-issues-list` gives occurrences and people reached, and
`query-error-tracking-issue` gives one issue's details. A scheduled Claude agent, once a day, can:

1. List the issues that are new or came back in the last 24 hours, ordered by people reached, and
   write the digest: each issue's type, message, place, count, first and last seen, and release.
2. For each of the top issues with a `place`, check out its `release` and see whether master still
   has the bug.
3. Write a failing test from the route, method and fields (an `expect`, or an HTTP test like
   `test/posthog.test.mjs`), fix the bug on a branch, and open a pull request. It never merges.
4. Link the pull request on the issue in PostHog.

Set `POSTHOG_RELEASE` to the commit each build is from (a Docker build argument), so step 2 can find it.
