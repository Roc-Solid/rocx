-- The app's tables, in SQLite (the app's database is a file: `database: Sqlite("data/tasks.db")`).
-- The server applies each file in migrations/ once, in the order of their names, when it starts
-- (rocx build embeds them; the server records each in rocx_migrations). A day is its date as text
-- (`2026-11-24`), which sorts as days do; a moment is milliseconds since the epoch.

-- The people on the team. There is no sign-in: you say which of them you are (/me), and a session
-- keeps it (packages/auth's table, auth_sessions).
create table people (
	id text primary key, -- a short handle, the session's user: 'avery'
	name text not null
);

-- The lists, each with its tasks.
create table lists (
	id integer primary key,
	name text not null,
	created_at integer not null default (cast(unixepoch('subsec') * 1000 as integer))
);

-- The tasks. `due` and `assignee` may be null: Store reads them as Db.Nullable(Str). `done` is
-- declared boolean, so Db reads it as a Bool (SQLite keeps it as 1 or 0).
create table tasks (
	id integer primary key,
	list_id integer not null references lists (id) on delete cascade,
	title text not null,
	notes text not null default '',
	due text,
	assignee text references people (id) on delete set null,
	done boolean not null default false,
	position integer not null, -- the task's place on its list, from 0
	created_at integer not null default (cast(unixepoch('subsec') * 1000 as integer))
);

create index tasks_by_list on tasks (list_id, position);
