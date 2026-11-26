import pf.Server
import pf.Endpoint
import ../../../Middlewares
import ../../../Store
import ../../../Tasks

## GET /api/team: who you are (`me`, a person's id, or `""`), everyone on the team, and every list
## with its counts. The layout reads it on every page (the lists down the side, your name at the
## top), and so do the front page and `/me`: a page renders each URL once, however many read it.
get! : { request : Server.Request, params : {}, context : Middlewares.Context } => Try(Tasks.Team, Endpoint.Refusal)
get! = |{ context, .. }| {
	people = Store.people!({}).map_err!(Store.refusal!)?
	lists = Store.lists!({}).map_err!(Store.refusal!)?
	# A session naming nobody on the team (someone who has left) is nobody.
	me = if (people.any(|person| person.id == context.me)) context.me else ""
	Ok({ me, people, lists })
}
