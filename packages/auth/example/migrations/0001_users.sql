-- The app's people: a row each, made the first time someone signs in (Accounts.admit!). Ids are
-- text the app makes, so the table is the same on SQLite and on Postgres.
create table users (
    id text primary key,
    email text not null unique,
    name text not null,
    created_at bigint not null
);
