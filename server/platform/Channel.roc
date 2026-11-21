## A channel: what the server publishes to the pages subscribed to it, as it happens, and what
## pages say to the server, over one stream per browser tab (`/rocx/live`).
##
## A route's `+server.roc` defines one at its path, as it defines an endpoint: `channel!`, its check,
## is given the request, the path's params and what the route's middleware handed on, and answers
## who the subscriber is (`Channel.allow(who)`), or a refusal. Its type says what is published on it
## (`message`) and what pages may say on it (`said`, `[]` for nothing):
##
## ```roc
## channel! : { request : Server.Request, params : { org : Str }, context : Member } => Try(Channel(Str, News, []), Endpoint.Refusal)
## channel! = |{ params, context, .. }| if context.org == params.org Ok(Channel.allow(context.name)) else Err(Forbidden)
## ```
##
## `Generated/Api` has it as a function of its params (`Api.channel_org_org_news({ org })`): a
## component subscribes to it (`Endpoint.subscribe!`) and says things on it (`Endpoint.say!`); the
## server publishes on it (`Endpoint.publish!`). The route may define hooks beside it: `receive!`,
## what pages say; `on_open!`, what a subscriber is sent first, each time it subscribes;
## `on_close!`, told when a subscription ends.
Channel(who, message, said) :: { who : who }.{

	## What a subscriber hears, in order:
	##
	## - `Resync`: each time its tab's stream (re)connects, when the server noticed it fell behind,
	##   and when a page asks (`Endpoint.resync!`): what it shows may be out of date, so it reads it
	##   again (`refresh!`). The route's `on_open!` messages come right after it.
	## - `Message(message)`: what was published, in the order it was (but see `publish_latest!`).
	## - `Refused(status, why)`: the check refused it as the stream opened: nothing will come.
	## - `Ended(why)`: the check, run again on a beat of the stream, refused it: nothing more will
	##   come on this stream.
	Event(message) : [Message(message), Resync, Refused(U16, Str), Ended(Str)]

	## Why a subscription ended, as `on_close!` is told: its stream went (the tab closed or went
	## elsewhere, its network went, it changed what it subscribes to, the server stopped), or its
	## check, run again, refused it.
	Closed : [Gone, Refused(Str)]

	## A subscriber let in, as `who`: what the route's hooks are given (who it is, its name and
	## colour, say). It stays on the server, kept as JSON between the check and `on_close!`.
	allow : who -> Channel(who, message, said)
	allow = |who| { who: who }

	## Who the check said the subscriber is.
	who_of : Channel(who, message, said) -> who
	who_of = |channel| channel.who
}

expect Channel.who_of(Channel.allow("Ada")) == "Ada"
