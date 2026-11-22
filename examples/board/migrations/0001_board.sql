-- Board's tables. Ranks (Rank.roc) sort byte by byte, so they are text in the "C" collation,
-- whatever the database's own is.

create table people (
	id bigserial primary key,
	name text not null check (length(name) between 1 and 40),
	color text not null,
	created_at timestamptz not null default now()
);

-- One person per name, whatever its case: joining as "ada" is joining as Ada.
create unique index people_name on people (lower(name));

create table boards (
	id bigserial primary key,
	slug text not null unique,
	name text not null
);

create table columns (
	id bigserial primary key,
	board_id bigint not null references boards on delete cascade,
	name text not null check (length(name) between 1 and 60),
	rank text collate "C" not null
);

create table cards (
	id bigserial primary key,
	board_id bigint not null references boards on delete cascade,
	column_id bigint not null references columns on delete cascade,
	rank text collate "C" not null,
	title text not null check (length(title) between 1 and 200),
	description text not null default '',
	labels jsonb not null default '[]',
	assignee_id bigint references people on delete set null,
	due date,
	archived boolean not null default false,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now()
);

-- No two cards in a column share a rank: moves into a column take turns (Store.move!), and this
-- says so to anything that doesn't.
create unique index cards_place on cards (column_id, rank);

create table checklist_items (
	id bigserial primary key,
	card_id bigint not null references cards on delete cascade,
	text text not null check (length(text) between 1 and 200),
	done boolean not null default false
);

create index checklist_items_card on checklist_items (card_id);
