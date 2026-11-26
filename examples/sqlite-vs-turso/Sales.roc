import pf.Db
import pf.Kv
import jobs.Job

## A sale, written as a shop's checkout writes one: in one transaction (`Db.transaction!`), the
## sale, its three lines, its payment and its entry in the ledger, four tables
## (`migrations/0002_sales.sql`); and, in the workloads with a job, its receipt queued beside them
## (`Job.enqueue!`), a row of `rocx_jobs` in the same transaction. Either all of it is written or
## none: the outbox pattern, with the job queue as the outbox. `Bench` times it with one caller and
## with eight at once, with the job and without, so the job's own cost shows.
Sales := [].{

	## The job a sale queues in its transaction: its receipt, sent once the sale is written. Its
	## sale is always there when it runs: the job and the sale commit together, and the workers hear
	## of the job only then. The benchmark's jobs plugin has no workers (`main.roc`), so receipts
	## stay queued: the workloads time what queueing one with the sale costs, not sending it, and
	## `Bench` checks that every receipt was queued with its sale.
	receipt : Job.Kind(_, { sale : I64 })
	receipt = Job.define(
		"receipt",
		|_context, { sale }| {
			found : Try(List({ total : I64 }), [DbErr(Str), BadRow(Str)])
			found = Db.all!("select total from sales where id = $1", [Int(sale)])
			match found {
				Ok([_]) => Ok({})
				Ok(_) => Err("receipt: no sale ${sale.to_str()}")
				Err(DbErr(why)) => Err("receipt: ${why}")
				Err(BadRow(why)) => Err("receipt: ${why}")
			}
		},
	)

	## Sale `n` of customer `customer`, in one transaction: the sale (its id read back with
	## `returning`), its lines, its payment and its ledger entry; with `job`, its receipt queued too.
	## Each run of the body is counted in `Kv`'s `bench:runs` (on Turso's MVCC a transaction that
	## loses to another's write runs again).
	sell! : I64, I64, Bool => Try({}, Str)
	sell! = |customer, n, job| {
		bought = Sales.lines(n)
		total = bought.fold(0, |sum, line| sum + line.quantity * line.price)
		at = 1700000000000 + n * 1000
		sold = Db.transaction!(
			|{}| {
				_ = Kv.increment!("bench:runs", 1, { ttl_ms: 0 })
				made : List({ id : I64 })
				made = Db.all!("insert into sales (customer, total, created) values ($1, $2, $3) returning id", [Int(customer), Int(total), Int(at)])?
				sale =
					match made.get(0) {
						Ok(row) => row.id
						Err(_) => return Err(NoSale)
					}
				for line in bought {
					_ = Db.run!("insert into sale_lines (sale, product, quantity, price) values ($1, $2, $3, $4)", [Int(sale), Int(line.product), Int(line.quantity), Int(line.price)])?
				}
				_ = Db.run!("insert into payments (sale, amount, method) values ($1, $2, $3)", [Int(sale), Int(total), Text("card")])?
				_ = Db.run!("insert into ledger (sale, account, amount, at) values ($1, $2, $3, $4)", [Int(sale), Text("revenue"), Int(total), Int(at)])?
				if job {
					Job.enqueue!(Sales.receipt, { sale: sale }, {})?
				}
				Ok({})
			},
		)
		match sold {
			Ok({}) => Ok({})
			Err(DbErr(why)) => Err("sale: ${why}")
			Err(BadRow(why)) => Err("sale: ${why}")
			Err(JobErr(why)) => Err("sale: ${why}")
			Err(NoSale) => Err("sale: the insert returned no id")
		}
	}

	## Sale `n`'s three lines: which product, how many, at what price (in cents), the same on every
	## engine.
	lines : I64 -> List({ product : I64, quantity : I64, price : I64 })
	lines = |n| [0, 1, 2].map(|k| { product: (n * 7 + k) % 500 + 1, quantity: k + 1, price: (n * 37 + k * 101) % 5000 + 100 })
}

expect Sales.lines(1).len() == 3
expect Sales.lines(1).map(|line| line.quantity) == [1, 2, 3]
