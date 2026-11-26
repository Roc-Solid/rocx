import pf.Kv
import pf.Server
import pf.Endpoint
import ../../../../../Status

## POST /api/admin/demo: the flaky demo's switch (`broken`: `yes` or `no`). Broken, `/demo/flaky`
## answers 503 to every check, so the "Payments API" monitor opens an incident after three; mended,
## the next check closes it. Kept in `Kv`, so a restart mends it.
post! : { request : Server.Request, params : {}, context : {}, body : { broken : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }| {
	broken = body.broken == "yes"
	Kv.set!(Status.broken_key, broken, { ttl_ms: 0 })
	Ok(if (broken) "Broken: the next checks of /demo/flaky fail." else "Mended: the next check of /demo/flaky passes.")
}
