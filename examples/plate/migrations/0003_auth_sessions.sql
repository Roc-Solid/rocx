-- The sessions moved to packages/auth (its `auth_sessions`, made by its own migration), so plate's
-- own table goes. A browser signed in before signs in once more; nothing else changes.
drop table if exists sessions;
