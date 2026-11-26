# Status

Status is an uptime monitor with a public status page. An admin adds monitors (a URL to check, how
often, and the status it should answer). Background jobs check each monitor on time, open an
incident after a few failed checks in a row, close it when a check passes again, and email the
subscribers each time. The status page shows every service's state, uptime and response time, and
it changes as checks come in, without a reload.

Read it to see a whole small app in one place: jobs and cron (packages/jobs), email
(packages/email), live updates over a channel, metrics (packages/otel), charts (packages/charts), an
admin over the app's tables (packages/admin) behind a password and sessions (packages/auth), and a
SQLite database in the server's process, so it needs nothing else to run.

## Run it

From the repository's root, once the toolchain is set up (`just setup`):

```sh
cd examples/uptime
ADMIN_PASSWORD=acme-demo ../../bin/rocx dev
```

Open http://127.0.0.1:8080, and http://127.0.0.1:8080/admin with the password `acme-demo`.

`rocx dev` builds the app (the server and the browser's WebAssembly), serves it with the server's
`--dev` flag, and builds and restarts it each time you save a file. Run it from the example's
directory: the database is the file `data/uptime.db`, relative to where the server starts
(`database: Sqlite("data/uptime.db")` in `main.roc`; `*.db` files are git-ignored). The first start
makes the file, its tables and the seed data. Under `--dev`, the alert emails go to the dev mailbox
at http://127.0.0.1:8080/__rocx/mail unless `SMTP_URL` is set.

The full form is `rocx dev [dir] [--port N] [-- server options…]`. Options after `--` go to the
server, for example `../../bin/rocx dev -- --database-url sqlite:/tmp/uptime.db`.

The app reads these environment variables:

| Variable | What it is |
|---|---|
| `ADMIN_PASSWORD` | The admin's password. Without it, nobody can sign in. A session lasts 12 hours, and goes on while the admin uses it. |
| `PUBLIC_URL` | Where the app is (`https://status.example.com`, or `--public-url`). It is used for the links in emails and for the checks the app makes of itself. Without it, the app uses the address the server listens on. |
| `SMTP_URL` | Where alerts are sent (`smtp://user:password@host:587?tls=required`). Without it, they are kept for the dev mailbox under `--dev`, and without `--dev` the server doesn't start. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | An OpenTelemetry collector for the metrics (`http://localhost:4318`). Without it, nothing is measured. |

### Build it as it would ship

`rocx dev` builds quickly, without optimizations. To build and start it as you would in production
(from the repository's root):

```sh
just web-host   # the browser's host, which the WebAssembly is linked with
bin/rocx build examples/uptime --client examples/uptime/build/client
.tools/roc-active build --target=wasm32 --opt=size --output=examples/uptime/build/client/static/rocx/app.wasm examples/uptime/build/client/main.roc
node server/build.mjs examples/uptime/main.roc examples/uptime/build/uptime --opt=speed
cd examples/uptime && ADMIN_PASSWORD=acme-demo build/uptime --port 8080 \
  --static build/client/static --static static
```

Without `--dev` the server needs `SMTP_URL`, to send the alerts: it doesn't start without one.

## A tour

- **`/` is the status page.** A banner says how things are: "All systems operational", "Degraded
  performance", "Partial outage" or "Major outage". Under it, "Live" shows once the page is
  following the live channel, and "Updated" says when the data was read. Then come the incidents
  happening now, each with its timeline, and every monitor by group ("Platform", "Websites"). Each
  monitor shows its state, its uptime over 24 hours, 7 days and 90 days, its last response time
  beside a sparkline of the last day, and a bar for each of its last 90 days (green, amber or red).
  At the bottom are the incidents of the last two weeks and a form to subscribe to alerts.
- **A monitor's page** (`/monitors/2`) says how the monitor is checked. It shows its numbers, a line
  chart of its response time for each half hour of the last day, a heatmap of its failed checks by
  day and hour over the last week, its 90 days, its last 20 checks and its incidents.
- **An incident's page** (`/incidents/1`) has the incident's whole timeline. The alert emails link
  here.
- **`/admin`** asks for the admin password, then lists every monitor with its URL, its state, and
  two buttons: "Check now" and "Pause". Each open incident has a form for its next update
  (Investigating, Identified, Monitoring, Resolved); "Resolved" closes the incident. "Break it" makes
  the demo service fail every check, so you can watch an incident open. Links lead to the tables
  (`/admin/db`, where you add, edit and delete monitors), the jobs page (`/admin/jobs`) and the dev
  mailbox (`/__rocx/mail`).
- **Try it:** open `/` in one window and `/admin` in another, and press "Break it". Within about a
  minute and a half (three checks, 30 seconds apart) the status page turns red by itself and shows
  the incident under "Happening now". The mailbox has "[Status] Payments API is down", sent to
  `oncall@example.com`. Post an update from the admin, and it shows on the status page. Press "Mend
  it": the next check closes the incident, the page turns green, and the mailbox has "[Status]
  Resolved: Payments API is back".
- **Every page is JSON too:** `curl -H 'accept: application/json' http://127.0.0.1:8080/` (also
  `/monitors/2`, `/incidents/1`, and `/admin` with the admin's cookie).
- **Light and dark** follow the system, and the pages work from a phone's width up.

The seed (`migrations/0002_seed.sql`) gives the app three monitors, ninety days of history, a past
incident with four updates, and one subscriber, so the page looks lived in from the first start. Two
monitors check the app itself:

- "Status page" asks `/health`, which also asks the database.
- "Payments API" asks `/demo/flaky`, which takes 40 to 200 ms, fails about one answer in 250, and
  fails every answer while the admin's "Break it" switch is on.

The third, "example.com", asks https://example.com every five minutes, starting a minute after the
first start.

## What it shows

Where to look in the code for each Roc Solid feature the app uses.

### Background work: jobs, cron and email

| Feature | Where |
|---|---|
| packages/jobs as a plugin: `Job.plugin({ jobs: App.jobs, crons })` in `main.roc`. A cron every 10 seconds queues the checks that are due, and another runs a roll-up each night at 03:00 UTC. | `main.roc`, `Jobs.roc` |
| Job kinds with their own retries and time limits (`Job.define_with`): a check is tried three times; an alert (`Job.define`, five tries) is tried again, waiting longer each time, while the mail server doesn't answer. | `Jobs.roc` |
| The sweep: one `update … returning` claims the monitors that are due, and their checks are queued in the same transaction. Each check is keyed by its monitor (`Job.enqueue_keyed!`), so a check still waiting isn't queued twice. | `sweep!` in `Jobs.roc`, `Store.claim_due!` |
| A check: `Http.fetch!` with the monitor's method and time limit, timed with `Time.now_nanos!`, then judged by `Checks.judge` (which has its own `expect` tests). | `Checks.roc` |
| Storing a check in one transaction: the check, the streak of failures, the incident that `Incident.decide` opens or closes, its update, and the alert jobs it queues. All of it is stored, or none of it. | `Store.record!` |
| The incident rules, tested with `expect`s: open when the streak reaches the threshold, close on the next pass, and after a manual close, don't open again until the monitor has passed and failed again. | `Incident.roc` |
| The nightly roll-up: each past day's checks summed into `daily` (once, with `on conflict do nothing`), and checks older than a week deleted once their day is rolled up. | `Jobs.nightly`, `Store.roll_up!` |
| Email alerts through packages/email: one job per subscriber. The email's HTML is a pure component turned into a string (`Html.to_str`). Its unsubscribe link opens a page with a button, so opening the link changes nothing. | `Alerts.roc`, `Ui/AlertMail.rocx`, `routes/unsubscribe/` |
| The jobs page from packages/admin, as a plugin behind the admin's sign-in (`JobsPage.plugin({ at, guard, back })`). | `main.roc` |

### The live status page

| Feature | Where |
|---|---|
| A channel (live messages for open pages) at `/live`. Each check and each admin change publishes on it, from jobs and endpoints alike (`News.tell!`). | `routes/live/+server.roc`, `News.roc` |
| A page that subscribes to the channel in an effect (`create_effect!` with `Endpoint.subscribe!`) and reads its data again when it hears something (`refresh!` on its memo). The page fades while the new data loads (`is_pending!`), and a hidden `aria-live` region tells screen readers what changed. | `routes/+page.rocx`, `routes/monitors/[id]/+page.rocx`, `routes/admin/+page.rocx` |
| Lists whose rows are kept by key. A group maps its monitors to cards (`{...monitors.map(…)}`), each card's root keyed by `key={monitor.id}`, so a new reading keeps the cards and patches only what changed. A card takes its monitor as an accessor (`monitor!={monitor}`), so its numbers update in place and its sparkline glides to the new values. | `Ui/GroupSection.rocx`, `Ui/MonitorCard.rocx` |
| Charts from packages/charts: `<Sparkline>` on each card; `<LineChart>` and `<Heatmap>` on a monitor's page. The 90-day strip is a pure component of its own, because its colours are thresholds, not a scale. | `Ui/MonitorCard.rocx`, `routes/monitors/[id]/+page.rocx`, `Ui/UptimeStrip.rocx` |

### Pages, endpoints and components

| Feature | Where |
|---|---|
| Each page's data comes from an endpoint at the page's own URL (`GET /` as JSON, and so on). The page reads it with `Endpoint.get!` while the server renders it, and the data travels in the page for hydration. The same JSON is the app's API. | `routes/**/+server.roc`, `Status.roc`, `Report.roc` |
| A 404 for a monitor or incident that doesn't exist: the page's `<Errored>` shows `Ui/Missing.rocx`, which sets the status with `<HttpStatusCode>`. | `routes/monitors/[id]/+page.rocx`, `routes/incidents/[id]/+page.rocx`, `Ui/Missing.rocx` |
| Forms that work without JavaScript and, with it, are sent in place (`use_submission!`): subscribe, sign in, check now, pause, post an update, break the demo. | `Ui/SubscribeForm.rocx`, `Ui/AdminRow.rocx`, `Ui/UpdateForm.rocx`, `routes/admin/+page.rocx`, `routes/admin/sign-in/+page.rocx` |
| Pure components (`view`): the state pill, the 90-day strip, the banner, the incident card, and the monitor card. Effectful components (`view!`): the forms (they make submissions), the group (its list of rows), and the 404 (it sets the status). | `Ui/` |
| Pure components tested in `expect`s with packages/testing's `Dom`, and stories for the component catalog (`<story>`, shown at `/__rocx/stories` under `rocx dev`). | `Ui/Banner.rocx`, `Ui/IncidentCard.rocx`, `Ui/StatePill.rocx`, `Ui/UptimeStrip.rocx` |
| Scoped styles in each component, design tokens in one stylesheet (light and dark), a skip link, focus rings, labels and landmarks. | `Ui/*.rocx`, `routes/**/*.rocx`, `static/uptime.css` |

### Admin, metrics and data

| Feature | Where |
|---|---|
| The admin's sign-in: a password from the environment, compared in constant time, then a session from packages/auth (`Auth.sign_in!`). The plugin is listed without `admit!`, so nobody signs in by a link or a provider. The session is a random token in the `uptime_admin` cookie (HttpOnly; `__Host-uptime_admin` and `Secure` when the public URL is HTTPS), kept as its hash in the database (`auth_sessions`) for 12 hours, and renewed while it is used. `Auth.required` sends a stranger to sign in (`?then=`) and back, and signing out is a form posting to the plugin's `/auth/sign-out`. Wrong passwords are limited to ten tries a minute (`Kv.increment!`). | `main.roc`, `Session.roc`, `Middlewares.admin`, `routes/admin/` |
| packages/admin for the tables, behind the admin's middleware, with labels. The tables' `check` constraints refuse values that make no sense (named, like `monitors_url_check`), and the admin's form shows why. | `routes/admin/db/+server.roc`, `migrations/0001_uptime.sql` |
| packages/otel: every request timed by route (`Otel.middleware`), a histogram of check latency by monitor and outcome, and a gauge of each monitor's up or down state, sent by the package's plugin (`Otel.plugin`). | `Metrics.roc`, `Middlewares.roc`, `main.roc` |
| SQLite in the server's process (`database: Sqlite("data/uptime.db")`). Moments are milliseconds given from Roc and read as ISO 8601 with `strftime`; days with `date`. See [Moving from Postgres to SQLite](#moving-from-postgres-to-sqlite) for what SQLite lacks. | `main.roc`, `Store.roc`, `migrations/` |
| Seed data that is safe to start with again: it is a migration, so it runs once. | `migrations/0002_seed.sql` |

## Live updates: a channel, not `events!`

The status page follows the live channel (`routes/live/+server.roc`) rather than an endpoint's
`events!` stream (server-sent events). There are three reasons:

- **The speaker is a job.** A check runs in a job, not in a request. `Endpoint.publish!` works from
  either, so the check publishes once and every open page hears it. With `events!`, each open page
  would hold a loop on the server that waits on a topic and copies messages out.
- **An outage brings visitors.** A status page is busiest when something is down. While a channel's
  stream waits, the host holds it and no Roc code runs, and all the channels a tab follows share one
  stream. An `events!` stream is a call on the server for as long as the page is open.
- **Reconnects are handled.** On every connect and reconnect, and when a page falls behind, the page
  hears `Resync` and reads its data again. A laptop waking from sleep shows the current state.

The message says only which monitor changed and how (`Report.News`). Each page then reads its own
data again, so what a page shows is always what its endpoint answers.

## Test it

```sh
just examples uptime
```

This builds the app, type-checks the server's and the browser's programs, lints it, checks its SQL
(`rocx check --sql`), and runs the `expect`s and the node tests. For a quick type check alone, run
`../../bin/rocx check` in `examples/uptime` (exit 1 on an error, 2 on warnings).

To run the parts by hand from the repository's root (each test file makes its own SQLite file in a
temporary directory and removes it after):

```sh
bin/rocx build examples/uptime
bin/rocx check -- .tools/roc-active test examples/uptime/main.roc   # the expects
node --test 'examples/uptime/test/*.test.mjs'
```

- **`expect`s** (about a hundred of the app's own). They cover uptime shares and their rounding,
  combining rolled-up days with raw ones, the 7- and 90-day windows, each day's level, a monitor's
  state, the banner, and filling gaps in a line (`Uptime.roc`). They also cover the incident rules,
  including a whole up, down, down, down, down, up run (`Incident.roc`), judging an answer
  (`Checks.roc`), the calendar and how times read (`Days.roc`), the words around the numbers
  (`Words.roc`), the alert emails (`Alerts.roc`), what counts as an email address
  (`routes/subscribe/+server.roc`), and the pure components (`StatePill`, `UptimeStrip`, `Banner`,
  `IncidentCard`).
- **`test/http.test.mjs`** (11 tests) starts the server on its own SQLite file, with a fake target
  (an HTTP server that answers 200 or 500, as a test says) that is also a fake OpenTelemetry
  collector. It tests:
  - the status page and its JSON (the banner, the groups, the 90 days, the past incident);
  - the app's own monitors checking `/health` and `/demo/flaky`, and the demo's switch;
  - a monitor's page and JSON, and the 404s;
  - subscribing, as a plain form and as the runtime sends it, a wrong address, and the unsubscribe
    link;
  - the admin's sign-in (a wrong password is refused and never sent back: no cookie, no `value`;
    a `then` off the site goes to `/admin`), the session's row in `auth_sessions` (the token's
    hash, 12 hours), the admin's pages, packages/admin and the jobs page, and signing out at
    `/auth/sign-out` (the row gone, the old cookie no good);
  - **up, down, up:** checks are queued with `enqueue()` and run with `settleJobs()` (on SQLite,
    these wake the server's job workers through the jobs plugin's `POST /__rocx/jobs/wake`). Two
    failures give "degraded", and the third opens the incident. The alert mail arrives
    (`waitForMail`) for the test's subscriber and the seeded one, and the status page and its JSON
    say "Partial outage". A fourth failure changes nothing. The pass closes the incident with a
    second mail, and all six checks are stored;
  - an admin's update, and a "Resolved" update that closes the incident and sends mail;
  - "Check now" and "Pause";
  - the nightly roll-up, and that running it twice changes nothing;
  - the metrics reaching the collector;
  - the admin's session outliving a restart of the server.
- **`test/browser.test.mjs`** (2 tests) uses headless Chromium with strict hydration checks. It
  opens the status page, sends a monitor down and up again through its jobs, and sees the banner,
  the incident and the state pill change with no reload, along with the screen reader announcement.
  It also subscribes from the page and sees the answer in place. Both tests skip without Chromium.

## Product calls

- **Everything is in UTC.** A status page read in many time zones is clearest in one, and the
  footer says so.
- **No URLs on the public pages.** A monitor's URL may be an address inside the company. The public
  pages show its name and how often it is checked; only the admin shows URLs.
- **Three failures open an incident; one pass closes it.** The threshold is set per monitor
  (`threshold`, 1 to 10). Closing on the first pass keeps an incident's length honest. A manual
  "Resolved" holds until the monitor passes and fails again, so the admin can close a known flapping
  service without it reopening at once.
- **A day is good from 99%, minor from 95%, and major below that.** With checks every 30 seconds, a
  day turns amber after about 15 minutes of failures and red after about 70. A blip leaves it green.
- **Uptime is rounded down.** 100% means nothing failed, so 1999 checks passed of 2000 is 99.95%,
  not 100%.
- **The last 24 hours are counted from checks, older days from roll-ups.** Checks are kept for a
  week, then only their day's roll-up.
- **Subscribing answers the same whether or not the address was already subscribed**, so the form
  doesn't tell anyone who else subscribed. There is no confirmation email: this is a demo, and the
  seeded subscriber shows the alerts.
- **The unsubscribe link opens a page with a button**, because mail scanners open links.
- **One admin, one password.** The password comes from the environment, and its sessions are
  packages/auth's: kept in the database for 12 hours (renewed while the admin works), so a restart or
  a deploy doesn't sign the admin out. There are no accounts and no Web Push (packages/push would be
  the next step for subscribers who want it).

