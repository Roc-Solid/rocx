import Host

## The server's log, on stderr: an event a line, the app's and the platform's alike, in the format
## the app's `program` chose (`logs: { format: Auto }`, or `Pretty`, or `Json`). An event is a
## message and its fields, a record written as JSON:
##
## ```roc
## Log.info!("gate failed", { path: request.path, error: why })
## ```
##
## is, pretty (a person at a terminal):
##
## ```
## 14:03:12 INFO  gate failed error="no session" path=/admin
## ```
##
## and as JSON (a server whose log is collected):
##
## ```
## {"time":"2026-11-21T13:03:12.345Z","level":"info","msg":"gate failed","error":"no session","path":"/admin"}
## ```
##
## The fields go beside `time`, `level` and `msg`; one named `time`, `level` or `msg` is written as
## `fields.time` (and so on), so it can't take their place. `{}` is no fields. Logging doesn't wait
## for stderr: the host writes the line on a thread of its own, in the order the events came.
Log := [].{

	## A message with no fields, at info level.
	line! : Str => {}
	line! = |message| Host.log!(1, message, "")

	## Detail, for finding out why something happened.
	debug! : Str, fields => {} where [fields.Json.Encodable(e)]
	debug! = |message, fields| Host.log!(0, message, written(fields))

	## What happened, as it should.
	info! : Str, fields => {} where [fields.Json.Encodable(e)]
	info! = |message, fields| Host.log!(1, message, written(fields))

	## What went wrong, and was dealt with: worth a look.
	warn! : Str, fields => {} where [fields.Json.Encodable(e)]
	warn! = |message, fields| Host.log!(2, message, written(fields))

	## What went wrong, and wasn't: someone should look.
	error! : Str, fields => {} where [fields.Json.Encodable(e)]
	error! = |message, fields| Host.log!(3, message, written(fields))
}

## The fields as JSON. A record that can't be (an `F64` that is NaN or an infinity in it) is logged
## all the same, saying so, rather than not at all.
written : fields -> Str where [fields.Json.Encodable(e)]
written = |fields|
	match Json.to_str_try(fields) {
		Ok(json) => json
		Err(_) => "{\"fields\":\"they hold a number JSON can't write (an F64 that is NaN or an infinity)\"}"
	}
