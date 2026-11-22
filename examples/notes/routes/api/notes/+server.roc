import pf.Server
import pf.Endpoint
import ../../../Middlewares
import ../../../Note
import ../../../Notebook
import ../../../Query

## The JSON API: your notes, for scripts and AI clients, with a personal access token
## (`Authorization: Bearer acme_pat_…`) or the session cookie. /openapi.html describes every
## endpoint; MCP's tools are made of these (Agents.roc).
middleware = Middlewares.api

## Your notes, pinned first, then the latest changed: `?archived=true` for the archived ones,
## `?tag=work` for a tag's (once for each tag a note must have). Each with the start of its words.
get! : { request : Server.Request, params : {}, context : Middlewares.Me } => Try(List(Note.Summary), Endpoint.Refusal)
get! = |{ request, context, .. }| Notebook.list!(context, { archived: Query.flag(request.query, "archived"), tags: Query.values(request.query, "tag") })

## A new note: its title (1 to 200 characters), its body in Markdown, and its tags (letters,
## digits and dashes; 12 at most). The note, with its id. Refused to a read-only token.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : { title : Str, body : Str, tags : List(Str) } } => Try(Note.Full, Endpoint.Refusal)
post! = |{ context, body, .. }| Notebook.create!(context, body)
