# sqlite-vs-turso

sqlite-vs-turso is a benchmark app: it times the same database work on SQLite and on Turso, from
Roc, on the server platform. One build runs on either engine; the server's `--database-url` option
picks which. The docs site shows its numbers at `/examples/sqlite-vs-turso`.

Read it to see an app made only of endpoints (no pages), a database chosen when the server starts,
transactions, a job queued in the same transaction as the rows it goes with, actors used as
concurrent callers, and timing in Roc with `Time.now_nanos!`.

| `--database-url` | Engine |
|---|---|
| `sqlite:<path>` (or nothing: `data/bench.db`) | SQLite (rusqlite) in WAL mode: writes take turns. |
| `turso:<path>` | Turso (`turso_core`) in MVCC mode: transactions write at once, and one that loses to another's write runs again. |
| `turso:<path>?mvcc=off` | Turso in WAL mode: writes take turns, as on SQLite. |

## Run it

From the repository's root, once the toolchain is set up (`just setup`):

```sh
cd examples/sqlite-vs-turso
../../bin/rocx dev                                          # SQLite, on data/bench.db
```

Then, in another terminal, run every workload at a small size:

```sh
curl -s -X POST http://127.0.0.1:8080/bench -H 'content-type: application/json' -d '{"size":10}'
```

`rocx dev` builds the app, serves it with the server's `--dev` flag, and builds and restarts it each
time you save a file. Run it from the example's directory: the default database is the file
`data/bench.db`, relative to where the server starts (`database: Sqlite("data/bench.db")` in
`main.roc`; `data/` is git-ignored).

Options after `--` go to the server, so this runs it on Turso instead:

```sh
../../bin/rocx dev -- --database-url turso:data/turso.db                 # Turso, MVCC
../../bin/rocx dev -- --database-url 'turso:data/turso-wal.db?mvcc=off'  # Turso, WAL
```

Quote a URL with `?` in it: shells like zsh read `?` as a pattern. Give each engine a file of its
own. A Turso file in MVCC mode is Turso's alone: SQLite can't open it, and its error says how to give
it back (start once with `turso:<path>?mvcc=off`).

`rocx dev` builds without optimizations, so its times are only for trying the app. For numbers worth
comparing, build it as `just db-bench` does (below).

### Build it as it would ship

From the repository's root:

```sh
bin/rocx generate examples/sqlite-vs-turso
node server/build.mjs examples/sqlite-vs-turso/main.roc /tmp/bench/app --opt=speed
/tmp/bench/app --port 8080 --database-url turso:/tmp/bench/turso.db &
curl -s -X POST http://127.0.0.1:8080/bench -H 'content-type: application/json' -d '{"size":10}'
```

## What it measures

Every time is measured in Roc around the `Db` calls a workload makes (`Time.now_nanos!`), in
nanoseconds, so no HTTP is in the numbers. `Bench.roc` has the workloads.

**`POST /bench`** with `{"size": n}` (1 to 1000) makes the tables fresh, fills them with `200 × n`
items, and answers what each workload did and how long it took. The workloads:

- **One caller**, one statement after another: an insert committed alone; inserts all in one
  transaction (filling the table); reads by key; scans of 50 rows through an index; a group by over
  the table; an update committed alone; a row's JSON taken apart and put back together; a recursive
  query counting to 10,000; a sum over every row (a scan); and the group by with its index ruled out
  (a scan and a sort).
- **Eight callers at once** (`Workers.roc`, eight actors that run side by side, all told at once and
  timed from the first told to the last done): inserts, each writer on its own rows; transactions
  that read and write back a counter of their own; transactions on one counter they all share (on
  Turso in MVCC mode the losers run again, and the result's `runs` counts how many times the bodies
  ran); and four readers beside four writers.
- **After a checkpoint**, the reads again. On Turso's MVCC, rows not yet checkpointed live in an
  in-memory store of versions, which is slower to walk through an index than the database's pages.
- **A sale in one transaction** (`Sales.roc`), as a shop's checkout writes one: the sale (its id
  read back with `returning`), three lines, a payment and a ledger entry, four tables with foreign
  keys to the sale. Four workloads: one caller (`sale`), the same with the sale's receipt job
  queued in the same transaction (`sale-job`), and both with eight callers at once
  (`concurrent-sale`, `concurrent-sale-job`). The job is a row of `rocx_jobs` in the transaction
  (`Job.enqueue!`, packages/jobs), so the sale and its job are written together or not at all:
  the outbox pattern, with the job queue as the outbox. Comparing each pair shows what the job
  adds. The app's jobs plugin has no workers (`workers: 0` in `main.roc`), so the receipts stay
  queued: the time is writing them, with no worker's writes running beside the workloads.

