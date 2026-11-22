-- Three sets to play the first time the app runs. Each insert skips what is there already (by a
-- set's slug, a question's set and place), so running this again changes nothing.
insert into quiz_sets (slug, title, blurb) values
	('around-the-globe', 'Around the Globe', 'Rivers, deserts, capitals and peaks: a lap of the planet.'),
	('science-snacks', 'Science Snacks', 'Bite-sized questions about plants, planets and the body.'),
	('words-and-wonders', 'Words and Wonders', 'Odd words, baby animals and other things worth knowing.')
on conflict (slug) do nothing;

insert into quiz_questions (set_id, position, prompt, choices, answer)
with q (slug, position, prompt, choices, answer) as (values
	('around-the-globe', 0, 'Which is the longest river in South America?', '["Orinoco", "Amazon", "Paraná", "Magdalena"]', 1),
	('around-the-globe', 1, 'What is the capital of Canada?', '["Toronto", "Vancouver", "Ottawa", "Montreal"]', 2),
	('around-the-globe', 2, 'Which desert covers much of northern Africa?', '["Sahara", "Gobi", "Atacama", "Kalahari"]', 0),
	('around-the-globe', 3, 'Mount Kilimanjaro is in which country?', '["Kenya", "Tanzania", "Uganda", "Ethiopia"]', 1),
	('around-the-globe', 4, 'Which ocean lies between Africa and Australia?', '["Atlantic", "Pacific", "Indian", "Arctic"]', 2),
	('around-the-globe', 5, 'How many continents are there?', '["Five", "Six", "Seven", "Eight"]', 2),
	('science-snacks', 0, 'Which gas do plants take from the air to make their food?', '["Oxygen", "Carbon dioxide", "Nitrogen", "Helium"]', 1),
	('science-snacks', 1, 'What is the hardest natural substance?', '["Quartz", "Iron", "Diamond", "Granite"]', 2),
	('science-snacks', 2, 'Which planet is best known for its rings?', '["Mars", "Mercury", "Saturn", "Venus"]', 2),
	('science-snacks', 3, 'At sea level, water boils at how many degrees Celsius?', '["90", "100", "110", "120"]', 1),
	('science-snacks', 4, 'How many bones are in an adult human body?', '["106", "186", "206", "306"]', 2),
	('science-snacks', 5, 'Which part of a cell holds its DNA?', '["The membrane", "The nucleus", "The ribosomes"]', 1),
	('words-and-wonders', 0, 'Which of these words reads the same backwards?', '["Rotor", "Motor", "Robot", "Rover"]', 0),
	('words-and-wonders', 1, 'What is a baby kangaroo called?', '["A kit", "A joey", "A cub", "A calf"]', 1),
	('words-and-wonders', 2, 'How many sides does a hexagon have?', '["Five", "Six", "Seven", "Eight"]', 1),
	('words-and-wonders', 3, 'A tomato is a fruit, as a botanist sees it.', '["True", "False"]', 0),
	('words-and-wonders', 4, 'Which instrument usually has 88 keys?', '["Piano", "Harp", "Accordion", "Xylophone"]', 0),
	('words-and-wonders', 5, 'In which season do most trees drop their leaves?', '["Spring", "Summer", "Autumn", "Winter"]', 2)
)
-- A where before the on conflict, as SQLite's upsert after a select asks (an `on` there could be a join's).
select s.id, q.position, q.prompt, q.choices, q.answer
from quiz_sets s, q
where q.slug = s.slug
on conflict (set_id, position) do nothing;
