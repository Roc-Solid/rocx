-- The SQLite test app's tables (server/test/sqlite.test.mjs), in SQLite's flavor.
create table items (
    id integer primary key,
    name text not null,
    count integer not null default 0,
    done boolean not null default false,
    note text,
    meta json,
    weight real
);

-- A counter that many requests bump at once, each reading it and writing it back in a transaction.
create table counters (
    name text primary key,
    value integer not null
);
insert into counters (name, value) values ('hits', 0);