## What it asked of the platform

Writing the app turned up gaps in the platform and the packages. Most are fixed now; these are still
worth knowing.

1. **A sweep on a cron leaves a job row each run.** Every 10 seconds is 8,640 finished jobs a day,
   kept for a week by the plugin's tidy-up: about 60,000 rows that say nothing. A schedule that runs
   a function without a row, or a shorter keep for one kind, would suit a sweep better.
2. **A job kind is a value in the module that defines it, so a module that module imports can't
   queue it.** `Jobs.check` runs `Checks.run!`, and a check queues alerts (`Jobs.alert`). To avoid an
   import cycle, `Jobs` passes its own `alert!` down as an argument. Queueing a kind by its name,
   typed, would let any module queue any kind.
3. **Wrong passwords are counted for everyone together**, ten tries a minute. The app was written
   before the server passed on the client's address; `Server.Request` now has `peer` (the
   connection's address), so a per-client limit is possible.
4. **Roc and rocx gotchas met on the way:**
   - A one-field record written short is a block: `UptimeStrip.view({ days })` passes the list
     itself, so it has to be `{ days: days }`.
   - A parameter or a lambda's argument can't have the name of a member of the module's block.
     `state`, `level` and `day` clashed, hence `Uptime.state_of` and `Uptime.level_of`.
   - A memo's type is `() => a`, not `{} => a` (`overview! : () => Report.Overview`, read as
     `overview!()`).
   - A list of rows that changes is effectful (its rows are made once and kept), so a component
     that holds one is a `view!`, as `Ui/GroupSection.rocx` is.
   - A heatmap's row labels are a value prop. Labels read from the page's data would make the chart
     anew on every check, so they are fixed words ("6 days ago" … "Today").

