## Jobs and cron for Roc Solid's server, as a plugin (`Job.plugin`): work queued in Postgres and run
## in the background by workers, each job in a call of its own and tried again if it fails (`Job`);
## jobs on a schedule (`Cron`); and the queue's table, `rocx_jobs`, as the plugin's migration. It
## names the server platform, so only an app on it names this package; the browser's half doesn't
## see it. `Calendar` is the dates cron's schedules are read in (UTC).
package [Calendar, Cron, Job] { pf: platform "../../server/platform/main.roc" }
