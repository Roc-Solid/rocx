import pf.Server
import pf.Endpoint
import ../../../Notes

## GET /api/notes: every note, oldest first.
get! : { request : Server.Request, params : {}, context : c } => Try(List({ id : U64, text : Str }), Endpoint.Refusal)
get! = |_input| Ok(Notes.all!({}))
