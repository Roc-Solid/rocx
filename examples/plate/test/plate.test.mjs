// Plate, tested as people use it: over HTTP (pages, plain forms, the runtime's posts, the
// endpoints as JSON, the database), then in a real browser. The app is built once (rocx build, the
// browser's wasm, the server), and started against a SQLite file of the tests' own, which its
// migrations make and fill with the USDA's foods. Open Food Facts is a stand-in on a local port
// (`OFF_URL`), so no test leaves the machine. No database server is needed.
//
//   node --test 'examples/plate/test/*.test.mjs'
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { join } from "node:path";
import { buildForTests, startServer, testSqlite, launchBrowser, until, repo } from "../../../packages/testing/index.mjs";

const skip = false;

let db;
let app;
let built;
/** The stand-in for Open Food Facts, and the barcodes it was asked for. */
let off;
const asked = [];
/** Chromium's headless shell, or null when there is none: the browser's tests skip then. */
let browser = null;

// What Open Food Facts answers for a product it has (its API v2, the fields the app asks for).
const granola = {
	code: "5000000000017",
	product: {
		brands: "Acme Mills, Acme",
		nutriments: { "energy-kcal_100g": 412, carbohydrates_100g: 64, fat_100g: 14.5, fiber_100g: "6.1", proteins_100g: 9.8, "saturated-fat_100g": 2.4, sodium_100g: 0.12 },
		product_name: "Honey granola",
		serving_quantity: "45",
		serving_size: "1 bowl (45 g)",
	},
	status: 1,
	status_verbose: "product found",
};

before(async () => {
	if (skip) return;
	off = createServer((request, response) => {
		const code = /^\/api\/v2\/product\/(\d+)/.exec(request.url)?.[1];
		asked.push({ code, agent: request.headers["user-agent"] });
		response.setHeader("content-type", "application/json");
		if (code === granola.code) return response.end(JSON.stringify(granola));
		response.statusCode = 404;
		response.end(JSON.stringify({ code, status: 0, status_verbose: "product not found" }));
	});
	await new Promise((resolve) => off.listen(0, "127.0.0.1", resolve));
	built = await buildForTests(join(repo, "examples", "plate"));
	db = testSqlite();
	app = await startServer(built.server, { statics: built.statics, database: db.url, env: { OFF_URL: `http://127.0.0.1:${off.address().port}` } });
	browser = await launchBrowser();
});

after(async () => {
	await browser?.close();
	await app?.stop();
	await db?.drop();
	off?.close();
});

/** The first food a search finds: its id. */
async function found(person, words) {
	const search = await person.read(`/add?q=${encodeURIComponent(words)}`);
	assert.ok(search.hits.length > 0, `something for "${words}"`);
	return search.hits[0];
}

/** Today, as the diary has it (the profile's time zone). */
async function today(person) {
	return (await person.read("/")).today;
}

/** A day that is `days` from `day` (both `2026-11-22`). */
function shifted(day, days) {
	const date = new Date(`${day}T12:00:00Z`);
	date.setUTCDate(date.getUTCDate() + days);
	return date.toISOString().slice(0, 10);
}

test("the USDA's foods are there, and a search finds each word's start", { skip }, async () => {
	const person = app.client();
	const [{ count }] = await db.sql`select count(*) as count from foods where source = 'usda'`;
	assert.ok(count > 7000, `${count} foods`);
	const banana = await found(person, "bananas raw");
	assert.equal(banana.name, "Bananas, raw");
	assert.equal(banana.kcal, 89);
	// Words in any order, each a word's start: "chick brea" is chicken breast.
	const chicken = await person.read("/add?q=brea+chick");
	assert.ok(chicken.hits.every((hit) => /chick/i.test(hit.name) && /brea/i.test(hit.name)));
	// What a text search would read as its own syntax is only a space here.
	assert.equal((await person.read("/add?q=%27%3A*%26%21%28")).hits.length, 0);
	// The page, without JavaScript: the results are links to each food's page, for the meal asked.
	const page = await person.get("/add?q=bananas+raw&meal=lunch&day=2026-11-20");
	assert.equal(page.status, 200);
	page.dom.getByRole("heading", { level: 1, name: "Add to Lunch" });
	const link = page.dom.getByRole("link", { name: /^Bananas, raw 89 kcal \/ 100 g/ });
	assert.equal(link.attr("href"), `/foods/${banana.id}?day=2026-11-20&meal=lunch`);
});

