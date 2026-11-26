import pf.Server
import pf.Endpoint
import ../../../../Plate
import ../../../../PlateForm
import ../../../../Store
import ../../../../Generated/Paths

## GET /api/recipes, for JSON: every recipe, by name, with what a serving has.
get! : { request : Server.Request, params : {}, context : {} } => Try(List(Plate.Card), Endpoint.Refusal)
get! = |_| Store.recipes!({}).map_err!(Store.refusal!)

## What POST /api/recipes is sent: a name and servings, read and checked by `PlateForm.recipe`
## (D-093).
post_body = PlateForm.recipe

## POST /api/recipes, from the new recipe form: a recipe of no ingredients yet, and on to it.
post! : { request : Server.Request, params : {}, context : {}, body : PlateForm.Recipe } => Try({}, Endpoint.Refusal)
post! = |{ body, .. }| {
	id = Store.add_recipe!(body).map_err!(Store.refusal!)?
	Err(Answer(Server.redirect(Paths.recipes_id({ id: id }))))
}
