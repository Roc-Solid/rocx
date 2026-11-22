import forms.Form
import forms.Value
import forms.Date
import Plate

## The app's forms, each written once with packages/forms. The endpoint a form posts to reads what
## was posted with it, into a typed record, or refuses it (422) with each field's issues; the pages
## check what is typed with the very same rules as it is typed (`LiveForm`).
PlateForm := [].{

	## A meal, as a form posts it (`lunch`).
	meal : Str -> Form(Plate.Meal)
	meal = |name| Form.choice(name, Plate.meals.map(|each| (Plate.meal_id(each), each)))

	## How much of a food was eaten, at which meal, on which day: `amount` of the portion `unit`
	## (its place among the food's portions, or `g` for grams). The food's page posts it.
	amount : Form({ count : Dec, unit : Str, meal : Plate.Meal, day : Date })
	amount = {
		count: Form.dec("amount", [Min(0.01), Max(10000.0)]),
		unit: Form.text("unit", [Trim, Required, MaxLength(4)]),
		meal: PlateForm.meal("meal"),
		day: Form.date("day", [Min("2000-01-01"), Max("2100-12-31")]),
	}.Form

	## A food of your own, as its packet says it: what `per` grams of it have (100, or a serving's
	## weight), and maybe a portion and a barcode.
	food : Form({ name : Str, brand : Str, per : Dec, kcal : Dec, protein : Dec, carbs : Dec, fat : Dec, fiber : Try(Dec, [Missing]), sugars : Try(Dec, [Missing]), sat_fat : Try(Dec, [Missing]), sodium : Try(Dec, [Missing]), serving : Str, serving_grams : Try(Dec, [Missing]), barcode : Str })
	food =
		{
			name: Form.text("name", [Trim, CollapseSpaces, Required, MaxLength(120)]),
			brand: Form.text("brand", [Trim, CollapseSpaces, MaxLength(80)]),
			per: Form.dec("per", [Min(1.0), Max(2000.0)]),
			kcal: Form.dec("kcal", [Min(0.0), Max(9000.0)]),
			protein: Form.dec("protein", [Min(0.0), Max(2000.0)]),
			carbs: Form.dec("carbs", [Min(0.0), Max(2000.0)]),
			fat: Form.dec("fat", [Min(0.0), Max(2000.0)]),
			fiber: Form.optional("fiber", Value.dec([Min(0.0), Max(2000.0)])),
			sugars: Form.optional("sugars", Value.dec([Min(0.0), Max(2000.0)])),
			sat_fat: Form.optional("sat_fat", Value.dec([Min(0.0), Max(2000.0)])),
			sodium: Form.optional("sodium", Value.dec([Min(0.0), Max(100000.0)])),
			serving: Form.text("serving", [Trim, CollapseSpaces, MaxLength(60)]),
			serving_grams: Form.optional("serving_grams", Value.dec([Min(0.1), Max(5000.0)])),
			barcode: Form.text("barcode", [Trim, Matches("^([0-9]{8,14})?$")]),
		}.Form
			.check_at("fat", |it| it.protein + it.carbs + it.fat <= it.per, Custom("too-much", "Protein, carbohydrate and fat weigh more than the amount they're for"))
			.check_at("serving_grams", |it| it.serving.is_empty() or it.serving_grams.is_ok(), Custom("serving-weight", "Say what the serving weighs"))

	## A barcode, as printed under its lines: 8 to 14 digits (EAN-8, UPC-A, EAN-13, GTIN-14).
	barcode : Form(Str)
	barcode = Form.text("barcode", [Trim, Required, Matches("^[0-9]{8,14}$")]).message("A barcode is 8 to 14 digits")

	## A new recipe: its name and how many servings it makes.
	recipe : Form({ name : Str, servings : I64 })
	recipe = {
		name: Form.text("name", [Trim, CollapseSpaces, Required, MaxLength(120)]),
		servings: Form.int("servings", [Min(1), Max(100)]),
	}.Form

	## A recipe as its page edits it.
	recipe_edit : Form({ name : Str, servings : I64, notes : Str })
	recipe_edit = {
		name: Form.text("name", [Trim, CollapseSpaces, Required, MaxLength(120)]),
		servings: Form.int("servings", [Min(1), Max(100)]),
		notes: Form.text("notes", [Trim, MaxLength(4000)]),
	}.Form

	## An ingredient added to a recipe: the food, and how many grams of it.
	ingredient : Form({ food : Str, grams : Dec })
	ingredient = {
		food: Form.text("food", [Trim, Required, Matches("^[0-9]+$")]),
		grams: Form.dec("grams", [Min(0.1), Max(20000.0)]),
	}.Form

	## Who the targets are for.
	profile : Form(Plate.Profile)
	profile = {
		sex: Form.choice("sex", Plate.sexes.map(|each| (each.id, each.id))),
		birth_year: Form.int("birth_year", [Min(1900), Max(2020)]),
		height_cm: Form.dec("height_cm", [Min(100.0), Max(250.0)]),
		weight_kg: Form.dec("weight_kg", [Min(25.0), Max(400.0)]),
		activity: Form.choice("activity", Plate.activities.map(|each| (each.id, each.id))),
		goal: Form.choice("goal", Plate.goals.map(|each| (each.id, each.id))),
		kcal_target: Form.optional("kcal_target", Value.dec([Min(1000.0), Max(6000.0)])).map(|target| target ?? 0.0),
		timezone: Form.text("timezone", [Trim, Required, MaxLength(64)]),
	}.Form

	## A weight, on a day.
	weight : Form({ day : Date, kg : Dec })
	weight = {
		day: Form.date("day", [Min("2000-01-01"), Max("2100-12-31")]),
		kg: Form.dec("kg", [Min(25.0), Max(400.0)]),
	}.Form

	## The password, when the diary has one.
	password : Form(Str)
	password = Form.text("password", [Required, Secret, MaxLength(200)])
}

