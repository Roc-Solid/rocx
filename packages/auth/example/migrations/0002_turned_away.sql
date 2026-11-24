-- Who `Accounts.admit!` turned away, and when: written as it refuses, so the row stays though no
-- session starts (packages/auth commits what admit! writes either way).
create table turned_away (
    email text not null,
    at bigint not null
);
