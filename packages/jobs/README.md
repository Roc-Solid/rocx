# jobs

Jobs and cron for a Roc Solid app's server, as a plugin. A job is work queued in the app's database
(Postgres or SQLite) and run in the background by workers, each job in a call of its own. A job
that fails runs again, a little later each time. Schedules queue jobs when their time comes. The
plugin brings the queue's table and its statements for both databases.

The package names the server platform, so only the server's half of an app names it; the browser's
half doesn't see it. The docs site's page, `/ecosystem/jobs`, is the guide; this is the reference.

```roc
# main.roc
app [program] { jobs: "../packages/jobs/main.roc", pf: platform "../server/platform/main.roc" }

import jobs.Cron
import jobs.Job
import Generated/App
import Middlewares
import Jobs

program = App.program({
    init!: |started| Ok({ facts: started }),
    middleware: Middlewares.default,
    plugins: [Job.plugin({ jobs: App.jobs, crons: [Cron.every("0 3 * * *", Jobs.nightly, {})] })],
})
```

```roc
# Jobs.roc: rocx build finds each kind at the top of a module's block, and lists it in App.jobs.
# Each is given the app's context (what its init! made) and its input. A kind annotated
# `Job.Kind(_, input)`, or not annotated, takes the context as the app has it.
import jobs.Job

Jobs := [].{
    welcome : Job.Kind(_, { member : I64 })
    welcome = Job.define("welcome", |_context, { member }| { … Email.send!(…) … })    # Ok({}), or Err(why)

    # Tried once, within 20 minutes (Job.define: five times, no limit).
    reminder = Job.define_with("reminder", { attempts: 1, timeout_ms: 20 * 60_000 }, |_context, { member }| …)

    nightly = Job.define("nightly", |_context, {}| …)
}
```

```roc
Job.enqueue!(Jobs.welcome, { member: 7 }, {})                                            # now
Job.enqueue!(Jobs.welcome, { member: 7 }, { when: At(Time.now_millis!({}) + 60_000) })  # a minute from now
Job.enqueue_keyed!(Jobs.reminder, { member: "ada" }, { key: "reminder:ada" })           # Ok(Queued), or Ok(Exists)
Job.cancel!("reminder:ada")                               # cancels the queued jobs with that key: how many
Job.move!("reminder:ada", At(due))                        # the queued one with that key runs then instead
```

The third argument says how a job is queued, a record whose fields have defaults:
`Job.Opts := { when : When ?? Now }`, and for a keyed job `Job.KeyedOpts := { key : Str, when :
When ?? Now }`. `{}` queues a job to run as soon as a worker is free; `{ when: At(ms) }` not before
that moment (milliseconds since the epoch; one past is due now). A call that says `{ when: Now }`
says the default.

## The plugin

```roc
Job.Options(context) := {
    jobs : List(Job.Handler(context)),                                      # the kinds the workers run: App.jobs
    crons : List({ name : Str, schedule : Str, job : Str, input : Str }) ?? [],   # Cron.every(…)
    workers : U64 ?? 4,                                            # jobs run at once
    retry_ms : U64 ?? 1000,                                        # a failed job's first wait, doubled after
    on_failed! : (Job.Failure => {}) ?? ignored!,                  # a job that failed for good
}
Job.Failure : { kind : Str, id : I64, attempts : U64, error : Str }
Job.plugin : Job.Options(context) -> Plugin.Value(context, ctx)
```

`App.jobs` is every kind the app's modules define: `rocx build` finds each `Job.define` and
`Job.define_with` at the top of a module's block. A program written by hand lists
`Job.handler(kind)` for each kind instead. `on_failed!` is called after the failure is logged; by
default it does nothing more. An error tracker's report goes there (packages/posthog's
`PostHog.job_failed!`).

The plugin adds:

- **The table**, `rocx_jobs`, recorded as the migration `jobs/0001_jobs` (applied after the
  platform's migrations, before the app's).
- **The workers** (`jobs.worker`, `workers` of them; each ends at once without a database or a kind
  to run) and **the schedules' loop** (`jobs.schedules`, when there is a schedule; it ends at once
  without a database).
- **A call**, `jobs.run`, in which each job runs, isolated (`Plugin.isolated!`).
- **Under `--dev` or `--debug`**, `POST /__rocx/jobs/wake`, which tells the workers to look for a
  due job now, as queueing one does. It is for a job another process wrote into `rocx_jobs`
  directly, which on SQLite can't wake them: packages/testing's `enqueue` and `settleJobs` use it.
