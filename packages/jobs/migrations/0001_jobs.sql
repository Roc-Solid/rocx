-- The jobs queue. A database the server platform migrated before jobs were a package has it
-- already (`rocx/0001`, `rocx/0002`), rows and all: nothing here changes it.
create table if not exists rocx_jobs (
    id bigserial primary key,
    kind text not null,
    input text not null,
    state text not null default 'queued' constraint rocx_jobs_state_check check (state in ('queued', 'running', 'done', 'failed', 'canceled')),
    attempts int not null default 0,
    max_attempts int not null default 5,
    run_at timestamptz not null default now(),
    locked_at timestamptz,
    finished_at timestamptz,
    last_error text,
    unique_key text,
    created_at timestamptz not null default now()
);
-- The next due job, quickly.
create index if not exists rocx_jobs_ready on rocx_jobs (run_at, id) where state = 'queued';
-- A key is one job's while it is pending (queued or running), not forever: the next may have it
-- once that one is done.
create unique index if not exists rocx_jobs_pending_key on rocx_jobs (unique_key) where state in ('queued', 'running');
-- The jobs page's lists, by state and kind.
create index if not exists rocx_jobs_listed on rocx_jobs (state, kind, id);
