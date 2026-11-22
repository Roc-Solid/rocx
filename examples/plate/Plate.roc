import forms.Date
import charts.Format

## Acme Plate's rules: what a food and a diary entry are, what an amount of a food has, a day's
## totals against its target, the targets a profile asks for, and how numbers and days are said.
## Plain Roc on no platform, so the server and the browser run the same functions: the food page
## shows what an amount has as it is typed, and the server logs the very same numbers.
Plate := [].{

	## What 100 g of a food has, or what an entry had: energy in kcal, and protein, carbohydrate
	## and fat in grams.
	Nutrients : { kcal : Dec, protein : Dec, carbs : Dec, fat : Dec }

	## A nutrient that not every food's data gives (fibre, sugars, saturated fat, sodium): only
	## the ones a food's data has are listed, so "not known" never shows as 0.
	Extra : { name : Str, amount : Dec, unit : Str }

	## A measure of a food and what it weighs: "1 cup, chopped", 76 g.
	Portion : { label : Str, grams : Dec }

	## A food, as its page shows it. `source` is where it came from: `usda` (FoodData Central),
	## `off` (Open Food Facts, by its barcode), `mine` (made in the app) or `recipe` (one of your
	## recipes, whose page is `recipe`'s); `source_id` is its id there (an FDC id, a barcode).
	Food : {
		id : Str,
		name : Str,
		brand : Str,
		group : Str,
		source : Str,
		source_id : Str,
		per100 : Plate.Nutrients,
		extras : List(Plate.Extra),
		portions : List(Plate.Portion),
		recipe : Str,
	}

	## A food in a search's results: its energy per 100 g, and its first portion ("" when it has
	## none), to say what a usual amount is.
	Hit : { id : Str, name : Str, brand : Str, source : Str, kcal : Dec, portion : Str }

	## A meal of the day.
	Meal : [Breakfast, Lunch, Dinner, Snacks]

	## An entry in the diary: what was eaten, how much (`amount`, as it was said, and `grams`), and
	## what that had, worked out when it was logged. Kept as it was, so a food changed later
	## doesn't change what a past day says.
	Entry : {
		id : Str,
		meal : Str,
		food : Str,
		name : Str,
		amount : Str,
		grams : Dec,
		kcal : Dec,
		protein : Dec,
		carbs : Dec,
		fat : Dec,
	}

	## A day of the diary (`GET /days/:day`): its entries, the days either side of it, today (in
	## the profile's time zone), and the target.
	Day : { day : Str, today : Str, previous : Str, next : Str, entries : List(Plate.Entry), target : Plate.Nutrients }

	## Who the targets are for: what the energy a day needs is worked out from. `kcal_target` is
	## one you set yourself, or 0 to have it worked out.
	Profile : {
		sex : Str,
		birth_year : I64,
		height_cm : Dec,
		weight_kg : Dec,
		activity : Str,
		goal : Str,
		kcal_target : Dec,
		timezone : Str,
	}

	## A day's totals, for the trends.
	Totals : { day : Str, kcal : Dec, protein : Dec, carbs : Dec, fat : Dec }

	## A weight, on a day.
	Weight : { day : Str, kg : Dec }

	## The add page (`GET /add`): what was searched for, where it goes (a day and a meal), and
	## what was found; before a search, the foods logged lately.
	Search : { query : Str, day : Str, today : Str, meal : Str, hits : List(Plate.Hit), recent : List(Plate.Hit) }

	## A food's page (`GET /foods/:id`): the food, today, and the meal the time of day suggests.
	Pick : { food : Plate.Food, today : Str, meal : Str }

	## What goes into a recipe: a food, how many grams, and what that has.
	Ingredient : { id : Str, food : Str, name : Str, grams : Dec, nutrients : Plate.Nutrients }

	## A recipe: its ingredients, how many servings they make, and the food that logs a serving.
	Recipe : { id : Str, food : Str, name : Str, servings : I64, notes : Str, ingredients : List(Plate.Ingredient) }

	## A recipe's page (`GET /recipes/:id`): the recipe, and the foods a search for an ingredient
	## found (`?q=`).
	Kitchen : { recipe : Plate.Recipe, query : Str, hits : List(Plate.Hit) }

	## A recipe in the list: what a serving has.
	Card : { id : Str, food : Str, name : Str, servings : I64, kcal : Dec, ingredients : I64 }

	## The goals page (`GET /goals`): the profile, this year (for its age), and whether the diary
	## has a password (so it has a way to sign out).
	Goals : { profile : Plate.Profile, year : I64, locked : Bool }

	## The trends page (`GET /trends?days=30`): each of the last `range` days' totals, the
	## targets, and the weights in that time.
	Trends : { range : U64, today : Str, totals : List(Plate.Totals), target : Plate.Nutrients, weights : List(Plate.Weight) }

	## How far back the trends look, in days.
	ranges : List(U64)
	ranges = [7, 30, 90]

	## The range a query asks for (`days=30`): one of `ranges`, or a week.
	range_of : Str -> U64
	range_of = |asked|
		match U64.from_str(asked) {
			Ok(days) if Plate.ranges.contains(days) => days
			_ => 7
		}

	## The days that have something logged.
	logged : List(Plate.Totals) -> List(Plate.Totals)
	logged = |days| days.keep_if(|day| day.kcal > 0.0)

	## What a day with something logged had, on average; nothing when none has.
	average : List(Plate.Totals) -> Plate.Nutrients
	average = |days| {
		counted = Plate.logged(days)
		if counted.is_empty() {
			Plate.none
		} else {
			all = Plate.sum(counted.map(|day| { kcal: day.kcal, protein: day.protein, carbs: day.carbs, fat: day.fat }))
			Plate.scaled(all, 100.0 / counted.len().to_dec())
		}
	}

	## The trends' bars of energy: a day each for a week ("Mon") or a month (the day of the month,
	## "22"); for longer, a week each ("Nov 16", its first day), the average of its days that have
	## something logged.
	bars : List(Plate.Totals), U64 -> List({ label : Str, value : Dec })
	bars = |days, range|
		if range <= 7 {
			days.map(|day| { label: Date.from_str(day.day).map_ok(weekday) ?? day.day, value: day.kcal })
		} else if range <= 31 {
			days.map(|day| { label: Date.from_str(day.day).map_ok(|date| date.day().to_str()) ?? day.day, value: day.kcal })
		} else {
			weeks = days.fold_with_index(
				[],
				|found, day, index|
					if index % 7 == 0 {
						found.append([day])
					} else {
						match found.last() {
							Ok(week) => found.drop_last(1).append(week.append(day))
							Err(ListWasEmpty) => [[day]]
						}
					},
			)
			weeks.map(|week| { label: week.first().map_ok(|day| Plate.short_day(day.day)) ?? "", value: Plate.average(week).kcal })
		}

	## What one of `servings` servings of a whole has.
	per_serving : Plate.Nutrients, I64 -> Plate.Nutrients
	per_serving = |all, servings| if (servings <= 0) all else Plate.scaled(all, 100.0 / servings.to_dec())

	## What the recipe's ingredients have, together.
	in_recipe : Plate.Recipe -> Plate.Nutrients
	in_recipe = |recipe| Plate.sum(recipe.ingredients.map(|each| each.nutrients))

	## What the recipe's ingredients weigh, together.
	weight_of : Plate.Recipe -> Dec
	weight_of = |recipe| recipe.ingredients.fold(0.0, |so_far, each| so_far + each.grams)

	meals : List(Plate.Meal)
	meals = [Breakfast, Lunch, Dinner, Snacks]

	## A meal as its URL and the database say it: `breakfast`.
	meal_id : Plate.Meal -> Str
	meal_id = |meal|
		match meal {
			Breakfast => "breakfast"
			Lunch => "lunch"
			Dinner => "dinner"
			Snacks => "snacks"
		}

	## A meal as the page says it: "Breakfast".
	meal_name : Plate.Meal -> Str
	meal_name = |meal|
		match meal {
			Breakfast => "Breakfast"
			Lunch => "Lunch"
			Dinner => "Dinner"
			Snacks => "Snacks"
		}

	## The meal `id` names; anything else is a snack.
	meal_of : Str -> Plate.Meal
	meal_of = |id| Plate.meals.find_first(|meal| Plate.meal_id(meal) == id) ?? Snacks

	## The meal a time of day suggests (hours 0 to 23): breakfast until 11, lunch until 16, dinner
	## until 22, and a snack after.
	meal_at : U64 -> Plate.Meal
	meal_at = |hour|
		if hour >= 4 and hour < 11 {
			Breakfast
		} else if hour >= 11 and hour < 16 {
			Lunch
		} else if hour >= 16 and hour < 22 {
			Dinner
		} else {
			Snacks
		}

	none : Plate.Nutrients
	none = { kcal: 0.0, protein: 0.0, carbs: 0.0, fat: 0.0 }

	## What `grams` of a food has, from what 100 g of it has.
	scaled : Plate.Nutrients, Dec -> Plate.Nutrients
	scaled = |per100, grams| {
		factor = grams / 100.0
		{ kcal: per100.kcal * factor, protein: per100.protein * factor, carbs: per100.carbs * factor, fat: per100.fat * factor }
	}

	## Two amounts' nutrients together.
	plus : Plate.Nutrients, Plate.Nutrients -> Plate.Nutrients
	plus = |a, b| { kcal: a.kcal + b.kcal, protein: a.protein + b.protein, carbs: a.carbs + b.carbs, fat: a.fat + b.fat }

	## All of them together.
	sum : List(Plate.Nutrients) -> Plate.Nutrients
	sum = |all| all.fold(Plate.none, Plate.plus)

	## What an entry had.
	of_entry : Plate.Entry -> Plate.Nutrients
	of_entry = |entry| { kcal: entry.kcal, protein: entry.protein, carbs: entry.carbs, fat: entry.fat }

	## What the entries had, together.
	total : List(Plate.Entry) -> Plate.Nutrients
	total = |entries| Plate.sum(entries.map(Plate.of_entry))

	## A meal's entries, in the order they were logged.
	in_meal : List(Plate.Entry), Plate.Meal -> List(Plate.Entry)
	in_meal = |entries, meal| entries.keep_if(|entry| entry.meal == Plate.meal_id(meal))

	## What 100 g of a mix has, from its parts (each a food's per-100 g and its grams): a recipe.
	## A mix of nothing has nothing.
	mixed : List({ per100 : Plate.Nutrients, grams : Dec }) -> Plate.Nutrients
	mixed = |parts| {
		weight = parts.fold(0.0, |grams, part| grams + part.grams)
		if weight <= 0.0 {
			Plate.none
		} else {
			Plate.scaled(Plate.sum(parts.map(|part| Plate.scaled(part.per100, part.grams))), 10000.0 / weight)
		}
	}

	# ---- How much ----

	## How many grams an amount is: `count` of a portion, or grams when `unit` is `g` (or a portion
	## the food doesn't have).
	grams_of : Dec, Str, List(Plate.Portion) -> Dec
	grams_of = |count, unit, portions|
		match Plate.portion_at(portions, unit) {
			Ok(portion) => count * portion.grams
			Err(Grams) => count
		}

	## The portion a unit names: its place among the food's portions (`0` for the first); `Grams`
	## for `g`, or anything else.
	portion_at : List(Plate.Portion), Str -> Try(Plate.Portion, [Grams])
	portion_at = |portions, unit|
		match U64.from_str(unit) {
			Ok(index) => portions.get(index).map_err(|_| Grams)
			Err(_) => Err(Grams)
		}

	## An amount as the diary says it: "150 g", "1 cup, chopped", "2 × 1 slice".
	amount_label : Dec, Str, List(Plate.Portion) -> Str
	amount_label = |count, unit, portions|
		match Plate.portion_at(portions, unit) {
			Ok(portion) => if (count == 1.0) portion.label else "${Format.num(count, 2)} × ${portion.label}"
			Err(Grams) => "${Format.num(count, 1)} g"
		}

	# ---- Targets ----

	## How active a day is, and what the energy the body uses at rest is multiplied by for it
	## (the usual factors for the Mifflin–St Jeor equation).
	activities : List({ id : Str, label : Str, factor : Dec })
	activities = [
		{ id: "sedentary", label: "Mostly sitting", factor: 1.2 },
		{ id: "light", label: "Lightly active (exercise 1–3 days a week)", factor: 1.375 },
		{ id: "moderate", label: "Moderately active (3–5 days)", factor: 1.55 },
		{ id: "very", label: "Very active (6–7 days)", factor: 1.725 },
		{ id: "extra", label: "Hard training or a physical job", factor: 1.9 },
	]

	## What you're aiming for, and what it changes the energy a day by.
	goals : List({ id : Str, label : Str, kcal : Dec })
	goals = [
		{ id: "lose", label: "Lose weight (about 0.5 kg a week)", kcal: -500.0 },
		{ id: "lose-slowly", label: "Lose weight slowly (about 0.25 kg a week)", kcal: -250.0 },
		{ id: "keep", label: "Keep my weight", kcal: 0.0 },
		{ id: "gain", label: "Gain weight slowly", kcal: 250.0 },
	]

	sexes : List({ id : Str, label : Str })
	sexes = [{ id: "female", label: "Female" }, { id: "male", label: "Male" }, { id: "unsaid", label: "Rather not say" }]

	## The fewest kcal a worked-out target goes down to.
	floor_kcal : Dec
	floor_kcal = 1200.0

	## The energy the body uses at rest, in kcal a day (Mifflin–St Jeor, 1990): 10 × weight in kg
	## + 6.25 × height in cm − 5 × age, + 5 for a man, − 161 for a woman (− 78, between them, for
	## "rather not say").
	resting : Plate.Profile, I64 -> Dec
	resting = |profile, year| {
		age = I64.max(0, year - profile.birth_year).to_dec()
		base = 10.0 * profile.weight_kg + 6.25 * profile.height_cm - 5.0 * age
		match profile.sex {
			"male" => base + 5.0
			"female" => base - 161.0
			_ => base - 78.0
		}
	}

	## The energy a day the profile aims for: your own target if you set one; or else the energy
	## at rest times how active you are, changed by your goal, rounded to 10 kcal, and never under
	## 1,200.
	kcal_for : Plate.Profile, I64 -> Dec
	kcal_for = |profile, year|
		if profile.kcal_target > 0.0 {
			profile.kcal_target
		} else {
			factor = (Plate.activities.find_first(|each| each.id == profile.activity) ?? { id: "", label: "", factor: 1.2 }).factor
			change = (Plate.goals.find_first(|each| each.id == profile.goal) ?? { id: "", label: "", kcal: 0.0 }).kcal
			worked_out = Dec.round_to(Plate.resting(profile, year) * factor + change, { step: 10.0, ties: AwayFromZero })
			Dec.max(worked_out, Plate.floor_kcal)
		}

	## A day's target: the energy, and its grams of protein, carbohydrate and fat, as 25%, 45% and
	## 30% of it (4, 4 and 9 kcal a gram), each rounded to a gram.
	aim : Plate.Profile, I64 -> Plate.Nutrients
	aim = |profile, year| {
		kcal = Plate.kcal_for(profile, year)
		to_gram = |x| Dec.round_to(x, { step: 1.0, ties: AwayFromZero })
		{ kcal, protein: to_gram(kcal * 0.25 / 4.0), carbs: to_gram(kcal * 0.45 / 4.0), fat: to_gram(kcal * 0.30 / 9.0) }
	}

	## The profile a new diary starts with, until you say otherwise.
	starting : Plate.Profile
	starting = { sex: "unsaid", birth_year: 1990, height_cm: 170.0, weight_kg: 70.0, activity: "light", goal: "keep", kcal_target: 0.0, timezone: "UTC" }

	# ---- Words ----

	## A whole number, with commas between thousands: "2,150".
	whole : Dec -> Str
	whole = |x| {
		rounded = Format.num(Dec.round_to(x, { step: 1.0, ties: AwayFromZero }), 0)
		negative = rounded.starts_with("-")
		digits = rounded.drop_prefix("-").to_utf8()
		count = digits.len()
		grouped = digits.fold_with_index(
			[],
			|out, digit, index|
				if index > 0 and (count - index) % 3 == 0 {
					out.append(',').append(digit)
				} else {
					out.append(digit)
				},
		)
		"${if (negative) "-" else ""}${Str.from_utf8(grouped) ?? rounded}"
	}

	## A number as a form field starts with it: "62", "62.5".
	number : Dec -> Str
	number = |x| Format.num(x, 2)

	## Grams, to a tenth below 10 g and to a gram above: "0.4 g", "12 g".
	grams_label : Dec -> Str
	grams_label = |x| if (Dec.abs(x) < 10.0) "${Format.num(x, 1)} g" else "${Plate.whole(x)} g"

	## What's left of a target: "860 kcal left", "120 kcal over", "Right on target".
	left : Dec, Dec -> Str
	left = |eaten, target| {
		gap = Dec.round_to(target - eaten, { step: 1.0, ties: AwayFromZero })
		if gap > 0.0 {
			"${Plate.whole(gap)} kcal left"
		} else if gap < 0.0 {
			"${Plate.whole(-gap)} kcal over"
		} else {
			"Right on target"
		}
	}

	## How much of a target is reached, as a width for a bar: "40%", at most "100%".
	share : Dec, Dec -> Str
	share = |part, all|
		if all <= 0.0 {
			"0%"
		} else {
			"${Format.num(Dec.min(100.0, Dec.max(0.0, part * 100.0 / all)), 1)}%"
		}

	## A day as the diary's heading says it, seen from `today` (both as `2026-11-22`): "Today",
	## "Yesterday", "Tomorrow", "Fri, Nov 20", or "Mar 3, 2025" in another year.
	day_label : Str, Str -> Str
	day_label = |day, today|
		match (Date.from_str(day), Date.from_str(today)) {
			(Ok(date), Ok(now)) => {
				days = Date.days_between(now, date)
				if days == 0 {
					"Today"
				} else if days == -1 {
					"Yesterday"
				} else if days == 1 {
					"Tomorrow"
				} else if date.year() == now.year() {
					"${weekday(date)}, ${Plate.short_day(day)}"
				} else {
					"${Plate.short_day(day)}, ${date.year().to_str()}"
				}
			}
			_ => day
		}

	## A day without its year: "Nov 22".
	short_day : Str -> Str
	short_day = |day|
		match Date.from_str(day) {
			Ok(date) => "${month_name(date.month())} ${date.day().to_str()}"
			Err(NotDate) => day
		}

	## Where a source's foods come from, as a food's page credits it.
	source_name : Str -> Str
	source_name = |source|
		match source {
			"usda" => "USDA FoodData Central"
			"off" => "Open Food Facts"
			"recipe" => "Your recipe"
			_ => "Your food"
		}

	## Where a food's data can be seen where it came from: its page on FoodData Central, or its
	## product on Open Food Facts.
	source_url : Plate.Food -> Try(Str, [None])
	source_url = |food|
		match food.source {
			"usda" => Ok("https://fdc.nal.usda.gov/food-details/${food.source_id}/nutrients")
			"off" => Ok("https://world.openfoodfacts.org/product/${food.source_id}")
			_ => Err(None)
		}

	## A food's name with its brand, if it has one: "Granola · Acme Mills".
	full_name : Str, Str -> Str
	full_name = |name, brand| if (brand.is_empty()) name else "${name} · ${brand}"
}

