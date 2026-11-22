import pf.Server
import pf.Endpoint
import forms.Issues
import ../../../../PlateForm
import ../../../../Store

## POST /recipes/:id/ingredients: grams of a food added to the recipe, which its food then follows
## (what 100 g of the mix has, and a serving's weight). Each food a search on the recipe's page
## finds is a form that posts here: without JavaScript, back to the page (303), the search still
## in its address; with it, sent with fetch, and the recipe read again.
post! : { request : Server.Request, params : { id : Str }, context : {}, body : { food : Str, grams : Str } } => Try({}, Endpoint.Refusal)
post! = |{ request, params, .. }|
	match PlateForm.ingredient.parse_body(Server.text_of(request)) {
		Ok(ingredient) => Store.add_ingredient!(params.id, ingredient).map_err(Store.refusal)
		Err(issues) => Err(Issues.refusal(issues))
	}