expect PlateForm.amount.parse_body("amount=1.5&unit=0&meal=lunch&day=2026-11-22").map_ok(|it| (it.count, it.unit, it.meal, Date.to_str(it.day))) == Ok((1.5, "0", Lunch, "2026-11-22"))
expect PlateForm.amount.parse_body("amount=0&unit=g&meal=lunch&day=2026-11-22").map_err(|issues| issues.map(|issue| issue.field)) == Err(["amount"])
expect PlateForm.amount.parse_body("amount=2&unit=g&meal=brunch&day=2026-13-01").map_err(|issues| issues.map(|issue| issue.field)) == Err(["meal", "day"])

oat_bar : Str
oat_bar = "name=Oat+bar&brand=Acme+Mills&per=40&kcal=180&protein=4&carbs=24&fat=7&fiber=3&sugars=&sat_fat=&sodium=&serving=1+bar&serving_grams=40&barcode=0012345678905"

expect PlateForm.food.parse_body(oat_bar).map_ok(|food| (food.per, food.fiber, food.sugars, food.serving_grams, food.barcode)) == Ok((40.0, Ok(3.0), Err(Missing), Ok(40.0), "0012345678905"))
expect PlateForm.food.parse_body(oat_bar.replace_each("fat=7", "fat=70")).map_err(|issues| issues.map(|issue| issue.field)) == Err(["fat"])
expect PlateForm.food.parse_body(oat_bar.replace_each("serving_grams=40", "serving_grams=")).map_err(|issues| issues.map(|issue| issue.field)) == Err(["serving_grams"])
expect PlateForm.food.parse_body(oat_bar.replace_each("barcode=0012345678905", "barcode=12ab")).map_err(|issues| issues.map(|issue| issue.field)) == Err(["barcode"])
expect PlateForm.barcode.parse_body("barcode=+5000159484695+") == Ok("5000159484695")
expect PlateForm.barcode.parse_body("barcode=123").map_err(|issues| issues.map(|issue| issue.message)) == Err(["A barcode is 8 to 14 digits"])
expect PlateForm.profile.parse_body("sex=female&birth_year=1990&height_cm=165&weight_kg=62&activity=light&goal=keep&kcal_target=&timezone=Europe%2FBerlin").map_ok(|profile| (profile.kcal_target, profile.timezone)) == Ok((0.0, "Europe/Berlin"))
expect PlateForm.recipe.parse_body("name=Overnight+oats&servings=2") == Ok({ name: "Overnight oats", servings: 2 })
expect PlateForm.ingredient.parse_body("food=12&grams=40").map_ok(|it| it.grams) == Ok(40.0)
