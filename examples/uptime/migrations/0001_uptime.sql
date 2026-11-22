-- Acme Status's tables. The server applies each file in migrations/ once, in the order of their
-- names, when it starts (rocx build embeds them in the program). Checks a type can't say are
-- Postgres's, so the admin (packages/admin), which edits these rows, shows its reason when a form
-- breaks one.

-- Days and moments in UTC, as the app shows them (Days.roc reads them): a status page read in several
-- time zones is clearest in one.
create function utc_day(at timestamptz) returns date
    language sql stable as $$ select (at at time zone 'UTC')::date $$;
create function utc_today() returns date
    language sql stable as $$ select (now() at time zone 'UTC')::date $$;
create function iso(at timestamptz) returns text
    language sql stable as $$ select to_char(at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') $$;

-- What is watched: an address asked every `interval_s` seconds, up when it answers
-- `expected_status` within `timeout_ms`. A URL that starts with `/` is this app itself.
create table monitors (
    id bigint generated always as identity primary key,
    name text not null check (length(trim(name)) between 1 and 60),
    url text not null check (url ~ '^(https?://[^\s]+|/[^\s]*)$'),
    method text not null default 'GET' check (method in ('GET', 'HEAD', 'POST')),
    expected_status integer not null default 200 check (expected_status between 100 and 599),
    interval_s integer not null default 60 check (interval_s between 15 and 86400),
    timeout_ms integer not null default 10000 check (timeout_ms between 500 and 30000),
    -- How many failed checks in a row open an incident.
    threshold integer not null default 3 check (threshold between 1 and 10),
    group_name text not null default 'Services' check (length(trim(group_name)) between 1 and 40),
    paused boolean not null default false,
    -- Failed checks in a row, now: 0 after any check that passed.
    streak integer not null default 0,
    -- When the sweep (the `due` job) next queues a check of it.
    next_check_at timestamptz not null default now(),
    created_at timestamptz not null default now()
);

comment on table monitors is 'What Acme Status watches. A URL that starts with / is this app.';

-- Every check, as it went: kept for a week, then only in `daily`.
create table checks (
    id bigint generated always as identity primary key,
    monitor_id bigint not null references monitors (id) on delete cascade,
    at timestamptz not null default now(),
    up boolean not null,
    -- The answer's status; null when there was none (no connection, a timeout).
    status integer,
    latency_ms integer not null,
    error text not null default ''
);

create index checks_by_monitor on checks (monitor_id, at desc);

comment on table checks is 'Every check of the last week; older ones are rolled up into daily.';

-- A day of a monitor's checks, rolled up each night (the `nightly` job) from `checks`.
create table daily (
    monitor_id bigint not null references monitors (id) on delete cascade,
    day date not null,
    checks integer not null,
    up integer not null check (up <= checks),
    latency_ms_sum bigint not null default 0,
    primary key (monitor_id, day)
);

comment on table daily is 'Each monitor''s checks a day, for the 7- and 90-day uptime.';

-- An outage: opened by the checks after `threshold` failures in a row, closed by the next check
-- that passes (or by the admin).
create table incidents (
    id bigint generated always as identity primary key,
    monitor_id bigint not null references monitors (id) on delete cascade,
    title text not null,
    opened_at timestamptz not null default now(),
    closed_at timestamptz
);

-- One open incident a monitor at most: the check that opens one inserts it `on conflict do nothing`.
create unique index incidents_one_open on incidents (monitor_id) where closed_at is null;

create index incidents_by_opening on incidents (opened_at desc);

-- What was said about an incident, in order: by the checks or by the admin.
create table incident_updates (
    id bigint generated always as identity primary key,
    incident_id bigint not null references incidents (id) on delete cascade,
    at timestamptz not null default now(),
    state text not null check (state in ('investigating', 'identified', 'monitoring', 'resolved')),
    body text not null check (length(trim(body)) between 1 and 2000),
    author text not null default 'Acme Status'
);

create index incident_updates_by_incident on incident_updates (incident_id, at);

-- Who is mailed when an incident opens or closes. `token` is the unsubscribe link's.
create table subscribers (
    id bigint generated always as identity primary key,
    email text not null check (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    token text not null unique default md5(random()::text || clock_timestamp()::text),
    created_at timestamptz not null default now()
);

create unique index subscribers_email on subscribers (lower(email));
