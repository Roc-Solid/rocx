import pf.Server
import pf.Endpoint
import forms.Date
import forms.Issues
import ../../../Links
import ../../../Plate
import ../../../PlateForm
import ../../../Store

## GET /foods/:id, for JSON: the food (what 100 g has, its portions), today, and the meal the time
## of day suggests, which the page's form starts at unless its address says another.
get! : { request : Server.Request, params : { id : Str }, context : {} } => Try(Plate.Pick, Endpoint.Refusal)
get! = |{ params, .. }| {
	food = Store.food!(params.id).map_err(Store.refusal)?
	today = Store.today!({}).map_err(Store.refusal)?
	meal = Store.meal_now!({}).map_err(Store.refusal)?
	Ok({ food, today, meal })
}

## POST /foods/:id, from the food's page: an amount of it logged to a meal on a day, then on to
## that day of the diary; or the form's issues (422), shown under its fields. What the amount has
## is worked out from the food as it is now, and kept with the entry (`Store.log!`).
post! : { request : Server.Request, params : { id : Str }, context : {}, body : { amount : Str, unit : Str, meal : Str, day : Str } } => Try({}, Endpoint.Refusal)
post! = |{ request, params, .. }|
	match PlateForm.amount.parse_body(Server.text_of(request)) {
		Ok(amount) => {
			day = Date.to_str(amount.day)
			_ = Store.log!({ food: params.id, day, meal: amount.meal, count: amount.count, unit: amount.unit }).map_err(Store.refusal)?
			today = Store.today!({}).map_err(Store.refusal)?
			Err(Answer(Server.redirect(Links.diary(day, today))))
		}
		Err(issues) => Err(Issues.refusal(issues))
	}
