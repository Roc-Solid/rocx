import pf.Job

## The app's jobs: rocx build finds each (`Job.define`, at the top of this block) and lists it in
## `Generated/App`, so the server's workers run it.
Jobs := [].{

	## Says hello to a new member.
	welcome : Job.Kind({ member : Str })
	welcome = Job.define("welcome", |{ member }| if (member.is_empty()) Err("no one to welcome") else Ok({}))
}
