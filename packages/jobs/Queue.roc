import pf.Db
import pf.Time

## What the queue's statements share across the two databases (D-045). On Postgres, its clock
## (`now()`) and `pg_notify` are in the SQL, as they were. On SQLite, the queue's times are
## milliseconds in integer columns, now given from here, the workers and the jobs page are told with
## `Db.notify!` on `rocx_jobs` (held until the transaction commits), and a list of kinds is JSON.
Queue := [].{

	## Whether the server's database is SQLite.
	lite! : {} => Bool
	lite! = |{}| Db.backend!({}) == Sqlite

	## Now, in milliseconds since the epoch.
	now! : {} => I64
	now! = |{}| Time.now_millis!({}).to_i64_wrap()

	## Tells the workers and the jobs page, when `changed` changed any job: on SQLite, where the SQL
	## can't.
	told! : Try(U64, [DbErr(Str)]) => Try(U64, [DbErr(Str)])
	told! = |changed|
		match changed {
			Ok(count) if count > 0 =>
				match Db.notify!("rocx_jobs", "") {
					Ok({}) => Ok(count)
					Err(DbErr(why)) => Err(DbErr(why))
				}
			other => other
		}

	## The kinds as one parameter on SQLite: a JSON list, for `kind in (select value from json_each($1))`.
	kinds : List(Str) -> Db.Value
	kinds = |names| Text(Json.to_str(names))
}
