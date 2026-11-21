import Host

## What the app lists, kept in the server's memory when it starts: only `main.roc` sees `program`,
## so it keeps here, for `Job`, `Cron`, the workers and the jobs page, the kinds of job the app runs
## (with their attempts and time limits) and its schedules.
Registry := [].{

	## A kind of job the app lists: its name, how many times it is tried, and its time limit in
	## milliseconds (0: none).
	Kind : { name : Str, attempts : U64, timeout_ms : U64 }

	## A schedule the app lists (`Cron.every`).
	Schedule : { name : Str, schedule : Str, job : Str, input : Str }

	keep! : List(Kind), List(Schedule) => {}
	keep! = |kinds, schedules| {
		Host.store_set!("rocx:kinds", Json.to_str(kinds))
		Host.store_set!("rocx:schedules", Json.to_str(schedules))
	}

	kinds! : {} => List(Kind)
	kinds! = |{}|
		match Host.store_get!("rocx:kinds") {
			Ok(kept) =>
				match Json.parse(kept) {
					Ok(kinds) => kinds
					Err(InvalidJson(_)) => []
				}
			Err(_) => []
		}

	schedules! : {} => List(Schedule)
	schedules! = |{}|
		match Host.store_get!("rocx:schedules") {
			Ok(kept) =>
				match Json.parse(kept) {
					Ok(schedules) => schedules
					Err(InvalidJson(_)) => []
				}
			Err(_) => []
		}

	## How many times a job of the kind called `name` is tried: as the app lists it, or five for a
	## kind it doesn't.
	attempts! : Str => U64
	attempts! = |name|
		match Registry.kinds!({}).find_first(|kind| kind.name == name) {
			Ok(kind) => kind.attempts
			Err(_) => 5
		}
}
