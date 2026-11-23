import pf.Actor
import pf.Db
import pf.Kv
import pf.Log
import pf.Time
import Workers

## The workloads, each timed in Roc around the `Db` calls it makes (`Time.now_nanos!`, the server's
## monotonic clock), on whichever engine the server opened (`Db.engine!`). A run does them in order
## on fresh tables (`run!`): first those one caller does alone, one statement after another, then
## those eight do at once (`Workers`, eight actors whose turns run beside each other), timed from the
## first worker told to the last one done. Each is a different shape of work: a write that commits
## alone, many in one transaction, reads by key, scans of an index, sums over the table, JSON, a
## recursive query; and, at once, writers on rows of their own, transactions on counters of their
## own, transactions on one counter, and readers beside writers. What they wrote is checked after.
Bench := [].{

	## A workload's result: its name, what one of its operations is, how many it did, how many
	## callers did them at once, how long they all took (nanoseconds), and how many times
	## transaction bodies ran (more than the transactions when some lost to another's write and ran
	## again, on Turso; 0 for a workload that runs none).
	Measured : { name : Str, what : Str, ops : U64, callers : U64, ns : U64, runs : U64 }

	## A run's answer: the engine it ran on, the SQLite version it answers to, its size, how many
	## items the table held, and each workload's result.
	Report : { engine : Str, version : Str, size : U64, rows : U64, workloads : List(Bench.Measured) }

	## Every workload once, `size` scaling them (1 to 1000: how many items the table holds, 200 for
	## each step of size); fresh tables first. An `Err` says which workload failed, or what a check
	## of what they wrote found.
	run! : U64 => Try(Bench.Report, Str)
	run! = |asked| {
		size = asked.max(1).min(1000).to_i64_wrap()
		rows = 200 * size
		fresh!({})?
		var $done = []

		# ---- One caller ----
		$done = $done.append(logged!(measured("insert-each", "an insert committed alone", 20 * size, 1, 0, timed!(|{}| insert_each!(rows + 1, 20 * size))?)))
		$done = $done.append(logged!(measured("insert-batch", "an insert, all in one transaction", rows, 1, 1, timed!(|{}| insert_batch!(rows))?)))
		$done = $done.append(logged!(measured("read-point", "a row read by its key", 200 * size, 1, 0, timed!(|{}| read_points!(200 * size, rows))?)))
		$done = $done.append(logged!(measured("read-range", "50 rows of a category, by its index", 20 * size, 1, 0, timed!(|{}| read_ranges!(20 * size))?)))
		$done = $done.append(logged!(measured("aggregate", "a group by over the whole table", size.max(2) // 2, 1, 0, timed!(|{}| aggregates!(size.max(2) // 2))?)))
		$done = $done.append(logged!(measured("update-each", "an update committed alone", 20 * size, 1, 0, timed!(|{}| update_each!(20 * size, rows))?)))
		$done = $done.append(logged!(measured("json", "a row's JSON read apart and put together", 50 * size, 1, 0, timed!(|{}| json_reads!(50 * size, rows))?)))
		$done = $done.append(logged!(measured("recursive", "a recursive query counting to 10,000", size.max(2) // 2, 1, 0, timed!(|{}| recursive!(size.max(2) // 2))?)))

		# ---- Eight callers at once ----
		inserts = 5 * size
		$done = $done.append(logged!(measured("concurrent-insert", "an insert committed alone, eight writers at once", 8 * inserts, 8, 0, together!(eight(|w| Insert({ worker: w, from: 1, count: inserts })))?)))
		own = 2 * size
		before_own = runs!({})
		took_own = together!(eight(|w| Bump({ counter: w, count: own })))?
		$done = $done.append(logged!(measured("concurrent-own-rows", "a transaction on a counter of its own, eight at once", 8 * own, 8, runs!({}) - before_own, took_own)))
		shared = size
		before_shared = runs!({})
		took_shared = together!(eight(|_| Bump({ counter: 0, count: shared })))?
		$done = $done.append(logged!(measured("concurrent-one-row", "a transaction on one counter, eight at once", 8 * shared, 8, runs!({}) - before_shared, took_shared)))
		reads = 20 * size
		writes = 2 * size
		mixed = eight(|w| if (w <= 4) Read({ count: reads, rows, seed: w * 1000 }) else Insert({ worker: w, from: inserts + 1, count: writes }))
		$done = $done.append(logged!(measured("concurrent-mixed", "a read or an insert, four readers and four writers at once", 4 * reads + 4 * writes, 8, 0, together!(mixed)?)))

		checked!({ own, shared, events: 8 * inserts + 4 * writes, rows: rows + 20 * size })?
		version : List({ version : Str })
		version = said(Db.all!("select sqlite_version() as version", []))?
		Ok({
			engine: engine!({}),
			version: version.get(0).map_ok(|row| row.version) ?? "",
			size: size.to_u64_wrap(),
			rows: rows.to_u64_wrap(),
			workloads: $done,
		})
	}
}

## A message for each of the eight workers, from its number (1 to 8).
eight : (I64 -> Workers.Message) -> List(Workers.Message)
eight = |message| {
	var $all = []
	var $w = 1
	while $w <= 8 {
		$all = $all.append(message($w))
		$w = $w + 1
	}
	$all
}

## A workload's result, from what it did and how long it took.
measured : Str, Str, I64, I64, U64, U64 -> Bench.Measured
measured = |name, what, ops, callers, runs, ns| { name, what, ops: ops.to_u64_wrap(), callers: callers.to_u64_wrap(), ns, runs }

## A workload's result, said on the log as well (outside its time): which ran, and how long it took.
logged! : Bench.Measured => Bench.Measured
logged! = |result| {
	Log.info!("bench: ${result.name}", { ops: result.ops, ms: result.ns // 1000000, runs: result.runs })
	result
}

## The engine the server runs on, as the report names it.
engine! : {} => Str
engine! = |{}|
	match Db.engine!({}) {
		Postgres => "postgres"
		Sqlite => "sqlite"
		Turso => "turso"
		None => "none"
	}

## How long `work!` took, in nanoseconds.
timed! : ({} => Try({}, Str)) => Try(U64, Str)
timed! = |work!| {
	started = Time.now_nanos!({})
	work!({})?
	Ok(Time.now_nanos!({}) - started)
}

## A database error, as the report says it.
said : Try(a, [DbErr(Str), BadRow(Str)]) -> Try(a, Str)
said = |tried|
	match tried {
		Ok(value) => Ok(value)
		Err(DbErr(why)) => Err(why)
		Err(BadRow(why)) => Err(why)
	}

## A statement that writes, its error as text.
write! : Str, List(Db.Value) => Try({}, Str)
write! = |sql, params|
	match Db.run!(sql, params) {
		Ok(_) => Ok({})
		Err(DbErr(why)) => Err(why)
	}

## Empty tables, and the counters at 0: the shared one (0) and one for each worker (1 to 8). On
## Turso, a checkpoint after the deletes: without one, rows deleted after Turso checkpointed them
## slow every later statement down, a run after two or three on one file taking minutes, not
## seconds (turso_core 0.8.4, D-049).
fresh! : {} => Try({}, Str)
fresh! = |{}| {
	match Db.script!("delete from items; delete from events; delete from counters; insert into counters (id, value) values (0, 0), (1, 0), (2, 0), (3, 0), (4, 0), (5, 0), (6, 0), (7, 0), (8, 0);") {
		Ok({}) => {}
		Err(DbErr(why)) => return Err("fresh tables: ${why}")
	}
	if Db.engine!({}) == Turso {
		match Db.run!("pragma wal_checkpoint(truncate)", []) {
			Ok(_) => {}
			Err(DbErr(why)) => return Err("checkpoint: ${why}")
		}
	}
	Ok({})
}

## An item's columns, from its id: the same items on every engine.
item : I64 -> List(Db.Value)
item = |id| [
	Int(id),
	Text("item ${id.to_str()}"),
	Int(id % 100),
	Int((id * 37) % 10000),
	Text("{\"tags\":[\"t${(id % 7).to_str()}\",\"t${(id % 11).to_str()}\"],\"score\":${(id % 1000).to_str()}}"),
]

insert_sql : Str
insert_sql = "insert into items (id, name, category, price, data) values ($1, $2, $3, $4, $5)"

## `count` inserts from id `from`, each committed alone.
insert_each! : I64, I64 => Try({}, Str)
insert_each! = |from, count| {
	var $i = 0
	while $i < count {
		i = $i
		$i = $i + 1
		write!(insert_sql, item(from + i)).map_err(|why| "insert-each: ${why}")?
	}
	Ok({})
}

## Items 1 to `rows`, all in one transaction.
insert_batch! : I64 => Try({}, Str)
insert_batch! = |rows| {
	done = Db.transaction!(
		|{}| {
			var $id = 1
			while $id <= rows {
				_ = Db.run!(insert_sql, item($id))?
				$id = $id + 1
			}
			Ok({})
		},
	)
	match done {
		Ok({}) => Ok({})
		Err(DbErr(why)) => Err("insert-batch: ${why}")
	}
}

## `count` items read by their id, all over the first `rows`.
read_points! : I64, I64 => Try({}, Str)
read_points! = |count, rows| {
	var $i = 0
	while $i < count {
		i = $i
		$i = $i + 1
		found : Try(List({ name : Str, price : I64 }), [DbErr(Str), BadRow(Str)])
		found = Db.all!("select name, price from items where id = $1", [Int(Workers.pick(i, rows))])
		_ = said(found).map_err(|why| "read-point: ${why}")?
	}
	Ok({})
}

## `count` scans of a category's first 50 items, by its index.
read_ranges! : I64 => Try({}, Str)
read_ranges! = |count| {
	var $i = 0
	while $i < count {
		i = $i
		$i = $i + 1
		found : Try(List({ id : I64, name : Str, price : I64 }), [DbErr(Str), BadRow(Str)])
		found = Db.all!("select id, name, price from items where category = $1 order by id limit 50", [Int(i % 100)])
		_ = said(found).map_err(|why| "read-range: ${why}")?
	}
	Ok({})
}

## `count` sums over every item, a row for each category.
aggregates! : I64 => Try({}, Str)
aggregates! = |count| {
	var $i = 0
	while $i < count {
		$i = $i + 1
		found : Try(List({ category : I64, n : I64, total : I64, mean : F64 }), [DbErr(Str), BadRow(Str)])
		found = Db.all!("select category, count(*) as n, sum(price) as total, avg(price) as mean from items group by category order by category", [])
		_ = said(found).map_err(|why| "aggregate: ${why}")?
	}
	Ok({})
}

## `count` updates of items all over the first `rows`, each committed alone.
update_each! : I64, I64 => Try({}, Str)
update_each! = |count, rows| {
	var $i = 0
	while $i < count {
		i = $i
		$i = $i + 1
		write!("update items set price = price + 1 where id = $1", [Int(Workers.pick(i + 7, rows))]).map_err(|why| "update-each: ${why}")?
	}
	Ok({})
}

## `count` items' JSON read apart (a tag, the score) and put together again.
json_reads! : I64, I64 => Try({}, Str)
json_reads! = |count, rows| {
	var $i = 0
	while $i < count {
		i = $i
		$i = $i + 1
		found : Try(List({ tag : Str, score : I64, made : Str }), [DbErr(Str), BadRow(Str)])
		found = Db.all!(
			"select json_extract(data, '$.tags[0]') as tag, json_extract(data, '$.score') as score, json_object('id', id, 'tags', json_extract(data, '$.tags')) as made from items where id = $1",
			[Int(Workers.pick(i + 13, rows))],
		)
		_ = said(found).map_err(|why| "json: ${why}")?
	}
	Ok({})
}

## `count` recursive queries, each counting to 10,000 and summing.
recursive! : I64 => Try({}, Str)
recursive! = |count| {
	var $i = 0
	while $i < count {
		$i = $i + 1
		found : Try(List({ total : I64 }), [DbErr(Str), BadRow(Str)])
		found = Db.all!("with recursive n(i) as (select 1 union all select i + 1 from n where i < 10000) select sum(i) as total from n", [])
		_ = said(found).map_err(|why| "recursive: ${why}")?
	}
	Ok({})
}

## How many times transaction bodies have run (`Workers`' bumps count each run in `Kv`).
runs! : {} => U64
runs! = |{}| (Kv.increment!("bench:runs", 0, { ttl_ms: 0 }) ?? 0).to_u64_wrap()

## `messages`, one to each worker (`w1`, `w2`…), done at once: each worker asked first, so its state
## is read before the clock starts; then all told, and asked again, each answer waiting for what it
## was told. The time from the first tell to the last answer, or why a worker failed.
together! : List(Workers.Message) => Try(U64, Str)
together! = |messages| {
	keys = messages.map_with_index(|_, n| "w${(n + 1).to_str()}")
	for key in keys {
		_ = Actor.ask!(Workers.kind, key, Ready).map_err(|ActorErr(why)| "${key}: ${why}")?
		Kv.set!("bench:${key}", "", { ttl_ms: 0 })
	}
	started = Time.now_nanos!({})
	var $n = 0
	for message in messages {
		Actor.tell!(Workers.kind, keys.get($n) ?? "w1", message)
		$n = $n + 1
	}
	for key in keys {
		_ = Actor.ask!(Workers.kind, key, Ready).map_err(|ActorErr(why)| "${key}: ${why}")?
	}
	took = Time.now_nanos!({}) - started
	for key in keys {
		outcome : Try(Str, [NotFound, BadValue(Str)])
		outcome = Kv.get!("bench:${key}")
		match outcome {
			Ok("") => {}
			Ok(why) => return Err("${key}: ${why}")
			Err(_) => return Err("${key} left no word of how it went")
		}
	}
	Ok(took)
}

## What the workloads wrote, checked: every counter at what its transactions made it (none lost to
## another's write), every event and item there.
checked! : { own : I64, shared : I64, events : I64, rows : I64 } => Try({}, Str)
checked! = |expected| {
	counters : List({ id : I64, value : I64 })
	counters = said(Db.all!("select id, value from counters order by id", []))?
	for counter in counters {
		wanted = if (counter.id == 0) 8 * expected.shared else expected.own
		if counter.value != wanted {
			return Err("check: counter ${counter.id.to_str()} is ${counter.value.to_str()}, not ${wanted.to_str()}: a transaction's write was lost")
		}
	}
	events : List({ n : I64 })
	events = said(Db.all!("select count(*) as n from events", []))?
	got_events = events.get(0).map_ok(|row| row.n) ?? 0
	if got_events != expected.events {
		return Err("check: ${got_events.to_str()} events, not ${expected.events.to_str()}")
	}
	items : List({ n : I64 })
	items = said(Db.all!("select count(*) as n from items", []))?
	got_items = items.get(0).map_ok(|row| row.n) ?? 0
	if got_items != expected.rows {
		return Err("check: ${got_items.to_str()} items, not ${expected.rows.to_str()}")
	}
	Ok({})
}

expect measured("x", "y", 3, 1, 0, 9).ops == 3
expect item(7).len() == 5
