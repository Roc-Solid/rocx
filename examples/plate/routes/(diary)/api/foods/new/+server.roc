import pf.Server
import pf.Endpoint
import forms.Issues
import ../../../../../Links
import ../../../../../PlateForm
import ../../../../../Query
import ../../../../../Store

## What POST /api/foods/new is sent: a food as its packet says it, read and checked by
## `PlateForm.food` (D-093).
post_body = PlateForm.food

## POST /api/foods/new, from the food form: a food of your own, as its packet says it, kept as what
## 100 g of it has; then on to its page, to log it to the day and meal the form was opened for
## (its `then_day` and `then_meal` fields). A barcode another food has already is refused.
post! : { request : Server.Request, params : {}, context : {}, body : PlateForm.Food } => Try(Server.Response, Endpoint.Refusal)
post! = |{ request, body, .. }| {
	food = body
	taken = if (food.barcode.is_empty()) Bool.False else Store.by_barcode!(food.barcode).is_ok()
	if taken {
		Err(Issues.refusal([{ field: "barcode", code: Custom("taken", "Another food has this barcode"), message: "Another food has this barcode" }]))
	} else {
		per = |amount| amount * 100.0 / food.per
		extras =
			[("Fibre", food.fiber, "g"), ("Sugars", food.sugars, "g"), ("Saturated fat", food.sat_fat, "g"), ("Sodium", food.sodium, "mg")]
				.keep_oks(|(name, amount, unit)| amount.map_ok(|known| { name, amount: per(known), unit }).map_err(|_| Unknown))
		portion =
			match food.serving_grams {
				Ok(grams) => Ok({ label: if (food.serving.is_empty()) "1 serving" else food.serving, grams })
				Err(Missing) => Err(Missing)
			}
		id =
			Store.add_food!({
				source: "mine",
				name: food.name,
				brand: food.brand,
				barcode: food.barcode,
				per100: { kcal: per(food.kcal), protein: per(food.protein), carbs: per(food.carbs), fat: per(food.fat) },
				extras,
				portion,
			})
				.map_err!(Store.refusal!)?
		# Where to go after: the form's own fields, beside the food's.
		posted = Server.text_of(request)
		Ok(Server.redirect(Links.food(id, { day: Query.value(posted, "then_day"), meal: Query.value(posted, "then_meal") })))
	}
}
