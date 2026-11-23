import pf.Actor
import pf.Db
import pf.Kv

## Eight actors, `w1` to `w8`, whose turns run at once: the concurrent workloads' writers and
## readers. An actor takes one turn at a time, but different actors run beside each other, each turn
## a call of its own, so eight of them told at once make eight callers of the database at once. Each
## keeps no state worth writing (`{}`, never changed, so no turn writes `rocx_actors`), does the work
## it is given (`work`), and leaves how that went in `Kv` (`bench:w1`…: "" when it went well, else
## why) for `Bench` to read, since a told actor's reply goes nowhere; being asked if it is `ready`
## leaves that be.
Workers := [].{

	kind : Actor.Kind({})
	kind = Actor.define({ name: "bench-worker", initial: |_key| {} })

	## Whether it is ready: its first turn reads its state, so it is asked this before the clock
	## starts, and again after, to wait for the work it was given.
	ready : Actor.Method(_, {}, {}, {})
	ready = Actor.method(Workers.kind, "ready", |{ state, .. }| { state, reply: {} })

	## Does `input`, and leaves how that went in `Kv`.
	work : Actor.Method(_, {}, Workers.Task, {})
	work = Actor.method(
		Workers.kind,
		"work",
		|{ me, state, input, .. }| {
			outcome =
				match Workers.work!(input) {
					Ok({}) => ""
					Err(why) => why
				}
			Kv.set!("bench:${Actor.key_of(me)}", outcome, { ttl_ms: 0 })
			{ state, reply: {} }
		},
	)

	## The work a worker is given: insert `count` events of its own, numbered from `from`; run
	## `count` transactions that each read counter `counter` and write it back one more (each run of
	## a transaction's body counted in `Kv`'s `bench:runs`); or read `count` items by their id, of the
	## first `rows`, starting from `seed`.
	Task : [
		Insert({ worker : I64, from : I64, count : I64 }),
		Bump({ counter : I64, count : I64 }),
		Read({ count : I64, rows : I64, seed : I64 }),
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
		}

	## The `i`th id of a walk through `1..rows` that jumps about (a prime stride), so reads land all
	## over the table, the same on every engine.
	pick : I64, I64 -> I64
	pick = |i, rows| (i * 7919) % rows + 1
}

expect Workers.pick(0, 100) == 1
expect Workers.pick(1, 100) == 20