month_name : I64 -> Str
month_name = |month| ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].get((month - 1).to_u64_wrap()) ?? ""

## The day of the week: 1970-01-01, day 0, was a Thursday.
weekday : Date -> Str
weekday = |date| ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].get(((Date.days(date) % 7 + 7 + 3) % 7).to_u64_wrap()) ?? ""

# The expects: `roc test main.roc` runs them.

oats : Plate.Nutrients
oats = { kcal: 379.0, protein: 13.15, carbs: 67.7, fat: 6.52 }

milk : Plate.Nutrients
milk = { kcal: 50.0, protein: 3.3, carbs: 4.8, fat: 2.0 }

expect Plate.scaled(oats, 40.0) == { kcal: 151.6, protein: 5.26, carbs: 27.08, fat: 2.608 }
expect Plate.scaled(oats, 0.0) == Plate.none
expect Plate.sum([oats, milk]).kcal == 429.0
# 40 g of oats and 200 g of milk: 251.6 kcal in 240 g, so 104.83… in 100 g.
expect Dec.round_to(Plate.mixed([{ per100: oats, grams: 40.0 }, { per100: milk, grams: 200.0 }]).kcal, { step: 0.01, ties: AwayFromZero }) == 104.83
expect Plate.mixed([]) == Plate.none

