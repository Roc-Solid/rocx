-- Two people, and notes enough that the app looks lived in the first time it runs. Sign in as
-- ada@example.com (the link lands in the dev mailbox, /__rocx/mail, with --dev) to see them.
-- Safe to run again: a person is added only if their address is new, and a note only if its person
-- has none with its title.

insert into people (email) values ('ada@example.com'), ('bo@example.com')
on conflict ((lower(email))) do nothing;

insert into notes (person_id, title, body, tags, pinned, archived, created_at, updated_at)
select p.id, n.title, n.body, n.tags, n.pinned, n.archived, now() - n.age, now() - n.edited
from people p
join (values
	('ada@example.com', 'Launch week plan', $md$## Before Monday

- [x] Book the test stand for Wednesday
- [x] Send the press kit to the printers
- [ ] Confirm the weather window with the range office
- [ ] Charge every radio, then charge them again

## The day

Countdown starts at **09:00**. Bo has the checklist, Cyd has the cameras.
If the wind is over 25 km/h at the pad we hold, no arguing.

> Measure twice, launch once.$md$, array['work', 'rocket'], true, false, interval '9 days', interval '2 days'),

	('ada@example.com', 'Trip to the coast', $md$Leaving Friday after work, back Sunday night.

## Packing

- [ ] Rain jacket (it will rain)
- [ ] Walking boots
- [x] Book the cabin
- [ ] Tide table for Saturday morning
- [ ] Cash for the ferry

The bakery by the harbour opens at 7; get there before the walkers do.$md$, array['travel', 'weekend'], true, false, interval '6 days', interval '1 day'),

	('ada@example.com', 'Sourdough schedule', $md$A loaf for Saturday lunch starts on Thursday evening.

1. **Thursday, 20:00**: feed the starter (50 g flour, 50 g water)
2. **Friday, 08:00**: mix 500 g flour, 350 g water, 100 g starter, 10 g salt
3. Four sets of stretch and folds, half an hour apart
4. Shape, then into the fridge overnight
5. **Saturday, 09:00**: bake at 250 °C, lid on for 20 minutes, off for 25

If the dough is slack, the kitchen was too warm: shorten the first rise.$md$, array['kitchen'], false, false, interval '20 days', interval '20 days'),

	('ada@example.com', 'Reading list', $md$Books people keep recommending, in no order:

- *The Lighthouse Keeper's Almanac*, for the long train rides
- *A Field Guide to Clouds*, finally
- *Small Engines and How to Mend Them*
- Anything about the history of maps

Ask the library about [their winter reading club](https://library.example.com/winter).$md$, array['books'], false, false, interval '30 days', interval '12 days'),

	('ada@example.com', 'One-to-one with Bo', $md$## Agenda

- How the launch rehearsal went, and what to change
- Bo wants to own the telemetry dashboard: yes
- Holiday dates in December

## Notes

Bo raised that the checklist is too long to read aloud. Split it into *before the pad* and
*at the pad*. Next one in two weeks.$md$, array['work', 'meetings'], false, false, interval '4 days', interval '4 days'),

	('ada@example.com', 'Shed ideas', $md$The shed could be a workshop if:

- the roof stops leaking (new felt, about a weekend)
- there is a bench along the window wall
- the bikes move to a rack outside

| Job | Cost | When |
| --- | --- | --- |
| Roof felt | 60 | March |
| Bench | 120 | April |
| Bike rack | 45 | Any time |$md$, array['home', 'ideas'], false, false, interval '15 days', interval '8 days'),

	('ada@example.com', 'Countdown script', $md$The little script that reads the countdown aloud, kept here so it doesn't get lost:

```sh
for n in 10 9 8 7 6 5 4 3 2 1; do
  say "$n"; sleep 1
done
say "Lift off"
```

Swap `say` for `espeak` on the field laptop.$md$, array['rocket', 'code'], false, false, interval '11 days', interval '11 days'),

	('ada@example.com', 'Old flat: things to sort', $md$- [x] Hand the keys back
- [x] Final meter reading
- [x] Forward the post

All done; kept for the deposit's reference number: **AC-20419**.$md$, array['home'], false, true, interval '60 days', interval '45 days'),

	('bo@example.com', 'Telemetry dashboard', $md$What the dashboard has to show, biggest first:

1. Altitude and speed
2. Battery voltage, in red under 7.2 V
3. Signal strength

Ask Ada about the launch week plan.$md$, array['work', 'rocket'], true, false, interval '3 days', interval '1 day'),

	('bo@example.com', 'Climbing log', $md$- Tuesday: the overhang at the wall, finally
- Thursday: rest
- Saturday: outdoors if it's dry$md$, array['climbing'], false, false, interval '5 days', interval '2 days')
) as n(email, title, body, tags, pinned, archived, age, edited) on lower(p.email) = n.email
where not exists (select 1 from notes existing where existing.person_id = p.id and existing.title = n.title);
