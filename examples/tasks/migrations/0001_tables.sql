-- Acme Tasks' tables. The server applies each file in migrations/ once, in the order of their
-- names, when it starts (rocx build embeds them; the server records each in rocx_migrations).

-- The people on the team. There is no sign-in: you say which of them you are (/me), and a cookie
-- keeps it.
create table people (
	id text primary key, -- a short handle, which the cookie holds: 'avery'
	name text not null
);

-- The lists, each with its tasks.
create table lists (
	id bigserial primary key,
	name text not null,
	created_at timestamptz not null default now()
);

-- The tasks. `due` and `assignee` may be null: Store reads them as Db.Nullable(Str).
create table tasks (
	id bigserial primary key,
	list_id bigint not null references lists (id) on delete cascade,
	title text not null,
	notes text not null default '',
	due date,
	assignee text references people (id) on delete set null,
	done boolean not null default false,
	position integer not null, -- the task's place on its list, from 0
	created_at timestamptz not null default now()
);

create index tasks_by_list on tasks (list_id, position);
