import pf.Env
import pf.Kv
import pf.Server

## Where this app is, for what has to name it whole: the checks of a monitor whose URL starts with
## `/` (`/health` is this app's own), and the links in an alert's email. `ORIGIN` says it
## (`https://status.example.com`); without it, the address a browser or a test last asked this app
## at on this machine (`http://127.0.0.1:18130`), which the default middleware remembers.
##
## The server doesn't tell the app the port it listens on (with `--port 0`, the tests', nobody
## knows it beforehand), so the app learns it from a request. Only a loopback address is learned:
## a `Host` header is whatever a client writes, and a check must never be sent where a stranger
## said.
Origin := [].{

	## The app's origin, if it is known yet.
	self! : {} => Try(Str, [Unknown])
	self! = |{}|
		match Env.var!("ORIGIN") {
			Ok(origin) => Ok(origin.drop_suffix("/"))
			Err(NotFound) =>
				match Kv.get!(key) {
					Ok(origin) => Ok(origin)
					Err(_) => Err(Unknown)
				}
		}

	## A monitor's URL, whole: one that starts with `/` is this app's.
	resolve! : Str => Try(Str, [Unknown])
	resolve! = |url| if (url.starts_with("/")) Origin.self!({}).map_ok(|origin| "${origin}${url}") else Ok(url)

	## Remembers where `request` was sent, if it was a loopback address and `ORIGIN` isn't set.
	learn! : Server.Request => {}
	learn! = |request|
		match Server.header(request, "host") {
			Ok(host) =>
				if Origin.loopback(host) and Env.var!("ORIGIN").is_err() {
					Kv.set!(key, "http://${host}", { ttl_ms: 0 })
				} else {
					{}
				}
			Err(Missing) => {}
		}

	## Whether `host` (a `Host` header) is this machine: `127.0.0.1:18130`, `localhost:18130`, `[::1]:18130`.
	loopback : Str -> Bool
	loopback = |host| {
		name = if (host.starts_with("[::1]")) "[::1]" else host.split_on(":").first() ?? ""
		rest = host.drop_prefix(name)
		allowed = name == "127.0.0.1" or name == "localhost" or name == "[::1]"
		allowed and (rest.is_empty() or (rest.starts_with(":") and U64.from_str(rest.drop_prefix(":")).is_ok()))
	}
}

key : Str
key = "uptime:origin"

expect Origin.loopback("127.0.0.1:18130")
expect Origin.loopback("localhost:18130")
expect Origin.loopback("[::1]:8080")
expect Origin.loopback("localhost")
expect !Origin.loopback("evil.example:18130")
expect !Origin.loopback("127.0.0.1.evil.example")
expect !Origin.loopback("127.0.0.1:80@evil.example")
