import pf.Actor
import pf.Db
import pf.Kv
import Sales

## Eight actors, `w1` to `w8`, whose turns run at once: the concurrent workloads' writers and
## readers. An actor takes one turn at a time, but different actors run beside each other, each turn
## a call of its own, so eight of them told at once make eight callers of the database at once. Each
## keeps no state worth writing (`{}`, never changed, so no turn writes `rocx_actors`), does the work
## it is given (`work`), and leaves how that went in `Kv` (`bench:w1`…: "" when it went well, else
## why) for `Bench` to read, since a told actor's reply goes nowhere; being asked if it is `ready`
## leaves that be.
Workers := [].{

	name = |{}| "bench-worker"
	initial = |_key| {}

	## Whether it is ready: its first turn reads its state, so it is asked this before the clock
	## starts, and again after, to wait for the work it was given.
	ready : Actor.Method(Workers, _, Str, {}, {}, {})
	ready = Actor.method("ready", |{ state, .. }| { state, reply: {} })

	## Does `input`, and leaves how that went in `Kv`.
	work : Actor.Method(Workers, _, Str, {}, Workers.Task, {})
	work = Actor.method(
		"work",
		|{ me, state, input, .. }| {
			outcome =
				match Workers.work!(input) {
					Ok({}) => ""
					Err(why) => why
				}
			Kv.set!("bench:${me.key()}", outcome, { ttl_ms: 0 })
			{ state, reply: {} }
		},
	)

	## The work a worker is given: insert `count` events of its own, numbered from `from`; run
	## `count` transactions that each read counter `counter` and write it back one more (each run of
	## a transaction's body counted in `Kv`'s `bench:runs`); read `count` items by their id, of the
	## first `rows`, starting from `seed`; or write `count` sales of its own customer (its number),
	## numbered from `from`, each in a transaction (`Sales.sell!`), with its receipt job queued if
	## `job`.
	Task : [
		Insert({ worker : I64, from : I64, count : I64 }),
		Bump({ counter : I64, count : I64 }),
		Read({ count : I64, rows : I64, seed : I64 }),
		Sell({ worker : I64, from : I64, count : I64, job : Bool }),
	]

	work! : Workers.Task => Try({}, Str)
	work! = |message|
		match message {
			Insert({ worker, from, count }) => {
				var $i = 0
				while $i < count {
					n = from + $i
					match Db.run!("insert into events (worker, n, body) values ($1, $2, $3)", [Int(worker), Int(n), Text("event ${n.to_str()} of worker ${worker.to_str()}")]) {
						Ok(_) => {}
						Err(DbErr(why)) => return Err("insert: ${why}")
					}
					$i = $i + 1
				}
				Ok({})
			}
			Bump({ counter, count }) => {
				var $i = 0
				while $i < count {
					$i = $i + 1
					bumped = Db.transaction!(
						|{}| {
							_ = Kv.increment!("bench:runs", 1, { ttl_ms: 0 })
							now : List({ value : I64 })
							now = Db.all!("select value from counters where id = $1", [Int(counter)])?
							was = now.get(0).map_ok(|row| row.value) ?? 0
							_ = Db.run!("update counters set value = $1 where id = $2", [Int(was + 1), Int(counter)])?
							Ok({})
						},
					)
					match bumped {
						Ok({}) => {}
						Err(DbErr(why)) => return Err("bump: ${why}")
						Err(BadRow(why)) => return Err("bump: ${why}")
					}
				}
				Ok({})
			}
			Read({ count, rows, seed }) => {
				var $i = 0
				while $i < count {
					found : Try(List({ price : I64 }), [DbErr(Str), BadRow(Str)])
					found = Db.all!("select price from items where id = $1", [Int(Workers.pick(seed + $i, rows))])
					$i = $i + 1
					match found {
						Ok(_) => {}
						Err(DbErr(why)) => return Err("read: ${why}")
						Err(BadRow(why)) => return Err("read: ${why}")
					}
				}
				Ok({})
			}
			Sell({ worker, from, count, job }) => {
				var $i = 0
				while $i < count {
					Sales.sell!(worker, from + $i, job)?
					$i = $i + 1
				}
				Ok({})
			}
		}

	## The `i`th id of a walk through `1..rows` that jumps about (a prime stride), so reads land all
	## over the table, the same on every engine.
	pick : I64, I64 -> I64
	pick = |i, rows| (i * 7919) % rows + 1
}

expect Workers.pick(0, 100) == 1
expect Workers.pick(1, 100) == 20