test("a food's page: its portions, its facts, and where its data came from", { skip }, async () => {
	const person = app.client();
	const broccoli = await found(person, "broccoli raw");
	const pick = await person.read(`/foods/${broccoli.id}`);
	assert.equal(pick.food.name, "Broccoli, raw");
	assert.equal(pick.food.source, "usda");
	assert.ok(pick.food.portions.some((portion) => portion.label === "1 cup, chopped" && portion.grams > 0));
	assert.ok(pick.food.extras.some((extra) => extra.name === "Fibre"));
	const page = await person.get(`/foods/${broccoli.id}?meal=dinner`);
	assert.equal(page.dom.getByLabelText("Amount").attr("value"), "1");
	assert.equal(page.dom.getAllByRole("option")[0].attr("selected"), "");
	assert.equal(page.dom.getByRole("option", { name: "Dinner" }).attr("selected"), "");
	page.dom.getByRole("table", { name: "Nutrition facts" });
	assert.match(page.dom.getByRole("link", { name: "USDA FoodData Central" }).attr("href"), /^https:\/\/fdc\.nal\.usda\.gov\/food-details\/\d+\/nutrients$/);
	assert.equal((await person.get("/foods/999999")).status, 404);
	assert.equal((await person.get("/foods/nope")).status, 404);
});

test("logging without JavaScript: a plain form, a 303 to the day, and the entry keeps what it had", { skip }, async () => {
	const person = app.client();
	const day = shifted(await today(person), -3);
	const banana = await found(person, "bananas raw");
	const pick = await person.read(`/foods/${banana.id}`);
	const medium = pick.food.portions.findIndex((portion) => portion.label.startsWith("1 medium"));
	assert.ok(medium >= 0);
	await person.get(`/foods/${banana.id}`);
	const logged = await person.post(`/foods/${banana.id}`, { amount: "2", unit: String(medium), meal: "breakfast", day });
	assert.equal(logged.status, 303);
	assert.equal(logged.location, `/days/${day}`);
	const [row] = await db.sql`select meal, name, amount, grams, kcal from entries where day = ${day}`;
	const grams = 2 * pick.food.portions[medium].grams;
	assert.deepEqual(row, { meal: "breakfast", name: "Bananas, raw", amount: `2 × ${pick.food.portions[medium].label}`, grams, kcal: Math.round(89 * grams) / 100 });
	const page = await logged.follow();
	const breakfast = page.dom.getByRole("region", { name: "Breakfast" });
	assert.ok(breakfast.text.includes("Bananas, raw"));
	assert.ok(breakfast.text.includes(`${Math.round(row.kcal)}`));
	// A food changed later doesn't change the day: the entry kept its numbers.
	await db.sql`update foods set kcal = 1000 where id = ${Number(banana.id)}`;
	assert.equal((await person.read(`/days/${day}`)).entries[0].kcal, row.kcal);
	await db.sql`update foods set kcal = 89 where id = ${Number(banana.id)}`;
	// Grams, as typed.
	await person.get(`/foods/${banana.id}`);
	await person.post(`/foods/${banana.id}`, { amount: "37.5", unit: "g", meal: "snacks", day });
	const [snack] = await db.sql`select amount, grams from entries where day = ${day} and meal = 'snacks'`;
	assert.deepEqual(snack, { amount: "37.5 g", grams: 37.5 });
});

test("an amount the form refuses comes back with why, and nothing is logged", { skip }, async () => {
	const person = app.client();
	const banana = await found(person, "bananas raw");
	const day = shifted(await today(person), -40);
	await person.get(`/foods/${banana.id}`);
	const refused = await person.post(`/foods/${banana.id}`, { amount: "0", unit: "g", meal: "brunch", day });
	assert.equal(refused.status, 303);
	assert.equal(person.flash.status, 422);
	const page = await refused.follow();
	assert.equal(page.dom.getByLabelText("Amount").attr("aria-invalid"), "true");
	// As the runtime sends it: 422, each field's issue.
	const runtime = await person.submit(`/foods/${banana.id}`, { amount: "lots", unit: "g", meal: "lunch", day: "2026-02-30" });
	assert.equal(runtime.status, 422);
	assert.deepEqual(await db.sql`select id from entries where day = ${day}`, []);
});

