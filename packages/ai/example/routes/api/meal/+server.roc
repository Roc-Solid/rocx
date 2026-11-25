import pf.Server
import pf.Endpoint
import ai.Ai

## POST /api/meal: a meal described in words, read into a record (`Ai.extract!`): each food, about
## how much of it, and its calories, as the model reckons them.
post! : { request : Server.Request, params : {}, context : c, body : { text : Str } } => Try({ items : List({ food : Str, grams : U32, kcal : U32 }), total_kcal : U32 }, Endpoint.Refusal)
post! = |{ body, .. }|
	match Ai.extract!({ system: "Read the meal the user describes into its foods, one item per food (two eggs are one item): its name, about how many grams of it, and its calories. Reckon a usual portion when no amount is given. total_kcal is the items' calories added up.", prompt: body.text, effort: Low }, Ai.schema([])) {
		Ok(meal) => Ok(meal)
		Err(problem) => Err(Status(502, Ai.explain(problem)))
	}
