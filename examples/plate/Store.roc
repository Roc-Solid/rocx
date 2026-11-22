import pf.Db
import pf.Endpoint
import charts.Format
import forms.Date
import Plate

## Acme Plate's data in Postgres (the tables are `migrations/0001_tables.sql`). Only the endpoints
## (`routes/**/+server.roc`) use it: it imports `pf.Db`, which only the server has.
##
## Postgres keeps amounts as `numeric`, which Db reads once they are cast (`kcal::float8`): a JSON
## number, which `Dec` reads exactly as written. A `Dec` goes to Postgres as text, cast back
## (`$1::numeric`): `Db.Value` has no decimal of its own.
Store := [].{

	## Why the store couldn't do something.
	Problem : [NotFound, DbErr(Str), BadRow(Str)]

	## An endpoint's refusal for a problem: a 404, or a 500 that says why (which the middleware
	## logs).
	refusal : Problem -> Endpoint.Refusal
	refusal = |problem|
		match problem {
			NotFound => NotFound
			DbErr(why) | BadRow(why) => Status(500, "The database failed: ${why}")
		}

	# ---- Days ----

	## Today, in the profile's time zone (`2026-11-22`).
	today! : {} => Try(Str, Problem)
	today! = |{}| {
		rows : List({ today : Str })
		rows = Db.all!("select (now() at time zone timezone)::date::text as today from profile", [])?
		rows.first().map_ok(|row| row.today).map_err(|_| NotFound)
	}

	## The hour it is now, in the profile's time zone (0 to 23): which meal the time suggests.
	hour! : {} => Try(U64, Problem)
	hour! = |{}| {
		rows : List({ hour : I64 })
		rows = Db.all!("select extract(hour from now() at time zone timezone)::int8 as hour from profile", [])?
		rows.first().map_ok(|row| row.hour.to_u64_wrap()).map_err(|_| NotFound)
	}

	## The meal the time of day suggests, as its id (`lunch`).
	meal_now! : {} => Try(Str, Problem)
	meal_now! = |{}| Ok(Plate.meal_id(Plate.meal_at(Store.hour!({})?)))

	## The diary's day `day` (`2026-11-22`): its entries, in the order they were logged, the days
	## either side, today, and the target. Not a day: `NotFound`.
	day! : Str => Try(Plate.Day, Problem)
	day! = |day| {
		_ = Date.from_str(day).map_err(|_| NotFound)?
		around : List({ previous : Str, next : Str })
		around = Db.all!("select ($1::date - 1)::text as previous, ($1::date + 1)::text as next", [Text(day)])?
		sides = around.first().map_err(|_| NotFound)?
		entries : List(Plate.Entry)
		entries = Db.all!(
			"select id::text as id, meal, coalesce(food_id::text, '') as food, name, amount, grams::float8 as grams, kcal::float8 as kcal, protein::float8 as protein, carbs::float8 as carbs, fat::float8 as fat from entries where day = $1::date order by id",
			[Text(day)],
		)?
		today = Store.today!({})?
		target = Store.aim!({})?
		Ok({ day, today, previous: sides.previous, next: sides.next, entries, target })
	}

	## The food `food` logged on `day` at `meal`: `count` of its portion `unit` (or grams, `g`).
	## What that amount has is worked out here, from the food as it is now, and kept with the entry.
	log! : { food : Str, day : Str, meal : Plate.Meal, count : Dec, unit : Str } => Try(Str, Problem)
	log! = |{ food, day, meal, count, unit }| {
		found = Store.food!(food)?
		grams = Plate.grams_of(count, unit, found.portions)
		eaten = Plate.scaled(found.per100, grams)
		rows : List({ id : I64 })
		rows = Db.all!(
			"insert into entries (day, meal, food_id, name, amount, grams, kcal, protein, carbs, fat) values ($1::date, $2, $3, $4, $5, $6::numeric, $7::numeric, $8::numeric, $9::numeric, $10::numeric) returning id",
			[
				Text(day),
				Text(Plate.meal_id(meal)),
				Int(number(food)?),
				Text(Plate.full_name(found.name, found.brand)),
				Text(Plate.amount_label(count, unit, found.portions)),
				dec(grams),
				dec(eaten.kcal),
				dec(eaten.protein),
				dec(eaten.carbs),
				dec(eaten.fat),
			],
		)?
		rows.first().map_ok(|row| row.id.to_str()).map_err(|_| NotFound)
	}

	## The entry `id` gone, and the day it was on (to go back to). Gone already is no problem: a
	## delete sent twice deletes once.
	unlog! : Str => Try(Str, Problem)
	unlog! = |id| {
		rows : List({ day : Str })
		rows = Db.all!("delete from entries where id = $1 returning day::text as day", [Int(number(id)?)])?
		Ok(rows.first().map_ok(|row| row.day) ?? "")
	}

	# ---- Foods ----

	## The food `id`: what 100 g of it has, the extras its data gives, and its portions.
	food! : Str => Try(Plate.Food, Problem)
	food! = |id| {
		key = number(id)?
		rows : List({ id : I64, name : Str, brand : Str, food_group : Str, source : Str, source_id : Str, kcal : Dec, protein : Dec, carbs : Dec, fat : Dec, fiber : Db.Nullable(Dec), sugars : Db.Nullable(Dec), sat_fat : Db.Nullable(Dec), sodium : Db.Nullable(Dec), recipe : Str })
		rows = Db.all!(
			"select f.id, f.name, f.brand, f.food_group, f.source, f.source_id, f.kcal::float8 as kcal, f.protein::float8 as protein, f.carbs::float8 as carbs, f.fat::float8 as fat, f.fiber::float8 as fiber, f.sugars::float8 as sugars, f.sat_fat::float8 as sat_fat, f.sodium::float8 as sodium, coalesce(r.id::text, '') as recipe from foods f left join recipes r on r.food_id = f.id where f.id = $1",
			[Int(key)],
		)?
		row = rows.first().map_err(|_| NotFound)?
		portions : List(Plate.Portion)
		portions = Db.all!("select label, grams::float8 as grams from portions where food_id = $1 order by position, id", [Int(key)])?
		extras = [
			("Fibre", row.fiber, "g"),
			("Sugars", row.sugars, "g"),
			("Saturated fat", row.sat_fat, "g"),
			("Sodium", row.sodium, "mg"),
		]
			.keep_oks(
				|(name, amount, unit)|
					match amount {
						Some(known) => Ok({ name, amount: known, unit })
						Null => Err(Unknown)
					},
			)
		Ok({
			id: row.id.to_str(),
			name: row.name,
			brand: row.brand,
			group: row.food_group,
			source: row.source,
			source_id: row.source_id,
			per100: { kcal: row.kcal, protein: row.protein, carbs: row.carbs, fat: row.fat },
			extras,
			portions,
			recipe: row.recipe,
		})
	}

	## Foods whose name or brand has words starting with each of `query`'s ("chick brea" finds
	## chicken breast): those logged most first, then your recipes and foods, then the shortest
	## names (the plainest: "Bananas, raw" before "Bananas, dehydrated, or banana powder"). `except`
	## leaves one food out (a recipe searching for its own ingredients).
	search! : Str, { limit : U64, except : Str } => Try(List(Plate.Hit), Problem)
	search! = |query, { limit, except }| {
		asked = Store.words(query)
		if asked.is_empty() {
			Ok([])
		} else {
			Db.all!(
				"select f.id::text as id, f.name, f.brand, f.source, f.kcal::float8 as kcal, coalesce((select label from portions p where p.food_id = f.id order by position, id limit 1), '') as portion from foods f left join (select food_id, count(*) as used from entries where food_id is not null group by food_id) u on u.food_id = f.id where f.words @@ to_tsquery('simple', $1) and f.id::text <> $3 order by coalesce(u.used, 0) desc, case f.source when 'recipe' then 0 when 'mine' then 1 when 'off' then 2 else 3 end, length(f.name), f.name limit $2",
				[Text(Str.join_with(asked.map(|word| "${word}:*"), " & ")), Int(limit.to_i64_wrap()), Text(except)],
			)
				.map_err(Store.widen)
		}
	}

	## The words a search looks for: letters and digits (any script), lower case; the rest, which
	## a text search query would read as its own syntax (`&`, `:`, `!`, quotes), splits words.
	words : Str -> List(Str)
	words = |query| {
		bytes = query.to_utf8()
		kept = bytes.map(|byte| if (byte >= 128 or (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z')) byte else ' ')
		(Str.from_utf8(kept) ?? "").split_on(" ").keep_if(|word| !word.is_empty()).map(|word| word.with_ascii_lowercased()).take_first(8)
	}

	## The foods logged lately, the latest first, each once.
	recent! : U64 => Try(List(Plate.Hit), Problem)
	recent! = |limit|
		Db.all!(
			"select f.id::text as id, f.name, f.brand, f.source, f.kcal::float8 as kcal, coalesce((select label from portions p where p.food_id = f.id order by position, id limit 1), '') as portion from foods f join (select food_id, max(id) as last from entries where food_id is not null group by food_id) r on r.food_id = f.id order by r.last desc limit $1",
			[Int(limit.to_i64_wrap())],
		)
			.map_err(Store.widen)

	## The food with the barcode `code`, if there is one.
	by_barcode! : Str => Try(Str, Problem)
	by_barcode! = |code| {
		rows : List({ id : I64 })
		rows = Db.all!("select id from foods where barcode = $1", [Text(code)])?
		rows.first().map_ok(|row| row.id.to_str()).map_err(|_| NotFound)
	}

	## A new food: from Open Food Facts (`off`, by its barcode) or made in the app (`mine`), with
	## what 100 g of it has and maybe a portion. Its id.
	add_food! : { source : Str, name : Str, brand : Str, barcode : Str, per100 : Plate.Nutrients, extras : List(Plate.Extra), portion : Try(Plate.Portion, [Missing]) } => Try(Str, Problem)
	add_food! = |food|
		Db.transaction!(
			|{}| {
				extra = |name| food.extras.find_first(|each| each.name == name).map_ok(|each| dec(each.amount)) ?? Null
				rows : List({ id : I64 })
				rows = Db.all!(
					"insert into foods (source, source_id, name, brand, barcode, kcal, protein, carbs, fat, fiber, sugars, sat_fat, sodium) values ($1, $2, $3, $4, nullif($2, ''), $5::numeric, $6::numeric, $7::numeric, $8::numeric, $9::numeric, $10::numeric, $11::numeric, $12::numeric) returning id",
					[
						Text(food.source),
						Text(food.barcode),
						Text(food.name),
						Text(food.brand),
						dec(food.per100.kcal),
						dec(food.per100.protein),
						dec(food.per100.carbs),
						dec(food.per100.fat),
						extra("Fibre"),
						extra("Sugars"),
						extra("Saturated fat"),
						extra("Sodium"),
					],
				)?
				row = rows.first().map_err(|_| NotFound)?
				match food.portion {
					Ok(portion) => {
						_ = Db.run!("insert into portions (food_id, label, grams) values ($1, $2, $3::numeric)", [Int(row.id), Text(portion.label), dec(portion.grams)])?
						{}
					}
					Err(Missing) => {}
				}
				Ok(row.id.to_str())
			},
		)

	# ---- Recipes ----

	## Every recipe, by name: what a serving has.
	recipes! : {} => Try(List(Plate.Card), Problem)
	recipes! = |{}| {
		rows : List(Plate.Card)
		rows = Db.all!(
			"select r.id::text as id, r.food_id::text as food, r.name, r.servings::int8 as servings, coalesce((select sum(i.grams * f.kcal / 100) from ingredients i join foods f on f.id = i.food_id where i.recipe_id = r.id), 0)::float8 / r.servings as kcal, (select count(*) from ingredients i where i.recipe_id = r.id) as ingredients from recipes r order by lower(r.name), r.id",
			[],
		)?
		Ok(rows)
	}

	## The recipe `id`: its ingredients, each with what its amount has.
	recipe! : Str => Try(Plate.Recipe, Problem)
	recipe! = |id| {
		key = number(id)?
		rows : List({ food : Str, name : Str, servings : I64, notes : Str })
		rows = Db.all!("select food_id::text as food, name, servings::int8 as servings, notes from recipes where id = $1", [Int(key)])?
		recipe = rows.first().map_err(|_| NotFound)?
		parts : List({ id : Str, food : Str, name : Str, brand : Str, grams : Dec, kcal : Dec, protein : Dec, carbs : Dec, fat : Dec })
		parts = Db.all!(
			"select i.id::text as id, f.id::text as food, f.name, f.brand, i.grams::float8 as grams, f.kcal::float8 as kcal, f.protein::float8 as protein, f.carbs::float8 as carbs, f.fat::float8 as fat from ingredients i join foods f on f.id = i.food_id where i.recipe_id = $1 order by i.position, i.id",
			[Int(key)],
		)?
		ingredients = parts.map(|part| { id: part.id, food: part.food, name: Plate.full_name(part.name, part.brand), grams: part.grams, nutrients: Plate.scaled({ kcal: part.kcal, protein: part.protein, carbs: part.carbs, fat: part.fat }, part.grams) })
		Ok({ id, food: recipe.food, name: recipe.name, servings: recipe.servings, notes: recipe.notes, ingredients })
	}

	## A new recipe, of no ingredients yet: its id.
	add_recipe! : { name : Str, servings : I64 } => Try(Str, Problem)
	add_recipe! = |{ name, servings }|
		Db.transaction!(
			|{}| {
				foods : List({ id : I64 })
				foods = Db.all!("insert into foods (source, name, kcal, protein, carbs, fat) values ('recipe', $1, 0, 0, 0, 0) returning id", [Text(name)])?
				food = foods.first().map_err(|_| NotFound)?
				rows : List({ id : I64 })
				rows = Db.all!("insert into recipes (food_id, name, servings) values ($1, $2, $3) returning id", [Int(food.id), Text(name), Int(servings)])?
				recipe = rows.first().map_err(|_| NotFound)?
				_ = Db.run!("update foods set source_id = $2 where id = $1", [Int(food.id), Text(recipe.id.to_str())])?
				Ok(recipe.id.to_str())
			},
		)

	## The recipe `id` renamed, its servings and notes changed.
	save_recipe! : Str, { name : Str, servings : I64, notes : Str } => Try({}, Problem)
	save_recipe! = |id, { name, servings, notes }|
		Db.transaction!(
			|{}| {
				key = number(id)?
				changed = Db.run!("update recipes set name = $2, servings = $3, notes = $4 where id = $1", [Int(key), Text(name), Int(servings), Text(notes)])?
				if changed == 0 {
					Err(NotFound)
				} else {
					_ = Db.run!("update foods set name = $2 where id = (select food_id from recipes where id = $1)", [Int(key), Text(name)])?
					Store.mix!(key)
				}
			},
		)

	## `grams` of the food `food` added to the recipe `id`, last.
	add_ingredient! : Str, { food : Str, grams : Dec } => Try({}, Problem)
	add_ingredient! = |id, { food, grams }|
		Db.transaction!(
			|{}| {
				key = number(id)?
				changed = Db.run!(
					"insert into ingredients (recipe_id, food_id, grams, position) select r.id, f.id, $3::numeric, (select coalesce(max(position) + 1, 0) from ingredients where recipe_id = r.id) from recipes r join foods f on f.id = $2 and f.id <> r.food_id where r.id = $1",
					[Int(key), Int(number(food)?), dec(grams)],
				)?
				if (changed == 0) Err(NotFound) else Store.mix!(key)
			},
		)

	## The ingredient `id` taken out of its recipe, and the recipe (to go back to).
	remove_ingredient! : Str => Try(Str, Problem)
	remove_ingredient! = |id|
		Db.transaction!(
			|{}| {
				rows : List({ recipe : I64 })
				rows = Db.all!("delete from ingredients where id = $1 returning recipe_id as recipe", [Int(number(id)?)])?
				match rows.first() {
					Ok(row) => {
						Store.mix!(row.recipe)?
						Ok(row.recipe.to_str())
					}
					Err(ListWasEmpty) => Ok("")
				}
			},
		)

	## The recipe's food made to match its ingredients: what 100 g of the mix has (`Plate.mixed`),
	## and its one portion, a serving, the whole mix's weight shared by the servings.
	mix! : I64 => Try({}, Problem)
	mix! = |recipe| {
		rows : List({ food : I64, servings : I64 })
		rows = Db.all!("select food_id as food, servings::int8 as servings from recipes where id = $1", [Int(recipe)])?
		found = rows.first().map_err(|_| NotFound)?
		parts : List({ grams : Dec, kcal : Dec, protein : Dec, carbs : Dec, fat : Dec })
		parts = Db.all!(
			"select i.grams::float8 as grams, f.kcal::float8 as kcal, f.protein::float8 as protein, f.carbs::float8 as carbs, f.fat::float8 as fat from ingredients i join foods f on f.id = i.food_id where i.recipe_id = $1",
			[Int(recipe)],
		)?
		per100 = Plate.mixed(parts.map(|part| { per100: { kcal: part.kcal, protein: part.protein, carbs: part.carbs, fat: part.fat }, grams: part.grams }))
		weight = parts.fold(0.0, |sum, part| sum + part.grams)
		_ = Db.run!(
			"update foods set kcal = $2::numeric, protein = $3::numeric, carbs = $4::numeric, fat = $5::numeric where id = $1",
			[Int(found.food), dec(per100.kcal), dec(per100.protein), dec(per100.carbs), dec(per100.fat)],
		)?
		_ = Db.run!("delete from portions where food_id = $1", [Int(found.food)])?
		if weight > 0.0 {
			serving = weight / found.servings.to_dec()
			_ = Db.run!("insert into portions (food_id, label, grams) values ($1, '1 serving', $2::numeric)", [Int(found.food), dec(serving)])?
			Ok({})
		} else {
			Ok({})
		}
	}

	# ---- Targets and trends ----

	## The profile the targets are worked out from.
	profile! : {} => Try(Plate.Profile, Problem)
	profile! = |{}| {
		rows : List(Plate.Profile)
		rows = Db.all!(
			"select sex, birth_year::int8 as birth_year, height_cm::float8 as height_cm, weight_kg::float8 as weight_kg, activity, goal, kcal_target::float8 as kcal_target, timezone from profile",
			[],
		)?
		rows.first().map_err(|_| NotFound)
	}

	## The profile, changed. A time zone Postgres doesn't know is `BadZone`.
	save_profile! : Plate.Profile => Try({}, [BadZone, NotFound, DbErr(Str), BadRow(Str)])
	save_profile! = |profile| {
		zones : List({ known : Bool })
		zones = Db.all!("select exists (select 1 from pg_timezone_names where name = $1) as known", [Text(profile.timezone)])?
		if zones.first().map_ok(|row| row.known) == Ok(Bool.True) {
			_ = Db.run!(
				"update profile set sex = $1, birth_year = $2, height_cm = $3::numeric, weight_kg = $4::numeric, activity = $5, goal = $6, kcal_target = $7::numeric, timezone = $8",
				[Text(profile.sex), Int(profile.birth_year), dec(profile.height_cm), dec(profile.weight_kg), Text(profile.activity), Text(profile.goal), dec(profile.kcal_target), Text(profile.timezone)],
			)?
			Ok({})
		} else {
			Err(BadZone)
		}
	}

	## Today's target, from the profile, in this year (for its age).
	aim! : {} => Try(Plate.Nutrients, Problem)
	aim! = |{}| {
		profile = Store.profile!({})?
		today = Store.today!({})?
		year = Date.from_str(today).map_ok(|date| date.year()) ?? 2026
		Ok(Plate.aim(profile, year))
	}

	## Each of the last `days` days to today, oldest first, with what its entries had (nothing, on a
	## day with none).
	totals! : U64 => Try(List(Plate.Totals), Problem)
	totals! = |days|
		Db.all!(
			"select d.day::date::text as day, coalesce(sum(e.kcal), 0)::float8 as kcal, coalesce(sum(e.protein), 0)::float8 as protein, coalesce(sum(e.carbs), 0)::float8 as carbs, coalesce(sum(e.fat), 0)::float8 as fat from generate_series((select (now() at time zone timezone)::date from profile) - ($1::int - 1), (select (now() at time zone timezone)::date from profile), interval '1 day') as d (day) left join entries e on e.day = d.day::date group by d.day order by d.day",
			[Int(days.to_i64_wrap())],
		)
			.map_err(Store.widen)

	## The weights of the last `days` days, oldest first.
	weights! : U64 => Try(List(Plate.Weight), Problem)
	weights! = |days|
		Db.all!(
			"select day::text as day, kg::float8 as kg from weights where day > (select (now() at time zone timezone)::date from profile) - $1::int order by day",
			[Int(days.to_i64_wrap())],
		)
			.map_err(Store.widen)

	## A weight for `day`, in place of one it had; the profile's too, when it is the latest.
	weigh! : Str, Dec => Try({}, Problem)
	weigh! = |day, kg| {
		_ = Date.from_str(day).map_err(|_| NotFound)?
		Db.transaction!(
			|{}| {
				_ = Db.run!("insert into weights (day, kg) values ($1::date, $2::numeric) on conflict (day) do update set kg = excluded.kg", [Text(day), dec(kg)])?
				_ = Db.run!("update profile set weight_kg = $2::numeric where not exists (select 1 from weights where day > $1::date)", [Text(day), dec(kg)])?
				Ok({})
			},
		)
	}

	## Db's errors as the store's.
	widen : [DbErr(Str), BadRow(Str)] -> Problem
	widen = |problem|
		match problem {
			DbErr(why) => DbErr(why)
			BadRow(why) => BadRow(why)
		}
}

## An id from a URL or a form: a number, or nothing there.
number : Str -> Try(I64, [NotFound])
number = |text| I64.from_str(text.trim()).map_err(|_| NotFound)

## A decimal as Postgres reads it (`$1::numeric`): to two places.
dec : Dec -> Db.Value
dec = |x| Text(Format.num(x, 2))

expect Store.words("Chicken  breast, roasted!") == ["chicken", "breast", "roasted"]
expect Store.words("a:* & b | !c") == ["a", "b", "c"]
expect Store.words("żurek") == ["żurek"]
expect Store.words("  ") == []
