import pf.Server
import pf.Endpoint
import forms.Issues
import ../../../Plate
import ../../../PlateForm
import ../../../Query
import ../../../Store

## GET /recipes/:id, for JSON: the recipe, its ingredients each with what its amount has, and the
## foods a search for another ingredient finds (`?q=`; the recipe itself left out).
get! : { request : Server.Request, params : { id : Str }, context : {} } => Try(Plate.Kitchen, Endpoint.Refusal)
get! = |{ request, params, .. }| {
	recipe = Store.recipe!(params.id).map_err(Store.refusal)?
	query = Query.value(request.query, "q").trim()
	hits = Store.search!(query, { limit: 12, except: recipe.food }).map_err(Store.refusal)?
	Ok({ recipe, query, hits })
}

## POST /recipes/:id, from the recipe's form: its name, servings and notes changed.
post! : { request : Server.Request, params : { id : Str }, context : {}, body : { name : Str, servings : Str, notes : Str } } => Try({}, Endpoint.Refusal)
post! = |{ request, params, .. }|
	match PlateForm.recipe_edit.parse_body(Server.text_of(request)) {
		Ok(recipe) => Store.save_recipe!(params.id, recipe).map_err(Store.refusal)
		Err(issues) => Err(Issues.refusal(issues))
	}
