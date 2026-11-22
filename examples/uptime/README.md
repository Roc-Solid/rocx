# uptime: Acme Status

An uptime monitor and its public status page. An admin adds monitors (a URL, a method, the status
it should answer, how often to ask, a group); jobs ask each one on time and store how it went;
incidents open on their own after a few failed checks in a row and close when the monitor passes
again; subscribers get an email each time. The status page shows every service's state, its uptime
over 24 hours, 7 and 90 days, its response time and its last 90 days, and it changes as checks come
in, without a reload.

It is a small, whole app on Postgres: jobs and cron through packages/jobs, email through
packages/email, metrics through packages/otel, its tables in packages/admin, charts from
packages/charts, and a channel for the live page.

## A tour

- **`/`** is the status page. A banner says how things are ("All systems operational", "Degraded
  performance", "Partial outage", "Major outage"). Under it, "Live" once the page follows the live
  channel, and when the data was worked out. Then the incidents happening now, each with its
  timeline, and every monitor by group ("Platform", "Websites"): its state, its uptime over 24
  hours, 7 and 90 days, its last response time beside a sparkline of the last day, and a bar for
  each of its last 90 days, green, amber or red by how the day went. Then the incidents of the last
  two weeks, and a form to subscribe to alerts.
- **A monitor's page** (`/monitors/2`) says how it is checked, then its numbers, a line chart of its
  response time each half hour of the last day, a heatmap of its failed checks by day and hour over
  the last week, its 90 days, its last 20 checks and its incidents.
- **An incident's page** (`/incidents/1`), where the alert emails link, has its whole timeline.
- **`/admin`** asks for the admin password (`ADMIN_PASSWORD`), then lists every monitor with its
  URL, its state, "Check now" and "Pause". Each open incident has a form for its next update
  (Investigating, Identified, Monitoring, Resolved), and "Resolved" closes it. "Break it" makes the
  flaky demo fail every check, so you can watch an incident open. The links lead to the tables
  (`/admin/db`, packages/admin: add, edit and delete monitors, see subscribers, checks and
  incidents), the jobs page (`/admin/jobs`) and the dev mailbox (`/__rocx/mail`).
- **Try it:** open `/` in one window and `/admin` in another, and press "Break it". Within about a
  minute and a half (three checks, 30 seconds apart) the status page turns red by itself, shows
  "Happening now" with the incident, and the mailbox has "[Acme Status] Payments API is down" for
  `oncall@example.com`. Post an update from the admin, and it shows on the status page. Press "Mend
  it": the next check closes the incident, the page turns green, and the mailbox has "Resolved:
  Payments API is back".
- **Every page is JSON too**: `curl -H 'accept: application/json' http://127.0.0.1:18130/` (also
  `/monitors/2`, `/incidents/1`, and `/admin` with the admin's cookie).
- **Light and dark** follow the system, and the pages work from a phone's width up.

What it starts with (`migrations/0002_seed.sql`): three monitors, ninety days of history, a past
incident with four updates, and one subscriber, so the page looks lived in the first time. Two
monitors ask the app itself: `/health` ("Status page", which also asks Postgres) and `/demo/flaky`
("Payments API", which takes 40 to 200 ms, fails about one answer in 250, and fails every one while
the admin's switch says so). The third asks https://example.com every five minutes, first a minute
after the first start.

## What it shows

| Feature | Where |
|---|---|
| packages/jobs as a plugin (D-034): `Job.plugin({ jobs: App.jobs, crons })`, a cron every 10 seconds that queues the checks due, one job a check, tried three times, alert jobs tried again while the mail server doesn't answer, and a nightly roll-up | `main.roc`, `Jobs.roc` |
| The sweep: monitors due claimed with one `update … returning` and their checks queued in the same transaction, keyed by monitor (`Job.enqueue_keyed!`), so a check still waiting isn't queued twice | `Jobs.roc` (`sweep!`), `Store.claim_due!` |
| A check: `Http.fetch!` with the monitor's method and time limit, timed with `Time.now_nanos!`, judged (`Checks.judge`, its expects) | `Checks.roc` |
| Storing a check in one transaction: the check, the streak of failures (atomic in Postgres), the incident `Incident.decide` opens or closes, its update, and the alerts it queues, so all of it stays or none does | `Store.record!` |
| The incident rules, as expects: open when the streak reaches the threshold, close on the next pass, no new one after a manual close until the monitor has passed and failed again | `Incident.roc` |
| Uptime arithmetic, as expects: shares rounded down (100% only when nothing failed), roll-ups and the days not rolled up yet put together, the 7- and 90-day windows, each day's level, the banner | `Uptime.roc`, `Days.roc` |
| The nightly roll-up: each past day into `daily` (once: `on conflict do nothing`), checks older than a week deleted when their day is rolled up | `Store.roll_up!`, `Jobs.nightly` |
| Email alerts through packages/email (D-035), one job per subscriber, the HTML a pure component (`Html.to_str`), an unsubscribe link whose page posts (opening it changes nothing) | `Alerts.roc`, `Ui/AlertMail.rocx`, `routes/unsubscribe/` |
| The live page: a channel (D-020), published on by each check and each admin change from jobs and endpoints alike; pages read their data again when they hear it (`refresh!`), rows kept by id, sparklines gliding, changes announced to screen readers (`aria-live`) | `routes/live/+server.roc`, `News.roc`, `routes/+page.rocx` |
| packages/otel: every request timed by route, a histogram of check latency by monitor and outcome, and a gauge of each monitor's up/down (`Otel.roc` copied from the package, as its README says) | `Metrics.roc`, `Middlewares.roc`, `Otel.roc`, `test/copies.test.mjs` |
| packages/charts: `<Sparkline>` on each card, `<LineChart>` and `<Heatmap>` on a monitor's page; the 90-day strip is a pure component of its own (its colours are thresholds, not a scale) | `Ui/MonitorCard.rocx`, `routes/monitors/[id]/+page.rocx`, `Ui/UptimeStrip.rocx` |
| packages/admin for the tables, mounted behind the admin's middleware, with labels; Postgres's checks refuse what makes no sense and the form shows why | `routes/admin/db/+server.roc`, `migrations/0001_uptime.sql` |
| packages/admin's jobs page as a plugin behind the same guard (`JobsPage.plugin({ at, guard })`) | `main.roc` |
| The admin's own pages: a password from the environment, a random session token in `Kv` with a time to live, a cookie, a middleware that sends a stranger to sign in and back | `Session.roc`, `Middlewares.admin`, `routes/admin/` |
| Forms that work without JavaScript and with it (`use_submission!`): subscribe, sign in, check now, pause, post an update, break the demo | `Ui/SubscribeForm.rocx`, `Ui/AdminRow.rocx`, `Ui/UpdateForm.rocx`, `routes/admin/+page.rocx` |
| Each page's data at its own URL as JSON, read as the page renders and carried in it (`Endpoint.get!`); one shape for the page and the API, on no platform | `routes/**/+server.roc`, `Report.roc`, `Status.roc` |
| A 404 for a monitor or incident that isn't there, from an `<Errored>` and `<HttpStatusCode>` | `Ui/Missing.rocx` |
| Pure `view` components (the pill, the strip, the banner, the incident card, the monitor card with an accessor prop) and effectful `view!` ones (forms with submissions, a group with a `<For>`, the 404) | `Ui/` |
| Pure components tested with `testing.Dom` in expects; stories for the catalog (`rocx build --dev`) | `Ui/*.rocx` |
| Scoped styles, tokens in one stylesheet (light and dark), a skip link, focus rings, labels, landmarks | `Ui/*.rocx`, `routes/*.rocx`, `static/uptime.css` |
| A seed that is safe to run again: it is a migration, so it runs once | `migrations/0002_seed.sql` |

## Live updates: a channel, not `events!`

The status page follows the live channel (`routes/live/+server.roc`), and not an endpoint's
`events!` stream, for three reasons:

- **Who speaks is a job.** A check runs in a job, not in a request. `Endpoint.publish!` works from
  either, so the check publishes once and every page hears it. With `events!`, each open page would
  hold a loop on the server that waits on a topic and copies messages out.
- **An outage brings visitors.** The status page is busiest when something is down. A channel's
  stream is held by the host and runs no Roc call while it waits, and every channel a tab follows
  shares one stream. An `events!` stream is a call on the server for as long as the page is open.
- **Reconnects are handled.** On every connect and reconnect, and when a page falls behind, the
  page hears `Resync` and reads its data again. So a laptop waking from sleep shows the truth.

The message says only which monitor changed and how (`News.Said`). Each page reads its own data
again, so what a page shows is always what its endpoint answers.

## Build and run it

From the repository's root, with the toolchain (`just setup`) and a Postgres (`just db`, which
prints its URL):

```sh
docker exec rocx-postgres createdb -U rocx acme_status   # a database of its own
bin/rocx build examples/uptime --client examples/uptime/build/client
.tools/roc-active build --target=wasm32 --opt=size --output=examples/uptime/build/client/static/rocx/app.wasm examples/uptime/build/client/main.roc
node server/build.mjs examples/uptime/main.roc examples/uptime/build/uptime
ADMIN_PASSWORD=acme-demo ORIGIN=http://127.0.0.1:18130 examples/uptime/build/uptime --port 18130 --host 127.0.0.1 \
  --database-url postgres://rocx:rocx@127.0.0.1:55432/acme_status \
  --static examples/uptime/build/client/static --static examples/uptime/static --dev
```

Then open http://127.0.0.1:18130, and http://127.0.0.1:18130/admin with the password `acme-demo`.
The first start makes the tables and the seed. `--dev` serves the dev mailbox at `/__rocx/mail`,
which is where the alerts go without `SMTP_URL`.

The environment:

| Variable | |
|---|---|
| `ADMIN_PASSWORD` | the admin's password; without it nobody can sign in |
| `ORIGIN` | where the app is, for its checks of itself and the links in emails; without it, the loopback address a browser last asked it at (see "What it asked of the platform") |
| `SMTP_URL` | where the alerts are sent (`smtp://user:password@host:587?tls=required`); without it they are kept for the dev mailbox |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | an OpenTelemetry collector for the metrics (`http://localhost:4318`); without it, nothing is measured |

## Test it

```sh
just examples uptime
```

That builds and type-checks both halves, lints, and runs the expects and the node tests. Or by hand,
with `DATABASE_URL` set (each test file makes a database of its own there):

```sh
bin/rocx build examples/uptime
bin/rocx check -- .tools/roc-active test examples/uptime/main.roc   # the expects
DATABASE_URL=postgres://rocx:rocx@127.0.0.1:55432/rocx node --test 'examples/uptime/test/*.test.mjs'
```

- **Expects** (106 of the app's own, 791 with the packages'). They cover uptime shares and their
  rounding, combining roll-ups with raw days, the 7- and 90-day windows, each day's level, a
  monitor's state, the banner and filling gaps in a line (`Uptime.roc`). They also cover the
  incident rules, including a whole up, down, down, down, down, up run (`Incident.roc`), judging an
  answer (`Checks.roc`), and the epoch-day calendar and how times read (`Days.roc`). And the words
  around the numbers (`Words.roc`), which `Host` headers count as this machine (`Origin.roc`), the
  alert emails (`Alerts.roc`), what counts as an email address (`routes/subscribe/+server.roc`),
  and the pure components through `testing.Dom` (`StatePill`, `UptimeStrip`, `Banner`,
  `IncidentCard`).
- **`test/http.test.mjs`** (10 tests) starts the server on a database of its own, with a fake target
  (`http.createServer`, answering 200 or 500 as a test says) that is also a fake OpenTelemetry
  collector. Its tests:
  - the status page and its JSON (banner, groups, 90 days, the past incident);
  - the app's own monitors checking `/health` and `/demo/flaky`, and the demo's switch;
  - a monitor's page and JSON, and the 404s;
  - subscribing, as a plain form and as the runtime sends it, a wrong address, the unsubscribe link;
  - the admin's sign-in, a wrong password with no flash, the pages, packages/admin and the jobs page;
  - **up → down → up**: checks queued with `enqueue()` and run with `settleJobs()`; two failures
    give "degraded", the third opens the incident; the alert mail arrives (`waitForMail`) for the
    test's subscriber and the seeded one; the status page and its JSON say "Partial outage"; a
    fourth failure changes nothing; the pass closes it with a second mail; the six checks are
    stored as they went;
  - an admin's update, and a "Resolved" that closes the incident and mails;
  - "Check now" and "Pause";
  - the nightly roll-up, and that running it twice changes nothing;
  - the metrics reaching the collector.
- **`test/browser.test.mjs`** (2 tests) uses headless Chromium with strict hydration. It opens the
  status page, sends a monitor down and up again through its jobs, and sees the banner, the
  incident and the pill change with no reload, and the screen reader's announcement. It also
  subscribes from the page and sees the answer in place. Both skip without Chromium.
- **`test/copies.test.mjs`** (1 test): `Otel.roc` is still packages/otel's.

## Product calls

- **Everything in UTC.** The browser has no clock of the server's, and a status page read in many
  time zones is clearest in one. The footer says so.
- **No URLs on the public pages.** A monitor's URL may be an address inside the company; the public
  pages show its name and how often it is checked, and only the admin shows URLs.
- **Three failures, then an incident; one pass, and it closes.** The threshold is each monitor's
  (`threshold`, 1 to 10). Closing on the first pass makes an incident's length honest. A manual
  "Resolved" holds until the monitor passes and fails again, so the admin can close a known
  flapping service without it reopening at once.
- **A day is good from 99%, minor from 95%, major below.** The strip shows how each day went. At
  30-second checks, a day turns amber after about 15 minutes of failures and red after about 70; a
  blip leaves it green.
- **Uptime is rounded down.** 100% means nothing failed, so 1999 of 2000 is 99.95%, not 100%.
- **The last day is counted from checks, older days from roll-ups.** Checks are kept for a week,
  then only their day's roll-up. The 24-hour figure counts checks, and 7 and 90 days count days.
- **Subscribing says the same whether or not the address was there**, so the form doesn't tell
  anyone who else subscribed. There is no confirmation email: this is a demo, and the seeded
  subscriber shows the alerts.
- **The unsubscribe link opens a page with a button**, because mail scanners open links.
- **Admin sessions are in memory** (`Kv`, 12 hours): a restart signs the admin out, which is fine
  for one admin. No accounts, and no Web Push (packages/push would be the next step for
  subscribers who want it).

## What it asked of the platform

Every gap met, and what the app does about each:

1. **Fixed: packages/otel had no gauge**, and the brief asked for an up/down gauge per monitor, so
   `uptime.check.up` was a histogram with one bucket boundary, 0.5. The package has
   `Metric.gauge` now (the last value set, sent as OTLP's `gauge`), and `uptime.check.up` is one:
   1 after a check that passed, 0 after one that failed (`Metrics.roc`; the HTTP test reads both
   off the fake collector).
2. **The server doesn't tell the app the address it listens on.** With `--port 0` (the tests') nobody
   knows it beforehand, and a check of `/health` needs a whole URL. `ORIGIN` says it. Without it,
   the default middleware remembers the `Host` a request came with, but only a loopback one, since
   a client writes that header (`Origin.roc`, with expects). Until a page has been asked, the app's
   checks of itself wait and log why. A `Server.address!` or a setting with the port would remove
   this.
3. **A plain form's flash keeps what the form sent, so a password sent to the sign-in form would
   sit in the `rocx-flash` cookie and in the page's flash script.** This happens whenever the
   endpoint refuses (a wrong password). The sign-in endpoint never refuses: it answers its own
   redirect back to the form with `?problem=wrong` (`Err(Answer(…))`), and the page says the
   problem in words. Fields that are never kept (`type="password"`, or a list the endpoint gives)
   would make this safe by default. The HTTP test checks that no flash is set.
4. **packages/otel's actor must be copied into the app**, as its README says (`rocx build` lists
   actor kinds only from the app's own files). `Otel.roc` is a verbatim copy, and
   `test/copies.test.mjs` fails if it drifts.
5. **A module the routes import can't import `Generated/Api`**, which is made of the routes. The job
   that publishes on the live channel names it by its path:
   `Endpoint.remote("CHANNEL", "/live")` (`News.roc`). The board example met this too.
6. **packages/jobs, as its first real user** (D-034). The plugin, `App.jobs`, `Cron.every`,
   `define_with`'s attempts and time limit, the jobs page plugin and packages/testing's
   `enqueue()` and `settleJobs()` all worked as documented, and `settleJobs()` waits for the jobs a
   job queues (the alerts). What was rough:
   - **A sweep on a cron leaves a row a run.** Every 10 seconds is 8,640 done jobs a day, kept a week
     by the plugin's tidy-up: about 60,000 rows that say nothing. A schedule that runs a function
     without a row, or a shorter keep for one kind, would suit a sweep.
   - **Job kinds are values in the module that defines them, so a module that module imports can't
     queue them.** `Jobs.check` runs `Checks.run!`, and a check queues alerts (`Jobs.alert`), so
     `Jobs` passes its own `alert!` down as an argument to avoid an import cycle. Queueing by a
     kind's name, typed, would let any module queue any kind.
   - **Fixed: `JobErr` and `DbErr` were different tags**, so queueing inside a `Db.transaction!`
     took a `match` to turn one into the other. `Db`'s and `Job`'s errors are open unions now
     (`[JobErr(Str), ..others]`), so a transaction's body `?`s both (the sweep, `alert!`), and
     `Store.record!` and `Store.post_update!` say `JobErr` beside `DbErr` for the alerts they queue.
7. **`Http.fetch!`, not `Http.send!`.** The brief said `Http.send!`, which is the deprecated shape
   (D-024). The checks use `fetch!`, whose `timeout_ms` and `max_bytes` fit a monitor.
8. **The client's address isn't passed on**, so wrong passwords can't be counted per client. The
   sign-in allows ten tries a minute in all (`Kv.increment!` with a time to live), then says to
   wait.
9. **packages/admin's pages have no way back to the app's own admin.** Its sidebar lists the tables
   and nothing else, so the way back to `/admin` is the browser's. An option for a link in the
   header would help.
10. **The Roc and rocx gotchas met:**
    - A one-field record written short is a block: `UptimeStrip.view({ days })` passes the list
      itself, so it has to be `{ days: days }`.
    - A parameter or a lambda's argument can't have the name of a member of the module's block.
      `state`, `level` and `day` clashed, hence `Uptime.state_of` and `Uptime.level_of`.
    - A memo is `() => a`, not `{} => a` (`overview! : () => Report.Overview`, read as
      `overview!()`).
    - A pure `view` with a `<For>` inside doesn't compile: it has to be a `view!`
      (`Ui/GroupSection.rocx`).
    - `style` can't be computed, even in an email's HTML, so the alert's heading is two elements,
      one for each colour (`Ui/AlertMail.rocx`).
    - A heatmap's row labels are a value prop: reading them from the page's data would make the
      chart anew on every check, so they are fixed words ("6 days ago" … "Today").
