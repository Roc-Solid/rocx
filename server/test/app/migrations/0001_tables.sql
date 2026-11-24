-- The test app's tables: applied once, at the server's start (the program's migrations, embedded in it).
create table if not exists notes (id bigserial primary key, body text not null, note text);
create table if not exists job_log (id bigserial primary key, kind text not null, said text not null, at timestamptz not null default now());
create table if not exists flaky (name text primary key, tries int not null default 0);
