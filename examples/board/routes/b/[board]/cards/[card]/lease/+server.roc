import pf.Server
import pf.Endpoint
import ../../../../../../Lease
import ../../../../../../Middlewares
import ../../../../../../News
import ../../../../../../Store

middleware = Middlewares.member

## POST /b/<board>/cards/<card>/lease: the card's edit lease, taken or renewed for whoever asks
## (an open card asks every `Lease.renew_every`), or a 409 that says who has it. Everyone on the
## board hears when it changes hands.
post! : { request : Server.Request, params : { board : Str, card : Str }, context : Middlewares.Member, body : {} } => Try(Str, Endpoint.Refusal)
post! = |{ params, context, .. }|
	match Store.card!(params.board, params.card) {
		Err(problem) => Err(Store.refused!(problem))
		Ok(_) => {
			was_mine = Lease.holder!(params.card).map_ok(|held| held.person == context.me.id) ?? Bool.False
			match Lease.take!(params.card, context.me) {
				Ok({}) => {
					if (!was_mine) News.tell!(params.board, context.me, "") else {}
					Ok("yours")
				}
				Err(HeldBy(held)) => Err(Conflict("${held.name} is editing this card."))
			}
		}
	}

## DELETE /b/<board>/cards/<card>/lease: the lease let go (the card was closed), if it was yours.
delete! : { request : Server.Request, params : { board : Str, card : Str }, context : Middlewares.Member } => Try(Str, Endpoint.Refusal)
delete! = |{ params, context, .. }|
	if Lease.release!(params.card, context.me) {
		News.tell!(params.board, context.me, "")
		Ok("released")
	} else {
		Ok("not yours")
	}
