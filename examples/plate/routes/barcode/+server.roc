import pf.Server
import pf.Endpoint
import pf.Log
import forms.Issues
import ../../Links
import ../../OpenFoodFacts
import ../../PlateForm
import ../../Query
import ../../Store

## POST /barcode, from the barcode form: the food with that barcode, and on to its page. One the
## diary has already is found in the database; any other is asked of Open Food Facts once, and kept as
## a food (source `off`). One Open Food Facts doesn't know, or can't give the energy of, is refused
## under the field (422), and the page offers to make it yourself.
post! : { request : Server.Request, params : {}, context : {}, body : { barcode : Str } } => Try({}, Endpoint.Refusal)
post! = |{ request, .. }| {
	posted = Server.text_of(request)
	then = { day: Query.value(posted, "then_day"), meal: Query.value(posted, "then_meal") }
	match PlateForm.barcode.parse_body(posted) {
		Ok(code) =>
			match Store.by_barcode!(code) {
				Ok(id) => Err(Answer(Server.redirect(Links.food(id, then))))
				Err(NotFound) =>
					match OpenFoodFacts.lookup!(code) {
						Ok(product) => {
							id = Store.add_food!({ source: "off", name: product.name, brand: product.brand, barcode: code, per100: product.per100, extras: product.extras, portion: product.portion }).map_err!(Store.refusal!)?
							Log.info!("found on Open Food Facts", { barcode: code, name: product.name })
							Err(Answer(Server.redirect(Links.food(id, then))))
						}
						Err(NotFound) => refused("Open Food Facts doesn't know this barcode. You can make the food yourself.")
						Err(Unreadable(why)) => refused("${why}. You can make the food yourself.")
						Err(Unreachable(why)) => {
							Log.warn!("Open Food Facts couldn't be asked", { barcode: code, why })
							refused("Open Food Facts couldn't be asked just now (${why}). Try again, or make the food yourself.")
						}
					}
				Err(problem) => Err(Store.refusal!(problem))
			}
		Err(issues) => Err(Issues.refusal(issues))
	}
}

## The form refused, with why under the barcode.
refused : Str -> Try({}, Endpoint.Refusal)
refused = |why| Err(Issues.refusal([{ field: "barcode", code: Custom("unknown", why), message: why }]))
