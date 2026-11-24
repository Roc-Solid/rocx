-- The app's tables, in SQLite (the app's database is a file: `database: Sqlite("data/notes.db")`):
-- the people who sign in (by email: there are no passwords), their notes, and the personal access
-- tokens their AI clients use. Every note is one person's, and every query the app makes names
-- whose (Store.roc). A moment is milliseconds since the epoch.

create table people (
	id integer primary key,
	email text not null check (length(email) between 3 and 254),
	-- No longer used: "sign out everywhere" raised it when notes signed its own session cookies.
	-- Sessions are packages/auth's now (its auth_sessions table), and it ends them itself.
	session_epoch integer not null default 0,
	created_at integer not null default (cast(unixepoch('subsec') * 1000 as integer))
);

-- One person per address, whatever its case (SQLite's lower() folds ASCII letters, which is what
-- an address's are).
create unique index people_email on people (lower(email));

create table notes (
	id integer primary key,
	person_id integer not null references people on delete cascade,
	title text not null check (length(title) between 1 and 200),
	body text not null default '' check (length(body) <= 100000),
	-- A JSON list of the note's tags (declared json, so Db reads the list).
	tags json not null default '[]',
	pinned boolean not null default false,
	archived boolean not null default false,
	created_at integer not null default (cast(unixepoch('subsec') * 1000 as integer)),
	updated_at integer not null default (cast(unixepoch('subsec') * 1000 as integer)),
	-- The body as plain words: Markdown's marks, code fences and links' addresses left out
	-- (Note.plain, which Store writes with every body). What a list shows of a note, and what search
	-- finds and quotes.
	plain text not null default ''
);

create index notes_person on notes (person_id, archived, pinned desc, updated_at desc);

-- What full-text search matches: each note's title and plain words, in an FTS5 index the triggers
-- keep in step with `notes`, each word by its stem (porter: "rehearsals" finds "rehearsal"). A
-- search weighs the title's words more than the body's (Store.search!).
create virtual table note_words using fts5 (title, plain, content = 'notes', content_rowid = 'id', tokenize = 'porter unicode61');

create trigger notes_words_added after insert on notes begin
	insert into note_words (rowid, title, plain) values (new.id, new.title, new.plain);
end;

create trigger notes_words_removed after delete on notes begin
	insert into note_words (note_words, rowid, title, plain) values ('delete', old.id, old.title, old.plain);
end;

create trigger notes_words_changed after update of title, plain on notes begin
	insert into note_words (note_words, rowid, title, plain) values ('delete', old.id, old.title, old.plain);
	insert into note_words (rowid, title, plain) values (new.id, new.title, new.plain);
end;

create table tokens (
	id integer primary key,
	person_id integer not null references people on delete cascade,
	name text not null check (length(name) between 1 and 60),
	-- The token's SHA-256, in hex: the token itself is shown once, when it is made, and never kept.
	hash text not null unique,
	-- Its last four characters, so a list of tokens can tell them apart.
	hint text not null,
	read_only boolean not null default false,
	created_at integer not null default (cast(unixepoch('subsec') * 1000 as integer)),
	last_used_at integer
);

create index tokens_person on tokens (person_id, created_at);
