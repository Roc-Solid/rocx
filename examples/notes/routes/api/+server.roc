import pf.Server
import pf.Endpoint
import ../../Middlewares
import ../../Notebook
import ../../Pages
import ../../Query

middleware = Middlewares.signed_in

## GET /api: the notebook, as its page (`/`) reads it. `?q=` is a search (words, `#tags`), best
## match first, archived notes too; or else `?tag=` lists a tag's notes, and `?archived=true` the
## archived ones; or else every note, pinned first. With your tags, for the sidebar.
get! : { request : Server.Request, params : {}, context : Middlewares.Me } => Try(Pages.Home, Endpoint.Refusal)
get! = |{ request, context, .. }| {
	query = Query.value(request.query, "q").trim()
	tag = Query.value(request.query, "tag")
	archived = Query.flag(request.query, "archived")
	notes =
		if query.is_empty() {
			Notebook.list!(context, { archived, tags: if (tag.is_empty()) [] else [tag] })?
		} else {
			Notebook.search!(context, query)?
		}
	tags = Notebook.tags!(context)?
	Ok({ email: context.person.email, query, tag, archived, notes, tags })
}
