import pf.Server

## The planner demo's week (`Demos/Planner.rocx`, `routes/api/planner`): each reader's own, kept in
## a cookie of theirs, so nobody moves another's plans. A day holds three plans at most, and the
## dentist doesn't move: the refusals the demo shows.
Plans := [].{
	Plan : { id : Str, title : Str, day : Str }

	## The plans a week starts with.
	start : List(Plan)
	start = [
		{ id: "standup", title: "Team stand-up", day: "mon" },
		{ id: "notes", title: "Release notes", day: "mon" },
		{ id: "review", title: "Review the parser", day: "tue" },
		{ id: "dentist", title: "Dentist, 9:30", day: "wed" },
		{ id: "demo", title: "Demo day prep", day: "thu" },
		{ id: "groceries", title: "Groceries", day: "thu" },
	]

	## The days, and what the page calls each.
	days : List((Str, Str))
	days = [("mon", "Monday"), ("tue", "Tuesday"), ("wed", "Wednesday"), ("thu", "Thursday")]

	## The reader's week: the day their cookie keeps for each plan (`standup:tue,…`), or the start's.
	of : Server.Request -> List(Plan)
	of = |request| {
		saved =
			match Server.cookie(request, "planner") {
				Ok(cookie) => cookie.split_on(",").keep_oks(|pair| pair.split_first(":"))
				Err(Missing) => []
			}
		Plans.start.map(
			|plan|
				match saved.find_first(|{ before, .. }| before == plan.id) {
					Ok({ after, .. }) if Plans.days.any(|(id, _)| id == after) => { ..plan, day: after }
					_ => plan
				},
		)
	}

	## The week as its cookie keeps it: `standup:tue,notes:mon,…`.
	kept : List(Plan) -> Str
	kept = |plans| Str.join_with(plans.map(|plan| "${plan.id}:${plan.day}"), ",")

	## A plan moved to another day, as the server takes it; or why not.
	moved : List(Plan), { plan : Str, day : Str } -> Try(List(Plan), Str)
	moved = |plans, { plan, day }|
		match Plans.days.find_first(|(id, _)| id == day) {
			Err(_) => Err("There is no day called ${day}.")
			Ok((_, name)) =>
				if plan == "dentist" {
					Err("The dentist won't move: that slot was hard enough to get.")
				} else if plans.count_if(|each| each.day == day and each.id != plan) >= 3 {
					Err("${name} is full: three plans a day at most.")
				} else {
					Ok(plans.map(|each| if (each.id == plan) { ..each, day } else each))
				}
		}
}

## The week after a move, as its cookie keeps it, or why there is none: for the expects.
after : List(Plans.Plan), { plan : Str, day : Str } -> Str
after = |plans, move|
	match Plans.moved(plans, move) {
		Ok(moved) => Plans.kept(moved)
		Err(why) => why
	}

expect Plans.kept(Plans.start) == "standup:mon,notes:mon,review:tue,dentist:wed,demo:thu,groceries:thu"
expect after(Plans.start, { plan: "notes", day: "thu" }) == "standup:mon,notes:thu,review:tue,dentist:wed,demo:thu,groceries:thu"
expect after(Plans.start, { plan: "dentist", day: "mon" }) == "The dentist won't move: that slot was hard enough to get."
expect after(Plans.start, { plan: "standup", day: "fri" }) == "There is no day called fri."
expect after(Plans.start.map(|plan| if (plan.id == "notes") { ..plan, day: "thu" } else plan), { plan: "standup", day: "thu" }) == "Thursday is full: three plans a day at most."
