-- The app's tables, in SQLite (D-045). The server applies each file in migrations/ once, in the
-- order of their names, when it starts (rocx build embeds them in the program). Checks a type can't
-- say are the table's, so the admin (packages/admin), which edits these rows, shows its reason when
-- a form breaks one.
--
-- A moment is milliseconds since the epoch, in an integer (Store gives now from `Time.now_millis!`,
-- and reads a moment as ISO 8601 in UTC with strftime); a day is its date as text, `2026-11-22`, in
-- UTC as the app shows them (Days.roc reads them): a status page read in several time zones is
-- clearest in one. A column declared boolean is read as a Bool.

-- What is watched: an address asked every `interval_s` seconds, up when it answers
-- `expected_status` within `timeout_ms`. A URL that starts with `/` is this app itself.
create table monitors (
    id integer primary key,
    name text not null check (length(trim(name)) between 1 and 60),
    -- http:// or https:// and a host, or a path of this app's; no white space.
    url text not null constraint monitors_url_check check (
        (url glob 'http://?*' or url glob 'https://?*' or url glob '/*')
        and url not glob ('*[' || char(9, 10, 11, 12, 13, 32) || ']*')
    ),
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
    next_check_at integer not null default (cast(unixepoch('subsec') * 1000 as integer)),
    created_at integer not null default (cast(unixepoch('subsec') * 1000 as integer))
);

-- Every check, as it went: kept for a week, then only in `daily`.
create table checks (
    id integer primary key,
    monitor_id integer not null references monitors (id) on delete cascade,
    at integer not null default (cast(unixepoch('subsec') * 1000 as integer)),
    up boolean not null,
    -- The answer's status; null when there was none (no connection, a timeout).
    status integer,
    latency_ms integer not null,
    error text not null default ''
);

create index checks_by_monitor on checks (monitor_id, at desc);

-- A day of a monitor's checks, rolled up each night (the `nightly` job) from `checks`.
create table daily (
    monitor_id integer not null references monitors (id) on delete cascade,
    day text not null check (day glob '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
    checks integer not null,
    up integer not null check (up <= checks),
    latency_ms_sum integer not null default 0,
    primary key (monitor_id, day)
);

-- An outage: opened by the checks after `threshold` failures in a row, closed by the next check
-- that passes (or by the admin).
create table incidents (
    id integer primary key,
    monitor_id integer not null references monitors (id) on delete cascade,
    title text not null,
    opened_at integer not null default (cast(unixepoch('subsec') * 1000 as integer)),
    closed_at integer
);

-- One open incident a monitor at most: the check that opens one inserts it `on conflict do nothing`.
create unique index incidents_one_open on incidents (monitor_id) where closed_at is null;

create index incidents_by_opening on incidents (opened_at desc);

-- What was said about an incident, in order: by the checks or by the admin.
create table incident_updates (
    id integer primary key,
    incident_id integer not null references incidents (id) on delete cascade,
    at integer not null default (cast(unixepoch('subsec') * 1000 as integer)),
    state text not null check (state in ('investigating', 'identified', 'monitoring', 'resolved')),
    body text not null check (length(trim(body)) between 1 and 2000),
    author text not null default 'Status'
);

create index incident_updates_by_incident on incident_updates (incident_id, at);

-- Who is mailed when an incident opens or closes. `token` is the unsubscribe link's: 16 random
-- bytes, as hex.
create table subscribers (
    id integer primary key,
    -- Something, an @, and a domain with a dot in it; one @, no white space.
    email text not null constraint subscribers_email_check check (
        email glob '?*@?*.?*'
        and email not glob '*@*@*'
        and email not glob ('*[' || char(9, 10, 11, 12, 13, 32) || ']*')
    ),
    token text not null unique default (lower(hex(randomblob(16)))),
    created_at integer not null default (cast(unixepoch('subsec') * 1000 as integer))
);

-- One subscription an address, whatever its case (SQLite's lower() folds ASCII letters alone).
create unique index subscribers_email on subscribers (lower(email));
