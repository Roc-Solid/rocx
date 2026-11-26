import pf.Server
import pf.Endpoint
import forms.Date
import ../../../../../Links
import ../../../../../Plate
import ../../../../../PlateForm
import ../../../../../Store

## GET /api/foods/:id, for JSON: the food (what 100 g has, its portions), today, and the meal the
## time of day suggests, which the page's form starts at unless its address says another.
get! : { request : Server.Request, params : { id : Str }, context : {} } => Try(Plate.Pick, Endpoint.Refusal)
get! = |{ params, .. }| {
	food = Store.food!(params.id).map_err!(Store.refusal!)?
	today = Store.today!({}).map_err!(Store.refusal!)?
	meal = Store.meal_now!({}).map_err!(Store.refusal!)?
	Ok({ food, today, meal })
}

## What POST /api/foods/:id is sent: an amount, a meal and a day, read and checked by
## `PlateForm.amount` (D-093).
post_body = PlateForm.amount

## POST /api/foods/:id, from the food's page: an amount of it logged to a meal on a day, then on to
## that day of the diary; or the form's issues (422), shown under its fields. What the amount has
## is worked out from the food as it is now, and kept with the entry (`Store.log!`).
post! : { request : Server.Request, params : { id : Str }, context : {}, body : PlateForm.Amount } => Try(Server.Response, Endpoint.Refusal)
post! = |{ params, body, .. }| {
	day = Date.to_str(body.day)
	_ = Store.log!({ food: params.id, day, meal: body.meal, count: body.count, unit: body.unit }).map_err!(Store.refusal!)?
	today = Store.today!({}).map_err!(Store.refusal!)?
	Ok(Server.redirect(Links.diary(day, today)))
}
