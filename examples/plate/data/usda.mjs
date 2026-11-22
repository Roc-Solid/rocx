// Writes migrations/0002_usda_foods.sql: the foods Plate starts with, from USDA FoodData
// Central (public domain, CC0): SR Legacy (2018-04), the classic reference of about 7,800 foods,
// and Foundation Foods, newer analyses of a few hundred. Each food keeps its name, its group, what
// 100 g of it has (energy, protein, carbohydrate, fat, and fibre, sugars, saturated fat and sodium
// where the data says), and its portions ("1 cup, chopped", 76 g).
//
// Baby foods and the American Indian/Alaska Native foods are left out (about 500), to keep the
// seed small and the search about everyday food. A food with no energy value is left out too.
//
//   mkdir -p /tmp/fdc && cd /tmp/fdc
//   curl -LO https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_sr_legacy_food_csv_2018-04.zip
//   curl -LO https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_foundation_food_csv_2026-10-29.zip
//   unzip -q '*.zip'
//   cd - && node examples/plate/data/usda.mjs /tmp/fdc/FoodData_Central_sr_legacy_food_csv_2018-04 \
//     /tmp/fdc/FoodData_Central_foundation_food_csv_2026-10-29 > examples/plate/migrations/0002_usda_foods.sql
import { readFileSync } from "node:fs";
import { join } from "node:path";

const [legacy, foundation] = process.argv.slice(2);
if (!legacy || !foundation) {
	console.error("usage: node usda.mjs <sr-legacy csv dir> <foundation csv dir> > 0002_usda_foods.sql");
	process.exit(2);
}

/** The rows of a FoodData Central CSV file, each an object by the header's names. */
function rows(dir, file) {
	const text = readFileSync(join(dir, file), "utf8");
	const records = [];
	let field = "";
	let record = [];
	let quoted = false;
	for (let i = 0; i < text.length; i++) {
		const c = text[i];
		if (quoted) {
			if (c === '"' && text[i + 1] === '"') {
				field += '"';
				i++;
			} else if (c === '"') quoted = false;
			else field += c;
		} else if (c === '"') quoted = true;
		else if (c === ",") {
			record.push(field);
			field = "";
		} else if (c === "\n" || c === "\r") {
			if (c === "\r" && text[i + 1] === "\n") i++;
			record.push(field);
			field = "";
			if (record.length > 1 || record[0] !== "") records.push(record);
			record = [];
		} else field += c;
	}
	if (field !== "" || record.length) records.push([...record, field]);
	const [header, ...body] = records;
	return body.map((values) => Object.fromEntries(header.map((name, at) => [name, values[at] ?? ""])));
}

// The nutrients kept, by FoodData Central's nutrient ids; the first one a food has wins (Foundation
// Foods give energy as Atwater factors, 2047/2048, more often than as 1008).
const kept = {
	kcal: ["1008", "2047", "2048"],
	protein: ["1003"],
	carbs: ["1005", "1050"],
	fat: ["1004", "1085"],
	fiber: ["1079"],
	sugars: ["2000", "1063"],
	sat_fat: ["1258"],
	sodium: ["1093"],
};
const wanted = new Set(Object.values(kept).flat());
const skippedGroups = new Set(["Baby Foods", "American Indian/Alaska Native Foods"]);

