import forms.Date
import TaskForm

## The app's rules: what a task is, which tasks a filter shows, and what each change the page
## sends (a toggle, a move, a delete, an add) does to a list. Plain Roc on no platform, so the
## server and the browser run the same functions: the page shows a change at once, before the
## server has it (`Tasks.showing`), and the server makes the very same change (`Store`).
Tasks := [].{

	## A task, as the endpoints send it. `due` is a day (`2026-11-24`) and `assignee` a person's id;
	## each is `""` when there is none, as a form posts it. (In the database they are null, and `Store`
	## reads them as `Db.Nullable(Str)`.)
	Task : { id : Str, title : Str, notes : Str, due : Str, assignee : Str, done : Bool }

	## Someone on the team.
	Person : { id : Str, name : Str }

	## A list on the front page and down the side: how many of its tasks are open, and how many done.
	Summary : { id : Str, name : Str, open : U64, done : U64 }

	## What every page may want to know (`GET /api/team`): who you are (a person's id, or `""`),
	## everyone on the team, and every list.
	Team : { me : Str, people : List(Person), lists : List(Summary) }

	## A list's page (`GET /lists/:id`): the list, its tasks in their order, the team, who you are,
	## and today, which due days are counted from.
	Sheet : { id : Str, name : Str, tasks : List(Task), people : List(Person), me : Str, today : Str }

	## A task's page (`GET /tasks/:id`): the task, the list it is on, and the team.
	Detail : { task : Task, list : { id : Str, name : Str }, people : List(Person) }

	## Which tasks a list shows: `?show=open` in its URL.
	Filter : [All, Open, Done, Mine]

	## What the changes to a list send: a plain form posts its fields, which the endpoint reads by
	## these types (`done=true` a `Bool`, `to=2` a `U64`: D-038), and an action (`use_action!`)
	## sends the same record as JSON, so one endpoint answers both. Each says where things end up
	## (done or not, at which place), not "one more", so applying one twice changes nothing: the
	## page applies the changes still on their way to data the server may already have changed
	## (DECISIONS.md, D-030).
	Toggle : { id : Str, done : Bool }
	Move : { id : Str, to : U64 }
	Remove : { id : Str }

	## The changes on their way to the server, as `use_submissions!` lists them: an add as its form
	## reads it (`TaskForm.adding`, which its endpoint's body is checked by, D-093).
	Pending : { toggles : List(Toggle), moves : List(Move), removes : List(Remove), adds : List(TaskForm.Adding) }

	## How soon a task is due, for its badge.
	Due : { label : Str, tone : [Overdue, Today, Soon, Later] }

	filters : List(Filter)
	filters = [All, Open, Done, Mine]

	## The filter a list's query asks for (`show=open`); anything else shows them all.
	filter_of : Str -> Filter
	filter_of = |query| {
		asked =
			query
				.split_on("&")
				.keep_oks(|pair| pair.split_first("="))
				.find_first(|{ before, .. }| before == "show")
		match asked {
			Ok({ after, .. }) => Tasks.filters.find_first(|filter| Tasks.filter_name(filter) == after) ?? All
			Err(NotFound) => All
		}
	}

	## A filter as its URL says it: `open`, and `all`.
	filter_name : Filter -> Str
	filter_name = |filter|
		match filter {
			All => "all"
			Open => "open"
			Done => "done"
			Mine => "mine"
		}

	## The tasks a filter shows; `Mine` are those assigned to `me` (a person's id, or `""`).
	visible : List(Task), Filter, Str -> List(Task)
	visible = |tasks, filter, me|
		match filter {
			All => tasks
			Open => tasks.drop_if(|task| task.done)
			Done => tasks.keep_if(|task| task.done)
			Mine => if (me.is_empty()) [] else tasks.keep_if(|task| task.assignee == me)
		}

	## How many aren't done yet.
	open_count : List(Task) -> U64
	open_count = |tasks| tasks.count_if(|task| !task.done)

	## "3 open", "All done", "Nothing yet".
	open_label : List(Task) -> Str
	open_label = |tasks| {
		open = Tasks.open_count(tasks)
		if (tasks.is_empty()) "Nothing yet" else if (open == 0) "All done" else "${open.to_str()} open"
	}

	## A task done, or open again.
	toggled : List(Task), Toggle -> List(Task)
	toggled = |tasks, { id, done }| tasks.map(|task| if (task.id == id) { ..task, done: done } else task)

	## A task gone.
	removed : List(Task), Remove -> List(Task)
	removed = |tasks, { id }| tasks.drop_if(|task| task.id == id)

	## A task at another place: taken out, then put at `to` (counted without it), or last.
	moved : List(Task), Move -> List(Task)
	moved = |tasks, { id, to }|
		match tasks.find_first_index(|task| task.id == id) {
			Ok(from) =>
				match tasks.get(from) {
					Ok(task) => {
						rest = tasks.drop_at(from)
						rest.insert(U64.min(to, rest.len()), task) ?? tasks
					}
					Err(OutOfBounds) => tasks
				}
			Err(_) => tasks
		}

	## Tasks being added, at the end, as they will be once the server has them. Until then each has
	## an id of its own, `new-0`, `new-1`…, which no task in the database has (`Tasks.is_saving`).
	added : List(Task), List(TaskForm.Adding) -> List(Task)
	added = |tasks, adding| tasks.concat(adding.map_with_index(|new, index| { id: "new-${index.to_str()}", title: new.title, notes: "", due: new.due.map_ok(Date.to_str) ?? "", assignee: new.assignee ?? "", done: Bool.False }))

	## Whether a task is on its way to the server, not in it yet.
	is_saving : Task -> Bool
	is_saving = |task| task.id.starts_with("new-")

	## What the page shows: the server's tasks with every change still on its way applied.
	showing : List(Task), Pending -> List(Task)
	showing = |tasks, pending| {
		with_toggles = pending.toggles.fold(tasks, Tasks.toggled)
		with_moves = pending.moves.fold(with_toggles, Tasks.moved)
		Tasks.added(pending.removes.fold(with_moves, Tasks.removed), pending.adds)
	}

	## Where a task dropped on `target` goes: to the target's place, so it ends up just past it,
	## whichever way it came from.
	place_of : List(Task), Str -> Try(U64, [NotFound])
	place_of = |tasks, target| tasks.find_first_index(|task| task.id == target)

	## Where a task goes when it moves up the tasks shown (`shown`, which a filter may have
	## thinned): just before the one above it, at that one's place in the whole list.
	place_above : List(Task), List(Task), Str -> Try(U64, [Top])
	place_above = |tasks, shown, id|
		match shown.find_first_index(|task| task.id == id) {
			Ok(index) if index > 0 =>
				match shown.get(index - 1) {
					Ok(above) => Tasks.place_of(tasks, above.id).map_err(|_| Top)
					Err(_) => Err(Top)
				}
			_ => Err(Top)
		}

	## Where a task goes when it moves down: just after the one below it. Counted without the
	## task itself, that is the place the one below has now.
	place_below : List(Task), List(Task), Str -> Try(U64, [Bottom])
	place_below = |tasks, shown, id|
		match shown.find_first_index(|task| task.id == id) {
			Ok(index) =>
				match shown.get(index + 1) {
					Ok(below) => Tasks.place_of(tasks, below.id).map_err(|_| Bottom)
					Err(_) => Err(Bottom)
				}
			Err(_) => Err(Bottom)
		}

	## How soon `day` is, seen from `today` (both as `2026-11-24`): "Overdue · Nov 20", "Today",
	## "Tomorrow", "Fri, Nov 27", "Dec 24", or "Mar 3, 2027" in another year.
	due : Str, Str -> Try(Due, [NoDue])
	due = |day, today|
		match (Date.from_str(day), Date.from_str(today)) {
			(Ok(date), Ok(now)) => {
				days = Date.days_between(now, date)
				year = if (date.year() == now.year()) "" else ", ${date.year().to_str()}"
				short = "${month_name(date.month())} ${date.day().to_str()}${year}"
				if days < 0 {
					Ok({ label: "Overdue · ${short}", tone: Overdue })
				} else if days == 0 {
					Ok({ label: "Today", tone: Today })
				} else if days == 1 {
					Ok({ label: "Tomorrow", tone: Soon })
				} else if days < 7 {
					Ok({ label: "${weekday(date)}, ${short}", tone: Soon })
				} else {
					Ok({ label: short, tone: Later })
				}
			}
			_ => Err(NoDue)
		}

	## A person's initials, for their avatar: "AS" for Avery Stone.
	initials : Str -> Str
	initials = |name| {
		words = name.split_on(" ").keep_if(|word| !word.is_empty()).take_first(2)
		Str.join_with(words.keep_oks(|word| Str.from_utf8(word.to_utf8().take_first(1))), "")
	}

	## The name of the person with `id`, or `""`.
	name_of : List(Person), Str -> Str
	name_of = |people, id|
		match people.find_first(|person| person.id == id) {
			Ok(person) => person.name
			Err(NotFound) => ""
		}

	## Someone's first name: "Avery".
	first_name : Str -> Str
	first_name = |name| name.split_on(" ").first() ?? name
}

