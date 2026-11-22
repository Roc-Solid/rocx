import pf.Endpoint
import pf.Channel
import pf.Server
import Board

## What everyone on a board hears: the board's channel (`routes/b/[board]/+server.roc`'s
## `channel!`), published on after every change, so each page reads the board again.
News := [].{

	## The board's channel. A route file can't import `Generated/Api` (it is made of them), so a
	## handler names the channel by its path, as `Api.channel_b_board` does.
	channel : Str -> Endpoint(context, {}, Channel(Str, Board.News, []))
	channel = |board| Endpoint.remote("CHANNEL", "/b/${Server.encode_segment(board)}")

	## Tells everyone on `board` that `me` did something (`did`: "moved “Press kit” to Doing"; `""`
	## to say nothing, only that the board changed).
	tell! : Str, Board.Person, Str => {}
	tell! = |board, me, did| Endpoint.publish!(News.channel(board), { by: me.name, did })
}
