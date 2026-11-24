-- packages/auth's tables (D-072), the same on SQLite and on Postgres: every time is milliseconds
-- since 1970, given by the package, so its statements are the same on both.

-- Who is signed in: a row a session, found by the SHA-256 of the token in its cookie (base64url),
-- so the table alone signs no one in. Signing out deletes the row; so does its expiry, swept as
-- sessions start.
create table auth_sessions (
    id text primary key,
    user_id text not null,
    created_at bigint not null,
    expires_at bigint not null
);
create index auth_sessions_user on auth_sessions (user_id);
create index auth_sessions_expires on auth_sessions (expires_at);

-- Sign-in links on their way, by their token's SHA-256: deleted when used, or swept once expired.
create table auth_links (
    id text primary key,
    email text not null,
    return_to text not null,
    expires_at bigint not null
);
create index auth_links_expires on auth_links (expires_at);

-- Which of the app's users an identity signed in as before: an address (provider "email"), or an
-- account at a provider (its own id there).
create table auth_identities (
    provider text not null,
    subject text not null,
    user_id text not null,
    email text not null,
    created_at bigint not null,
    primary key (provider, subject)
);
create index auth_identities_user on auth_identities (user_id);
