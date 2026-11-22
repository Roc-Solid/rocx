-- What the app starts with, so its status page looks alive the first time it runs: three
-- monitors, ninety days of history, one past incident with its updates, and a subscriber whose
-- alerts the dev mailbox shows (/__rocx/mail). A migration runs once, so none of this is ever added
-- twice; rows deleted in the admin stay deleted.
--
-- Two monitors ask this app itself (a URL that starts with `/`): `/health`, and `/demo/flaky`,
-- which fails now and then on purpose, and always while the admin's "Break it" switch is on. The
-- third asks https://example.com, first a minute after the first start.
insert into monitors (name, url, interval_s, group_name, next_check_at) values
    ('Status page', '/health', 30, 'Platform', now()),
    ('Payments API', '/demo/flaky', 30, 'Platform', now() + interval '10 seconds'),
    ('example.com', 'https://example.com', 300, 'Websites', now() + interval '1 minute');

-- Ninety days, rolled up as the nightly job would have: a few failures a day for the flaky one, now
-- and then one for the others, and the past incident's 23 minutes. The numbers come from a hash of
-- the monitor and the day, so every database gets the same history.
insert into daily (monitor_id, day, checks, up, latency_ms_sum)
select m.id, utc_today() - ago, n.checks, n.checks - f.failures, n.checks * f.latency
from monitors m
cross join generate_series(1, 89) as ago
cross join lateral (select 86400 / m.interval_s as checks) n
cross join lateral (select abs(hashtext(m.url || ago::text)) as h) r
cross join lateral (
    select
        case m.url
            when '/demo/flaky' then case when ago = 12 then 46 + r.h % 9 else r.h % 20 end
            when '/health' then case when r.h % 31 = 0 then 2 else 0 end
            else case when r.h % 43 = 0 then 1 else 0 end
        end as failures,
        case m.url when '/health' then 11 + r.h % 4 when '/demo/flaky' then 112 + r.h % 25 else 158 + r.h % 30 end as latency
) f;

-- The last day, a check every five minutes (the live ones come every 30 seconds on top).
insert into checks (monitor_id, at, up, status, latency_ms, error)
select m.id, now() - make_interval(mins => 5 * k), not x.down, case when x.down then 503 else 200 end, x.latency,
    case when x.down then 'expected 200, got 503' else '' end
from monitors m
cross join generate_series(1, 288) as k
cross join lateral (select abs(hashtext(m.url || '/' || k::text)) as h) r
cross join lateral (
    select
        m.url = '/demo/flaky' and r.h % 97 = 0 as down,
        case m.url
            when '/health' then 6 + r.h % 14
            when '/demo/flaky' then 70 + r.h % 140 + case when r.h % 23 = 0 then 600 else 0 end
            else 140 + r.h % 90
        end as latency
) x;

-- The past incident, twelve days ago: opened by the checks, explained by the on-call team, closed by
-- the check that passed.
with opened as (
    insert into incidents (monitor_id, title, opened_at, closed_at)
    select id, 'Payments API is down',
        (utc_today() - 12)::timestamp at time zone 'UTC' + interval '14 hours 5 minutes',
        (utc_today() - 12)::timestamp at time zone 'UTC' + interval '14 hours 28 minutes'
    from monitors where url = '/demo/flaky'
    returning id, opened_at
)
insert into incident_updates (incident_id, at, state, body, author)
select opened.id, opened.opened_at + u.after, u.state, u.body, u.author
from opened, (values
    (interval '0 minutes', 'investigating', 'Payments API failed 3 checks in a row (expected 200, got 503).', 'Status'),
    (interval '6 minutes', 'identified', 'A slow database migration is holding a lock on the payments table. We are rolling it back.', 'On-call team'),
    (interval '17 minutes', 'monitoring', 'The migration is rolled back and payments are going through again. We are watching the error rate.', 'On-call team'),
    (interval '23 minutes', 'resolved', 'Payments API answers again (200 in 96 ms) after 23 minutes.', 'Status')
) as u(after, state, body, author);

insert into subscribers (email) values ('oncall@example.com');
