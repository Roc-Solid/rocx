-- What packages/admin's test reads and writes (server/test/admin-checks.mjs): an author, and books
-- with a foreign key, a check that is a choice, a boolean, a number and JSON.
create table if not exists admin_authors (id bigserial primary key, name text not null);
create table if not exists admin_books (
    id bigserial primary key,
    author_id bigint references admin_authors,
    title text not null,
    state text not null default 'draft' check (state in ('draft', 'sold')),
    done boolean not null default false,
    price numeric(8, 2),
    meta jsonb
);
insert into admin_authors (name) select 'Ada' where not exists (select 1 from admin_authors where name = 'Ada');
insert into admin_authors (name) select 'Bo' where not exists (select 1 from admin_authors where name = 'Bo');
