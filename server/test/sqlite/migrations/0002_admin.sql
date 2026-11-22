-- What packages/admin's test reads and writes (server/test/admin-checks.mjs): an author, and books
-- with a foreign key, a check that is a choice, a boolean, a number and JSON.
create table admin_authors (
    id integer primary key,
    name text not null
);

create table admin_books (
    id integer primary key,
    author_id integer references admin_authors,
    title text not null,
    state text not null default 'draft' check (state in ('draft', 'sold')),
    done boolean not null default false,
    price real,
    meta json
);

insert into admin_authors (name) values ('Ada'), ('Bo');
