# jobs

Jobs and cron for a Roc Solid app's server, as a plugin (D-034): work queued in the app's database
(Postgres or SQLite, D-045: the plugin has its table and statements for each) and run in
the background by workers, each job in a call of its own, tried again if it fails, a little later
each time; jobs on a schedule; and the queue's table. It names the server platform, so only an app
on it names this package: the browser's half doesn't see it.

```roc
# main.roc
app [program] { jobs: "../packages/jobs/main.roc", pf: platform "../server/platform/main.roc" }

import jobs.Cron
import jobs.Job
import Generated/App
import Middlewares
import Jobs

program = App.program({
    context: |started| { facts: started },
    middleware: Middlewares.default,
    plugins: [Job.plugin({ jobs: App.jobs, crons: [Cron.every("0 3 * * *", Jobs.nightly, {})] })],
})
```

```roc
# Jobs.roc: rocx build finds each kind at the top of a module's block, and lists it in App.jobs
import jobs.Job

Jobs := [].{
    welcome : Job.Kind({ member : I64 })
    welcome = Job.define("welcome", |{ member }| { … Email.send!(…) … })    # Ok({}), or Err(why)

    # Tried once, within 20 minutes (Job.define: five times, no limit).
    reminder = Job.define_with("reminder", { attempts: 1, timeout_ms: 20 * 60_000 }, |{ member }| …)

    nightly = Job.define("nightly", |{}| …)
}
```

```roc
Job.enqueue!(Jobs.welcome, { member: 7 }, { when: Now })
Job.enqueue!(Jobs.welcome, { member: 7 }, { when: At(Time.now_millis!({}) + 60_000) })  # a minute from now
Job.enqueue_keyed!(Jobs.reminder, { member: "ada" }, { when: Now, key: "reminder:ada" }) # Ok(Queued), or Ok(Exists)
Job.cancel!("reminder:ada")                               # the queued jobs with that key: how many
Job.move!("reminder:ada", At(due))                        # the queued one with that key runs then
```

## The plugin

```roc
Job.Options := {
    jobs : List(Job.Handler),                                      # the kinds the workers run: App.jobs
    crons : List({ name : Str, schedule : Str, job : Str, input : Str }) ?? [],   # Cron.every(…)
    workers : U64 ?? 4,                                            # jobs run at once
    retry_ms : U64 ?? 1000,                                        # a failed job's wait, doubled after
    on_failed! : (Job.Failure => {}) ?? ignored!,                  # a job that failed for good
}
Job.Failure : { kind : Str, id : I64, attempts : U64, error : Str }
Job.plugin : Job.Options -> Plugin.Value(ctx)
```

`App.jobs` is every kind the app's modules define (`rocx build` finds each `Job.define` and
`Job.define_with`; a program written by hand lists `Job.handler(kind)` for each). The plugin adds:

- **The table**, `rocx_jobs`, recorded as `jobs/0001_jobs` (after the platform's migrations, before
  the app's).
- **The workers** (`jobs.worker`, `workers` of them; none without a database or a kind to run) and
  **the schedules' loop** (`jobs.schedules`, with a database and a schedule).
- **A call**, `jobs.run`: each job runs in a call of its own (`Plugin.isolated!`).
- **Under `--dev` or `--debug`**, `POST /__rocx/jobs/wake`: the workers told to look for a due job
  now, as queuing one tells them. For a job another process wrote into `rocx_jobs` itself, which on
  SQLite can't tell them (a test's: packages/testing's `enqueue` and `settleJobs` ask it).
- **At start**: the kinds and schedules kept, for `Job.kinds!`, `Cron.schedules!` and the jobs
  page; every schedule checked (one it can't read, or whose job the plugin doesn't run, stops the
  server, saying why); and, with a database, the jobs a stop cut short queued again, and done jobs
  older than a week deleted.

Without the plugin in the app's list, `Job.enqueue!` says so (`JobErr`) rather than queue a job no
worker will run.

## Running jobs

A job is a row in `rocx_jobs`. Each worker is a background loop (`JobWorker.roc`): it takes the
next job due of a kind the plugin runs with `for update skip locked`, so none is taken twice, and
runs it in a call of its own, so a crash is that job's failure, not the worker's. A job that fails
(an `Err`, a crash, or its time limit passing) runs again after `retry_ms` (1000), then twice that,
and so on, as many attempts in all as its kind says (`attempts`; five with `Job.define`), each
failure a warning on the log (`rocx jobs: a job failed, and runs again`, with its `kind`, `id`,
`attempt`, `of`, `again_in_ms` and `error`); then it is `failed`, with its last error, an error on
the log (`rocx jobs: a job failed for good`, with its `kind`, `id`, `attempts` and `error`), and given to the plugin's `on_failed!` (nothing more
unless the app says: an error tracker's report, as packages/posthog's `PostHog.job_failed!`). Queueing one notifies `rocx_jobs` (Postgres's `NOTIFY`, or
`Db.notify!` on SQLite), delivered when the transaction commits (`Db.listen!` hears it as the live
topic `db:rocx_jobs`); a worker sleeps
on it (`Live.next!`) until then, or until the next delayed job or retry falls due. Queued in a
transaction (`Db.transaction!`), a job is a row in it: there only if it commits. A job running when
the server stopped runs again at the next start.

`Job`'s errors are open unions (`[JobErr(Str), ..others]`), as `Db`'s are (`[DbErr(Str), ..others]`),
so one transaction's body `?`s its statements, its jobs and the app's own errors, with nothing
mapped from one to another, and the caller matches each:

