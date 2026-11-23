-- The tables the workloads write and read (Bench.roc), the same on SQLite and on Turso.

-- What the sequential workloads insert, read, scan, sum and update.
create table items (
    id integer primary key,
    name text not null,
    category integer not null,
    price integer not null,
    data text not null
);
create index items_category on items (category);

-- The counters transactions read and write back one more: one per writer, and one they share.
create table counters (
    id integer primary key,
    value integer not null
);

-- What the concurrent writers insert, each its own rows.
create table events (
    id integer primary key,
    worker integer not null,
    n integer not null,
    body text not null
);
