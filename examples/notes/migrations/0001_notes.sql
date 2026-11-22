-- Acme Notes' tables: the people who sign in (by email: there are no passwords), their notes, and
-- the personal access tokens their AI clients use. Every note is one person's, and every query the
-- app makes names whose (Store.roc).

create table people (
	id bigserial primary key,
	email text not null check (length(email) between 3 and 254),
	-- Raised by "sign out everywhere": a session cookie carries the number it was signed with, and
	-- one with an older number is refused (Session.roc).
	session_epoch integer not null default 0,
	created_at timestamptz not null default now()
);

-- One person per address, whatever its case.
create unique index people_email on people (lower(email));

create table notes (
	id bigserial primary key,
	person_id bigint not null references people on delete cascade,
	title text not null check (length(title) between 1 and 200),
	body text not null default '' check (length(body) <= 100000),
	tags text[] not null default '{}',
	pinned boolean not null default false,
	archived boolean not null default false,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	-- The body as plain words, kept by Postgres in step with it: Markdown's marks, code fences and
	-- links' addresses left out. What a list shows of a note, and what search quotes from it.
	plain text generated always as (
		trim(regexp_replace(
			regexp_replace(
				regexp_replace(
					regexp_replace(
						regexp_replace(body, '!?\[([^\]]*)\]\([^)]*\)', '\1', 'g'),
					'^\s{0,3}(#{1,6}|>|[-*+]|\d+\.)\s+(\[[ xX]\]\s+)?', '', 'gn'),
				'```[A-Za-z0-9_-]*', '', 'g'),
			'[*_`~]+', '', 'g'),
		'\s+', ' ', 'g'))
	) stored,
	-- What full-text search matches: the title's words weigh more than the body's.
	search tsvector generated always as (
		setweight(to_tsvector('english', title), 'A') || setweight(to_tsvector('english', body), 'B')
	) stored
);

create index notes_search on notes using gin (search);
create index notes_tags on notes using gin (tags);
create index notes_person on notes (person_id, archived, pinned desc, updated_at desc);

create table tokens (
	id bigserial primary key,
	person_id bigint not null references people on delete cascade,
	name text not null check (length(name) between 1 and 60),
	-- The token's SHA-256, in hex: the token itself is shown once, when it is made, and never kept.
	hash text not null unique,
	-- Its last four characters, so a list of tokens can tell them apart.
	hint text not null,
	read_only boolean not null default false,
	created_at timestamptz not null default now(),
	last_used_at timestamptz
);

create index tokens_person on tokens (person_id, created_at);
