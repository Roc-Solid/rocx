-- Question sets and their questions. A set's `slug` names the ones this app seeds (0002), so that
-- seeding twice changes nothing; sets made in the editor have none.
create table if not exists quiz_sets (
	id bigserial primary key,
	slug text unique,
	title text not null,
	blurb text not null default '',
	created_at timestamptz not null default now()
);

-- A question: its prompt, its choices (a JSON list of two to four strings), and which is right
-- (counting from 0).
create table if not exists quiz_questions (
	set_id bigint not null references quiz_sets (id) on delete cascade,
	position int not null,
	prompt text not null,
	choices jsonb not null,
	answer int not null,
	primary key (set_id, position)
);
