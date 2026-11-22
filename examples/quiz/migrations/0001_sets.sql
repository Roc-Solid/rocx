-- Question sets and their questions, in SQLite (the app's database is a file:
-- `database: Sqlite("data/quiz.db")`). A set's `slug` names the ones this app seeds (0002), so that
-- seeding twice changes nothing; sets made in the editor have none. A moment is milliseconds since
-- the epoch.
create table if not exists quiz_sets (
	id integer primary key,
	slug text unique,
	title text not null,
	blurb text not null default '',
	created_at integer not null default (cast(unixepoch('subsec') * 1000 as integer))
);

-- A question: its prompt, its choices (a JSON list of two to four strings, declared json so Db
-- reads it as its JSON), and which is right (counting from 0).
create table if not exists quiz_questions (
	set_id integer not null references quiz_sets (id) on delete cascade,
	position integer not null,
	prompt text not null,
	choices json not null,
	answer integer not null,
	primary key (set_id, position)
);
