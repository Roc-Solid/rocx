-- What the app starts with, so its status page looks alive the first time it runs: three
-- monitors, ninety days of history, one past incident with its updates, and a subscriber whose
-- alerts the dev mailbox shows (/__rocx/mail). A migration runs once, so none of this is ever added
-- twice; rows deleted in the admin stay deleted. Moments are milliseconds since the epoch, now
-- `cast(unixepoch('subsec') * 1000 as integer)`; days are dates in UTC, today `date('now')`.
--
-- Two monitors ask this app itself (a URL that starts with `/`): `/health`, and `/demo/flaky`,
-- which fails now and then on purpose, and always while the admin's "Break it" switch is on. The
-- third asks https://example.com, first a minute after the first start.
insert into monitors (name, url, interval_s, group_name, next_check_at) values
    ('Status page', '/health', 30, 'Platform', cast(unixepoch('subsec') * 1000 as integer)),
    ('Payments API', '/demo/flaky', 30, 'Platform', cast(unixepoch('subsec') * 1000 as integer) + 10000),
    ('example.com', 'https://example.com', 300, 'Websites', cast(unixepoch('subsec') * 1000 as integer) + 60000);

-- Ninety days, rolled up as the nightly job would have: a few failures a day for the flaky one, now
-- and then one for the others, and the past incident's 23 minutes. The numbers come from a hash of
-- the monitor and the day (`h`: two rounds of a linear congruential generator, its high bits), so
-- every database gets the same history.
with recursive
    ago (n) as (select 1 union all select n + 1 from ago where n < 89),
    seeded as (select m.id, m.url, m.interval_s, ago.n as ago, (m.id * 92821 + ago.n * 68917) % 2147483648 as x from monitors m, ago),
    hashed as (select id, url, interval_s, ago, ((x * 1103515245 + 12345) % 2147483648 * 1103515245 + 12345) % 2147483648 / 256 as h from seeded),
    worked as (
        select id, ago, 86400 / interval_s as checks,
            case url
                when '/demo/flaky' then case when ago = 12 then 46 + h % 9 else h % 20 end
                when '/health' then case when h % 31 = 0 then 2 else 0 end
                else case when h % 43 = 0 then 1 else 0 end
            end as failures,
            case url when '/health' then 11 + h % 4 when '/demo/flaky' then 112 + h % 25 else 158 + h % 30 end as latency
        from hashed
    )
insert into daily (monitor_id, day, checks, up, latency_ms_sum)
select id, date('now', '-' || ago || ' days'), checks, checks - failures, checks * latency
from worked;

-- The last day, a check every five minutes (the live ones come every 30 seconds on top).
with recursive
    k (n) as (select 1 union all select n + 1 from k where n < 288),
    seeded as (select m.id, m.url, k.n as k, (m.id * 92821 + k.n * 68917 + 7) % 2147483648 as x from monitors m, k),
    hashed as (select id, url, k, ((x * 1103515245 + 12345) % 2147483648 * 1103515245 + 12345) % 2147483648 / 256 as h from seeded),
    worked as (
        select id, k,
            url = '/demo/flaky' and h % 97 = 0 as down,
            case url
                when '/health' then 6 + h % 14
                when '/demo/flaky' then 70 + h % 140 + case when h % 23 = 0 then 600 else 0 end
                else 140 + h % 90
            end as latency
        from hashed
    )
insert into checks (monitor_id, at, up, status, latency_ms, error)
select id, cast(unixepoch('subsec') * 1000 as integer) - 300000 * k, not down, case when down then 503 else 200 end, latency,
    case when down then 'expected 200, got 503' else '' end
from worked;

-- The past incident, twelve days ago from 14:05 to 14:28 UTC: opened by the checks, explained by
-- the on-call team, closed by the check that passed.
insert into incidents (monitor_id, title, opened_at, closed_at)
select id, 'Payments API is down',
    unixepoch(date('now', '-12 days')) * 1000 + (14 * 60 + 5) * 60000,
    unixepoch(date('now', '-12 days')) * 1000 + (14 * 60 + 28) * 60000
from monitors where url = '/demo/flaky';

with said (after_minutes, state, body, author) as (values
    (0, 'investigating', 'Payments API failed 3 checks in a row (expected 200, got 503).', 'Status'),
    (6, 'identified', 'A slow database migration is holding a lock on the payments table. We are rolling it back.', 'On-call team'),
    (17, 'monitoring', 'The migration is rolled back and payments are going through again. We are watching the error rate.', 'On-call team'),
    (23, 'resolved', 'Payments API answers again (200 in 96 ms) after 23 minutes.', 'Status')
)
insert into incident_updates (incident_id, at, state, body, author)
select i.id, i.opened_at + said.after_minutes * 60000, said.state, said.body, said.author
from incidents i join monitors m on m.id = i.monitor_id, said
where m.url = '/demo/flaky';

insert into subscribers (email) values ('oncall@example.com');
