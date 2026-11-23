import jobs.Job

## The app's jobs: rocx build finds each (`Job.define`, at the top of this block) and lists it in
## `App.jobs`, which the app gives the jobs plugin, so its workers run it.
Jobs := [].{

	## Says hello to a new member.
	welcome : Job.Kind(_, { member : Str })
	welcome = Job.define("welcome", |_context, { member }| if (member.is_empty()) Err("no one to welcome") else Ok({}))
}
