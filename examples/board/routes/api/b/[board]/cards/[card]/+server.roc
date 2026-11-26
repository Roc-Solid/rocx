import pf.Server
import pf.Endpoint
import ../../../../../../Board
import ../../../../../../Lease
import ../../../../../../Middlewares
import ../../../../../../News
import ../../../../../../Store

middleware = Middlewares.writer

## POST /api/b/<board>/cards/<card>, from an open card's form: its title, description, assignee (a
## person's id, or `""`) and due date (`2026-11-30`, or `""`). Refused while someone else is
## editing it (`Lease`).
post! : { request : Server.Request, params : { board : Str, card : Str }, context : Middlewares.Member, body : Board.Fields } => Try(Str, Endpoint.Refusal)
post! = |{ params, context, body, .. }| {
	Lease.editable!(params.card, context.me)?
	match Board.fields_of(body) {
		Err(why) => Err(BadRequest(why))
		Ok(fields) =>
			if !(fields.assignee.is_empty() or Store.person!(fields.assignee).is_ok()) {
				Err(BadRequest("No one by that id has joined."))
			} else {
				match Store.save_card!(params.board, params.card, fields) {
					Ok({}) => {
						News.tell!(params.board, context.me, "edited “${fields.title}”")
						Ok("saved")
					}
					Err(problem) => Err(Store.refused!(problem))
				}
			}
	}
}