- **At start**: the kinds and schedules kept, for `Job.kinds!`, `Cron.schedules!` and the jobs
  page; every schedule checked (one it can't read, or one whose job the plugin doesn't run, stops
  the server, saying why); and, with a database, the jobs a stop cut short queued again, and done
  jobs older than a week deleted.

Without the plugin in the app's list, `Job.enqueue!` returns a `JobErr` saying so, rather than
queue a job no worker will run.

### A plugin's own kinds

A kind another package defines (packages/push's `push.deliver`) isn't in `App.jobs`, which lists
only the app's modules' kinds. Its plugin brings it:

- `Job.call(kind)` in its `calls`: the call each of its jobs runs in, named as the kind is
  (`<plugin>.<name>`);
- `Job.adopt!(kind)` in its `starts`: the jobs plugin's registry lists the kind, so the workers
  take its jobs, the jobs page shows it, and its jobs a stop cut short are queued again;
- `Plugin("jobs")` in its `needs`, so the jobs plugin starts first.

```roc
deliver : Job.Kind(_, Input)
deliver = Job.define_with("push.deliver", { attempts: 5, timeout_ms: 60_000 }, |_context, input| deliver!(input))

plugin = |setup| { name: "push", calls: [Job.call(deliver)], starts: [|_context| Job.adopt!(deliver)], needs: [Plugin("jobs")], … }
```

## Running jobs

A job is a row in `rocx_jobs`. Each worker is a background loop (`JobWorker.roc`). It takes the
next job that is due, of a kind the plugin runs, with `for update skip locked` on Postgres, so no
two workers take the same job (on SQLite, writes take turns, so the update that takes it is
enough). It runs the job in a call of its own, so a crash is that job's failure, not the worker's.

A job that fails (an `Err`, a crash, or its time limit passing) runs again after `retry_ms`, then
twice that, and so on (doubling at most twenty times), until its kind's `attempts` are used up
(five with `Job.define`). Each such failure is a warning on the log (`rocx jobs: a job failed, and
runs again`, with its `kind`, `id`, `attempt`, `of`, `again_in_ms` and `error`). When the attempts
run out, the job is `failed`, with its last error. That is an error on the log (`rocx jobs: a job
failed for good`, with its `kind`, `id`, `attempts` and `error`), and then the plugin's
`on_failed!` is called. A failed job stays in `rocx_jobs` until it is retried (`Job.retry!`).

Queueing a job notifies `rocx_jobs` (Postgres's `NOTIFY`, or `Db.notify!` on SQLite), delivered
when the transaction commits (`Db.listen!` hears it as the live topic `db:rocx_jobs`). A worker
sleeps on it (`Live.next!`) until then, or until the next delayed job or retry is due. Queued
inside `Db.transaction!`, a job is a row in the transaction: it is there only if the transaction
commits. A job that was running when the server stopped runs again at the next start.

`Job`'s errors are open unions (`[JobErr(Str), ..others]`), as `Db`'s are (`[DbErr(Str), ..others]`).
So one transaction's body can `?` its statements, its jobs and the app's own errors, with nothing
mapped from one to another, and the caller matches each:

```roc
paused = Db.transaction!(|{}| {
    changed = Db.run!("update monitors set paused = true where id = $1", [Int(id)])?
    if changed == 0 {
        Err(NotFound)
    } else {
        Job.enqueue!(Jobs.paused, { monitor: id }, {})?
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
waits past it ends the call, wherever the job is:

- a database statement: cancelled (on SQLite, interrupted), and its connection closed rather than
  given back to the pool, along with any transaction on it;
- a socket's read or write, a request to another server, an actor's answer, a live topic.

The effect doesn't return an error the job could ignore. It jumps back to the call's guard, as a
crash does, so what the call allocated is freed and what it held (its transaction, sockets, rooms)
is given back. The job fails with `timed out after <limit> ms`, and is tried again if it has
attempts left. Roc that never waits (a loop without an effect) is cut off too: the host interrupts
its thread and ends the call there, as a crash would (server/README.md, "How a call runs").

**A key** (`enqueue_keyed!`) belongs to one pending job. While a job with that key is queued or
running, queueing another with it does nothing and answers `Exists`. Once that job is done, failed
or canceled, the key is free again (a unique index on `unique_key` where the state is `queued` or
`running`). A key names what the job is for (`reminder:ada`), so `Job.cancel!` (queued jobs become
`canceled`; a running one isn't stopped) and `Job.move!` can find it. Each is a statement, so inside
a transaction it takes effect only if the transaction commits.

## On a schedule

```roc
Cron.every("0 3 * * *", Jobs.nightly, {})       # five fields, UTC: at 03:00 each day
Cron.every("*/10 * * * * *", Jobs.tick, {})     # six begin with seconds: every ten seconds
```

A schedule, in the plugin's `crons`, queues its job with its input each time it comes round
(`CronTicker.roc`; the parser and the clock are Roc). Each job it queues is keyed by the schedule
and the second it was due, so a restart never queues one twice, and it is tried as many times as
its kind says.

A schedule has five fields (`minute hour day month weekday`), or six beginning with seconds. Times
are UTC. A field is `*`, a number, a range (`1-5`), a step (`*/15`, `0-30/10`), or a list of them
(`1,15,30`). Months may be named (`JAN`), and weekdays (`MON`; 0 and 7 are Sunday). When both the
day and the weekday are given, either one matching is enough, as in Unix cron.

A time a schedule came round while the server was stopped is skipped: at start, each schedule goes
on from its next time.

## Listing and control

These are what the jobs page (packages/admin's `JobsPage`) is made of, and an app can build its own
pages on them:

```roc
Job.list!({ state: "failed", kind: "", before_id: 0, limit: 50 })   # List(Job.Row), newest first; "" and 0 for any
Job.get!(id)                       # Job.Row, or NotFound
Job.counts!({})                    # how many of each kind in each state
Job.retry!(id)                     # failed or canceled: queued again, due now, attempts back to none
Job.cancel_id!(id)                 # queued: canceled
Job.run_now!(id)                   # queued for later (or for its next attempt): due now
Job.kinds!({})                     # the kinds the plugin runs, with their attempts and time limits
Job.changes                        # the live topic the workers say what they start and finish on
Cron.schedules!({})                # each schedule, its job, and when it comes round next (next_at)
Cron.run_now!(name)                # the schedule's job, queued now
```

A `Job.Row` is a job's id, kind, input (JSON), state (`queued`, `running`, `done`, `failed`,
`canceled`), attempts and `max_attempts`, key, last error, and its times in milliseconds (`run_at`,
`locked_at` when its last attempt began, `finished_at`, `created_at`). A page of `list!` goes on
with `before_id` set to the last row's id. An action on a job in a state it doesn't apply to is a
`JobErr` saying so. `Job.changes` (`rocx:jobs`) carries `<id> running`, `<id> done`,
`<id> queued` and `<id> failed`.

## Modules

| Module | What it has |
|---|---|
| `Job` | kinds (`define`, `define_with`, `handler`; a plugin's, `call` and `adopt!`), queueing (`enqueue!`, `enqueue_keyed!`, `cancel!`, `move!`), reading and acting on the queue (`list!`, `get!`, `counts!`, `retry!`, `cancel_id!`, `run_now!`), `kinds!`, `changes`, and the plugin (`Options`, `plugin`) |
| `Cron` | `every`, the parser (`parse`, `after`), `check`, `schedules!`, `run_now!` |
| `Calendar` | days since the epoch as a date (`civil`) and a weekday, in UTC |
| `JobWorker`, `CronTicker`, `Registry`, `Queue` | the package's own: the workers, the schedules' loop, what the plugin keeps at start, and what the queue's statements share across the two databases |

`roc test packages/jobs/main.roc` runs the `expect`s (the cron parser, the calendar, the backoff).
The server's tests (`server/test`) run the plugin on Postgres and on SQLite.

## Not yet

- **A job's log in the jobs page**: the lines each attempt logged, kept with the attempt and shown
  in the job's drawer. Today a run's lines are in the server's log, with its job's id. PROPOSALS.md
  weighs two options: the package alone (`job.log!`), or the host collecting every line logged
  during an isolated call (recommended).

## Moving from `pf.Job`

Jobs and cron were once the platform's own (`pf.Job`, `pf.Cron`, `pf.JobsPage`). An app written
then moves like this:

- Name the package in the app's header (`jobs: "…/packages/jobs/main.roc"`), and import
  `jobs.Job` and `jobs.Cron` instead of `pf.Job` and `pf.Cron`. The jobs page is `admin.JobsPage`
  (packages/admin, which the header names too), best listed as a plugin:
  `JobsPage.plugin({ at: "/admin/jobs", guard: Middlewares.admin })`. A route file that mounted it
  still works, with `admin.JobsPage`.
- List the plugin: `plugins: [Job.plugin({ jobs: App.jobs, crons: [...] })]`. Schedules move from
  `App.program`'s `crons`, which is gone, to the plugin's.
- `--job-workers` and `--job-retry-ms` are gone: the plugin's `workers` and `retry_ms` replace them.
- A program written by hand drops `jobs` and `crons`, and lists the plugin as above, with
  `Job.handler(kind)` for each kind.
- A database the platform migrated keeps everything: the plugin's migration finds `rocx_jobs` as it
  is and changes nothing.
