import pf.Server
import pf.Endpoint
import pf.Channel

## The lobby, a channel: anyone may join, and every tab that has hears each wave as it is
## made. Its check lets everyone in; a tab is named by the first letters of its id.
channel! : { request : Server.Request, params : {}, context : c } => Try(Channel({}, { hand : Str, from : Str }, [Wave(Str)]), Endpoint.Refusal)
channel! = |_| Ok(Channel.allow({}))

## What a page says: a wave, published to everyone in the lobby. Only these hands.
receive! = |{ tab, said, channel, .. }|
	match said {
		Wave(hand) =>
			if ["👋", "🎉", "🙌"].contains(hand) {
				Endpoint.publish!(channel, { hand, from: short(tab) })
				Ok({})
			} else {
				Err(BadRequest("wave 👋, 🎉 or 🙌"))
			}
	}

## A subscriber is greeted first, each time it joins.
on_open! = |{ tab, .. }| [{ hand: "👋", from: "the lobby, to tab ${short(tab)}" }]

short = |tab| Str.from_utf8_lossy(tab.to_utf8().take_first(4))
