-- Wrong codes in a row, counted per user's authenticator (not only per sign-in, as auth_waiting's
-- attempts are): a sign-in's code, and the codes that turn two-factor off and make new recovery
-- codes, all count. After ten, every code of theirs is refused until a quarter of an hour after
-- the last (Rules.locked); a right code sets the count back to 0. The same on SQLite and Postgres.
alter table auth_two_factor add column misses bigint not null default 0;
alter table auth_two_factor add column missed_at bigint not null default 0;
