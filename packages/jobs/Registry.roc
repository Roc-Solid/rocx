import pf.Plugin

## What the jobs plugin runs, kept in the server's memory when it starts (`Job.plugin`'s start):
## the kinds of job (with their attempts and time limits), the schedules, and how long finished jobs
## are kept, for `Job`, `Cron`, the workers and the jobs page, which can't see the plugin's options.
Registry := [].{

	## A kind of job the plugin runs: its name, how many times it is tried, and its time limit in
	## milliseconds (0: none).
	Kind : { name : Str, attempts : U64, timeout_ms : U64 }

	## A schedule the plugin runs (`Cron.every`).
	Schedule : { name : Str, schedule : Str, job : Str, input : Str }

	## How long finished jobs are kept, in milliseconds after they finished (the plugin's options).
	Keeps : { keep_done_ms : U64, keep_failed_ms : U64 }

	keep! : List(Kind), List(Schedule), Keeps => {}
	keep! = |kinds, schedules, keeps| {
		Plugin.keep!("jobs:kinds", Json.to_str(kinds))
		Plugin.keep!("jobs:schedules", Json.to_str(schedules))
		Plugin.keep!("jobs:keeps", Json.to_str(keeps))
	}

	## Keeps a kind another plugin brought (`Job.adopt!`) beside the plugin's own, once.
	adopt! : Kind => {}
	adopt! = |kind| {
		kinds = Registry.kinds!({})
		if !kinds.any(|each| each.name == kind.name) {
			Plugin.keep!("jobs:kinds", Json.to_str(kinds.append(kind)))
		}
	}

	## Whether the jobs plugin started: what it keeps is there.
	installed! : {} => Bool
	installed! = |{}| Plugin.kept!("jobs:kinds").is_ok()

	kinds! : {} => List(Kind)
	kinds! = |{}|
		match Plugin.kept!("jobs:kinds") {
			Ok(kept) =>
				match Json.parse(kept) {
					Ok(kinds) => kinds
					Err(InvalidJson(_)) => []
				}
			Err(_) => []
		}

	schedules! : {} => List(Schedule)
	schedules! = |{}|
		match Plugin.kept!("jobs:schedules") {
			Ok(kept) =>
				match Json.parse(kept) {
					Ok(schedules) => schedules
					Err(InvalidJson(_)) => []
				}
			Err(_) => []
		}

	## How long finished jobs are kept: as the plugin has it, or its defaults (a week done, 30 days
	## failed or canceled) without it.
	keeps! : {} => Keeps
	keeps! = |{}| {
		defaults = { keep_done_ms: 604_800_000, keep_failed_ms: 2_592_000_000 }
		match Plugin.kept!("jobs:keeps") {
			Ok(kept) =>
				match Json.parse(kept) {
					Ok(keeps) => keeps
					Err(InvalidJson(_)) => defaults
				}
			Err(_) => defaults
		}
	}

	## How many times a job of the kind called `name` is tried: as the plugin has it, or five for a
	## kind it doesn't.
	attempts! : Str => U64
	attempts! = |name|
		match Registry.kinds!({}).find_first(|kind| kind.name == name) {
			Ok(kind) => kind.attempts
			Err(_) => 5
		}
}
