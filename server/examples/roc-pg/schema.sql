-- The example's schema: its migration, and what roc-pg checks its queries against.
create table rocpg_planets (
    id integer primary key,
    name text not null,
    gravity double precision not null,
    moons integer
);
