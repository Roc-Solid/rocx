-- The jobs queue on SQLite (D-045): Postgres's table (0001_jobs.sql), its times milliseconds since
-- the epoch in integer columns.
create table if not exists rocx_jobs (
    id integer primary key,
    kind text not null,
    input text not null,
    state text not null default 'queued' check (state in ('queued', 'running', 'done', 'failed', 'canceled')),
    attempts integer not null default 0,
    max_attempts integer not null default 5,
    run_at integer not null default (cast(unixepoch('subsec') * 1000 as integer)),
    locked_at integer,
    finished_at integer,
    last_error text,
    unique_key text,
    created_at integer not null default (cast(unixepoch('subsec') * 1000 as integer))
);
-- The next due job, quickly.
create index if not exists rocx_jobs_ready on rocx_jobs (run_at, id) where state = 'queued';
-- A key is one job's while it is pending (queued or running), not forever: the next may have it
-- once that one is done.
create unique index if not exists rocx_jobs_pending_key on rocx_jobs (unique_key) where state in ('queued', 'running');
-- The jobs page's lists, by state and kind.
create index if not exists rocx_jobs_listed on rocx_jobs (state, kind, id);
