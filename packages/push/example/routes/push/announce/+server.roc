import pf.Server
import pf.Endpoint
import push.Notification
import push.Options
import push.Push

## POST /push/announce: queues a notification for every browser that subscribed. How many, or why
## not.
post! : { request : Server.Request, params : {}, context : c, body : {} } => Try(Str, Endpoint.Refusal)
post! = |_|
	match Push.broadcast!({ ..Notification.new("Hello", "A notification from the example"), url: "/" }, Options.defaults) {
		Ok(count) => Ok("Queued: ${count.to_str()}")
		Err(why) => Err(Status(503, why))
	}