broccoli : List(Plate.Portion)
broccoli = [{ label: "1 cup, chopped", grams: 76.0 }, { label: "1 stalk", grams: 151.0 }]

expect Plate.grams_of(1.5, "0", broccoli) == 114.0
expect Plate.grams_of(150.0, "g", broccoli) == 150.0
expect Plate.grams_of(2.0, "7", broccoli) == 2.0
expect Plate.amount_label(1.0, "0", broccoli) == "1 cup, chopped"
expect Plate.amount_label(2.0, "1", broccoli) == "2 × 1 stalk"
expect Plate.amount_label(0.5, "1", broccoli) == "0.5 × 1 stalk"
expect Plate.amount_label(150.0, "g", broccoli) == "150 g"
expect Plate.amount_label(12.5, "g", broccoli) == "12.5 g"

expect Plate.meal_of("dinner") == Dinner
expect Plate.meal_of("elevenses") == Snacks
expect Plate.meal_at(7) == Breakfast
expect Plate.meal_at(13) == Lunch
expect Plate.meal_at(19) == Dinner
expect Plate.meal_at(23) == Snacks
expect Plate.meal_at(2) == Snacks

# A 36-year-old woman, 165 cm and 62 kg, lightly active, keeping her weight: at rest 10 × 62 +
# 6.25 × 165 − 5 × 36 − 161 = 1310.25 kcal, times 1.375 is 1801.6…, so 1,800.
someone : Plate.Profile
someone = { sex: "female", birth_year: 1990, height_cm: 165.0, weight_kg: 62.0, activity: "light", goal: "keep", kcal_target: 0.0, timezone: "UTC" }