test("a day: its meals and totals, the days either side, and an entry taken off", { skip }, async () => {
	const person = app.client();
	const day = shifted(await today(person), -5);
	const rice = await found(person, "rice white long grain regular enriched cooked");
	const egg = await found(person, "egg whole raw fresh");
	await person.submit(`/foods/${rice.id}`, { amount: "200", unit: "g", meal: "lunch", day });
	await person.submit(`/foods/${egg.id}`, { amount: "100", unit: "g", meal: "dinner", day });
	const sheet = await person.read(`/days/${day}`);
	assert.equal(sheet.previous, shifted(day, -1));
	assert.equal(sheet.next, shifted(day, 1));
	assert.deepEqual(sheet.entries.map((entry) => [entry.meal, entry.grams]), [["lunch", 200], ["dinner", 100]]);
	const page = await person.get(`/days/${day}`);
	const kcal = Math.round(sheet.entries.reduce((sum, entry) => sum + entry.kcal, 0));
	page.dom.getByRole("img", { name: `${kcal.toLocaleString("en-US")} of ${sheet.target.kcal.toLocaleString("en-US")} kcal` });
	assert.equal(page.dom.getByRole("link", { name: "The day before" }).attr("href"), `/days/${shifted(day, -1)}`);
	// Taken off, without JavaScript: back to the day; sent twice, still fine.
	const [lunch] = sheet.entries;
	await person.get(`/days/${day}`);
	assert.equal((await person.post("/api/entries/delete", { id: lunch.id })).status, 303);
	assert.equal((await person.submit("/api/entries/delete", { id: lunch.id })).status, 200);
	assert.deepEqual((await person.read(`/days/${day}`)).entries.map((entry) => entry.meal), ["dinner"]);
	// Not a day: a 404.
	assert.equal((await person.get("/days/2026-02-30")).status, 404);
	assert.equal((await person.get("/days/yesterday")).status, 404);
	// Today is `/`, with "Today" over it.
	const home = await person.get("/");
	home.dom.getByRole("heading", { level: 1, name: "Today" });
});

test("a food of your own: as its label says it, kept per 100 g, found first", { skip }, async () => {
	const person = app.client();
	await person.get("/foods/new");
	const fields = { name: "Oat bar", brand: "Acme Mills", per: "40", kcal: "180", protein: "4", carbs: "24", fat: "7", fiber: "3", sugars: "", sat_fat: "", sodium: "", serving: "1 bar", serving_grams: "40", barcode: "0012345678905", then_day: "2026-11-20", then_meal: "snacks" };
	const made = await person.post("/foods/new", fields);
	assert.equal(made.status, 303);
	const id = /^\/foods\/(\d+)\?day=2026-11-20&meal=snacks$/.exec(made.location)?.[1];
	assert.ok(id, made.location);
	const [food] = await db.sql`select source, name, brand, barcode, kcal, protein, fiber, sugars from foods where id = ${Number(id)}`;
	assert.deepEqual(food, { source: "mine", name: "Oat bar", brand: "Acme Mills", barcode: "0012345678905", kcal: 450, protein: 10, fiber: 7.5, sugars: null });
	const pick = await person.read(`/foods/${id}`);
	assert.deepEqual(pick.food.portions, [{ label: "1 bar", grams: 40 }]);
	assert.deepEqual(pick.food.extras.map((extra) => extra.name), ["Fibre"]);
	// Yours come before the USDA's.
	assert.equal((await person.read("/add?q=oat+bar")).hits[0].id, id);
	// Another with its barcode, or with more macronutrients than weight, is refused.
	assert.equal((await person.submit("/foods/new", fields)).status, 422);
	const heavy = await person.submit("/foods/new", { ...fields, barcode: "", fat: "70" });
	assert.equal(heavy.status, 422);
	assert.match(heavy.text, /weigh more than the amount/);
});

