-- The app's users: a row each, made the first time someone signs in (Accounts.admit!). Ids are text
-- the app makes and times are milliseconds, so the table is the same on SQLite, Postgres and Turso.
-- packages/auth keeps its own tables (sessions, links, identities) beside it.
create table users (
    id text primary key,
    email text not null unique,
    name text not null,
    created_at bigint not null
);
