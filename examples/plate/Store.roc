import pf.Db
import pf.Endpoint
import pf.Log
import pf.Time
import charts.Format
import forms.Date
import Plate

## Plate's data in SQLite, a file beside the server (the tables are `migrations/0001_tables.sql`).
## Only the endpoints (`routes/**/+server.roc`) use it: it imports `pf.Db`, which only the server
## has.
##
## SQLite keeps amounts as `real`, which Db reads as a JSON number, which `Dec` reads as written. A
## `Dec` goes to SQLite as text (`Db.Value` has no decimal of its own), which a `real` column takes
## as its number. A day is text (`2026-11-22`); SQLite's `date()` works days out, from the time in
## the profile's time zone (`Time.offset!`), as SQLite knows no zones.
Store := [].{

	## Why the store couldn't do something.
	Problem : [NotFound, DbErr(Str), BadRow(Str)]

	## An endpoint's refusal for a problem: a 404, or a 500. Why the database failed goes on the
	## log, never to the client: its text can name the app's tables, columns and values.
	refusal! : Problem => Endpoint.Refusal
	refusal! = |problem|
		match problem {
			NotFound => NotFound
			DbErr(why) | BadRow(why) => {
				Log.error!("plate: the database failed", { error: why })
				Status(500, "Something went wrong on our side. Try again in a minute.")
			}
		}

	# ---- Days ----

	## Now, in the profile's time zone: seconds since the epoch as its clocks read them (a zone
	## the zone database doesn't have is UTC). SQLite's `date($1, 'unixepoch')` is today there.
	local_now! : {} => Try(I64, Problem)
	local_now! = |{}| {
		rows : List({ timezone : Str })
		rows = Db.all!("select timezone from profile", [])?
		zone = rows.first().map_ok(|row| row.timezone) ?? "UTC"
		now = Time.now_millis!({}).to_i64_wrap()
		Ok(now // 1000 + (Time.offset!(zone, now) ?? 0))
	}

	## Today, in the profile's time zone (`2026-11-22`).
	today! : {} => Try(Str, Problem)
	today! = |{}| {
		row : { today : Str }
		row = Db.one!("select date($1, 'unixepoch') as today", [Int(Store.local_now!({})?)])?
		Ok(row.today)
	}

	## The hour it is now, in the profile's time zone (0 to 23): which meal the time suggests.
	hour! : {} => Try(U64, Problem)
	hour! = |{}| {
		local = Store.local_now!({})?
		Ok(((local % 86_400 + 86_400) % 86_400 // 3_600).to_u64_wrap())
	}

	## The meal the time of day suggests, as its id (`lunch`).
	meal_now! : {} => Try(Str, Problem)
	meal_now! = |{}| Ok(Plate.meal_id(Plate.meal_at(Store.hour!({})?)))

	## The diary's day `day` (`2026-11-22`): its entries, in the order they were logged, the days
	## either side, today, and the target. Not a day: `NotFound`.
	day! : Str => Try(Plate.Day, Problem)
	day! = |day| {
		_ = Date.from_str(day).map_err(|_| NotFound)?
		sides : { previous : Str, next : Str }
		sides = Db.one!("select date($1, '-1 day') as previous, date($1, '+1 day') as next", [Text(day)])?
		entries : List(Plate.Entry)
		entries = Db.all!(
			"select cast(id as text) as id, meal, coalesce(cast(food_id as text), '') as food, name, amount, grams, kcal, protein, carbs, fat from entries where day = $1 order by id",
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
		row : { id : I64 }
		row = Db.one!(
			"insert into entries (day, meal, food_id, name, amount, grams, kcal, protein, carbs, fat) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) returning id",
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
		Ok(row.id.to_str())
	}

	## The entry `id` gone, and the day it was on (to go back to). Gone already is no problem: a
	## delete sent twice deletes once.
	unlog! : Str => Try(Str, Problem)
	unlog! = |id| {
		rows : List({ day : Str })
		rows = Db.all!("delete from entries where id = $1 returning day", [Int(number(id)?)])?
		Ok(rows.first().map_ok(|row| row.day) ?? "")
	}

	# ---- Foods ----

	## The food `id`: what 100 g of it has, the extras its data gives, and its portions.
	food! : Str => Try(Plate.Food, Problem)
	food! = |id| {
		key = number(id)?
		row : { id : I64, name : Str, brand : Str, food_group : Str, source : Str, source_id : Str, kcal : Dec, protein : Dec, carbs : Dec, fat : Dec, fiber : Db.Nullable(Dec), sugars : Db.Nullable(Dec), sat_fat : Db.Nullable(Dec), sodium : Db.Nullable(Dec), recipe : Str }
		row = Db.one!(
			"select f.id, f.name, f.brand, f.food_group, f.source, f.source_id, f.kcal, f.protein, f.carbs, f.fat, f.fiber, f.sugars, f.sat_fat, f.sodium, coalesce(cast(r.id as text), '') as recipe from foods f left join recipes r on r.food_id = f.id where f.id = $1",
			[Int(key)],
		)?
		portions : List(Plate.Portion)
		portions = Db.all!("select label, grams from portions where food_id = $1 order by position, id", [Int(key)])?
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
				"select cast(f.id as text) as id, f.name, f.brand, f.source, f.kcal, coalesce((select label from portions p where p.food_id = f.id order by position, id limit 1), '') as portion from food_words join foods f on f.id = food_words.rowid left join (select food_id, count(*) as used from entries where food_id is not null group by food_id) u on u.food_id = f.id where food_words match $1 and cast(f.id as text) <> $3 order by coalesce(u.used, 0) desc, case f.source when 'recipe' then 0 when 'mine' then 1 when 'off' then 2 else 3 end, length(f.name), f.name limit $2",
				[Text(Str.join_with(asked.map(|word| "\"${word}\"*"), " ")), Int(limit.to_i64_wrap()), Text(except)],
			)
				.map_err(Store.widen)
		}
	}

	## The words a search looks for: letters and digits (any script), lower case; the rest, which
	## a full-text query would read as its own syntax (`*`, `:`, `^`, quotes), splits words. Each is
	## asked for as a word's start (`"chick"*`), all of them at once.
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
			"select cast(f.id as text) as id, f.name, f.brand, f.source, f.kcal, coalesce((select label from portions p where p.food_id = f.id order by position, id limit 1), '') as portion from foods f join (select food_id, max(id) as last from entries where food_id is not null group by food_id) r on r.food_id = f.id order by r.last desc limit $1",
			[Int(limit.to_i64_wrap())],
		)
			.map_err(Store.widen)

	## The food with the barcode `code`, if there is one.
	by_barcode! : Str => Try(Str, Problem)
	by_barcode! = |code| {
		row : { id : I64 }
		row = Db.one!("select id from foods where barcode = $1", [Text(code)])?
		Ok(row.id.to_str())
	}

	## A new food: from Open Food Facts (`off`, by its barcode) or made in the app (`mine`), with
	## what 100 g of it has and maybe a portion. Its id.
	add_food! : { source : Str, name : Str, brand : Str, barcode : Str, per100 : Plate.Nutrients, extras : List(Plate.Extra), portion : Try(Plate.Portion, [Missing]) } => Try(Str, Problem)
	add_food! = |food|
		Db.transaction!(
			|{}| {
				extra = |name| food.extras.find_first(|each| each.name == name).map_ok(|each| dec(each.amount)) ?? Null
				row : { id : I64 }
				row = Db.one!(
					"insert into foods (source, source_id, name, brand, barcode, kcal, protein, carbs, fat, fiber, sugars, sat_fat, sodium) values ($1, $2, $3, $4, nullif($2, ''), $5, $6, $7, $8, $9, $10, $11, $12) returning id",
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
				match food.portion {
					Ok(portion) => {
						_ = Db.run!("insert into portions (food_id, label, grams) values ($1, $2, $3)", [Int(row.id), Text(portion.label), dec(portion.grams)])?
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
			"select cast(r.id as text) as id, cast(r.food_id as text) as food, r.name, r.servings, round(coalesce((select sum(i.grams * f.kcal / 100) from ingredients i join foods f on f.id = i.food_id where i.recipe_id = r.id), 0) * 1.0 / r.servings, 2) as kcal, (select count(*) from ingredients i where i.recipe_id = r.id) as ingredients from recipes r order by lower(r.name), r.id",
			[],
		)?
		Ok(rows)
	}

	## The recipe `id`: its ingredients, each with what its amount has.
	recipe! : Str => Try(Plate.Recipe, Problem)
	recipe! = |id| {
		key = number(id)?
		recipe : { food : Str, name : Str, servings : I64, notes : Str }
		recipe = Db.one!("select cast(food_id as text) as food, name, servings, notes from recipes where id = $1", [Int(key)])?
		parts : List({ id : Str, food : Str, name : Str, brand : Str, grams : Dec, kcal : Dec, protein : Dec, carbs : Dec, fat : Dec })
		parts = Db.all!(
			"select cast(i.id as text) as id, cast(f.id as text) as food, f.name, f.brand, i.grams, f.kcal, f.protein, f.carbs, f.fat from ingredients i join foods f on f.id = i.food_id where i.recipe_id = $1 order by i.position, i.id",
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
				food : { id : I64 }
				food = Db.one!("insert into foods (source, name, kcal, protein, carbs, fat) values ('recipe', $1, 0, 0, 0, 0) returning id", [Text(name)])?
				recipe : { id : I64 }
				recipe = Db.one!("insert into recipes (food_id, name, servings) values ($1, $2, $3) returning id", [Int(food.id), Text(name), Int(servings)])?
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
					"insert into ingredients (recipe_id, food_id, grams, position) select r.id, f.id, $3, (select coalesce(max(position) + 1, 0) from ingredients where recipe_id = r.id) from recipes r join foods f on f.id = $2 and f.id <> r.food_id where r.id = $1",
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
		found : { food : I64, servings : I64 }
		found = Db.one!("select food_id as food, servings from recipes where id = $1", [Int(recipe)])?
		parts : List({ grams : Dec, kcal : Dec, protein : Dec, carbs : Dec, fat : Dec })
		parts = Db.all!(
			"select i.grams, f.kcal, f.protein, f.carbs, f.fat from ingredients i join foods f on f.id = i.food_id where i.recipe_id = $1",
			[Int(recipe)],
		)?
		per100 = Plate.mixed(parts.map(|part| { per100: { kcal: part.kcal, protein: part.protein, carbs: part.carbs, fat: part.fat }, grams: part.grams }))
		weight = parts.fold(0.0, |sum, part| sum + part.grams)
		_ = Db.run!(
			"update foods set kcal = $2, protein = $3, carbs = $4, fat = $5 where id = $1",
			[Int(found.food), dec(per100.kcal), dec(per100.protein), dec(per100.carbs), dec(per100.fat)],
		)?
		_ = Db.run!("delete from portions where food_id = $1", [Int(found.food)])?
		if weight > 0.0 {
			serving = weight / found.servings.to_dec()
			_ = Db.run!("insert into portions (food_id, label, grams) values ($1, '1 serving', $2)", [Int(found.food), dec(serving)])?
			Ok({})
		} else {
			Ok({})
		}
	}

	# ---- Targets and trends ----

	## The profile the targets are worked out from.
	profile! : {} => Try(Plate.Profile, Problem)
	profile! = |{}| Db.one!("select sex, birth_year, height_cm, weight_kg, activity, goal, kcal_target, timezone from profile", [])

	## The profile, changed. A time zone the zone database doesn't have (`Time.offset!`) is
	## `BadZone`.
	save_profile! : Plate.Profile => Try({}, [BadZone, NotFound, DbErr(Str), BadRow(Str)])
	save_profile! = |profile| {
		known = Time.offset!(profile.timezone, Time.now_millis!({}).to_i64_wrap()).is_ok()
		if known {
			_ = Db.run!(
				"update profile set sex = $1, birth_year = $2, height_cm = $3, weight_kg = $4, activity = $5, goal = $6, kcal_target = $7, timezone = $8",
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
	totals! = |days| {
		local = Store.local_now!({})?
		Db.all!(
			"with recursive d (day) as (select date($2, 'unixepoch', '-' || ($1 - 1) || ' days') union all select date(day, '+1 day') from d where day < date($2, 'unixepoch')) select d.day as day, round(coalesce(sum(e.kcal), 0), 2) as kcal, round(coalesce(sum(e.protein), 0), 2) as protein, round(coalesce(sum(e.carbs), 0), 2) as carbs, round(coalesce(sum(e.fat), 0), 2) as fat from d left join entries e on e.day = d.day group by d.day order by d.day",
			[Int(days.to_i64_wrap()), Int(local)],
		)
			.map_err(Store.widen)
	}

	## The weights of the last `days` days, oldest first.
	weights! : U64 => Try(List(Plate.Weight), Problem)
	weights! = |days| {
		local = Store.local_now!({})?
		Db.all!(
			"select day, kg from weights where day > date($2, 'unixepoch', '-' || $1 || ' days') order by day",
			[Int(days.to_i64_wrap()), Int(local)],
		)
			.map_err(Store.widen)
	}

	## A weight for `day`, in place of one it had; the profile's too, when it is the latest.
	weigh! : Str, Dec => Try({}, Problem)
	weigh! = |day, kg| {
		_ = Date.from_str(day).map_err(|_| NotFound)?
		Db.transaction!(
			|{}| {
				_ = Db.run!("insert into weights (day, kg) values ($1, $2) on conflict (day) do update set kg = excluded.kg", [Text(day), dec(kg)])?
				_ = Db.run!("update profile set weight_kg = $2 where not exists (select 1 from weights where day > $1)", [Text(day), dec(kg)])?
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

## A decimal as a `real` column takes it: text, to two places.
dec : Dec -> Db.Value
dec = |x| Text(Format.num(x, 2))

expect Store.words("Chicken  breast, roasted!") == ["chicken", "breast", "roasted"]
expect Store.words("a:* & b | !c") == ["a", "b", "c"]
expect Store.words("żurek") == ["żurek"]
expect Store.words("  ") == []
