import pf.Endpoint
import Board
import Generated/Api

## What everyone on a board hears: the board's channel (`routes/b/[board]/+server.roc`'s
## `channel!`, `Api.channel_b_board`), published on after every change, so each page reads the
## board again. A module the routes import may import `Generated/Api`: it is the app's contract,
## the channel's URL and types, and imports no route file (D-037).
News := [].{

	## Tells everyone on `board` that `me` did something (`did`: "moved “Press kit” to Doing"; `""`
	## to say nothing, only that the board changed).
	tell! : Str, Board.Person, Str => {}
	tell! = |board, me, did| Endpoint.publish!(Api.channel_b_board({ board: board }), { by: me.name, did })
}