/** A dataset's foods: those of `types`, with their group's name, nutrients and portions. */
function foods(dir, types) {
	const groups = new Map(rows(dir, "food_category.csv").map((row) => [row.id, row.description]));
	const units = new Map(rows(dir, "measure_unit.csv").map((row) => [row.id, row.name]));
	const found = new Map();
	for (const row of rows(dir, "food.csv")) {
		if (!types.includes(row.data_type)) continue;
		const group = groups.get(row.food_category_id) ?? "";
		if (skippedGroups.has(group)) continue;
		found.set(row.fdc_id, { id: row.fdc_id, name: row.description.trim(), group, amounts: new Map(), portions: [] });
	}
	for (const row of rows(dir, "food_nutrient.csv")) {
		const food = found.get(row.fdc_id);
		if (food && wanted.has(row.nutrient_id) && row.amount !== "") food.amounts.set(row.nutrient_id, Number(row.amount));
	}
	for (const row of rows(dir, "food_portion.csv")) {
		const food = found.get(row.fdc_id);
		const grams = Number(row.gram_weight);
		if (!food || !(grams > 0)) continue;
		const unit = units.get(row.measure_unit_id);
		const amount = Number(row.amount || "1");
		const words = [unit && unit !== "undetermined" ? unit : "", row.portion_description, row.modifier]
			.map((word) => word.trim())
			.filter(Boolean);
		// "1 cup, chopped", "2 waffles", "1 slice"; a description that already says its amount stays as it is.
		const said = words.join(unit && unit !== "undetermined" && row.modifier ? ", " : " ");
		const label = /^\d/.test(said) ? said : `${number(amount)} ${said}`.trim();
		if (label && !food.portions.some((portion) => portion.label === label)) food.portions.push({ label, grams });
	}
	return [...found.values()].filter((food) => kept.kcal.some((id) => food.amounts.has(id)));
}

/** A number as the SQL has it: at most two decimals, no trailing zeros. */
function number(value) {
	return String(Math.round(value * 100) / 100);
}

/** What 100 g of a food has, by the names Plate keeps; null where the data doesn't say. */
function per100(food) {
	return Object.fromEntries(
		Object.entries(kept).map(([name, ids]) => {
			const id = ids.find((each) => food.amounts.has(each));
			return [name, id === undefined ? null : food.amounts.get(id)];
		}),
	);
}

const text = (value) => `'${value.replaceAll("'", "''")}'`;
// Carbohydrate "by difference" can come out a little under 0 (-0.48 g): it is 0.
const amount = (value) => (value === null ? "null" : number(Math.max(0, value)));

// A name is kept once: Foundation Foods has some foods twice (analysed again, a newer id), and some
// SR Legacy names come back in it. The newest wins, so a search shows one "Bananas, overripe, raw".
const byName = new Map();
for (const food of [...foods(legacy, ["sr_legacy_food"]), ...foods(foundation, ["foundation_food"])]) {
	const known = byName.get(food.name.toLowerCase());
	if (!known || Number(food.id) > Number(known.id)) byName.set(food.name.toLowerCase(), food);
}
const all = [...byName.values()].sort((a, b) => Number(a.id) - Number(b.id));

const out = [];
out.push(
	"-- Generated by data/usda.mjs from USDA FoodData Central (public domain, CC0): SR Legacy 2018-04 and",
	"-- Foundation Foods 2026-10-29. Each food's amounts are per 100 g; portions are what a measure of it",
	"-- weighs. Don't edit it by hand: run the script again (its header says how).",
	"",
);
const batch = 500;
for (let start = 0; start < all.length; start += batch) {
	out.push("insert into foods (source, source_id, name, food_group, kcal, protein, carbs, fat, fiber, sugars, sat_fat, sodium) values");
	const values = all.slice(start, start + batch).map((food) => {
		const n = per100(food);
		return `('usda','${food.id}',${text(food.name)},${text(food.group)},${amount(n.kcal)},${amount(n.protein ?? 0)},${amount(n.carbs ?? 0)},${amount(n.fat ?? 0)},${amount(n.fiber)},${amount(n.sugars)},${amount(n.sat_fat)},${amount(n.sodium)})`;
	});
	out.push(values.join(",\n") + ";", "");
}
const portions = all.flatMap((food) => food.portions.map((portion, place) => ({ food: food.id, place, ...portion })));
for (let start = 0; start < portions.length; start += batch * 2) {
	// A named `with` of the values, which SQLite reads (it has no column list on a VALUES alias).
	out.push("with p (source_id, label, grams, position) as (values");
	const values = portions.slice(start, start + batch * 2).map((portion) => `('${portion.food}',${text(portion.label)},${number(portion.grams)},${portion.place})`);
	out.push(values.join(",\n"));
	out.push(")");
	out.push("insert into portions (food_id, label, grams, position)");
	out.push("select f.id, p.label, p.grams, p.position from foods f join p on f.source = 'usda' and f.source_id = p.source_id;", "");
}
process.stdout.write(out.join("\n"));
console.error(`${all.length} foods, ${portions.length} portions`);
