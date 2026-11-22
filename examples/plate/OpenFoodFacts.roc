import pf.Env
import pf.Http
import mcp.JsonValue
import charts.Format
import Plate

## A packaged food looked up by its barcode in Open Food Facts (world.openfoodfacts.org), the open
## database of food products anyone can add to. Its data is under the Open Database License: the
## food's page says where it came from and links to the product there.
##
## A barcode is asked for once: what comes back is kept as a food (`Store.add_food!`, source
## `off`), so the next time it is found in Postgres, and Open Food Facts' limits (100 product reads
## a minute) are never near. `OFF_URL` points it somewhere else (the tests' stand-in).
##
## Its JSON names nutrients with dashes (`energy-kcal_100g`), which a Roc record's fields can't
## have, so it is read a field at a time with packages/mcp's `JsonValue`.
OpenFoodFacts := [].{

	## A product, as the app keeps it.
	Product : { name : Str, brand : Str, barcode : Str, per100 : Plate.Nutrients, extras : List(Plate.Extra), portion : Try(Plate.Portion, [Missing]) }

	## Where Open Food Facts answers: `OFF_URL`, or the real one.
	base! : {} => Str
	base! = |{}|
		match Env.var!("OFF_URL") {
			Ok(url) if !url.is_empty() => url
			_ => "https://world.openfoodfacts.org"
		}

	## Asks Open Food Facts for the product with `barcode`.
	lookup! : Str => Try(OpenFoodFacts.Product, [NotFound, Unreadable(Str), Unreachable(Str)])
	lookup! = |barcode| {
		url = "${OpenFoodFacts.base!({})}/api/v2/product/${barcode}?fields=product_name,product_name_en,generic_name,brands,nutriments,serving_size,serving_quantity"
		asked = Http.fetch!(url, { headers: [("user-agent", "AcmePlate/1.0 (a Roc Solid example app)"), ("accept", "application/json")], timeout_ms: 10_000, max_bytes: 2_000_000 })
		match asked {
			Ok(answer) if answer.status == 404 => Err(NotFound)
			Ok(answer) if answer.status == 200 =>
				match Str.from_utf8(answer.body) {
					Ok(text) => OpenFoodFacts.product(text, barcode)
					Err(_) => Err(Unreadable("its answer wasn't UTF-8"))
				}
			Ok(answer) => Err(Unreachable("it answered ${answer.status.to_str()}"))
			Err(HttpErr(why)) => Err(Unreachable(why))
			Err(TimedOut) => Err(Unreachable("no answer in 10 seconds"))
			Err(TooLarge) => Err(Unreadable("its answer was over 2 MB"))
		}
	}

	## The product in an answer of Open Food Facts' API (`/api/v2/product/<barcode>`): `NotFound`
	## when it says it has none; `Unreadable` when it has one without a name or energy.
	product : Str, Str -> Try(OpenFoodFacts.Product, [NotFound, Unreadable(Str)])
	product = |text, barcode| {
		json = JsonValue.parse(text).map_err(|InvalidJson(why)| Unreadable("its answer isn't JSON: ${why}"))?
		status = json.get("status").map_ok(number) ?? Err(NotNumber)
		item = json.get("product").map_err(|_| NotFound)?
		if status == Ok(0.0) or !item.is_object() {
			Err(NotFound)
		} else {
			name = first_text(item, ["product_name", "product_name_en", "generic_name"])
			nutriments = item.get("nutriments") ?? Object([])
			amount = |key| nutriments.get(key).map_ok(number) ?? Err(NotNumber)
			kcal =
				match amount("energy-kcal_100g") {
					Ok(known) => Ok(known)
					Err(_) => amount("energy_100g").map_ok(|kj| Dec.round_to(kj / 4.184, { step: 0.1, ties: AwayFromZero }))
				}
			match (name, kcal) {
				(Err(_), _) => Err(Unreadable("Open Food Facts has no name for it"))
				(_, Err(_)) => Err(Unreadable("Open Food Facts doesn't say how much energy it has"))
				(Ok(named), Ok(energy)) => {
					extras = [
						("Fibre", amount("fiber_100g"), "g", 1.0),
						("Sugars", amount("sugars_100g"), "g", 1.0),
						("Saturated fat", amount("saturated-fat_100g"), "g", 1.0),
						("Sodium", amount("sodium_100g"), "mg", 1000.0),
					]
						.keep_oks(|(extra, value, unit, times)| value.map_ok(|known| { name: extra, amount: known * times, unit }))
					serving = first_text(item, ["serving_size"]) ?? ""
					grams = item.get("serving_quantity").map_ok(number) ?? Err(NotNumber)
					portion =
						match grams {
							Ok(weight) if weight > 0.0 and !serving.is_empty() => Ok({ label: serving, grams: weight })
							Ok(weight) if weight > 0.0 => Ok({ label: "1 serving (${Format.num(weight, 1)} g)", grams: weight })
							_ => Err(Missing)
						}
					Ok({
						name: named,
						brand: (first_text(item, ["brands"]) ?? "").split_on(",").first().map_ok(Str.trim) ?? "",
						barcode,
						per100: { kcal: energy, protein: amount("proteins_100g") ?? 0.0, carbs: amount("carbohydrates_100g") ?? 0.0, fat: amount("fat_100g") ?? 0.0 },
						extras,
						portion,
					})
				}
			}
		}
	}
}

