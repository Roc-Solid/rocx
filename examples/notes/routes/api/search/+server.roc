import pf.Server
import pf.Endpoint
import ../../../Middlewares
import ../../../Note
import ../../../Notebook

middleware = Middlewares.api

## Your notes that match `query`, best first, archived ones too: words, `"an exact phrase"`, `or`,
## `-without`, and `#tag` for only a tag's notes. Each with the parts that matched (`hit`). A POST,
## as search APIs often are, so the query isn't in a URL's logs.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : { query : Str } } => Try(List(Note.Summary), Endpoint.Refusal)
post! = |{ context, body, .. }| Notebook.search!(context, body.query)
