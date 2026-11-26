# Proposals: what the jobs package would like next

Nothing here is built. Each proposal says what it would take, and where the work goes: this package,
the jobs page (packages/admin), the platform, or more than one.

## A job's log in the jobs page

**Status (2026-11-23).** Parked. Two options below, the second recommended. Nothing is built.

**Problem.** When a job fails, the jobs page shows its last error and nothing else: not what the
job did before it failed, and not what its earlier attempts said. What a job logs (`Log.info!` and
the rest) goes to the server's stderr, mixed in with every request's lines, with nothing on them
saying which job wrote them. An admin who opens a failed job wants the lines it wrote, attempt by
attempt, beside its input.

**How it works today.**

- `Log.*` hands each line to the host (`Host.log!`), which queues it for a writer thread that
  writes it to stderr (`server/host/src/logging.rs`). After that nothing in Roc sees the line
  again, neither a package nor the platform: there's no hook and no per-call tag.
- Each attempt is already a call of its own. The worker runs it with
  `Plugin.isolated!("jobs.run", …)` (`JobWorker.attempt!`), and the host gives every call a
  `Context` of its own (`server/host/src/hosted.rs`). The context is stashed while the call waits
  and put back when it resumes, so the host knows which call wrote each line.
- `rocx_jobs` keeps one row per job: `attempts` is a count, and `last_error` is the last attempt's
  error. Earlier attempts leave nothing behind.
- Finished jobs are swept (`JobSweeper`, every hour and at start): done ones a week after they
  finished, failed and canceled ones 30 days after (the plugin's `keep_done_ms` and
  `keep_failed_ms`).

### Option 1: the package alone

A job that wants its lines kept logs them through the package:

```roc
sync = Job.define_logged("sync", |_context, { account }, job| {
    job.log!("fetching", { account })
    ...
})
```

- `job.log!` writes the line to stderr, as `Log.info!` does, and pushes a copy to Kv under
  `jobs:log:<id>:<attempt>` (`Kv.push!`, capped). Kv is outside any transaction, and it keeps
  what was pushed when the call crashes or runs out of time, so a failed attempt's lines survive.
- After the attempt, `JobWorker.finish!` takes the list (`Kv.list!`, then `Kv.delete!`) and writes
  it to the attempts table (as in Option 2, below).
- The handler needs the job's id and attempt to know where to push. `Job.Kind`'s `run!` is
  `context, input => Try({}, Str)` today, so a third argument comes in through `define_logged`,
  beside `define`. Existing jobs don't change.

**What it can't do.** It can't catch a line the job didn't write through `job.log!`. A `Log.warn!`
in a helper module, in another package (Http's retries, otel, email), or from the host itself (a
transaction left open and rolled back) still goes only to stderr. A helper that should log for the
job must be handed `job`.

**Cost.** No platform change. About a day: the define variant, the Kv buffer, the table and the
drawer.

### Option 2: the host collects, the package keeps and shows (recommended)

**The platform (small).** An isolated call can ask the host to keep a copy of the lines logged
during it.

- `Context` gets `captured: Option<Captured>`: the lines, their size, and how many were dropped.
  When it is set, `logging::from_roc` and the host's own `logging::*` calls made in the call push a
  copy (time, level, message, fields as JSON). The line still goes to stderr, as now.
- Calls the job runs inside itself share the collection, as they share its deadline. An actor it
  asks doesn't: the actor's turn is a call of its own.
- The host caps it (say 500 lines or 64 KB per call, then a count of the lines left out), so a
  chatty job can't grow the server's memory.
- When the call ends, however it ends (`Ok`, `Err`, a crash, or cut off by its time limit), the
  lines come back with its answer: `Host.isolated!` returns `{ status, out, logs }`, with `logs`
  as JSON lines. `Plugin.isolated!` keeps its type. A new `Plugin.isolated_logged!` returns
  `{ result : Try(Str, Str), logs : List(Plugin.Line) }`. Host.roc changes, so the glue is
  regenerated (`just glue`).

That is about 50 lines of Rust and 15 of Roc. The host test: a call that logs, then one that
crashes, then one cut off by its limit, each returning its lines; and two calls interleaved on one
thread, each keeping only its own lines.

**packages/jobs.**

- A table of attempts, `rocx_job_attempts`: `job_id`, `attempt`, `started_at`, `finished_at`,
  `outcome` (done, failed, timed out, crashed), `error`, `logs` (JSON lines) and `dropped`. It has a
  migration for Postgres and one for SQLite. Turso runs SQLite's.
- `JobWorker.attempt!` calls `isolated_logged!`. `finish!` writes the attempt's row beside the
  job's own update, after the attempt and outside the job's transactions, so a failed attempt's
  lines are kept.
- The sweep that deletes finished jobs (`JobSweeper`) deletes their attempts too. A retried job's
  earlier runs stay, and its new attempts are numbered on from them.
- `Job.attempts!(id)` reads them, for the page.

**packages/admin.** The job drawer gets an "Attempts" section. It lists each attempt, newest
first, with its outcome, when it ran and for how long, its error, and its lines: time since the
attempt began, level in colour, message, and fields folded away. The last error stays at the top,
where it is now.

**Cost.** About half a day for the platform part, and a day for the package and the page. Every
job is covered without changing how it's written.

### Side by side

| | Option 1: the package alone | Option 2: the host collects |
|---|---|---|
| Lines kept | only those written with `job.log!` | every line in the attempt: the app's, other packages', the host's |
| Changes to jobs | they opt in (`define_logged`) | none |
| Platform change | none | `Context` collects; `Host.isolated!` answers with the lines |
| Kept on a crash or timeout | yes (Kv) | yes (the host hands them back) |
| History of attempts | yes (the table) | yes (the table) |
| Cost | about a day | about a day and a half |

**Recommended: 2.** It's the only option that shows what the job did when a line came from code
the job's author didn't write. It also meets the rule for what goes in the platform (D-025: a
platform module stays only if it needs the host or the transpiler). No Roc code can see a line once
`Host.log!` has it, and the change is small and general.

**Open questions.**

1. **Live lines.** Show the lines while an attempt runs (each published on `rocx:jobs:<id>`, the
   drawer listening), or only once it ends? Recommended: once it ends, first; live lines later.
2. **Caps.** 500 lines or 64 KB per attempt? Keep the first lines and the last ones, since a
   failure is usually at the end? Recommended: the first 100 and the last 400, with a count of the
   lines between.
3. **Levels.** Keep debug lines too? stderr writes every level today.
4. **One isolated call.** Should `isolated_logged!` become the only `isolated!`, with one answer
   type for every plugin?
5. **Keeping failed jobs.** Settled since (2026-11-26): failed and canceled jobs are swept 30 days
   after they finished (`keep_failed_ms`), and their attempts would go with them.

**Related.**

- otel's traces proposal (packages/otel/PROPOSALS.md, "Traces") wants a per-call slot in the host:
  the same `Context` this extends.
- The same collection could hand a crashed request's last lines to an error report
  (packages/posthog).
- A smaller step on its own: the host could add `job` and `kind` fields to every stderr line
  written in a job's call, so a log collector can filter one job's lines. There's no storage and no
  page.
