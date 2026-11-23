import pf.Server
import pf.Endpoint
import pf.Channel
import ../../Grid
import ../../Store

## GET /boxes: every chunk that has changed since the server started, and how many pages are open.
## The page reads it as the server renders it, so the boxes it shows first come in the page itself.
get! : { request : Server.Request, params : {}, context : {} } => Try(Grid.Snapshot, Endpoint.Refusal)
get! = |_| Ok(Store.snapshot!({}))

## The boxes' channel (D-020): every chunk that changes, to every open page, and how many are
## open. Anyone may listen, and say which box they checked.
channel! : { request : Server.Request, params : {}, context : {} } => Try(Channel(Str, Grid.News, Grid.Said), Endpoint.Refusal)
channel! = |_| Ok(Channel.allow("visitor"))

## A page subscribed (and each time it reconnects): one more online, which it hears first.
on_open! = |_| [Online(Store.opened!({}))]

## A page's subscription ended: one fewer.
on_close! = |_| Store.closed!({})

## A box checked or unchecked. One that isn't there is a 400.
receive! = |{ said, .. }|
	match said {
		Set({ index, on }) =>
			if index >= Grid.size {
				Err(BadRequest("there are ${Grid.thousands(Grid.size)} boxes, numbered from 0"))
			} else {
				Store.set!(index, on)
				Ok({})
			}
	}