expect Plate.resting(someone, 2026) == 1310.25
expect Plate.kcal_for(someone, 2026) == 1800.0
expect Plate.kcal_for({ ..someone, goal: "lose" }, 2026) == 1300.0
expect Plate.kcal_for({ ..someone, goal: "lose", activity: "sedentary" }, 2026) == 1200.0
expect Plate.kcal_for({ ..someone, kcal_target: 2222.0 }, 2026) == 2222.0
expect Plate.aim(someone, 2026) == { kcal: 1800.0, protein: 113.0, carbs: 203.0, fat: 60.0 }

expect Plate.whole(2150.4) == "2,150"
expect Plate.whole(999.5) == "1,000"
expect Plate.whole(1234567.0) == "1,234,567"
expect Plate.whole(-1500.0) == "-1,500"
expect Plate.whole(0.0) == "0"
expect Plate.grams_label(0.44) == "0.4 g"
expect Plate.grams_label(12.6) == "13 g"
expect Plate.left(1240.0, 2100.0) == "860 kcal left"
expect Plate.left(2220.0, 2100.0) == "120 kcal over"
expect Plate.left(2100.2, 2100.0) == "Right on target"
expect Plate.share(50.0, 200.0) == "25%"
expect Plate.share(300.0, 200.0) == "100%"
expect Plate.share(1.0, 0.0) == "0%"

expect Plate.day_label("2026-11-22", "2026-11-22") == "Today"
expect Plate.day_label("2026-11-21", "2026-11-22") == "Yesterday"
expect Plate.day_label("2026-11-23", "2026-11-22") == "Tomorrow"
expect Plate.day_label("2026-11-20", "2026-11-22") == "Fri, Nov 20"
expect Plate.day_label("2025-03-03", "2026-11-22") == "Mar 3, 2025"
expect Plate.full_name("Granola", "Acme Mills") == "Granola · Acme Mills"
expect Plate.full_name("Granola", "") == "Granola"
