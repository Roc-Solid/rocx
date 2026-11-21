import pf.Server
import pf.Endpoint
import pf.Events

## GET /api/count/5, asked for its events (`accept: text/event-stream`): 1 to 5, each with its
## square, 300 ms apart. A loop: send, sleep, round again; if the page goes, `send!` says so, and
## `?` ends the loop.
events! : { request : Server.Request, params : { to : Str }, context : c } => Try(Events({ count : U64, of : U64, square : U64 }), Endpoint.Refusal)
events! = |{ params, .. }| {
	to = U64.from_str(params.to) ?? 0
	if to < 1 or to > 20 {
		Err(BadRequest("count to a number from 1 to 20"))
	} else {
		Ok(
			Events.stream(
				|{ send!, sleep! }| {
					var $count = 1
					while $count <= to {
						send!({ count: $count, of: to, square: $count * $count })?
						sleep!(300)
						$count = $count + 1
					}
					Ok({})
				},
			),
		)
	}
}
