import pf.Server
import pf.Endpoint
import ../../Plate
import ../../Query
import ../../Store

## GET /add, for JSON: a search of the foods (`?q=oats`), for a day and a meal (`?day=…&meal=…`,
## today and the meal the time suggests when they're left out): the best 30 matches; before a
## search, the 12 foods logged most lately.
get! : { request : Server.Request, params : {}, context : {} } => Try(Plate.Search, Endpoint.Refusal)
get! = |{ request, .. }| {
	query = Query.value(request.query, "q").trim()
	today = Store.today!({}).map_err(Store.refusal)?
	asked_day = Query.value(request.query, "day")
	asked_meal = Query.value(request.query, "meal")
	meal = if (asked_meal.is_empty()) Store.meal_now!({}).map_err(Store.refusal)? else Plate.meal_id(Plate.meal_of(asked_meal))
	hits = Store.search!(query, { limit: 30, except: "" }).map_err(Store.refusal)?
	recent = if (query.is_empty()) Store.recent!(12).map_err(Store.refusal)? else []
	Ok({ query, day: if (asked_day.is_empty()) today else asked_day, today, meal, hits, recent })
}
