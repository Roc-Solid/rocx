# Plate

A food diary, built with Roc Solid. You log what you eat to a day's four meals, and see the day's
energy against a target, with protein, carbohydrate and fat beside it. Foods come from three places:
the USDA's reference foods (about 7,500, seeded into its SQLite file), packets looked up by their
barcode in Open Food Facts, and foods you make yourself from a label. Recipes are made from foods
and logged like one. Your target is worked out from a profile, and the trends page charts the days
and your weight.

It is meant to be used, on a phone above all: the sections are tabs along the bottom on a narrow
screen, every control is big enough for a thumb, and everything works without JavaScript too. Read
it to see a search that follows the typing, another service called from the server, rules shared by
the server and the browser, and a phone-first layout.

## Run it

From the repository's root, after `just setup`:

```sh
cd examples/plate
../../bin/rocx dev    # http://localhost:8080
```

`rocx dev` builds the app (its server, and its browser half as wasm), serves it under `--dev`, and
builds it again each time you save a file. The diary is a SQLite file, `data/plate.db`
(`database: Sqlite("data/plate.db")` in `main.roc`). The path is relative to the folder the server
starts in, which is why you start `rocx dev` in `examples/plate`. `*.db` files are gitignored.

The first start makes the file and its tables, and seeds the foods. Set your profile on Goals (the
time zone above all), then log your first meal. Two settings come from the environment:

- `PLATE_PASSWORD=…`: the diary asks for it once a browser, which then stays signed in for 90 days,
  and on while you keep using it. Set it whenever the server can be reached from anywhere but your
  own machine.
- `OFF_URL=…`: where Open Food Facts is asked (the tests point it at a stand-in). The real one
  otherwise.

For example, `PLATE_PASSWORD=apple ../../bin/rocx dev`. To keep the file elsewhere (on a volume,
say), pass the server an option after `--`: `../../bin/rocx dev -- --database-url sqlite:/tmp/plate.db`.
To back the diary up, copy `data/plate.db` with the server stopped, or run
`sqlite3 data/plate.db ".backup copy.db"`.

### Build it by hand

To build each piece yourself, run these from the repository's root. The browser's wasm is
optimized for size here, as the docs' examples page measures it:

```sh
just web-host     # the browser platform's host, once (rocx dev builds it too)
bin/rocx build examples/plate --client examples/plate/build/client
.tools/roc-active build --target=wasm32 --opt=size --output=examples/plate/build/client/static/rocx/app.wasm examples/plate/build/client/main.roc
node server/build.mjs examples/plate/main.roc examples/plate/build/plate
cd examples/plate && build/plate --port 18190 --static build/client/static
```

Then open http://localhost:18190.

## A tour

1. **`/`**, today. A ring shows the energy eaten against the target ("860 kcal left", red once it
   is past it), with a bar for each macronutrient. Below are the four meals, each with what was
   eaten (its amount, its energy) and a button that takes it off. The arrows go to the day before
   and after (`/days/2026-11-21`).
2. **Add to Lunch** (`/add?day=…&meal=lunch`): a search of every food, which follows the typing.
   Words match from their start, in any order ("chick brea" finds chicken breast). Foods you've
   logged come first, then your recipes and foods, then the plainest names. Before a search, it
   lists the foods logged lately. The chips at the top switch the meal.
3. **A food** (`/foods/:id`): how much (a count of one of its portions, such as "1 cup, chopped",
   or grams), which meal and which day. As you type, it works out what that amount has. Below are
   its nutrition facts, per 100 g and for the amount, and where its data came from, with a link to
   it there.
4. **Barcode** (`/barcode`): type the digits under a packet's lines. One the diary has is found at
   once. Any other is asked of Open Food Facts, once, and kept as a food. If Open Food Facts doesn't
   know it, the page offers to make the food yourself, with the barcode filled in.
5. **Make a food** (`/foods/new`): as its label says it, per 100 g or per serving, with fibre,
   sugars, saturated fat and sodium if the label gives them, its serving, and its barcode.
