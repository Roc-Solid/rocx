import pf.Kv
import pf.Random
import pf.Server
import pf.Endpoint
import pf.Time
import ../../../Status

## GET /demo/flaky: a stand-in for a real service, which the seeded "Payments API" monitor checks.
## It takes 40 to 200 ms to answer (now and then most of a second), fails about one check in 250 at
## random (a blip, too short for an incident), and always while the admin's "Break it" switch is on
## (`Status.broken_key`), which is how the README's tour opens an incident on purpose.
get! : { request : Server.Request, params : {}, context : {} } => Try({ ok : Bool, service : Str }, Endpoint.Refusal)
get! = |_| {
	roll = Random.bytes!(2).fold(0, |total, byte| total * 256 + byte.to_u64())
	Time.sleep!(40 + roll % 160 + (if (roll % 37 == 0) 600 else 0))
	broken : Try(Bool, [NotFound, BadValue(Str)])
	broken = Kv.get!(Status.broken_key)
	if broken ?? Bool.False {
		Err(Status(503, "The payments service is down: the admin broke it on purpose."))
	} else if roll % 250 == 0 {
		Err(Status(503, "The payments service blinked."))
	} else {
		Ok({ ok: Bool.True, service: "payments" })
	}
}
