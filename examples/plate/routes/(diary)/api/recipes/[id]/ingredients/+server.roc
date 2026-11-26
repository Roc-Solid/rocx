import pf.Server
import pf.Endpoint
import ../../../../../../PlateForm
import ../../../../../../Store

## What POST /api/recipes/:id/ingredients is sent: a food and its grams, read and checked by
## `PlateForm.ingredient` (D-093).
post_body = PlateForm.ingredient

## POST /api/recipes/:id/ingredients: grams of a food added to the recipe, which its food then
## follows (what 100 g of the mix has, and a serving's weight). Each food a search on the recipe's
## page finds is a form that posts here: without JavaScript, back to the page (303), the search
## still in its address; with it, sent with fetch, and the recipe read again.
post! : { request : Server.Request, params : { id : Str }, context : {}, body : PlateForm.Ingredient } => Try({}, Endpoint.Refusal)
post! = |{ params, body, .. }| Store.add_ingredient!(params.id, body).map_err!(Store.refusal!)
