import pf.Channel
import pf.Endpoint

## What every open status page hears: the live channel (`routes/live/+server.roc`), published on
## by each check and by the admin's changes, so each page reads the status again.
News := [].{

	## What is said on it: which monitor, and what happened: `up` or `down` (a check), `opened` or
	## `closed` (its incident), `paused`, `resumed` or `updated` (the admin).
	Said : { monitor : I64, name : Str, what : Str }

	## The live channel. A module the routes import can't import `Generated/Api` (it is made of
	## them), so the channel is named by its path, as `Api.channel_live` names it.
	channel : {} -> Endpoint(context, {}, Channel(Str, News.Said, []))
	channel = |{}| Endpoint.remote("CHANNEL", "/live")

	## Tells every open page.
	tell! : News.Said => {}
	tell! = |said| Endpoint.publish!(News.channel({}), said)
}
