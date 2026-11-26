import pf.Server
import pf.Endpoint
import forms.Issues
import ../../Plate
import ../../PlateForm
import ../../Store
import ../../Generated/Paths

## GET /recipes, for JSON: every recipe, by name, with what a serving has.
get! : { request : Server.Request, params : {}, context : {} } => Try(List(Plate.Card), Endpoint.Refusal)
get! = |_| Store.recipes!({}).map_err!(Store.refusal!)

## POST /recipes, from the new recipe form: a recipe of no ingredients yet, and on to it.
post! : { request : Server.Request, params : {}, context : {}, body : { name : Str, servings : Str } } => Try({}, Endpoint.Refusal)
post! = |{ request, .. }|
	match PlateForm.recipe.parse_body(Server.text_of(request)) {
		Ok(recipe) => {
			id = Store.add_recipe!(recipe).map_err!(Store.refusal!)?
			Err(Answer(Server.redirect(Paths.recipes_id({ id: id }))))
		}
		Err(issues) => Err(Issues.refusal(issues))
	}
