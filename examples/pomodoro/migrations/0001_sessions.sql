-- Each focus session done: the day it ended on, as the server's clock has it (its own time zone),
-- and how long it was.
create table sessions (
	id integer primary key,
	day text not null,
	minutes integer not null,
	ended_at text not null default (datetime('now'))
);

create index sessions_by_day on sessions (day);
