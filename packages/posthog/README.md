# posthog

Send a Roc Solid app's errors to [PostHog's error tracking](https://posthog.com/docs/error-tracking).
Everything runs in the app: a middleware, a plugin's routes and a background loop. It needs nothing
from the platform beyond what any plugin has. The user guide is the docs site's
[PostHog page](https://roc-solid.github.io/ecosystem/posthog); this file is the reference.

It reports four kinds of error:

| What | How | Type | Handled |
| --- | --- | --- | --- |
| An answer with a 5xx status | `PostHog.middleware(user)` | `ServerError` | no |
| An error the app dealt with but wants seen | `PostHog.capture!(message, fields)` | `Error` | yes |
| A job that failed for good | the jobs plugin's `on_failed!: PostHog.job_failed!` | `JobFailed` | no |
| An error nothing caught in a browser, or a rejected promise | the page's script, `/rocx-errors.js` | the error's own (`TypeError`) | no |

Each error is kept in the server's memory (`Kv`). A loop sends what has been kept every 10 seconds,
and once more as the server stops, each error as an `$exception` event to PostHog's batch endpoint.
A request never waits on PostHog. Without a project key nothing is kept or sent, so development
costs nothing.

**Not reported:**

- **A crash in Roc while answering a request.** It ends the call before the middleware sees an
  answer: the host answers 500 and logs `rocx server: Roc crashed`. Crashes show up in the server's
  log, not here. (A job that crashes is reported: the jobs plugin counts a crash as a failure.)
- **Some browser failures.** A computation that fails with no `<Errored>` around it, and a handler
  that fails, are only written to the browser's console by the runtime, so the script never sees
  them.

## Installing it

The package names the server platform, so only the server's half of an app sees it. Name it in the
app's header, add the plugin, give the jobs plugin `PostHog.job_failed!`, and put the middleware in
`routes/+middleware.roc`, the one around every request:

```roc
# main.roc
app [program] { jobs: "…/packages/jobs/main.roc", posthog: "…/packages/posthog/main.roc", pf: platform "…/server/platform/main.roc" }

import jobs.Job
import posthog.PostHog
import Generated/App

program = App.program({
	init!: |started| Ok({ facts: started }),
	plugins: [
		Job.plugin({ jobs: App.jobs, on_failed!: PostHog.job_failed! }),
		PostHog.plugin({}),
	],
})
```

```roc
# routes/+middleware.roc
import posthog.PostHog
import ../Middlewares

# After the middleware that knows who is signed in, so an error says who it reached.
middleware = Middlewares.member.then(PostHog.middleware(|context| context.member.id))
```

And in the layout, so pages send their errors too:

```html
<script src="/rocx-errors.js" defer></script>
```

`packages/posthog/example/` is a whole app wired this way.

## API

All of it is in the `PostHog` module (`import posthog.PostHog`).

| Function | What it does |
| --- | --- |
| `plugin : Options -> Plugin.Value(context, ctx)` | The plugin: the browser's script (`GET <at>.js`), where it sends errors (`POST <at>`), the loop that sends what was kept (`posthog.send`), and a check that logs, once the server has started, where errors go or `off: no POSTHOG_KEY` (`posthog.reporting`). |
| `middleware : (context -> Str) -> Middleware(context, context)` | Reports every answer with a 5xx status that passes through it. The function names who asked, from the context the middleware before it handed on (`""` for nobody known). Put it after the middleware that knows who is signed in, or first, with `\|_\| ""`. |
| `capture! : Str, fields => {}` | Reports an error the app dealt with, with fields (a record, as `Log.error!` takes them). While answering a request, the report also carries the request's path and method. |
| `capture_for! : Str, Str, fields => {}` | `capture!` for a person the app knows (the first argument, as the app names them), so PostHog counts the people an issue reached. |
| `job_failed! : { kind : Str, id : I64, attempts : U64, error : Str } => {}` | Reports a job that failed for good. Give it to the jobs plugin as `on_failed!`. |

`Options` (every field optional):

| Option | Environment | Default |
| --- | --- | --- |
| `key` | `POSTHOG_KEY` | none: reporting is off |
| `host` | `POSTHOG_HOST` | `https://us.i.posthog.com` (`https://eu.i.posthog.com` for EU Cloud) |
| `release` | `POSTHOG_RELEASE` | none (set it to the commit a build is from) |
| `at` | | `/rocx-errors` (its script at `/rocx-errors.js`) |
| `interval_ms` | | `10000` (at least 100) |

An option given in `PostHog.plugin({ … })` wins over the environment.

The package also exposes `Event` (the `$exception` event and the batch body) and `Fingerprint`
(`of` and `normalized`, below), which the plugin uses and its tests check.

## How it works

### The events

Each error is one `$exception` event:

- `$exception_list`: one exception, with its `type`, its message as `value`, and
  `mechanism.handled`. When it happened somewhere with a name (a route's pattern, a job's kind, a
  page's path), the exception also gets one frame (`platform: custom`, `lang: roc` or `javascript`)
  naming that place.
- `$exception_fingerprint`: which issue it belongs to (below).
- `source` (`server`, `browser`, `job`), `place`, `method`, `status`, `release`, and `fields` (the
  app's, or a job's id and attempts). A browser's error also has its `stack`.
- `distinct_id`: the person, as the app names them. An error from nobody known uses the event's
  own id instead, with `$process_person_profile: false`, so it creates no person in PostHog.
- `uuid`: the event's id, so an event sent twice is counted once.

A 5xx event's message is `answered <status>: <the first line of the answer's text>`, or just
`answered <status>` when the answer is HTML or empty.

### Fingerprints

Roc has no stack traces, so PostHog's own grouping has little to go on. The package sets the
fingerprint itself, from:

- a 5xx answer: its route's pattern and its message;
- `capture!`: its message only, so it is one issue wherever it happens;
- a job: its kind and its error;
- a browser's error: its type and message.

Each part is normalized: a word with a digit in it becomes `<n>` (all digits) or `<id>` (a UUID, a
hash, a date), and text in double quotes or backticks becomes `<s>`. So `user 1234 not found` and
`user 77 not found` are one issue.

### Limits

- The newest 1,000 errors are kept while PostHog can't be reached.
- One issue is sent at most 20 times a minute.
- All browsers together send at most 120 errors a minute, and each page load at most 10.
- A page's report may be at most 16 KiB; a message is cut to 2,000 bytes and a stack to 8,000.

A 5xx answer from PostHog, or no answer at all, puts the batch back to be sent next time. A 4xx (a
wrong key) drops it, and says so on the log.

## Tests

- `roc test packages/posthog/main.roc`: the fingerprints and the events' JSON.
- `packages/posthog/test/posthog.test.mjs` builds `example/`, starts it against a fake PostHog, and
  checks that every kind of error arrives, in Chromium too. It also covers the per-issue cap, a
  resend after a 503, and a server with no key, which sends nothing. The job's test needs
  `DATABASE_URL`.

## A daily digest that fixes what it can

Sending errors somewhere pays off when something reads them. PostHog's MCP server
(`https://mcp.posthog.com/mcp`, with a personal API key) lists the issues:
`query-error-tracking-issues-list` gives occurrences and people reached, and
`query-error-tracking-issue` gives one issue's details. A scheduled Claude agent, once a day, can:

1. List the issues that are new or came back in the last 24 hours, ordered by people reached, and
   write the digest: each issue's type, message, place, count, first and last seen, and release.
2. For each of the top issues with a `place`, check out its `release` and see whether master still
   has the bug.
3. Write a failing test from the route, method and fields (an `expect`, or an HTTP test like
   `packages/posthog/test/posthog.test.mjs`), fix the bug on a branch, and open a pull request. It
   never merges.
4. Link the pull request on the issue in PostHog.

Set `POSTHOG_RELEASE` to the commit each build is from (a Docker build argument, say), so step 2
can find it.