6. **Recipes** (`/recipes`): a recipe's ingredients (searched for and added on its page, in grams),
   how many servings they make, and what a serving has. A recipe is a food too (its source is
   `recipe`), kept up to date as its ingredients change, so you log a serving as you log any food.
7. **Goals** (`/goals`): your sex, year of birth, height, weight, how active you are and your goal
   give the energy for a day. A target of your own wins. The targets follow the form as you change
   it. The time zone says when your day starts.
8. **Trends** (`/trends?days=30`): the energy of each day of the last week, month or three months
   (a bar a week, for three months), the average day against the targets, and your weight, with a
   form that logs it. The latest weight becomes the profile's.

## Where the foods come from

- **[USDA FoodData Central](https://fdc.nal.usda.gov/)**, public domain (CC0): SR Legacy (2018),
  the classic reference of about 7,800 foods, and Foundation Foods (2026-10), newer analyses of a
  few hundred. [`migrations/0002_usda_foods.sql`](migrations/0002_usda_foods.sql) has them,
  generated by [`data/usda.mjs`](data/usda.mjs) (its header says how to run it again). For each
  food it keeps the name, the group, what 100 g has (energy, protein, carbohydrate, fat; fibre,
  sugars, saturated fat and sodium where the data has them) and its portions. Baby foods and the
  American Indian/Alaska Native foods are left out, and each name is kept once. The file is 1.5 MB
  of SQL, which the server applies on its first start.
- **[Open Food Facts](https://world.openfoodfacts.org/)**, under the
  [Open Database License](https://opendatacommons.org/licenses/odbl/1-0/): packaged foods, by
  barcode, asked for one at a time (`GET /api/v2/product/<barcode>`, with a `User-Agent` that names
  the app). A food from there says so on its page, and links to the product. Its limit (100 product
  reads a minute) is never near: each barcode is asked for once, and kept.
- **You**: foods made from a label, and recipes.

## What it shows

Each row names a feature and the file to read for it. Paths are from `examples/plate/`.

### Pages and components

| Feature | Where |
|---|---|
| A layout with the sections as tabs (along the bottom on a phone), and an error page | [`routes/+layout.rocx`](routes/+layout.rocx), [`routes/+error.rocx`](routes/+error.rocx) |
| One component for two routes: today at `/`, and any day at `/days/:day` | [`components/Diary.rocx`](components/Diary.rocx), [`routes/+page.rocx`](routes/+page.rocx), [`routes/days/[day]/+page.rocx`](routes/days/[day]/+page.rocx) |
| A page's own 404 when what it shows isn't there (`<HttpStatusCode code={404} />`): a day, a food or a recipe | [`routes/days/[day]/+page.rocx`](routes/days/[day]/+page.rocx), [`routes/foods/[id]/+page.rocx`](routes/foods/[id]/+page.rocx), [`routes/recipes/[id]/+page.rocx`](routes/recipes/[id]/+page.rocx) |
| A search that follows the typing: a signal holds the words, and a memo reads the endpoint with them (`Endpoint.with_query`). `is_pending!` dims the results while new ones are read. Without JavaScript it is a plain `GET` form | [`routes/add/+page.rocx`](routes/add/+page.rocx), [`routes/recipes/[id]/+page.rocx`](routes/recipes/[id]/+page.rocx) |
| A form whose result is worked out as you type, by the same function the server uses | [`routes/foods/[id]/+page.rocx`](routes/foods/[id]/+page.rocx) (the preview), [`routes/goals/+page.rocx`](routes/goals/+page.rocx) (the targets) |
| A form's starting values read once, on purpose (`untrack!`), and a row per position (`.map_with_index(\|portion, index\| <option key={index} …>)`) | [`routes/foods/[id]/+page.rocx`](routes/foods/[id]/+page.rocx) |
| Optimistic removal (`use_submissions!`): an entry or an ingredient goes at once. Entries are keyed rows that fade in and out (`transition:in`, `transition:out`) | [`components/Diary.rocx`](components/Diary.rocx), [`components/MealPart.rocx`](components/MealPart.rocx), [`routes/recipes/[id]/+page.rocx`](routes/recipes/[id]/+page.rocx) |
| Charts from packages/charts: energy each day (`BarChart`), weight on the days it was logged, each to scale (`LineChart`, a day a number: `Plate.weight_points`, `Plate.day_at`), in the app's colours | [`routes/trends/+page.rocx`](routes/trends/+page.rocx) |
| An SVG ring drawn from data (`stroke-dasharray`), and bars sized by a CSS variable (`style:--share`) | [`components/Summary.rocx`](components/Summary.rocx) |
| Pure components (`view`): `Summary` and `HitRow` have stories and expects, `Facts` has expects | [`components/Summary.rocx`](components/Summary.rocx), [`components/HitRow.rocx`](components/HitRow.rocx), [`components/Facts.rocx`](components/Facts.rocx) |

### Data and rules

| Feature | Where |
|---|---|
| SQLite in the server's process: a file beside it, no database server | [`main.roc`](main.roc), [`migrations/0001_tables.sql`](migrations/0001_tables.sql) |
| Full-text search by each word's start (SQLite's FTS5, `"chick"* "brea"*`), kept in step with the foods by triggers, and ranked by use | [`Store.roc`](Store.roc) (`search!`, `words`), [`migrations/0001_tables.sql`](migrations/0001_tables.sql) |
| A seed generated from open data, shipped as a migration | [`data/usda.mjs`](data/usda.mjs), [`migrations/`](migrations) |
| Rules written once and run on both sides: amounts, totals, recipes, targets (Mifflin–St Jeor), the words for days and numbers | [`Plate.roc`](Plate.roc), with its expects |
| Forms with packages/forms: decimals, choices, days, optional fields, checks across fields (`check_at`), a pattern (`Matches`) | [`PlateForm.roc`](PlateForm.roc) |
| An entry that keeps what it had when it was logged, so a food changed later doesn't change a past day | [`Store.roc`](Store.roc) (`log!`), [`migrations/0001_tables.sql`](migrations/0001_tables.sql) |
| A recipe kept as a food: what 100 g of the mix has, and a serving's weight, worked out in one transaction with each change | [`Store.roc`](Store.roc) (`mix!`) |
| A time zone the day starts in: its offset from the platform (`Time.offset!`), the day from SQLite's `date(…, 'unixepoch')` | [`Store.roc`](Store.roc) (`local_now!`, `today!`, `hour!`) |

### The server

| Feature | Where |
|---|---|
| `Http.fetch!` to another service, its JSON read a field at a time (packages/tools' `JsonValue`), and the result kept | [`OpenFoodFacts.roc`](OpenFoodFacts.roc), [`routes/barcode/+server.roc`](routes/barcode/+server.roc) |
| A stand-in for that service in the tests, through `OFF_URL` | [`test/plate.test.mjs`](test/plate.test.mjs) |
| A password, only when one is set (`PLATE_PASSWORD`), compared in constant time; wrong ones are limited with a `Kv` counter. The session is packages/auth's (`Auth.sign_in!`; the plugin is listed without `admit!`, so nobody signs in by a link or a provider): a random token in the `plate_session` cookie (`__Host-plate_session` and `Secure` when the public URL is HTTPS), kept as its hash in the database (`auth_sessions`) for 90 days and renewed while it is used. The middleware lets everything through when the diary is open, and is `Auth.required` otherwise: a browser without a session goes to sign in, and back to where it was going after. Signing out is a form posting to the plugin's `/auth/sign-out` | [`main.roc`](main.roc), [`Session.roc`](Session.roc), [`Middlewares.roc`](Middlewares.roc), [`routes/sign-in/`](routes/sign-in), [`migrations/0003_auth_sessions.sql`](migrations/0003_auth_sessions.sql) |

## Test it

```sh
just examples plate                                                # build, type-check, lint, check the SQL, run the expects and the tests
bin/rocx fmt --check examples/plate                                # the formatting
bin/rocx check examples/plate                                      # build, then type-check both programs
bin/rocx check -- .tools/roc-active test examples/plate/main.roc   # the expects (after a build)
node --test 'examples/plate/test/*.test.mjs'                       # HTTP and browser tests
```

The node tests in [`test/plate.test.mjs`](test/plate.test.mjs) build the app, start it on a SQLite
file of their own, and point it at a stand-in for Open Food Facts on a local port, so no test leaves
the machine.

Over HTTP, they cover:

- the seed and the search (each word's start, in any order, with the search syntax kept out);
- a food's page;
- logging without JavaScript (a 303 to the day, the amount from a portion or from grams, an entry
  that keeps its numbers when its food changes), and refused (the plain form's flash, the runtime's
  422);
- a day's totals and the days either side, and taking an entry off;
- a food of your own (per 100 g, found first, its barcode taken);
- a barcode asked of the stand-in once and kept, and one it doesn't know;
- a recipe (its food, its serving, logged, changed);
- goals (the targets, and a time zone refused), trends and weights, and the password: signing
  in, the session's row in `auth_sessions` (the token's hash, 90 days), a session that outlives a
  restart, and signing out at `/auth/sign-out`.

In Chromium (skipped when there is none): a search that follows the typing, a food's preview as its
amount is typed, logging it, and an entry taken off at once.

## Product calls

- **One diary, no accounts.** It is yours: on your machine it is open; anywhere else, set a
  password. Several people would each run their own.
- **Sessions are packages/auth's.** The diary kept its own table of sessions (`sessions`) until
  it moved onto the package; `migrations/0003_auth_sessions.sql` drops that table, so a browser
  signed in before signs in once more, and nothing else in the diary changes.
- **An entry keeps what it had.** Editing a food (or a recipe's ingredients) changes what you log
  next, never a past day.
- **Energy and three macronutrients are tracked.** Fibre, sugars, saturated fat and sodium are on
  a food's page when its data has them, but not added up: too many foods don't say.
- **What isn't known isn't 0.** A food whose data doesn't give a nutrient doesn't list it.
- **Grams under the hood.** An amount is a count of a portion or grams. It is kept as grams, with
  the words it was said in ("2 × 1 medium").
- **Targets are an estimate.** Mifflin–St Jeor, times an activity factor, ±250 or 500 kcal for a
  goal, never under 1,200; 25% protein, 45% carbohydrate, 30% fat. The goals page says so, and a
  number of your own wins.
- **A barcode is typed, for now.** See below.

## What it asked of the platform

What the platform didn't do, or did in a way an app has to know about, and what the app does
instead. None of it needed a change to the platform.

1. **Db has no decimal value.** `Db.Value` is `Null`, `Text`, `Int` and `Bool`, so a `Dec` goes to
   SQLite as text, which a `real` column takes as its number (`dec` in `Store.roc`). Reading back
   is simpler: SQLite's `real` comes as a JSON number, which a `Dec` field reads as written. A
   `Dec` value in `Db.Value` would remove the text step.
2. **Bulk imports can't be done by the app.** `Http.fetch!` holds a whole answer in memory (64 MiB
   at most, by default). `Http.fetch_chunks!` hands a body over a chunk at a time, but nothing
   unpacks zip or gzip, so neither the USDA's downloads (zipped CSV) nor Open Food Facts' dump
   (gigabytes of gzipped JSON lines) can be imported by a job. The USDA's foods are a seed that a
   Node script generates instead, and Open Food Facts is asked one barcode at a time. A gzip reader
   would let a job keep a country's packets up to date.
3. **No camera.** A barcode is typed. Scanning one needs the camera and a decoder.
   `BarcodeDetector` is in Chromium and on Android, but not in Firefox, so it would be a JavaScript
   or WebAssembly decoder called through `Browser.call!`, or the camera of a native phone app.
4. **No installing it, and nothing offline.** On a phone it is a web page: no icon on the home
   screen, and no way to log a meal on a plane.
5. **Roc, met on the way:**
    - `targets`, `has` and `with` are reserved: they can't name a field, a local or a definition.
    - A local or a lambda's argument can't share a name with a definition of its module (`grams`,
      `words`, `whole`, `sum`, `food`, `value`, `name`).
    - `Paths` has pages only, so a form posting to an endpoint that has no page names it with
      `Endpoint.url_of(Api.post_api_entries_delete({}))`.
