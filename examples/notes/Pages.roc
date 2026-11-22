import Note
import Token

## What each signed-in page reads from the server, as its endpoint answers it (at the page's own
## address: `GET /` for the notebook). Written here so both halves agree: in the browser's copy of
## the app an endpoint has no types, so each page says what it reads.
Pages := [].{

	## The notebook (`/`): your notes, or a search's, and your tags.
	Home : { email : Str, query : Str, tag : Str, archived : Bool, notes : List(Note.Summary), tags : List(Note.Tagged) }

	## A note's page and its editor (`/notes/<id>`).
	Opened : { email : Str, note : Note.Full }

	## A new note's page (`/new`).
	Blank : { email : Str }

	## Settings (`/settings`): your personal access tokens, and where the MCP server is.
	Settings : { email : Str, mcp : Str, tokens : List(Token.Listed) }
}
