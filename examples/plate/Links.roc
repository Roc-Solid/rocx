import Generated/Paths
import Query

## Where the pages link to, with the day and meal an entry is for carried along, so a food found
## from lunch's "Add" is logged to lunch on that day.
Links := [].{

	## A day of the diary: `/` for today, `/days/2026-11-21` for another.
	diary : Str, Str -> Str
	diary = |day, today| if (day.is_empty() or day == today) Paths.root else Paths.days_day({ day: day })

	## The add page, for a day and a meal (and a search, if there is one).
	add : { day : Str, meal : Str, query : Str } -> Str
	add = |{ day, meal, query }| Query.link(Paths.add, Query.of([("day", day), ("meal", meal), ("q", query)]))

	## A food's page, with the day and meal its form starts at.
	food : Str, { day : Str, meal : Str } -> Str
	food = |id, { day, meal }| Query.link(Paths.foods_id({ id: id }), Query.of([("day", day), ("meal", meal)]))
}
