-- Plate's tables, in SQLite (the app's database is a file: `database: Sqlite("data/plate.db")`).
-- The server applies each file in migrations/ once, in the order of their names, when it starts
-- (rocx build embeds them; the server records each in rocx_migrations). Amounts are `real`; a day
-- is its date as text (`2026-11-22`), which sorts as days do; a moment is milliseconds since the
-- epoch.

-- Every food the diary can log, each with what 100 g of it has. They come from USDA FoodData
-- Central (0002_usda_foods.sql, source 'usda', source_id its FDC id), from Open Food Facts when a
-- barcode is looked up (source 'off', source_id the barcode), from the food form ('mine'), and from
-- recipes ('recipe': what 100 g of the mix has, kept up to date as its ingredients change).
-- Energy and the three macronutrients are always known; the four below them may not be (null).
create table foods (
	id integer primary key,
	source text not null check (source in ('usda', 'off', 'mine', 'recipe')),
	source_id text not null default '',
	name text not null,
	brand text not null default '',
	food_group text not null default '',
	barcode text,
	kcal real not null check (kcal >= 0),
	protein real not null check (protein >= 0),
	carbs real not null check (carbs >= 0),
	fat real not null check (fat >= 0),
	fiber real,
	sugars real,
	sat_fat real,
	sodium real, -- in mg
	created_at integer not null default (cast(unixepoch('subsec') * 1000 as integer))
);

create unique index foods_by_barcode on foods (barcode) where barcode is not null;

-- The words a search matches: each food's name and brand, in a full-text index (FTS5) that the
-- triggers keep in step with `foods`. A search asks for each word's start ('chick' finds chicken),
-- in any case, accents or not.
create virtual table food_words using fts5 (name, brand, content = 'foods', content_rowid = 'id');

create trigger foods_words_added after insert on foods begin
	insert into food_words (rowid, name, brand) values (new.id, new.name, new.brand);
end;

create trigger foods_words_removed after delete on foods begin
	insert into food_words (food_words, rowid, name, brand) values ('delete', old.id, old.name, old.brand);
end;

create trigger foods_words_changed after update of name, brand on foods begin
	insert into food_words (food_words, rowid, name, brand) values ('delete', old.id, old.name, old.brand);
	insert into food_words (rowid, name, brand) values (new.id, new.name, new.brand);
end;

-- What a measure of a food weighs: "1 cup, chopped" is 76 g.
create table portions (
	id integer primary key,
	food_id integer not null references foods (id) on delete cascade,
	label text not null,
	grams real not null check (grams > 0),
	position integer not null default 0
);

create index portions_by_food on portions (food_id, position);

-- A recipe: its name, how many servings it makes, and the food that logs it (source 'recipe', with
-- one portion, "1 serving").
create table recipes (
	id integer primary key,
	food_id integer not null unique references foods (id),
	name text not null,
	servings integer not null check (servings > 0),
	notes text not null default '',
	created_at integer not null default (cast(unixepoch('subsec') * 1000 as integer))
);

-- What goes into a recipe, and how much.
create table ingredients (
	id integer primary key,
	recipe_id integer not null references recipes (id) on delete cascade,
	food_id integer not null references foods (id),
	grams real not null check (grams > 0),
	position integer not null default 0
);

create index ingredients_by_recipe on ingredients (recipe_id, position);

-- The diary: what was eaten, on which day, at which meal. Each entry keeps what it had when it was
-- logged (name, amount, energy, macronutrients), so a food changed or deleted later doesn't change
-- a past day; `food_id` is null once its food is gone.
create table entries (
	id integer primary key,
	day text not null,
	meal text not null check (meal in ('breakfast', 'lunch', 'dinner', 'snacks')),
	food_id integer references foods (id) on delete set null,
	name text not null,
	amount text not null,
	grams real not null,
	kcal real not null,
	protein real not null,
	carbs real not null,
	fat real not null,
	created_at integer not null default (cast(unixepoch('subsec') * 1000 as integer))
);

create index entries_by_day on entries (day, meal, id);
create index entries_by_food on entries (food_id, created_at desc);

-- Who the targets are for: one row. `kcal_target` 0 means "work it out".
create table profile (
	id integer primary key default 1 check (id = 1),
	sex text not null default 'unsaid',
	birth_year integer not null default 1990,
	height_cm real not null default 170,
	weight_kg real not null default 70,
	activity text not null default 'light',
	goal text not null default 'keep',
	kcal_target real not null default 0,
	timezone text not null default 'UTC'
);

insert into profile (id) values (1) on conflict do nothing;

-- Weights over time, one a day.
create table weights (
	day text primary key,
	kg real not null check (kg > 0)
);

-- Signed-in browsers, when PLATE_PASSWORD is set: each token's SHA-256, so the table alone can't
-- sign anyone in, and when it runs out (milliseconds since the epoch).
create table sessions (
	token_hash text primary key,
	expires_at integer not null
);
