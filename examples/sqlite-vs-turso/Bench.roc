import pf.Actor
import pf.Db
import pf.Kv
import pf.Log
import pf.Time
import Workers

## The workloads, each timed in Roc around the `Db` calls it makes (`Time.now_nanos!`, the server's
## monotonic clock), on whichever engine the server opened (`Db.engine!`). Two runs:
##
## - `run!`, everyday work on fresh tables of a few thousand items: first what one caller does
##   alone, one statement after another, then what eight do at once (`Workers`, eight actors whose
##   turns run beside each other), timed from the first worker told to the last one done; then a
##   checkpoint, and the reads again. Each is a different shape of work: a write that commits alone,
##   many in one transaction, reads by key, scans of an index, a sum over the table, a group by
##   (and the same with its index ruled out), JSON, a recursive query; and, at once, writers on rows
##   of their own, transactions on counters of their own, transactions on one counter, and readers
##   beside writers. The checkpoint shows what Turso's MVCC does with rows it hasn't yet written
##   into its pages (it keeps them in a store of versions in memory, slower to walk), and with
##   rows it has.
## - `big!`, a million orders of ten thousand customers: loaded, checkpointed, then fetched one
##   and a hundred at a time (by key, and by an index), joined to their customers, and summed.
##
## What each wrote is checked after.
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
		$done = $done.append(logged!(measured("scan", "a sum over every row, no index", size.max(2) // 2, 1, 0, timed!(|{}| scans!(size.max(2) // 2))?)))
		$done = $done.append(logged!(measured("aggregate-no-index", "the group by, its index ruled out: a scan and a sort", size.max(2) // 2, 1, 0, timed!(|{}| aggregates_unindexed!(size.max(2) // 2))?)))

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

		# ---- After a checkpoint: what was written, in the database's own pages ----
		$done = $done.append(logged!(measured("checkpoint", "a checkpoint: what the log holds, written into the database's pages", 1, 1, 0, timed!(|{}| checkpoint!({}))?)))
		$done = $done.append(logged!(measured("read-point-checkpointed", "a row read by its key, after the checkpoint", 200 * size, 1, 0, timed!(|{}| read_points!(200 * size, rows))?)))
		$done = $done.append(logged!(measured("read-range-checkpointed", "50 rows of a category by its index, after the checkpoint", 20 * size, 1, 0, timed!(|{}| read_ranges!(20 * size))?)))
		$done = $done.append(logged!(measured("aggregate-checkpointed", "the group by, after the checkpoint", size.max(2) // 2, 1, 0, timed!(|{}| aggregates!(size.max(2) // 2))?)))
		$done = $done.append(logged!(measured("scan-checkpointed", "a sum over every row, after the checkpoint", size.max(2) // 2, 1, 0, timed!(|{}| scans!(size.max(2) // 2))?)))
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

	## The big run's answer: the engine it ran on, how many orders and customers, and each workload's
	## result.
	BigReport : { engine : Str, orders : U64, customers : U64, workloads : List(Bench.Measured) }

	## `asked` orders (1,000 to 5,000,000; a million for the docs' numbers) of a hundredth as many
	## customers, a hundred orders each, in tables made afresh: loaded, checkpointed, then read and
	## joined. An `Err` says which workload failed, or what a check of what it read found.
	big! : U64 => Try(Bench.BigReport, Str)
	big! = |asked| {
		orders = asked.max(1000).min(5000000).to_i64_wrap()
		customers = orders // 100
		fetches = orders.min(10000)
		ranges = (orders // 100).min(1000)
		tables!({})?
		var $done = []
		$done = $done.append(logged!(measured("load", "a row inserted, the customers then the orders, 100,000 to a statement", customers + orders, 1, 0, timed!(|{}| load!(customers, orders))?)))
		$done = $done.append(logged!(measured("load-checkpoint", "a checkpoint after the load", 1, 1, 0, timed!(|{}| checkpoint!({}))?)))
		$done = $done.append(logged!(measured("fetch-1", "an order by its key", fetches, 1, 0, timed!(|{}| fetch_ones!(fetches, orders))?)))
		$done = $done.append(logged!(measured("fetch-100", "100 orders by a range of keys", ranges, 1, 0, timed!(|{}| fetch_hundreds!(ranges, orders))?)))
		$done = $done.append(logged!(measured("fetch-100-by-index", "a customer's 100 orders, by an index", ranges, 1, 0, timed!(|{}| fetch_by_customer!(ranges, customers))?)))
		$done = $done.append(logged!(measured("join-1", "an order with its customer", fetches, 1, 0, timed!(|{}| join_ones!(fetches, orders))?)))
		$done = $done.append(logged!(measured("join-100", "a customer with their 100 orders", ranges, 1, 0, timed!(|{}| join_hundreds!(ranges, customers))?)))
		$done = $done.append(logged!(measured("join-top-10", "the ten customers who spent most: a join, a group by, a sort, over every order", 3, 1, 0, timed!(|{}| join_tops!(3))?)))
		$done = $done.append(logged!(measured("scan-orders", "a sum over every order", 3, 1, 0, timed!(|{}| order_scans!(3, orders))?)))
		Ok({ engine: engine!({}), orders: orders.to_u64_wrap(), customers: customers.to_u64_wrap(), workloads: $done })
	}
}

## A task for each of the eight workers, from its number (1 to 8).
eight : (I64 -> Workers.Task) -> List(Workers.Task)
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

## `count` sums over every item, no index: a scan of the table.
scans! : I64 => Try({}, Str)
scans! = |count| {
	var $i = 0
	while $i < count {
		$i = $i + 1
		found : Try(List({ n : I64, total : I64 }), [DbErr(Str), BadRow(Str)])
		found = Db.all!("select count(*) as n, sum(price) as total from items", [])
		_ = said(found).map_err(|why| "scan: ${why}")?
	}
	Ok({})
}

## `count` of the group by, its index ruled out (`category + 0` isn't the indexed column): a scan of
## the table and a sort, where with the index each engine walks the index and reads each row.
aggregates_unindexed! : I64 => Try({}, Str)
aggregates_unindexed! = |count| {
	var $i = 0
	while $i < count {
		$i = $i + 1
		found : Try(List({ category : I64, n : I64, total : I64, mean : F64 }), [DbErr(Str), BadRow(Str)])
		found = Db.all!("select category + 0 as category, count(*) as n, sum(price) as total, avg(price) as mean from items group by 1 order by 1", [])
		_ = said(found).map_err(|why| "aggregate-no-index: ${why}")?
	}
	Ok({})
}

## A checkpoint (`wal_checkpoint(truncate)`), on SQLite and Turso alike: what the log holds written
## into the database's own pages. On Turso's MVCC that takes rows out of its store of versions.
checkpoint! : {} => Try({}, Str)
checkpoint! = |{}|
	match Db.run!("pragma wal_checkpoint(truncate)", []) {
		Ok(_) => Ok({})
		Err(DbErr(why)) => Err("checkpoint: ${why}")
	}

# ---- A million rows ----

## The big run's tables, made afresh (dropped first, so no run deletes a million rows): customers,
## and their orders, with an index on whose they are. No migration makes them, so the statements
## that read them are `Db.unchecked`: `rocx check --sql` checks the app's SQL on a database built
## from its migrations, which hasn't these tables (D-058).
tables! : {} => Try({}, Str)
tables! = |{}|
	match Db.script!(
		Str.join_with(
			[
				"drop table if exists orders;",
				"drop table if exists customers;",
				"create table customers (id integer primary key, name text not null, city text not null);",
				"create table orders (id integer primary key, customer integer not null references customers (id), amount integer not null, created integer not null, note text not null);",
				"create index orders_customer on orders (customer);",
			],
			"\n",
		),
	) {
		Ok({}) => Ok({})
		Err(DbErr(why)) => Err("tables: ${why}")
	}

## How many rows one statement of the load inserts.
load_chunk : I64
load_chunk = 100000

## The customers (1 to `customers`) and orders (1 to `orders`), made by SQL itself from a count (a
## recursive query), `load_chunk` rows a statement, each its own transaction: order `i` is customer
## `(i × 7919) mod customers + 1`'s, so each has a hundred, spread over the table.
load! : I64, I64 => Try({}, Str)
load! = |customers, orders| {
	write!(
		"insert into customers (id, name, city) select i, 'customer ' || i, 'city ' || (i % 50) from (with recursive n(i) as (select 1 union all select i + 1 from n where i < $1) select i from n)",
		[Int(customers)],
	)
		.map_err(|why| "load customers: ${why}")?
	var $from = 1
	while $from <= orders {
		to = ($from + load_chunk - 1).min(orders)
		write!(
			"insert into orders (id, customer, amount, created, note) select i, (i * 7919) % $3 + 1, (i * 37) % 100000, 1700000000000 + i * 1000, 'order ' || i from (with recursive n(i) as (select $1 union all select i + 1 from n where i < $2) select i from n)",
			[Int($from), Int(to), Int(customers)],
		)
			.map_err(|why| "load orders: ${why}")?
		$from = to + 1
	}
	got : List({ n : I64 })
	got = said(Db.all!(Db.unchecked("select count(*) as n from orders"), []))?
	if (got.get(0).map_ok(|row| row.n) ?? 0) != orders {
		return Err("load: ${(got.get(0).map_ok(|row| row.n) ?? 0).to_str()} orders, not ${orders.to_str()}")
	}
	Ok({})
}

## An order's columns, as the fetches read them.
Order : { id : I64, customer : I64, amount : I64, created : I64, note : Str }

## `count` orders, each by its key, all over the table.
fetch_ones! : I64, I64 => Try({}, Str)
fetch_ones! = |count, orders| {
	var $i = 0
	while $i < count {
		i = $i
		$i = $i + 1
		found : Try(List(Order), [DbErr(Str), BadRow(Str)])
		found = Db.all!(Db.unchecked("select id, customer, amount, created, note from orders where id = $1"), [Int(Workers.pick(i, orders))])
		rows = said(found).map_err(|why| "fetch-1: ${why}")?
		if rows.len() != 1 {
			return Err("fetch-1: ${rows.len().to_str()} orders, not 1")
		}
	}
	Ok({})
}

## `count` runs of 100 orders, each by a range of keys.
fetch_hundreds! : I64, I64 => Try({}, Str)
fetch_hundreds! = |count, orders| {
	var $i = 0
	while $i < count {
		i = $i
		$i = $i + 1
		from = Workers.pick(i, orders - 99)
		found : Try(List(Order), [DbErr(Str), BadRow(Str)])
		found = Db.all!(Db.unchecked("select id, customer, amount, created, note from orders where id between $1 and $2"), [Int(from), Int(from + 99)])
		rows = said(found).map_err(|why| "fetch-100: ${why}")?
		if rows.len() != 100 {
			return Err("fetch-100: ${rows.len().to_str()} orders, not 100")
		}
	}
	Ok({})
}

## `count` customers' orders, a hundred each, by the index on whose they are.
fetch_by_customer! : I64, I64 => Try({}, Str)
fetch_by_customer! = |count, customers| {
	var $i = 0
	while $i < count {
		i = $i
		$i = $i + 1
		found : Try(List({ id : I64, amount : I64, created : I64 }), [DbErr(Str), BadRow(Str)])
		found = Db.all!(Db.unchecked("select id, amount, created from orders where customer = $1"), [Int(Workers.pick(i, customers))])
		rows = said(found).map_err(|why| "fetch-100-by-index: ${why}")?
		if rows.len() != 100 {
			return Err("fetch-100-by-index: ${rows.len().to_str()} orders, not 100")
		}
	}
	Ok({})
}

## `count` orders, each with its customer's name and city.
join_ones! : I64, I64 => Try({}, Str)
join_ones! = |count, orders| {
	var $i = 0
	while $i < count {
		i = $i
		$i = $i + 1
		found : Try(List({ id : I64, amount : I64, name : Str, city : Str }), [DbErr(Str), BadRow(Str)])
		found = Db.all!(Db.unchecked("select o.id as id, o.amount as amount, c.name as name, c.city as city from orders o join customers c on c.id = o.customer where o.id = $1"), [Int(Workers.pick(i + 3, orders))])
		rows = said(found).map_err(|why| "join-1: ${why}")?
		if rows.len() != 1 {
			return Err("join-1: ${rows.len().to_str()} rows, not 1")
		}
	}
	Ok({})
}

## `count` customers, each with their hundred orders.
join_hundreds! : I64, I64 => Try({}, Str)
join_hundreds! = |count, customers| {
	var $i = 0
	while $i < count {
		i = $i
		$i = $i + 1
		found : Try(List({ name : Str, id : I64, amount : I64 }), [DbErr(Str), BadRow(Str)])
		found = Db.all!(Db.unchecked("select c.name as name, o.id as id, o.amount as amount from customers c join orders o on o.customer = c.id where c.id = $1"), [Int(Workers.pick(i + 5, customers))])
		rows = said(found).map_err(|why| "join-100: ${why}")?
		if rows.len() != 100 {
			return Err("join-100: ${rows.len().to_str()} rows, not 100")
		}
	}
	Ok({})
}

## `count` times, the ten customers who spent most: every order joined to its customer, summed by
## customer, sorted, the first ten.
join_tops! : I64 => Try({}, Str)
join_tops! = |count| {
	var $i = 0
	while $i < count {
		$i = $i + 1
		found : Try(List({ id : I64, name : Str, total : I64, n : I64 }), [DbErr(Str), BadRow(Str)])
		found = Db.all!(Db.unchecked("select c.id as id, c.name as name, sum(o.amount) as total, count(*) as n from orders o join customers c on c.id = o.customer group by c.id order by total desc limit 10"), [])
		rows = said(found).map_err(|why| "join-top-10: ${why}")?
		if rows.len() != 10 or rows.any(|row| row.n != 100) {
			return Err("join-top-10: not ten customers of a hundred orders each")
		}
	}
	Ok({})
}

## `count` sums over every order: a scan of a million rows.
order_scans! : I64, I64 => Try({}, Str)
order_scans! = |count, orders| {
	var $i = 0
	while $i < count {
		$i = $i + 1
		found : Try(List({ n : I64, total : I64 }), [DbErr(Str), BadRow(Str)])
		found = Db.all!(Db.unchecked("select count(*) as n, sum(amount) as total from orders"), [])
		rows = said(found).map_err(|why| "scan-orders: ${why}")?
		if (rows.get(0).map_ok(|row| row.n) ?? 0) != orders {
			return Err("scan-orders: not every order counted")
		}
	}
	Ok({})
}

## How many times transaction bodies have run (`Workers`' bumps count each run in `Kv`).
runs! : {} => U64
runs! = |{}| (Kv.increment!("bench:runs", 0, { ttl_ms: 0 }) ?? 0).to_u64_wrap()

## `messages`, one to each worker (`w1`, `w2`…), done at once: each worker asked first, so its state
## is read before the clock starts; then all given their work, and asked again, each answer waiting
## for that work. The time from the first tell to the last answer, or why a worker failed.
together! : List(Workers.Task) => Try(U64, Str)
together! = |messages| {
	keys = messages.map_with_index(|_, n| "w${(n + 1).to_str()}")
	for key in keys {
		_ = Workers.ready.ask!(key, {}).map_err(|ActorErr(why)| "${key}: ${why}")?
		Kv.set!("bench:${key}", "", { ttl_ms: 0 })
	}
	started = Time.now_nanos!({})
	var $n = 0
	for message in messages {
		Workers.work.tell!(keys.get($n) ?? "w1", message)
		$n = $n + 1
	}
	for key in keys {
		_ = Workers.ready.ask!(key, {}).map_err(|ActorErr(why)| "${key}: ${why}")?
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
