-- What the tests of nested transactions write (server/test/nested-checks.mjs, D-076): a mark for
-- each level that wrote one, by the test's run.
create table nested_marks (
    id integer primary key,
    run text not null,
    label text not null
);
