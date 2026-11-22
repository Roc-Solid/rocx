import pf.Endpoint
import Report
import Generated/Api

## What every open status page hears: the live channel (`routes/live/+server.roc`,
## `Api.channel_live`), published on by each check and by the admin's changes, so each page reads
## the status again. A job, a route or an actor may publish on it: `Generated/Api`, the app's
## contract, imports no route file (D-037).
News := [].{

	## Tells every open page.
	tell! : Report.News => {}
	tell! = |said| Endpoint.publish!(Api.channel_live({}), said)
}
