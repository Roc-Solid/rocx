-- Something to look at the first time the app runs: four people, three lists, a dozen tasks, with
-- due days counted from the day the database was made. A migration runs once per database, and
-- each insert skips what is already there, so seeding twice changes nothing.

insert into people (id, name) values
	('avery', 'Avery Stone'),
	('jun', 'Jun Park'),
	('mila', 'Mila Novak'),
	('theo', 'Theo Brandt')
on conflict (id) do nothing;

insert into lists (id, name) values
	(1, 'Website relaunch'),
	(2, 'Office move'),
	(3, 'Team offsite')
on conflict (id) do nothing;

-- The lists' ids were given by hand: the next one made is 4.
select setval('lists_id_seq', (select max(id) from lists));

insert into tasks (id, list_id, title, notes, due, assignee, done, position) values
	(1, 1, 'Write the launch announcement', 'Short: what changed, and a link to the new pricing page.', current_date + 2, 'avery', false, 0),
	(2, 1, 'Proofread the pricing page', '', current_date + 1, 'jun', false, 1),
	(3, 1, 'Redirect the old blog URLs', 'The list of old paths is in the shared drive.', current_date - 1, 'theo', false, 2),
	(4, 1, 'Pick the hero photo', '', null, 'mila', true, 3),
	(5, 1, 'Check every page on a phone', '', current_date + 5, null, false, 4),
	(6, 2, 'Order moving boxes', 'Forty should do. Tape too.', current_date, 'jun', false, 0),
	(7, 2, 'Book the van', '', current_date + 9, 'avery', false, 1),
	(8, 2, 'Label the desks', '', null, null, false, 2),
	(9, 2, 'Tell the post office', '', current_date + 12, 'theo', true, 3),
	(10, 3, 'Pick a date', 'Two weekends in spring look free for everyone.', current_date + 3, 'mila', false, 0),
	(11, 3, 'Find a place to stay', '', current_date + 14, null, false, 1),
	(12, 3, 'Ask about dietary needs', '', null, 'avery', true, 2)
on conflict (id) do nothing;

select setval('tasks_id_seq', (select max(id) from tasks));
