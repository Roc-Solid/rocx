import pf.Server
import pf.Endpoint
import ../../../../../../Lease
import ../../../../../../Middlewares
import ../../../../../../News
import ../../../../../../Store

middleware = Middlewares.member

## POST /b/<board>/cards/<card>/lease, `{ token }`: the card's edit lease, taken or renewed for
## whoever asks with the token of the card's opening (an open card asks every `Board.renew_every`),
## or a 409 that says who has it, or that this opening has let it go (it was closed). Everyone on
## the board hears when it changes hands.
post! : { request : Server.Request, params : { board : Str, card : Str }, context : Middlewares.Member, body : { token : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ params, context, body, .. }|
	match Store.card!(params.board, params.card) {
		Err(problem) => Err(Store.refused!(problem))
		Ok(_) =>
			match Lease.take!(params.card, context.me, body.token) {
				Ok(Taken) => {
					News.tell!(params.board, context.me, "")
					Ok("yours")
				}
				Ok(Renewed) => Ok("yours")
				Err(HeldBy(held)) => Err(Conflict("${held.name} is editing this card."))
				Err(LetGo) => Err(Conflict("This card was closed."))
			}
	}
