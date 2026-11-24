-- What the sale workloads write (Sales.roc), a sale in one transaction as a shop's checkout writes
-- one: the sale, its lines, its payment and its entry in the ledger, each table keyed by its own
-- rowid and pointing at the sale (foreign keys are on, on every engine); and, in the workloads with
-- a job, its receipt queued in rocx_jobs (packages/jobs) beside them.

create table sales (
    id integer primary key,
    customer integer not null,
    total integer not null,
    created integer not null
);

create table sale_lines (
    id integer primary key,
    sale integer not null references sales (id),
    product integer not null,
    quantity integer not null,
    price integer not null
);
create index sale_lines_sale on sale_lines (sale);

create table payments (
    id integer primary key,
    sale integer not null references sales (id),
    amount integer not null,
    method text not null
);

create table ledger (
    id integer primary key,
    sale integer not null references sales (id),
    account text not null,
    amount integer not null,
    at integer not null
);