Fixed since, and visible in the code:

- The admin's sessions are packages/auth's (`Auth.sign_in!`, `Auth.required`, `/auth/sign-out`).
  They were kept in `Kv`, in the server's memory, so every restart signed the admin out; now they
  are rows in the database, kept as their token's hash.
- packages/otel has `Metric.gauge` now, so `uptime.check.up` is a real gauge: 1 after a check that
  passed, 0 after one that failed.
- `Env.public_url!` gives the app its own address (`--public-url`, `PUBLIC_URL`, or where the server
  listens), so a check of `/health` works even with `--port 0` in the tests.
- The platform keeps a plain form's flash (what the form sent, and its answer) in the server's
  memory, and never puts a password back into the form or the page. The sign-in refuses a wrong
  password with `Status(401, …)`, as any endpoint refuses.
- `Generated/Api` is the app's contract and imports no route file, so a job can publish on the
  channel, typed: `News.tell!` uses `Api.channel_live({})`. The message type lives in `Report.roc`,
  because `Api` imports the module that defines it, and that module can't import `Api` back.
- `Db`'s and `Job`'s errors are open unions, so a transaction's body can use `?` on both (the sweep,
  `alert!`).
- packages/admin's tables and jobs page take `back`, a link to the app's own admin first in their
  sidebar (here "Status admin").
- `style:color={…}` sets one CSS property from data, in `Html.to_str` too, so the alert email's
  heading is one element (`Ui/AlertMail.rocx`).
- On SQLite, packages/testing's `enqueue()` and `settleJobs()` wake the server's job workers through
  `POST /__rocx/jobs/wake` (served under `--dev` or `--debug`).

### Moving from Postgres to SQLite

The app started on Postgres. Its SQL is SQLite's now, and what SQLite has no form for is written
another way:

- **No functions of the app's own.** Postgres's `iso()`, `utc_day()` and `utc_today()` are SQL that
  `Store.roc` writes (`iso`, `day`), and "now" is a parameter (`Time.now_millis!`).
- **No lateral join.** A monitor's last check is joined by the id of its newest check
  (`last_check` in `Store.roc`).
- **No regular expressions.** The URL and email checks in the migration are globs with the same
  rules, named so that a refusal says which one failed.
- **No booleans from expressions.** A boolean worked out in SQL (`exists (…)`) is 0 or 1, read as an
  `I64` and turned into a `Bool` in `Store.roc`.
- **No comments on tables**, which packages/admin showed under a table's name.
- **No `hashtext`.** The seed's history comes from a hash of the monitor's id and the day written in
  SQL, so it is the same in every database.
