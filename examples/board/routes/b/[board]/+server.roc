import pf.Server
import pf.Endpoint
import pf.Channel
import ../../../Board
import ../../../Lease
import ../../../Middlewares
import ../../../Store

middleware = Middlewares.member

## GET /b/<board>: the whole board, as its page reads it (as the server renders it, and again after
## every change anyone makes): its columns, cards and people, who is asking, and who is editing what.
get! : { request : Server.Request, params : { board : Str }, context : Middlewares.Member } => Try(Board.Data, Endpoint.Refusal)
get! = |{ params, context, .. }|
	match Store.board!(params.board) {
		Ok(board) =>
			Ok({
				slug: board.slug,
				name: board.name,
				today: board.today,
				me: context.me,
				columns: board.columns,
				cards: board.cards,
				people: board.people,
				leases: Lease.of!(board.cards.map(|card| card.id)),
			})
		Err(problem) => Err(Store.refused!(problem))
	}

## The board's channel (D-020): every page on the board subscribes, and hears `News` after each
## change (`News.tell!`), so it reads the board again. Its check is this route's middleware (only
## members) and that the board is there; it runs again every 15 seconds while the page is open.
channel! : { request : Server.Request, params : { board : Str }, context : Middlewares.Member } => Try(Channel(Str, Board.News, []), Endpoint.Refusal)
channel! = |{ params, context, .. }| if (Store.board_exists!(params.board)) Ok(Channel.allow(context.me.id)) else Err(NotFound)
