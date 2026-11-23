# sqlite-vs-turso

One app timing the same database work on SQLite and on Turso (D-046, D-049), in Roc. Its database
is SQLite unless `--database-url` says otherwise, so the same build runs on each engine:

| `--database-url` | engine |
|---|---|
| `sqlite:<path>` (or nothing: `data/bench.db`) | SQLite (rusqlite), WAL: writes take turns |
| `turso:<path>` | Turso (`turso_core`), MVCC: writes at once, a transaction that loses to another runs again |
| `turso:<path>?mvcc=off` | Turso in WAL mode: writes take turns, as SQLite's |

`POST /bench` with `{"size": n}` (1 to 1000) runs every workload on fresh tables of `200 × n` items
and answers what each did and how long it took, in nanoseconds, timed in Roc around the `Db` calls
it makes (`Time.now_nanos!`), so no HTTP is in the numbers. `Bench.roc` has the workloads:

- one caller, one statement after another: an insert committed alone; inserts all in one
  transaction (the table's items); reads by key; scans of 50 rows by an index; a group by over the
  table; an update committed alone; a row's JSON read apart and put together; a recursive query
  counting to 10,000;
- eight callers at once (`Workers.roc`: eight actors, whose turns run beside each other, told at
  once and timed from the first told to the last done): inserts, each writer its own rows;
  transactions reading and writing back a counter of their own; transactions on one counter they
  share (on Turso the losers run again: `runs` counts the bodies' runs); four readers beside four
  writers.

Then it checks what they wrote: every counter at what its transactions made it (no write lost),
every event and item there. A failure is a 500 saying which.

## Run it

From the repository's root, with the toolchain set up (`just setup`):

```sh
just examples sqlite-vs-turso    # build, check, lint, expects, and its tests on all three engines
just db-bench                    # the docs' numbers: site/sqlite-vs-turso.json (a few minutes)
```

By hand:

```sh
bin/rocx build examples/sqlite-vs-turso
node server/build.mjs examples/sqlite-vs-turso/main.roc /tmp/bench/app --opt=speed
/tmp/bench/app --port 18090 --database-url turso:/tmp/bench/turso.db &
curl -s -X POST localhost:18090/bench -H 'content-type: application/json' -d '{"size":10}'
```

`just db-bench` (`site/sqlite-vs-turso.mjs`) does that on each engine with a file of its own: a
small run to warm up, then three at size 100 (20,000 items), each workload's time the median of the
three. The docs show them at `/examples/sqlite-vs-turso`. Measure on a quiet machine, and compare
the engines with each other rather than with another machine's numbers.

A Turso file in MVCC mode is Turso's alone: run the app on a fresh path for each engine (SQLite
can't open it, and says how to give it back: `turso:<path>?mvcc=off`, once).

On Turso a run checkpoints after deleting the last run's rows (`Bench.fresh!`): without it, once
Turso has checkpointed rows, deleting them slows every later statement 75 to 250 times until its
next checkpoint, a third run on one file taking minutes (turso_core 0.8.4; D-049). `just db-bench`
starts each round on a fresh file anyway.
