-- Roles (D-127, `Roles`): what a user holds (`role`, one of the app's own tags), and why (`via`,
-- the app's tags too: paid for, a trial, a gift), each kept as its JSON. A row is one unbroken
-- stretch of a grant: given `by` someone (an admin's id, or what gave it) at `granted_at`, until
-- `ends_at` (null: for good), with a note. Granting again while it lasts changes its end (and its
-- `by` and note) in place. Rows are never deleted but by `Roles.forget!` (the user is gone): a
-- user's history of grants stays, so an app can tell a trial was had before.
--
-- `closed_at` is null on a user's one open row for a role and a reason (the unique index), and set
-- when it stops being that: revoked (`revoked_by` says who), or found expired by the next grant,
-- which then starts a row of its own. Times are milliseconds since 1970, given by the package.
create table auth_roles (
    id text primary key,
    user_id text not null,
    role text not null,
    via text not null,
    granted_by text not null,
    granted_at bigint not null,
    ends_at bigint,
    note text not null,
    closed_at bigint,
    revoked_by text
);
create unique index auth_roles_open on auth_roles (user_id, role, via) where closed_at is null;
create index auth_roles_user on auth_roles (user_id, role);
