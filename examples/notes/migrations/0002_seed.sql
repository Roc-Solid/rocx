-- Two people, and notes enough that the app looks lived in the first time it runs. Sign in as
-- ada@example.com (the link lands in the dev mailbox, /__rocx/mail, with --dev) to see them.
-- Safe to run again: a person is added only if their address is new, and a note only if its person
-- has none with its title. A note's `plain` is what its body reads as (Note.plain, which Store
-- writes with every body), so a list and a search read it as they read a note written in the app;
-- its age and when it was last edited are days before the seed runs.

insert into people (email) values ('ada@example.com'), ('bo@example.com')
on conflict (lower(email)) do nothing;

insert into notes (person_id, title, body, plain, tags, pinned, archived, created_at, updated_at)
with n (email, title, body, plain, tags, pinned, archived, age, edited) as (values
	('ada@example.com', 'Launch week plan', '## Before Monday

- [x] Book the test stand for Wednesday
- [x] Send the press kit to the printers
- [ ] Confirm the weather window with the range office
- [ ] Charge every radio, then charge them again

## The day

Countdown starts at **09:00**. Bo has the checklist, Cyd has the cameras.
If the wind is over 25 km/h at the pad we hold, no arguing.

> Measure twice, launch once.',
		'Before Monday Book the test stand for Wednesday Send the press kit to the printers Confirm the weather window with the range office Charge every radio, then charge them again The day Countdown starts at 09:00. Bo has the checklist, Cyd has the cameras. If the wind is over 25 km/h at the pad we hold, no arguing. Measure twice, launch once.',
		'["work","rocket"]', true, false, 9, 2),

	('ada@example.com', 'Trip to the coast', 'Leaving Friday after work, back Sunday night.

## Packing

- [ ] Rain jacket (it will rain)
- [ ] Walking boots
- [x] Book the cabin
- [ ] Tide table for Saturday morning
- [ ] Cash for the ferry

The bakery by the harbour opens at 7; get there before the walkers do.',
		'Leaving Friday after work, back Sunday night. Packing Rain jacket (it will rain) Walking boots Book the cabin Tide table for Saturday morning Cash for the ferry The bakery by the harbour opens at 7; get there before the walkers do.',
		'["travel","weekend"]', true, false, 6, 1),

	('ada@example.com', 'Sourdough schedule', 'A loaf for Saturday lunch starts on Thursday evening.

1. **Thursday, 20:00**: feed the starter (50 g flour, 50 g water)
2. **Friday, 08:00**: mix 500 g flour, 350 g water, 100 g starter, 10 g salt
3. Four sets of stretch and folds, half an hour apart
4. Shape, then into the fridge overnight
5. **Saturday, 09:00**: bake at 250 °C, lid on for 20 minutes, off for 25

If the dough is slack, the kitchen was too warm: shorten the first rise.',
		'A loaf for Saturday lunch starts on Thursday evening. Thursday, 20:00: feed the starter (50 g flour, 50 g water) Friday, 08:00: mix 500 g flour, 350 g water, 100 g starter, 10 g salt Four sets of stretch and folds, half an hour apart Shape, then into the fridge overnight Saturday, 09:00: bake at 250 °C, lid on for 20 minutes, off for 25 If the dough is slack, the kitchen was too warm: shorten the first rise.',
		'["kitchen"]', false, false, 20, 20),

	('ada@example.com', 'Reading list', 'Books people keep recommending, in no order:

- *The Lighthouse Keeper''s Almanac*, for the long train rides
- *A Field Guide to Clouds*, finally
- *Small Engines and How to Mend Them*
- Anything about the history of maps

Ask the library about [their winter reading club](https://library.example.com/winter).',
		'Books people keep recommending, in no order: The Lighthouse Keeper''s Almanac, for the long train rides A Field Guide to Clouds, finally Small Engines and How to Mend Them Anything about the history of maps Ask the library about their winter reading club.',
		'["books"]', false, false, 30, 12),

	('ada@example.com', 'One-to-one with Bo', '## Agenda

- How the launch rehearsal went, and what to change
- Bo wants to own the telemetry dashboard: yes
- Holiday dates in December

## Notes

Bo raised that the checklist is too long to read aloud. Split it into *before the pad* and
*at the pad*. Next one in two weeks.',
		'Agenda How the launch rehearsal went, and what to change Bo wants to own the telemetry dashboard: yes Holiday dates in December Notes Bo raised that the checklist is too long to read aloud. Split it into before the pad and at the pad. Next one in two weeks.',
		'["work","meetings"]', false, false, 4, 4),

	('ada@example.com', 'Shed ideas', 'The shed could be a workshop if:

- the roof stops leaking (new felt, about a weekend)
- there is a bench along the window wall
- the bikes move to a rack outside

| Job | Cost | When |
| --- | --- | --- |
| Roof felt | 60 | March |
| Bench | 120 | April |
| Bike rack | 45 | Any time |',
		'The shed could be a workshop if: the roof stops leaking (new felt, about a weekend) there is a bench along the window wall the bikes move to a rack outside | Job | Cost | When | | --- | --- | --- | | Roof felt | 60 | March | | Bench | 120 | April | | Bike rack | 45 | Any time |',
		'["home","ideas"]', false, false, 15, 8),

	('ada@example.com', 'Countdown script', 'The little script that reads the countdown aloud, kept here so it doesn''t get lost:

```sh
for n in 10 9 8 7 6 5 4 3 2 1; do
  say "$n"; sleep 1
done
say "Lift off"
```

Swap `say` for `espeak` on the field laptop.',
		'The little script that reads the countdown aloud, kept here so it doesn''t get lost: for n in 10 9 8 7 6 5 4 3 2 1; do say "$n"; sleep 1 done say "Lift off" Swap say for espeak on the field laptop.',
		'["rocket","code"]', false, false, 11, 11),

	('ada@example.com', 'Old flat: things to sort', '- [x] Hand the keys back
- [x] Final meter reading
- [x] Forward the post

All done; kept for the deposit''s reference number: **AC-20419**.',
		'Hand the keys back Final meter reading Forward the post All done; kept for the deposit''s reference number: AC-20419.',
		'["home"]', false, true, 60, 45),

	('bo@example.com', 'Telemetry dashboard', 'What the dashboard has to show, biggest first:

1. Altitude and speed
2. Battery voltage, in red under 7.2 V
3. Signal strength

Ask Ada about the launch week plan.',
		'What the dashboard has to show, biggest first: Altitude and speed Battery voltage, in red under 7.2 V Signal strength Ask Ada about the launch week plan.',
		'["work","rocket"]', true, false, 3, 1),

	('bo@example.com', 'Climbing log', '- Tuesday: the overhang at the wall, finally
- Thursday: rest
- Saturday: outdoors if it''s dry',
		'Tuesday: the overhang at the wall, finally Thursday: rest Saturday: outdoors if it''s dry',
		'["climbing"]', false, false, 5, 2)
)
select p.id, n.title, n.body, n.plain, n.tags, n.pinned, n.archived,
	cast(unixepoch('subsec') * 1000 as integer) - n.age * 86400000,
	cast(unixepoch('subsec') * 1000 as integer) - n.edited * 86400000
from people p
join n on lower(p.email) = n.email
where not exists (select 1 from notes existing where existing.person_id = p.id and existing.title = n.title);