```roc
paused = Db.transaction!(|{}| {
    changed = Db.run!("update monitors set paused = true where id = $1", [Int(id)])?
    if changed == 0 {
        Err(NotFound)
    } else {
        Job.enqueue!(Jobs.paused, { monitor: id }, { when: Now })?
        Ok({})
    }
})
match paused {
    Ok({}) => …
    Err(NotFound) => …      # the app's own: no such monitor
    Err(DbErr(why)) => …    # a statement's
    Err(JobErr(why)) => …   # the queue's
}
```

**A time limit** (`timeout_ms`, 0 for none) is a deadline on the job's call. The first effect that
waits past it ends the call, wherever the job is: a database statement (cancelled, or on SQLite
interrupted, and its connection closed rather than given back to the pool, a transaction on it
with it), a socket's read
or write, a request to another server, an actor's answer, a live topic. The effect doesn't return
an error the job could ignore: it jumps back to the call's guard, as a crash does, so what the call
allocated is freed and what it held (its transaction, sockets, rooms) is given back. The job fails
with `timed out after <limit> ms`, and is tried again if it has attempts left. Roc that loops
without an effect isn't cut off.

**A key** (`enqueue_keyed!`) is one pending job's: while a job with it is queued or running,
queueing another with it does nothing and answers `Exists`; once that one is done, failed or
canceled, the key is free again (a unique index on `unique_key` where the state is `queued` or
`running`). It names what the job is for (`reminder:ada`), so `Job.cancel!` (queued ones become
`canceled`; a running one isn't stopped) and `Job.move!` can find it. Each is a statement, so in a
transaction it stays only if the transaction commits.

## On a schedule

```roc
Cron.every("0 3 * * *", Jobs.nightly, {})       # five fields, UTC: at 03:00 each day
Cron.every("*/10 * * * * *", Jobs.tick, {})     # six begin with seconds: every ten seconds
```

A schedule, in the plugin's `crons`, queues its job each time it comes round (`CronTicker.roc`: the
parser and the clock are Roc), keyed by its schedule and the second it was due, so a restart never
queues one twice, and tried as many times as its kind says. A field is `*`, a number, a range
(`1-5`), a step (`*/15`), or a list of them; months and weekdays may be named (`JAN`, `MON`).

## Listing and control

What the jobs page is made of (`packages/admin`'s `JobsPage.plugin({ at, guard })`), and an app
may build its own on:

```roc
Job.list!({ state: "failed", kind: "", before_id: 0, limit: 50 })   # List(Job.Row), newest first; "" and 0 for any
Job.get!(id)                       # Job.Row, or NotFound
Job.counts!({})                    # how many of each kind in each state
Job.retry!(id)                     # failed or canceled: queued again, due now, attempts back to none
Job.cancel_id!(id)                 # queued: canceled
Job.run_now!(id)                   # queued for later (or for its next attempt): due now
Job.kinds!({})                     # the kinds the plugin runs, with their attempts and time limits
Job.changes                        # the live topic workers say what they start and finish on
Cron.schedules!({})                # each schedule, its job, and when it comes round next (next_at)
Cron.run_now!(name)                # the schedule's job, queued now
```

A `Job.Row` is a job's id, kind, input (JSON), state (`queued`, `running`, `done`, `failed`,
`canceled`), attempts and `max_attempts`, key, last error, and its times in milliseconds (`run_at`,
`locked_at` when its last attempt began, `finished_at`, `created_at`). An action on a job in a state
it doesn't apply to is a `JobErr` saying so.

Waits on a proposal (PROPOSALS.md):

- **A job's log in the jobs page**: the lines each attempt logged, kept with the attempt and shown
  in the job's drawer. Parked, with two options: the package alone (`job.log!`), or the host
  collecting every line logged during an isolated call (recommended).

## Modules

| Module | What it has |
|---|---|
| `Job` | kinds (`define`, `define_with`, `handler`), queueing (`enqueue!`, `enqueue_keyed!`, `cancel!`, `move!`), reading and acting on the queue, `kinds!`, `changes`, and the plugin (`Options`, `plugin`) |
| `Cron` | `every`, the parser (`parse`, `after`), `check`, `schedules!`, `run_now!` |
| `Calendar` | days since the epoch as a date (`civil`) and a weekday, in UTC |
| `JobWorker`, `CronTicker`, `Registry` | the workers, the schedules' loop, and what the plugin keeps at start: the package's own |

## Moving to it

From the platform's `pf.Job`, `pf.Cron` and `pf.JobsPage` (before D-034):

- Name the package in the app's header (`jobs: "…/packages/jobs/main.roc"`), and import
  `jobs.Job`, `jobs.Cron` instead of `pf.Job`, `pf.Cron`; the jobs page is `admin.JobsPage`
  (packages/admin, which the header names too), best listed as a plugin:
  `JobsPage.plugin({ at: "/admin/jobs", guard: Middlewares.admin })`, in place of the route file
  that mounted it (which still works, with `admin.JobsPage`).
- List the plugin: `plugins: [Job.plugin({ jobs: App.jobs, crons: [...] })]`. The schedules that were
  `App.program`'s `crons` are the plugin's now, and `App.program` has no `crons`.
- `--job-workers` and `--job-retry-ms` are gone: the plugin's `workers` and `retry_ms` say it.
- A program written by hand drops `jobs` and `crons`, and lists the plugin as above, with
  `Job.handler(kind)` for each kind.
- A database the platform migrated keeps everything: the plugin's migration finds `rocx_jobs` as it
  is, and changes nothing (tested: a queue from before, its jobs where they were).
