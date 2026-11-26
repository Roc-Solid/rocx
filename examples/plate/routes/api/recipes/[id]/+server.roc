import pf.Server
import pf.Endpoint
import ../../../../Plate
import ../../../../PlateForm
import ../../../../Query
import ../../../../Store

## GET /api/recipes/:id, for JSON: the recipe, its ingredients each with what its amount has, and
## the foods a search for another ingredient finds (`?q=`; the recipe itself left out).
get! : { request : Server.Request, params : { id : Str }, context : {} } => Try(Plate.Kitchen, Endpoint.Refusal)
get! = |{ request, params, .. }| {
	recipe = Store.recipe!(params.id).map_err!(Store.refusal!)?
	query = Query.value(request.query, "q").trim()
	hits = Store.search!(query, { limit: 12, except: recipe.food }).map_err!(Store.refusal!)?
	Ok({ recipe, query, hits })
}

## What POST /api/recipes/:id is sent: the recipe's name, servings and notes, read and checked by
## `PlateForm.recipe_edit` (D-093).
post_body = PlateForm.recipe_edit

## POST /api/recipes/:id, from the recipe's form: its name, servings and notes changed.
post! : { request : Server.Request, params : { id : Str }, context : {}, body : PlateForm.RecipeEdit } => Try({}, Endpoint.Refusal)
post! = |{ params, body, .. }| Store.save_recipe!(params.id, body).map_err!(Store.refusal!)