Then the app checks what the workloads wrote: every counter at the value its transactions made it
(no write lost), every event and item there, every sale with its three lines, its payment and its
ledger entry, and one receipt queued for each sale written with one, naming a sale that is there. A
failure is a 500 that says which check failed.

**`POST /bench/big`** with `{"orders": n}` (1,000 to 5,000,000; the docs use a million) makes two
tables afresh: `customers` (n / 100 rows) and `orders` (n rows, a hundred per customer, spread over
the table, with an index on `customer`). It loads them with SQL (a recursive query, 100,000 rows per
statement), checkpoints, and times:

- an order fetched by its key, and 100 by a range of keys;
- a customer's 100 orders, through the index;
- an order joined to its customer, and a customer joined to their 100 orders;
- the ten customers who spent most (a join, a group by and a sort over every order);
- a sum over every order.

Each fetch and join checks that it read what it should.

## What it shows

| Feature | Where |
|---|---|
| An app of endpoints alone: two `POST` endpoints and no pages, so `rocx build` writes no browser half. | `routes/bench/+server.roc`, `routes/bench/big/+server.roc` |
| A typed JSON body (`body : { size : U64 }`) and a typed answer (`Bench.Report`), turned into JSON by the platform. A failure is `Err(Status(500, why))`. | `routes/bench/+server.roc`, `Bench.roc` |
| The database named in the program (`database: Sqlite("data/bench.db")`) and overridden at start with `--database-url`. `Db.engine!` says which engine the server opened. | `main.roc`, `engine!` in `Bench.roc` |
| Timing in Roc with the server's monotonic clock (`Time.now_nanos!`). | `timed!` in `Bench.roc` |
| Transactions (`Db.transaction!`). On Turso in MVCC mode, a transaction that loses to another's write runs its body again; the app counts the runs. | `insert_batch!` in `Bench.roc`, `Workers.work!`, `Sales.sell!` |
| A job queued in the transaction that writes its rows (`Job.enqueue!` inside `Db.transaction!`), with a job kind defined in the app (`Job.define`) and the jobs plugin listed with no workers. | `Sales.roc`, `main.roc` |
| Actors as concurrent callers: eight actors (`Actor.method`), each turn a call of its own. They are told their work at once (`tell!`), then asked whether they are `ready` (`ask!`) to wait for them. A told actor's reply goes nowhere, so each leaves its outcome in `Kv`. | `Workers.roc`, `together!` in `Bench.roc` |
| Several statements in one call (`Db.script!`). | `fresh!` in `Bench.roc` |
| SQL on tables no migration makes, marked `Db.unchecked`, so `rocx check --sql` (which checks the app's SQL against a database built from its migrations) leaves it out. | the big run in `Bench.roc` |
| The tables the workloads use, made by migrations, the same on every engine. | `migrations/0001_bench.sql`, `migrations/0002_sales.sql` |

## The docs' numbers: `just db-bench`

```sh
just db-bench    # about eight minutes; writes site/sqlite-vs-turso.json
```

`just db-bench` (`site/sqlite-vs-turso.mjs`) builds the app with `--opt=speed` and runs it on each
engine the way an app's database lives: written and read for a long time. On one file, it makes a
small run to warm up, then ten runs in a row at size 100 (20,000 items). On another file, it makes
the big run at a million orders, ten times in a row. Every run's times are kept. The docs page shows
the first run, the first three, or all ten (their average, fastest and slowest), with the machine
they ran on (`site/machine.mjs`). The site's build reads the committed JSON file and doesn't measure.
The file was last measured before the sale's four workloads were added, so the page doesn't show
them yet; the next `just db-bench` adds them.

The big run gets a file of its own because, on Turso's MVCC, what an earlier run wrote (versions
kept in memory) slows later reads two or three times, even of tables it never touched.

`just db-bench --size 10 --orders 100000 --series 3` takes a quick look. Measure on a quiet machine,
and compare the engines with each other rather than with another machine's numbers.

## Test it

```sh
just examples sqlite-vs-turso
```

This builds the app, type-checks it, lints it, checks its SQL (`rocx check --sql`), and runs the
`expect`s and `test/bench.test.mjs`. The test runs the benchmark small (size 1, and the big run at
2,000 orders) on all three engines, each on a file of its own: SQLite, Turso in MVCC mode, and Turso
in WAL mode. It checks that every workload answers with what it did, and that the transactions'
bodies ran at least once each (exactly once where writes take turns). No database server is needed.

## A Turso gotcha: deletes after a checkpoint

On Turso, `fresh!` in `Bench.roc` checkpoints after deleting the last run's rows. Without that, once
Turso has checkpointed rows, deleting them slows every later statement 75 to 250 times until the
next checkpoint, and a third run on one file takes minutes (turso_core 0.8.4; DECISIONS.md, D-049).
With the checkpoint, ten runs in a row on one file stay as quick as the first.
