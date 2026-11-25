-- Two-factor sign-in (D-081): an authenticator app's codes (TOTP), recovery codes, and sign-ins
-- waiting for a code. The same on SQLite and on Postgres; times are milliseconds since 1970.

-- A user's authenticator: its secret, sealed (AES-256-GCM under a key derived from the app's
-- secret, base64url), never in clear; when it was turned on (null while it waits for its first
-- code); the last 30-second step a code was taken at, so a code is good once.
create table auth_two_factor (
    user_id text primary key,
    secret text not null,
    enabled_at bigint,
    last_step bigint not null,
    created_at bigint not null
);

-- A user's recovery codes, each by its SHA-256 (base64url), deleted when used.
create table auth_recovery_codes (
    user_id text not null,
    id text not null,
    created_at bigint not null,
    primary key (user_id, id)
);

-- A sign-in that waits for its code: by its token's SHA-256, as a session is; whose, where it goes
-- after, how many wrong codes it has had, until when. A right code turns it into a session.
create table auth_waiting (
    id text primary key,
    user_id text not null,
    return_to text not null,
    attempts bigint not null,
    expires_at bigint not null
);
create index auth_waiting_user on auth_waiting (user_id);
create index auth_waiting_expires on auth_waiting (expires_at);
