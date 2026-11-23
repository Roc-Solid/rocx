-- The tables the check's tests read (test/check-sql.test.mjs).
create table notes (
    id integer primary key,
    author integer not null,
    body text not null,
    note text,
    done boolean not null default false
);