month_name : I64 -> Str
month_name = |month| ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].get((month - 1).to_u64_wrap()) ?? ""

## The day of the week: 1970-01-01, day 0, was a Thursday.
weekday : Date -> Str
weekday = |date| ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].get(((Date.days(date) % 7 + 7 + 3) % 7).to_u64_wrap()) ?? ""

# The expects: `roc test main.roc` runs them.

task : Str, Bool, Str -> Tasks.Task
task = |id, done, assignee| { id, title: "Task ${id}", notes: "", due: "", assignee, done }

sample : List(Tasks.Task)
sample = [task("1", Bool.False, "avery"), task("2", Bool.True, "jun"), task("3", Bool.False, ""), task("4", Bool.False, "jun")]

ids : List(Tasks.Task) -> Str
ids = |tasks| Str.join_with(tasks.map(|each| each.id), ",")

expect Tasks.filter_of("show=open") == Open
expect Tasks.filter_of("page=2&show=mine") == Mine
expect Tasks.filter_of("show=everything") == All
expect Tasks.filter_of("") == All
expect ids(Tasks.visible(sample, Open, "")) == "1,3,4"
expect ids(Tasks.visible(sample, Done, "")) == "2"
expect ids(Tasks.visible(sample, Mine, "jun")) == "2,4"
expect ids(Tasks.visible(sample, Mine, "")) == ""
expect Tasks.open_label(sample) == "3 open"
expect Tasks.open_label([]) == "Nothing yet"
expect Tasks.open_label(Tasks.visible(sample, Done, "")) == "All done"

