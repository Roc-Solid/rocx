import pf.Db
import pf.Endpoint
import Pomodoro

## The sessions done, in SQLite (`migrations/0001_sessions.sql`). Only the endpoints use it: it
## imports `pf.Db`, which only the server has. A day is the server's (`date('now', 'localtime')`):
## the page and the phone ask the same server, so they agree on when today began.
Store := [].{

	## A focus session done, today: the day's count after it.
	record! : U64 => Try(Pomodoro.Today, Endpoint.Refusal)
	record! = |minutes| {
		_ = Db.run!("insert into sessions (day, minutes) values (date('now', 'localtime'), $1)", [Int(minutes.to_i64_wrap())]).map_err(failed)?
		Store.today!({})
	}

	## Today's count.
	today! : {} => Try(Pomodoro.Today, Endpoint.Refusal)
	today! = |{}| {
		rows : List({ done : I64 })
		rows = Db.all!("select count(*) as done from sessions where day = date('now', 'localtime')", []).map_err(failed)?
		done = rows.first().map_ok(|row| row.done.to_u64_wrap()) ?? 0
		Ok({ done, goal: Pomodoro.daily_goal })
	}
}

failed : _ -> Endpoint.Refusal
failed = |_| Status(500, "The database failed")
