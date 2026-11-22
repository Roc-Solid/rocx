import pf.Db
import pf.Endpoint
import forms.Date
import Tasks

## Acme Tasks' data in Postgres (the tables are `migrations/0001_tables.sql`). Only the endpoints
## (`routes/**/+server.roc`) use it: it imports `pf.Db`, which only the server has, so no page or
## component may import it (`rocx build --client` warns if one does).
Store := [].{

	## What a task's row reads into. `due` and `assignee` may be null in Postgres, so they are
	## `Db.Nullable`: `Null`, or `Some(value)`.
	Row : { id : I64, title : Str, notes : Str, due : Db.Nullable(Str), assignee : Db.Nullable(Str), done : Bool }

	## Why the store couldn't do something.
	Problem : [NotFound, DbErr(Str), BadRow(Str)]

	## A task as the endpoints send it: a null is `""` there, as a form posts it.
	task_of : Row -> Tasks.Task
	task_of = |row| {
		id: row.id.to_str(),
		title: row.title,
		notes: row.notes,
		due: or_empty(row.due),
		assignee: or_empty(row.assignee),
		done: row.done,
	}

	## An endpoint's refusal for a problem: a 404, or a 500 that says why (which the middleware
	## logs: `Middlewares.identify`).
	refusal : Problem -> Endpoint.Refusal
	refusal = |problem|
		match problem {
			NotFound => NotFound
			DbErr(why) | BadRow(why) => Status(500, "The database failed: ${why}")
		}

	## Today, as Postgres has it (`2026-11-24`): what a task's due day is counted from.
	today! : {} => Try(Str, Problem)
	today! = |{}| {
		rows : List({ today : Str })
		rows = Db.all!("select current_date::text as today", [])?
		rows.first().map_ok(|row| row.today).map_err(|_| NotFound)
	}

	## Everyone on the team, by name.
	people! : {} => Try(List(Tasks.Person), Problem)
	people! = |{}| Ok(Db.all!("select id, name from people order by name", [])?)

	## Every list, oldest first, with its counts.
	lists! : {} => Try(List(Tasks.Summary), Problem)
	lists! = |{}| {
		rows : List({ id : I64, name : Str, open : I64, done : I64 })
		rows = Db.all!(
			"select l.id, l.name, count(t.id) filter (where not t.done) as open, count(t.id) filter (where t.done) as done from lists l left join tasks t on t.list_id = l.id group by l.id order by l.id",
			[],
		)?
		Ok(rows.map(|row| { id: row.id.to_str(), name: row.name, open: row.open.to_u64_wrap(), done: row.done.to_u64_wrap() }))
	}

	## A new list, named `name`: its id.
	add_list! : Str => Try(Str, Problem)
	add_list! = |name| {
		rows : List({ id : I64 })
		rows = Db.all!("insert into lists (name) values ($1) returning id", [Text(name)])?
		rows.first().map_ok(|row| row.id.to_str()).map_err(|_| NotFound)
	}

	## The list `id` (as its URL has it): its name.
	list! : Str => Try({ id : Str, name : Str }, Problem)
	list! = |id| {
		key = number(id)?
		rows : List({ name : Str })
		rows = Db.all!("select name from lists where id = $1", [Int(key)])?
		rows.first().map_ok(|row| { id, name: row.name }).map_err(|_| NotFound)
	}

	## The list's tasks, in their order.
	tasks! : Str => Try(List(Tasks.Task), Problem)
	tasks! = |list| {
		key = number(list)?
		rows : List(Row)
		rows = Db.all!("select id, title, notes, due::text as due, assignee, done from tasks where list_id = $1 order by position, id", [Int(key)])?
		Ok(rows.map(Store.task_of))
	}

	## The task `id`, and the list it is on.
	task! : Str => Try({ task : Tasks.Task, list : { id : Str, name : Str } }, Problem)
	task! = |id| {
		key = number(id)?
		rows : List({ id : I64, title : Str, notes : Str, due : Db.Nullable(Str), assignee : Db.Nullable(Str), done : Bool, list_id : I64, list_name : Str })
		rows = Db.all!(
			"select t.id, t.title, t.notes, t.due::text as due, t.assignee, t.done, l.id as list_id, l.name as list_name from tasks t join lists l on l.id = t.list_id where t.id = $1",
			[Int(key)],
		)?
		match rows.first() {
			Ok(row) => Ok({ task: Store.task_of({ id: row.id, title: row.title, notes: row.notes, due: row.due, assignee: row.assignee, done: row.done }), list: { id: row.list_id.to_str(), name: row.list_name } })
			Err(ListWasEmpty) => Err(NotFound)
		}
	}

	## A new task, last on its list: its id.
	add! : Str, { title : Str, due : Try(Date, [Missing]), assignee : Try(Str, [Missing]) } => Try(Str, Problem)
	add! = |list, { title, due, assignee }| {
		key = number(list)?
		rows : List({ id : I64 })
		rows = Db.all!(
			"insert into tasks (list_id, title, due, assignee, position) values ($1, $2, $3, $4, (select coalesce(max(position) + 1, 0) from tasks where list_id = $1)) returning id",
			[Int(key), Text(title), nullable(due.map_ok(Date.to_str)), nullable(assignee)],
		)?
		rows.first().map_ok(|row| row.id.to_str()).map_err(|_| NotFound)
	}

	## The task `id`, changed as its page's form says.
	save! : Str, { title : Str, notes : Str, due : Try(Date, [Missing]), assignee : Try(Str, [Missing]), done : Bool } => Try({}, Problem)
	save! = |id, { title, notes, due, assignee, done }| {
		key = number(id)?
		changed = Db.run!(
			"update tasks set title = $2, notes = $3, due = $4, assignee = $5, done = $6 where id = $1",
			[Int(key), Text(title), Text(notes), nullable(due.map_ok(Date.to_str)), nullable(assignee), Bool(done)],
		)?
		if (changed == 0) Err(NotFound) else Ok({})
	}

	## The task `id` done, or open again.
	toggle! : Str, Bool => Try({}, Problem)
	toggle! = |id, done| {
		key = number(id)?
		changed = Db.run!("update tasks set done = $2 where id = $1", [Int(key), Bool(done)])?
		if (changed == 0) Err(NotFound) else Ok({})
	}

	## The task `id` gone, and the list it was on (to go back to). Gone already is no problem: a
	## delete sent twice deletes once.
	remove! : Str => Try(Str, Problem)
	remove! = |id| {
		key = number(id)?
		rows : List({ list_id : I64 })
		rows = Db.all!("delete from tasks where id = $1 returning list_id", [Int(key)])?
		Ok(rows.first().map_ok(|row| row.list_id.to_str()) ?? "")
	}

	## The task `id` moved to place `to` on its list, the others closing up around it: the same
	## `Tasks.moved` the page applied while the move was on its way, then each task's position
	## written as its place in that order. In a transaction, so two moves at once take turns.
	move! : Tasks.Move => Try({}, Problem)
	move! = |move|
		Db.transaction!(
			|{}| {
				key = number(move.id)?
				lists : List({ list_id : I64 })
				lists = Db.all!("select list_id from tasks where id = $1 for update", [Int(key)])?
				list = lists.first().map_err(|_| NotFound)?
				order = Tasks.moved(Store.tasks!(list.list_id.to_str())?, move)
				# Each task's position is where its id is in `order` (array_position counts from 1).
				_ = Db.run!(
					"update tasks set position = array_position(string_to_array($2, ',')::bigint[], id) - 1 where list_id = $1",
					[Int(list.list_id), Text(Str.join_with(order.map(|task| task.id), ","))],
				)?
				Ok({})
			},
		)

	## Whether `id` is someone on the team.
	is_person! : Str => Try(Bool, Problem)
	is_person! = |id| {
		rows : List({ id : Str })
		rows = Db.all!("select id from people where id = $1", [Text(id)])?
		Ok(!rows.is_empty())
	}
}

## An id from a URL or a form: a number, or nothing there.
number : Str -> Try(I64, [NotFound])
number = |text| I64.from_str(text.trim()).map_err(|_| NotFound)

## `Null` for a value left out, as Postgres stores it.
nullable : Try(Str, [Missing]) -> Db.Value
nullable = |value|
	match value {
		Ok(text) => Text(text)
		Err(Missing) => Null
	}

or_empty : Db.Nullable(Str) -> Str
or_empty = |value|
	match value {
		Null => ""
		Some(text) => text
	}