# A toggle, a delete and a move say where things end up, so applying one twice is applying it once.
expect ids(Tasks.visible(Tasks.toggled(Tasks.toggled(sample, { id: "2", done: Bool.False }), { id: "2", done: Bool.False }), Done, "")) == ""
expect ids(Tasks.removed(Tasks.removed(sample, { id: "3" }), { id: "3" })) == "1,2,4"
expect ids(Tasks.moved(sample, { id: "4", to: 0 })) == "4,1,2,3"
expect ids(Tasks.moved(Tasks.moved(sample, { id: "4", to: 0 }), { id: "4", to: 0 })) == "4,1,2,3"
expect ids(Tasks.moved(sample, { id: "1", to: 9 })) == "2,3,4,1"
expect ids(Tasks.moved(sample, { id: "9", to: 0 })) == "1,2,3,4"

# Dropped on another task, a task takes its place: past it, from above or from below.
expect ids(Tasks.moved(sample, { id: "1", to: (Tasks.place_of(sample, "3") ?? 0) })) == "2,3,1,4"
expect ids(Tasks.moved(sample, { id: "4", to: (Tasks.place_of(sample, "2") ?? 0) })) == "1,4,2,3"

# Moving among the open tasks (1, 3, 4): 3 goes up past 1, and 1 goes down past 3.
expect Tasks.place_above(sample, Tasks.visible(sample, Open, ""), "3") == Ok(0)
expect Tasks.place_above(sample, sample, "1") == Err(Top)
expect ids(Tasks.moved(sample, { id: "1", to: (Tasks.place_below(sample, Tasks.visible(sample, Open, ""), "1") ?? 0) })) == "2,3,1,4"
expect Tasks.place_below(sample, sample, "4") == Err(Bottom)

expect ids(Tasks.showing(sample, { toggles: [], moves: [{ id: "3", to: 0 }], removes: [{ id: "2" }], adds: [{ title: "Milk", due: Err(Missing), assignee: Err(Missing) }] })) == "3,1,4,new-0"
expect Tasks.showing(sample, { toggles: [], moves: [], removes: [], adds: [{ title: "Milk", due: Err(Missing), assignee: Ok("jun") }] }).last().map_ok(|each| (each.title, each.due, each.assignee)) == Ok(("Milk", "", "jun"))

expect Tasks.due("2026-11-20", "2026-11-22") == Ok({ label: "Overdue · Nov 20", tone: Overdue })
expect Tasks.due("2026-11-22", "2026-11-22") == Ok({ label: "Today", tone: Today })
expect Tasks.due("2026-11-23", "2026-11-22") == Ok({ label: "Tomorrow", tone: Soon })
expect Tasks.due("2026-11-27", "2026-11-22") == Ok({ label: "Fri, Nov 27", tone: Soon })
expect Tasks.due("2026-12-24", "2026-11-22") == Ok({ label: "Dec 24", tone: Later })
expect Tasks.due("2027-03-03", "2026-11-22") == Ok({ label: "Mar 3, 2027", tone: Later })
expect Tasks.due("", "2026-11-22") == Err(NoDue)
expect Tasks.initials("Avery Stone") == "AS"
expect Tasks.initials("Jun") == "J"
expect Tasks.first_name("Avery Stone") == "Avery"
