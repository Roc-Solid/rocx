-- The demo board, so the app looks alive the first time it runs: three people, four columns and a
-- dozen cards. A migration runs once per database, and every insert here is skipped when what it
-- would make is there already, so running it again by hand changes nothing.

insert into people (name, color) values ('Ada', '#c2255c'), ('Bo', '#3b5bdb'), ('Cyd', '#2b8a3e')
on conflict do nothing;

insert into boards (slug, name) values ('launch', 'Acme Rocket Launch')
on conflict (slug) do nothing;

insert into columns (board_id, name, rank)
select b.id, c.name, c.rank
from boards b, (values ('Ideas', 'c'), ('To do', 'i'), ('Doing', 'r'), ('Done', 'w')) as c(name, rank)
where b.slug = 'launch' and not exists (select 1 from columns where board_id = b.id);

insert into cards (board_id, column_id, rank, title, description, labels, assignee_id, due)
select b.id, col.id, c.rank, c.title, c.description, c.labels::jsonb,
	(select id from people where name = c.assignee), current_date + c.due_in
from boards b
join (values
	('Ideas', 'i', 'Confetti cannon at lift-off', 'Ask the safety team first.', '["feature"]', null, null),
	('Ideas', 'r', 'Live countdown on the website', '', '["feature","design"]', 'Bo', null),
	('To do', 'c', 'Book the launch pad', 'Tuesday or Thursday; the pad crew prefers mornings.', '["ops","urgent"]', 'Ada', 2),
	('To do', 'i', 'Weather go/no-go checklist', '', '["ops"]', 'Cyd', 4),
	('To do', 'r', 'Press kit', 'Photos, the fact sheet, and a quote from the crew.', '["design"]', 'Bo', 6),
	('To do', 'w', 'Fix the fuel gauge rounding', 'It shows 100% at 99.6%.', '["bug"]', null, 3),
	('Doing', 'i', 'Telemetry dashboard', 'Altitude, speed and the fuel left, every second.', '["feature"]', 'Ada', 5),
	('Doing', 'r', 'Rehearse the countdown', '', '["ops"]', 'Cyd', 1),
	('Done', 'i', 'Paint the rocket', 'Acme red, with the logo on both sides.', '["design"]', 'Bo', -3),
	('Done', 'r', 'Order the fuel', '', '["ops"]', 'Ada', -6)
) as c(column_name, rank, title, description, labels, assignee, due_in) on true
join columns col on col.board_id = b.id and col.name = c.column_name
where b.slug = 'launch' and not exists (select 1 from cards where board_id = b.id);

insert into checklist_items (card_id, text, done)
select card.id, i.text, i.done
from cards card
join (values
	(1, 'Book the launch pad', 'Call the pad crew', true),
	(2, 'Book the launch pad', 'Sign the booking form', false),
	(3, 'Book the launch pad', 'Tell the press office', false),
	(4, 'Weather go/no-go checklist', 'Wind under 30 km/h', false),
	(5, 'Weather go/no-go checklist', 'No lightning within 10 km', false),
	(6, 'Telemetry dashboard', 'Altitude chart', true),
	(7, 'Telemetry dashboard', 'Speed chart', true),
	(8, 'Telemetry dashboard', 'Fuel gauge', false),
	(9, 'Paint the rocket', 'Primer', true),
	(10, 'Paint the rocket', 'Acme red', true),
	(11, 'Paint the rocket', 'Logo', true)
) as i(position, card_title, text, done) on card.title = i.card_title
where not exists (select 1 from checklist_items where card_id = card.id)
order by i.position;