## A number, written as one or in a string (Open Food Facts has both).
number : JsonValue -> Try(Dec, [NotNumber])
number = |value|
	match value {
		Number(text) | String(text) => Dec.from_str(text.trim()).map_err(|_| NotNumber)
		_ => Err(NotNumber)
	}

## The first of `keys` that holds some text.
first_text : JsonValue, List(Str) -> Try(Str, [Missing])
first_text = |value, keys|
	keys
		.keep_oks(
			|key|
				match value.get(key) {
					Ok(found) => found.to_text().map_err(|_| Missing)
					Err(_) => Err(Missing)
				},
		)
		.map(Str.trim)
		.find_first(|text| !text.is_empty())
		.map_err(|_| Missing)

found : Str
found = "{\"code\":\"5000000000017\",\"product\":{\"brands\":\"Acme Mills, Acme\",\"nutriments\":{\"carbohydrates_100g\":64,\"energy-kcal_100g\":412,\"energy_100g\":1724,\"fat_100g\":14.5,\"fiber_100g\":\"6.1\",\"proteins_100g\":9.8,\"saturated-fat_100g\":2.4,\"sodium_100g\":0.12},\"product_name\":\"Honey granola\",\"serving_quantity\":\"45\",\"serving_size\":\"1 bowl (45 g)\"},\"status\":1,\"status_verbose\":\"product found\"}"

expect OpenFoodFacts.product(found, "5000000000017").map_ok(|it| (it.name, it.brand, it.per100)) == Ok(("Honey granola", "Acme Mills", { kcal: 412.0, protein: 9.8, carbs: 64.0, fat: 14.5 }))
expect OpenFoodFacts.product(found, "5000000000017").map_ok(|it| it.extras.map(|extra| (extra.name, extra.amount))) == Ok([("Fibre", 6.1), ("Saturated fat", 2.4), ("Sodium", 120.0)])
expect OpenFoodFacts.product(found, "5000000000017").map_ok(|it| it.portion) == Ok(Ok({ label: "1 bowl (45 g)", grams: 45.0 }))
expect OpenFoodFacts.product("{\"code\":\"1\",\"status\":0,\"status_verbose\":\"product not found\"}", "1") == Err(NotFound)
expect OpenFoodFacts.product("{\"code\":\"1\",\"product\":{\"product_name\":\"Tea\",\"nutriments\":{}},\"status\":1}", "1") == Err(Unreadable("Open Food Facts doesn't say how much energy it has"))
# Energy only in kJ: 1724 kJ is 412.0 kcal.
expect OpenFoodFacts.product("{\"product\":{\"product_name\":\"Oats\",\"nutriments\":{\"energy_100g\":1724}},\"status\":1}", "1").map_ok(|it| (it.per100.kcal, it.brand, it.portion)) == Ok((412.0, "", Err(Missing)))
