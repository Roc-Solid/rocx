import presence.Room
import presence.Stack
import presence.Wire
import ../Board

## What the parts of a board's page share (`routes/b/[board]/+page.rocx` makes it): the board as it
## shows, the card being dragged and where it would land, the card that is open, and who is here.
## Each is an accessor or a setter, so a part that reads one is patched when it changes.
Shared := [].{

	## Where a dragged card would land: before the card `before` in `column` (`""`: at its end).
	Over : { column : Str, before : Str }

	## Nowhere: no drag is over the board.
	nowhere : Shared.Over
	nowhere = { column: "", before: "" }

	## A card on its way to the server, shown (dimmed) at the end of its column until it is in.
	Adding : { column : Str, title : Str }

	State : {
		board : Str,
		board! : () => Board.Data,
		dragging! : () => Str,
		set_dragging! : Str => {},
		over! : () => Shared.Over,
		set_over! : Shared.Over => {},
		move! : Board.Move => {},
		open! : () => Str,
		set_open! : Str => {},
		here! : () => List(Room.Here(Wire.Meta({}))),
		adding! : () => List(Shared.Adding),
		add! : Shared.Adding => {},
	}

	## Who else is on the board, as the header's avatar stack shows them (you are beside it): `away`
	## while their tab is hidden (D-055); the card one has open is the tiles' to show.
	others : List(Room.Here(Wire.Meta({}))), Str -> List(Stack.Face)
	others = |here, me| here.keep_if(|each| each.key != me).map(|each| { ..Wire.face(each), status: if (each.meta.status == "away") "away" else "" })

	## Who else has card `card` open, from their presence (`Board.status_of`): the faces its tile
	## shows.
	viewers : List(Room.Here(Wire.Meta({}))), Str, Str -> List(Room.Here(Wire.Meta({})))
	viewers = |here, card, me| here.keep_if(|each| each.meta.status == Board.status_of(card) and each.key != me)
}
