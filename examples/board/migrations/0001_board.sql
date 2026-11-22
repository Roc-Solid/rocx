-- Board's tables, in SQLite (the app's database is a file: `database: Sqlite("data/board.db")`).
-- Ranks (Rank.roc) sort byte by byte, which SQLite's own collation (binary) does. A day is its
-- date as text (`2026-11-30`); a moment is milliseconds since the epoch.

create table people (
	id integer primary key,
	name text not null check (length(name) between 1 and 40),
	color text not null,
	created_at integer not null default (cast(unixepoch('subsec') * 1000 as integer))
);

-- One person per name, whatever its case: joining as "ada" is joining as Ada. (SQLite's lower()
-- folds ASCII letters alone, so "Åsa" and "åsa" are two people.)
create unique index people_name on people (lower(name));

create table boards (
	id integer primary key,
	slug text not null unique,
	name text not null
);

create table columns (
	id integer primary key,
	board_id integer not null references boards on delete cascade,
	name text not null check (length(name) between 1 and 60),
	rank text not null
);

-- A card's labels are a JSON list of their names (declared json, so Db reads the list).
create table cards (
	id integer primary key,
	board_id integer not null references boards on delete cascade,
	column_id integer not null references columns on delete cascade,
	rank text not null,
	title text not null check (length(title) between 1 and 200),
	description text not null default '',
	labels json not null default '[]',
	assignee_id integer references people on delete set null,
	due text,
	archived boolean not null default false,
	created_at integer not null default (cast(unixepoch('subsec') * 1000 as integer)),
	updated_at integer not null default (cast(unixepoch('subsec') * 1000 as integer))
);

-- No two cards in a column share a rank: moves into a column take turns (Store.move!), and this
-- says so to anything that doesn't.
create unique index cards_place on cards (column_id, rank);

create table checklist_items (
	id integer primary key,
	card_id integer not null references cards on delete cascade,
	text text not null check (length(text) between 1 and 200),
	done boolean not null default false
);

create index checklist_items_card on checklist_items (card_id);
