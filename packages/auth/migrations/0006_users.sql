-- The app's users (D-134, `Auth.user_for!`): a row each, made the first time someone signs in, its
-- id a version 7 UUID the package makes (crypto's `Uuid`), its address lower-cased and unique, so
-- the identities that give an address are one user. The address is the user's as it is now:
-- `user_for!` changes it when their provider's does (each identity's own stays on its row in
-- `auth_identities`). The app keeps what else it knows of a user in its own tables, by this id;
-- it may read this table in its queries (a join for the address), and writes it only through the
-- package. `Auth.forget!` deletes the row, with everything else the package keeps for the user.
create table auth_users (
    id text primary key,
    email text not null unique,
    created_at bigint not null
);
