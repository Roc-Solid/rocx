-- Plate's tables. The server applies each file in migrations/ once, in the order of their
-- names, when it starts (rocx build embeds them; the server records each in rocx_migrations).

-- Every food the diary can log, each with what 100 g of it has. They come from USDA FoodData
-- Central (0002_usda_foods.sql, source 'usda', source_id its FDC id), from Open Food Facts when a
-- barcode is looked up (source 'off', source_id the barcode), from the food form ('mine'), and from
-- recipes ('recipe': what 100 g of the mix has, kept up to date as its ingredients change).
-- Energy and the three macronutrients are always known; the four below them may not be (null).
create table foods (
	id bigserial primary key,
	source text not null check (source in ('usda', 'off', 'mine', 'recipe')),
	source_id text not null default '',
	name text not null,
	brand text not null default '',
	food_group text not null default '',
	barcode text,
	kcal numeric(8, 2) not null check (kcal >= 0),
	protein numeric(8, 2) not null check (protein >= 0),
	carbs numeric(8, 2) not null check (carbs >= 0),
	fat numeric(8, 2) not null check (fat >= 0),
	fiber numeric(8, 2),
	sugars numeric(8, 2),
	sat_fat numeric(8, 2),
	sodium numeric(9, 2), -- in mg
	-- The words a search matches: the name and the brand, each word's start ('chick' finds chicken).
	words tsvector generated always as (to_tsvector('simple', name || ' ' || brand)) stored,
	created_at timestamptz not null default now()
);

create index foods_by_words on foods using gin (words);
create unique index foods_by_barcode on foods (barcode) where barcode is not null;

-- What a measure of a food weighs: "1 cup, chopped" is 76 g.
create table portions (
	id bigserial primary key,
	food_id bigint not null references foods (id) on delete cascade,
	label text not null,
	grams numeric(9, 2) not null check (grams > 0),
	position integer not null default 0
);

create index portions_by_food on portions (food_id, position);

-- A recipe: its name, how many servings it makes, and the food that logs it (source 'recipe', with
-- one portion, "1 serving").
create table recipes (
	id bigserial primary key,
	food_id bigint not null unique references foods (id),
	name text not null,
	servings integer not null check (servings > 0),
	notes text not null default '',
	created_at timestamptz not null default now()
);

-- What goes into a recipe, and how much.
create table ingredients (
	id bigserial primary key,
	recipe_id bigint not null references recipes (id) on delete cascade,
	food_id bigint not null references foods (id),
	grams numeric(9, 2) not null check (grams > 0),
	position integer not null default 0
);

create index ingredients_by_recipe on ingredients (recipe_id, position);

-- The diary: what was eaten, on which day, at which meal. Each entry keeps what it had when it was
-- logged (name, amount, energy, macronutrients), so a food changed or deleted later doesn't change
-- a past day; `food_id` is null once its food is gone.
create table entries (
	id bigserial primary key,
	day date not null,
	meal text not null check (meal in ('breakfast', 'lunch', 'dinner', 'snacks')),
	food_id bigint references foods (id) on delete set null,
	name text not null,
	amount text not null,
	grams numeric(9, 2) not null,
	kcal numeric(9, 2) not null,
	protein numeric(9, 2) not null,
	carbs numeric(9, 2) not null,
	fat numeric(9, 2) not null,
	created_at timestamptz not null default now()
);

create index entries_by_day on entries (day, meal, id);
create index entries_by_food on entries (food_id, created_at desc);

-- Who the targets are for: one row. `kcal_target` 0 means "work it out".
create table profile (
	id integer primary key default 1 check (id = 1),
	sex text not null default 'unsaid',
	birth_year integer not null default 1990,
	height_cm numeric(5, 1) not null default 170,
	weight_kg numeric(5, 1) not null default 70,
	activity text not null default 'light',
	goal text not null default 'keep',
	kcal_target numeric(6, 0) not null default 0,
	timezone text not null default 'UTC'
);

insert into profile (id) values (1) on conflict do nothing;

-- Weights over time, one a day.
create table weights (
	day date primary key,
	kg numeric(5, 1) not null check (kg > 0)
);

-- Signed-in browsers, when PLATE_PASSWORD is set: each token's SHA-256, so the table alone can't
-- sign anyone in.
create table sessions (
	token_hash text primary key,
	expires_at timestamptz not null
);
