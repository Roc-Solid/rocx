-- What the tests of nested transactions write (server/test/nested-checks.mjs, D-076): a mark for
-- each level that wrote one, by the test's run.
create table if not exists nested_marks (id bigserial primary key, run text not null, label text not null);

-- What the docs' sample of a transaction inside another writes (Samples.roc: `place_order!`, which
-- calls `award!`): orders, and the points a customer was given.
create table if not exists orders (id bigserial primary key, customer text not null, total bigint not null);
create table if not exists points (customer text not null, points bigint not null);