test("a barcode: Open Food Facts is asked once, and the product kept as a food", { skip }, async () => {
	const person = app.client();
	await person.get("/barcode");
	const looked = await person.post("/barcode", { barcode: ` ${granola.code} `, then_day: "", then_meal: "breakfast" });
	assert.equal(looked.status, 303);
	const id = /^\/foods\/(\d+)\?meal=breakfast$/.exec(looked.location)?.[1];
	assert.ok(id, looked.location);
	const pick = await person.read(`/foods/${id}`);
	assert.equal(pick.food.name, "Honey granola");
	assert.equal(pick.food.brand, "Acme Mills");
	assert.equal(pick.food.source, "off");
	assert.deepEqual(pick.food.per100, { kcal: 412, protein: 9.8, carbs: 64, fat: 14.5 });
	assert.deepEqual(pick.food.portions, [{ label: "1 bowl (45 g)", grams: 45 }]);
	assert.ok(pick.food.extras.some((extra) => extra.name === "Sodium" && extra.amount === 120));
	assert.equal(asked.filter((each) => each.code === granola.code).length, 1);
	assert.match(asked[0].agent, /^Plate\//);
	// The second time it is the diary's: Open Food Facts isn't asked again.
	const again = await person.submit("/barcode", { barcode: granola.code });
	assert.equal(asked.filter((each) => each.code === granola.code).length, 1);
	assert.ok([200, 303].includes(again.status));
	// The page credits Open Food Facts, and links to the product there.
	const page = await person.get(`/foods/${id}`);
	assert.equal(page.dom.getByRole("link", { name: "Open Food Facts" }).attr("href"), `https://world.openfoodfacts.org/product/${granola.code}`);
	// One it doesn't know: refused under the field, and the way to make it yourself.
	const unknown = await person.submit("/barcode", { barcode: "4006381333931" });
	assert.equal(unknown.status, 422);
	assert.match(unknown.text, /doesn't know this barcode/);
	await person.get("/barcode");
	await person.post("/barcode", { barcode: "4006381333931" });
	const back = await person.get("/barcode");
	assert.equal(back.dom.getByRole("link", { name: "Make the food yourself" }).attr("href"), "/foods/new?barcode=4006381333931");
	// Not a barcode: refused before anyone is asked.
	assert.equal((await person.submit("/barcode", { barcode: "123" })).status, 422);
	assert.ok(!asked.some((each) => each.code === "123"));
});

test("a recipe: its ingredients make a food, and a serving is logged like one", { skip }, async () => {
	const person = app.client();
	await person.get("/recipes");
	const made = await person.post("/recipes", { name: "Overnight oats", servings: "2" });
	assert.equal(made.status, 303);
	const id = /^\/recipes\/(\d+)$/.exec(made.location)?.[1];
	assert.ok(id, made.location);
	const oats = await found(person, "cereals oats regular quick not fortified dry");
	const milk = await found(person, "milk reduced fat fluid 2% milkfat vitamin");
	await person.get(`/recipes/${id}`);
	assert.equal((await person.post(`/recipes/${id}/ingredients`, { food: oats.id, grams: "80" })).status, 303);
	assert.equal((await person.submit(`/recipes/${id}/ingredients`, { food: milk.id, grams: "300" })).status, 200);
	const kitchen = await person.read(`/recipes/${id}`);
	assert.deepEqual(kitchen.recipe.ingredients.map((each) => each.grams), [80, 300]);
	// Its food: what 100 g of the mix has, and a serving of half its weight.
	const pick = await person.read(`/foods/${kitchen.recipe.food}`);
	assert.equal(pick.food.source, "recipe");
	assert.equal(pick.food.recipe, id);
	assert.deepEqual(pick.food.portions, [{ label: "1 serving", grams: 190 }]);
	const whole = kitchen.recipe.ingredients.reduce((sum, each) => sum + each.nutrients.kcal, 0);
	assert.ok(Math.abs(pick.food.per100.kcal - (whole * 100) / 380) < 0.01);
	// Searches find it first, by its name.
	assert.equal((await person.read("/add?q=overnight")).hits[0].id, kitchen.recipe.food);
	// A search for an ingredient leaves the recipe itself out.
	assert.ok(!(await person.read(`/recipes/${id}?q=overnight`)).hits.some((hit) => hit.id === kitchen.recipe.food));
	// A serving, logged.
	const day = shifted(await today(person), -7);
	await person.submit(`/foods/${kitchen.recipe.food}`, { amount: "1", unit: "0", meal: "breakfast", day });
	const [entry] = (await person.read(`/days/${day}`)).entries;
	assert.equal(entry.name, "Overnight oats");
	assert.ok(Math.abs(entry.kcal - whole / 2) < 0.05);
	// An ingredient out, and the food follows; renamed, it follows too.
	await person.submit("/api/ingredients/delete", { id: kitchen.recipe.ingredients[1].id });
	assert.deepEqual((await person.read(`/foods/${kitchen.recipe.food}`)).food.portions, [{ label: "1 serving", grams: 40 }]);
	assert.equal((await person.submit(`/recipes/${id}`, { name: "Oats, soaked", servings: "1", notes: "Overnight, in the fridge." })).status, 200);
	assert.equal((await person.read(`/foods/${kitchen.recipe.food}`)).food.name, "Oats, soaked");
	// The list says what a serving has.
	const page = await person.get("/recipes");
	page.dom.getByRole("link", { name: /^Oats, soaked \d+ kcal a serving · 1 serving$/ });
	assert.equal((await person.get("/recipes/999999")).status, 404);
});

test("goals: the targets follow the profile, and a time zone it doesn't know is refused", { skip }, async () => {
	const person = app.client();
	const year = Number((await today(person)).slice(0, 4));
	await person.get("/goals");
	const saved = await person.post("/goals", { sex: "female", birth_year: String(year - 36), height_cm: "165", weight_kg: "62", activity: "light", goal: "keep", kcal_target: "", timezone: "Europe/Berlin" });
	assert.equal(saved.status, 303);
	// 10 × 62 + 6.25 × 165 − 5 × 36 − 161 = 1310.25 at rest, × 1.375 = 1801.6, so 1,800 kcal.
	assert.deepEqual((await person.read("/")).target, { kcal: 1800, protein: 113, carbs: 203, fat: 60 });
	const page = await person.get("/goals");
	page.dom.getByText("1,800");
	assert.equal(page.dom.getByLabelText("Time zone").attr("value"), "Europe/Berlin");
	// A target of your own wins.
	await person.submit("/goals", { sex: "female", birth_year: String(year - 36), height_cm: "165", weight_kg: "62", activity: "light", goal: "keep", kcal_target: "2222", timezone: "Europe/Berlin" });
	assert.equal((await person.read("/")).target.kcal, 2222);
	const zone = await person.submit("/goals", { sex: "female", birth_year: "1990", height_cm: "165", weight_kg: "62", activity: "light", goal: "keep", kcal_target: "", timezone: "Mars/Olympus" });
	assert.equal(zone.status, 422);
	assert.match(zone.text, /Not a time zone/);
	// Back to the start, for the other tests.
	await person.submit("/goals", { sex: "unsaid", birth_year: "1990", height_cm: "170", weight_kg: "70", activity: "light", goal: "keep", kcal_target: "", timezone: "UTC" });
});

test("trends: each day of the range, an average day, and weights", { skip }, async () => {
	const person = app.client();
	const now = await today(person);
	assert.equal((await person.submit("/weights", { day: shifted(now, -6), kg: "72.4" })).status, 200);
	await person.submit("/weights", { day: shifted(now, -5), kg: "72.1" });
	await person.submit("/weights", { day: now, kg: "71.8" });
	const week = await person.read("/trends");
	assert.equal(week.range, 7);
	assert.equal(week.totals.length, 7);
	assert.equal(week.totals.at(-1).day, now);
	assert.deepEqual(week.weights, [{ day: shifted(now, -6), kg: 72.4 }, { day: shifted(now, -5), kg: 72.1 }, { day: now, kg: 71.8 }]);
	// The latest weight is the profile's, which the targets are worked out from.
	assert.equal((await person.read("/goals")).profile.weight_kg, 71.8);
	assert.equal((await person.read("/trends?days=30")).totals.length, 30);
	assert.equal((await person.read("/trends?days=12")).range, 7);
	const page = await person.get("/trends?days=30");
	assert.equal(page.dom.getByRole("link", { name: "Month" }).attr("aria-current"), "page");
	page.dom.getByRole("group", { name: "Energy eaten each day, in kcal" });
	const short = (day) => new Date(`${day}T12:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
	page.dom.getByText("Down 0.6 kg since " + short(shifted(now, -6)));
	// Weight on its days, to scale: the day after the first is a sixth of the way across (48 to 620
	// of the chart's 640), not half, and the axis along the bottom names the days.
	const weight = page.dom.getByRole("img", { name: "Weight on the days it was logged, in kg" });
	const line = (function find(node) {
		return node.tag === "path" && node.hasClass("line") ? node : node.elements.map(find).find(Boolean);
	})(weight);
	assert.match(line.attr("d"), /^M48,[\d.]+C.* 143\.33,[\d.]+C.* 620,[\d.]+$/);
	assert.ok(weight.text.includes(short(shifted(now, -6))) && weight.text.includes(short(now)), weight.text);
	await person.submit("/weights", { day: now, kg: "70" });
});

test("with PLATE_PASSWORD set, the diary is for whoever signs in", { skip }, async () => {
	let locked = await startServer(built.server, { statics: built.statics, database: db.url, env: { PLATE_PASSWORD: "open sesame" } });
	try {
		const person = locked.client();
		const asked = await person.get("/trends?days=30");
		assert.equal(asked.status, 303);
		assert.equal(asked.location, "/sign-in?then=%2Ftrends%3Fdays%3D30");
		assert.equal((await person.read("/").catch((error) => error.status)), 401);
		await person.get("/sign-in");
		await person.post("/sign-in", { password: "sesame", then: "/trends?days=30" });
		assert.equal(person.flash.status, 422);
		assert.ok(!person.cookies.has("plate_session"), "no session for a wrong password");
		const signed = await person.post("/sign-in", { password: "open sesame", then: "/trends?days=30" });
		assert.equal(signed.status, 303);
		assert.equal(signed.location, "/trends?days=30");
		assert.equal((await person.get("/trends?days=30")).status, 200);
		// The session is packages/auth's: a random token in the `plate_session` cookie, for 90 days,
		// and a row in `auth_sessions` that keeps the token's hash, not the token.
		const token = person.cookies.get("plate_session");
		assert.match(token, /^[A-Za-z0-9_-]{43}$/);
		const [session] = await db.sql`select id, user_id, created_at, expires_at from auth_sessions order by created_at desc limit 1`;
		assert.equal(session.user_id, "me");
		assert.match(session.id, /^[A-Za-z0-9_-]{43}$/);
		assert.notEqual(session.id, token);
		assert.equal(Number(session.expires_at) - Number(session.created_at), 90 * 24 * 60 * 60 * 1000);
		assert.match(signed.headers.getSetCookie().find((cookie) => cookie.startsWith("plate_session=")), /Max-Age=7776000.*HttpOnly.*SameSite=Lax/);
		// Plate's own table of sessions is gone (0003_auth_sessions.sql).
		assert.deepEqual(await db.sql`select name from sqlite_master where type = 'table' and name = 'sessions'`, []);
		// A `then` off the site goes home.
		const elsewhere = locked.client();
		await elsewhere.get("/sign-in");
		assert.equal((await elsewhere.post("/sign-in", { password: "open sesame", then: "//example.com/" })).location, "/");
		// The session outlives a restart: it is in the database.
		await locked.stop();
		locked = await startServer(built.server, { statics: built.statics, database: db.url, env: { PLATE_PASSWORD: "open sesame" } });
		const back = locked.client();
		back.cookies.set("plate_session", token);
		assert.equal((await back.get("/trends?days=30")).status, 200);
		// Signed out, from the goals page's button (a form posting to packages/auth's /auth/sign-out):
		// back to signing in, the session's row gone, and its cookie signs nobody in.
		const goals = await back.get("/goals");
		goals.dom.getByRole("button", { name: "Sign out" });
		assert.match(goals.text, /<form[^>]* method="post" action="\/auth\/sign-out"><input[^>]* type="hidden" name="then" value="\/sign-in">/);
		const out = await back.post("/auth/sign-out", { then: "/sign-in" });
		assert.equal(out.status, 303);
		assert.equal(out.location, "/sign-in");
		assert.ok(!back.cookies.has("plate_session"), "the cookie cleared");
		assert.deepEqual(await db.sql`select id from auth_sessions where id = ${session.id}`, []);
		assert.equal((await back.get("/")).status, 303);
		const stale = locked.client();
		stale.cookies.set("plate_session", token);
		assert.equal((await stale.get("/")).status, 303);
		// Signing out without a session (one that ran out, say) still lands on signing in.
		assert.equal((await locked.client().post("/auth/sign-out", { then: "/sign-in" })).location, "/sign-in");
	} finally {
		await locked.stop();
	}
	// Without it, there's nothing to sign in to.
	assert.equal((await app.client().get("/")).status, 200);
});

// ---- In a browser ----

/** Waits for the tab to have gone to `path` (a link followed, a form's redirect) and hydrated there. */
function landed(tab, path) {
	return until(
		async () => {
			try {
				return (await tab.page.eval("location.pathname + location.search")).startsWith(path) && (await tab.page.eval("Boolean(window.__rocxReady)"));
			} catch {
				return false;
			}
		},
		{ what: `the page at ${path}` },
	);
}

test("in a browser: a search follows the typing, and a food is logged with its preview", { skip }, async (t) => {
	if (!browser) return t.skip("no Chromium");
	const bananas = await found(app.client(), "bananas raw");
	const portion = (await app.client().read(`/foods/${bananas.id}`)).food.portions[0];
	const tab = await browser.open(`${app.url}/add?meal=snacks`);
	const search = await tab.getByLabelText("Search foods");
	await search.fill("bananas raw");
	// The results follow the typing: the food the endpoint finds first is among them.
	const to = (link) => link.attr("href").startsWith(`/foods/${bananas.id}?`);
	await tab.waitFor((dom) => dom.queryAllByRole("link", { name: /^Bananas, raw/ }).some(to));
	const link = (await tab.getAllByRole("link", { name: /^Bananas, raw/ })).find(to);
	assert.match(link.attr("href"), new RegExp(`^/foods/${bananas.id}\\?day=\\d{4}-\\d\\d-\\d\\d&meal=snacks$`));
	await link.click();
	await landed(tab, `/foods/${bananas.id}`);
	await tab.findByRole("heading", { level: 1, name: /^Bananas, raw/ });
	const amount = await tab.getByLabelText("Amount");
	await amount.fill("2");
	// The preview follows the amount, worked out in the browser.
	const grams = Math.round(2 * portion.grams);
	await tab.findByText(new RegExp(`^in ${grams.toLocaleString("en-US")} g · protein`));
	await (await tab.getByRole("button", { name: "Add to Snacks" })).click();
	await landed(tab, "/");
	await tab.findByRole("heading", { level: 1, name: "Today" });
	await tab.findByRole("link", { name: /^Bananas, raw/ });
	const rows = await db.sql`select amount from entries where name = 'Bananas, raw' and meal = 'snacks' and day = ${await today(app.client())}`;
	assert.equal(rows.length, 1);
	assert.match(rows[0].amount, /^2 × /);
	assert.deepEqual(tab.errors, []);
	await tab.close();
});

test("in a browser: an entry taken off goes at once, and from the database", { skip }, async (t) => {
	if (!browser) return t.skip("no Chromium");
	const person = app.client();
	const now = await today(person);
	const pear = await found(person, "pears raw");
	await person.submit(`/foods/${pear.id}`, { amount: "1", unit: "0", meal: "dinner", day: now });
	const tab = await browser.open(`${app.url}/`);
	const remove = await tab.findByRole("button", { name: /^Remove Pears, raw/ });
	await remove.click();
	await tab.waitFor((dom) => !dom.queryByRole("button", { name: /^Remove Pears, raw/ }));
	await until(async () => (await db.sql`select id from entries where name like 'Pears, raw%' and day = ${now}`).length === 0, { what: "the entry gone from the database" });
	// Sent by the runtime with fetch: the page didn't load again.
	await until(async () => (await tab.requested()).includes("/api/entries/delete"), { what: "the runtime's post" });
	assert.deepEqual(tab.errors, []);
	await tab.close();
});
